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
  #
  #   File.open("events.parquet", "rb") do |f|
  #     reader = Herringbone::Reader.new(f)
  #     reader.bloom_filter(0, "user_id")&.might_contain?(42)
  #     reader.row_groups_that_may_contain("user_id", 42) # => [0, 3]
  #   end
  class BloomFilter
    SALT = [0x47b6137b, 0x44974d91, 0x8824ad5b, 0xa2b7289d, 0x705495c7, 0x2df1424b, 0x9efc4947, 0x5c6bfb31].freeze
    S0, S1, S2, S3, S4, S5, S6, S7 = SALT
    BLOCK_BYTES = 32
    MIN_BYTES = 32
    MAX_BYTES = 128 * 1024 * 1024
    # Default cap for filters sized by the writer (as in parquet-mr)
    DEFAULT_MAX_BYTES = 1024 * 1024
    DEFAULT_FPP = 0.01
    M32 = 0xFFFF_FFFF
    M64 = 0xFFFF_FFFF_FFFF_FFFF
    T = Format::Type
    # Physical types a bloom filter can be built for (the spec does not define BOOLEAN hashing)
    TYPES = [T::INT32, T::INT64, T::INT96, T::FLOAT, T::DOUBLE, T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY].freeze

    # Bitset size in bytes for +ndv+ distinct values at false positive probability +fpp+, per the
    # spec's formula (m = -8 * ndv / ln(1 - fpp ** (1/8)) bits), rounded up to a power of two
    # and clamped to MIN_BYTES..max_bytes
    def self.optimal_num_bytes(ndv, fpp = DEFAULT_FPP, max_bytes: DEFAULT_MAX_BYTES)
      fpp = Float(fpp)
      raise ArgumentError, "fpp must be between 0 and 1, got #{fpp}" unless fpp > 0 && fpp < 1
      max_bytes = [[Integer(max_bytes), MAX_BYTES].min, MIN_BYTES].max
      max_bytes = 1 << (max_bytes.bit_length - 1) # a power of two
      ndv = [Integer(ndv), 1].max
      bits = -8.0 * ndv / Math.log(1 - fpp**(1.0 / 8))
      bytes = (bits / 8).ceil
      return max_bytes if bytes >= max_bytes
      return MIN_BYTES if bytes <= MIN_BYTES
      1 << (bytes - 1).bit_length
    end

    # XXH64 of the PLAIN encoding of a physical value of +type+ (as the column encoders produce it)
    def self.hash_physical(value, type)
      case type
      when T::INT32 then XXHash.xxh64_u32(value & M32)
      when T::INT64 then XXHash.xxh64_u64(value & M64)
      when T::FLOAT then XXHash.xxh64_u32([value].pack("e").unpack1("L<"))
      when T::DOUBLE then XXHash.xxh64_u64([value].pack("E").unpack1("Q<"))
      when T::INT96 then XXHash.xxh64(value.pack("Q<L<"))
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY then XXHash.xxh64(value)
      else raise UnsupportedError, "Bloom filters are not defined for #{T::NAMES.fetch(type, type)} values"
      end
    end

    # Hashes of many physical values of +type+, converting them in bulk
    def self.hash_physical_all(values, type)
      case type
      when T::INT32 then values.map { |v| XXHash.xxh64_u32(v & M32) }
      when T::INT64 then values.map { |v| XXHash.xxh64_u64(v & M64) }
      when T::FLOAT then values.pack("e*").unpack("L<*").map! { |w| XXHash.xxh64_u32(w) }
      when T::DOUBLE then values.pack("E*").unpack("Q<*").map! { |w| XXHash.xxh64_u64(w) }
      else values.map { |v| hash_physical(v, type) }
      end
    end

    # Reads a filter (header and bitset) from +buf+ at +pos+. Returns nil for algorithms, hashes
    # or compressions this implementation does not know.
    def self.decode(buf, pos = 0, column: nil)
      reader = Thrift::Reader.new(buf, pos)
      header = reader.read_struct(Format::BloomFilterHeader)
      return nil unless supported_header?(header)
      bitset = buf.byteslice(reader.pos, header.num_bytes)
      raise FormatError, "Truncated bloom filter" if bitset.nil? || bitset.bytesize != header.num_bytes
      new(bitset: bitset, column: column)
    end

    def self.supported_header?(header)
      n = header.num_bytes
      n.is_a?(Integer) && n >= BLOCK_BYTES && (n % BLOCK_BYTES).zero? && n <= MAX_BYTES &&
        header.algorithm&.block && header.hash_function&.xxhash &&
        (header.compression.nil? || header.compression.uncompressed)
    end

    attr_reader :column

    # A filter of +num_bytes+ (a multiple of 32, normally a power of two), or one using an existing
    # +bitset+ String. With a +column+ (a Schema::Column), values are Ruby values converted with
    # the column's encoder; without one, values must be Strings and their bytes are hashed.
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

    def num_bytes = @words.size * 4

    def insert(value)
      insert_hash(hash_of(value))
      self
    end
    alias_method :<<, :insert

    def might_contain?(value)
      might_contain_hash?(hash_of(value))
    end
    alias_method :include?, :might_contain?

    # XXH64 hash the filter uses for a Ruby +value+
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

    def insert_hash(h)
      i = (((h >> 32) * @num_blocks) >> 32) << 3
      lo = h & M32
      w = @words
      w[i] |= 1 << (((lo * S0) & M32) >> 27)
      w[i + 1] |= 1 << (((lo * S1) & M32) >> 27)
      w[i + 2] |= 1 << (((lo * S2) & M32) >> 27)
      w[i + 3] |= 1 << (((lo * S3) & M32) >> 27)
      w[i + 4] |= 1 << (((lo * S4) & M32) >> 27)
      w[i + 5] |= 1 << (((lo * S5) & M32) >> 27)
      w[i + 6] |= 1 << (((lo * S6) & M32) >> 27)
      w[i + 7] |= 1 << (((lo * S7) & M32) >> 27)
      self
    end

    def might_contain_hash?(h)
      i = (((h >> 32) * @num_blocks) >> 32) << 3
      lo = h & M32
      w = @words
      w[i][((lo * S0) & M32) >> 27] == 1 &&
        w[i + 1][((lo * S1) & M32) >> 27] == 1 &&
        w[i + 2][((lo * S2) & M32) >> 27] == 1 &&
        w[i + 3][((lo * S3) & M32) >> 27] == 1 &&
        w[i + 4][((lo * S4) & M32) >> 27] == 1 &&
        w[i + 5][((lo * S5) & M32) >> 27] == 1 &&
        w[i + 6][((lo * S6) & M32) >> 27] == 1 &&
        w[i + 7][((lo * S7) & M32) >> 27] == 1
    end

    # The raw bitset (little-endian 32-bit words)
    def bitset = @words.pack("V*")

    def header
      Format::BloomFilterHeader.new(
        num_bytes: num_bytes,
        algorithm: Format::BloomFilterAlgorithm.new(block: Format::SplitBlockAlgorithm.new),
        hash_function: Format::BloomFilterHash.new(xxhash: Format::XxHash.new),
        compression: Format::BloomFilterCompression.new(uncompressed: Format::BloomFilterUncompressed.new)
      )
    end

    # Header and bitset, as stored in a Parquet file
    def encode
      header.encode << bitset
    end

    # Fraction of bits set, a rough indication of how full the filter is
    def saturation
      @words.sum { |w| w.to_s(2).count("1") } / (@words.size * 32.0)
    end

    def inspect
      "#<#{self.class.name} #{num_bytes} bytes#{" for #{@column.dotted_path}" if @column}>"
    end
  end

  class Reader
    # Reads the bloom filter of a column chunk: +column+ is a dotted path ("a.b") or an Array
    # path. Returns a BloomFilter, or nil when the chunk has none (or one of an unknown kind).
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

    # Indexes of the row groups that may hold +value+ in +column+, according to their bloom
    # filters. Row groups without a bloom filter for the column are always included.
    def row_groups_that_may_contain(column, value)
      col = bloom_filter_column(column)
      probe = BloomFilter.new(column: col)
      hash = probe.hash_of(value)
      (0...row_groups.size).select do |i|
        filter = bloom_filter(i, col.path)
        filter.nil? || filter.might_contain_hash?(hash)
      end
    end

    private

    def bloom_filter_column(column)
      return column if column.is_a?(Schema::Column)
      col = schema.column(column.is_a?(Array) ? column.map(&:to_s) : column.to_s)
      raise ArgumentError, "No column #{column.inspect}" unless col
      col
    end
  end
end
