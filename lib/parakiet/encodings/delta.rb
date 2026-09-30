# frozen_string_literal: true

module Parakiet
  module Encodings
    # DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY
    module Delta
      module_function

      BLOCK_SIZE = 128
      MINIBLOCKS = 4

      def zigzag_decode(n) = (n >> 1) ^ -(n & 1)
      def zigzag_encode(n) = n.negative? ? ((-n) << 1) - 1 : n << 1

      # Wraps an integer into the signed range of +bits+ bits
      def wrap(v, bits)
        half = 1 << (bits - 1)
        ((v + half) & ((1 << bits) - 1)) - half
      end

      # Decodes DELTA_BINARY_PACKED integers. +bits+ is 32 or 64 (for wraparound).
      # Returns [values, new_pos]. If +count+ is nil, the total from the header is used.
      def decode_binary_packed(data, pos, bits = 64, count = nil)
        block_size, pos = RLE.read_uleb(data, pos)
        miniblocks, pos = RLE.read_uleb(data, pos)
        total, pos = RLE.read_uleb(data, pos)
        first, pos = RLE.read_uleb(data, pos)
        raise DecodeError, "Invalid DELTA_BINARY_PACKED header" if miniblocks.zero? || block_size % miniblocks != 0
        per_mini = block_size / miniblocks
        raise DecodeError, "Invalid miniblock size #{per_mini}" if per_mini % 8 != 0
        total = count if count && count < total
        values = []
        return [values, pos] if total.zero?
        last = zigzag_decode(first)
        values << last
        half = 1 << (bits - 1)
        mask = (1 << bits) - 1
        while values.size < total
          min_delta, pos = RLE.read_uleb(data, pos)
          min_delta = zigzag_decode(min_delta)
          widths = data.byteslice(pos, miniblocks).unpack("C*")
          pos += miniblocks
          widths.each do |w|
            break if values.size >= total
            raise DecodeError, "Invalid delta bit width #{w}" if w > bits
            deltas = RLE.unpack_bits(data, pos, per_mini, w)
            pos += per_mini * w / 8
            take = total - values.size
            deltas = deltas.first(take) if take < per_mini
            deltas.each do |d|
              last = ((last + min_delta + d + half) & mask) - half
              values << last
            end
          end
        end
        [values, pos]
      end

      def encode_binary_packed(values, bits = 64)
        out = String.new(encoding: Encoding::BINARY)
        per_mini = BLOCK_SIZE / MINIBLOCKS
        RLE.write_uleb(out, BLOCK_SIZE)
        RLE.write_uleb(out, MINIBLOCKS)
        RLE.write_uleb(out, values.size)
        RLE.write_uleb(out, zigzag_encode(values.empty? ? 0 : values[0]))
        return out if values.size <= 1

        mask = (1 << bits) - 1
        deltas = Array.new(values.size - 1) { |i| wrap(values[i + 1] - values[i], bits) }
        deltas.each_slice(BLOCK_SIZE) do |block|
          min = block.min
          RLE.write_uleb(out, zigzag_encode(min))
          adjusted = block.map { |d| (d - min) & mask }
          minis = adjusted.each_slice(per_mini).to_a
          widths = Array.new(MINIBLOCKS) { |m| minis[m] ? minis[m].max.bit_length : 0 }
          out << widths.pack("C*")
          minis.each_with_index do |mini, m|
            mini += Array.new(per_mini - mini.size, 0) if mini.size < per_mini
            out << RLE.pack_bits(mini, widths[m])
          end
        end
        out
      end

      def decode_length_byte_array(data, pos, count)
        lengths, pos = decode_binary_packed(data, pos, 32, count)
        raise DecodeError, "DELTA_LENGTH_BYTE_ARRAY has #{lengths.size} lengths, need #{count}" if lengths.size < count
        out = Array.new(count)
        size = data.bytesize
        lengths.each_with_index do |len, i|
          raise DecodeError, "DELTA_LENGTH_BYTE_ARRAY value overruns page" if len.negative? || pos + len > size
          out[i] = data.byteslice(pos, len)
          pos += len
        end
        [out, pos]
      end

      def encode_length_byte_array(values)
        out = encode_binary_packed(values.map(&:bytesize), 32)
        values.each { |v| out << v.b }
        out
      end

      def decode_byte_array(data, pos, count)
        prefixes, pos = decode_binary_packed(data, pos, 32, count)
        suffixes, pos = decode_length_byte_array(data, pos, count)
        prev = "".b
        out = Array.new(count) do |i|
          prefix = prefixes[i]
          raise DecodeError, "DELTA_BYTE_ARRAY prefix longer than previous value" if prefix > prev.bytesize
          prev = prefix.zero? ? suffixes[i] : prev.byteslice(0, prefix) + suffixes[i]
        end
        [out, pos]
      end

      def encode_byte_array(values)
        prev = "".b
        prefixes = []
        suffixes = []
        values.each do |v|
          v = v.b
          max = [prev.bytesize, v.bytesize].min
          n = 0
          n += 1 while n < max && prev.getbyte(n) == v.getbyte(n)
          prefixes << n
          suffixes << v.byteslice(n, v.bytesize - n)
          prev = v
        end
        encode_binary_packed(prefixes, 32) << encode_length_byte_array(suffixes)
      end
    end

    # BYTE_STREAM_SPLIT: byte k of every value is stored in stream k.
    module ByteStreamSplit
      module_function

      # Returns the value bytes re-interleaved into PLAIN layout
      def decode(data, pos, count, width)
        nbytes = count * width
        raise DecodeError, "Truncated BYTE_STREAM_SPLIT data" if pos + nbytes > data.bytesize
        streams = Array.new(width) { |k| data.byteslice(pos + k * count, count).unpack("C*") }
        [streams[0].zip(*streams[1..]).flatten.pack("C*"), pos + nbytes]
      end

      def encode(plain, width)
        count = plain.bytesize / width
        bytes = plain.unpack("C*")
        out = String.new(capacity: plain.bytesize, encoding: Encoding::BINARY)
        width.times do |k|
          out << Array.new(count) { |i| bytes[i * width + k] }.pack("C*")
        end
        out
      end
    end
  end
end
