# frozen_string_literal: true

module Herringbone
  class Reader
    # read(as: :numo) and each_batch(as: :numo): columns as Numo arrays. Numo is optional:
    # "numo/narray" (from numo-narray-alt or numo-narray) is required on first use.
    #
    # Flat INT32 / INT64 / FLOAT / DOUBLE / BOOLEAN columns are decoded without a Ruby object
    # per value: PLAIN and BYTE_STREAM_SPLIT pages go through Numo::X.from_binary, dictionary
    # pages through dictionary[indices], and definition levels become a validity mask. Other
    # columns are read like as: :columns and converted per batch.
    #
    # Type mapping (following Polars' Series#to_numo and Rover):
    #   INT32 / INT64 (also TIME)       Numo::Int32 / Int64
    #   INT(8/16, signed)               Int8 / Int16
    #   INT(8/16/32/64, unsigned)       UInt8 / UInt16 / UInt32 / UInt64
    #   FLOAT / FLOAT16 / DOUBLE        SFloat / SFloat / DFloat, NaN for nulls
    #   integers with nulls             DFloat with NaN (exact up to 2^53)
    #   BOOLEAN                         Bit; RObject of true/false/nil with nulls
    #   list<number>, all rows of the   2-D [rows, length] of the element type
    #     same length and no nulls
    #   anything else                   RObject of the values as: :rows returns
    #
    # @api private
    module NumoColumns
      # Whether the host is little-endian, so PLAIN bytes (always little-endian) can be handed to
      # Numo's from_binary, which reads native byte order.
      LITTLE_ENDIAN = [1].pack("S") == [1].pack("v")
      # Shorthand for Format::Type.
      T = Format::Type

      # How a top-level field becomes a Numo array.
      #   kind:      :fixed (a numeric or boolean leaf), :list (list of numbers) or :object
      #   klass:     the Numo class of the result without nulls
      #   bin_klass: for :fixed leaves whose pages can be decoded straight into Numo, the class
      #              of the decoded values (same width as the physical type), else nil
      #   arrays:    whether values may be Arrays (list fields)
      Spec = Struct.new(:kind, :klass, :bin_klass, :arrays) do
        # @return [Boolean] whether pages can be decoded straight into Numo (via NumoCursor)
        def fast? = !bin_klass.nil?

        # @return [Boolean] whether the result class is a float type, which holds nulls as NaN in place
        def float? = klass == Numo::SFloat || klass == Numo::DFloat
      end

      module_function

      # @return [void]
      # @raise [UnsupportedError] if Numo is not loaded
      def load!
        return if loaded?
        raise UnsupportedError, "as: :numo needs the \"numo-narray-alt\" gem (or \"numo-narray\"), which " \
          "is not loaded. Add `gem \"numo-narray-alt\"` to your Gemfile and `require \"numo/narray\"` " \
          "to read columns into Numo arrays."
      end

      # A separate method so tests can stub it to simulate a missing gem.
      # @return [Boolean] whether "numo/narray" is loaded
      def loaded?
        defined?(::Numo::NArray) ? true : false
      end

      # Picks how +field+ is converted: a numeric or boolean leaf, a list of numbers with a single
      # repetition level, or anything else as RObject.
      # @param field [Schema::Field] top-level field of the read schema
      # @return [Spec] how to build the field's Numo array
      def spec_for(field)
        if field.leaf?
          klass, bin = leaf_classes(field.column)
          return Spec.new(:fixed, klass, bin) if klass
        elsif field.kind == :list && field.element.leaf? && field.element.column.max_repetition_level == 1
          klass, = leaf_classes(field.element.column)
          return Spec.new(:list, klass, nil) if klass && klass != Numo::Bit
        end
        Spec.new(:object, Numo::RObject, nil, field.kind == :list)
      end

      # [Numo class, class to decode pages into (nil: convert Ruby values)], or nil for columns
      # that become RObject
      # @param column [Schema::Column] leaf column
      # @return [Array(Class, Class), Array(Class, nil), nil] result class and page decode class, or nil
      def leaf_classes(column)
        kind, bits, signed = Types.logical_of(column.node)
        case column.type
        when T::BOOLEAN
          [Numo::Bit, Numo::Bit] if kind.nil?
        when T::INT32
          case kind
          when nil, :time then [Numo::Int32, Numo::Int32]
          when :integer
            if signed
              [{8 => Numo::Int8, 16 => Numo::Int16}.fetch(bits, Numo::Int32), Numo::Int32]
            else
              [{8 => Numo::UInt8, 16 => Numo::UInt16}.fetch(bits, Numo::UInt32), Numo::UInt32]
            end
          end
        when T::INT64
          case kind
          when nil, :time then [Numo::Int64, Numo::Int64]
          when :integer then signed ? [Numo::Int64, Numo::Int64] : [Numo::UInt64, Numo::UInt64]
          end
        when T::FLOAT then [Numo::SFloat, Numo::SFloat] if kind.nil?
        when T::DOUBLE then [Numo::DFloat, Numo::DFloat] if kind.nil?
        when T::FIXED_LEN_BYTE_ARRAY then [Numo::SFloat, nil] if kind == :float16
        end
      end

      # The result for a field read through Numo cursors: +parts+ are [values, validity] pairs
      # (validity is a Numo::Bit, or nil when every value is present)
      # Booleans with nulls become an RObject of true/false/nil, other types with nulls a float
      # array with NaN in the null slots.
      # @param spec [Spec] field spec from spec_for
      # @param parts [Array<Array(Numo::NArray, Numo::Bit)>] one [values, validity] pair per batch
      # @return [Numo::NArray] the whole column
      def finish_fixed(spec, parts)
        return spec.klass.new(0) if parts.empty?
        full = (parts.size == 1) ? parts[0][0] : Numo::NArray.concatenate(parts.map(&:first))
        valid = nil
        if parts.any? { |_, v| v }
          valid = (parts.size == 1) ? parts[0][1] : Numo::NArray.concatenate(parts.map { |f, v| v || Numo::Bit.ones(f.size) })
          valid = nil if valid.count_false.zero?
        end
        unless valid
          return full if full.instance_of?(spec.klass)
          return spec.klass.cast(full)
        end
        if spec.klass == Numo::Bit
          bits = full.to_a
          present = valid.to_a
          return robject(Array.new(bits.size) { |i| (present[i] == 1) ? bits[i] == 1 : nil })
        end
        out_class = spec.float? ? spec.klass : Numo::DFloat
        out = full.instance_of?(out_class) ? full.dup : out_class.cast(full) # never write into a view
        out[(~valid).where] = Float::NAN
        out
      end

      # The result for a field read as Ruby values (+parts+ are Arrays of values)
      # @param spec [Spec] field spec from spec_for
      # @param parts [Array<Array>] the field's values, one Array per batch
      # @return [Numo::NArray] the whole column
      def finish_values(spec, parts)
        values = (parts.size == 1) ? parts[0] : parts.flatten(1)
        case spec.kind
        when :object then robject(values, arrays: spec.arrays)
        when :list then list_array(spec.klass, values)
        else from_values(spec.klass, values)
        end
      end

      # A numeric / boolean leaf's Ruby values as a Numo array
      # @param klass [Class] Numo class for the column without nulls
      # @param values [Array<Numeric, Boolean, nil>] the column's values, nil for nulls
      # @return [Numo::NArray] +klass+ without nulls; SFloat/DFloat with NaN (or RObject for booleans) with nulls
      def from_values(klass, values)
        if values.include?(nil)
          return robject(values) if klass == Numo::Bit
          filled = values.map { |v| v.nil? ? Float::NAN : v }
          return ((klass == Numo::SFloat) ? Numo::SFloat : Numo::DFloat).cast(filled)
        end
        return klass.new(0) if values.empty?
        return Numo::Bit.cast(values.map { |v| v ? 1 : 0 }) if klass == Numo::Bit
        klass.cast(values)
      end

      # Lists of numbers: 2-D [rows, length] when every row is a list of the same, non-zero
      # length without nulls; otherwise an RObject of the Arrays
      # @param klass [Class] Numo class of the list elements
      # @param values [Array<Array<Numeric, nil>, nil>] one list (or nil) per row
      # @return [Numo::NArray] a 2-D +klass+ array or a 1-D Numo::RObject
      def list_array(klass, values)
        first = values.first
        width = first.is_a?(Array) ? first.size : 0
        if width.positive? && values.all? { |v| v.is_a?(Array) && v.size == width && !v.include?(nil) }
          return klass.cast(values)
        end
        robject(values, arrays: true)
      end

      # A 1-D Numo::RObject holding +values+ as they are. Only list columns hold Arrays, which
      # #store and .cast would turn into more dimensions.
      # @param values [Array] one Ruby value per row
      # @param arrays [Boolean] whether +values+ may contain Arrays that must stay single elements
      # @return [Numo::RObject] 1-D array of +values+
      def robject(values, arrays: false)
        return Numo::RObject.new(values.size).seq.map { |i| values[i] } if arrays
        out = Numo::RObject.new(values.size)
        out.store(values)
        out
      end

      # Numo vector of 1 << j for each bit j of +width+, memoized per Ractor; dotting a bit matrix
      # with it turns rows of bits into integers. Int64 above 30 bits so the sums cannot overflow.
      # @param width [Integer] bits per value
      # @return [Numo::Int32, Numo::Int64] the powers of two
      def powers(width)
        cache = Ractor.current[:herringbone_numo_powers] ||= {}
        cache[width] ||= ((width > 30) ? Numo::Int64 : Numo::Int32).cast(Array.new(width) { |j| 1 << j })
      end

      # +count+ bit-packed values of +width+ bits (LSB first) from +data+ at +pos+ as a Numo
      # array, without a Ruby object per value
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the first packed value
      # @param count [Integer] number of values, a multiple of 8
      # @param width [Integer] bits per value
      # @return [Numo::NArray] unsigned integer array of +count+ values (element type depends on +width+)
      def unpack_bits(data, pos, count, width)
        return Numo::Int32.zeros(count) if width.zero?
        nbytes = count * width / 8 # count is a multiple of 8
        bytes = data.byteslice(pos, nbytes) || "".b
        bytes += "\0" * (nbytes - bytes.bytesize) if bytes.bytesize < nbytes # truncated last run
        case width
        when 1 then return Numo::UInt8.cast(Numo::Bit.from_binary(bytes, [count]))
        when 8 then return Numo::UInt8.from_binary(bytes)
        when 16 then return Numo::UInt16.from_binary(bytes) if LITTLE_ENDIAN
        when 32 then return Numo::UInt32.from_binary(bytes) if LITTLE_ENDIAN
        end
        # Row i of the [count, width] bit matrix holds value i's bits, least significant first
        bits = Numo::Bit.from_binary(bytes, [count * width]).reshape(count, width)
        pow = powers(width)
        pow.class.cast(bits).dot(pow)
      end
    end

    # Hands out the next +k+ rows of a flat (non-repeated) numeric or boolean column as a
    # [Numo values, validity] pair: values has one slot per row (zero where the row is null),
    # validity is a Numo::Bit or nil when all rows are present.
    #
    # @api private
    class NumoCursor
      # @param chunk_reader [ColumnChunkReader] reader for the column's chunk in one row group
      # @param spec [NumoColumns::Spec] a :fixed spec with a bin_klass
      def initialize(chunk_reader, spec)
        @src = chunk_reader
        col = chunk_reader.column
        @path = col.dotted_path
        @max_def = col.max_definition_level
        @klass = spec.bin_klass
        @bytes = NumoColumns::LITTLE_ENDIAN && @klass != Numo::Bit
        @dictionaries = {}.compare_by_identity
        @page = nil
        @row = 0
        @page_idx = -1
      end

      # @return [Integer] index within the chunk of the next row #take returns
      attr_reader :row

      # Moves forward to row +target+ of the chunk, jumping over pages with the OffsetIndex
      # @param target [Integer] row index within the chunk, not before #row
      # @return [void]
      # @raise [ArgumentError] if +target+ is before the current row
      # @raise [FormatError] if the chunk runs out of pages
      def seek(target)
        raise ArgumentError, "Cannot seek backwards (at row #{@row}, asked for #{target})" if target < @row
        return if target == @row
        locs = @src.locations
        if locs
          j = locs.bsearch_index { |loc| loc.first_row_index > target }
          j = (j || locs.size) - 1
          if j > @page_idx
            @src.jump_to_page(j)
            @page = nil
            @page_idx = j - 1
            @row = locs[j].first_row_index
          end
        end
        k = target - @row
        while k > 0
          load_page! while @page.nil? || @page.remaining.zero?
          t = @page.remaining
          t = k if k < t
          defs, = @page.read_levels(t)
          @page.skip_values(defs ? defs.count(@max_def) : t)
          k -= t
        end
        @row = target
      end

      # Reads the next +k+ rows, crossing page boundaries as needed.
      # @param k [Integer] number of rows
      # @return [Array(Numo::NArray, Numo::Bit), Array(Numo::NArray, nil)] values (zero in null slots)
      #   and validity, nil when all +k+ rows are present
      # @raise [FormatError] if the chunk runs out of pages
      def take(k)
        parts = []
        nulls = false
        @row += k
        while k > 0
          load_page! while @page.nil? || @page.remaining.zero?
          t = @page.remaining
          t = k if k < t
          nv = t
          if (valid = @page.read_validity_numo(t, @max_def))
            nv = valid.count_true
          end
          dense = values(nv)
          if nv < t
            full = @klass.zeros(t)
            full[valid.where] = dense if nv.positive?
            nulls = true
          else
            full = dense
            valid = nil
          end
          parts << [full, valid]
          k -= t
        end
        return parts.first if parts.size == 1
        full = Numo::NArray.concatenate(parts.map(&:first))
        return [full, nil] unless nulls
        [full, Numo::NArray.concatenate(parts.map { |f, v| v || Numo::Bit.ones(f.size) })]
      end

      private

      # Decodes the current page's next +n+ non-null values into a +@klass+ array, by the cheapest
      # route the value decoder supports: raw bytes, dictionary indices, its own Numo decoding, or
      # Ruby values as a last resort.
      # @param n [Integer] number of non-null values
      # @return [Numo::NArray] +n+ values, never a view into a cached dictionary
      def values(n)
        return @klass.new(0) if n.zero?
        dec = @page.value_decoder
        if @bytes && dec.respond_to?(:read_bytes)
          @klass.from_binary(dec.read_bytes(n))
        elsif dec.is_a?(PageStream::DictionaryDecoder)
          dict = @dictionaries[dec.dictionary] ||= cast(dec.dictionary)
          dict[dec.read_indices_numo(n)].dup # a copy, not a view the caller could write through
        elsif dec.respond_to?(:read_numo)
          dec.read_numo(n)
        else
          vals = @page.read_values(n)
          conv = @page.converter
          cast(conv ? vals.map!(&conv) : vals)
        end
      end

      # @param values [Array<Numeric, Boolean>] decoded values, without nulls
      # @return [Numo::NArray] +values+ as a +@klass+ array (booleans as 0/1 bits)
      def cast(values)
        if @klass == Numo::Bit
          Numo::Bit.cast(values.map { |v| v ? 1 : 0 })
        else
          @klass.cast(values)
        end
      end

      # Advances to the chunk's next data page.
      # @return [void]
      # @raise [FormatError] if there are no more pages
      def load_page!
        @page = @src.next_stream
        @page_idx += 1
        return if @page
        raise FormatError, "Column #{@path}: ran out of pages after #{@src.seen} of #{@src.total} values"
      end
    end
  end
end
