# frozen_string_literal: true

module Herringbone
  class Reader
    # Decodes the pages of one column chunk, one page at a time. Pages are read from the IO as
    # they are needed (a page header, then its body), so memory use is bounded by the page size
    # rather than the size of the chunk.
    #
    #   reader = ColumnChunkReader.new(io, chunk, column)
    #   while (page = reader.next_page)
    #     defs, reps, values = page # levels are nil when the column's max level is 0
    #   end
    #
    # The declared total_compressed_size of the chunk is not relied on (some old writers
    # under-report it): pages are read until the chunk's num_values have been seen.
    class ColumnChunkReader
      # Shorthand for the physical type constants
      T = Format::Type
      # Shorthand for the encoding constants
      E = Format::Encoding

      # Bytes read past a page body, so that the next page header usually needs no extra read
      READ_AHEAD = 64 * 1024
      # Bytes read for a page header whose size is not known; grown 4x while decoding fails
      HEADER_GUESS = 1024
      # Largest header read attempted before a page header is declared corrupt
      MAX_HEADER = 64 * 1024 * 1024

      # @return [Schema::Column] the leaf column this chunk belongs to
      attr_reader :column

      # With +lazy+, values of data pages that are not dictionary-encoded are returned as
      # physical values, and #page_converter is what still has to be applied to them. This keeps
      # a decoded page small (Integers instead of Time or BigDecimal objects) when only a slice
      # of it is needed at a time.
      #
      # @return [Proc, nil] converter of the last page returned by #next_page, nil when none
      attr_reader :page_converter

      # @param io [IO, StringIO] the file, read with #seek and #read
      # @param chunk [Format::ColumnChunk] the chunk's footer entry
      # @param column [Schema::Column] the leaf column the chunk stores
      # @param converter [Proc, nil] physical value => Ruby value, applied to values and dictionaries
      # @param lazy [Boolean] leave non-dictionary values physical in #next_page (see #page_converter)
      # @param crypto [Encryption::ModuleCrypto, nil] decryption of the chunk's pages, for an
      #   encrypted column
      # @raise [UnsupportedError] for chunks without metadata (encrypted) or stored in another file
      def initialize(io, chunk, column, converter: column.converter, lazy: false, crypto: nil)
        @io = io
        @chunk = chunk
        @column = column
        @meta = chunk.meta_data or raise UnsupportedError, "Column chunk without metadata (encrypted?)"
        raise UnsupportedError, "Column chunks in external files are not supported" if chunk.file_path
        @max_def = column.max_definition_level
        @max_rep = column.max_repetition_level
        @converter = converter
        @lazy = lazy
        start = @meta.data_page_offset
        dict = @meta.dictionary_page_offset
        # Some writers store 0 when there is no dictionary page
        start = dict if dict&.positive? && dict < start
        @pos = start
        @start = start
        @crypto = crypto
        # An encrypted header's AAD depends on whether it is the dictionary page's, which only its
        # position tells before it is decrypted
        @dictionary_offset = (start < @meta.data_page_offset) ? start : nil
        @ordinal = 0 # data pages read so far, part of an encrypted data page's AAD
        @locations = nil # OffsetIndex page locations, when jumping between pages
        @page_number = nil
        @total = @meta.num_values
        @seen = 0
        @buf = "".b
        @buf_pos = start
      end

      # All pages concatenated: [definition_levels, repetition_levels, values]
      #
      # @return [Array(Array<Integer>, Array<Integer>, Array)] levels are nil when the column's
      #   max level is 0
      # @raise [FormatError] when a page is corrupt or overruns the file
      def read
        defs = @max_def.positive? ? [] : nil
        reps = @max_rep.positive? ? [] : nil
        values = []
        while (page = next_page)
          d, r, v = page
          defs&.concat(d)
          reps&.concat(r)
          values.concat(v)
        end
        [defs, reps, values]
      end

      # The next data page as [defs, reps, values], or nil after the last one
      #
      # @return [Array(Array<Integer>, Array<Integer>, Array), nil] levels are nil when the
      #   column's max level is 0; values hold the non-null entries
      # @raise [FormatError] when a page is corrupt or overruns the file
      def next_page
        page = next_stream or return nil
        n = page.remaining
        defs, reps = page.read_levels(n)
        non_null = defs ? defs.count(@max_def) : n
        values = page.read_values(non_null)
        if (conv = page.converter)
          if @lazy
            @page_converter = conv
          else
            values.map!(&conv)
          end
        else
          @page_converter = nil
        end
        [defs, reps, values]
      end

      # The next data page as a PageStream::Page that decodes its levels and values on demand,
      # or nil after the last one. Values come out physical; apply Page#converter to them.
      # Dictionary pages are read on the way.
      #
      # @return [PageStream::Page, nil] the next data page
      # @raise [FormatError] when a page header is corrupt or a page overruns the file
      # @raise [UnsupportedError] for an unsupported encoding or compression codec
      def next_stream
        while more_pages?
          header, body = read_page
          case header.type
          when Format::PageType::DICTIONARY_PAGE
            read_dictionary(header, body)
          when Format::PageType::DATA_PAGE
            page = data_page_v1(header, body)
            @seen += header.data_page_header.num_values
            @page_number += 1 if @page_number
            return page
          when Format::PageType::DATA_PAGE_V2
            page = data_page_v2(header, body)
            @seen += header.data_page_header_v2.num_values
            @page_number += 1 if @page_number
            return page
          end
        end
        nil
      rescue Thrift::Error => e
        raise FormatError, "Corrupt page header in #{@column.dotted_path}: #{e.message}"
      end

      # @return [Array<Format::PageLocation>, nil] the chunk's data page locations from its
      #   OffsetIndex (enables #jump_to_page)
      attr_accessor :locations

      # Continues reading at data page +index+ of the OffsetIndex. The dictionary page (which
      # the OffsetIndex does not list) is read first if it has not been yet.
      #
      # @param index [Integer] position of the page in #locations
      # @return [void]
      # @raise [ArgumentError] when no #locations are set
      # @raise [IndexError] when +index+ is outside #locations
      def jump_to_page(index)
        raise ArgumentError, "No OffsetIndex for #{@column.dotted_path}" unless @locations
        load_dictionary
        @pos = @locations.fetch(index).offset
        @page_number = index
        @ordinal = index
      end

      # Whether all of the chunk's values have been returned
      #
      # @return [Boolean] true once num_values entries have been seen
      def done? = @seen >= @total

      # @return [Integer] entries (levels, nulls included) of the data pages returned so far
      attr_reader :seen

      # @return [Integer] the chunk's num_values from its ColumnMetaData
      attr_reader :total

      private

      # Whether another data page is due: up to the last OffsetIndex location after a jump,
      # otherwise until num_values entries have been seen
      #
      # @return [Boolean] true when #next_stream should read on
      def more_pages?
        @page_number ? @page_number < @locations.size : @seen < @total
      end

      # Reads the dictionary page at the start of the chunk, if there is one
      #
      # @return [void]
      def load_dictionary
        return if @dictionary || @dictionary_checked
        @dictionary_checked = true
        first_data = @locations.first&.offset
        return if first_data.nil? || @start >= first_data
        saved = @pos
        @pos = @start
        header, body = read_page
        read_dictionary(header, body) if header.type == Format::PageType::DICTIONARY_PAGE
        @pos = saved
      end

      # Reads the page header at @pos and the page body after it
      #
      # @return [Array(Format::PageHeader, String)] the header and the (still compressed) body
      # @raise [FormatError] for a negative page size or a page that overruns the file
      # @raise [DecryptionError] when an encrypted page does not decrypt
      def read_page
        return read_encrypted_page if @crypto
        # With an OffsetIndex the page's size (header included) is known, so read exactly that
        loc = @page_number && @locations[@page_number]
        exact = loc && loc.offset == @pos && loc.compressed_page_size.positive?
        want = exact ? loc.compressed_page_size : HEADER_GUESS
        begin
          buf, off = window(@pos, want)
          header, hend = Format::PageHeader.decode(buf, off)
        rescue Thrift::Error
          # The header may be larger than guessed (long statistics) or be cut off by EOF
          raise if buf.bytesize - off < want || want >= MAX_HEADER
          want *= 4
          retry
        end
        hlen = hend - off
        size = header.compressed_page_size
        raise FormatError, "Negative page size in #{@column.dotted_path}" if size.nil? || size.negative?
        buf, off = window(@pos + hlen, size + (exact ? 0 : READ_AHEAD), size)
        if buf.bytesize - off < size
          raise FormatError, "Column #{@column.dotted_path}: page overruns the file (read #{@seen} of #{@total} values)"
        end
        body = (off.zero? && buf.bytesize == size) ? buf : buf.byteslice(off, size)
        @pos += hlen + size
        [header, body]
      end

      # Like #read_page, for an encrypted column: the header and the body are each an encrypted
      # module, the header's starting with its length
      #
      # @return [Array(Format::PageHeader, String)] the header and the decrypted (still compressed) body
      # @raise [FormatError] for a page that overruns the file
      # @raise [DecryptionError] when the header or the body does not decrypt
      def read_encrypted_page
        loc = @page_number && @locations[@page_number]
        exact = loc && loc.offset == @pos && loc.compressed_page_size.positive?
        dictionary = @pos == @dictionary_offset
        ordinal = dictionary ? nil : @ordinal
        mod = read_module(@pos, exact ? loc.compressed_page_size : HEADER_GUESS)
        type = dictionary ? Encryption::DICTIONARY_PAGE_HEADER : Encryption::DATA_PAGE_HEADER
        header = Format::PageHeader.decode(@crypto.decrypt(type, mod, ordinal)).first
        size = header.compressed_page_size
        raise FormatError, "Negative page size in #{@column.dotted_path}" if size.nil? || size.negative?
        buf, off = window(@pos + mod.bytesize, size + (exact ? 0 : READ_AHEAD), size)
        if buf.bytesize - off < size
          raise FormatError, "Column #{@column.dotted_path}: page overruns the file (read #{@seen} of #{@total} values)"
        end
        type = (header.type == Format::PageType::DICTIONARY_PAGE) ? Encryption::DICTIONARY_PAGE : Encryption::DATA_PAGE
        body = @crypto.decrypt(type, buf.byteslice(off, size), ordinal)
        @pos += mod.bytesize + size
        @ordinal += 1 unless dictionary
        [header, body]
      end

      # An encrypted module (length prefix included) at +pos+
      #
      # @param pos [Integer] file offset of the module
      # @param guess [Integer] bytes to read when the buffer does not hold the length prefix
      # @return [String] the module
      # @raise [FormatError] when the module overruns the file
      def read_module(pos, guess)
        buf, off = window(pos, guess, 4)
        len = buf.bytesize - off >= 4 && buf.byteslice(off, 4).unpack1("V")
        raise FormatError, "Column #{@column.dotted_path}: encrypted page header overruns the file" unless len
        buf, off = window(pos, 4 + len + READ_AHEAD, 4 + len)
        if buf.bytesize - off < 4 + len
          raise FormatError, "Column #{@column.dotted_path}: encrypted page header overruns the file"
        end
        buf.byteslice(off, 4 + len)
      end

      # Returns [buffer, offset] where buffer[offset..] holds at least +need+ bytes from file
      # position +pos+ (fewer only at EOF), reading +len+ bytes when the buffer does not cover it.
      #
      # @param pos [Integer] file offset wanted
      # @param len [Integer] bytes to read when the buffer has to be refilled
      # @param need [Integer] bytes that must be available from +pos+ to reuse the buffer
      # @return [Array(String, Integer)] binary buffer and the offset of +pos+ in it
      def window(pos, len, need = len)
        off = pos - @buf_pos
        return [@buf, off] if off >= 0 && off + need <= @buf.bytesize
        @io.seek(pos)
        @buf = @io.read(len) || "".b
        @buf.force_encoding(Encoding::BINARY)
        @buf_pos = pos
        [@buf, 0]
      end

      # Decompresses a page body with the chunk's codec
      #
      # @param body [String] compressed bytes
      # @param size [Integer] uncompressed size from the page header
      # @return [String] uncompressed bytes
      # @raise [UnsupportedError] for an unsupported codec, naming the column
      def decompress(body, size)
        Compression.decompress(@meta.codec, body, size)
      rescue UnsupportedError => e
        raise e, "#{e.message} (column #{@column.dotted_path})"
      end

      # Decodes a dictionary page (always PLAIN) and keeps its converted values
      #
      # @param header [Format::PageHeader] the dictionary page header
      # @param body [String] the compressed page body
      # @return [Array] the dictionary values
      def read_dictionary(header, body)
        dh = header.dictionary_page_header
        data = decompress(body, header.uncompressed_page_size)
        vals, = Encodings::Plain.decode(data, 0, dh.num_values, @column.type, @column.type_length)
        vals.map!(&@converter) if @converter
        @dictionary = vals
      end

      # A DATA_PAGE: the whole body is compressed, levels come first with their own length prefix
      #
      # @param header [Format::PageHeader] the data page header
      # @param body [String] the compressed page body
      # @return [PageStream::Page] the page, decoded on demand
      def data_page_v1(header, body)
        dh = header.data_page_header
        n = dh.num_values
        data = decompress(body, header.uncompressed_page_size)
        pos = 0
        reps = defs = nil
        reps, pos = level_decoder(data, pos, dh.repetition_level_encoding, @max_rep, n) if @max_rep.positive?
        defs, pos = level_decoder(data, pos, dh.definition_level_encoding, @max_def, n) if @max_def.positive?
        values, conv = value_decoder(data, pos, dh.encoding)
        PageStream::Page.new(n, defs, reps, values, conv)
      end

      # A DATA_PAGE_V2: levels are stored uncompressed before the (optionally compressed) values
      #
      # @param header [Format::PageHeader] the data page header
      # @param body [String] the page body
      # @return [PageStream::Page] the page, decoded on demand
      def data_page_v2(header, body)
        dh = header.data_page_header_v2
        n = dh.num_values
        rep_len = dh.repetition_levels_byte_length
        def_len = dh.definition_levels_byte_length
        reps = defs = nil
        reps = PageStream::HybridDecoder.new(body, 0, rep_len, @max_rep.bit_length) if @max_rep.positive?
        defs = PageStream::HybridDecoder.new(body, rep_len, rep_len + def_len, @max_def.bit_length) if @max_def.positive?
        data = body.byteslice(rep_len + def_len, body.bytesize - rep_len - def_len)
        if dh.is_compressed != false
          data = decompress(data, header.uncompressed_page_size - rep_len - def_len)
        end
        values, conv = value_decoder(data, 0, dh.encoding)
        PageStream::Page.new(n, defs, reps, values, conv)
      end

      # [decoder, position after the levels]
      #
      # @param data [String] the uncompressed page
      # @param pos [Integer] offset of the levels in +data+
      # @param encoding [Integer] Format::Encoding of the levels (RLE or BIT_PACKED)
      # @param max [Integer] max level of the column, which sets the bit width
      # @param n [Integer] number of entries in the page
      # @return [Array(PageStream::HybridDecoder, Integer), Array(PageStream::ArrayDecoder, Integer)]
      #   the decoder and the offset just past the levels
      # @raise [FormatError] when the RLE length prefix is cut off
      # @raise [UnsupportedError] for any other level encoding
      def level_decoder(data, pos, encoding, max, n)
        width = max.bit_length
        case encoding
        when E::RLE
          len = data.byteslice(pos, 4)&.unpack1("V") or raise FormatError, "Truncated levels"
          start = pos + 4
          [PageStream::HybridDecoder.new(data, start, start + len, width), start + len]
        when E::BIT_PACKED
          levels = Encodings::RLE.decode_legacy_bit_packed(data, pos, width, n)
          [PageStream::ArrayDecoder.new(levels), pos + (n * width + 7) / 8]
        else
          raise UnsupportedError, "Unsupported level encoding #{E::NAMES[encoding] || encoding}"
        end
      end

      # Physical type => [String#unpack directive, byte width] for PLAIN fixed-width values
      FIXED_FORMATS = Ractor.make_shareable({
        T::INT32 => ["l<", 4], T::INT64 => ["q<", 8], T::FLOAT => ["e", 4], T::DOUBLE => ["E", 8]
      })

      # [value decoder, converter still to apply to its values (nil for dictionary pages)]
      #
      # @param data [String] the uncompressed values section
      # @param pos [Integer] offset of the values in +data+
      # @param encoding [Integer] Format::Encoding of the values
      # @return [Array(Object, Proc)] a PageStream decoder (responds to #read) and the converter,
      #   which may be nil
      # @raise [FormatError] for a dictionary-encoded page in a chunk without a dictionary page
      # @raise [UnsupportedError] for an encoding not valid for the column's type, or unknown
      def value_decoder(data, pos, encoding)
        type = @column.type
        decoder = case encoding
        when E::PLAIN
          case type
          when T::BOOLEAN then PageStream::BooleanDecoder.new(data, pos)
          when T::INT96 then PageStream::Int96Decoder.new(data, pos)
          when T::BYTE_ARRAY then PageStream::ByteArrayDecoder.new(data, pos)
          when T::FIXED_LEN_BYTE_ARRAY then PageStream::FixedBytesDecoder.new(data, pos, @column.type_length)
          else PageStream::FixedDecoder.new(data, pos, *FIXED_FORMATS.fetch(type))
          end
        when E::PLAIN_DICTIONARY, E::RLE_DICTIONARY
          raise FormatError, "Dictionary-encoded page without a dictionary in #{@column.dotted_path}" unless @dictionary
          # Dictionary values are converted once, when the dictionary page is read
          return [PageStream::DictionaryDecoder.new(data, pos, @dictionary, @column.dotted_path), nil]
        when E::RLE
          raise UnsupportedError, "RLE value encoding is only supported for BOOLEAN" unless type == T::BOOLEAN
          PageStream::RleBooleanDecoder.new(data, pos)
        when E::DELTA_BINARY_PACKED
          bits = (type == T::INT32) ? 32 : 64
          PageStream::ArrayDecoder.new(Encodings::Delta.decode_binary_packed(data, pos, bits).first)
        when E::DELTA_LENGTH_BYTE_ARRAY
          PageStream::DeltaLengthDecoder.new(data, pos)
        when E::DELTA_BYTE_ARRAY
          PageStream::DeltaByteArrayDecoder.new(data, pos)
        when E::BYTE_STREAM_SPLIT
          width = case type
          when T::INT32, T::FLOAT then 4
          when T::INT64, T::DOUBLE then 8
          when T::FIXED_LEN_BYTE_ARRAY then @column.type_length
          else raise UnsupportedError, "BYTE_STREAM_SPLIT is not valid for #{T::NAMES[type]}"
          end
          PageStream::ByteStreamSplitDecoder.new(data, pos, width, type, @column.type_length)
        else
          raise UnsupportedError, "Unsupported encoding #{E::NAMES[encoding] || encoding}"
        end
        [decoder, @converter]
      end
    end
  end
end
