# frozen_string_literal: true

module Herringbone
  # A Parquet Split Block Bloom Filter (parquet-format BloomFilter.md).
  #
  # The bitset is made of 32-byte blocks of eight 32-bit words. A value is hashed with XXH64 over
  # the PLAIN encoding of its physical value (without the length prefix for BYTE_ARRAY); the upper
  # 32 bits of the hash pick a block, and the lower 32 bits set one bit in each of its words.
  #
  # A filter answers "definitely not in the column chunk" or "maybe": +might_contain?+ never
  # returns false for a value that was inserted. Values are given as Ruby values and converted
  # like the writer converts them (the column's encoder), so a Date, Time, BigDecimal or UUID
  # String hashes the same bytes as the stored value. Nulls are never in a bloom filter.
  # The writer builds them (bloom_filters: option) and reads with where: consult them.
  class BloomFilter
    # The spec's eight salt constants, one per word of a block
    SALT = [0x47b6137b, 0x44974d91, 0x8824ad5b, 0xa2b7289d, 0x705495c7, 0x2df1424b, 0x9efc4947, 0x5c6bfb31].freeze
    S0, S1, S2, S3, S4, S5, S6, S7 = SALT
    # Low 16 bits of the salts: (lo * salt) mod 2**32 is computed as
    # (lo & 0xFFFF) * salt + ((lo >> 16) * (salt & 0xFFFF) << 16), which stays a Fixnum
    L0, L1, L2, L3, L4, L5, L6, L7 = SALT.map { |s| s & 0xFFFF }
    # Size of a block: eight 32-bit words
    BLOCK_BYTES = 32
    # Smallest bitset: a single block
    MIN_BYTES = 32
    # Largest bitset accepted when reading or building (128 MiB, the cap parquet-mr uses)
    MAX_BYTES = 128 * 1024 * 1024
    # Default cap for filters sized by the writer (as in parquet-mr)
    DEFAULT_MAX_BYTES = 1024 * 1024
    # Default false positive probability for filters sized by the writer
    DEFAULT_FPP = 0.01
    # 32-bit mask
    M32 = 0xFFFF_FFFF
    # 64-bit mask
    M64 = 0xFFFF_FFFF_FFFF_FFFF
    # Shorthand for the physical type constants
    T = Format::Type
    # Physical types a bloom filter can be built for (the spec does not define BOOLEAN hashing)
    TYPES = [T::INT32, T::INT64, T::INT96, T::FLOAT, T::DOUBLE, T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY].freeze

    # Bitset size in bytes for +ndv+ distinct values at false positive probability +fpp+, per the
    # spec's formula (m = -8 * ndv / ln(1 - fpp ** (1/8)) bits), rounded up to a power of two
    # and clamped to MIN_BYTES..max_bytes
    #
    # @param ndv [Integer] expected number of distinct values (values below 1 count as 1)
    # @param fpp [Float] false positive probability, strictly between 0 and 1
    # @param max_bytes [Integer] upper bound, clamped to MIN_BYTES..MAX_BYTES and rounded down to a
    #   power of two
    # @return [Integer] bitset size in bytes, a power of two
    # @raise [ArgumentError] when +fpp+ is not between 0 and 1
    def self.optimal_num_bytes(ndv, fpp = DEFAULT_FPP, max_bytes: DEFAULT_MAX_BYTES)
      fpp = Float(fpp)
      raise ArgumentError, "fpp must be between 0 and 1, got #{fpp}" unless fpp > 0 && fpp < 1
      max_bytes = Integer(max_bytes).clamp(MIN_BYTES, MAX_BYTES)
      max_bytes = 1 << (max_bytes.bit_length - 1) # a power of two
      ndv = [Integer(ndv), 1].max
      bits = -8.0 * ndv / Math.log(1 - fpp**(1.0 / 8))
      bytes = (bits / 8).ceil
      return max_bytes if bytes >= max_bytes
      return MIN_BYTES if bytes <= MIN_BYTES
      1 << (bytes - 1).bit_length
    end

    # XXH64 of the PLAIN encoding of a physical value of +type+ (as the column encoders produce it)
    #
    # @param value [Integer, Float, String, Array<Integer>] the physical value; for INT96 the
    #   +[nanos_of_day, julian_day]+ pair the encoder produces
    # @param type [Integer] Format::Type physical type
    # @return [Integer] the unsigned 64-bit hash
    # @raise [UnsupportedError] for BOOLEAN (or any type not in TYPES)
    def self.hash_physical(value, type)
      case type
      when T::INT32 then XXHash.xxh64_u32(value)
      when T::INT64 then XXHash.xxh64_u64(value)
      when T::FLOAT then XXHash.xxh64_u32([value].pack("e").unpack1("L<"))
      when T::DOUBLE then XXHash.xxh64_u64([value].pack("E").unpack1("Q<"))
      when T::INT96 then XXHash.xxh64(value.pack("Q<L<"))
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY then XXHash.xxh64(value)
      else raise UnsupportedError, "Bloom filters are not defined for #{T::NAMES.fetch(type, type)} values"
      end
    end

    # Hashes of many physical values of +type+, converting them in bulk. With +distinct+, each
    # distinct physical value is hashed once (floats are compared by their bytes, so -0.0 and 0.0,
    # or NaNs with different payloads, stay apart as they hash differently).
    #
    # @param values [Array] physical values, as for .hash_physical
    # @param type [Integer] Format::Type physical type
    # @param distinct [Boolean] hash each distinct value once (the result is then shorter)
    # @return [Array<Integer>] the unsigned 64-bit hashes
    # @raise [UnsupportedError] for BOOLEAN (or any type not in TYPES)
    def self.hash_physical_all(values, type, distinct: false)
      case type
      when T::INT32 then XXHash.xxh64_u32_all(distinct ? values.uniq : values)
      when T::INT64 then XXHash.xxh64_u64_all(distinct ? values.uniq : values)
      when T::FLOAT
        words = values.pack("e*").unpack("L<*")
        XXHash.xxh64_u32_all(distinct ? words.uniq! || words : words)
      when T::DOUBLE
        lanes = values.pack("E*").unpack("Q<*")
        XXHash.xxh64_u64_all(distinct ? lanes.uniq! || lanes : lanes)
      when T::INT96 then XXHash.xxh64_all((distinct ? values.uniq : values).map { |v| v.pack("Q<L<") })
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY then XXHash.xxh64_all(distinct ? values.uniq : values)
      else raise UnsupportedError, "Bloom filters are not defined for #{T::NAMES.fetch(type, type)} values"
      end
    end

    # Reads a filter (header and bitset) from +buf+ at +pos+. Returns nil for algorithms, hashes
    # or compressions this implementation does not know.
    #
    # @param buf [String] bytes holding the BloomFilterHeader followed by the bitset
    # @param pos [Integer] byte offset of the header in +buf+
    # @param column [Schema::Column, nil] column the filter belongs to, for converting values
    # @return [BloomFilter, nil] the filter, or nil when it is of an unsupported kind
    # @raise [FormatError] when the bitset is shorter than the header announces
    # @raise [Thrift::Error] when the header cannot be decoded
    def self.decode(buf, pos = 0, column: nil)
      reader = Thrift::Reader.new(buf, pos)
      header = reader.read_struct(Format::BloomFilterHeader)
      return nil unless supported_header?(header)
      bitset = buf.byteslice(reader.pos, header.num_bytes)
      raise FormatError, "Truncated bloom filter" if bitset.nil? || bitset.bytesize != header.num_bytes
      new(bitset: bitset, column: column)
    end

    # Whether a header describes a filter this implementation can read: split block algorithm,
    # XXH64, uncompressed, and a size that is a multiple of 32 bytes up to MAX_BYTES
    #
    # @param header [Format::BloomFilterHeader] decoded header
    # @return [Boolean] truthy when supported, falsy otherwise (not strictly true or false)
    def self.supported_header?(header)
      n = header.num_bytes
      n.is_a?(Integer) && n >= BLOCK_BYTES && (n % BLOCK_BYTES).zero? && n <= MAX_BYTES &&
        header.algorithm&.block && header.hash_function&.xxhash &&
        (header.compression.nil? || header.compression.uncompressed)
    end

    # @return [Schema::Column, nil] column whose encoder converts values, nil for raw Strings
    attr_reader :column

    # A filter of +num_bytes+ (a multiple of 32, normally a power of two), or one using an existing
    # +bitset+ String. With a +column+ (a Schema::Column), values are Ruby values converted with
    # the column's encoder; without one, values must be Strings and their bytes are hashed.
    #
    # @param num_bytes [Integer, nil] bitset size for an empty filter (MIN_BYTES when nil); ignored
    #   with +bitset+
    # @param bitset [String, nil] existing bitset (little-endian 32-bit words)
    # @param column [Schema::Column, nil] column the filter is for
    # @raise [ArgumentError] when the size is not a multiple of 32 bytes or exceeds MAX_BYTES
    # @raise [UnsupportedError] when the column's physical type cannot have a bloom filter
    def initialize(num_bytes = nil, bitset: nil, column: nil)
      if bitset
        @words = bitset.unpack("V*")
      else
        num_bytes = Integer(num_bytes || MIN_BYTES)
        unless num_bytes >= BLOCK_BYTES && (num_bytes % BLOCK_BYTES).zero? && num_bytes <= MAX_BYTES
          raise ArgumentError, "Bloom filter size must be a multiple of 32 bytes up to 128MB, got #{num_bytes}"
        end
        @words = Array.new(num_bytes / 4, 0)
      end
      @num_blocks = @words.size / 8
      raise ArgumentError, "Bloom filter bitset must be a multiple of 32 bytes" if @num_blocks.zero? || @words.size % 8 != 0
      @column = column
      if column && !TYPES.include?(column.type)
        raise UnsupportedError, "Bloom filters are not supported for #{T::NAMES[column.type]} column #{column.dotted_path}"
      end
    end

    # @return [Integer] bitset size in bytes
    def num_bytes = @words.size * 4

    # Adds a value to the filter
    #
    # @param value [Object] Ruby value, converted with the column's encoder (a String without a
    #   column)
    # @return [BloomFilter] self
    # @raise [ArgumentError] for nil or a value the column cannot encode
    def insert(value)
      insert_hash(hash_of(value))
      self
    end

    # Whether the value may be in the filter. Never false for an inserted value; true for a
    # value that was not inserted with about the false positive probability the filter was sized for.
    #
    # @param value [Object] Ruby value, converted with the column's encoder (a String without a
    #   column)
    # @return [Boolean] false when the value is definitely absent
    # @raise [ArgumentError] for nil or a value the column cannot encode
    def might_contain?(value)
      might_contain_hash?(hash_of(value))
    end

    # XXH64 hash the filter uses for a Ruby +value+
    #
    # @param value [Object] Ruby value, converted with the column's encoder (a String without a
    #   column)
    # @return [Integer] the unsigned 64-bit hash
    # @raise [ArgumentError] for nil, a value the column cannot encode, or (without a column) a
    #   non-String
    def hash_of(value)
      raise ArgumentError, "Nulls are not recorded in bloom filters" if value.nil?
      if @column
        begin
          physical = @column.encoder.call(value)
        rescue ArgumentError, TypeError, NoMethodError, RangeError, EncodeError => e
          raise ArgumentError, "#{value.inspect} is not a valid value for #{@column.dotted_path}: #{e.message}"
        end
        self.class.hash_physical(physical, @column.type)
      else
        raise ArgumentError, "Without a column, bloom filter values must be Strings, got #{value.class}" unless value.is_a?(String)
        XXHash.xxh64(value)
      end
    end

    # Sets the bits for a hash: the upper 32 bits pick the block, the lower 32 bits (multiplied
    # by each salt) one bit in each of its eight words
    #
    # @param h [Integer] unsigned 64-bit XXH64 hash
    # @return [BloomFilter] self
    def insert_hash(h)
      i = (((h >> 32) * @num_blocks) >> 32) << 3
      x0 = h & 0xFFFF
      x1 = (h >> 16) & 0xFFFF
      w = @words
      w[i] |= 1 << (((x0 * S0 + (x1 * L0 << 16)) & M32) >> 27)
      w[i + 1] |= 1 << (((x0 * S1 + (x1 * L1 << 16)) & M32) >> 27)
      w[i + 2] |= 1 << (((x0 * S2 + (x1 * L2 << 16)) & M32) >> 27)
      w[i + 3] |= 1 << (((x0 * S3 + (x1 * L3 << 16)) & M32) >> 27)
      w[i + 4] |= 1 << (((x0 * S4 + (x1 * L4 << 16)) & M32) >> 27)
      w[i + 5] |= 1 << (((x0 * S5 + (x1 * L5 << 16)) & M32) >> 27)
      w[i + 6] |= 1 << (((x0 * S6 + (x1 * L6 << 16)) & M32) >> 27)
      w[i + 7] |= 1 << (((x0 * S7 + (x1 * L7 << 16)) & M32) >> 27)
      self
    end

    # Single-bit masks, +BITS[i] == 1 << i+
    BITS = Array.new(32) { |i| 1 << i }.freeze

    # Inserts many hashes at once: faster than insert_hash, as the hashes (mostly Bignums) are
    # split into 32-bit halves in bulk and the rest is Fixnum arithmetic
    #
    # @param hashes [Array<Integer>] unsigned 64-bit XXH64 hashes
    # @return [BloomFilter] self
    def insert_hashes(hashes)
      halves = hashes.pack("Q<*").unpack("V*")
      w = @words
      num_blocks = @num_blocks
      bit = BITS
      j = 0
      n = halves.size
      while j < n
        lo = halves[j]
        i = halves[j + 1] * num_blocks / 4_294_967_296 * 8
        x0 = lo & 0xFFFF
        x1 = lo / 65_536
        w[i] |= bit[(x0 * S0 + x1 * L0 * 65536) / 134_217_728 & 31]
        w[i + 1] |= bit[(x0 * S1 + x1 * L1 * 65536) / 134_217_728 & 31]
        w[i + 2] |= bit[(x0 * S2 + x1 * L2 * 65536) / 134_217_728 & 31]
        w[i + 3] |= bit[(x0 * S3 + x1 * L3 * 65536) / 134_217_728 & 31]
        w[i + 4] |= bit[(x0 * S4 + x1 * L4 * 65536) / 134_217_728 & 31]
        w[i + 5] |= bit[(x0 * S5 + x1 * L5 * 65536) / 134_217_728 & 31]
        w[i + 6] |= bit[(x0 * S6 + x1 * L6 * 65536) / 134_217_728 & 31]
        w[i + 7] |= bit[(x0 * S7 + x1 * L7 * 65536) / 134_217_728 & 31]
        j += 2
      end
      self
    end

    # Whether all the bits for a hash are set (see #insert_hash)
    #
    # @param h [Integer] unsigned 64-bit XXH64 hash
    # @return [Boolean] false when the hashed value is definitely absent
    def might_contain_hash?(h)
      i = (((h >> 32) * @num_blocks) >> 32) << 3
      x0 = h & 0xFFFF
      x1 = (h >> 16) & 0xFFFF
      w = @words
      w[i][(((x0 * S0 + (x1 * L0 << 16)) & M32) >> 27)] == 1 &&
        w[i + 1][(((x0 * S1 + (x1 * L1 << 16)) & M32) >> 27)] == 1 &&
        w[i + 2][(((x0 * S2 + (x1 * L2 << 16)) & M32) >> 27)] == 1 &&
        w[i + 3][(((x0 * S3 + (x1 * L3 << 16)) & M32) >> 27)] == 1 &&
        w[i + 4][(((x0 * S4 + (x1 * L4 << 16)) & M32) >> 27)] == 1 &&
        w[i + 5][(((x0 * S5 + (x1 * L5 << 16)) & M32) >> 27)] == 1 &&
        w[i + 6][(((x0 * S6 + (x1 * L6 << 16)) & M32) >> 27)] == 1 &&
        w[i + 7][(((x0 * S7 + (x1 * L7 << 16)) & M32) >> 27)] == 1
    end

    # The raw bitset (little-endian 32-bit words)
    #
    # @return [String] binary String of #num_bytes bytes
    def bitset = @words.pack("V*")

    # Header and bitset, as stored in a Parquet file
    #
    # @return [String] Thrift-encoded BloomFilterHeader followed by the bitset (binary)
    def encode
      header.encode << bitset
    end

    # @return [String] size and, when set, the column's dotted path
    def inspect
      "#<#{self.class.name} #{num_bytes} bytes#{" for #{@column.dotted_path}" if @column}>"
    end

    private

    # Header for this filter: split block algorithm, XXH64 hash, uncompressed
    #
    # @return [Format::BloomFilterHeader] the header
    def header
      Format::BloomFilterHeader.new(
        num_bytes: num_bytes,
        algorithm: Format::BloomFilterAlgorithm.new(block: Format::SplitBlockAlgorithm.new),
        hash_function: Format::BloomFilterHash.new(xxhash: Format::XxHash.new),
        compression: Format::BloomFilterCompression.new(uncompressed: Format::BloomFilterUncompressed.new)
      )
    end
  end

  class Reader
    # Internal (used by reads with where:): the bloom filter of a column chunk. +column+ is a
    # dotted path ("a.b"), an Array path or a Schema::Column. Returns a BloomFilter, or nil when
    # the chunk has none (or one of an unknown kind).
    #
    # @param row_group_index [Integer] index of the row group
    # @param column [String, Array<String, Symbol>, Symbol, Schema::Column] the leaf column
    # @return [BloomFilter, nil] the filter, or nil when there is none or it is unsupported
    # @raise [IndexError] when there is no such row group
    # @raise [ArgumentError] when there is no such column
    # @raise [FormatError] when the filter is truncated
    # @raise [Thrift::Error] when the filter header cannot be decoded
    def bloom_filter(row_group_index, column)
      col = bloom_filter_column(column)
      rg = row_groups.fetch(row_group_index) { raise IndexError, "No row group #{row_group_index}" }
      meta = rg.columns.fetch(col.index).meta_data
      offset = meta&.bloom_filter_offset
      return nil unless offset
      length = meta.bloom_filter_length
      @io.seek(offset)
      if length
        buf = @io.read(length)
        raise FormatError, "Truncated bloom filter" if buf.nil? || buf.bytesize < length
        return BloomFilter.decode(buf, column: col)
      end
      # Without a length (older writers), read the header first, then the bitset it announces
      head = @io.read(256) || "".b
      reader = Thrift::Reader.new(head)
      header = reader.read_struct(Format::BloomFilterHeader)
      return nil unless BloomFilter.supported_header?(header)
      @io.seek(offset + reader.pos)
      bitset = @io.read(header.num_bytes)
      raise FormatError, "Truncated bloom filter" if bitset.nil? || bitset.bytesize != header.num_bytes
      BloomFilter.new(bitset: bitset, column: col)
    end

    private

    # Resolves the +column+ argument of #bloom_filter to a leaf column
    #
    # @param column [String, Array<String, Symbol>, Symbol, Schema::Column] dotted path, path
    #   Array or column
    # @return [Schema::Column] the column
    # @raise [ArgumentError] when the schema has no such column
    def bloom_filter_column(column)
      return column if column.is_a?(Schema::Column)
      col = schema.column(column.is_a?(Array) ? column.map(&:to_s) : column.to_s)
      raise ArgumentError, "No column #{column.inspect}" unless col
      col
    end
  end
end
