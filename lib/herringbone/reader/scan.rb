# frozen_string_literal: true

module Herringbone
  class Reader
    # Row selection for where: filters. A filter maps columns to conditions:
    #
    #   where: { "user_id" => 42,                      # equality
    #            "status" => %w[paid shipped],         # any of these (IN)
    #            "created_at" => t1...t2,              # Ranges, also endless / beginless
    #            "address.city" => "Amsterdam",        # a member of a struct, by dotted path
    #            "deleted_at" => nil,                  # IS NULL
    #            "amount" => ->(v) { v && v > 100 } }  # any callable (row check only)
    #
    # All conditions must hold. The filter is used three ways, from cheapest to most exact:
    # whole row groups are ruled out with column chunk statistics (min/max, null counts) and
    # bloom filters; within a row group, pages are ruled out with the page index (ColumnIndex +
    # OffsetIndex), leaving ranges of rows to read; and every row that is read is checked, so
    # results are exact.
    class Filter
      # One where: entry, resolved against the schema
      #
      # @!attribute [rw] name
      #   @return [String] the key as given (dotted path of a leaf column)
      # @!attribute [rw] column
      #   @return [Schema::Column] the leaf column the condition reads
      # @!attribute [rw] field
      #   @return [Schema::Field] the top-level field holding that column
      # @!attribute [rw] path
      #   @return [Array<String>] member names from the top-level field down to the column
      #     (empty for a top-level column)
      # @!attribute [rw] test
      #   @return [Object] the condition, with Symbols turned into Strings
      Condition = Struct.new(:name, :column, :field, :path, :test)

      # @return [Array<Condition>] one per where: entry, in the order given
      attr_reader :conditions

      # @param schema [Schema] schema of the file being read
      # @param where [Hash{String, Symbol => Object}] column => condition (see the class docs)
      # @raise [ArgumentError] when +where+ is not a Hash, names an unknown column, or a column
      #   inside a list or map
      def initialize(schema, where)
        raise ArgumentError, "where: must be a Hash of column => condition" unless where.is_a?(Hash)
        @conditions = where.map do |key, test|
          name = key.to_s
          column = schema.column(name) or raise ArgumentError, "where: no such column #{name.inspect}"
          if column.max_repetition_level.positive?
            raise ArgumentError, "where: #{name} is inside a list or map; only non-repeated columns can be filtered on"
          end
          field = schema.field(column.path.first)
          Condition.new(name, column, field, column.path.drop(1), normalize(test))
        end
      end

      # Top-level fields the conditions need to read
      #
      # @return [Array<Schema::Field>] distinct fields, in condition order
      def fields
        @conditions.map(&:field).uniq
      end

      # --- statistics-based pruning ---

      # Whether any row of row group +rg_index+ may match, judging by chunk statistics and bloom
      # filters
      #
      # @param reader [Reader] reader of the file (for its footer and bloom filters)
      # @param rg_index [Integer] position of the row group in the footer
      # @return [Boolean] false only when no row of the row group can match
      def row_group_may_match?(reader, rg_index)
        chunks = reader.row_groups[rg_index].columns
        @conditions.all? do |c|
          meta = chunks[c.column.index].meta_data
          next true unless meta
          min, max = Filter.stat_range(c.column, meta.statistics)
          nulls = meta.statistics&.null_count
          all_null = nulls && nulls == meta.num_values
          Filter.may_match?(c.test, min, max, nulls, all_null) && bloom_may_match?(reader, rg_index, c)
        end
      end

      # Sorted, non-overlapping [first_row, end_row) ranges of row group +rg_index+ that may hold
      # matching rows, judging by the page index. Columns without a page index do not narrow
      # the ranges.
      #
      # @param reader [Reader] reader of the file (for its page index)
      # @param rg_index [Integer] position of the row group in the footer
      # @return [Array<Array(Integer, Integer)>] half-open row ranges within the row group
      def page_ranges(reader, rg_index)
        n = reader.row_groups[rg_index].num_rows
        ranges = [[0, n]]
        @conditions.each do |c|
          column_index, offset_index = reader.page_index(rg_index, c.column)
          next unless column_index && offset_index
          locs = offset_index.page_locations
          next unless locs && column_index.null_pages && locs.size == column_index.null_pages.size
          candidates = []
          locs.each_with_index do |loc, i|
            min = max = nil
            unless column_index.null_pages[i]
              min = Filter.decode_stat(c.column, column_index.min_values[i])
              max = Filter.decode_stat(c.column, column_index.max_values[i])
            end
            nulls = column_index.null_counts&.[](i)
            next unless Filter.may_match?(c.test, min, max, nulls, column_index.null_pages[i])
            stop = (i + 1 < locs.size) ? locs[i + 1].first_row_index : n
            candidates << [loc.first_row_index, stop]
          end
          ranges = Filter.intersect(ranges, Filter.merge(candidates))
          break if ranges.empty?
        end
        ranges
      end

      # --- row checks ---

      # Indexes (0...k) of the rows of an assembled batch that match. +data+ holds one Array per
      # field in +fields+; +symbolize+ says how struct Hashes are keyed.
      #
      # @param data [Array<Array>] assembled values, one Array of +k+ entries per field
      # @param fields [Array<Schema::Field>] the fields +data+ holds, in the same order
      # @param k [Integer] number of rows in the batch
      # @param symbolize [Boolean] whether struct Hashes are keyed by Symbol
      # @return [Array<Integer>] indexes of matching rows, ascending
      def matching_rows(data, fields, k, symbolize)
        columns = @conditions.map do |c|
          values = data.fetch(fields.index(c.field))
          next values if c.path.empty?
          path = symbolize ? c.path.map(&:to_sym) : c.path
          values.map { |v| path.reduce(v) { |h, key| h&.[](key) } }
        end
        tests = @conditions.map(&:test)
        (0...k).select do |i|
          j = 0
          ok = true
          while ok && j < tests.size
            ok = Filter.matches?(tests[j], columns[j][i])
            j += 1
          end
          ok
        end
      end

      # --- condition evaluation ---

      # Whether a value satisfies a condition: nil matches nulls, an Array any of its elements,
      # a Range by #cover? (never nil, incomparable values do not match), a String by bytes
      # (ignoring the encoding), a callable by its result, anything else by ==.
      #
      # @param test [Object] the condition
      # @param v [Object] the row's value
      # @return [Boolean] true when the value matches
      def self.matches?(test, v)
        case test
        when nil then v.nil?
        when Array then test.any? { |t| matches?(t, v) }
        when Range then !v.nil? && begin
          test.cover?(v)
        rescue
          false
        end
        when String then v.is_a?(String) && (v == test || (v.bytesize == test.bytesize && v.b == test.b))
        else
          if test.respond_to?(:call) then test.call(v)
          else v == test
          end
        end
      end

      # Whether a set of values with the given bounds may contain a match. Unknown bounds or
      # values that cannot be compared never rule anything out.
      #
      # @param test [Object] the condition
      # @param min [Object, nil] lower bound of the values, nil when unknown
      # @param max [Object, nil] upper bound of the values, nil when unknown
      # @param nulls [Integer, nil] number of nulls, nil when unknown
      # @param all_null [Boolean, nil] whether every value is null
      # @return [Boolean] false only when no value can match
      def self.may_match?(test, min, max, nulls, all_null)
        case test
        when nil then nulls.nil? || nulls.positive?
        when Array then test.any? { |t| may_match?(t, min, max, nulls, all_null) }
        when Range
          return false if all_null
          lo = test.begin
          hi = test.end
          if !hi.nil? && !min.nil?
            c = compare(min, hi)
            return false if c && (c.positive? || (test.exclude_end? && c.zero?))
          end
          if !lo.nil? && !max.nil?
            c = compare(max, lo)
            return false if c&.negative?
          end
          true
        else
          return true if test.respond_to?(:call)
          return false if all_null
          lo = min.nil? ? nil : compare(test, min)
          hi = max.nil? ? nil : compare(test, max)
          !(lo&.negative? || hi&.positive?)
        end
      end

      # Booleans compare as integers, false before true (the Parquet sort order)
      BOOLEAN_ORDER = {false => 0, true => 1}.freeze

      # Compares two values in Parquet order: Strings byte-wise, false before true
      #
      # @param a [Object] left-hand value
      # @param b [Object] right-hand value
      # @return [Integer, nil] -1, 0 or 1, or nil when the values cannot be compared
      def self.compare(a, b)
        a = a.b if a.is_a?(String)
        b = b.b if b.is_a?(String)
        a = BOOLEAN_ORDER.fetch(a, a)
        b = BOOLEAN_ORDER.fetch(b, b)
        a <=> b
      rescue
        nil
      end

      # [min, max] of a chunk's statistics as Ruby values, or [nil, nil] when unusable
      #
      # @param column [Schema::Column] the chunk's column, for decoding the bounds
      # @param stats [Format::Statistics, nil] the chunk's statistics
      # @return [Array(Object, Object)] min and max, each nil when unknown
      def self.stat_range(column, stats)
        return [nil, nil] unless stats
        if stats.min_value && stats.max_value
          [decode_stat(column, stats.min_value), decode_stat(column, stats.max_value)]
        elsif stats.min && stats.max && legacy_order_ok?(column)
          [decode_stat(column, stats.min), decode_stat(column, stats.max)]
        else
          [nil, nil]
        end
      end

      # The deprecated min/max fields were written with signed comparisons, which only agree
      # with the logical order for signed numbers and booleans
      #
      # @param column [Schema::Column] column whose statistics are being read
      # @return [Boolean] true when the legacy min/max fields can be trusted
      def self.legacy_order_ok?(column)
        kind, _, signed = Types.logical_of(column.node)
        case column.type
        when Format::Type::BOOLEAN, Format::Type::FLOAT, Format::Type::DOUBLE then true
        when Format::Type::INT32, Format::Type::INT64 then !(kind == :integer && !signed)
        else false
        end
      end

      # Decodes a min/max bound (PLAIN encoding of one value) into a Ruby value
      #
      # @param column [Schema::Column] the column the bound belongs to
      # @param bytes [String, nil] the encoded bound
      # @return [Object, nil] the value, or nil when it is absent or cannot be used (INT96,
      #   truncated FIXED_LEN_BYTE_ARRAY, too short, undecodable)
      def self.decode_stat(column, bytes)
        return nil if bytes.nil?
        type = column.type
        value = case type
        when Format::Type::INT96 then return nil # no defined order
        when Format::Type::BYTE_ARRAY, Format::Type::FIXED_LEN_BYTE_ARRAY
          # Truncated bounds (shorter than the type length) still bound byte-wise
          return (type == Format::Type::FIXED_LEN_BYTE_ARRAY && bytes.bytesize != column.type_length) ? nil : convert(column, bytes.dup)
        when Format::Type::BOOLEAN then bytes.getbyte(0) == 1
        else
          return nil if bytes.bytesize < {Format::Type::INT32 => 4, Format::Type::FLOAT => 4}.fetch(type, 8)
          Encodings::Plain.decode(bytes, 0, 1, type).first.first
        end
        convert(column, value)
      rescue
        nil
      end

      # Applies the column's converter, so bounds compare with the values rows hold
      #
      # @param column [Schema::Column] the column the value belongs to
      # @param value [Object] physical value
      # @return [Object] the Ruby value
      def self.convert(column, value)
        conv = column.converter
        conv ? conv.call(value) : value
      end

      # Sorts ranges and merges overlapping or touching ones
      #
      # @param ranges [Array<Array(Integer, Integer)>] half-open row ranges
      # @return [Array<Array(Integer, Integer)>] sorted, non-overlapping ranges
      def self.merge(ranges)
        ranges.sort.each_with_object([]) do |(s, e), out|
          if out.any? && s <= out.last[1]
            out.last[1] = e if e > out.last[1]
          else
            out << [s, e]
          end
        end
      end

      # Intersection of two sorted, non-overlapping lists of half-open ranges
      #
      # @param a [Array<Array(Integer, Integer)>] first list of ranges
      # @param b [Array<Array(Integer, Integer)>] second list of ranges
      # @return [Array<Array(Integer, Integer)>] the rows in both, sorted
      def self.intersect(a, b)
        out = []
        i = j = 0
        while i < a.size && j < b.size
          s = [a[i][0], b[j][0]].max
          e = [a[i][1], b[j][1]].min
          out << [s, e] if s < e
          (a[i][1] < b[j][1]) ? i += 1 : j += 1
        end
        out
      end

      private

      # Symbols (also inside Arrays) become Strings, since columns never hold Symbols
      #
      # @param test [Object] a condition as given in where:
      # @return [Object] the condition to store in Condition#test
      def normalize(test)
        case test
        when Symbol then test.to_s
        when Array then test.map { |t| normalize(t) }
        else test
        end
      end

      # Bloom filters answer equality lookups (a value or a list of values)
      #
      # @param reader [Reader] reader of the file (for its bloom filters)
      # @param rg_index [Integer] position of the row group in the footer
      # @param condition [Condition] the condition to check
      # @return [Boolean] false only when the bloom filter rules out every value of the condition
      def bloom_may_match?(reader, rg_index, condition)
        values = Array(condition.test.is_a?(Array) ? condition.test : [condition.test])
        return true if values.empty? || values.any? { |v| v.nil? || v.is_a?(Range) || v.respond_to?(:call) }
        return true unless reader.respond_to?(:bloom_filter)
        filter = reader.bloom_filter(rg_index, condition.column.path)
        return true unless filter
        values.any? { |v| filter.might_contain?(v) }
      rescue
        true # values the column cannot store never rule a row group out here; rows are checked anyway
      end
    end
  end
end
