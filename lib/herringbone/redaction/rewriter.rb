# frozen_string_literal: true

module Herringbone
  class Redaction
    # Applies a Redaction to one file. Building it checks the redaction against the file's schema,
    # so mistakes surface before anything is written.
    #
    # Each row group lands in one of three tiers. When no statement can match (by statistics,
    # bloom filters and the page index, or by reading the condition columns), its column chunks
    # are copied byte for byte. When rows match but none is deleted and only leaf columns change,
    # the changed chunks are re-encoded and the others copied. Otherwise the whole row group is
    # rewritten, keeping its boundary: one row group in, one (or none) out.
    class Rewriter
      # A replaced column, resolved against the file's schema
      #
      # @!attribute name
      #   @return [String] the column as named in the statement
      # @!attribute path
      #   @return [Array<String>] top-level field name, then struct member names
      # @!attribute field
      #   @return [Schema::Field] the replaced field
      # @!attribute column
      #   @return [Schema::Column, nil] the leaf column, nil when the field is nested
      Target = Struct.new(:name, :path, :field, :column)

      # Writer options that make no sense here, since row groups keep their boundaries
      ROW_GROUP_OPTIONS = %i[row_group_bytes row_group_rows].freeze
      # Footer metadata that describes the columns, and goes stale when some are dropped
      COLUMN_METADATA_KEYS = %w[ARROW:schema pandas].freeze
      # What #current returns for a struct member of a null struct
      ABSENT = Object.new.freeze

      # @param redaction [Redaction] the statements and drops to apply
      # @param io_or_reader [IO, StringIO, Reader] the Parquet file, read with #seek and #read, or a
      #   Reader of it (whose IO and decryption are used)
      # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, nil] keys of an encrypted
      #   file, see Reader.new; not with a Reader
      # @raise [ArgumentError] when +io_or_reader+ is neither an IO nor a Reader, when a Reader comes
      #   with +decryption:+, or when a statement or drop does not fit the file's schema
      # @raise [FormatError] when the footer cannot be read
      # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted
      def initialize(redaction, io_or_reader, decryption: nil)
        @reader = fixed_options_reader(io_or_reader, decryption)
        @copier = Reader::ChunkCopier.new(@reader, @reader.io)
        @schema = @reader.schema
        @statements = redaction.statements
        @filters = @statements.map { |s| s.where && Reader::Filter.new(@schema, s.where) }
        @targets = @statements.map { |s| s.targets.map { |name| target(name, s) } }
        @row_blocks = @statements.map { |s| s.block && wants_row?(s.block) }
        @drops = redaction.drops.uniq.map { |name| resolve(name, "drop")[1] }
        check_drops!
        @output_schema = output_schema
        @output_columns = @output_schema.columns.map { |c| @schema.column(c.path) }
        @first_rows = @reader.row_groups.each_with_object([0]) { |rg, firsts| firsts << firsts.last + rg.num_rows }
        @rows_read = 0
        @data = {}
      end

      # @return [Boolean] see Redaction#affects?
      def affects?
        return true unless @drops.empty?
        @reader.row_groups.each_index.any? do |i|
          @data = {}
          candidates = candidates(i)
          next false if candidates.empty?
          candidates.any? { |k| @filters[k].nil? } || any_match?(i, candidates)
        end
      end

      # @param output_io [IO, #write] destination
      # @param options [Hash{Symbol => Object}] Writer options for re-encoded chunks, and +metadata:+
      # @option options [Symbol] :compression (codec of each source chunk) codec for re-encoded chunks
      # @option options [Integer, nil] :compression_level (nil) level for that codec, see Writer
      # @option options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
      #   columns whose re-encoded chunks get a bloom filter, besides those whose source chunk had one
      # @option options [Hash{String => String}] :metadata (the input's) footer key/value metadata
      # @option options [Integer] :page_bytes (1MB) approximate uncompressed data page size
      # @option options [Integer] :page_rows (20_000) maximum rows per data page
      # @option options [Integer] :data_page_version (1) 1 or 2
      # @option options [Boolean, Array<String>] :dictionary (true) see Writer
      # @option options [Hash{String => Symbol}] :encodings ({}) see Writer
      # @option options [EncryptionConfiguration, Hash{Symbol => Object}, false] :encryption (as the input) see Writer
      # @return [Report]
      # @raise [ArgumentError] for +row_group_bytes:+ / +row_group_rows:+ or an invalid writer option
      # @raise [EncodeError] when a replacement value cannot be written
      # @raise [DecryptionError] when the output is to be encrypted like the input but a key is missing
      def apply(output_io, **options)
        bad = options.keys & ROW_GROUP_OPTIONS
        raise ArgumentError, "#{bad.join(", ")}: a redaction keeps the row groups of the input" unless bad.empty?
        @keep_codecs = !options.key?(:compression)
        options = {metadata: copied_metadata}.merge(options)
        options[:encryption] = input_encryption unless options.key?(:encryption)
        writer = Writer.new(output_io, @output_schema, row_group_bytes: 1 << 62, **options)
        @report = Report.new(rows_read: 0, rows_deleted: 0, rows_changed: 0, row_groups: {copied: 0, rewritten: 0})
        begin
          @reader.row_groups.each_index { |i| redact_row_group(i, writer) }
        rescue Exception # rubocop:disable Lint/RescueException -- also abort on Interrupt
          writer.abort
          raise
        end
        writer.close
        @report.rows_read = @rows_read
        @report
      end

      private

      # The caller's Reader may have been built with +keys:+ or +time_zone:+, which change what
      # #read returns, so values are always read through a Reader with the default options
      #
      # @param io_or_reader [IO, StringIO, Reader] the Parquet file, or a Reader of it
      # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, nil] keys, for an IO only
      # @return [Reader]
      # @raise [ArgumentError] when +io_or_reader+ is neither an IO nor a Reader, or a Reader comes
      #   with +decryption:+
      def fixed_options_reader(io_or_reader, decryption)
        if io_or_reader.is_a?(Reader)
          if decryption
            raise ArgumentError, "decryption: cannot be given with a Herringbone::Reader, which " \
              "already has its decryption (pass decryption: to Reader.new instead)"
          end
          return Reader.new(io_or_reader.io, decryption: io_or_reader.decryption)
        end
        unless io_or_reader.respond_to?(:seek) && io_or_reader.respond_to?(:read)
          raise ArgumentError, "io_or_reader must be an IO that supports #seek and #read " \
            "(e.g. File.open(path, \"rb\")) or a Herringbone::Reader, got #{io_or_reader.class}"
        end
        Reader.new(io_or_reader, decryption: decryption)
      end

      # @param i [Integer] row group index
      # @param writer [Writer] the output
      # @return [void]
      def redact_row_group(i, writer)
        @data = {}
        candidates = candidates(i)
        if candidates.empty? || (candidates.all? { |k| @filters[k] } && !any_match?(i, candidates))
          return copy_row_group(i, writer)
        end
        deleted, changed = run_statements(i)
        if deleted.none? && changed.empty?
          copy_row_group(i, writer)
        elsif deleted.none? && changed.all?(&:column)
          rewrite_columns(i, writer, changed)
        else
          rewrite_row_group(i, writer, deleted, changed)
        end
      end

      # Statements that may touch row group +i+: those without conditions, and those whose
      # conditions the statistics, bloom filters and page index do not rule out
      #
      # @param i [Integer] row group index
      # @return [Array<Integer>] statement indexes
      def candidates(i)
        return [] if rows(i).zero?
        @statements.each_index.select do |k|
          filter = @filters[k]
          filter.nil? || (filter.row_group_may_match?(@reader, i) && !filter.page_ranges(@reader, i).empty?)
        end
      end

      # Reads the condition columns of row group +i+ and checks them against the original values.
      # When no row matches any statement, no statement changes anything (later statements see
      # what earlier ones changed, and none did), so the row group can be copied.
      #
      # @param i [Integer] row group index
      # @param candidates [Array<Integer>] indexes of statements, all with conditions
      # @return [Boolean] whether some row matches some statement
      def any_match?(i, candidates)
        fields = candidates.flat_map { |k| @filters[k].fields }.uniq
        load(i, fields.map(&:name))
        data = fields.map { |f| @data[f.name] }
        candidates.any? { |k| !@filters[k].matching_rows(data, fields, rows(i), false).empty? }
      end

      # Applies the statements to every row of row group +i+, in place in @data
      #
      # @param i [Integer] row group index
      # @return [Array(Array<Boolean>, Array<Target>)] deleted flag per row, and the targets whose
      #   values changed
      def run_statements(i)
        names = if @row_blocks.any?
          @schema.fields.map(&:name)
        else
          @filters.compact.flat_map { |f| f.fields.map(&:name) } + @targets.flatten.map { |t| t.path.first }
        end
        load(i, names.uniq)
        n = rows(i)
        deleted = Array.new(n, false)
        changed = {}
        n.times do |r|
          row_changed = false
          @statements.each_with_index do |statement, k|
            filter = @filters[k]
            next if filter && !row_matches?(filter, r)
            if statement.kind == :delete
              deleted[r] = true
              break
            end
            @targets[k].each do |t|
              old = current(t, r)
              next if old.equal?(ABSENT)
              value = if @row_blocks[k] then statement.block.call(old, row_hash(r))
              elsif statement.block then statement.block.call(old)
              else statement.constants[t.name]
              end
              next unless value != old
              assign(t, r, value)
              changed[t.path] ||= t
              row_changed = true
            end
          end
          if deleted[r]
            @report.rows_deleted += 1
          elsif row_changed
            @report.rows_changed += 1
          end
        end
        [deleted, changed.values]
      end

      # @param filter [Reader::Filter] conditions of a statement
      # @param r [Integer] row index within the row group
      # @return [Boolean] whether the row, as earlier statements left it, matches all conditions
      def row_matches?(filter, r)
        filter.conditions.all? do |c|
          value = c.path.reduce(@data[c.field.name][r]) { |h, key| h.is_a?(Hash) ? h[key] : nil }
          Reader::Filter.matches?(c.test, value)
        end
      end

      # @param t [Target] replaced column
      # @param r [Integer] row index within the row group
      # @return [Object] the column's current value, or ABSENT when a struct holding it is null
      def current(t, r)
        value = @data[t.path.first][r]
        t.path.drop(1).each do |key|
          return ABSENT unless value.is_a?(Hash)
          value = value[key]
        end
        value
      end

      # Stores a value, copying the struct Hashes on the way so nothing else shares them
      #
      # @param t [Target] replaced column
      # @param r [Integer] row index within the row group
      # @param value [Object] the new value
      # @return [void]
      def assign(t, r, value)
        column = @data[t.path.first]
        return column[r] = value if t.path.size == 1
        hash = column[r] = column[r].dup
        t.path[1...-1].each { |key| hash = hash[key] = hash[key].dup }
        hash[t.path.last] = value
      end

      # @param r [Integer] row index within the row group
      # @return [Hash{String => Object}] the whole row as it stands, keyed by top-level field name
      def row_hash(r)
        @schema.fields.to_h { |f| [f.name, @data[f.name][r]] }
      end

      # Tier 1: every kept column chunk is copied as it is, except those encrypted in the input or
      # the output, which are encoded again
      #
      # @param i [Integer] row group index
      # @param writer [Writer] the output
      # @return [void]
      def copy_row_group(i, writer)
        unless encrypted_columns(i, writer).empty?
          rewrite_columns(i, writer, [])
          @report.row_groups[:copied] += 1
          return
        end
        copies = @output_columns.each_with_index.to_h { |col, j| [j, @copier.copy(i, col)] }
        writer.write_row_group(rows(i), copies: copies, sorting_columns: sorting_columns(i, []))
        @report.row_groups[:copied] += 1
      end

      # Tier 2: the chunks of the changed leaf columns (and of encrypted ones) are encoded again,
      # the rest are copied
      #
      # @param i [Integer] row group index
      # @param writer [Writer] the output
      # @param changed [Array<Target>] leaf targets whose values changed
      # @return [void]
      def rewrite_columns(i, writer, changed)
        rewritten = changed.map { |t| t.column.index }
        encoded = rewritten | encrypted_columns(i, writer)
        names = encoded.map { |index| @schema.columns[index].path.first }.uniq
        load(i, names)
        names.each { |name| writer.buffer_field(name, @data[name]) }
        copies = {}
        codecs = {}
        blooms = {}
        @output_columns.each_with_index do |col, j|
          if encoded.include?(col.index)
            chunk_settings(i, col, j, codecs, blooms)
          else
            copies[j] = @copier.copy(i, col)
          end
        end
        writer.write_row_group(rows(i), copies: copies, codecs: codecs, bloom_filters: blooms,
          sorting_columns: sorting_columns(i, rewritten))
        @report.row_groups[:rewritten] += 1 unless changed.empty?
      end

      # Kept columns whose chunk in row group +i+ cannot be copied, because it is encrypted in the
      # input (its AAD names the file and the chunk's place in it) or is to be encrypted
      #
      # @param i [Integer] row group index
      # @param writer [Writer] the output
      # @return [Array<Integer>] input column indexes
      def encrypted_columns(i, writer)
        chunks = @reader.row_groups[i].columns
        @output_columns.each_with_index.filter_map do |col, j|
          col.index if chunks.fetch(col.index).crypto_metadata || writer.encrypted_column?(j)
        end
      end

      # The Writer +encryption:+ option that encrypts the output like the input: the same
      # algorithm, footer mode, AAD prefix and keys, for the columns that are kept
      #
      # @return [EncryptionConfiguration, nil] nil for a plaintext input
      # @raise [DecryptionError] when a key of the input was not given
      def input_encryption
        decryptor = @reader.decryptor or return nil
        chunks = @reader.row_groups.first&.columns || []
        columns = @output_columns.each_with_index.filter_map do |col, j|
          chunk = chunks[col.index]
          crypto = chunk&.crypto_metadata or next
          path = @output_schema.columns[j].dotted_path
          with_column_key = crypto.encryption_with_column_key
          next [path, :footer] unless with_column_key
          key = decryptor.chunk_key(chunk, col.dotted_path)
          key or raise DecryptionError, "The output is encrypted like the input, which needs the key of #{col.dotted_path}: " \
            "pass it in decryption:, or pass encryption: for the output"
          [path, {key: key, key_metadata: with_column_key.key_metadata}]
        end
        uniform = !columns.empty? && columns.size == @output_columns.size && columns.all? { |_, v| v == :footer }
        decryptor.writer_settings(uniform ? nil : columns.to_h)
      end

      # Tier 3: the remaining rows are encoded again, every column of them
      #
      # @param i [Integer] row group index
      # @param writer [Writer] the output
      # @param deleted [Array<Boolean>] deleted flag per row
      # @param changed [Array<Target>] targets whose values changed
      # @return [void]
      def rewrite_row_group(i, writer, deleted, changed)
        @report.row_groups[:rewritten] += 1
        kept = deleted.count(false)
        return if kept.zero?
        load(i, @output_schema.fields.map(&:name))
        @output_schema.fields.each do |f|
          values = @data[f.name]
          values = values.reject.with_index { |_, r| deleted[r] } if kept < values.size
          writer.buffer_field(f.name, values)
        end
        codecs = {}
        blooms = {}
        @output_columns.each_with_index { |col, j| chunk_settings(i, col, j, codecs, blooms) }
        rewritten = changed.flat_map { |t| t.field.leaves.map(&:index) }
        writer.write_row_group(kept, codecs: codecs, bloom_filters: blooms, sorting_columns: sorting_columns(i, rewritten))
      end

      # Codec and bloom filter of a re-encoded chunk follow the source chunk (see
      # Reader::ChunkCopier#recode_settings), unless +compression:+ was given
      #
      # @param i [Integer] row group index
      # @param col [Schema::Column] the input column
      # @param j [Integer] the output column index
      # @param codecs [Hash{Integer => Integer}] collects output column index => codec id
      # @param blooms [Hash{Integer => Boolean}] collects output column index => true
      # @return [void]
      def chunk_settings(i, col, j, codecs, blooms)
        codec, bloom = @copier.recode_settings(i, col)
        codecs[j] = codec if codec && @keep_codecs
        blooms[j] = true if bloom
      end

      # The row group's sorting columns that still hold: dropped or changed columns end the list,
      # since the columns after them were only sorted within their runs
      #
      # @param i [Integer] row group index
      # @param rewritten [Array<Integer>] indexes of input columns whose values changed
      # @return [Array<Format::SortingColumn>, nil]
      def sorting_columns(i, rewritten)
        out = []
        (@reader.row_groups[i].sorting_columns || []).each do |sc|
          col = @schema.columns[sc.column_idx]
          j = col && !rewritten.include?(col.index) && @output_columns.index(col)
          break unless j
          out << Format::SortingColumn.new(column_idx: j, descending: sc.descending, nulls_first: sc.nulls_first)
        end
        out.empty? ? nil : out
      end

      # Reads top-level fields of row group +i+ into @data, unless they are there already
      #
      # @param i [Integer] row group index
      # @param names [Array<String>] top-level field names
      # @return [void]
      def load(i, names)
        missing = names - @data.keys
        return if missing.empty?
        n = rows(i)
        @rows_read += n if @data.empty?
        @data.merge!(@reader.read(as: :columns, columns: missing, from: @first_rows[i], limit: n))
      end

      # @param i [Integer] row group index
      # @return [Integer] rows in the row group
      def rows(i) = @reader.row_groups[i].num_rows

      # @return [Hash{String => String, nil}] the input's key/value metadata, without the keys that
      #   describe the columns when some are dropped
      def copied_metadata
        meta = @reader.metadata
        @drops.empty? ? meta : meta.except(*COLUMN_METADATA_KEYS)
      end

      # @param block [Proc] a replace block
      # @return [Boolean] whether the block takes the row as a second parameter
      def wants_row?(block)
        params = block.parameters
        params.any? { |type, _| type == :rest } || params.count { |type, _| type == :req || type == :opt } >= 2
      end

      # Resolves a column named in a statement: a top-level field, or a struct member by dotted path
      #
      # @param name [String] the column as named
      # @param verb [String] "replace" or "drop", for error messages
      # @return [Array(Schema::Field, Array<String>)] the field and its path of names
      # @raise [ArgumentError] when there is no such column, or it is inside a list or map
      def resolve(name, verb)
        field = @schema.field(name)
        return [field, [name]] if field
        parts = name.split(".")
        field = @schema.field(parts.first) or raise ArgumentError, "#{verb}: no such column #{name.inspect}"
        parts.drop(1).each_with_index do |part, depth|
          case field.kind
          when :struct
            field = field.children_by_name[part] or raise ArgumentError, "#{verb}: no such column #{name.inspect}"
          when :list, :map
            whole = parts.first(depth + 1).join(".")
            container = (field.kind == :map) ? "Hash" : "Array"
            hint = (verb == "replace") ? " with a block that receives its #{container}" : ""
            raise ArgumentError, "#{verb}: #{name} is inside the #{field.kind} #{whole}; #{verb} #{whole} instead#{hint}"
          else
            raise ArgumentError, "#{verb}: no such column #{name.inspect}"
          end
        end
        [field, parts]
      end

      # @param name [String] the column as named in the statement
      # @param statement [Statement] the replace statement
      # @return [Target]
      # @raise [ArgumentError] when the column does not exist, is inside a list or map, or a
      #   constant cannot be stored in it (nil in a required column, a value of the wrong type)
      def target(name, statement)
        field, path = resolve(name, "replace")
        if statement.block.nil?
          value = statement.constants[name]
          if value.nil?
            raise ArgumentError, "replace: #{name} is required (null: false) and cannot be set to nil" unless field.optional
          elsif field.leaf?
            begin
              field.column.encoder.call(value)
            rescue ArgumentError, TypeError, NoMethodError, RangeError => e
              raise ArgumentError, "replace: cannot write #{value.inspect} to #{name}: #{e.message}"
            end
          end
        end
        Target.new(name, path, field, field.leaf? ? field.column : nil)
      end

      # @return [void]
      # @raise [ArgumentError] when a replaced column is dropped
      def check_drops!
        @targets.flatten.each do |t|
          dropped = @drops.find { |path| t.path.first(path.size) == path }
          raise ArgumentError, "replace: #{t.name} is dropped by drop(#{dropped.join(".").inspect})" if dropped
        end
      end

      # The input schema without the dropped fields
      #
      # @return [Schema]
      # @raise [ArgumentError] when every column, or every member of a struct, would be dropped
      def output_schema
        return @schema if @drops.empty?
        copy = Schema.from_elements(@schema.to_elements)
        emptied = @drops.filter_map do |path|
          parent = path[0...-1].reduce(copy.root) { |node, name| node&.children&.find { |c| c.name == name } }
          node = parent&.children&.find { |c| c.name == path.last }
          next unless node
          parent.children.delete(node)
          parent if parent.children.empty?
        end
        emptied.each do |node|
          raise ArgumentError, "drop: cannot drop every column" if node.equal?(copy.root)
          raise ArgumentError, "drop: cannot drop every member of #{node.path.join(".")}; drop #{node.path.join(".")} instead"
        end
        Schema.new(copy.root)
      end
    end
  end
end
