# frozen_string_literal: true

require "json"
require "zlib"

module Herringbone
  # Examines a Parquet file using only its footer, page headers and page indexes. Values are
  # never decompressed or decoded, so this works for files whose codecs are not installed and
  # stays fast for big files (it seeks from page header to page header).
  #
  #   File.open("data.parquet", "rb") do |io|
  #     inspector = Herringbone::Inspector.new(io)
  #     inspector.summary                        # => { file_size:, num_rows:, codecs:, ... }
  #     inspector.row_groups[0].column("name").pages
  #     inspector.to_h                           # everything, JSON-serializable
  #     puts inspector.report                    # readable text (bin/herringbone inspect)
  #     html = inspector.to_html                 # self-contained HTML page (see Visualizer)
  #   end
  #
  # Page headers and indexes are read lazily; #load_all reads them all up front, after which the
  # inspector no longer needs the IO. The IO is never closed. After #verify_checksums, page CRC
  # results are included in every output.
  class Inspector
    # Shorthand for the Parquet physical type constants
    T = Format::Type
    # Magic bytes at the start and end of every (unencrypted) Parquet file
    MAGIC = "PAR1"
    # Size of the read-ahead window used by #read_at, in bytes
    WINDOW = 64 * 1024

    # Just enough of parquet.thrift's BloomFilterHeader to learn the filter's size
    class BloomFilterHeader < Thrift::Struct
      field 1, :num_bytes, :i32
    end

    # Decoded min/max statistics (from a column chunk, a page header or a page index entry).
    # +min+/+max+ are converted with the column's type converter (hex Strings when they could
    # not be decoded); +min_exact+/+max_exact+ mirror is_min_value_exact/is_max_value_exact;
    # +source+ says which Thrift fields they came from and +caveat+ why they may be unreliable.
    Stats = Struct.new(:min, :max, :null_count, :distinct_count, :min_exact, :max_exact, :source, :caveat,
      keyword_init: true) do
      # @return [Hash{Symbol => Object}] the set members, JSON-safe (see Inspector.jsonable)
      def to_h = Inspector.jsonable(super.compact)
    end

    # One page header of a column chunk. +checksum+ is nil until the CRCs are verified
    # (Inspector#verify_checksums), then :ok, :mismatch or :absent (the page has no CRC);
    # +actual_crc+ is then the CRC32 of the page's stored bytes (nil when it has no CRC).
    # +index+ is the page's position in the chunk, +offset+ where its header starts; +type+ is
    # a PageType name such as :DATA_PAGE (the raw Integer when unknown). +first_row_index+ and,
    # for v1 pages of repeated columns, +num_rows+ are only known from the OffsetIndex.
    PageInfo = Struct.new(:index, :type, :offset, :header_size, :compressed_size, :uncompressed_size,
      :num_values, :num_nulls, :num_rows, :first_row_index, :encoding, :definition_level_encoding,
      :repetition_level_encoding, :definition_levels_byte_length, :repetition_levels_byte_length,
      :is_compressed, :is_sorted, :statistics, :crc, :checksum, :actual_crc, keyword_init: true) do
      # @return [Integer] bytes taken by the page in the file: header plus compressed body
      def total_size = header_size + compressed_size

      # @return [Integer] file offset just past the page's body
      def end_offset = offset + total_size

      # @return [Integer] file offset where the page's body (after the header) starts
      def body_offset = offset + header_size

      # @return [Boolean] whether this is a dictionary page
      def dictionary? = type == :DICTIONARY_PAGE

      # @return [Boolean] whether this is a v1 or v2 data page
      def data? = type == :DATA_PAGE || type == :DATA_PAGE_V2

      # The CRC from the header as an unsigned 32-bit value (Thrift stores it as a signed i32)
      # @return [Integer, nil] nil when the header has no CRC
      def expected_crc = crc && (crc & 0xFFFF_FFFF)

      # @return [Hash{Symbol => Object}] the set members, JSON-safe; +:crc+ becomes a Boolean
      #   saying whether the header has a CRC, +:actual_crc+ is left out
      def to_h
        h = super
        h.delete(:actual_crc)
        h[:statistics] = statistics&.to_h
        h[:crc] = !crc.nil?
        Inspector.jsonable(h.compact)
      end
    end

    # ColumnIndex of one column chunk, with min/max decoded per page (nil for all-null pages)
    ColumnIndexInfo = Struct.new(:offset, :length, :null_pages, :min_values, :max_values, :boundary_order,
      :null_counts, :repetition_level_histograms, :definition_level_histograms, keyword_init: true) do
      # @return [Hash{Symbol => Object}] the set members, JSON-safe (see Inspector.jsonable)
      def to_h = Inspector.jsonable(super.compact)
    end

    # One OffsetIndex entry: where a data page starts, its size (header included) and the index
    # of its first row within the row group
    PageLocation = Struct.new(:offset, :compressed_page_size, :first_row_index, keyword_init: true)

    # OffsetIndex of one column chunk: its own +offset+/+length+ in the file, the PageLocations
    # of its data pages and the optional per-page unencoded BYTE_ARRAY sizes
    OffsetIndexInfo = Struct.new(:offset, :length, :page_locations, :unencoded_byte_array_data_bytes,
      keyword_init: true) do
      # @return [Hash{Symbol => Object}] the set members, with +:page_locations+ as Hashes
      def to_h
        h = super
        h[:page_locations] = page_locations.map(&:to_h)
        h.compact
      end
    end

    # One column chunk of a row group
    class ColumnChunkInfo
      attr_reader :inspector, :row_group, :column, :chunk, :meta, :error

      # @param inspector [Inspector] owner, used to read page headers and indexes lazily
      # @param row_group [RowGroupInfo] row group the chunk belongs to
      # @param column [Schema::Column] leaf column the chunk stores
      # @param chunk [Format::ColumnChunk] chunk as decoded from the footer
      def initialize(inspector, row_group, column, chunk)
        @inspector = inspector
        @row_group = row_group
        @column = column
        @chunk = chunk
        # An encrypted footer leaves out the metadata of columns with their own key; without that
        # key nothing is known about the chunk
        @meta = chunk.meta_data || Format::ColumnMetaData.new(path_in_schema: column.path)
      end

      # @return [Boolean] whether the chunk is encrypted
      def encrypted? = !@chunk.crypto_metadata.nil?

      # Decryption of the chunk's modules (memoized)
      # @return [Encryption::ModuleCrypto, nil] nil when the chunk is not encrypted or its key was
      #   not given
      def crypto
        return @crypto if defined?(@crypto)
        @crypto = @inspector.chunk_crypto(self)
      end

      # How the chunk is encrypted, without its key
      # @return [Hash{Symbol => Object}, nil] { key: :footer or :column, key_metadata:, readable: },
      #   nil for a plaintext chunk
      def encryption
        c = @chunk.crypto_metadata or return nil
        with_column_key = c.encryption_with_column_key
        {key: with_column_key ? :column : :footer, key_metadata: with_column_key&.key_metadata, readable: !crypto.nil?}
      end

      # @return [String] dotted path of the column, e.g. +"address.city"+
      def path = @column.dotted_path

      # @return [Integer] position of the column among the schema's leaf columns
      def column_index_number = @column.index

      # @return [Symbol, Integer] codec name such as :SNAPPY (the raw Integer when unknown)
      def codec = Format::Codec::NAMES[@meta.codec] || @meta.codec

      # @return [Array<String>] encoding names listed in the column metadata
      def encodings = (@meta.encodings || []).map { |e| Inspector.encoding_name(e) }

      # @return [Integer] values in the chunk, nulls and repeated entries included
      def num_values = @meta.num_values

      # @return [Integer] total_compressed_size from the column metadata (page headers included)
      def compressed_size = @meta.total_compressed_size

      # @return [Integer] total_uncompressed_size from the column metadata (page headers included)
      def uncompressed_size = @meta.total_uncompressed_size

      # @return [Integer] offset of the first data page, as declared in the column metadata
      def data_page_offset = @meta.data_page_offset

      # @return [String, nil] path of the file holding the chunk when it is not stored in this one
      def external_file = @chunk.file_path

      # @return [Float, nil] uncompressed size divided by compressed size; nil when nothing is compressed
      def compression_ratio
        compressed_size.to_i.positive? ? uncompressed_size.to_f / compressed_size : nil
      end

      # Some writers store 0 when there is no dictionary page, and some store a data_page_offset
      # of 0 for empty chunks (which would point at the magic bytes)
      # @return [Integer, nil] the declared dictionary page offset, nil when absent or implausible
      def dictionary_page_offset
        d = @meta.dictionary_page_offset
        (d && d >= 4 && (d < @meta.data_page_offset.to_i || @meta.data_page_offset.to_i < 4)) ? d : nil
      end

      # Where the chunk's first page starts
      # @return [Integer, nil] file offset; nil when the chunk's metadata is encrypted and its key
      #   was not given
      def start_offset = dictionary_page_offset || data_page_offset

      # The end according to the metadata; some writers under-report it (see #end_offset)
      # @return [Integer, nil] file offset just past the chunk; nil when it is not known
      def declared_end_offset = start_offset && start_offset + compressed_size

      # The end of the last page actually found (the declared end if the pages could not be walked)
      # @return [Integer, nil] file offset just past the chunk, never before #declared_end_offset
      def end_offset
        last = pages.last
        last ? [last.end_offset, declared_end_offset].max : declared_end_offset
      end

      # Page counts per page type and encoding, from the column metadata's encoding_stats
      # @return [Array<Hash{Symbol => Object}>] each { page_type:, encoding:, count: }; empty when
      #   the writer stored none
      def encoding_stats
        (@meta.encoding_stats || []).map do |s|
          {page_type: Format::PageType::NAMES[s.page_type] || s.page_type,
           encoding: Inspector.encoding_name(s.encoding), count: s.count}
        end
      end

      # Chunk-level statistics from the column metadata, decoded (memoized)
      # @return [Stats, nil] nil when the chunk has no statistics
      def statistics
        return @statistics if defined?(@statistics)
        @statistics = @inspector.decode_statistics(@meta.statistics, @column)
      end

      # @return [Hash{Symbol => Object}, nil] the SizeStatistics (unencoded byte array sizes and
      #   level histograms) as a Hash, nil when absent
      def size_statistics
        s = @meta.size_statistics
        s&.to_h
      end

      # @return [Hash{String => String}] the chunk's own key/value metadata (rarely used by writers)
      def key_value_metadata
        (@meta.key_value_metadata || []).to_h { |kv| [kv.key, kv.value] }
      end

      # @return [Integer, nil] file offset of the chunk's bloom filter, nil when it has none
      def bloom_filter_offset = @meta.bloom_filter_offset

      # Bytes taken by the bloom filter (header + bitset); read from its header when the footer has no length
      # @return [Integer, nil] nil when there is no bloom filter or its header can't be decoded
      def bloom_filter_length
        return nil unless bloom_filter_offset
        return @meta.bloom_filter_length if @meta.bloom_filter_length
        return @bloom_filter_length if defined?(@bloom_filter_length)
        @bloom_filter_length = @inspector.bloom_filter_size(bloom_filter_offset, encrypted?)
      end

      # @return [Array(Integer, Integer), nil] [offset, length] of the chunk's ColumnIndex, nil when
      #   it has none
      def column_index_range
        o = @chunk.column_index_offset
        (o && @chunk.column_index_length) ? [o, @chunk.column_index_length] : nil
      end

      # @return [Array(Integer, Integer), nil] [offset, length] of the chunk's OffsetIndex, nil when
      #   it has none
      def offset_index_range
        o = @chunk.offset_index_offset
        (o && @chunk.offset_index_length) ? [o, @chunk.offset_index_length] : nil
      end

      # All page headers, in file order. Errors while walking (corrupt or truncated headers) end
      # the walk; #error then says what went wrong and #pages holds the pages found before it.
      # @return [Array<PageInfo>]
      def pages
        @pages ||= begin
          list, @error = @inspector.walk_pages(self)
          apply_offset_index(list)
          list
        end
      end

      # @return [Array<PageInfo>] the v1 and v2 data pages, in file order
      def data_pages = pages.select(&:data?)

      # @return [PageInfo, nil] the dictionary page, nil when the chunk has none
      def dictionary_page = pages.find(&:dictionary?)

      # Number of entries in the dictionary (from its page header)
      # @return [Integer, nil] nil when the chunk has no dictionary page
      def dictionary_size = dictionary_page&.num_values

      # The chunk's ColumnIndex, read and decoded on first use
      # @return [ColumnIndexInfo, nil] nil when there is none or it is corrupt
      def column_index
        return @column_index if defined?(@column_index)
        @column_index = @inspector.read_column_index(self)
      end

      # The chunk's OffsetIndex, read and decoded on first use
      # @return [OffsetIndexInfo, nil] nil when there is none or it is corrupt
      def offset_index
        return @offset_index if defined?(@offset_index)
        @offset_index = @inspector.read_offset_index(self)
      end

      # Null count from the chunk statistics, else the sum over the data page headers
      # @return [Integer, nil] nil when neither the statistics nor every data page has it, or the
      #   chunk is encrypted and its key was not given
      def null_count
        return statistics.null_count if statistics&.null_count
        return nil if encrypted? && !crypto
        counts = data_pages.map(&:num_nulls)
        counts.all? ? counts.sum : nil
      end

      # Reads every page body (compressed bytes, as stored) and checks it against the CRC in its
      # page header. Sets PageInfo#checksum on each page and returns the pages' statuses.
      # @return [Array<Symbol>] :ok, :mismatch or :absent per page, in #pages order
      def verify_checksums
        pages.map { |p| p.checksum = @inspector.page_checksum(p) }
      end

      # Page statistics (from page headers) that disagree with the ColumnIndex entry for the
      # same page. Each: { page:, data_page:, field:, page_value:, index_value: } where +page+
      # is the page's position in #pages, +data_page+ its position among the data pages (and
      # in the ColumnIndex), +field+ one of :min, :max, :null_count, :null_page, :page_count.
      # A ColumnIndex bound that is wider than the page's (e.g. a truncated string prefix) is
      # allowed; one that is narrower, or a differing null count, is reported. Empty when the
      # chunk has no ColumnIndex or its pages carry no statistics.
      # @return [Array<Hash{Symbol => Object}>]
      def index_mismatches
        @index_mismatches ||= @inspector.compare_page_index(self)
      end

      # Everything known about the chunk, including its pages and page indexes (reads them if
      # they were not read yet)
      # @return [Hash{Symbol => Object}] JSON-safe; keys without a value are left out
      def to_h
        Inspector.jsonable({
          path: path,
          column: @column.index,
          type: Inspector.type_name(@column),
          codec: codec,
          encodings: encodings,
          encoding_stats: encoding_stats,
          num_values: num_values,
          null_count: null_count,
          compressed_size: compressed_size,
          uncompressed_size: uncompressed_size,
          compression_ratio: compression_ratio&.round(4),
          file_offset: @chunk.file_offset,
          start_offset: start_offset,
          end_offset: end_offset,
          data_page_offset: data_page_offset,
          dictionary_page_offset: dictionary_page_offset,
          dictionary: dictionary_page && {offset: dictionary_page.offset, num_values: dictionary_page.num_values,
                                          compressed_size: dictionary_page.compressed_size, uncompressed_size: dictionary_page.uncompressed_size,
                                          is_sorted: dictionary_page.is_sorted},
          statistics: statistics&.to_h,
          size_statistics: size_statistics,
          key_value_metadata: key_value_metadata.empty? ? nil : key_value_metadata,
          bloom_filter: bloom_filter_offset && {offset: bloom_filter_offset, length: bloom_filter_length},
          column_index_offset: column_index_range&.first,
          column_index_length: column_index_range&.last,
          offset_index_offset: offset_index_range&.first,
          offset_index_length: offset_index_range&.last,
          external_file: external_file,
          encryption: encryption,
          num_pages: pages.size,
          num_data_pages: data_pages.size,
          index_mismatches: index_mismatches.empty? ? nil : index_mismatches,
          error: error,
          pages: pages.map(&:to_h),
          column_index: column_index&.to_h,
          offset_index: offset_index&.to_h
        }.compact)
      end

      # @return [String] short description: path, row group, codec and sizes
      def inspect
        "#<#{self.class.name} #{path} rg=#{@row_group.index} #{codec} #{compressed_size}/#{uncompressed_size} bytes>"
      end

      private

      # Page row counts come from the offset index when there is one (v1 pages don't carry them)
      # Sets +first_row_index+ on the data pages the index points at, and +num_rows+ where the
      # page header did not provide it.
      # @param list [Array<PageInfo>] pages of this chunk, updated in place
      # @return [void]
      def apply_offset_index(list)
        oi = offset_index or return
        by_offset = list.select(&:data?).to_h { |p| [p.offset, p] }
        locs = oi.page_locations
        locs.each_with_index do |loc, i|
          page = by_offset[loc.offset] or next
          page.first_row_index = loc.first_row_index
          next_first = locs[i + 1]&.first_row_index || @row_group.num_rows
          page.num_rows ||= next_first - loc.first_row_index
        end
      end
    end

    # One row group
    class RowGroupInfo
      attr_reader :index, :row_group, :columns

      # @param inspector [Inspector] owner, passed on to the column chunks
      # @param index [Integer] position of the row group in the file
      # @param row_group [Format::RowGroup] row group as decoded from the footer
      # @param first_row [Integer] file-wide index of the row group's first row
      # @raise [FormatError] when the row group has more column chunks than the schema has leaves
      def initialize(inspector, index, row_group, first_row)
        @index = index
        @row_group = row_group
        @first_row = first_row
        leaves = inspector.schema.columns
        @columns = (row_group.columns || []).each_with_index.map do |cc, i|
          column = leaves[i] or raise FormatError, "Row group #{index} has more column chunks than the schema has columns"
          ColumnChunkInfo.new(inspector, self, column, cc)
        end
      end

      # @return [Integer] rows in the row group
      def num_rows = @row_group.num_rows
      # @return [Integer] file-wide index of the row group's first row
      attr_reader :first_row

      # @return [Integer] total_byte_size from the footer (uncompressed size of all column data)
      def total_byte_size = @row_group.total_byte_size

      # @return [Integer] total_compressed_size from the footer, else the sum over the chunks
      def compressed_size = @row_group.total_compressed_size || @columns.sum(&:compressed_size)

      # @return [Integer] sum of the chunks' total_uncompressed_size
      def uncompressed_size = @columns.sum { |c| c.uncompressed_size.to_i }

      # @return [Integer, nil] lowest start offset of the row group's chunks; nil without chunks
      def start_offset = @columns.filter_map(&:start_offset).min

      # @return [Integer, nil] highest end offset of the row group's chunks; nil without chunks
      def end_offset = @columns.filter_map(&:end_offset).max

      # @param path [String, Array<String>] dotted path (+"a.b"+) or path segments (+["a", "b"]+)
      # @return [ColumnChunkInfo, nil] the chunk of that column, nil when there is none
      def column(path) = @columns.find { |c| c.path == path.to_s || c.column.path == Array(path) }

      # The row group's declared sort order
      # @return [Array<Hash{Symbol => Object}>] each { column:, descending:, nulls_first: }, where
      #   +column+ is the column's path (its index when out of range)
      def sorting_columns
        (@row_group.sorting_columns || []).map do |s|
          {column: @columns[s.column_idx]&.path || s.column_idx, descending: s.descending, nulls_first: s.nulls_first}
        end
      end

      # Everything known about the row group, with each column chunk's #to_h
      # @return [Hash{Symbol => Object}] JSON-safe; keys without a value are left out
      def to_h
        Inspector.jsonable({
          index: index,
          ordinal: @row_group.ordinal,
          num_rows: num_rows,
          first_row: first_row,
          total_byte_size: total_byte_size,
          compressed_size: compressed_size,
          uncompressed_size: uncompressed_size,
          file_offset: @row_group.file_offset,
          start_offset: start_offset,
          end_offset: end_offset,
          sorting_columns: sorting_columns,
          columns: @columns.map(&:to_h)
        }.compact)
      end

      # @return [String] short description: index, row count and number of columns
      def inspect
        "#<#{self.class.name} #{index} rows=#{num_rows} columns=#{@columns.size}>"
      end
    end

    attr_reader :metadata, :schema, :file_size, :footer_size

    # A label for the file (the basename of the IO's path, when it has one)
    attr_reader :name

    # +io+ is a random-access IO (responds to #seek and #read, e.g. File.open(path, "rb")). It is
    # left open.
    #
    # An encrypted file needs +decryption:+ (see Reader.new) when its footer is encrypted. With a
    # plaintext footer it opens without keys, and the chunks whose key is missing are shown
    # without their pages, page indexes and statistics.
    #
    # @param io [IO] random-access IO positioned anywhere; only the footer is read here
    # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, nil] keys of an encrypted file, see Reader.new
    # @raise [ArgumentError] when +io+ does not support #seek and #read
    # @raise [FormatError] when the file is too small, lacks the magic bytes or has a corrupt footer
    # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted
    def initialize(io, decryption: nil)
      @io = io
      @decryption = decryption.nil? ? nil : DecryptionConfiguration.from(decryption)
      unless @io.respond_to?(:read) && @io.respond_to?(:seek)
        raise ArgumentError, "Herringbone::Inspector expects an IO that supports #seek and #read " \
          "(e.g. File.open(path, \"rb\")), got #{io.class}"
      end
      @name = (@io.respond_to?(:path) && @io.path) ? File.basename(@io.path.to_s) : nil
      read_footer
      @schema = Schema.from_elements(@metadata.schema)
    end

    # @return [Integer] row count declared in the footer
    def num_rows = @metadata.num_rows

    # @return [String, nil] the writer's created_by string, e.g. +"parquet-cpp-arrow version 15.0.0"+
    def created_by = @metadata.created_by

    # @return [Integer] format version from the footer (1 or 2; says little about the features used)
    def version = @metadata.version

    # @return [Array<Schema::Column>] the schema's leaf columns
    def columns = @schema.columns

    # @return [Integer] file offset where the Thrift-encoded FileMetaData starts
    def footer_offset = @file_size - 8 - @footer_size

    # @return [Array<RowGroupInfo>] the row groups, in footer order (built on first use)
    def row_groups
      @row_groups ||= begin
        first = 0
        (@metadata.row_groups || []).each_with_index.map do |rg, i|
          info = RowGroupInfo.new(self, i, rg, first)
          first += rg.num_rows.to_i
          info
        end
      end
    end

    # @return [Array<ColumnChunkInfo>] the column chunks of all row groups, row group by row group
    def column_chunks = row_groups.flat_map(&:columns)

    # Walks every page header and page index now (e.g. before closing the file)
    # @return [Inspector] self
    def load_all
      column_chunks.each do |c|
        c.pages
        c.column_index
        c.offset_index
        c.bloom_filter_length
      end
      self
    end

    # @return [Boolean] whether any column chunk has a ColumnIndex or an OffsetIndex
    def page_index? = column_chunks.any? { |c| c.column_index_range || c.offset_index_range }

    # @return [Boolean] whether any column chunk has a bloom filter
    def bloom_filters? = column_chunks.any?(&:bloom_filter_offset)

    # How the file is encrypted (see Reader#encryption), nil for a file that is not
    # @return [Hash{Symbol => Object}, nil] +:algorithm+, +:footer+, +:footer_key_metadata+,
    #   +:aad_prefix+, +:supply_aad_prefix+, +:footer_verified+ and +:columns+ (path => { key:,
    #   key_metadata:, readable: } for the encrypted columns of the first row group)
    def encryption = @decryptor&.describe(@schema, @metadata.row_groups&.first&.columns || [])

    # The file-level key/value metadata, each entry described: ARROW:schema is decoded, JSON
    # values are parsed (pandas metadata summarized), binary values are shown as hex
    # @return [Array<Hash{Symbol => Object}>] each with :key, :bytesize, :format ("arrow_schema",
    #   "json", "text" or "binary"), :value (truncated) and, depending on the format, :summary,
    #   :json, :arrow_schema, :arrow_fields, :arrow_error
    def key_value_metadata
      (@metadata.key_value_metadata || []).map { |kv| describe_key_value(kv.key, kv.value) }
    end

    # @return [Array<String>, nil] "TYPE_DEFINED_ORDER" or "UNKNOWN" per leaf column; nil when the
    #   footer has no column_orders
    def column_orders
      orders = @metadata.column_orders or return nil
      orders.map { |o| o.type_order ? "TYPE_DEFINED_ORDER" : "UNKNOWN" }
    end

    # File-wide facts: sizes, row and column counts, codecs, whether page indexes and bloom
    # filters are present, and (after #verify_checksums) the CRC tallies under :checksums.
    # Walks no page headers.
    # @return [Hash{Symbol => Object}]
    def summary
      codecs = column_chunks.filter_map(&:codec).uniq
      {
        name: @name,
        file_size: @file_size,
        footer_size: @footer_size,
        footer_offset: footer_offset,
        format_version: version,
        created_by: created_by,
        num_rows: num_rows,
        num_row_groups: row_groups.size,
        num_columns: columns.size,
        codecs: codecs,
        compressed_size: column_chunks.sum { |c| c.compressed_size.to_i },
        uncompressed_size: column_chunks.sum { |c| c.uncompressed_size.to_i },
        page_index: page_index?,
        bloom_filters: bloom_filters?,
        column_orders: column_orders,
        encryption: encryption
      }.tap { |h| h[:checksums] = checksum_summary.except(:mismatches) if checksums_verified? }
    end

    # Reads every page body and checks it against the CRC32 in its page header (the CRC covers
    # the page data as stored: compressed, and for v2 pages the levels plus the compressed
    # values). Nothing is decompressed. Sets PageInfo#checksum on every page and returns
    # #checksum_summary. Needs the IO, so call it before closing the file.
    # @return [Hash{Symbol => Object}] see #checksum_summary
    def verify_checksums
      column_chunks.each(&:verify_checksums)
      @checksums_verified = true
      checksum_summary
    end

    # @return [Boolean] whether #verify_checksums has run
    def checksums_verified? = @checksums_verified == true

    # After #verify_checksums: { ok:, mismatch:, absent:, mismatches: [{ row_group:, column:, page:, type:, offset:, crc:, actual: }] }
    # The counts are pages per status; in each mismatch +crc+ is the CRC from the page header and
    # +actual+ the CRC32 of the stored bytes (kept from the verification, so the IO is not needed).
    # @return [Hash{Symbol => Object}, nil] nil before #verify_checksums
    def checksum_summary
      return nil unless checksums_verified?
      all = column_chunks.flat_map { |c| c.pages.map { |p| [c, p] } }
      tally = all.map { |_, p| p.checksum }.tally
      {
        ok: tally.fetch(:ok, 0), mismatch: tally.fetch(:mismatch, 0), absent: tally.fetch(:absent, 0),
        mismatches: all.select { |_, p| p.checksum == :mismatch }.map do |c, p|
          {row_group: c.row_group.index, column: c.path, page: p.index, type: p.type, offset: p.offset,
           crc: p.expected_crc, actual: p.actual_crc}
        end
      }
    end

    # Every disagreement between page header statistics and the ColumnIndex, across the file,
    # each with :row_group and :column added (see ColumnChunkInfo#index_mismatches)
    # @return [Array<Hash{Symbol => Object}>]
    def index_mismatches
      column_chunks.flat_map do |c|
        c.index_mismatches.map { |m| {row_group: c.row_group.index, column: c.path}.merge(m) }
      end
    end

    # The decoded ARROW:schema key/value (see ArrowSchema.decode); nil when the file has none or
    # it could not be decoded, and #arrow_schema_error then says why
    # @return [Hash{Symbol => Object}, nil] see ArrowSchema.decode
    def arrow_schema
      return @arrow_schema if defined?(@arrow_schema)
      @arrow_schema_error = nil
      kv = (@metadata.key_value_metadata || []).find { |x| x.key == "ARROW:schema" }
      @arrow_schema = kv && begin
        ArrowSchema.decode(kv.value)
      rescue => e
        @arrow_schema_error = "could not decode ARROW:schema: #{e.message}"
        nil
      end
    end

    # @return [String, nil] why the ARROW:schema value could not be decoded; nil when it decoded
    #   fine or the file has none
    def arrow_schema_error
      arrow_schema
      @arrow_schema_error
    end

    # Schema tree: Hashes with name, repetition, types, levels (leaves) and children (groups)
    # Nodes that match a field of the ARROW:schema also get its type as :arrow_type.
    # @return [Array<Hash{Symbol => Object}>] the root's children
    def schema_tree
      leaf_by_node = @schema.columns.to_h { |c| [c.node, c] }
      build = lambda do |node|
        h = {name: node.name, repetition: node.repetition}
        if node.leaf?
          col = leaf_by_node[node]
          h[:physical_type] = T::NAMES[node.type]&.to_s
          h[:type_length] = node.type_length
          h[:column] = col.index
          h[:path] = col.dotted_path
          h[:max_definition_level] = col.max_definition_level
          h[:max_repetition_level] = col.max_repetition_level
        end
        h[:logical_type] = Inspector.logical_type_name(node)
        h[:converted_type] = Format::ConvertedType::NAMES[node.converted_type]&.to_s
        h[:field_id] = node.field_id
        h[:children] = node.children.map { |c| build.call(c) } if node.group?
        h.compact
      end
      tree = @schema.root.children.map { |c| build.call(c) }
      annotate_arrow_types(tree, arrow_schema[:fields]) if arrow_schema
      tree
    end

    # Per leaf column: sums over all row groups, plus overall min/max where comparable
    # Walks every page header (for the page counts).
    # @return [Array<Hash{Symbol => Object}>] one per leaf column, in schema order
    def column_totals
      columns.map do |col|
        chunks = row_groups.map { |rg| rg.columns[col.index] }.compact
        compressed = chunks.sum { |c| c.compressed_size.to_i }
        uncompressed = chunks.sum { |c| c.uncompressed_size.to_i }
        nulls = chunks.map(&:null_count)
        stats = chunks.map(&:statistics)
        mins = stats.map { |s| s&.min }
        maxes = stats.map { |s| s&.max }
        {
          column: col.index,
          path: col.dotted_path,
          type: Inspector.type_name(col),
          codecs: chunks.filter_map(&:codec).uniq,
          encodings: chunks.flat_map(&:encodings).uniq,
          num_values: chunks.sum { |c| c.num_values.to_i },
          null_count: nulls.all? ? nulls.sum : nil,
          compressed_size: compressed,
          uncompressed_size: uncompressed,
          compression_ratio: compressed.positive? ? (uncompressed.to_f / compressed).round(4) : nil,
          num_pages: chunks.sum { |c| c.pages.size },
          num_data_pages: chunks.sum { |c| c.data_pages.size },
          dictionary_pages: chunks.count(&:dictionary_page),
          dictionary_bytes: chunks.sum { |c| c.dictionary_page&.total_size.to_i },
          min: mins.include?(nil) ? nil : safe_extreme(mins, :min),
          max: maxes.include?(nil) ? nil : safe_extreme(maxes, :max),
          metadata_unavailable: (!chunks.empty? && chunks.none?(&:start_offset)) || nil
        }.compact
      end
    end

    # Byte ranges of the whole file, in offset order: magic, pages (or whole chunks when their pages
    # could not be walked), bloom filters, page indexes, footer. Gaps right after a chunk at its
    # file_offset are inline :column_metadata copies; other gaps are reported as :unknown. Each entry: { kind:, start:, length:, row_group:, column:, page: }
    # +row_group+, +column+ and +page+ are indexes, present only where they apply. Segments can
    # overlap when the file is damaged; gaps are only computed past the furthest end seen so far.
    # @return [Array<Hash{Symbol => Object}>]
    def layout
      segs = [{kind: :magic, start: 0, length: 4}]
      column_chunks.each do |c|
        rg = c.row_group.index
        col = c.column.index
        if c.pages.empty?
          next unless c.start_offset
          segs << {kind: :chunk, start: c.start_offset, length: c.compressed_size, row_group: rg, column: col}
        else
          c.pages.each_with_index do |p, i|
            segs << {kind: p.dictionary? ? :dictionary_page : :data_page, start: p.offset, length: p.total_size,
                      row_group: rg, column: col, page: i}
          end
        end
        if c.bloom_filter_offset
          segs << {kind: :bloom_filter, start: c.bloom_filter_offset, length: c.bloom_filter_length.to_i,
                    row_group: rg, column: col}
        end
        if (r = c.column_index_range)
          segs << {kind: :column_index, start: r[0], length: r[1], row_group: rg, column: col}
        end
        if (r = c.offset_index_range)
          segs << {kind: :offset_index, start: r[0], length: r[1], row_group: rg, column: col}
        end
      end
      segs << {kind: :footer, start: footer_offset, length: @footer_size}
      segs << {kind: :footer_length, start: @file_size - 8, length: 4}
      segs << {kind: :magic, start: @file_size - 4, length: 4}
      segs.sort_by! { |s| s[:start] }
      # Some writers (old parquet-rs, parquet-mr for a while) store a copy of the ColumnMetaData
      # right after the chunk, at ColumnChunk.file_offset
      meta_copies = column_chunks.each_with_object({}) do |c, h|
        fo = c.chunk.file_offset
        h[fo] = c if fo && c.end_offset && fo >= c.end_offset
      end
      out = []
      pos = 0
      segs.each do |s|
        if s[:start] > pos
          c = meta_copies[pos]
          out << if c
            {kind: :column_metadata, start: pos, length: s[:start] - pos, row_group: c.row_group.index, column: c.column.index}
          else
            {kind: :unknown, start: pos, length: s[:start] - pos}
          end
        end
        out << s
        pos = [pos, s[:start] + s[:length]].max
      end
      out
    end

    # Everything: summary, key/value metadata, schema tree, row groups with their chunks and
    # pages, column totals, and any checksum and page index mismatches. Walks every page header.
    # @return [Hash{Symbol => Object}] JSON-safe; keys without a value are left out
    def to_h
      Inspector.jsonable({
        summary: summary,
        key_value_metadata: key_value_metadata,
        schema: schema_tree,
        row_groups: row_groups.map(&:to_h),
        column_totals: column_totals,
        checksum_mismatches: checksum_summary&.fetch(:mismatches),
        index_mismatches: index_mismatches
      }.compact)
    end

    # @param args [Array] passed on to Hash#to_json (e.g. a JSON::State)
    # @return [String] #to_h as JSON
    def to_json(*args) = to_h.to_json(*args)

    # A self-contained HTML page showing the file's layout, see Visualizer
    # @return [String] HTML document
    def to_html = Visualizer.new(self).to_html

    # Readable text summary. With pages: true, lists every page header too.
    # @param pages [Boolean] whether to add a line per page header under each column chunk
    # @return [String] multi-line text, as printed by +bin/herringbone inspect+
    def report(pages: false)
      s = summary
      out = []
      out << "file: #{@name || "(IO)"}"
      out << "size: #{Inspector.human_bytes(s[:file_size])} (#{s[:file_size]} bytes), footer #{s[:footer_size]} bytes at #{s[:footer_offset]}"
      out << "rows: #{s[:num_rows]}, row groups: #{s[:num_row_groups]}, columns: #{s[:num_columns]}, format version #{s[:format_version]}"
      out << "created by: #{s[:created_by]}"
      out << "codecs: #{s[:codecs].join(", ")}; data #{Inspector.human_bytes(s[:compressed_size])} compressed, " \
        "#{Inspector.human_bytes(s[:uncompressed_size])} uncompressed#{ratio_text(s[:uncompressed_size], s[:compressed_size])}"
      out << "page index: #{s[:page_index] ? "yes" : "no"}, bloom filters: #{s[:bloom_filters] ? "yes" : "no"}"
      if (e = s[:encryption])
        out << "encryption: #{e[:algorithm]}, #{e[:footer]} footer" \
          "#{" (signature verified)" if e[:footer_verified]}" \
          "#{", footer key metadata #{Inspector.display(e[:footer_key_metadata])}" if e[:footer_key_metadata]}" \
          "#{", AAD prefix #{Inspector.display(e[:aad_prefix])}" if e[:aad_prefix]}" \
          "#{", AAD prefix not stored" if e[:supply_aad_prefix]}"
        e[:columns].each do |path, c|
          out << "  #{path}: #{c[:key]} key#{" #{Inspector.display(c[:key_metadata])}" if c[:key_metadata]}" \
            "#{" (no key given)" unless c[:readable]}"
        end
      end
      if (cs = checksum_summary)
        out << "page CRCs: #{cs[:ok]} ok, #{cs[:mismatch]} mismatched, #{cs[:absent]} without a CRC"
        cs[:mismatches].each do |m|
          out << "  CRC MISMATCH: row group #{m[:row_group]} #{m[:column]} page #{m[:page]} (#{m[:type]} @#{m[:offset]}): " \
            "header says #{format("%08x", m[:crc])}, data has #{format("%08x", m[:actual])}"
        end
      end
      mismatches = index_mismatches
      unless mismatches.empty?
        out << "page statistics vs column index: #{mismatches.size} disagreement#{"s" unless mismatches.size == 1}"
        mismatches.first(50).each { |m| out << "  #{index_mismatch_text(m)}" }
        out << "  ..." if mismatches.size > 50
      end
      kvs = key_value_metadata
      unless kvs.empty?
        out << "key/value metadata:"
        kvs.each do |kv|
          out << "  #{kv[:key]} (#{kv[:format]}, #{kv[:bytesize]} bytes): #{kv[:summary] || kv[:value].to_s[0, 80].inspect}"
          out << "    #{kv[:arrow_error]}" if kv[:arrow_error]
          ArrowSchema.lines(kv[:arrow_schema][:fields]).each { |l| out << "    #{l}" } if kv[:arrow_schema]
        end
      end
      out << "schema:"
      walk = lambda do |n, depth|
        type = n[:children] ? "group" : [n[:physical_type], n[:type_length] && "(#{n[:type_length]})"].compact.join
        ann = n[:logical_type] || n[:converted_type]
        levels = n[:children] ? "" : "  [def #{n[:max_definition_level]}, rep #{n[:max_repetition_level]}]"
        arrow = n[:arrow_type] ? "  arrow: #{n[:arrow_type]}" : ""
        out << "#{"  " * depth}#{n[:repetition]} #{type} #{n[:name]}#{" (#{ann})" if ann}#{levels}#{arrow}"
        (n[:children] || []).each { |c| walk.call(c, depth + 1) }
      end
      schema_tree.each { |n| walk.call(n, 1) }
      out << "columns:"
      column_totals.each do |t|
        if t[:metadata_unavailable]
          out << "  #{t[:path]}: #{t[:type]} encrypted, metadata unavailable without its key"
          next
        end
        range = t.key?(:min) ? "  [#{Inspector.display(t[:min])} .. #{Inspector.display(t[:max])}]" : ""
        out << "  #{t[:path]}: #{t[:type]} #{t[:codecs].join(",")} #{t[:encodings].join(",")} " \
          "#{Inspector.human_bytes(t[:compressed_size])}/#{Inspector.human_bytes(t[:uncompressed_size])}" \
          "#{ratio_text(t[:uncompressed_size], t[:compressed_size])}, #{t[:num_values]} values" \
          "#{", #{t[:null_count]} nulls" if t[:null_count]}, #{t[:num_data_pages]} data pages#{range}"
      end
      row_groups.each do |rg|
        sorting = rg.sorting_columns.map { |c| "#{c[:column]}#{" desc" if c[:descending]}" }
        out << "row group #{rg.index}: #{rg.num_rows} rows, #{Inspector.human_bytes(rg.compressed_size)} " \
          "at #{rg.start_offset}..#{rg.end_offset}#{", sorted by #{sorting.join(", ")}" unless sorting.empty?}"
        rg.columns.each do |c|
          st = c.statistics
          range = (st && !(st.min.nil? && st.max.nil?)) ? " [#{Inspector.display(st.min)} .. #{Inspector.display(st.max)}]" : ""
          extras = []
          extras << "dict #{c.dictionary_size} entries" if c.dictionary_page
          extras << "column index" if c.column_index_range
          extras << "offset index" if c.offset_index_range
          extras << "bloom filter" if c.bloom_filter_offset
          extras << "encrypted" if c.encrypted?
          extras << "ERROR: #{c.error}" if c.error
          unless c.start_offset
            out << "  #{c.path}: encrypted, metadata and pages unavailable without its key"
            next
          end
          out << "  #{c.path}: #{c.codec} #{c.encodings.join(",")} " \
            "#{c.compressed_size}/#{c.uncompressed_size} bytes#{ratio_text(c.uncompressed_size, c.compressed_size)}, " \
            "#{c.num_values} values, #{c.pages.size} pages#{", #{extras.join(", ")}" unless extras.empty?}#{range}"
          next unless pages
          c.pages.each do |p|
            st = p.statistics
            out << "    #{p.index}: #{p.type} @#{p.offset} header #{p.header_size} + #{p.compressed_size}/#{p.uncompressed_size} bytes, " \
              "#{p.num_values} values#{", #{p.num_nulls} nulls" if p.num_nulls}#{", #{p.num_rows} rows" if p.num_rows}" \
              "#{" #{p.encoding}" if p.encoding}#{crc_text(p)}" \
              "#{" [#{Inspector.display(st.min)} .. #{Inspector.display(st.max)}]" if st && !(st.min.nil? && st.max.nil?)}"
          end
        end
      end
      out.join("\n")
    end

    # @return [String] short description: name, rows, row group count and file size
    def inspect
      "#<#{self.class.name} #{@name || "(IO)"} rows=#{num_rows} row_groups=#{row_groups.size} size=#{@file_size}>"
    end

    # ---- used by the info objects ----

    # Decryption of an encrypted chunk's modules
    # @param chunk [ColumnChunkInfo] an encrypted chunk
    # @return [Encryption::ModuleCrypto, nil] nil when the chunk's key was not given
    def chunk_crypto(chunk)
      @decryptor&.chunk(chunk.row_group.index, chunk.row_group.row_group.ordinal, chunk.column, chunk.chunk)
    rescue DecryptionError
      nil
    end

    # Walks page headers from the chunk's first page. Returns [pages, error_message_or_nil].
    # Mirrors the reader's tolerance: a chunk may extend past its declared total_compressed_size.
    # @param chunk [ColumnChunkInfo] chunk whose pages to walk
    # @return [Array(Array<PageInfo>, String), Array(Array<PageInfo>, nil)] the pages found, and why
    #   the walk stopped early (nil when every value was accounted for)
    def walk_pages(chunk)
      return [[], "column chunk stored in external file #{chunk.external_file}"] if chunk.external_file
      if chunk.encrypted?
        return [[], "encrypted, and its key was not given"] unless chunk.crypto
        return [[], "encrypted, and its metadata with it"] unless chunk.start_offset
      end
      pages = []
      pos = chunk.start_offset
      limit = footer_offset
      total = chunk.num_values.to_i
      seen = 0
      declared_end = chunk.declared_end_offset
      # Walk until all values are accounted for (reading past the declared end if a writer
      # under-reported it), then pick up any trailing pages still inside the declared range
      while pos < limit && (seen < total || pos < declared_end)
        trailing = seen >= total
        begin
          header, header_size = if chunk.crypto
            read_encrypted_page_header(chunk, pos, limit, pages)
          else
            read_page_header(pos, limit)
          end
          page = page_info(pages.size, header, pos, header_size, chunk.column)
        rescue Thrift::Error, FormatError, DecryptionError => e
          break if trailing
          return [pages, "corrupt page header at #{pos}: #{e.message}"]
        end
        if page.end_offset > limit
          break if trailing
          return [pages, "page #{pages.size} at #{pos} overruns the data section (#{page.end_offset} > #{limit})"]
        end
        pages << page
        seen += page.num_values.to_i if page.data?
        pos = page.end_offset
      end
      [pages, (seen < total) ? "found #{seen} of #{total} values in page headers" : nil]
    end

    # Reads and decodes a chunk's ColumnIndex, decoding the per-page min/max with the column type
    # @param chunk [ColumnChunkInfo] chunk whose ColumnIndex to read
    # @return [ColumnIndexInfo, nil] nil when the chunk has none or it fails to decode
    def read_column_index(chunk)
      offset, length = chunk.column_index_range
      return nil unless offset && length.positive?
      bytes = read_module(chunk, offset, length, Encryption::COLUMN_INDEX) or return nil
      ci = Format::ColumnIndex.decode(bytes).first
      col = chunk.column
      mins = ci.min_values || []
      maxes = ci.max_values || []
      nulls = ci.null_pages || []
      ColumnIndexInfo.new(
        offset: offset, length: length,
        null_pages: nulls,
        min_values: mins.each_with_index.map { |v, i| nulls[i] ? nil : decode_value(v, col) },
        max_values: maxes.each_with_index.map { |v, i| nulls[i] ? nil : decode_value(v, col) },
        boundary_order: Format::BoundaryOrder::NAMES[ci.boundary_order]&.to_s || ci.boundary_order,
        null_counts: ci.null_counts,
        repetition_level_histograms: ci.repetition_level_histograms,
        definition_level_histograms: ci.definition_level_histograms
      )
    rescue Thrift::Error, FormatError, DecryptionError
      nil
    end

    # Reads and decodes a chunk's OffsetIndex
    # @param chunk [ColumnChunkInfo] chunk whose OffsetIndex to read
    # @return [OffsetIndexInfo, nil] nil when the chunk has none or it fails to decode
    def read_offset_index(chunk)
      offset, length = chunk.offset_index_range
      return nil unless offset && length.positive?
      bytes = read_module(chunk, offset, length, Encryption::OFFSET_INDEX) or return nil
      oi = Format::OffsetIndex.decode(bytes).first
      OffsetIndexInfo.new(
        offset: offset, length: length,
        page_locations: (oi.page_locations || []).map do |l|
          PageLocation.new(offset: l.offset, compressed_page_size: l.compressed_page_size, first_row_index: l.first_row_index)
        end,
        unencoded_byte_array_data_bytes: oi.unencoded_byte_array_data_bytes
      )
    rescue Thrift::Error, FormatError, DecryptionError
      nil
    end

    # Size in bytes of the bloom filter at +offset+ (its Thrift header plus the bitset). An
    # encrypted filter is two modules, whose lengths are stored in the clear.
    # @param offset [Integer] file offset of the BloomFilterHeader
    # @param encrypted [Boolean] whether the filter is encrypted
    # @return [Integer, nil] nil when the header can't be decoded or has no num_bytes
    def bloom_filter_size(offset, encrypted = false)
      if encrypted
        header = read_at(offset, 4).unpack1("V") or return nil
        bitset = read_at(offset + 4 + header, 4).unpack1("V") or return nil
        return 8 + header + bitset
      end
      buf = read_at(offset, 64)
      header, size = BloomFilterHeader.decode(buf)
      header.num_bytes ? size + header.num_bytes : nil
    rescue Thrift::Error
      nil
    end

    # :ok, :mismatch or :absent for one page (reads its body). Sets PageInfo#actual_crc.
    # @param page [PageInfo] page to check
    # @return [Symbol]
    def page_checksum(page)
      return :absent unless page.crc
      page.actual_crc = page_crc(page)
      (page.actual_crc == page.expected_crc) ? :ok : :mismatch
    end

    # CRC32 of a page's body as stored
    # @param page [PageInfo] page whose compressed body to read
    # @return [Integer] unsigned 32-bit CRC
    def page_crc(page)
      Zlib.crc32(read_at(page.body_offset, page.compressed_size))
    end

    # See ColumnChunkInfo#index_mismatches
    # @param chunk [ColumnChunkInfo] chunk whose page headers to compare with its ColumnIndex
    # @return [Array<Hash{Symbol => Object}>] one entry per disagreement; a single :page_count
    #   entry when the ColumnIndex and the data pages differ in number
    def compare_page_index(chunk)
      ci = chunk.column_index or return []
      data = chunk.data_pages
      if ci.null_pages.size != data.size
        return [{page: nil, data_page: nil, field: :page_count, page_value: data.size, index_value: ci.null_pages.size}]
      end
      order = Inspector.sort_order(chunk.column)
      out = []
      data.each_with_index do |p, k|
        report = ->(field, pv, iv) { out << {page: p.index, data_page: k, field: field, page_value: pv, index_value: iv} }
        idx_nulls = ci.null_counts&.[](k)
        report.call(:null_count, p.num_nulls, idx_nulls) if idx_nulls && p.num_nulls && idx_nulls != p.num_nulls
        st = p.statistics
        # Legacy min/max were computed with another ordering, so they can't be compared
        next if st.nil? || st.caveat || (st.min.nil? && st.max.nil?)
        if ci.null_pages[k]
          report.call(:null_page, "has min/max", "null page")
          next
        end
        imin = ci.min_values[k]
        imax = ci.max_values[k]
        report.call(:min, st.min, imin) if st.min_exact != false && narrower?(imin, st.min, order, :min)
        report.call(:max, st.max, imax) if st.max_exact != false && narrower?(imax, st.max, order, :max)
      end
      out
    end

    # Decodes a Format::Statistics into Ruby values via the column's type converter
    # Prefers min_value/max_value; falls back to the deprecated min/max, with a caveat when their
    # ordering can't be trusted for the column's type.
    # @param st [Format::Statistics, nil] statistics from column metadata or a page header
    # @param column [Schema::Column] column the statistics describe
    # @return [Stats, nil] nil when +st+ is nil
    def decode_statistics(st, column)
      return nil unless st
      order = Inspector.sort_order(column)
      if st.min_value || st.max_value
        min_raw = st.min_value
        max_raw = st.max_value
        source = "min_value/max_value"
      elsif st.min || st.max
        min_raw = st.min
        max_raw = st.max
        source = "min/max (legacy)"
        binary = column.type == T::BYTE_ARRAY || column.type == T::FIXED_LEN_BYTE_ARRAY
        if order == :unsigned
          caveat = "legacy min/max were computed with signed comparison, which is wrong for unsigned-ordered " \
            "values (strings, binary, unsigned integers); most readers ignore them"
        elsif binary
          caveat = "legacy min/max of binary-backed values were compared bytewise; most readers ignore them"
        end
      end
      caveat ||= "sort order of #{T::NAMES[column.type]} is undefined; min/max may be meaningless" if order == :unknown && source
      Stats.new(
        min: decode_value(min_raw, column),
        max: decode_value(max_raw, column),
        null_count: st.null_count,
        distinct_count: st.distinct_count,
        min_exact: st.is_min_value_exact,
        max_exact: st.is_max_value_exact,
        source: source,
        caveat: caveat
      )
    end

    # Decodes one PLAIN-encoded statistics value (no length prefix for byte arrays)
    # INT96 decodes to [nanoseconds, julian_day] before conversion. Values of the wrong width,
    # or that fail to convert, come back as hex (see Inspector.hex).
    # @param bytes [String, nil] encoded value
    # @param column [Schema::Column] column whose physical type and converter apply
    # @return [Object, nil] the converted value, a hex String when it could not be decoded, nil
    #   for nil (or empty BOOLEAN) input
    def decode_value(bytes, column)
      return nil if bytes.nil?
      bytes = bytes.b
      raw = case column.type
      when T::BOOLEAN
        return nil if bytes.empty?
        bytes.getbyte(0) != 0
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY
        bytes
      when T::INT96
        return Inspector.hex(bytes) unless bytes.bytesize == 12
        bytes.unpack("Q<L<")
      else
        width = Encodings::Plain::FORMATS[column.type][1]
        return Inspector.hex(bytes) unless bytes.bytesize == width
        Encodings::Plain.decode(bytes, 0, 1, column.type).first.first
      end
      conv = column.converter
      conv ? conv.call(raw) : raw
    rescue
      Inspector.hex(bytes)
    end

    # Decodes the ARROW:schema key/value that Arrow writers (pyarrow, arrow-rs, DuckDB...) store:
    # base64 of an Arrow IPC message whose header is a flatbuffer Schema (Arrow's Message.fbs and
    # Schema.fbs). Pure Ruby and read-only; type names follow pyarrow's (str(field.type)).
    #
    #   Inspector::ArrowSchema.decode(value)
    #   # => { endianness: "little", metadata: {...}, fields: [{ name: "a", type: "int32", nullable: true, ... }] }
    #
    # Fields carry :name, :type, :nullable and, when present, :children, :dictionary
    # ({ index_type:, ordered:, id: }), :extension (ARROW:extension:name) and :metadata.
    module ArrowSchema
      # Raised for malformed or unsupported ARROW:schema values
      class Error < StandardError; end

      # Deepest field nesting accepted, against stack exhaustion on hostile input
      MAX_DEPTH = 64
      # Most fields (nested ones included) accepted in one schema
      MAX_FIELDS = 100_000
      # Arrow TimeUnit values (SECOND, MILLISECOND, MICROSECOND, NANOSECOND) as pyarrow abbreviates them
      TIME_UNITS = %w[s ms us ns].freeze
      # MessageHeader union tag of a Schema in Message.fbs
      MESSAGE_SCHEMA = 1

      # A minimal flatbuffer reader: tables (through their vtables), scalars, strings, vectors of
      # scalars and tables, and unions. Every read is bounds-checked; malformed input raises Error.
      class FlatBuffer
        # @param bytes [String] the flatbuffer (copied as binary)
        def initialize(bytes)
          @b = bytes.b
        end

        # @return [Table] the root table, whose offset is stored in the first 4 bytes
        def root = table_at(u32(0))

        # @param pos [Integer] absolute position of a table
        # @return [Table]
        # @raise [Error] when its vtable is out of bounds or malformed
        def table_at(pos) = Table.new(self, pos)

        # @param pos [Integer] absolute start of the read
        # @param len [Integer] bytes to read
        # @return [void]
        # @raise [Error] when the range is not inside the buffer
        def check(pos, len)
          return if pos >= 0 && len >= 0 && pos + len <= @b.bytesize
          raise Error, "flatbuffer read of #{len} bytes at #{pos} is out of bounds (#{@b.bytesize} bytes)"
        end

        # @param pos [Integer] absolute start of the read
        # @param len [Integer] bytes to read
        # @param fmt [String] String#unpack1 directive for the bytes
        # @return [Integer] the unpacked scalar
        # @raise [Error] when the range is not inside the buffer
        def read(pos, len, fmt)
          check(pos, len)
          @b.byteslice(pos, len).unpack1(fmt)
        end

        # @param pos [Integer] absolute position
        # @return [Integer] unsigned 8-bit value at +pos+
        def u8(pos) = read(pos, 1, "C")

        # @param pos [Integer] absolute position
        # @return [Integer] unsigned little-endian 16-bit value at +pos+
        def u16(pos) = read(pos, 2, "S<")

        # @param pos [Integer] absolute position
        # @return [Integer] signed little-endian 16-bit value at +pos+
        def i16(pos) = read(pos, 2, "s<")

        # @param pos [Integer] absolute position
        # @return [Integer] unsigned little-endian 32-bit value at +pos+
        def u32(pos) = read(pos, 4, "L<")

        # @param pos [Integer] absolute position
        # @return [Integer] signed little-endian 32-bit value at +pos+
        def i32(pos) = read(pos, 4, "l<")

        # @param pos [Integer] absolute position
        # @return [Integer] signed little-endian 64-bit value at +pos+
        def i64(pos) = read(pos, 8, "q<")

        # Offsets are relative to where they are stored
        # @param pos [Integer] absolute position of a uoffset
        # @return [Integer] absolute position it points to
        def deref(pos) = pos + u32(pos)

        # @param pos [Integer] absolute position of the string's length prefix
        # @return [String] the string's bytes as UTF-8 (not validated)
        def string(pos)
          len = u32(pos)
          check(pos + 4, len)
          @b.byteslice(pos + 4, len).force_encoding(Encoding::UTF_8)
        end

        # [start, length] of the vector at +pos+ with +size+-byte elements
        # @param pos [Integer] absolute position of the vector's length prefix
        # @param size [Integer] bytes per element
        # @return [Array(Integer, Integer)] start of the first element and the element count
        # @raise [Error] when the elements do not fit in the buffer
        def vector(pos, size)
          len = u32(pos)
          check(pos + 4, len * size)
          [pos + 4, len]
        end
      end

      # One flatbuffer table; fields are addressed by their slot (declaration order in the .fbs)
      class Table
        # @param fb [FlatBuffer] buffer the table lives in
        # @param pos [Integer] absolute position of the table (where its vtable offset is stored)
        # @raise [Error] when the vtable is out of bounds or malformed
        def initialize(fb, pos)
          @fb = fb
          @pos = pos
          @vtable = pos - fb.i32(pos)
          @vtable_size = fb.u16(@vtable)
          raise Error, "bad flatbuffer vtable at #{@vtable}" if @vtable_size < 4 || @vtable_size.odd?
          fb.check(@vtable, @vtable_size)
        end

        # Absolute position of a field's value, nil when absent
        # @param slot [Integer] field slot, counting from 0
        # @return [Integer, nil]
        def field(slot)
          o = 4 + (slot * 2)
          return nil if o + 2 > @vtable_size
          off = @fb.u16(@vtable + o)
          off.zero? ? nil : @pos + off
        end

        # @param slot [Integer] field slot, counting from 0
        # @param default [Integer] returned when the field is absent (the .fbs default)
        # @return [Integer] the unsigned 8-bit field (also used for union type tags)
        def u8(slot, default = 0) = (p = field(slot)) ? @fb.u8(p) : default

        # @param slot [Integer] field slot, counting from 0
        # @param default [Boolean] returned when the field is absent (the .fbs default)
        # @return [Boolean]
        def bool(slot, default = false) = (p = field(slot)) ? @fb.u8(p) != 0 : default

        # @param slot [Integer] field slot, counting from 0
        # @param default [Integer] returned when the field is absent (the .fbs default)
        # @return [Integer] the signed 16-bit field (also used for enums such as TimeUnit)
        def i16(slot, default = 0) = (p = field(slot)) ? @fb.i16(p) : default

        # @param slot [Integer] field slot, counting from 0
        # @param default [Integer] returned when the field is absent (the .fbs default)
        # @return [Integer] the signed 32-bit field
        def i32(slot, default = 0) = (p = field(slot)) ? @fb.i32(p) : default

        # @param slot [Integer] field slot, counting from 0
        # @param default [Integer] returned when the field is absent (the .fbs default)
        # @return [Integer] the signed 64-bit field
        def i64(slot, default = 0) = (p = field(slot)) ? @fb.i64(p) : default

        # @param slot [Integer] field slot, counting from 0
        # @return [String, nil] the string field, nil when absent
        def string(slot) = (p = field(slot)) && @fb.string(@fb.deref(p))

        # @param slot [Integer] field slot, counting from 0 (also the value of a union)
        # @return [Table, nil] the sub-table, nil when absent
        def table(slot) = (p = field(slot)) && @fb.table_at(@fb.deref(p))

        # @param slot [Integer] field slot, counting from 0
        # @return [Array<Table>] the vector of tables, empty when absent
        def tables(slot)
          p = field(slot) or return []
          start, len = @fb.vector(@fb.deref(p), 4)
          Array.new(len) { |i| @fb.table_at(@fb.deref(start + (4 * i))) }
        end

        # @param slot [Integer] field slot, counting from 0
        # @return [Array<Integer>] the vector of signed 32-bit values, empty when absent
        def i32s(slot)
          p = field(slot) or return []
          start, len = @fb.vector(@fb.deref(p), 4)
          Array.new(len) { |i| @fb.i32(start + (4 * i)) }
        end
      end

      module_function

      # Decodes the base64 ARROW:schema value; raises ArrowSchema::Error when it can't
      # @param b64 [String] the key/value metadata value (base64 of an IPC Schema message)
      # @return [Hash{Symbol => Object}] { endianness:, fields:, metadata: }; +metadata+ is a
      #   Hash{String => String}, left out when the schema has none
      # @raise [Error] when the value is empty, malformed or not a Schema message
      def decode(b64)
        bytes = b64.to_s.unpack1("m")
        raise Error, "empty value" if bytes.empty?
        fb = FlatBuffer.new(message_bytes(bytes))
        message = fb.root
        header_type = message.u8(1)
        raise Error, "IPC message holds a #{header_type} header, not a Schema" unless header_type == MESSAGE_SCHEMA
        schema = message.table(2) or raise Error, "IPC message has no Schema"
        count = [0]
        {
          endianness: schema.i16(0).zero? ? "little" : "big",
          fields: schema.tables(1).map { |f| field(f, 0, count) },
          metadata: key_values(schema.tables(2))
        }.compact
      rescue ArgumentError, TypeError, RangeError => e
        raise Error, e.message
      end

      # The flatbuffer inside an encapsulated IPC message: [0xFFFFFFFF] int32 length, flatbuffer
      # (the continuation marker is missing in files from before Arrow 0.15)
      # @param bytes [String] the decoded (binary) ARROW:schema value
      # @return [String] the message's flatbuffer bytes
      # @raise [Error] when the length prefix is missing or does not fit
      def message_bytes(bytes)
        raise Error, "too short for an IPC message (#{bytes.bytesize} bytes)" if bytes.bytesize < 8
        len = bytes.unpack1("l<")
        start = 4
        if len == -1
          len = bytes.byteslice(4, 4).unpack1("l<")
          start = 8
        end
        raise Error, "IPC message length #{len} does not fit in #{bytes.bytesize} bytes" if len <= 0 || start + len > bytes.bytesize
        bytes.byteslice(start, len)
      end

      # Describes one Arrow Field table and, recursively, its children
      # @param t [Table] the Field table
      # @param depth [Integer] nesting depth of the field, 0 at the top level
      # @param count [Array<Integer>] one-element counter of the fields seen so far, shared across
      #   the recursion
      # @return [Hash{Symbol => Object}] see the module description for the keys
      # @raise [Error] past MAX_DEPTH or MAX_FIELDS, or on malformed input
      def field(t, depth, count)
        raise Error, "fields nested deeper than #{MAX_DEPTH} levels" if depth > MAX_DEPTH
        raise Error, "more than #{MAX_FIELDS} fields" if (count[0] += 1) > MAX_FIELDS
        children = t.tables(5).map { |c| field(c, depth + 1, count) }
        metadata = key_values(t.tables(6))
        type = type_name(t.u8(2), t.table(3), children)
        h = {name: t.string(0).to_s, type: type, nullable: t.bool(1)}
        if (d = t.table(4))
          index = d.table(1)
          index_type = index ? int_name(index) : "int32"
          ordered = d.bool(2)
          h[:dictionary] = {index_type: index_type, ordered: ordered, id: d.i64(0)}
          h[:type] = "dictionary<values=#{type}, indices=#{index_type}, ordered=#{ordered ? 1 : 0}>"
        end
        h[:children] = children unless children.empty?
        if metadata
          h[:extension] = metadata["ARROW:extension:name"] if metadata["ARROW:extension:name"]
          h[:metadata] = metadata
        end
        h
      end

      # @param tables [Array<Table>] KeyValue tables (custom_metadata of a Schema or Field)
      # @return [Hash{String => String}, nil] nil when there are none
      def key_values(tables)
        return nil if tables.empty?
        tables.to_h { |kv| [kv.string(0).to_s, kv.string(1).to_s] }
      end

      # A child as pyarrow prints it inside a nested type: "name: type" plus " not null"
      # @param c [Hash{Symbol => Object}] a field as returned by #field
      # @return [String]
      def child_text(c) = "#{c[:name]}: #{c[:type]}#{" not null" unless c[:nullable]}"

      # @param t [Table] an Arrow Int table (bitWidth, is_signed)
      # @return [String] e.g. "int32" or "uint8"
      def int_name(t) = "#{"u" unless t.bool(1)}int#{t.i32(0)}"

      # @param u [Integer] Arrow TimeUnit value
      # @return [String] "s", "ms", "us" or "ns" ("unitN" for unknown values)
      def unit(u) = TIME_UNITS[u] || "unit#{u}"

      # Type names follow Arrow's DataType::ToString (what pyarrow prints)
      # @param kind [Integer] the Field's Type union tag (Schema.fbs)
      # @param t [Table, nil] the union's type table, nil when absent
      # @param children [Array<Hash{Symbol => Object}>] the already described child fields
      # @return [String] e.g. "timestamp[us, tz=UTC]" or "list<item: string>"
      # @raise [Error] for a Decimal type without its parameters table
      def type_name(kind, t, children)
        case kind
        when 1 then "null"
        when 2 then t ? int_name(t) : "int"
        when 3 then %w[halffloat float double][t ? t.i16(0) : 0] || "float?"
        when 4 then "binary"
        when 5 then "string"
        when 6 then "bool"
        when 7
          raise Error, "decimal type without parameters" unless t
          bits = t.i32(2, 128)
          "decimal#{bits}(#{t.i32(0)}, #{t.i32(1)})"
        when 8 then t&.i16(0, 1)&.zero? ? "date32[day]" : "date64[ms]"
        when 9
          bits = t ? t.i32(1, 32) : 32
          "time#{bits}[#{unit(t ? t.i16(0, 1) : 1)}]"
        when 10
          tz = t&.string(1)
          "timestamp[#{unit(t ? t.i16(0) : 0)}#{", tz=#{tz}" if tz}]"
        when 11 then %w[month_interval day_time_interval month_day_nano_interval][t ? t.i16(0) : 0] || "interval"
        when 12 then "list<#{children.map { |c| child_text(c) }.join(", ")}>"
        when 13 then "struct<#{children.map { |c| child_text(c) }.join(", ")}>"
        when 14
          mode = t&.i16(0)&.positive? ? "dense" : "sparse"
          ids = t ? t.i32s(1) : []
          members = children.each_with_index.map { |c, i| "#{child_text(c)}=#{ids[i] || i}" }
          "#{mode}_union<#{members.join(", ")}>"
        when 15 then "fixed_size_binary[#{t ? t.i32(0) : 0}]"
        when 16 then "fixed_size_list<#{children.map { |c| child_text(c) }.join(", ")}>[#{t ? t.i32(0) : 0}]"
        when 17 then map_name(t, children)
        when 18 then "duration[#{unit(t ? t.i16(0, 1) : 1)}]"
        when 19 then "large_binary"
        when 20 then "large_string"
        when 21 then "large_list<#{children.map { |c| child_text(c) }.join(", ")}>"
        when 22 then "run_end_encoded<#{children.map { |c| "#{(c[:name] == "values") ? "values" : "run_ends"}: #{c[:type]}" }.join(", ")}>"
        when 23 then "binary_view"
        when 24 then "string_view"
        when 25 then "list_view<#{children.map { |c| child_text(c) }.join(", ")}>"
        when 26 then "large_list_view<#{children.map { |c| child_text(c) }.join(", ")}>"
        else "unknown type #{kind}"
        end
      end

      # map<key, value> with non-standard field names in parentheses, as Arrow prints it
      # @param t [Table, nil] the Map table (keysSorted), nil when absent
      # @param children [Array<Hash{Symbol => Object}>] the map's single entries struct field
      # @return [String]
      def map_name(t, children)
        entries = children.first
        kv = entries && entries[:children] || []
        named = ->(f, std) { f ? "#{f[:type]}#{" ('#{f[:name]}')" unless f[:name] == std}" : "?" }
        sorted = t&.bool(0) ? ", keys_sorted" : ""
        entries_name = (entries && entries[:name] != "entries") ? " ('#{entries[:name]}')" : ""
        "map<#{named.call(kv[0], "key")}, #{named.call(kv[1], "value")}#{sorted}#{entries_name}>"
      end

      # "name: type" lines for a field and its children, indented, for text output
      # Children nested deeper than 8 levels are left out.
      # @param fields [Array<Hash{Symbol => Object}>] fields as returned by #decode under +:fields+
      # @param depth [Integer] indentation level of +fields+
      # @param out [Array<String>] accumulator the lines are appended to
      # @return [Array<String>] +out+
      def lines(fields, depth = 0, out = [])
        fields.each do |f|
          notes = []
          notes << "not null" unless f[:nullable]
          notes << "extension #{f[:extension]}" if f[:extension]
          meta = (f[:metadata] || {}).reject { |k, _| k.start_with?("ARROW:extension:") }
          notes << "metadata #{meta.map { |k, v| "#{k}=#{v.to_s[0, 60].inspect}" }.join(", ")}" unless meta.empty?
          out << "#{"  " * depth}#{f[:name]}: #{f[:type]}#{" (#{notes.join("; ")})" unless notes.empty?}"
          lines(f[:children], depth + 1, out) if f[:children] && depth < 8
        end
        out
      end
    end

    # ---- class helpers ----

    # @param e [Integer] Parquet Encoding value
    # @return [String] its name, e.g. "RLE_DICTIONARY" (the number as a String when unknown)
    def self.encoding_name(e) = Format::Encoding::NAMES[e]&.to_s || e.to_s

    # @param column [Schema::Column] leaf column
    # @return [String] physical type with its logical annotation, e.g. "BYTE_ARRAY STRING" or
    #   "FIXED_LEN_BYTE_ARRAY(16) UUID"
    def self.type_name(column)
      node = column.node
      phys = T::NAMES[node.type].to_s
      phys += "(#{node.type_length})" if node.type == T::FIXED_LEN_BYTE_ARRAY && node.type_length
      logical = logical_type_name(node)
      logical ? "#{phys} #{logical}" : phys
    end

    # The node's LogicalType, else its ConvertedType, as text
    # @param node [Schema::Node] schema node (leaf or group)
    # @return [String, nil] e.g. "INTEGER(8, unsigned)", "TIMESTAMP(MICROS, UTC)" or "DECIMAL(10, 2)";
    #   nil when the node has no annotation
    def self.logical_type_name(node)
      if (kind = node.logical_type&.kind)
        name, payload = kind
        case name
        when :integer then "INTEGER(#{payload.bit_width}, #{payload.is_signed ? "signed" : "unsigned"})"
        when :decimal then "DECIMAL(#{payload.precision}, #{payload.scale})"
        when :timestamp, :time
          "#{name.upcase}(#{payload.unit&.to_sym&.upcase}, #{payload.is_adjusted_to_utc ? "UTC" : "local"})"
        when :unknown then "NULL"
        else name.to_s.upcase
        end
      elsif node.converted_type
        c = Format::ConvertedType::NAMES[node.converted_type].to_s
        (c == "DECIMAL") ? "DECIMAL(#{node.precision}, #{node.scale || 0})" : c
      end
    end

    # :signed, :unsigned or :unknown, per the Parquet sort order rules for the column's type
    # @param column [Schema::Column] leaf column
    # @return [Symbol]
    def self.sort_order(column)
      kind, _a, signed = Types.logical_of(column.node)
      case kind
      when :integer then (signed == false) ? :unsigned : :signed
      when :decimal, :date, :time, :timestamp, :float16 then :signed
      when :string, :enum, :json, :bson, :uuid then :unsigned
      else
        case column.type
        when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY then :unsigned
        when T::INT96 then :unknown
        else :signed
        end
      end
    end

    # Converts Ruby values (Time, BigDecimal, binary Strings, non-finite Floats...) to JSON-safe ones
    # Recurses into Hashes, Arrays and Structs; Hash keys other than Symbols become Strings.
    # @param v [Object] value to convert
    # @return [Hash, Array, String, Integer, Float, Boolean, nil]
    def self.jsonable(v)
      case v
      when Hash then v.each_with_object({}) { |(k, x), h| h[k.is_a?(Symbol) ? k : k.to_s] = jsonable(x) }
      when Array then v.map { |x| jsonable(x) }
      when Struct then v.respond_to?(:to_h) ? jsonable(v.to_h) : v.to_s
      when String then text(v)
      when Symbol then v.to_s
      when Float then v.finite? ? v : v.to_s
      when Time then v.utc.strftime(v.nsec.zero? ? "%Y-%m-%dT%H:%M:%SZ" : "%Y-%m-%dT%H:%M:%S.%NZ")
      when Date then v.iso8601
      when BigDecimal then v.to_s("F")
      when Integer, true, false, nil then v
      else v.to_s
      end
    end

    # A String as readable text when it is valid UTF-8 without control characters, else as hex
    # Strings already tagged as valid UTF-8 are returned as they are, control characters and all.
    # @param s [String] string in any encoding
    # @return [String]
    def self.text(s)
      return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?
      u = s.dup.force_encoding(Encoding::UTF_8)
      return u if u.valid_encoding? && !u.match?(/[\x00-\x08\x0e-\x1f\x7f]/)
      hex(s)
    end

    # @param bytes [String] bytes to show
    # @return [String] "0x" and lowercase hex digits; only the first 64 bytes, followed by the
    #   total size, for longer input
    def self.hex(bytes)
      b = bytes.b
      (b.bytesize > 64) ? "0x#{b.byteslice(0, 64).unpack1("H*")}… (#{b.bytesize} bytes)" : "0x#{b.unpack1("H*")}"
    end

    # A short display form of a decoded value
    # Strings are quoted (binary ones go through Inspector.text first), nil shows as "null".
    # @param v [Object] decoded value
    # @param max [Integer] longest result, in characters; longer ones are cut and end in an ellipsis
    # @return [String]
    def self.display(v, max: 40)
      s = case v
      when String then (v.encoding == Encoding::BINARY) ? text(v) : v
      when nil then "null"
      else jsonable(v).to_s
      end
      s = s.inspect if v.is_a?(String)
      (s.size > max) ? "#{s[0, max - 1]}…" : s
    end

    # @param n [Integer, nil] byte count
    # @return [String] e.g. "512 B", "1.50 KB" or "12.3 MB" (binary units); "?" for nil
    def self.human_bytes(n)
      return "?" unless n
      units = %w[B KB MB GB TB]
      f = n.to_f
      i = 0
      while f >= 1024 && i < units.size - 1
        f /= 1024
        i += 1
      end
      if i.zero?
        "#{n} B"
      else
        format("%.#{(f < 10) ? 2 : 1}f %s", f, units[i])
      end
    end

    private

    # @param uncompressed [Integer, nil] uncompressed byte count
    # @param compressed [Integer, nil] compressed byte count
    # @return [String] " (3.21x)" for #report, empty when the ratio is unknown
    def ratio_text(uncompressed, compressed)
      (compressed.to_i.positive? && uncompressed) ? format(" (%.2fx)", uncompressed.to_f / compressed) : ""
    end

    # @param page [PageInfo] page whose CRC status to show
    # @return [String] the status for a #report page line: " crc ok", " CRC MISMATCH", " crc"
    #   (has a CRC, not verified) or empty
    def crc_text(page)
      case page.checksum
      when :ok then " crc ok"
      when :mismatch then " CRC MISMATCH"
      else page.crc ? " crc" : ""
      end
    end

    # @param m [Hash{Symbol => Object}] an entry of #index_mismatches
    # @return [String] one #report line describing it
    def index_mismatch_text(m)
      where = "row group #{m[:row_group]} #{m[:column]}"
      if m[:field] == :page_count
        "#{where}: #{m[:page_value]} data pages but #{m[:index_value]} column index entries"
      else
        "#{where} page #{m[:page]}: #{m[:field]} in page header #{Inspector.display(m[:page_value])}, " \
          "in column index #{Inspector.display(m[:index_value])}"
      end
    end

    # Adds :arrow_type to schema nodes with a same-named Arrow field (top level, and struct members)
    # @param nodes [Array<Hash{Symbol => Object}>] #schema_tree nodes, updated in place
    # @param fields [Array<Hash{Symbol => Object}>] Arrow fields at the same level
    # @param depth [Integer] nesting depth; recursion stops at 32
    # @return [void]
    def annotate_arrow_types(nodes, fields, depth = 0)
      by_name = fields.to_h { |f| [f[:name], f] }
      nodes.each do |n|
        f = by_name[n[:name]] or next
        n[:arrow_type] = f[:type]
        if n[:children] && f[:children] && f[:type].start_with?("struct<") && depth < 32
          annotate_arrow_types(n[:children], f[:children], depth + 1)
        end
      end
    end

    # Whether the index bound +idx+ excludes values the page's bound +page+ says are present
    # (index min above the page min, or index max below the page max). Truncated binary bounds
    # (one a prefix of the other) and values that can't be compared are never reported.
    # @param idx [Object, nil] decoded ColumnIndex bound
    # @param page [Object, nil] decoded page header bound
    # @param order [Symbol] :signed, :unsigned or :unknown (see Inspector.sort_order)
    # @param which [Symbol] :min or :max
    # @return [Boolean]
    def narrower?(idx, page, order, which)
      return false if idx.nil? || page.nil? || order == :unknown
      a, b = (which == :min) ? [page, idx] : [idx, page] # true when a < b
      if a.is_a?(String) && b.is_a?(String)
        a = a.b
        b = b.b
        return false if a.start_with?(b) || b.start_with?(a)
        return (order == :unsigned) ? a < b : false
      end
      return false if a.is_a?(Float) && a.nan? || b.is_a?(Float) && b.nan?
      a = a ? 1 : 0 if a == true || a == false
      b = b ? 1 : 0 if b == true || b == false
      (a <=> b) == -1
    rescue
      false
    end

    # Overall min or max of per-chunk bounds, when they can be compared
    # @param values [Array<Object, nil>] decoded per-chunk minimums or maximums
    # @param which [Symbol] :min or :max
    # @return [Object, nil] nil when there are no values or they are of mixed or incomparable types
    def safe_extreme(values, which)
      vals = values.compact
      return nil if vals.empty?
      if vals.all? { |v| v == true || v == false }
        return (which == :min) ? vals.all? : vals.any?
      end
      return nil unless vals.map(&:class).uniq.size == 1
      (which == :min) ? vals.min : vals.max
    rescue ArgumentError, NoMethodError
      nil
    end

    # Reads the file size, the footer length and magic, and decodes the FileMetaData into @metadata
    # (decrypting it, or checking its signature, in an encrypted file)
    # @return [void]
    # @raise [FormatError] when the file is too small, lacks the magic bytes or has a corrupt footer
    # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted
    def read_footer
      @io.seek(0, IO::SEEK_END)
      @file_size = @io.pos
      raise FormatError, "File too small to be Parquet (#{@file_size} bytes)" if @file_size < 12
      tail = read_at(@file_size - 8, 8)
      magic = tail.byteslice(4, 4)
      raise FormatError, "Missing PAR1 footer magic" unless magic == MAGIC || magic == Reader::ENCRYPTED_MAGIC
      @footer_size = tail.unpack1("V")
      raise FormatError, "Footer length #{@footer_size} exceeds file size" if @footer_size + 12 > @file_size
      footer = read_at(footer_offset, @footer_size)
      if magic == MAGIC
        @metadata = Format::FileMetaData.decode(footer).first
        return unless @metadata.encryption_algorithm
      end
      @metadata, @decryptor = Encryption.read_footer(footer, magic, @decryption)
    rescue Thrift::Error => e
      raise FormatError, "Corrupt file metadata: #{e.message}"
    end

    # Reads +len+ bytes at +pos+ through a small read-ahead window, so walking many small pages
    # does not cost a syscall per header
    # @param pos [Integer] file offset
    # @param len [Integer] bytes wanted
    # @return [String] binary String; shorter than +len+ at the end of the file
    def read_at(pos, len)
      if @window && pos >= @window_pos && pos + len <= @window_pos + @window.bytesize
        return @window.byteslice(pos - @window_pos, len)
      end
      @io.seek(pos)
      if len >= WINDOW
        (@io.read(len) || "".b).b
      else
        @window_pos = pos
        @window = (@io.read(WINDOW) || "".b).b
        @window.byteslice(0, len)
      end
    end

    # A module of an encrypted chunk, decrypted
    # @param chunk [ColumnChunkInfo] the chunk the module belongs to
    # @param offset [Integer] file offset of the module
    # @param length [Integer] its length, length prefix included
    # @param type [Integer] module type
    # @return [String, nil] the plaintext (the bytes as stored for a plaintext chunk), nil when the
    #   chunk's key was not given
    # @raise [DecryptionError] when the module does not decrypt
    def read_module(chunk, offset, length, type)
      bytes = read_at(offset, length)
      return bytes unless chunk.encrypted?
      chunk.crypto&.decrypt(type, bytes)
    end

    # Decrypts and decodes the encrypted page header at +pos+. Its AAD depends on whether it is the
    # dictionary page's (the first page, when the chunk has a dictionary) and on the number of
    # data pages before it.
    # @param chunk [ColumnChunkInfo] the chunk, whose key is available
    # @param pos [Integer] file offset of the header module
    # @param limit [Integer] offset the header must not extend past (the footer's start)
    # @param pages [Array<PageInfo>] the chunk's pages before this one
    # @return [Array(Format::PageHeader, Integer)] the header and the module's size in bytes
    # @raise [FormatError] when the module does not fit before +limit+
    # @raise [DecryptionError] when it does not decrypt
    def read_encrypted_page_header(chunk, pos, limit, pages)
      raise FormatError, "no room for a page header" if pos + 4 > limit
      size = read_at(pos, 4).unpack1("V") + 4
      raise FormatError, "encrypted page header overruns the data section" if pos + size > limit
      plain = if pages.empty? && chunk.dictionary_page_offset == pos
        chunk.crypto.decrypt(Encryption::DICTIONARY_PAGE_HEADER, read_at(pos, size))
      else
        chunk.crypto.decrypt(Encryption::DATA_PAGE_HEADER, read_at(pos, size), pages.count(&:data?))
      end
      [Format::PageHeader.decode(plain).first, size]
    end

    # Decodes the page header at +pos+, reading more bytes when it is larger than the first guess
    # (page statistics of long strings can make headers big)
    # @param pos [Integer] file offset of the header
    # @param limit [Integer] offset the header must not extend past (the footer's start)
    # @return [Array(Format::PageHeader, Integer)] the header and its encoded size in bytes
    # @raise [FormatError] when there is no room for a header before +limit+
    # @raise [Thrift::Error] when it does not decode within +limit+ or 16 MiB
    def read_page_header(pos, limit)
      want = 256
      while true
        avail = [want, limit - pos].min
        raise FormatError, "no room for a page header" if avail <= 0
        buf = read_at(pos, avail)
        begin
          header, size = Format::PageHeader.decode(buf)
          return [header, size]
        rescue Thrift::Error
          raise if avail < want || want >= 16 * 1024 * 1024
          want *= 8
        end
      end
    end

    # Builds a PageInfo from a decoded page header
    # @param index [Integer] position of the page in its chunk
    # @param h [Format::PageHeader] decoded header
    # @param pos [Integer] file offset of the header
    # @param header_size [Integer] encoded size of the header in bytes
    # @param column [Schema::Column] column the page belongs to (for statistics and row counts)
    # @return [PageInfo]
    # @raise [FormatError] when the header declares a negative compressed size
    def page_info(index, h, pos, header_size, column)
      info = PageInfo.new(
        index: index,
        type: Format::PageType::NAMES[h.type] || h.type,
        offset: pos,
        header_size: header_size,
        compressed_size: h.compressed_page_size.to_i,
        uncompressed_size: h.uncompressed_page_size.to_i,
        crc: h.crc
      )
      raise FormatError, "negative page size #{info.compressed_size}" if info.compressed_size.negative?
      if (d = h.data_page_header)
        info.num_values = d.num_values
        info.encoding = Inspector.encoding_name(d.encoding)
        info.definition_level_encoding = Inspector.encoding_name(d.definition_level_encoding) if d.definition_level_encoding
        info.repetition_level_encoding = Inspector.encoding_name(d.repetition_level_encoding) if d.repetition_level_encoding
        info.statistics = decode_statistics(d.statistics, column)
        info.num_nulls = info.statistics&.null_count
        # Without repetition every value is a row
        info.num_rows = d.num_values if column.max_repetition_level.zero?
      elsif (d = h.data_page_header_v2)
        info.num_values = d.num_values
        info.num_nulls = d.num_nulls
        info.num_rows = d.num_rows
        info.encoding = Inspector.encoding_name(d.encoding)
        info.definition_levels_byte_length = d.definition_levels_byte_length
        info.repetition_levels_byte_length = d.repetition_levels_byte_length
        info.is_compressed = d.is_compressed.nil? || d.is_compressed
        info.statistics = decode_statistics(d.statistics, column)
      elsif (d = h.dictionary_page_header)
        info.num_values = d.num_values
        info.encoding = Inspector.encoding_name(d.encoding)
        info.is_sorted = d.is_sorted
      end
      info
    end

    # One #key_value_metadata entry
    # @param key [String] metadata key
    # @param value [String, nil] metadata value
    # @return [Hash{Symbol => Object}] see #key_value_metadata
    def describe_key_value(key, value)
      value = value.to_s
      h = {key: key, bytesize: value.bytesize}
      if key == "ARROW:schema"
        h[:format] = "arrow_schema"
        h[:value] = (value.size > 120) ? "#{value[0, 120]}…" : value
        if (arrow = arrow_schema)
          h[:summary] = "Arrow schema, #{arrow[:fields].size} field#{"s" unless arrow[:fields].size == 1}"
          h[:arrow_fields] = arrow[:fields].map { |f| f[:name] }
          meta = arrow[:metadata]&.transform_values { |v| (v.size > 4000) ? "#{v[0, 4000]}…" : v }
          h[:arrow_schema] = arrow.merge(metadata: meta).compact
        else
          h[:summary] = "Arrow IPC schema message, base64-encoded (#{value.bytesize} bytes)"
          h[:arrow_error] = arrow_schema_error
          names = arrow_field_names(value)
          h[:arrow_fields] = names if names
        end
      elsif value.lstrip.start_with?("{", "[") && value.bytesize < 4 * 1024 * 1024
        begin
          h[:json] = JSON.parse(value)
          h[:format] = "json"
          h[:summary] = (key == "pandas") ? pandas_summary(h[:json]) : "JSON"
        rescue JSON::ParserError
          h[:format] = "text"
        end
        h[:value] = (value.size > 4000) ? "#{value[0, 4000]}…" : value
      else
        t = Inspector.text(value.b)
        h[:format] = (t.start_with?("0x") && value.bytesize.positive?) ? "binary" : "text"
        h[:value] = (t.size > 4000) ? "#{t[0, 4000]}…" : t
      end
      h
    end

    # @param json [Object] the parsed "pandas" metadata value
    # @return [String] e.g. "pandas 2.2.0 metadata, 3 columns"
    def pandas_summary(json)
      return "pandas metadata" unless json.is_a?(Hash)
      cols = json["columns"]&.size
      "pandas #{json["pandas_version"]} metadata, #{cols || "?"} columns"
    end

    # Field names from an Arrow IPC schema message, found by scanning for its flatbuffer strings.
    # Best effort: only used to label the blob, nil when nothing sensible is found.
    # Only top-level Parquet column names that occur in the decoded bytes are reported.
    # @param b64 [String] the base64 ARROW:schema value
    # @return [Array<String>, nil]
    def arrow_field_names(b64)
      bytes = b64.unpack1("m")
      schema_cols = columns.map { |c| c.path.first }.uniq
      found = schema_cols.select { |n| bytes.include?(n.b) }
      found.empty? ? nil : found
    rescue ArgumentError
      nil
    end
  end
end
