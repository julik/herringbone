# frozen_string_literal: true

module Herringbone
  module Encodings
    # Bit packing (LSB-first, as used by Parquet) and the RLE / bit-packed hybrid encoding
    # used for repetition/definition levels, dictionary indices and RLE booleans.
    module RLE
      module_function

      # Unpacks +count+ values of +width+ bits each, starting at byte +offset+ of +data+.
      # Missing trailing bytes are treated as zeroes.
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
        words = (pad.zero? ? chunk : chunk + ("\0" * pad)).unpack("V*")
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

      def write_uleb(out, n)
        while n >= 0x80
          out << ((n & 0x7F) | 0x80)
          n >>= 7
        end
        out << n
      end

      # Decodes the RLE/bit-packed hybrid from +data+ between +pos+ and +limit+,
      # returning exactly +count+ values (missing values are an error).
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

      def flush_literals(out, values, from, to, width)
        count = to - from
        groups = (count + 7) / 8
        write_uleb(out, (groups << 1) | 1)
        out << pack_bits(values[from, count], width)
      end

      def bit_width(max_value)
        max_value.to_i.bit_length
      end

      # Legacy BIT_PACKED level encoding (deprecated): MSB-first bit order, no header.
      def decode_legacy_bit_packed(data, pos, width, count)
        nbytes = (count * width + 7) / 8
        bits = data.byteslice(pos, nbytes).unpack1("B*")
        Array.new(count) { |i| bits[i * width, width].to_i(2) }
      end
    end
  end
end
