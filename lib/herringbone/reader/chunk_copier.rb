# frozen_string_literal: true

module Herringbone
  class Reader
    # Internal (used by Redaction and Herringbone.combine): takes plaintext column chunks out of a
    # file as they are stored, for Writer#write_row_group to copy into another file, and tells how
    # a chunk that has to be encoded again should be compressed.
    class ChunkCopier
      # Bytes read at a time when a page header runs past what was read of a chunk
      READ_MORE = 64 * 1024

      # @param reader [Reader] reads the file's footer, page indexes and bloom filters
      # @param io [RestrictedReadableIO, IO, StringIO] the IO +reader+ reads, read with #seek and #read
      def initialize(reader, io)
        @reader = reader
        @io = RestrictedReadableIO.wrap(io)
      end

      # @param i [Integer] row group index
      # @param col [Schema::Column] the column, in the file's schema
      # @return [Writer::CopiedChunk] the chunk's pages, page index and bloom filter
      # @raise [UnsupportedError] for an encrypted chunk or one stored in another file
      # @raise [FormatError] when a page header is corrupt or the chunk overruns the file
      def copy(i, col)
        chunk = @reader.row_groups[i].columns.fetch(col.index)
        meta = chunk.meta_data or raise UnsupportedError, "Column chunk without metadata (encrypted?)"
        raise UnsupportedError, "Column chunks in external files are not supported" if chunk.file_path
        column_index, offset_index = @reader.page_index(i, col)
        start, bytes = chunk_bytes(col, meta, offset_index)
        column_index &&= read_at(chunk.column_index_offset, chunk.column_index_length)
        Writer::CopiedChunk.new(chunk, start, bytes, column_index, offset_index, bloom_bytes(i, col, meta))
      end

      # How a chunk encoded again follows the source chunk: the same codec (LZO cannot be written
      # and becomes Snappy), and a bloom filter when the source chunk had one
      #
      # @param i [Integer] row group index
      # @param col [Schema::Column] the column, in the file's schema
      # @return [Array(Integer, Boolean), nil] codec id and whether to write a bloom filter, nil when
      #   the chunk's metadata is not readable
      def recode_settings(i, col)
        meta = @reader.row_groups[i].columns.fetch(col.index).meta_data
        return nil unless meta
        [(meta.codec == Format::Codec::LZO) ? Format::Codec::SNAPPY : meta.codec, !meta.bloom_filter_offset.nil?]
      end

      # The encrypted columns of a file encrypted like this one, as the +columns:+ of its
      # EncryptionConfiguration: those encrypted with the footer key as +:footer+, the others
      # with their key and key metadata
      #
      # @param sources [Hash{String => Schema::Column}] the new file's column path => the column
      #   here that holds its values
      # @return [Hash{String => Symbol, Hash}] the encrypted ones of +sources+
      # @raise [DecryptionError] when the key of an encrypted column was not given
      def encrypted_columns(sources)
        decryptor = @reader.decryptor or return {}
        chunks = @reader.row_groups.first&.columns || []
        sources.filter_map do |path, col|
          chunk = chunks[col.index]
          crypto = chunk&.crypto_metadata or next
          with_column_key = crypto.encryption_with_column_key
          next [path, :footer] unless with_column_key
          key = decryptor.chunk_key(chunk, col.dotted_path)
          key or raise DecryptionError, "The output is encrypted like the input, which needs the key of #{col.dotted_path}: " \
            "pass it in decryption:, or pass encryption: for the output"
          [path, {key: key, key_metadata: with_column_key.key_metadata}]
        end.to_h
      end

      private

      # The chunk's pages. They are walked header by header rather than trusting
      # total_compressed_size, which some writers get wrong: copying too little breaks the
      # chunk, and copying too much could carry over bytes of a neighbouring chunk.
      #
      # @param col [Schema::Column] the column
      # @param meta [Format::ColumnMetaData] the chunk's metadata
      # @param offset_index [Format::OffsetIndex, nil] the chunk's OffsetIndex, whose pages are
      #   included even when num_values is reached before them
      # @return [Array(Integer, String)] file offset of the first page, and the pages' bytes
      # @raise [FormatError] when a page header is corrupt or the chunk overruns the file
      def chunk_bytes(col, meta, offset_index)
        start = meta.data_page_offset
        dict = meta.dictionary_page_offset
        start = dict if dict&.positive? && dict < start
        last = offset_index&.page_locations&.last
        min_end = last ? last.offset + last.compressed_page_size - start : 0
        @io.seek(start)
        buf = (@io.read(meta.total_compressed_size) || "").b
        pos = 0
        seen = 0
        while seen < meta.num_values || pos < min_end
          begin
            header, body = Format::PageHeader.decode(buf, pos)
          rescue Thrift::Error
            raise FormatError, "Corrupt page header in #{col.dotted_path}" if read_more(buf, start, READ_MORE).zero?
            retry
          end
          size = header.compressed_page_size
          raise FormatError, "Negative page size in #{col.dotted_path}" if size.nil? || size.negative?
          short = body + size - buf.bytesize
          if short.positive? && read_more(buf, start, short) < short
            raise FormatError, "Column #{col.dotted_path}: page overruns the file"
          end
          pos = body + size
          seen += header.data_page_header&.num_values || header.data_page_header_v2&.num_values || 0
        end
        [start, (pos == buf.bytesize) ? buf : buf.byteslice(0, pos)]
      end

      # Appends up to +count+ bytes that follow +buf+ in the file
      #
      # @param buf [String] bytes read from +start+ on; appended to
      # @param start [Integer] file offset of +buf+
      # @param count [Integer] bytes wanted
      # @return [Integer] bytes appended, 0 at the end of the file
      def read_more(buf, start, count)
        @io.seek(start + buf.bytesize)
        more = @io.read(count)
        return 0 if more.nil?
        buf << more.b
        more.bytesize
      end

      # @param offset [Integer, nil] file offset
      # @param length [Integer, nil] byte count
      # @return [String, nil] the bytes, nil when absent or cut off
      def read_at(offset, length)
        return nil unless offset && length&.positive?
        @io.seek(offset)
        bytes = @io.read(length)
        (bytes&.bytesize == length) ? bytes.b : nil
      end

      # The chunk's bloom filter as stored. Filters written without a length (older writers) are
      # decoded and encoded again. A filter that cannot be read is left out, which only costs
      # pruning.
      #
      # @param i [Integer] row group index
      # @param col [Schema::Column] the column
      # @param meta [Format::ColumnMetaData] the chunk's metadata
      # @return [String, nil] header and bitset
      def bloom_bytes(i, col, meta)
        return nil unless meta.bloom_filter_offset
        return read_at(meta.bloom_filter_offset, meta.bloom_filter_length) if meta.bloom_filter_length
        @reader.bloom_filter(i, col)&.encode
      rescue FormatError
        nil
      end
    end
  end
end
