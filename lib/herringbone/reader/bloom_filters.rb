# frozen_string_literal: true

module Herringbone
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
    # @raise [FormatError] when the filter is truncated or its header cannot be decoded
    # @raise [DecryptionError] when the column is encrypted and its key was not given, or the
    #   filter does not decrypt
    def bloom_filter(row_group_index, column)
      col = bloom_filter_column(column)
      rg = row_groups.fetch(row_group_index) { raise IndexError, "No row group #{row_group_index}" }
      # Raises for an encrypted column without its key, whose metadata may be encrypted too
      crypto = chunk_crypto(row_group_index, col)
      meta = rg.columns.fetch(col.index).meta_data
      offset = meta&.bloom_filter_offset
      return nil unless offset
      return encrypted_bloom_filter(offset, col, crypto) if crypto
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
    rescue Thrift::Error => e
      raise FormatError, "Corrupt bloom filter header for #{col.dotted_path}: #{e.message}"
    end

    private

    # An encrypted bloom filter: the header and the bitset are two modules, one after the other
    #
    # @param offset [Integer] file offset of the header module
    # @param col [Schema::Column] the leaf column
    # @param crypto [Encryption::ModuleCrypto] decryption of the chunk's modules
    # @return [BloomFilter, nil] nil when the filter is of an unsupported kind
    # @raise [FormatError] when a module is truncated
    # @raise [DecryptionError] when a module does not decrypt
    def encrypted_bloom_filter(offset, col, crypto)
      header_module = read_module_at(offset)
      header = Format::BloomFilterHeader.decode(crypto.decrypt(Encryption::BLOOM_FILTER_HEADER, header_module)).first
      return nil unless BloomFilter.supported_header?(header)
      bitset = crypto.decrypt(Encryption::BLOOM_FILTER_BITSET, read_module_at(offset + header_module.bytesize))
      raise FormatError, "Truncated bloom filter" unless bitset.bytesize == header.num_bytes
      BloomFilter.new(bitset: bitset, column: col)
    end

    # @param offset [Integer] file offset of an encrypted module
    # @return [String] the module, length prefix included
    # @raise [FormatError] when it is cut off
    def read_module_at(offset)
      @io.seek(offset)
      prefix = @io.read(4)
      raise FormatError, "Truncated bloom filter" unless prefix&.bytesize == 4
      len = prefix.unpack1("V")
      body = @io.read(len)
      raise FormatError, "Truncated bloom filter" unless body&.bytesize == len
      prefix.b << body
    end

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
