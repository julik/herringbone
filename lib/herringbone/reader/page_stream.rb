# frozen_string_literal: true

module Herringbone
  class Reader
    # Incremental decoders for the contents of one data page. The page bytes are decoded as they
    # are asked for, so a caller that takes a few hundred entries at a time never holds a whole
    # page's worth of levels or values as Ruby objects.
    #
    # @api private
    module PageStream
      # Values unpacked from a bit-packed run at a time (a multiple of 8)
      CHUNK = 1024

      # The levels and values of one data page
      class Page
        # @return [Integer] entries (levels) of the page not read yet
        attr_reader :remaining

        # @return [Proc, nil] physical value => Ruby value, still to be applied to #read_values
        attr_reader :converter

        # @param entries [Integer] number of entries (num_values of the page header, nulls included)
        # @param defs [HybridDecoder, ArrayDecoder, nil] definition levels; nil when max level is 0
        # @param reps [HybridDecoder, ArrayDecoder, nil] repetition levels; nil when max level is 0
        # @param values [Object] value decoder responding to #read(n) (one of the decoders here)
        # @param converter [Proc, nil] converter for the decoded values, nil when none is needed
        def initialize(entries, defs, reps, values, converter)
          @remaining = entries
          @defs = defs
          @reps = reps
          @values = values
          @converter = converter
        end

        # [definition_levels, repetition_levels] of the next +n+ entries (nil when a column has no
        # levels of that kind)
        #
        # @param n [Integer] entries wanted; capped at #remaining
        # @return [Array(Array<Integer>, Array<Integer>)] definition and repetition levels
        def read_levels(n)
          n = @remaining if n > @remaining
          @remaining -= n
          [@defs&.read(n), @reps&.read(n)]
        end

        # The next +n+ values, as physical values (apply #converter for Ruby values)
        #
        # @param n [Integer] number of non-null values
        # @return [Array] decoded values
        # @raise [FormatError] when the page holds fewer values
        def read_values(n)
          n.zero? ? [] : @values.read(n)
        end

        # Moves past the next +n+ values without returning them
        #
        # @param n [Integer] number of non-null values
        # @return [void]
        # @raise [FormatError] when the page holds fewer values
        def skip_values(n)
          return if n.zero?
          @values.respond_to?(:skip) ? @values.skip(n) : @values.read(n)
        end

        # The value decoder (for read(as: :numo), which asks it for bytes or Numo arrays)
        #
        # @return [Object] one of the decoders in PageStream
        def value_decoder = @values

        # Which of the next +n+ entries are defined (definition level == +max_def+), as a
        # Numo::Bit, or nil when the column has no definition levels. For columns without
        # repetition levels; used by read(as: :numo).
        #
        # @param n [Integer] entries wanted; capped at #remaining
        # @param max_def [Integer] the column's max definition level
        # @return [Numo::Bit, nil] 1 where the entry holds a value
        def read_validity_numo(n, max_def)
          n = @remaining if n > @remaining
          @remaining -= n
          defs = @defs or return nil
          return defs.read_flags(n) if max_def == 1 && defs.respond_to?(:read_flags)
          levels = defs.respond_to?(:read_numo) ? defs.read_numo(n, Numo::UInt8) : Numo::UInt8.cast(defs.read(n))
          levels.eq(max_def)
        end
      end

      # A decoder over an Array that is already decoded (legacy encodings, booleans, deltas)
      class ArrayDecoder
        # @param values [Array] all of the page's decoded levels or values
        def initialize(values)
          @values = values
          @i = 0
        end

        # @param n [Integer] number of entries to hand out
        # @return [Array] the next +n+ entries
        # @raise [FormatError] when fewer than +n+ are left
        def read(n)
          raise FormatError, "Page has fewer values than its levels require" if @i + n > @values.size
          out = @values[@i, n]
          @i += n
          out
        end
      end

      # The RLE / bit-packed hybrid, decoded run by run
      class HybridDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first run header
        # @param limit [Integer] offset just past the encoded runs
        # @param width [Integer] bit width of each value
        def initialize(data, pos, limit, width)
          @data = data
          @pos = pos
          @limit = limit
          @width = width
          @value_bytes = (width + 7) / 8
          @left = 0 # values left in the current run
          @rle = true
          @value = 0
          @buf = nil
          @bi = 0
          @groups = 0 # bit-packed groups of 8 not unpacked yet
        end

        # Bit-packed runs are unpacked up to CHUNK values at a time
        #
        # @param n [Integer] number of values to decode
        # @return [Array<Integer>] the next +n+ values
        # @raise [FormatError] when the runs end before +n+ values
        def read(n)
          out = []
          while n > 0
            next_run if @left.zero?
            t = (n < @left) ? n : @left
            if @rle
              out.fill(@value, out.size, t)
            else
              if @buf.nil? || @bi >= @buf.size
                g = (@groups < CHUNK / 8) ? @groups : CHUNK / 8
                @buf = Encodings::RLE.unpack_bits(@data, @pos, g * 8, @width)
                @pos += g * @width
                @groups -= g
                @bi = 0
              end
              avail = @buf.size - @bi
              t = avail if t > avail
              out.concat(@buf[@bi, t])
              @bi += t
            end
            @left -= t
            n -= t
          end
          out
        end

        # For a bit width of 1: the next +n+ values as a Numo::Bit (read(as: :numo)). Runs are
        # collected as "0"/"1" characters, which costs less per run than Numo calls do (levels of
        # columns with scattered nulls come in many short runs).
        #
        # @param n [Integer] number of values to decode
        # @return [Numo::Bit] the next +n+ values
        # @raise [ArgumentError] when the bit width is not 1
        # @raise [FormatError] when the runs end before +n+ values
        def read_flags(n)
          raise ArgumentError, "read_flags needs a bit width of 1" unless @width == 1
          out = String.new(capacity: n, encoding: Encoding::BINARY)
          while n > 0
            next_run if @left.zero?
            t = (n < @left) ? n : @left
            if @rle
              out << ((@value == 1) ? "1" : "0") * t
            elsif @buf && @bi < @buf.size
              avail = @buf.size - @bi
              t = avail if t > avail
              out << @buf[@bi, t].join
              @bi += t
            else
              groups = (t + 7) / 8
              bits = @data.byteslice(@pos, groups)&.unpack1("b*") || +""
              bits << "0" * (groups * 8 - bits.bytesize) if bits.bytesize < groups * 8 # truncated last run
              @pos += groups
              @groups -= groups
              if groups * 8 > t
                out << bits.byteslice(0, t)
                @buf = bits.byteslice(t, groups * 8 - t).bytes.map! { |c| c - 48 }
              else
                out << bits
                @buf = nil
              end
              @bi = 0
            end
            @left -= t
            n -= t
          end
          Numo::UInt8.from_binary(out).eq(49)
        end

        # The next +n+ values as a Numo array of +klass+ (read(as: :numo)): RLE runs are
        # filled and bit-packed runs unpacked by Numo, with no Ruby object per value. Leaves the
        # decoder in a state #read can continue from.
        #
        # @param n [Integer] number of values to decode
        # @param klass [Class] Numo integer class to fill, e.g. Numo::UInt8 or Numo::Int32
        # @return [Numo::NArray] the next +n+ values as a +klass+ array
        # @raise [FormatError] when the runs end before +n+ values
        def read_numo(n, klass)
          out = klass.zeros(n)
          i = 0
          while n > 0
            next_run if @left.zero?
            t = (n < @left) ? n : @left
            if @rle
              out[i...i + t] = @value
            elsif @buf && @bi < @buf.size
              # Values of this run that #read (or a previous call) already unpacked
              avail = @buf.size - @bi
              t = avail if t > avail
              out[i...i + t] = @buf[@bi, t]
              @bi += t
            else
              groups = (t + 7) / 8 # @left == @groups * 8 here, so these groups exist
              vals = NumoColumns.unpack_bits(@data, @pos, groups * 8, @width)
              @pos += groups * @width
              @groups -= groups
              # A partly used group goes to the buffer #read and this method take values from
              @buf = (groups * 8 > t) ? vals[t..].to_a : nil
              @bi = 0
              out[i...i + t] = (groups * 8 > t) ? vals[0...t] : vals
            end
            @left -= t
            n -= t
            i += t
          end
          out
        end

        private

        # Reads run headers until a non-empty run starts: an RLE run (count and one value) or
        # a bit-packed run (groups of 8 values)
        #
        # @return [void]
        # @raise [FormatError] when there are no more runs before +limit+
        def next_run
          while @left.zero?
            raise FormatError, "RLE data exhausted" if @pos >= @limit
            header, @pos = Encodings::RLE.read_uleb(@data, @pos)
            if header & 1 == 1
              @rle = false
              @groups = header >> 1
              @left = @groups * 8
              @buf = nil
            else
              @rle = true
              @left = header >> 1
              v = 0
              @value_bytes.times { |k| v |= @data.getbyte(@pos + k).to_i << (8 * k) }
              @value = v
              @pos += @value_bytes
            end
          end
        end
      end

      # PLAIN INT32 / INT64 / FLOAT / DOUBLE / INT96
      class FixedDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first value
        # @param format [String] String#unpack directive of one value, e.g. "l<"
        # @param width [Integer] bytes per value
        def initialize(data, pos, format, width)
          @data = data
          @pos = pos
          @format = format
          @width = width
        end

        # @param n [Integer] number of values to decode
        # @return [Array<Integer>, Array<Float>] the next +n+ values
        # @raise [FormatError] when the page holds fewer values
        def read(n)
          bytes = n * @width
          raise FormatError, "Truncated PLAIN data" if @pos + bytes > @data.bytesize
          out = @data.byteslice(@pos, bytes).unpack("#{@format}#{n}")
          @pos += bytes
          out
        end

        # @param n [Integer] number of values to move past
        # @return [void]
        # @raise [FormatError] when the page holds fewer values
        def skip(n)
          raise FormatError, "Truncated PLAIN data" if @pos + n * @width > @data.bytesize
          @pos += n * @width
        end

        # The next +n+ values as their PLAIN (little-endian) bytes, for read(as: :numo)
        #
        # @param n [Integer] number of values
        # @return [String] +n+ * width bytes
        # @raise [FormatError] when the page holds fewer values
        def read_bytes(n)
          bytes = n * @width
          raise FormatError, "Truncated PLAIN data" if @pos + bytes > @data.bytesize
          out = @data.byteslice(@pos, bytes)
          @pos += bytes
          out
        end
      end

      # PLAIN INT96 (legacy Impala/Spark timestamps): 8 bytes of nanoseconds, 4 of Julian day
      class Int96Decoder < FixedDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first value
        def initialize(data, pos)
          super(data, pos, "Q<L<", 12)
        end

        # @param n [Integer] number of values to decode
        # @return [Array<Array(Integer, Integer)>] [nanoseconds of the day, Julian day] per value
        # @raise [FormatError] when the page holds fewer values
        def read(n)
          bytes = n * 12
          raise FormatError, "Truncated INT96 data" if @pos + bytes > @data.bytesize
          out = @data.byteslice(@pos, bytes).unpack("Q<L<" * n).each_slice(2).to_a
          @pos += bytes
          out
        end
      end

      # PLAIN FIXED_LEN_BYTE_ARRAY
      class FixedBytesDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first value
        # @param width [Integer] the column's type_length
        def initialize(data, pos, width)
          @data = data
          @pos = pos
          @width = width
        end

        # @param n [Integer] number of values to decode
        # @return [Array<String>] the next +n+ values as binary Strings
        # @raise [FormatError] when the page holds fewer values
        def read(n)
          raise FormatError, "Truncated FIXED_LEN_BYTE_ARRAY data" if @pos + n * @width > @data.bytesize
          out = Array.new(n) { |i| @data.byteslice(@pos + i * @width, @width) }
          @pos += n * @width
          out
        end

        # @param n [Integer] number of values to move past
        # @return [void]
        # @raise [FormatError] when the page holds fewer values
        def skip(n)
          raise FormatError, "Truncated FIXED_LEN_BYTE_ARRAY data" if @pos + n * @width > @data.bytesize
          @pos += n * @width
        end
      end

      # PLAIN BYTE_ARRAY: 4-byte length, then the bytes
      class ByteArrayDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first length prefix
        def initialize(data, pos)
          @data = data
          @pos = pos
        end

        # @param n [Integer] number of values to decode
        # @return [Array<String>] the next +n+ values as binary Strings
        # @raise [FormatError] when a length prefix or value runs past the page
        def read(n)
          data = @data
          size = data.bytesize
          pos = @pos
          out = Array.new(n)
          i = 0
          while i < n
            raise FormatError, "Truncated BYTE_ARRAY data" if pos + 4 > size
            len = data.getbyte(pos) | (data.getbyte(pos + 1) << 8) | (data.getbyte(pos + 2) << 16) | (data.getbyte(pos + 3) << 24)
            pos += 4
            raise FormatError, "BYTE_ARRAY value overruns page" if pos + len > size
            out[i] = data.byteslice(pos, len)
            pos += len
            i += 1
          end
          @pos = pos
          out
        end

        # Walks the length prefixes without creating Strings
        #
        # @param n [Integer] number of values to move past
        # @return [void]
        # @raise [FormatError] when a length prefix or value runs past the page
        def skip(n)
          data = @data
          size = data.bytesize
          pos = @pos
          n.times do
            raise FormatError, "Truncated BYTE_ARRAY data" if pos + 4 > size
            pos += 4 + (data.getbyte(pos) | (data.getbyte(pos + 1) << 8) | (data.getbyte(pos + 2) << 16) | (data.getbyte(pos + 3) << 24))
          end
          raise FormatError, "BYTE_ARRAY value overruns page" if pos > size
          @pos = pos
        end
      end

      # PLAIN BOOLEAN: one bit per value, LSB first
      class BooleanDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the first value; the rest of +data+ is unpacked at once
        def initialize(data, pos)
          @bits = data.byteslice(pos, data.bytesize - pos).unpack1("b*")
          @i = 0
        end

        # @param n [Integer] number of values to decode
        # @return [Array<Boolean>] the next +n+ values
        # @raise [FormatError] when the page holds fewer values
        def read(n)
          raise FormatError, "Truncated BOOLEAN data" if @i + n > @bits.bytesize
          out = Array.new(n) { |k| @bits.getbyte(@i + k) == 49 }
          @i += n
          out
        end

        # The next +n+ values as a Numo::Bit (read(as: :numo))
        #
        # @param n [Integer] number of values to decode
        # @return [Numo::Bit] 1 for true
        # @raise [FormatError] when the page holds fewer values
        def read_numo(n)
          raise FormatError, "Truncated BOOLEAN data" if @i + n > @bits.bytesize
          out = Numo::UInt8.from_binary(@bits.byteslice(@i, n)).eq(49) # "0"/"1" characters
          @i += n
          out
        end
      end

      # RLE_DICTIONARY / PLAIN_DICTIONARY indices mapped to the (already converted) dictionary
      class DictionaryDecoder
        # @return [Array] the chunk's dictionary values (converted, shared by all its pages)
        attr_reader :dictionary

        # @param data [String] binary page data
        # @param pos [Integer] offset of the bit width byte that precedes the RLE/bit-packed indices
        # @param dictionary [Array] values the indices point into, already converted
        # @param path [String] dotted column path, for error messages
        def initialize(data, pos, dictionary, path)
          @indices = HybridDecoder.new(data, pos + 1, data.bytesize, data.getbyte(pos).to_i)
          @dictionary = dictionary
          @path = path
        end

        # Indices are decoded but not looked up
        #
        # @param n [Integer] number of values to move past
        # @return [void]
        # @raise [FormatError] when the indices run out
        def skip(n)
          @indices.read(n)
        end

        # @param n [Integer] number of values to decode; must be positive
        # @return [Array] the dictionary values at the next +n+ indices
        # @raise [FormatError] when an index is out of range or the indices run out
        def read(n)
          indices = @indices.read(n)
          dict = @dictionary
          raise FormatError, "Dictionary index out of range in #{@path}" if indices.max >= dict.size
          indices.map! { |i| dict[i] }
        end

        # The next +n+ indices as a Numo::Int32, bounds-checked (read(as: :numo))
        #
        # @param n [Integer] number of indices to decode
        # @return [Numo::Int32] indices into #dictionary
        # @raise [FormatError] when an index is out of range or the indices run out
        def read_indices_numo(n)
          indices = @indices.read_numo(n, Numo::Int32)
          raise FormatError, "Dictionary index out of range in #{@path}" if n.positive? && indices.max >= @dictionary.size
          indices
        end
      end

      # RLE-encoded BOOLEAN values
      class RleBooleanDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the 4-byte length prefix of the RLE data
        def initialize(data, pos)
          len = data.byteslice(pos, 4).unpack1("V")
          @bits = HybridDecoder.new(data, pos + 4, pos + 4 + len, 1)
        end

        # @param n [Integer] number of values to decode
        # @return [Array<Boolean>] the next +n+ values
        # @raise [FormatError] when the runs end before +n+ values
        def read(n)
          @bits.read(n).map! { |v| v == 1 }
        end

        # The next +n+ values as a Numo::Bit (read(as: :numo))
        #
        # @param n [Integer] number of values to decode
        # @return [Numo::Bit] 1 for true
        # @raise [FormatError] when the runs end before +n+ values
        def read_numo(n)
          @bits.read_flags(n)
        end
      end

      # DELTA_LENGTH_BYTE_ARRAY: all lengths first (Integers), then the bytes sliced as needed
      class DeltaLengthDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the DELTA_BINARY_PACKED lengths
        # @raise [FormatError] when the lengths are malformed
        def initialize(data, pos)
          @lengths, @pos = Encodings::Delta.decode_binary_packed(data, pos, 32)
          @data = data
          @i = 0
        end

        # @param n [Integer] number of values to decode
        # @return [Array<String>] the next +n+ values as binary Strings
        # @raise [FormatError] when there are too few lengths or a value runs past the page
        def read(n)
          raise FormatError, "DELTA_LENGTH_BYTE_ARRAY has too few values" if @i + n > @lengths.size
          data = @data
          out = Array.new(n) do |k|
            len = @lengths[@i + k]
            raise FormatError, "DELTA_LENGTH_BYTE_ARRAY value overruns page" if len.negative? || @pos + len > data.bytesize
            s = data.byteslice(@pos, len)
            @pos += len
            s
          end
          @i += n
          out
        end
      end

      # DELTA_BYTE_ARRAY: prefix lengths and suffixes, each value built from the previous one
      class DeltaByteArrayDecoder
        # @param data [String] binary page data
        # @param pos [Integer] offset of the DELTA_BINARY_PACKED prefix lengths
        # @raise [FormatError] when the prefix or suffix lengths are malformed
        def initialize(data, pos)
          @prefixes, pos = Encodings::Delta.decode_binary_packed(data, pos, 32)
          @suffixes = DeltaLengthDecoder.new(data, pos)
          @prev = "".b
          @i = 0
        end

        # @param n [Integer] number of values to decode
        # @return [Array<String>] the next +n+ values as binary Strings
        # @raise [FormatError] when there are too few values or a prefix is negative or longer than
        #   the previous value
        def read(n)
          raise FormatError, "DELTA_BYTE_ARRAY has too few values" if @i + n > @prefixes.size
          suffixes = @suffixes.read(n)
          prev = @prev
          out = Array.new(n) do |k|
            prefix = @prefixes[@i + k]
            raise FormatError, "DELTA_BYTE_ARRAY prefix length #{prefix} out of range" if prefix > prev.bytesize || prefix.negative?
            prev = prefix.zero? ? suffixes[k] : prev.byteslice(0, prefix) + suffixes[k]
          end
          @prev = prev
          @i += n
          out
        end
      end

      # BYTE_STREAM_SPLIT: byte k of every value lives in stream k; values are gathered per call
      class ByteStreamSplitDecoder
        # @param data [String] binary page data; the streams run to its end
        # @param pos [Integer] offset of the first stream
        # @param width [Integer] bytes per value (and number of streams)
        # @param type [Integer] Format::Type of the column
        # @param type_length [Integer, nil] value size in bytes for FIXED_LEN_BYTE_ARRAY, else unused
        def initialize(data, pos, width, type, type_length)
          @data = data
          @pos = pos
          @width = width
          @count = (data.bytesize - pos) / width
          @type = type
          @type_length = type_length
          @i = 0
        end

        # @param n [Integer] number of values to decode
        # @return [Array<Integer>, Array<Float>, Array<String>] the next +n+ values, decoded as PLAIN
        # @raise [FormatError] when the streams hold fewer values
        def read(n)
          raise FormatError, "Truncated BYTE_STREAM_SPLIT data" if @i + n > @count
          streams = Array.new(@width) { |k| @data.byteslice(@pos + k * @count + @i, n) }.join
          @i += n
          plain, = Encodings::ByteStreamSplit.decode(streams, 0, n, @width)
          Encodings::Plain.decode(plain, 0, n, @type, @type_length).first
        end

        # The next +n+ values re-interleaved into PLAIN bytes by Numo (read(as: :numo))
        #
        # @param n [Integer] number of values
        # @return [String] +n+ * width bytes in PLAIN layout
        # @raise [FormatError] when the streams hold fewer values
        def read_bytes(n)
          raise FormatError, "Truncated BYTE_STREAM_SPLIT data" if @i + n > @count
          streams = Array.new(@width) { |k| @data.byteslice(@pos + k * @count + @i, n) }.join
          @i += n
          Numo::UInt8.from_binary(streams, [@width, n]).transpose.to_binary.b
        end
      end
    end
  end
end
