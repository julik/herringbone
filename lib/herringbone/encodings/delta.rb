# frozen_string_literal: true

module Herringbone
  module Encodings
    # DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY
    module Delta
      module_function

      # Values per block written by the encoder (the size parquet-mr and Arrow use).
      BLOCK_SIZE = 128
      # Miniblocks per block written by the encoder, so 32 values per miniblock.
      MINIBLOCKS = 4

      # @param n [Integer] zigzag-encoded unsigned integer
      # @return [Integer] the signed integer it represents
      def zigzag_decode(n) = (n >> 1) ^ -(n & 1)

      # @param n [Integer] signed integer
      # @return [Integer] zigzag-encoded form (0, -1, 1, -2 map to 0, 1, 2, 3)
      def zigzag_encode(n) = n.negative? ? ((-n) << 1) - 1 : n << 1

      # Wraps an integer into the signed range of +bits+ bits
      # @param v [Integer] integer to wrap
      # @param bits [Integer] target width, 32 or 64
      # @return [Integer] +v+ modulo 2^bits, as a two's complement signed integer
      def wrap(v, bits)
        half = 1 << (bits - 1)
        ((v + half) & ((1 << bits) - 1)) - half
      end

      # Decodes DELTA_BINARY_PACKED integers. +bits+ is 32 or 64 (for wraparound).
      # Returns [values, new_pos]. If +count+ is nil, the total from the header is used. A smaller
      # +count+ decodes only that many values, but the returned offset is still the end of the
      # whole encoded block, so data following it can be read from there.
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the block header
      # @param bits [Integer] integer width that deltas wrap around in, 32 or 64
      # @param count [Integer, nil] maximum number of values to decode
      # @return [Array(Array<Integer>, Integer)] the decoded values and the offset just past the encoded block
      # @raise [FormatError] on an invalid header or miniblock bit width, or truncated data
      def decode_binary_packed(data, pos, bits = 64, count = nil)
        block_size, pos = RLE.read_uleb(data, pos)
        miniblocks, pos = RLE.read_uleb(data, pos)
        total, pos = RLE.read_uleb(data, pos)
        first, pos = RLE.read_uleb(data, pos)
        raise FormatError, "Invalid DELTA_BINARY_PACKED header" if miniblocks.zero? || block_size % miniblocks != 0
        per_mini = block_size / miniblocks
        raise FormatError, "Invalid miniblock size #{per_mini}" if per_mini % 8 != 0
        want = (count && count < total) ? count : total
        values = []
        return [values, pos] if total.zero?
        last = zigzag_decode(first)
        values << last if want.positive?
        half = 1 << (bits - 1)
        mask = (1 << bits) - 1
        left = total - 1 # deltas still encoded, decoded or skipped
        while left.positive?
          min_delta, pos = RLE.read_uleb(data, pos)
          min_delta = zigzag_decode(min_delta)
          widths = data.byteslice(pos, miniblocks).unpack("C*")
          pos += miniblocks
          widths.each do |w|
            # Miniblocks past the last value have a width byte but no body
            break unless left.positive?
            raise FormatError, "Invalid delta bit width #{w}" if w > bits
            if values.size < want
              deltas = RLE.unpack_bits(data, pos, per_mini, w)
              take = want - values.size
              deltas = deltas.first(take) if take < per_mini
              deltas.each do |d|
                last = ((last + min_delta + d + half) & mask) - half
                values << last
              end
            end
            pos += per_mini * w / 8
            left -= per_mini
          end
        end
        [values, pos]
      end

      # Encodes integers with DELTA_BINARY_PACKED, using BLOCK_SIZE values per block in MINIBLOCKS
      # miniblocks. Deltas wrap at +bits+ so INT32 columns never need more than 32-bit widths.
      # @param values [Array<Integer>] signed integers that fit in +bits+ bits
      # @param bits [Integer] physical integer width, 32 or 64
      # @return [String] encoded bytes in ASCII-8BIT
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

      # Decodes DELTA_LENGTH_BYTE_ARRAY: DELTA_BINARY_PACKED lengths followed by the concatenated bytes.
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the lengths block
      # @param count [Integer] number of values to decode
      # @return [Array(Array<String>, Integer)] binary slices of +data+ and the offset just past them
      # @raise [FormatError] if there are too few lengths or a value runs past the end of +data+
      def decode_length_byte_array(data, pos, count)
        lengths, pos = decode_binary_packed(data, pos, 32, count)
        raise FormatError, "DELTA_LENGTH_BYTE_ARRAY has #{lengths.size} lengths, need #{count}" if lengths.size < count
        out = Array.new(count)
        size = data.bytesize
        lengths.each_with_index do |len, i|
          raise FormatError, "DELTA_LENGTH_BYTE_ARRAY value overruns page" if len.negative? || pos + len > size
          out[i] = data.byteslice(pos, len)
          pos += len
        end
        [out, pos]
      end

      # Encodes byte strings with DELTA_LENGTH_BYTE_ARRAY.
      # @param values [Array<String>] byte strings, in any encoding
      # @return [String] encoded bytes in ASCII-8BIT
      def encode_length_byte_array(values)
        encode_binary_packed(values.map(&:bytesize), 32) << values.pack("a*" * values.size)
      end

      # Decodes DELTA_BYTE_ARRAY (incremental encoding): DELTA_BINARY_PACKED prefix lengths, then
      # the suffixes as DELTA_LENGTH_BYTE_ARRAY. Each value is the previous value's prefix plus its suffix.
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the prefix lengths block
      # @param count [Integer] number of values to decode
      # @return [Array(Array<String>, Integer)] binary values and the offset just past them
      # @raise [FormatError] if a prefix is negative or longer than the previous value, or the data is malformed
      def decode_byte_array(data, pos, count)
        prefixes, pos = decode_binary_packed(data, pos, 32, count)
        suffixes, pos = decode_length_byte_array(data, pos, count)
        prev = "".b
        out = Array.new(count) do |i|
          prefix = prefixes[i]
          raise FormatError, "DELTA_BYTE_ARRAY prefix length #{prefix} out of range" if prefix > prev.bytesize || prefix.negative?
          prev = prefix.zero? ? suffixes[i] : prev.byteslice(0, prefix) + suffixes[i]
        end
        [out, pos]
      end

      # Encodes byte strings with DELTA_BYTE_ARRAY, sharing the common byte prefix with the previous value.
      # @param values [Array<String>] byte strings, in any encoding
      # @return [String] encoded bytes in ASCII-8BIT
      def encode_byte_array(values)
        prev = "".b
        prefixes = []
        suffixes = []
        values.each do |v|
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
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the first stream
      # @param count [Integer] number of values
      # @param width [Integer] byte width of one value
      # @return [Array(String, Integer)] PLAIN-layout bytes and the offset just past the streams
      # @raise [FormatError] if fewer than count * width bytes remain
      def decode(data, pos, count, width)
        nbytes = count * width
        raise FormatError, "Truncated BYTE_STREAM_SPLIT data" if pos + nbytes > data.bytesize
        streams = Array.new(width) { |k| data.byteslice(pos + k * count, count).unpack("C*") }
        [streams[0].zip(*streams[1..]).flatten.pack("C*"), pos + nbytes]
      end

      # Splits PLAIN-layout fixed-width values into +width+ byte streams. Inverse of decode.
      # @param plain [String] PLAIN-encoded values, a multiple of +width+ bytes
      # @param width [Integer] byte width of one value
      # @return [String] the concatenated streams in ASCII-8BIT
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
