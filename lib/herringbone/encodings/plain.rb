# frozen_string_literal: true

module Herringbone
  module Encodings
    # PLAIN encoding for all physical types. Values are returned in their physical
    # Ruby form (Integer, Float, true/false, binary String); logical conversion happens elsewhere.
    module Plain
      module_function

      # Fixed-width numeric types: pack/unpack directive and byte width (all little-endian).
      FORMATS = Ractor.make_shareable({
        Format::Type::INT32 => ["l<", 4],
        Format::Type::INT64 => ["q<", 8],
        Format::Type::FLOAT => ["e", 4],
        Format::Type::DOUBLE => ["E", 8]
      })

      # Decodes +count+ values of +type+ from +data+ starting at +pos+.
      # Returns [values, new_pos].
      # INT96 values come back as [nanoseconds_of_day, julian_day] pairs.
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the first value
      # @param count [Integer] number of values to decode
      # @param type [Integer] physical type, a Format::Type constant
      # @param type_length [Integer, nil] byte width, required for FIXED_LEN_BYTE_ARRAY
      # @return [Array(Array, Integer)] the decoded values and the offset just past them
      # @raise [FormatError] if the data is truncated or the type is unknown
      def decode(data, pos, count, type, type_length = nil)
        case type
        when Format::Type::BOOLEAN
          nbytes = (count + 7) / 8
          bits = data.byteslice(pos, nbytes).unpack1("b*")
          raise FormatError, "Truncated BOOLEAN data" if bits.bytesize < count
          [Array.new(count) { |i| bits.getbyte(i) == 49 }, pos + nbytes]
        when Format::Type::INT32, Format::Type::INT64, Format::Type::FLOAT, Format::Type::DOUBLE
          fmt, width = FORMATS[type]
          nbytes = count * width
          raise FormatError, "Truncated PLAIN data" if pos + nbytes > data.bytesize
          [data.byteslice(pos, nbytes).unpack("#{fmt}#{count}"), pos + nbytes]
        when Format::Type::INT96
          nbytes = count * 12
          raise FormatError, "Truncated INT96 data" if pos + nbytes > data.bytesize
          vals = data.byteslice(pos, nbytes).unpack("Q<L<" * count).each_slice(2).map { |nanos, day| [nanos, day] }
          [vals, pos + nbytes]
        when Format::Type::BYTE_ARRAY
          decode_byte_arrays(data, pos, count)
        when Format::Type::FIXED_LEN_BYTE_ARRAY
          nbytes = count * type_length
          raise FormatError, "Truncated FIXED_LEN_BYTE_ARRAY data" if pos + nbytes > data.bytesize
          [Array.new(count) { |i| data.byteslice(pos + i * type_length, type_length) }, pos + nbytes]
        else
          raise FormatError, "Unknown physical type #{type}"
        end
      end

      # Decodes PLAIN BYTE_ARRAY values: each is a 4-byte little-endian length followed by the bytes.
      # @param data [String] binary page data
      # @param pos [Integer] byte offset of the first length prefix
      # @param count [Integer] number of values to decode
      # @return [Array(Array<String>, Integer)] binary slices of +data+ and the offset just past them
      # @raise [FormatError] if a length prefix or value runs past the end of +data+
      def decode_byte_arrays(data, pos, count)
        out = Array.new(count)
        size = data.bytesize
        i = 0
        while i < count
          raise FormatError, "Truncated BYTE_ARRAY data" if pos + 4 > size
          len = data.getbyte(pos) | (data.getbyte(pos + 1) << 8) | (data.getbyte(pos + 2) << 16) | (data.getbyte(pos + 3) << 24)
          pos += 4
          raise FormatError, "BYTE_ARRAY value overruns page" if pos + len > size
          out[i] = data.byteslice(pos, len)
          pos += len
          i += 1
        end
        [out, pos]
      end

      # Encodes values of a physical type with PLAIN. Inverse of decode; INT96 values are
      # [nanoseconds_of_day, julian_day] pairs and booleans are packed LSB-first, 8 per byte.
      # @param values [Array] values in their physical Ruby form, without nulls
      # @param type [Integer] physical type, a Format::Type constant
      # @param type_length [Integer, nil] byte width, required for FIXED_LEN_BYTE_ARRAY
      # @return [String] encoded bytes in ASCII-8BIT
      # @raise [EncodeError] if a FIXED_LEN_BYTE_ARRAY value has the wrong size or the type is unknown
      def encode(values, type, type_length = nil)
        case type
        when Format::Type::BOOLEAN
          [values.map { |v| v ? "1" : "0" }.join].pack("b*")
        when Format::Type::INT32, Format::Type::INT64, Format::Type::FLOAT, Format::Type::DOUBLE
          values.pack("#{FORMATS[type][0]}*")
        when Format::Type::INT96
          values.flat_map { |nanos, day| [nanos, day] }.pack("Q<L<" * values.size)
        when Format::Type::BYTE_ARRAY
          # pack("a*") copies raw bytes whatever the string's encoding, without an intermediate copy
          args = []
          values.each { |v| args << v.bytesize << v }
          args.pack("Va*" * values.size)
        when Format::Type::FIXED_LEN_BYTE_ARRAY
          values.each do |v|
            raise EncodeError, "Expected #{type_length} bytes, got #{v.bytesize}" if v.bytesize != type_length
          end
          values.pack("a*" * values.size)
        else
          raise EncodeError, "Unknown physical type #{type}"
        end
      end
    end
  end
end
