# frozen_string_literal: true

module Herringbone
  class Reader
    # Incremental decoders for the contents of one data page. The page bytes are decoded as they
    # are asked for, so a caller that takes a few hundred entries at a time never holds a whole
    # page's worth of levels or values as Ruby objects.
    module PageStream
      # Values unpacked from a bit-packed run at a time (a multiple of 8)
      CHUNK = 1024

      # The levels and values of one data page
      class Page
        attr_reader :remaining, :converter

        def initialize(entries, defs, reps, values, converter)
          @remaining = entries
          @defs = defs
          @reps = reps
          @values = values
          @converter = converter
        end

        # [definition_levels, repetition_levels] of the next +n+ entries (nil when a column has no
        # levels of that kind)
        def read_levels(n)
          n = @remaining if n > @remaining
          @remaining -= n
          [@defs&.read(n), @reps&.read(n)]
        end

        # The next +n+ values, as physical values (apply #converter for Ruby values)
        def read_values(n)
          n.zero? ? [] : @values.read(n)
        end
      end

      # A decoder over an Array that is already decoded (legacy encodings, booleans, deltas)
      class ArrayDecoder
        def initialize(values)
          @values = values
          @i = 0
        end

        def read(n)
          raise DecodeError, "Page has fewer values than its levels require" if @i + n > @values.size
          out = @values[@i, n]
          @i += n
          out
        end
      end

      # The RLE / bit-packed hybrid, decoded run by run
      class HybridDecoder
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

        def read(n)
          out = []
          while n > 0
            next_run if @left.zero?
            t = n < @left ? n : @left
            if @rle
              out.fill(@value, out.size, t)
            else
              if @buf.nil? || @bi >= @buf.size
                g = @groups < CHUNK / 8 ? @groups : CHUNK / 8
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

        private

        def next_run
          while @left.zero?
            raise DecodeError, "RLE data exhausted" if @pos >= @limit
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
        def initialize(data, pos, format, width)
          @data = data
          @pos = pos
          @format = format
          @width = width
        end

        def read(n)
          bytes = n * @width
          raise DecodeError, "Truncated PLAIN data" if @pos + bytes > @data.bytesize
          out = @data.byteslice(@pos, bytes).unpack("#{@format}#{n}")
          @pos += bytes
          out
        end
      end

      class Int96Decoder < FixedDecoder
        def initialize(data, pos)
          super(data, pos, "Q<L<", 12)
        end

        def read(n)
          bytes = n * 12
          raise DecodeError, "Truncated INT96 data" if @pos + bytes > @data.bytesize
          out = @data.byteslice(@pos, bytes).unpack("Q<L<" * n).each_slice(2).to_a
          @pos += bytes
          out
        end
      end

      # PLAIN FIXED_LEN_BYTE_ARRAY
      class FixedBytesDecoder
        def initialize(data, pos, width)
          @data = data
          @pos = pos
          @width = width
        end

        def read(n)
          raise DecodeError, "Truncated FIXED_LEN_BYTE_ARRAY data" if @pos + n * @width > @data.bytesize
          out = Array.new(n) { |i| @data.byteslice(@pos + i * @width, @width) }
          @pos += n * @width
          out
        end
      end

      # PLAIN BYTE_ARRAY: 4-byte length, then the bytes
      class ByteArrayDecoder
        def initialize(data, pos)
          @data = data
          @pos = pos
        end

        def read(n)
          data = @data
          size = data.bytesize
          pos = @pos
          out = Array.new(n)
          i = 0
          while i < n
            raise DecodeError, "Truncated BYTE_ARRAY data" if pos + 4 > size
            len = data.getbyte(pos) | (data.getbyte(pos + 1) << 8) | (data.getbyte(pos + 2) << 16) | (data.getbyte(pos + 3) << 24)
            pos += 4
            raise DecodeError, "BYTE_ARRAY value overruns page" if pos + len > size
            out[i] = data.byteslice(pos, len)
            pos += len
            i += 1
          end
          @pos = pos
          out
        end
      end

      # PLAIN BOOLEAN: one bit per value, LSB first
      class BooleanDecoder
        def initialize(data, pos)
          @bits = data.byteslice(pos, data.bytesize - pos).unpack1("b*")
          @i = 0
        end

        def read(n)
          raise DecodeError, "Truncated BOOLEAN data" if @i + n > @bits.bytesize
          out = Array.new(n) { |k| @bits.getbyte(@i + k) == 49 }
          @i += n
          out
        end
      end

      # RLE_DICTIONARY / PLAIN_DICTIONARY indices mapped to the (already converted) dictionary
      class DictionaryDecoder
        def initialize(data, pos, dictionary, path)
          @indices = HybridDecoder.new(data, pos + 1, data.bytesize, data.getbyte(pos).to_i)
          @dictionary = dictionary
          @path = path
        end

        def read(n)
          indices = @indices.read(n)
          dict = @dictionary
          raise FormatError, "Dictionary index out of range in #{@path}" if indices.max >= dict.size
          indices.map! { |i| dict[i] }
        end
      end

      # RLE-encoded BOOLEAN values
      class RleBooleanDecoder
        def initialize(data, pos)
          len = data.byteslice(pos, 4).unpack1("V")
          @bits = HybridDecoder.new(data, pos + 4, pos + 4 + len, 1)
        end

        def read(n)
          @bits.read(n).map! { |v| v == 1 }
        end
      end

      # DELTA_LENGTH_BYTE_ARRAY: all lengths first (Integers), then the bytes sliced as needed
      class DeltaLengthDecoder
        def initialize(data, pos)
          @lengths, @pos = Encodings::Delta.decode_binary_packed(data, pos, 32)
          @data = data
          @i = 0
        end

        def read(n)
          raise DecodeError, "DELTA_LENGTH_BYTE_ARRAY has too few values" if @i + n > @lengths.size
          data = @data
          out = Array.new(n) do |k|
            len = @lengths[@i + k]
            raise DecodeError, "DELTA_LENGTH_BYTE_ARRAY value overruns page" if len.negative? || @pos + len > data.bytesize
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
        def initialize(data, pos)
          @prefixes, pos = Encodings::Delta.decode_binary_packed(data, pos, 32)
          @suffixes = DeltaLengthDecoder.new(data, pos)
          @prev = "".b
          @i = 0
        end

        def read(n)
          raise DecodeError, "DELTA_BYTE_ARRAY has too few values" if @i + n > @prefixes.size
          suffixes = @suffixes.read(n)
          prev = @prev
          out = Array.new(n) do |k|
            prefix = @prefixes[@i + k]
            raise DecodeError, "DELTA_BYTE_ARRAY prefix longer than previous value" if prefix > prev.bytesize
            prev = prefix.zero? ? suffixes[k] : prev.byteslice(0, prefix) + suffixes[k]
          end
          @prev = prev
          @i += n
          out
        end
      end

      # BYTE_STREAM_SPLIT: byte k of every value lives in stream k; values are gathered per call
      class ByteStreamSplitDecoder
        def initialize(data, pos, width, type, type_length)
          @data = data
          @pos = pos
          @width = width
          @count = (data.bytesize - pos) / width
          @type = type
          @type_length = type_length
          @i = 0
        end

        def read(n)
          raise DecodeError, "Truncated BYTE_STREAM_SPLIT data" if @i + n > @count
          streams = Array.new(@width) { |k| @data.byteslice(@pos + k * @count + @i, n) }.join
          @i += n
          plain, = Encodings::ByteStreamSplit.decode(streams, 0, n, @width)
          Encodings::Plain.decode(plain, 0, n, @type, @type_length).first
        end
      end
    end
  end
end
