# frozen_string_literal: true

module Herringbone
  # Decoders and encoders for the Parquet value and level encodings: PLAIN, the RLE / bit-packed
  # hybrid, the DELTA_* family and BYTE_STREAM_SPLIT. They work on binary Strings and byte offsets,
  # and know nothing about pages or columns.
  module Encodings
    # Bit packing (LSB-first, as used by Parquet) and the RLE / bit-packed hybrid encoding
    # used for repetition/definition levels, dictionary indices and RLE booleans.
    #
    # @api private
    module RLE
      module_function

      # Unpacks +count+ values of +width+ bits each, starting at byte +offset+ of +data+.
      # Missing trailing bytes are treated as zeroes.
      # @param data [String] binary input
      # @param offset [Integer] byte offset of the first packed value
      # @param count [Integer] number of values to unpack
      # @param width [Integer] bits per value, 0..64
      # @return [Array<Integer>] +count+ unsigned values
      def unpack_bits(data, offset, count, width)
        return Array.new(count, 0) if width.zero?
        nbytes = (count * width + 7) / 8
        chunk = data.byteslice(offset, nbytes) || "".b
        if width == 8
          vals = chunk.unpack("C*")
          vals.fill(0, vals.size, count - vals.size) if vals.size < count
          return vals
        end
        return unpack_wide(chunk, count, width) if width > 32

        # Pad to a whole number of 32-bit words plus one spare word, so reads never go out of range
        pad = (-chunk.bytesize % 4) + 4
        words = (chunk + ("\0" * pad)).unpack("V*")
        mask = (1 << width) - 1
        out = Array.new(count)
        bitpos = 0
        i = 0
        while i < count
          wi = bitpos >> 5
          off = bitpos & 31
          v = words[wi] >> off
          spill = off + width - 32
          v |= (words[wi + 1] & ((1 << spill) - 1)) << (32 - off) if spill.positive?
          out[i] = v & mask
          bitpos += width
          i += 1
        end
        out
      end

      # Slow path for widths above 32 bits (used by DELTA_BINARY_PACKED with 64-bit values)
      # @param chunk [String] packed bytes, starting at the first value
      # @param count [Integer] number of values to unpack
      # @param width [Integer] bits per value, 33..64
      # @return [Array<Integer>] +count+ unsigned values
      def unpack_wide(chunk, count, width)
        mask = (1 << width) - 1
        out = Array.new(count)
        group_bytes = width # 8 values * width bits = width bytes
        ngroups = (count + 7) / 8
        i = 0
        ngroups.times do |g|
          bytes = chunk.byteslice(g * group_bytes, group_bytes) || "".b
          bytes += "\0" * (group_bytes - bytes.bytesize) if bytes.bytesize < group_bytes
          big = bytes.reverse.unpack1("H*").to_i(16)
          8.times do |j|
            break if i >= count
            out[i] = (big >> (j * width)) & mask
            i += 1
          end
        end
        out
      end

      # Packs +values+ with +width+ bits each; the value count is padded up to a multiple of 8.
      # @param values [Array<Integer>] non-negative integers that fit in +width+ bits
      # @param width [Integer] bits per value
      # @return [String] packed bytes in ASCII-8BIT, +width+ bytes per group of 8 values
      def pack_bits(values, width)
        return "".b if width.zero? || values.empty?
        n = values.size
        padded = (n + 7) & ~7
        if width == 8
          s = values.pack("C*")
          s << ("\0" * (padded - n)) if padded > n
          return s
        end
        out = String.new(capacity: padded * width / 8, encoding: Encoding::BINARY)
        acc = 0
        nbits = 0
        i = 0
        while i < padded
          acc |= (values[i] || 0) << nbits
          nbits += width
          while nbits >= 32
            out << [acc & 0xFFFFFFFF].pack("V")
            acc >>= 32
            nbits -= 32
          end
          i += 1
        end
        # Remaining bits: padded*width is a multiple of 8, so nbits is a whole number of bytes
        while nbits.positive?
          out << (acc & 0xFF)
          acc >>= 8
          nbits -= 8
        end
        out
      end

      # Reads an unsigned LEB128 varint (hybrid run headers, DELTA_BINARY_PACKED headers).
      # @param data [String] binary input
      # @param pos [Integer] byte offset of the varint
      # @return [Array(Integer, Integer)] the decoded value and the offset just past it
      # @raise [FormatError] if the input ends inside the varint
      def read_uleb(data, pos)
        result = 0
        shift = 0
        while true
          b = data.getbyte(pos)
          raise FormatError, "Truncated varint" unless b
          pos += 1
          result |= (b & 0x7F) << shift
          return [result, pos] if b < 0x80
          shift += 7
        end
      end

      # Appends +n+ as an unsigned LEB128 varint.
      # @param out [String] binary output buffer, appended to
      # @param n [Integer] non-negative integer to encode
      # @return [String] +out+
      def write_uleb(out, n)
        while n >= 0x80
          out << ((n & 0x7F) | 0x80)
          n >>= 7
        end
        out << n
      end

      # Decodes the RLE/bit-packed hybrid from +data+ between +pos+ and +limit+,
      # returning exactly +count+ values (missing values are an error).
      # @param data [String] binary input
      # @param pos [Integer] byte offset of the first run header
      # @param limit [Integer] byte offset just past the encoded data
      # @param width [Integer] bits per value
      # @param count [Integer] number of values to decode
      # @return [Array<Integer>] exactly +count+ values
      # @raise [FormatError] if the runs end before +count+ values were produced
      def decode_hybrid(data, pos, limit, width, count)
        out = []
        value_bytes = (width + 7) / 8
        while out.size < count
          raise FormatError, "RLE data exhausted (#{out.size}/#{count} values)" if pos >= limit
          header, pos = read_uleb(data, pos)
          if header & 1 == 1
            groups = header >> 1
            n = groups * 8
            vals = unpack_bits(data, pos, n, width)
            pos += groups * width
            remaining = count - out.size
            vals = vals.first(remaining) if vals.size > remaining
            out.concat(vals)
          else
            run = header >> 1
            v = 0
            value_bytes.times { |k| v |= data.getbyte(pos + k).to_i << (8 * k) }
            pos += value_bytes
            remaining = count - out.size
            run = remaining if run > remaining
            out.fill(v, out.size, run)
          end
        end
        out
      end

      # Encodes +values+ with the RLE/bit-packed hybrid. Repeated runs of 8+ equal values
      # become RLE runs, everything else goes into bit-packed groups of 8.
      # Output has no length prefix; callers that need one (levels in data page v1) add it.
      # @param values [Array<Integer>] non-negative integers that fit in +width+ bits
      # @param width [Integer] bits per value
      # @return [String] encoded runs in ASCII-8BIT
      def encode_hybrid(values, width)
        out = String.new(encoding: Encoding::BINARY)
        n = values.size
        value_bytes = (width + 7) / 8
        return out if n.zero?
        min, max = values.minmax
        if min == max
          # A single run, the common case for levels of columns without nulls
          write_uleb(out, n << 1)
          value_bytes.times { |k| out << ((min >> (8 * k)) & 0xFF) }
          return out
        end
        literal_start = nil
        i = 0
        while i < n
          v = values[i]
          # Measure how long the run of v starting at i is
          j = i + 1
          j += 1 while j < n && values[j] == v
          run = j - i
          if run >= 8 && (literal_start.nil? || (i - literal_start) % 8 == 0)
            flush_literals(out, values, literal_start, i, width) if literal_start
            literal_start = nil
            write_uleb(out, run << 1)
            value_bytes.times { |k| out << ((v >> (8 * k)) & 0xFF) }
            i = j
          else
            literal_start ||= i
            # Consume values so that the literal count stays aligned to groups of 8 where possible
            i += 1
          end
        end
        flush_literals(out, values, literal_start, n, width) if literal_start
        out
      end

      # Appends values[from...to] as one bit-packed run, zero-padded to whole groups of 8.
      # @param out [String] binary output buffer, appended to
      # @param values [Array<Integer>] all values being encoded
      # @param from [Integer] index of the first literal value
      # @param to [Integer] index just past the last literal value
      # @param width [Integer] bits per value
      # @return [String] +out+
      def flush_literals(out, values, from, to, width)
        count = to - from
        groups = (count + 7) / 8
        write_uleb(out, (groups << 1) | 1)
        out << pack_bits(values[from, count], width)
      end

      # Number of bits needed to store values up to +max_value+ (0 for 0).
      # @param max_value [Integer, nil] largest value to encode; nil counts as 0
      # @return [Integer] bit width
      def bit_width(max_value)
        max_value.to_i.bit_length
      end

      # Legacy BIT_PACKED level encoding (deprecated): MSB-first bit order, no header.
      # @param data [String] binary input
      # @param pos [Integer] byte offset of the packed levels
      # @param width [Integer] bits per value
      # @param count [Integer] number of values to decode
      # @return [Array<Integer>] +count+ levels
      # @raise [FormatError] if +data+ ends before +count+ levels
      def decode_legacy_bit_packed(data, pos, width, count)
        nbytes = (count * width + 7) / 8
        raise FormatError, "Truncated BIT_PACKED levels" if pos + nbytes > data.bytesize
        bits = data.byteslice(pos, nbytes).unpack1("B*")
        Array.new(count) { |i| bits[i * width, width].to_i(2) }
      end
    end
  end
end
