# frozen_string_literal: true

module Herringbone
  # Writes Parquet files.
  #
  #   schema = Herringbone::Schema.define do |s|
  #     s.int64 :id, null: false
  #     s.string :name
  #     s.list :tags, :string
  #   end
  #   File.open("out.parquet", "wb") do |file|
  #     Herringbone::Writer.open(file, schema) do |w|
  #       w << { "id" => 1, "name" => "one", "tags" => ["a", "b"] }
  #       w << [2, "two", []]           # Arrays are taken in schema order
  #       w << order                    # objects responding to #attributes (ActiveRecord) or #to_h
  #     end
  #   end
  #
  # The output is any IO that responds to #write (a File, StringIO, Tempfile, socket, pipe...); it
  # is written sequentially and never seeked, rewound or closed by the writer; only #write is
  # required, its return value is ignored, and #binmode and #flush are called when available.
  # Herringbone does not open files by path.
  #
  # Options:
  #   compression:     :snappy (default), :zstd, :gzip, :lz4 (LZ4_RAW), :lz4_hadoop, :brotli, :none
  #                    (:zstd and :brotli need the zstd-ruby / brotli gems)
  #   compression_level: nil (the codec's default), or a level for :zstd (up to 22), :gzip (0-9)
  #                    or :brotli (0-11)
  #   row_group_bytes: flush a row group once the buffered values take roughly this much memory
  #                    (default 16MB). This bounds memory use while writing.
  #   row_group_rows:  also flush after this many rows (default: no row limit)
  #   page_bytes:      approximate uncompressed data page size (default 1MB)
  #   page_rows:       at most this many rows per data page (default 20_000), which keeps the page
  #                    index selective
  #   data_page_version: 1 (default) or 2
  #   dictionary:      true/false, or an Array of column paths to dictionary-encode
  #   encodings:       { "path.to.column" => :delta_binary_packed, ... } for non-dictionary pages
  #   metadata:        Hash of String => String key/value metadata for the footer
  #   bloom_filters:   write split block bloom filters: true (every column that supports them),
  #                    an Array of column paths, or { "path" => true | { ndv:, fpp:, max_bytes: } }.
  #                    Without ndv: the distinct values of each row group are counted. fpp defaults
  #                    to 0.01 and max_bytes to 1MB. Filters are written after each row group.
  #   encryption:      Parquet modular encryption: { footer_key: "...", columns: { "ssn" => "..." } }.
  #                    Without columns: every column is encrypted with the footer key. See
  #                    #initialize for the settings.
  #
  # Statistics and page indexes (ColumnIndex/OffsetIndex) are always written.
  class Writer
    # Marker at the start and end of every Parquet file
    MAGIC = "PAR1".b.freeze
    # Shorthand for Format::Type (physical types)
    T = Format::Type
    # Shorthand for Format::Encoding
    E = Format::Encoding

    # Names accepted in the +encodings:+ option => Parquet encoding id
    ENCODING_NAMES = {
      plain: E::PLAIN, rle: E::RLE, delta_binary_packed: E::DELTA_BINARY_PACKED,
      delta_length_byte_array: E::DELTA_LENGTH_BYTE_ARRAY, delta_byte_array: E::DELTA_BYTE_ARRAY,
      byte_stream_split: E::BYTE_STREAM_SPLIT
    }.freeze

    # Encoding id => physical types it may be used for, per the Parquet encodings spec
    VALID_ENCODINGS = Ractor.make_shareable({
      E::PLAIN => T::NAMES.keys,
      E::RLE => [T::BOOLEAN],
      E::DELTA_BINARY_PACKED => [T::INT32, T::INT64],
      E::DELTA_LENGTH_BYTE_ARRAY => [T::BYTE_ARRAY],
      E::DELTA_BYTE_ARRAY => [T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY],
      E::BYTE_STREAM_SPLIT => [T::INT32, T::INT64, T::FLOAT, T::DOUBLE, T::FIXED_LEN_BYTE_ARRAY]
    })

    # Largest dictionary build_dictionary keeps; above it the chunk is written without a dictionary.
    # Byte-array columns are dictionary-encoded by ByteValues, which applies its own
    # ByteValues::MAX_DICTIONARY_BYTES as values arrive.
    MAX_DICTIONARY_BYTES = 1024 * 1024
    # The row group byte size is first estimated after this many rows, then after every row group
    ESTIMATE_AFTER_ROWS = 1000

    # @return [Schema] schema the rows are written with
    attr_reader :schema

    # Opens a writer on +io+. With a block, the file is finished (footer written) when the block
    # returns and the block's value is returned; if the block raises, the writer is aborted and no
    # footer is written. Without a block, call #close to finish. The IO is never closed.
    #
    # @param io [IO, #write] destination
    # @param schema [Schema] schema of the rows
    # @param options [Hash{Symbol => Object}] see the class description and #initialize
    # @option options [Symbol] :compression (:snappy) codec, see Herringbone.codecs
    # @option options [Integer, nil] :compression_level (nil) level for :zstd, :gzip or :brotli
    # @option options [Integer] :row_group_bytes (16MB) approximate buffered size that triggers a row group
    # @option options [Integer, nil] :row_group_rows (nil) also flush a row group after this many rows
    # @option options [Integer] :page_bytes (1MB) approximate uncompressed data page size
    # @option options [Integer] :page_rows (20_000) maximum rows per data page
    # @option options [Integer] :data_page_version (1) 1 or 2
    # @option options [Boolean, Array<String>] :dictionary (true) dictionary-encode all eligible columns,
    #   none, or only the listed dotted column paths
    # @option options [Hash{String => Symbol}] :encodings ({}) dotted column path => value encoding
    #   for non-dictionary pages
    # @option options [Hash{String => String}] :metadata ({}) key/value metadata for the footer
    # @option options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
    #   columns to write split block bloom filters for
    # @option options [EncryptionConfiguration, Hash{Symbol => Object}, nil] :encryption (nil) modular
    #   encryption settings, see #initialize
    # @yield [writer] the open writer
    # @yieldparam writer [Writer] writer to append rows to
    # @yieldreturn [Object] returned by open
    # @return [Writer, Object] the writer without a block, the block's value with one
    # @raise [ArgumentError] for an invalid IO, schema or option
    def self.open(io, schema, **options)
      writer = new(io, schema, **options)
      return writer unless block_given?
      begin
        result = yield writer
      rescue Exception # rubocop:disable Lint/RescueException -- also abort on Interrupt
        writer.abort
        raise
      end
      writer.close
      result
    end

    # Validates the options and writes the leading magic bytes to +io+.
    #
    # @param io [IO, #write] destination; switched to binmode when it supports that
    # @param schema [Schema] schema of the rows
    # @param compression [Symbol, Integer] codec name (see Herringbone.codecs) or Format::Codec id
    # @param compression_level [Integer, nil] level for :zstd, :gzip or :brotli (see
    #   Compression::LEVELS), nil for the codec's default
    # @param row_group_bytes [Integer] approximate buffered size that triggers a row group
    # @param row_group_rows [Integer, nil] also flush a row group after this many rows
    # @param page_bytes [Integer] approximate uncompressed data page size
    # @param page_rows [Integer] maximum level entries per data page (pages of repeated columns
    #   extend to the next row start)
    # @param data_page_version [Integer] 1 or 2
    # @param dictionary [Boolean, Array<String>] true for every column except BOOLEAN, FLOAT, DOUBLE
    #   and those listed in +encodings+; false for none; or the dotted paths of the columns to encode
    # @param encodings [Hash{String, Symbol => Symbol, Integer}] dotted column path => value encoding
    #   (a name from ENCODING_NAMES or an encoding id) for non-dictionary pages
    # @param metadata [Hash{#to_s => #to_s}] key/value metadata for the footer
    # @param bloom_filters [Boolean, Array<String>, Hash{String => Boolean, Hash}, nil] see the class
    #   description
    # @param encryption [EncryptionConfiguration, Hash{Symbol => Object}, false, nil] encrypts the file
    #   (Parquet modular encryption); a Hash holds the keywords of EncryptionConfiguration.new.
    #   Keys are 16, 24 or 32-byte Strings; key metadata is stored as given, for readers to find
    #   the keys by.
    # @option encryption [String] :footer_key key of the footer, and of columns without their own
    # @option encryption [String, nil] :footer_key_metadata stored for the footer key
    # @option encryption [Hash{String => String, Hash, Symbol}, nil] :columns column path or field
    #   name => key, +{key:, key_metadata:}+ or +:footer+. Columns not listed are not encrypted;
    #   without this option every column is, with the footer key.
    # @option encryption [Boolean] :plaintext_footer (false) store the footer in the clear (signed),
    #   so readers without keys can read the plaintext columns
    # @option encryption [Symbol] :algorithm (:aes_gcm) or :aes_gcm_ctr, which encrypts pages with
    #   AES-CTR (faster, but page contents are not authenticated)
    # @option encryption [String, nil] :aad_prefix identity of the file, which readers can check
    # @option encryption [Boolean] :store_aad_prefix (true) false leaves it out of the file, so
    #   readers must supply it
    # @raise [ArgumentError] for an invalid IO, schema or option, or a compression level the codec
    #   does not take
    # @raise [MissingCodecError] when the codec's optional gem is not loaded
    # @raise [UnsupportedError] when the codec is not supported
    def initialize(io, schema, compression: :snappy, compression_level: nil, row_group_bytes: 16 * 1024 * 1024, row_group_rows: nil,
      page_bytes: 1024 * 1024, page_rows: 20_000, data_page_version: 1, dictionary: true, encodings: {},
      metadata: {}, bloom_filters: nil, encryption: nil)
      raise ArgumentError, "Expected a Herringbone::Schema, got #{schema.class}" unless schema.is_a?(Schema)
      @schema = schema
      @codec = Compression.codec_id(compression)
      # Fail before creating any file if the codec's library is missing
      Compression.ensure_available!(@codec)
      @compression_level = Compression.check_level!(@codec, compression_level)
      @row_group_bytes = Integer(row_group_bytes)
      @row_group_rows = row_group_rows && Integer(row_group_rows)
      @row_limit = @row_group_rows || ESTIMATE_AFTER_ROWS
      @page_bytes = Integer(page_bytes)
      @page_rows = Integer(page_rows)
      raise ArgumentError, "page_rows must be positive" unless @page_rows.positive?
      @page_indexes = [] # [ColumnChunk, ColumnIndex or nil, OffsetIndex] per written column chunk
      @data_page_version = Integer(data_page_version)
      raise ArgumentError, "data_page_version must be 1 or 2" unless [1, 2].include?(@data_page_version)
      @dictionary = dictionary
      @encodings = encodings.to_h { |path, enc| [path.to_s, encoding_id(path, enc)] }
      columns = schema.columns.to_h { |c| [c.dotted_path, c] }
      unknown = @encodings.keys - columns.keys
      raise ArgumentError, "encodings: no such column #{unknown.join(", ")}" unless unknown.empty?
      @encodings.each { |path, enc| check_encoding!(columns[path], enc) }
      @metadata = metadata
      @bloom_filters = bloom_filter_config(bloom_filters)
      @pending_bloom_filters = [] # [ColumnMetaData, BloomFilter, ModuleCrypto] for the row group being written
      @encryption = encryption ? Encryption::FileEncryptor.new(EncryptionConfiguration.from(encryption), schema) : nil
      @row_groups = []
      @total_rows = 0
      @pos = 0
      @closed = false
      @aborted = false
      @bytes_per_row = nil
      @io = check_io!(io)
      write_raw(@encryption ? @encryption.magic : MAGIC)
      reset_buffers
    end

    # Appends a row: a Hash keyed by top-level field names (Strings or Symbols), an Array of values
    # in schema order, or an object responding to #attributes (ActiveRecord) or #to_h (Struct, Data).
    # A row that fails to encode leaves nothing behind in the buffers. Flushes a row group when the
    # buffered rows reach the size limits.
    #
    # @param row [Hash, Array, #attributes, #to_h] row to append
    # @return [self]
    # @raise [Error] when the writer is closed
    # @raise [EncodeError] when a required field is nil or missing, or a value cannot be encoded
    def <<(row)
      raise Error, "Writer is closed" if @closed
      row = row_hash(row)
      marks = @nested_buffers.empty? ? nil : @nested_buffers.map { |b| [b.defs.size, b.reps&.size, b.values.size] }
      begin
        @plan.each do |field, name, sym, buf, encoder|
          value = row.fetch(name) { row[sym] }
          if buf.nil?
            shred(field, value, 0, 0)
          elsif value.nil?
            raise EncodeError.new("Field #{name} is required but got nil", column: name) unless field.optional
            buf.defs << 0
          else
            begin
              buf.values << encoder.call(value)
            rescue ArgumentError, TypeError, NoMethodError, RangeError => e
              raise EncodeError.new("Cannot write #{value.inspect} to #{name}: #{e.message}", column: name, value: value)
            end
            buf.defs << field.def_level
          end
        end
      rescue EncodeError => e
        rollback_row(marks)
        raise EncodeError.new("Row #{@total_rows + @buffered_rows}: #{e.message}", row: @total_rows + @buffered_rows, column: e.column, value: e.value)
      rescue
        rollback_row(marks)
        raise
      end
      @buffered_rows += 1
      check_row_group_size if @buffered_rows >= @row_limit
      self
    end

    # Number of rows written so far, including buffered ones
    #
    # @return [Integer]
    def rows_written = @total_rows + @buffered_rows

    # Writes any buffered rows as a row group
    #
    # @return [void]
    def flush_row_group
      return if @buffered_rows.zero?
      write_row_group(@buffered_rows)
    end

    # A column chunk taken as it is from another file, for #write_row_group
    #
    # @!attribute chunk
    #   @return [Format::ColumnChunk] the chunk's footer entry in the source file
    # @!attribute start
    #   @return [Integer] source file offset of the chunk's first page
    # @!attribute bytes
    #   @return [String] the chunk's pages, headers included
    # @!attribute column_index
    #   @return [String, nil] the chunk's encoded ColumnIndex
    # @!attribute offset_index
    #   @return [Format::OffsetIndex, nil] the chunk's OffsetIndex, with source file offsets
    # @!attribute bloom_filter
    #   @return [String, nil] the chunk's encoded bloom filter, header included
    CopiedChunk = Struct.new(:chunk, :start, :bytes, :column_index, :offset_index, :bloom_filter)

    # Internal (used by Redaction and Combiner): writes a row group of +num_rows+ rows from the
    # buffered values, except for the columns in +copies+, whose chunks are copied byte for byte
    # from another file with their offsets rebased. Starts a new row group afterwards.
    #
    # @param num_rows [Integer] rows in the row group
    # @param copies [Hash{Integer => CopiedChunk}] column index => chunk to copy instead of encoding
    #   (only plaintext chunks, into columns this writer does not encrypt)
    # @param codecs [Hash{Integer => Integer}] column index => codec id for an encoded chunk, instead
    #   of the +compression:+ option
    # @param bloom_filters [Hash{Integer => Boolean}] column index => true to give an encoded chunk a
    #   bloom filter (default settings) when the +bloom_filters:+ option does not ask for one
    # @param sorting_columns [Array<Format::SortingColumn>, nil] stored on the RowGroup as given
    # @return [void]
    # @raise [Error] when the writer is closed
    def write_row_group(num_rows, copies: {}, codecs: {}, bloom_filters: {}, sorting_columns: nil)
      raise Error, "Writer is closed" if @closed
      if @encryption && (encrypted = copies.keys.find { |i| @encryption.encrypted?(i) })
        raise ArgumentError, "Cannot copy a chunk into the encrypted column #{@schema.columns[encrypted].dotted_path}"
      end
      start = @pos
      chunks = @schema.columns.map do |col|
        if (copy = copies[col.index])
          copy_column_chunk(copy)
        else
          bloom = @bloom_filters[col.dotted_path]
          bloom ||= bloom_filter_settings({}) if bloom_filters[col.index] && BloomFilter::TYPES.include?(col.type)
          write_column_chunk(col, @buffers[col.index], codec: codecs.fetch(col.index, @codec), bloom: bloom)
        end
      end
      @row_groups << Format::RowGroup.new(
        columns: chunks,
        total_byte_size: chunks.sum { |c| c.meta_data.total_uncompressed_size },
        num_rows: num_rows,
        sorting_columns: sorting_columns,
        file_offset: start,
        total_compressed_size: @pos - start,
        ordinal: @row_groups.size
      )
      write_bloom_filters
      @total_rows += num_rows
      reset_buffers
    end

    # Internal (used by Redaction and Combiner): whether the column is encrypted in this file
    #
    # @param index [Integer] leaf column index
    # @return [Boolean]
    def encrypted_column?(index) = @encryption&.encrypted?(index) || false

    # Internal (used by Redaction and Combiner): shreds one value per row of a top-level field into
    # the buffers, for #write_row_group. Other fields are left as they are, so the caller decides
    # which columns are encoded and which are copied.
    #
    # @param name [String] top-level field name
    # @param values [Array] the field's value for each row
    # @return [void]
    # @raise [ArgumentError] when the schema has no such field
    # @raise [EncodeError] when a value cannot be written to the field
    def buffer_field(name, values)
      field = @schema.field(name) or raise ArgumentError, "No such field #{name.inspect}"
      values.each_with_index do |value, i|
        shred(field, value, 0, 0)
      rescue EncodeError => e
        raise EncodeError.new("Row #{@total_rows + i}: #{e.message}", row: @total_rows + i, column: e.column, value: e.value)
      end
    end

    # Flushes buffered rows, then writes the page indexes and the footer and flushes the IO.
    # Does nothing when already closed or aborted. The IO itself is not closed.
    #
    # @return [void]
    def close
      return if @closed
      flush_row_group
      write_page_indexes
      @encryption&.finish(@row_groups)
      meta = Format::FileMetaData.new(
        version: 2,
        schema: @schema.to_elements,
        num_rows: @total_rows,
        row_groups: @row_groups,
        key_value_metadata: @metadata.empty? ? nil : @metadata.map { |k, v| Format::KeyValue.new(key: k.to_s, value: v&.to_s) },
        created_by: "herringbone-ruby #{VERSION}",
        column_orders: @schema.columns.map { Format::ColumnOrder.new(type_order: Format::TypeDefinedOrder.new) }
      )
      footer = @encryption ? @encryption.footer(meta) : meta.encode
      write_raw(footer)
      write_raw([footer.bytesize].pack("V"))
      write_raw(@encryption ? @encryption.magic : MAGIC)
      @io.flush if @io.respond_to?(:flush)
      @closed = true
    end

    # Stops writing without finishing the file (no footer is written). Whatever was already written
    # to the IO stays there; discarding it is up to the caller.
    #
    # @return [void]
    def abort
      @aborted = true unless @closed
      @closed = true
    end

    # Short summary for the console, without the buffered values
    #
    # @return [String] state (open, closed or aborted), rows written including buffered ones,
    #   row groups flushed and the codec
    def inspect
      state = if @aborted then "aborted"
      elsif @closed then "closed"
      else "open"
      end
      "#<#{self.class.name} #{state} rows_written=#{rows_written} row_groups=#{@row_groups.size} " \
        "compression=#{Compression::NAMES.fetch(@codec, @codec).inspect}>"
    end

    private

    # Pathname responds to #write too (writing a whole file by path), so it is rejected explicitly.
    # A text-mode IO (a pipe, or a File opened with "w") transcodes what is written when
    # Encoding.default_internal is set, as Rails does, and binary pages cannot be transcoded,
    # so the IO is switched to binary mode.
    #
    # @param io [Object] candidate destination
    # @return [IO, #write] +io+, in binary mode when it supports #binmode
    # @raise [ArgumentError] when +io+ does not respond to #write, or is a String or Pathname
    def check_io!(io)
      if io.respond_to?(:write) && !io.is_a?(String) && !(defined?(Pathname) && io.is_a?(Pathname))
        io.binmode if io.respond_to?(:binmode)
        return io
      end
      raise ArgumentError, "Herringbone::Writer expects an IO that responds to #write " \
        "(e.g. File.open(path, \"wb\") or StringIO.new), got #{io.class}"
    end

    # Levels are kept as binary Strings (one byte per entry). Values are an Array for numeric and
    # boolean columns, and a compact ByteValues for BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY columns.
    #
    # @!attribute defs
    #   @return [String, Array<Integer>] definition levels (unpacked to an Array while a chunk is written)
    # @!attribute reps
    #   @return [String, Array<Integer>, nil] repetition levels, like +defs+; nil for non-repeated columns
    # @!attribute values
    #   @return [Array, ByteValues] non-null physical values
    ColumnBuffer = Struct.new(:defs, :reps, :values)

    # Starts a new row group: fresh buffers per column, and the per-field write plan
    # (field, name, Symbol name, buffer and encoder for flat fields, or nils for shredded ones).
    #
    # @return [void]
    # @raise [UnsupportedError] when a column has more than 255 definition or repetition levels
    def reset_buffers
      @buffers = @schema.columns.map do |col|
        if col.max_definition_level > 255 || col.max_repetition_level > 255
          raise UnsupportedError, "Column #{col.dotted_path} is nested too deeply"
        end
        ColumnBuffer.new(String.new(encoding: Encoding::BINARY),
          col.max_repetition_level.positive? ? String.new(encoding: Encoding::BINARY) : nil,
          new_values_store(col))
      end
      # Column#encoder builds its Proc on every call
      @encoders = @schema.columns.map(&:encoder)
      # Top-level, non-repeated leaves are written directly, everything else is shredded
      @plan = @schema.fields.map do |field|
        flat = field.leaf? && field.column.max_repetition_level.zero?
        [field, field.name, field.name.to_sym, flat ? @buffers[field.column.index] : nil, flat ? @encoders[field.column.index] : nil]
      end
      @nested_buffers = @plan.reject { |p| p[3] }.flat_map { |p| p[0].leaves.map { |c| @buffers[c.index] } }
      @buffered_rows = 0
    end

    # @param col [Schema::Column] column to buffer
    # @return [ByteValues, Array] empty value store for the column
    def new_values_store(col)
      case col.type
      when T::BYTE_ARRAY then ByteValues.new(dictionary: use_dictionary?(col))
      when T::FIXED_LEN_BYTE_ARRAY then ByteValues.new(width: col.type_length, dictionary: use_dictionary?(col))
      else []
      end
    end

    # Flushes when the buffered values reach row_group_bytes (or row_group_rows rows). The bytes per
    # row are estimated from the buffered values after the first rows, then refreshed per row group.
    #
    # @return [void]
    def check_row_group_size
      @bytes_per_row ||= estimate_bytes_per_row
      limit = row_limit_for(@bytes_per_row)
      if @buffered_rows >= limit
        @bytes_per_row = estimate_bytes_per_row
        flush_row_group
        @row_limit = row_limit_for(@bytes_per_row)
      else
        @row_limit = limit
      end
    end

    # @param bytes_per_row [Integer] estimated buffered bytes per row
    # @return [Integer] rows to buffer before the next size check: what fits in row_group_bytes,
    #   at least ESTIMATE_AFTER_ROWS, at most row_group_rows
    def row_limit_for(bytes_per_row)
      by_bytes = [@row_group_bytes / [bytes_per_row, 1].max, ESTIMATE_AFTER_ROWS].max
      @row_group_rows ? [@row_group_rows, by_bytes].min : by_bytes
    end

    # @return [Integer] memory held by the buffers divided by the buffered rows
    def estimate_bytes_per_row
      bytes = @schema.columns.sum do |col|
        buf = @buffers[col.index]
        values = buf.values
        held = if values.is_a?(ByteValues)
          values.memory_bytes
        else
          values.size * ((col.type == T::INT96) ? 48 : 8)
        end
        held + buf.defs.bytesize + (buf.reps ? buf.reps.bytesize : 0)
      end
      bytes / [@buffered_rows, 1].max
    end

    # Writes to the IO and tracks the file offset, since the IO is never asked for its position
    #
    # @param bytes [String] binary data
    # @return [void]
    def write_raw(bytes)
      @io.write(bytes)
      @pos += bytes.bytesize
    end

    # @param path [String, Symbol] column path, for the error message
    # @param enc [Symbol, String, Integer] encoding name from ENCODING_NAMES, or an encoding id
    # @return [Integer] encoding id
    # @raise [ArgumentError] for an unknown encoding name, or an id that is not in VALID_ENCODINGS
    def encoding_id(path, enc)
      if enc.is_a?(Integer)
        return enc if VALID_ENCODINGS.key?(enc)
        raise ArgumentError, "Encoding #{E::NAMES.fetch(enc, enc)} cannot be requested for #{path}"
      end
      ENCODING_NAMES.fetch(enc.to_s.downcase.to_sym) { raise ArgumentError, "Unknown encoding #{enc.inspect} for #{path}" }
    end

    # @param col [Schema::Column] column the encoding is requested for
    # @param enc [Integer] encoding id, a key of VALID_ENCODINGS
    # @return [void]
    # @raise [ArgumentError] when the encoding is not valid for the column's physical type
    def check_encoding!(col, enc)
      return if VALID_ENCODINGS.fetch(enc).include?(col.type)
      raise ArgumentError, "Encoding #{E::NAMES[enc]} is not valid for #{T::NAMES[col.type]} column #{col.dotted_path}"
    end

    # Reads a struct member, by String or Symbol key
    #
    # @param hash [Hash, #to_h, nil] struct value
    # @param name [String] member name
    # @return [Object, nil] member value, nil when +hash+ is nil or has no such key
    # @raise [EncodeError] when +hash+ cannot be converted to a Hash
    def lookup(hash, name)
      return nil if hash.nil?
      hash = as_hash(hash, name) unless hash.is_a?(Hash)
      hash.fetch(name) { hash[name.to_sym] }
    end

    # @param row [Hash, Array, #attributes, #to_h] row given to #<<
    # @return [Hash] the row keyed by top-level field names
    # @raise [EncodeError] when an Array has the wrong size or the row cannot be converted to a Hash
    def row_hash(row)
      case row
      when Hash then row
      when Array
        if row.size != @plan.size
          raise EncodeError, "Row #{rows_written}: expected #{@plan.size} values in schema order, got #{row.size}"
        end
        @plan.each_with_index.to_h { |(_, name), i| [name, row[i]] }
      else
        return row.attributes if row.respond_to?(:attributes)
        as_hash(row, "row #{rows_written}")
      end
    end

    # @param value [Hash, #to_h] value to convert
    # @param what [String] description of the value, for the error message
    # @return [Hash]
    # @raise [EncodeError] when +value+ does not respond to #to_h
    def as_hash(value, what)
      return value if value.is_a?(Hash)
      raise EncodeError, "Expected a Hash for #{what}, got #{value.class}" unless value.respond_to?(:to_h)
      value.to_h
    end

    # Removes the entries a failed row left behind, so the buffers stay aligned
    #
    # @param marks [Array<Array(Integer, Integer, Integer)>, nil] sizes of defs, reps and values of
    #   each nested buffer before the row, nil when there are none
    # @return [void]
    def rollback_row(marks)
      @plan.each do |field, _, _, buf|
        next unless buf && buf.defs.bytesize > @buffered_rows
        d = buf.defs.getbyte(-1)
        buf.defs.slice!(-1..)
        buf.values.pop if d == field.def_level
      end
      marks&.each_with_index do |(defs, reps, values), i|
        buf = @nested_buffers[i]
        buf.defs.slice!(defs..)
        buf.reps&.slice!(reps..)
        buf.values.slice!(values..)
      end
    end

    # Record shredding: turns a nested value into (definition level, repetition level, value) entries
    #
    # @param field [Schema::Field] field the value belongs to
    # @param value [Object, nil] Ruby value of the field
    # @param parent_def [Integer] definition level recorded when +value+ is nil
    # @param rep [Integer] repetition level of the first entry this value produces
    # @return [void]
    # @raise [EncodeError] when a required value is nil, a list or map value has the wrong type, a
    #   map key is nil, or a leaf value cannot be encoded
    def shred(field, value, parent_def, rep)
      if value.nil?
        raise EncodeError.new("Field #{field.node.path.join(".")} is required but got nil", column: field.node.path.join(".")) unless field.optional
        field.leaves.each do |col|
          buf = @buffers[col.index]
          buf.defs << parent_def
          buf.reps&.<< rep
        end
        return
      end

      d = field.def_level
      case field.kind
      when :leaf
        buf = @buffers[field.column.index]
        buf.defs << d
        buf.reps&.<< rep
        begin
          buf.values << @encoders[field.column.index].call(value)
        rescue ArgumentError, TypeError, NoMethodError, RangeError => e
          raise EncodeError.new("Cannot write #{value.inspect} to #{field.column.dotted_path}: #{e.message}", column: field.column.dotted_path, value: value)
        end
      when :struct
        field.children.each { |ch| shred(ch, lookup(value, ch.name), d, rep) }
      when :list
        raise EncodeError.new("Expected an Array for #{field.node.path.join(".")}, got #{value.class}", column: field.node.path.join("."), value: value) unless value.respond_to?(:each_with_index)
        if value.empty?
          field.leaves.each do |col|
            buf = @buffers[col.index]
            buf.defs << d
            buf.reps&.<< rep
          end
        else
          value.each_with_index do |el, i|
            shred(field.element, el, field.item_def, i.zero? ? rep : field.rep_level)
          end
        end
      when :map
        raise EncodeError.new("Expected a Hash for #{field.node.path.join(".")}, got #{value.class}", column: field.node.path.join("."), value: value) unless value.respond_to?(:each_pair) || value.is_a?(Array)
        if value.empty?
          field.leaves.each do |col|
            buf = @buffers[col.index]
            buf.defs << d
            buf.reps&.<< rep
          end
        else
          value.each_with_index do |(k, v), i|
            r = i.zero? ? rep : field.rep_level
            raise EncodeError, "Map keys cannot be nil in #{field.node.path.join(".")}" if k.nil?
            shred(field.key, k, field.item_def, r)
            shred(field.value, v, field.item_def, r)
          end
        end
      end
    end

    # Writes one column chunk of the current row group: an optional dictionary page, then data pages.
    # Bloom filters and page indexes are queued, to be written after the row group and before the
    # footer.
    #
    # @param col [Schema::Column] column being written
    # @param buffer [ColumnBuffer] the column's buffered levels and values
    # @param codec [Integer] codec id to compress the pages with
    # @param bloom [Hash{Symbol => Numeric, nil}, nil] bloom filter settings (see
    #   #bloom_filter_settings), nil for no bloom filter
    # @return [Format::ColumnChunk] chunk with its ColumnMetaData, for the row group
    def write_column_chunk(col, buffer, codec: @codec, bloom: @bloom_filters[col.dotted_path])
      type = col.type
      path = col.dotted_path
      dict_values = nil
      indices = nil
      values = buffer.values
      if values.is_a?(ByteValues)
        kind, values, indices = values.materialize
        if kind == :dictionary
          dict_values = values
          values = nil
        end
      elsif use_dictionary?(col) && !values.empty?
        dict_values, indices = build_dictionary(values, type, col.type_length)
      end
      # Levels as Arrays of Integers, for this column only
      buf = ColumnBuffer.new(buffer.defs.unpack("C*"), buffer.reps&.unpack("C*"), values)
      value_encoding = if dict_values
        E::RLE_DICTIONARY
      else
        @encodings[path] || E::PLAIN
      end

      crypto = @encryption&.chunk(@row_groups.size, col.index)
      chunk_start = @pos
      uncompressed_total = 0
      dictionary_offset = nil
      if dict_values
        dictionary_offset = @pos
        plain = Encodings::Plain.encode(dict_values, type, col.type_length)
        header = Format::PageHeader.new(
          type: Format::PageType::DICTIONARY_PAGE,
          dictionary_page_header: Format::DictionaryPageHeader.new(num_values: dict_values.size, encoding: E::PLAIN)
        )
        uncompressed_total += write_page(header, plain, codec: codec, crypto: crypto)
      end

      data_offset = @pos
      max_def = col.max_definition_level
      max_rep = col.max_repetition_level
      value_index = 0
      value_bytes = if indices
        indices.size * 4
      elsif (width = value_width(col))
        values.size * width
      else
        values.sum(&:bytesize) + 4 * values.size
      end
      order = sort_key(col)
      pages = []
      first_row = 0
      page_ranges(buf, value_bytes).each do |from, to|
        n = to - from
        defs = buf.defs[from, n]
        reps = buf.reps&.slice(from, n)
        non_null = max_def.zero? ? n : defs.count(max_def)
        page_values = (indices || values)[value_index, non_null]
        value_index += non_null
        page_offset = @pos
        range = nil
        if order && non_null.positive?
          in_page = dict_values ? page_values.uniq.map { |i| dict_values[i] } : page_values
          range = value_range(col, in_page, order)
        end
        encoded = encode_values(page_values, value_encoding, type, col.type_length, dict_values&.size)
        rep_bytes = max_rep.positive? ? Encodings::RLE.encode_hybrid(reps, max_rep.bit_length) : "".b
        def_bytes = max_def.positive? ? Encodings::RLE.encode_hybrid(defs, max_def.bit_length) : "".b
        page_crypto = crypto && [crypto, pages.size]
        uncompressed_total += if @data_page_version == 1
          write_data_page_v1(n, rep_bytes, def_bytes, encoded, value_encoding, codec, page_crypto)
        else
          num_rows = max_rep.zero? ? n : reps.count(0)
          write_data_page_v2(n, n - non_null, num_rows, rep_bytes, def_bytes, encoded, value_encoding, codec, page_crypto)
        end
        pages << PageInfo.new(page_offset, @pos - page_offset, first_row, n - non_null, non_null, range)
        first_row += max_rep.zero? ? n : reps.count(0)
      end

      encodings = [E::RLE]
      encodings << E::PLAIN if dict_values
      encodings << value_encoding
      meta = Format::ColumnMetaData.new(
        type: type,
        encodings: encodings.uniq,
        path_in_schema: col.path,
        codec: codec,
        num_values: buf.defs.size,
        total_uncompressed_size: uncompressed_total,
        total_compressed_size: @pos - chunk_start,
        data_page_offset: data_offset,
        dictionary_page_offset: dictionary_offset,
        statistics: statistics_for(col, buf.defs, values || indices.uniq.map { |i| dict_values[i] }, order)
      )
      chunk = Format::ColumnChunk.new(file_offset: chunk_start, meta_data: meta)
      if bloom
        @pending_bloom_filters << [meta, build_bloom_filter(col, bloom, dict_values, values), crypto]
      end
      @page_indexes << [chunk, column_index_for(col, pages, order), offset_index_for(pages), crypto]
      chunk
    end

    # What the page indexes need to know about a written data page
    #
    # @!attribute offset
    #   @return [Integer] file offset of the page header
    # @!attribute size
    #   @return [Integer] page size in the file, header included
    # @!attribute first_row
    #   @return [Integer] index of the page's first row within the row group
    # @!attribute nulls
    #   @return [Integer] null entries in the page
    # @!attribute non_null
    #   @return [Integer] non-null values in the page
    # @!attribute range
    #   @return [Array(Object, Object), nil] [min, max] physical values, nil when there are none
    PageInfo = Struct.new(:offset, :size, :first_row, :nulls, :non_null, :range)

    # @param pages [Array<PageInfo>] pages of a column chunk
    # @return [Format::OffsetIndex]
    def offset_index_for(pages)
      Format::OffsetIndex.new(page_locations: pages.map do |p|
        Format::PageLocation.new(offset: p.offset, compressed_page_size: p.size, first_row_index: p.first_row)
      end)
    end

    # Writes a chunk copied from another file. The pages, the ColumnIndex and the bloom filter
    # hold no file offsets and go out as they are; the ColumnMetaData and the OffsetIndex do, so
    # those are rebased onto where the chunk lands in this file.
    #
    # @param copy [CopiedChunk] the chunk to copy
    # @return [Format::ColumnChunk] chunk with its ColumnMetaData, for the row group
    def copy_column_chunk(copy)
      start = @pos
      shift = start - copy.start
      meta = Format::ColumnMetaData.decode(copy.chunk.meta_data.encode).first
      meta.data_page_offset += shift
      dict = meta.dictionary_page_offset
      # Some writers store 0 when there is no dictionary page
      meta.dictionary_page_offset = dict&.positive? ? dict + shift : nil
      meta.index_page_offset += shift if meta.index_page_offset
      meta.total_compressed_size = copy.bytes.bytesize
      meta.bloom_filter_offset = meta.bloom_filter_length = nil
      write_raw(copy.bytes)
      chunk = Format::ColumnChunk.new(file_offset: start, meta_data: meta)
      @pending_bloom_filters << [meta, copy.bloom_filter] if copy.bloom_filter
      offset_index = copy.offset_index && Format::OffsetIndex.new(
        page_locations: copy.offset_index.page_locations.map do |loc|
          Format::PageLocation.new(offset: loc.offset + shift, compressed_page_size: loc.compressed_page_size,
            first_row_index: loc.first_row_index)
        end,
        unencoded_byte_array_data_bytes: copy.offset_index.unencoded_byte_array_data_bytes
      )
      @page_indexes << [chunk, copy.column_index, offset_index]
      chunk
    end

    # nil when the column has no defined sort order, or a page's values have no min/max (all NaN)
    #
    # @param col [Schema::Column] column the pages belong to
    # @param pages [Array<PageInfo>] pages of the column chunk
    # @param order [Proc, Method, nil] sort key from #sort_key
    # @return [Format::ColumnIndex, nil]
    def column_index_for(col, pages, order)
      return nil unless order
      return nil if pages.any? { |p| p.non_null.positive? && p.range.nil? }
      Format::ColumnIndex.new(
        null_pages: pages.map { |p| p.non_null.zero? },
        min_values: pages.map { |p| p.range ? truncate_min(stat_bytes(col, p.range[0])) : "".b },
        max_values: pages.map { |p| p.range ? truncate_max(stat_bytes(col, p.range[1])) : "".b },
        boundary_order: boundary_order(pages.filter_map(&:range), order),
        null_counts: pages.map(&:nulls)
      )
    end

    # @param ranges [Array<Array(Object, Object)>] [min, max] of each non-null page, in page order
    # @param order [Proc, Method] sort key from #sort_key
    # @return [Integer] Format::BoundaryOrder: ASCENDING when both mins and maxes never decrease
    #   (or there are fewer than two pages), DESCENDING when they never increase, else UNORDERED
    def boundary_order(ranges, order)
      return Format::BoundaryOrder::ASCENDING if ranges.size < 2
      cmp = ->(a, b) { order.equal?(IDENTITY) ? a <=> b : order.call(a) <=> order.call(b) }
      pairs = ranges.each_cons(2)
      if pairs.all? { |(a_min, a_max), (b_min, b_max)| cmp.call(a_min, b_min) <= 0 && cmp.call(a_max, b_max) <= 0 }
        Format::BoundaryOrder::ASCENDING
      elsif pairs.all? { |(a_min, a_max), (b_min, b_max)| cmp.call(a_min, b_min) >= 0 && cmp.call(a_max, b_max) >= 0 }
        Format::BoundaryOrder::DESCENDING
      else
        Format::BoundaryOrder::UNORDERED
      end
    end

    # Page indexes go after the last row group: all column indexes, then all offset indexes.
    # A copied chunk brings its ColumnIndex already encoded, and may come without either index.
    # Those of encrypted columns are encrypted.
    #
    # @return [void]
    def write_page_indexes
      @page_indexes.each do |chunk, column_index, _, crypto|
        next unless column_index
        bytes = column_index.is_a?(String) ? column_index : column_index.encode
        bytes = crypto.encrypt(Encryption::COLUMN_INDEX, bytes) if crypto
        chunk.column_index_offset = @pos
        chunk.column_index_length = bytes.bytesize
        write_raw(bytes)
      end
      @page_indexes.each do |chunk, _, offset_index, crypto|
        next unless offset_index
        bytes = offset_index.encode
        bytes = crypto.encrypt(Encryption::OFFSET_INDEX, bytes) if crypto
        chunk.offset_index_offset = @pos
        chunk.offset_index_length = bytes.bytesize
        write_raw(bytes)
      end
      @page_indexes.clear
    end

    # Per-column settings accepted in the +bloom_filters:+ option
    BLOOM_FILTER_OPTIONS = %i[ndv fpp max_bytes].freeze

    # { dotted_path => { ndv:, fpp:, max_bytes: } } from the bloom_filters: option
    #
    # @param requested [Boolean, Array<String>, Hash{String => Boolean, Hash, nil}, nil] true for every
    #   column of a supported type, column paths, or column path => true / false / settings Hash.
    #   A path may also be given as an Array of names. Settings are +ndv+, +fpp+ and +max_bytes+.
    # @return [Hash{String => Hash{Symbol => Numeric, nil}}] settings by dotted path; empty when disabled
    # @raise [ArgumentError] for an unknown column, a column type without bloom filter support, or
    #   invalid settings
    def bloom_filter_config(requested)
      return {} if requested.nil? || requested == false
      columns = @schema.columns.to_h { |c| [c.dotted_path, c] }
      if requested == true
        return columns.select { |_, c| BloomFilter::TYPES.include?(c.type) }.transform_values { bloom_filter_settings({}) }
      end
      requested = Array(requested).to_h { |path| [path, true] } unless requested.is_a?(Hash)
      requested.each_with_object({}) do |(path, settings), config|
        path = path.is_a?(Array) ? path.join(".") : path.to_s
        col = columns[path] or raise ArgumentError, "bloom_filters: no such column #{path}"
        next if settings.nil? || settings == false
        unless BloomFilter::TYPES.include?(col.type)
          raise ArgumentError, "bloom_filters: not supported for #{T::NAMES[col.type]} column #{path}"
        end
        settings = {} if settings == true
        raise ArgumentError, "bloom_filters: expected true or a Hash for #{path}, got #{settings.inspect}" unless settings.is_a?(Hash)
        config[path] = bloom_filter_settings(settings.transform_keys(&:to_sym), path)
      end
    end

    # @param settings [Hash{Symbol => Object}] +ndv+, +fpp+ and +max_bytes+, all optional
    # @param path [String, nil] column path, for error messages
    # @return [Hash{Symbol => Numeric, nil}] +ndv+ (nil to count distinct values), +fpp+ and
    #   +max_bytes+ with defaults filled in
    # @raise [ArgumentError] for unknown keys, a non-positive ndv, or an fpp outside (0, 1)
    def bloom_filter_settings(settings, path = nil)
      unknown = settings.keys - BLOOM_FILTER_OPTIONS
      raise ArgumentError, "bloom_filters: unknown option #{unknown.join(", ")} for #{path}" unless unknown.empty?
      ndv = settings[:ndv] && Integer(settings[:ndv])
      raise ArgumentError, "bloom_filters: ndv must be positive for #{path}" if ndv && !ndv.positive?
      fpp = Float(settings.fetch(:fpp, BloomFilter::DEFAULT_FPP))
      raise ArgumentError, "bloom_filters: fpp must be between 0 and 1 for #{path}" unless fpp > 0 && fpp < 1
      {ndv: ndv, fpp: fpp, max_bytes: Integer(settings.fetch(:max_bytes, BloomFilter::DEFAULT_MAX_BYTES))}
    end

    # A filter holding the chunk's values: +dict_values+ (already distinct) for dictionary-encoded
    # chunks, +values+ otherwise. Each distinct value is hashed once, and the filter is sized from
    # the configured ndv or from the number of distinct values.
    #
    # @param col [Schema::Column] column the filter is for
    # @param settings [Hash{Symbol => Numeric, nil}] from #bloom_filter_settings
    # @param dict_values [Array, nil] dictionary of the chunk, when dictionary-encoded
    # @param values [Array, nil] the chunk's non-null physical values, used without a dictionary
    # @return [BloomFilter]
    def build_bloom_filter(col, settings, dict_values, values)
      hashes = if dict_values
        BloomFilter.hash_physical_all(dict_values, col.type)
      else
        BloomFilter.hash_physical_all(values, col.type, distinct: true)
      end
      size = BloomFilter.optimal_num_bytes(settings[:ndv] || hashes.size, settings[:fpp], max_bytes: settings[:max_bytes])
      filter = BloomFilter.new(size, column: col)
      filter.insert_hashes(hashes)
      filter
    end

    # Bloom filters go right after the row group's column chunks, in column order. A copied
    # chunk brings its filter already encoded. In an encrypted column the header and the bitset
    # are encrypted separately.
    #
    # @return [void]
    def write_bloom_filters
      @pending_bloom_filters.each do |meta, filter, crypto|
        bytes = if crypto
          crypto.encrypt(Encryption::BLOOM_FILTER_HEADER, filter.header.encode) <<
            crypto.encrypt(Encryption::BLOOM_FILTER_BITSET, filter.bitset)
        else
          filter.is_a?(String) ? filter : filter.encode
        end
        meta.bloom_filter_offset = @pos
        meta.bloom_filter_length = bytes.bytesize
        write_raw(bytes)
      end
      @pending_bloom_filters.clear
    end

    # @param col [Schema::Column] column to check
    # @return [Boolean] whether the +dictionary:+ option asks for this column to be dictionary-encoded
    #   (never for BOOLEAN)
    def use_dictionary?(col)
      return false if col.type == T::BOOLEAN
      case @dictionary
      when true then ![T::BOOLEAN, T::FLOAT, T::DOUBLE].include?(col.type) && !@encodings.key?(col.dotted_path)
      when false, nil then false
      else Array(@dictionary).map(&:to_s).include?(col.dotted_path)
      end
    end

    # Returns [dictionary_values, indices] or nil when a dictionary is not worthwhile: more than about
    # half the values are distinct, or the dictionary exceeds MAX_DICTIONARY_BYTES
    #
    # @param values [Array] non-null physical values of the chunk
    # @param type [Integer] physical type
    # @param type_length [Integer, nil] FIXED_LEN_BYTE_ARRAY width
    # @return [Array(Array, Array<Integer>), nil]
    def build_dictionary(values, type, type_length)
      # Floats are keyed by bit pattern so that -0.0 and 0.0 (and NaNs) stay distinct
      if type == T::FLOAT || type == T::DOUBLE
        keys = values.pack("G*").unpack("Q>*")
        uniq = keys.uniq
        return nil if uniq.size > values.size / 2 + 1 && values.size > 16
        return nil if uniq.size * 8 > MAX_DICTIONARY_BYTES
        index = uniq.each_with_index.to_h
        return [uniq.pack("Q>*").unpack("G*"), keys.map(&index)]
      end
      dict = values.uniq
      return nil if dict.size > values.size / 2 + 1 && values.size > 16
      size = case type
      when T::BYTE_ARRAY then dict.sum { |v| v.bytesize + 4 }
      when T::FIXED_LEN_BYTE_ARRAY then dict.size * type_length
      else dict.size * 8
      end
      return nil if size > MAX_DICTIONARY_BYTES
      index = dict.each_with_index.to_h
      [dict, values.map(&index)]
    end

    # Splits a column buffer into pages of roughly @page_bytes bytes. Repeated columns
    # are only cut where a new row starts.
    #
    # @param buf [ColumnBuffer] column buffer with levels as Arrays
    # @param value_bytes [Integer] estimated encoded size of all the chunk's values
    # @return [Array<Array(Integer, Integer)>] [from, to) ranges of level entries, one per page
    def page_ranges(buf, value_bytes)
      n = buf.defs.size
      bytes = n + value_bytes
      pages = (bytes + @page_bytes - 1) / @page_bytes
      per = (pages <= 1) ? n : (n + pages - 1) / pages
      per = @page_rows if per > @page_rows
      return [[0, n]] if per >= n
      reps = buf.reps
      ranges = []
      start = 0
      while start < n
        stop = start + per
        stop = n if stop > n
        stop += 1 while reps && stop < n && reps[stop] != 0
        ranges << [start, stop]
        start = stop
      end
      ranges
    end

    # @param col [Schema::Column] column to check
    # @return [Integer, nil] PLAIN-encoded bytes per value, nil for BYTE_ARRAY (variable width)
    def value_width(col)
      case col.type
      when T::BOOLEAN then 1
      when T::INT32, T::FLOAT then 4
      when T::INT64, T::DOUBLE then 8
      when T::INT96 then 12
      when T::FIXED_LEN_BYTE_ARRAY then col.type_length
      end
    end

    # Encodes a page's values. RLE_DICTIONARY values are the dictionary indices, prefixed with the
    # bit width byte; RLE is only used for BOOLEAN and carries the 4-byte length prefix.
    #
    # @param values [Array] physical values, or dictionary indices
    # @param encoding [Integer] encoding id
    # @param type [Integer] physical type
    # @param type_length [Integer, nil] FIXED_LEN_BYTE_ARRAY width
    # @param dict_size [Integer, nil] number of dictionary entries, for RLE_DICTIONARY
    # @return [String] encoded binary page values
    def encode_values(values, encoding, type, type_length, dict_size)
      case encoding
      when E::PLAIN then Encodings::Plain.encode(values, type, type_length)
      when E::RLE_DICTIONARY
        width = (dict_size - 1).bit_length
        width.chr.b << Encodings::RLE.encode_hybrid(values, width)
      when E::RLE
        body = Encodings::RLE.encode_hybrid(values.map { |v| v ? 1 : 0 }, 1)
        [body.bytesize].pack("V") << body
      when E::DELTA_BINARY_PACKED
        Encodings::Delta.encode_binary_packed(values, (type == T::INT32) ? 32 : 64)
      when E::DELTA_LENGTH_BYTE_ARRAY then Encodings::Delta.encode_length_byte_array(values)
      when E::DELTA_BYTE_ARRAY then Encodings::Delta.encode_byte_array(values)
      when E::BYTE_STREAM_SPLIT
        width = {T::INT32 => 4, T::FLOAT => 4, T::INT64 => 8, T::DOUBLE => 8}[type] || type_length
        Encodings::ByteStreamSplit.encode(Encodings::Plain.encode(values, type, type_length), width)
      end
    end

    # Writes a page, returning the uncompressed size including the header
    #
    # Compresses with the configured level when +codec+ is the writer's own; chunks a redaction
    # keeps in their source codec use that codec's default
    #
    # @param codec [Integer] codec id
    # @param data [String, Array<String>] bytes to compress, or the parts of them
    # @return [String] compressed bytes
    def compress(codec, data)
      Compression.compress(codec, data, (codec == @codec) ? @compression_level : nil)
    end

    # In an encrypted column the body and the header are encrypted; the CRC covers the body as
    # stored, encrypted.
    #
    # @param header [Format::PageHeader] header; sizes and CRC32 are filled in here
    # @param body [String, Array<String>] uncompressed page body, or its parts
    # @param compressed [String, Array<String>, nil] bytes to write as the page body, or their
    #   parts, when already prepared (v2 data pages, whose levels stay uncompressed); +body+ is
    #   compressed otherwise
    # @param codec [Integer] codec id to compress +body+ with
    # @param crypto [Encryption::ModuleCrypto, nil] encryption of the column's modules
    # @param ordinal [Integer, nil] data page ordinal within the chunk; nil for a dictionary page
    # @return [Integer]
    def write_page(header, body, compressed = nil, codec: @codec, crypto: nil, ordinal: nil)
      parts = Array(compressed || compress(codec, body))
      header.uncompressed_page_size ||= Array(body).sum(&:bytesize)
      dictionary = header.type == Format::PageType::DICTIONARY_PAGE
      if crypto
        parts = [crypto.encrypt(dictionary ? Encryption::DICTIONARY_PAGE : Encryption::DATA_PAGE, parts.join, ordinal)]
      end
      header.compressed_page_size = parts.sum(&:bytesize)
      crc = parts.inject(0) { |c, part| Zlib.crc32(part, c) }
      header.crc = (crc >= 0x8000_0000) ? crc - 0x1_0000_0000 : crc
      encoded = header.encode
      if crypto
        encoded = crypto.encrypt(dictionary ? Encryption::DICTIONARY_PAGE_HEADER : Encryption::DATA_PAGE_HEADER, encoded, ordinal)
      end
      write_raw(encoded)
      parts.each { |part| write_raw(part) unless part.empty? }
      encoded.bytesize + header.uncompressed_page_size
    end

    # A DATA_PAGE: length-prefixed repetition and definition levels, then the values, all compressed
    #
    # @param n [Integer] number of level entries (values including nulls)
    # @param rep_bytes [String] RLE-encoded repetition levels, empty when the column has none
    # @param def_bytes [String] RLE-encoded definition levels, empty when the column has none
    # @param encoded [String] encoded values
    # @param encoding [Integer] encoding id of the values
    # @param codec [Integer] codec id to compress the page with
    # @param page_crypto [Array(Encryption::ModuleCrypto, Integer), nil] encryption of the column's
    #   modules and the page's ordinal, for an encrypted column
    # @return [Integer] uncompressed size including the header
    def write_data_page_v1(n, rep_bytes, def_bytes, encoded, encoding, codec, page_crypto)
      body = []
      body << [rep_bytes.bytesize].pack("V") << rep_bytes unless rep_bytes.empty?
      body << [def_bytes.bytesize].pack("V") << def_bytes unless def_bytes.empty?
      body << encoded
      header = Format::PageHeader.new(
        type: Format::PageType::DATA_PAGE,
        data_page_header: Format::DataPageHeader.new(
          num_values: n, encoding: encoding,
          definition_level_encoding: E::RLE, repetition_level_encoding: E::RLE
        )
      )
      write_page(header, body, codec: codec, crypto: page_crypto&.first, ordinal: page_crypto&.last)
    end

    # A DATA_PAGE_V2: levels without length prefixes and uncompressed, then the compressed values
    #
    # @param n [Integer] number of level entries (values including nulls)
    # @param nulls [Integer] null entries
    # @param rows [Integer] rows in the page
    # @param rep_bytes [String] RLE-encoded repetition levels, empty when the column has none
    # @param def_bytes [String] RLE-encoded definition levels, empty when the column has none
    # @param encoded [String] encoded values
    # @param encoding [Integer] encoding id of the values
    # @param codec [Integer] codec id to compress the values with
    # @param page_crypto [Array(Encryption::ModuleCrypto, Integer), nil] encryption of the column's
    #   modules and the page's ordinal, for an encrypted column
    # @return [Integer] uncompressed size including the header
    def write_data_page_v2(n, nulls, rows, rep_bytes, def_bytes, encoded, encoding, codec, page_crypto)
      compressed = compress(codec, encoded)
      header = Format::PageHeader.new(
        type: Format::PageType::DATA_PAGE_V2,
        uncompressed_page_size: rep_bytes.bytesize + def_bytes.bytesize + encoded.bytesize,
        data_page_header_v2: Format::DataPageHeaderV2.new(
          num_values: n, num_nulls: nulls, num_rows: rows, encoding: encoding,
          definition_levels_byte_length: def_bytes.bytesize,
          repetition_levels_byte_length: rep_bytes.bytesize,
          is_compressed: codec != Format::Codec::UNCOMPRESSED
        )
      )
      write_page(header, "".b, [rep_bytes, def_bytes, compressed], codec: codec, crypto: page_crypto&.first,
        ordinal: page_crypto&.last)
    end

    # Statistics and column index bounds longer than this are truncated, see #truncate_min
    STAT_TRUNCATE_BYTES = 64
    # Sort key for types whose Ruby ordering already matches Parquet's; compared by identity to
    # skip calling it
    IDENTITY = Ractor.make_shareable(->(v) { v })

    # Chunk statistics: null count, plus min/max (flagged exact unless truncated) when the column
    # has a sort order and non-NaN values
    #
    # @param col [Schema::Column] column the chunk belongs to
    # @param defs [Array<Integer>] definition levels of the chunk
    # @param values [Array] distinct or all non-null physical values of the chunk
    # @param order [Proc, Method, nil] sort key from #sort_key
    # @return [Format::Statistics]
    def statistics_for(col, defs, values, order)
      max_def = col.max_definition_level
      nulls = max_def.zero? ? 0 : defs.size - defs.count(max_def)
      stats = Format::Statistics.new(null_count: nulls)
      range = order && value_range(col, values, order)
      if range
        min = stat_bytes(col, range[0])
        max = stat_bytes(col, range[1])
        stats.min_value = truncate_min(min)
        stats.max_value = truncate_max(max)
        stats.is_min_value_exact = stats.min_value.bytesize == min.bytesize
        stats.is_max_value_exact = stats.max_value.bytesize == max.bytesize
      end
      stats
    end

    # A key giving the Parquet sort order of the column's physical values (IDENTITY when Ruby's own
    # comparison already matches), or nil when the order is undefined (INT96)
    #
    # @param col [Schema::Column] column to order
    # @return [Proc, Method, nil]
    def sort_key(col)
      kind, _, signed = Types.logical_of(col.node)
      case col.type
      when T::BOOLEAN then ->(v) { v ? 1 : 0 }
      when T::INT32, T::INT64
        return IDENTITY unless kind == :integer && !signed
        mask = (col.type == T::INT32) ? 0xFFFF_FFFF : 0xFFFF_FFFF_FFFF_FFFF
        ->(v) { v & mask }
      when T::FLOAT, T::DOUBLE then IDENTITY
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY
        case kind
        when :decimal then Types.method(:be_to_int)
        when :float16 then ->(v) { Types.half_to_float(v.unpack1("v")) }
        else IDENTITY # unsigned lexicographic, which is how Ruby compares binary Strings
        end
      end
    end

    # [min, max] of +values+ in column order, ignoring NaNs; nil if there is nothing to compare.
    # A zero float bound is normalized to -0.0 (min) / 0.0 (max), as the spec asks.
    #
    # @param col [Schema::Column] column the values belong to
    # @param values [Array] physical values
    # @param order [Proc, Method] sort key from #sort_key
    # @return [Array(Object, Object), nil]
    def value_range(col, values, order)
      floats = col.type == T::FLOAT || col.type == T::DOUBLE
      if floats
        values = values.reject(&:nan?)
      elsif Types.logical_of(col.node).first == :float16
        values = values.reject { |v| order.call(v).nan? }
      end
      return nil if values.empty?
      min, max = order.equal?(IDENTITY) ? values.minmax : values.minmax_by(&order)
      if floats
        min = -0.0 if min.zero?
        max = 0.0 if max.zero?
      end
      [min, max]
    end

    # @param col [Schema::Column] column the value belongs to
    # @param value [Object] physical value
    # @return [String] the value PLAIN-encoded, as statistics store it (byte arrays without length)
    def stat_bytes(col, value)
      case col.type
      when T::BOOLEAN then value ? "\x01".b : "\x00".b
      when T::INT32 then [value].pack("l<")
      when T::INT64 then [value].pack("q<")
      when T::FLOAT then [value].pack("e")
      when T::DOUBLE then [value].pack("E")
      else value.b
      end
    end

    # Long byte-array bounds are truncated: a prefix is still a lower bound for the minimum, and
    # a prefix with its last byte incremented is an upper bound for the maximum
    #
    # @param bytes [String] encoded minimum
    # @return [String] at most STAT_TRUNCATE_BYTES bytes
    def truncate_min(bytes)
      (bytes.bytesize > STAT_TRUNCATE_BYTES) ? bytes.byteslice(0, STAT_TRUNCATE_BYTES) : bytes
    end

    # @param bytes [String] encoded maximum
    # @return [String] at most STAT_TRUNCATE_BYTES bytes, with the last byte that is not 0xFF
    #   incremented (trailing 0xFF bytes dropped); +bytes+ unchanged when it fits, or when the
    #   whole prefix is 0xFF
    def truncate_max(bytes)
      return bytes if bytes.bytesize <= STAT_TRUNCATE_BYTES
      prefix = bytes.byteslice(0, STAT_TRUNCATE_BYTES).bytes
      prefix.pop while prefix.last == 0xFF
      return bytes if prefix.empty?
      prefix[-1] += 1
      prefix.pack("C*")
    end
  end
end
