# frozen_string_literal: true

module Herringbone
  # Writes Parquet files.
  #
  #   schema = Herringbone::Schema.define do
  #     int64 :id, null: false
  #     string :name
  #     list :tags, :string
  #   end
  #   Herringbone::Writer.open("out.parquet", schema) do |w|
  #     w << { "id" => 1, "name" => "one", "tags" => ["a", "b"] }
  #     w << [2, "two", []]           # Arrays are taken in schema order
  #     w << order                    # objects responding to #attributes (ActiveRecord) or #to_h
  #   end
  #
  # +schema+ is a Herringbone::Schema or a Hash spec (see Schema.define). The target is a path or an IO;
  # paths are written to a temporary file next to the target and renamed into place on close, so a
  # failed write never leaves a truncated file behind.
  #
  # Options:
  #   compression:     :snappy (default), :zstd, :gzip, :lz4 (LZ4_RAW), :lz4_hadoop, :brotli, :none
  #                    (:zstd and :brotli need the zstd-ruby / brotli gems)
  #   row_group_bytes: flush a row group once the buffered values take roughly this much memory
  #                    (default 16MB). This bounds memory use while writing.
  #   row_group_size:  also flush after this many rows (default: no row limit)
  #   page_size:       approximate uncompressed data page size in bytes (default 1MB)
  #   data_page_version: 1 (default) or 2
  #   dictionary:      true/false, or an Array of column paths to dictionary-encode
  #   encodings:       { "path.to.column" => :delta_binary_packed, ... } for non-dictionary pages
  #   statistics:      write min/max/null_count statistics (default true)
  #   metadata:        Hash of String => String key/value metadata for the footer
  class Writer
    MAGIC = "PAR1"
    T = Format::Type
    E = Format::Encoding

    ENCODING_NAMES = {
      plain: E::PLAIN, rle: E::RLE, delta_binary_packed: E::DELTA_BINARY_PACKED,
      delta_length_byte_array: E::DELTA_LENGTH_BYTE_ARRAY, delta_byte_array: E::DELTA_BYTE_ARRAY,
      byte_stream_split: E::BYTE_STREAM_SPLIT
    }.freeze

    VALID_ENCODINGS = {
      E::PLAIN => T::NAMES.keys,
      E::RLE => [T::BOOLEAN],
      E::DELTA_BINARY_PACKED => [T::INT32, T::INT64],
      E::DELTA_LENGTH_BYTE_ARRAY => [T::BYTE_ARRAY],
      E::DELTA_BYTE_ARRAY => [T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY],
      E::BYTE_STREAM_SPLIT => [T::INT32, T::INT64, T::FLOAT, T::DOUBLE, T::FIXED_LEN_BYTE_ARRAY]
    }.freeze

    MAX_DICTIONARY_BYTES = 1024 * 1024
    # The row group byte size is first estimated after this many rows, then after every row group
    ESTIMATE_AFTER_ROWS = 1000

    attr_reader :schema

    # Opens a writer on a path or an IO. With a block, the file is finished when the block returns
    # (or discarded if it raises) and the block's value is returned; without one, call #close.
    def self.open(target, schema, **options)
      writer = new(target, schema, **options)
      return writer unless block_given?
      begin
        result = yield writer
      rescue Exception # rubocop:disable Lint/RescueException -- also discard on Interrupt
        writer.abort
        raise
      end
      writer.close
      result
    end

    def initialize(target, schema, compression: :snappy, row_group_bytes: 16 * 1024 * 1024, row_group_size: nil,
      page_size: 1024 * 1024, data_page_version: 1, dictionary: true, encodings: {}, statistics: true, metadata: {})
      @schema = Schema.coerce(schema)
      schema = @schema
      @codec = Compression.codec_id(compression)
      # Fail before creating any file if the codec's library is missing
      Compression.ensure_available!(@codec)
      @row_group_bytes = Integer(row_group_bytes)
      @row_group_size = row_group_size && Integer(row_group_size)
      @row_limit = @row_group_size || ESTIMATE_AFTER_ROWS
      @page_size = Integer(page_size)
      @data_page_version = Integer(data_page_version)
      raise ArgumentError, "data_page_version must be 1 or 2" unless [1, 2].include?(@data_page_version)
      @dictionary = dictionary
      @encodings = encodings.to_h { |path, enc| [path.to_s, encoding_id(path, enc)] }
      unknown = @encodings.keys - schema.columns.map(&:dotted_path)
      raise ArgumentError, "encodings: no such column #{unknown.join(", ")}" unless unknown.empty?
      @statistics = statistics
      @metadata = metadata
      @row_groups = []
      @total_rows = 0
      @pos = 0
      @closed = false
      @bytes_per_row = nil
      open_target(target)
      write_raw(MAGIC)
      reset_buffers
    end

    # Appends a row: a Hash keyed by top-level field names (Strings or Symbols), an Array of values
    # in schema order, or an object responding to #attributes (ActiveRecord) or #to_h (Struct, Data)
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
            raise EncodeError, "Field #{name} is required but got nil" unless field.optional
            buf.defs << 0
          else
            begin
              buf.values << encoder.call(value)
            rescue ArgumentError, TypeError, NoMethodError, RangeError => e
              raise EncodeError, "Cannot write #{value.inspect} to #{name}: #{e.message}"
            end
            buf.defs << field.def_level
          end
        end
      rescue EncodeError => e
        rollback_row(marks)
        raise EncodeError, "Row #{@total_rows + @buffered_rows}: #{e.message}"
      rescue StandardError
        rollback_row(marks)
        raise
      end
      @buffered_rows += 1
      check_row_group_size if @buffered_rows >= @row_limit
      self
    end
    alias_method :write, :<<

    def write_rows(rows)
      rows.each { |row| self << row }
      self
    end

    # Number of rows written so far, including buffered ones
    def rows_written = @total_rows + @buffered_rows

    # Writes any buffered rows as a row group
    def flush_row_group
      return if @buffered_rows.zero?
      start = @pos
      chunks = @schema.columns.map { |col| write_column_chunk(col, @buffers[col.index]) }
      @row_groups << Format::RowGroup.new(
        columns: chunks,
        total_byte_size: chunks.sum { |c| c.meta_data.total_uncompressed_size },
        num_rows: @buffered_rows,
        file_offset: start,
        total_compressed_size: @pos - start,
        ordinal: @row_groups.size
      )
      @total_rows += @buffered_rows
      reset_buffers
    end

    def close
      return if @closed
      flush_row_group
      meta = Format::FileMetaData.new(
        version: 2,
        schema: @schema.to_elements,
        num_rows: @total_rows,
        row_groups: @row_groups,
        key_value_metadata: @metadata.empty? ? nil : @metadata.map { |k, v| Format::KeyValue.new(key: k.to_s, value: v&.to_s) },
        created_by: "herringbone version #{VERSION}",
        column_orders: @schema.columns.map { Format::ColumnOrder.new(type_order: Format::TypeDefinedOrder.new) }
      )
      footer = meta.encode
      write_raw(footer)
      write_raw([footer.bytesize].pack("V"))
      write_raw(MAGIC)
      @io.flush if @io.respond_to?(:flush)
      @closed = true
      finish_target
    end

    # Stops writing without producing a file: a temporary file is deleted, an IO is left as is
    def abort
      return if @closed
      @closed = true
      return unless @temp_path
      @io.close unless @io.closed?
      File.unlink(@temp_path) if File.exist?(@temp_path)
    end

    private

    # Levels are kept as binary Strings (one byte per entry). Values are an Array for numeric and
    # boolean columns, and a compact ByteValues for BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY columns.
    ColumnBuffer = Struct.new(:defs, :reps, :values)

    def reset_buffers
      @buffers = @schema.columns.map do |col|
        if col.max_definition_level > 255 || col.max_repetition_level > 255
          raise UnsupportedError, "Column #{col.dotted_path} is nested too deeply"
        end
        ColumnBuffer.new(String.new(encoding: Encoding::BINARY),
          col.max_repetition_level.positive? ? String.new(encoding: Encoding::BINARY) : nil,
          new_values_store(col))
      end
      # Top-level, non-repeated leaves are written directly, everything else is shredded
      @plan = @schema.fields.map do |field|
        flat = field.leaf? && field.column.max_repetition_level.zero?
        [field, field.name, field.name.to_sym, flat ? @buffers[field.column.index] : nil, flat ? field.column.encoder : nil]
      end
      @nested_buffers = @plan.reject { |p| p[3] }.flat_map { |p| p[0].leaves.map { |c| @buffers[c.index] } }
      @buffered_rows = 0
    end

    def new_values_store(col)
      case col.type
      when T::BYTE_ARRAY then ByteValues.new(dictionary: use_dictionary?(col))
      when T::FIXED_LEN_BYTE_ARRAY then ByteValues.new(width: col.type_length, dictionary: use_dictionary?(col))
      else []
      end
    end

    def open_target(target)
      if target.respond_to?(:write)
        @io = target
      else
        @path = target.to_s
        dir = File.dirname(@path)
        @temp_path = File.join(dir, ".#{File.basename(@path)}.#{Process.pid}.#{rand(1 << 32).to_s(36)}.tmp")
        @io = File.open(@temp_path, "wb")
      end
    end

    def finish_target
      return unless @temp_path
      @io.close
      File.rename(@temp_path, @path)
    end

    # Flushes when the buffered values reach row_group_bytes (or row_group_size rows). The bytes per
    # row are estimated from the buffered values after the first rows, then refreshed per row group.
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

    def row_limit_for(bytes_per_row)
      by_bytes = [@row_group_bytes / [bytes_per_row, 1].max, ESTIMATE_AFTER_ROWS].max
      @row_group_size ? [@row_group_size, by_bytes].min : by_bytes
    end

    def estimate_bytes_per_row
      bytes = @schema.columns.sum do |col|
        buf = @buffers[col.index]
        values = buf.values
        held = if values.is_a?(ByteValues)
          values.memory_bytes
        else
          values.size * (col.type == T::INT96 ? 48 : 8)
        end
        held + buf.defs.bytesize + (buf.reps ? buf.reps.bytesize : 0)
      end
      bytes / [@buffered_rows, 1].max
    end

    def write_raw(bytes)
      @io.write(bytes)
      @pos += bytes.bytesize
    end

    def encoding_id(path, enc)
      return enc if enc.is_a?(Integer)
      ENCODING_NAMES.fetch(enc.to_s.downcase.to_sym) { raise ArgumentError, "Unknown encoding #{enc.inspect} for #{path}" }
    end

    def lookup(hash, name)
      return nil if hash.nil?
      hash = as_hash(hash, name) unless hash.is_a?(Hash)
      hash.fetch(name) { hash[name.to_sym] }
    end

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

    def as_hash(value, what)
      return value if value.is_a?(Hash)
      raise EncodeError, "Expected a Hash for #{what}, got #{value.class}" unless value.respond_to?(:to_h)
      value.to_h
    end

    # Removes the entries a failed row left behind, so the buffers stay aligned
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
    def shred(field, value, parent_def, rep)
      if value.nil?
        raise EncodeError, "Field #{field.node.path.join(".")} is required but got nil" unless field.optional
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
          buf.values << field.column.encoder.call(value)
        rescue ArgumentError, TypeError, NoMethodError, RangeError => e
          raise EncodeError, "Cannot write #{value.inspect} to #{field.column.dotted_path}: #{e.message}"
        end
      when :struct
        field.children.each { |ch| shred(ch, lookup(value, ch.name), d, rep) }
      when :list
        raise EncodeError, "Expected an Array for #{field.node.path.join(".")}, got #{value.class}" unless value.respond_to?(:each_with_index)
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
        raise EncodeError, "Expected a Hash for #{field.node.path.join(".")}, got #{value.class}" unless value.respond_to?(:each_pair) || value.is_a?(Array)
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

    def write_column_chunk(col, buffer)
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
        enc = @encodings[path] || E::PLAIN
        unless VALID_ENCODINGS.fetch(enc).include?(type)
          raise ArgumentError, "Encoding #{E::NAMES[enc]} is not valid for #{T::NAMES[type]} column #{path}"
        end
        enc
      end

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
        uncompressed_total += write_page(header, plain)
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
      page_ranges(buf, value_bytes).each do |from, to|
        n = to - from
        defs = buf.defs[from, n]
        reps = buf.reps&.slice(from, n)
        non_null = max_def.zero? ? n : defs.count(max_def)
        page_values = (indices || values)[value_index, non_null]
        value_index += non_null
        encoded = encode_values(page_values, value_encoding, type, col.type_length, dict_values&.size)
        rep_bytes = max_rep.positive? ? Encodings::RLE.encode_hybrid(reps, max_rep.bit_length) : "".b
        def_bytes = max_def.positive? ? Encodings::RLE.encode_hybrid(defs, max_def.bit_length) : "".b
        uncompressed_total += if @data_page_version == 1
          write_data_page_v1(n, rep_bytes, def_bytes, encoded, value_encoding)
        else
          num_rows = max_rep.zero? ? n : reps.count(0)
          write_data_page_v2(n, n - non_null, num_rows, rep_bytes, def_bytes, encoded, value_encoding)
        end
      end

      encodings = [E::RLE]
      encodings << E::PLAIN if dict_values
      encodings << value_encoding
      meta = Format::ColumnMetaData.new(
        type: type,
        encodings: encodings.uniq,
        path_in_schema: col.path,
        codec: @codec,
        num_values: buf.defs.size,
        total_uncompressed_size: uncompressed_total,
        total_compressed_size: @pos - chunk_start,
        data_page_offset: data_offset,
        dictionary_page_offset: dictionary_offset,
        statistics: @statistics ? statistics_for(col, buf.defs, values || indices.uniq.map { |i| dict_values[i] }) : nil
      )
      Format::ColumnChunk.new(file_offset: chunk_start, meta_data: meta)
    end

    def use_dictionary?(col)
      return false if col.type == T::BOOLEAN
      case @dictionary
      when true then ![T::BOOLEAN, T::FLOAT, T::DOUBLE].include?(col.type) && !@encodings.key?(col.dotted_path)
      when false, nil then false
      else Array(@dictionary).map(&:to_s).include?(col.dotted_path)
      end
    end

    # Returns [dictionary_values, indices] or nil when a dictionary is not worthwhile
    def build_dictionary(values, type, type_length)
      # Floats are keyed by bit pattern so that -0.0 and 0.0 (and NaNs) stay distinct
      if type == T::FLOAT || type == T::DOUBLE
        keys = values.pack("G*").unpack("Q>*")
        uniq = keys.uniq
        return nil if uniq.size > values.size / 2 + 1 && values.size > 16
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

    # Splits a column buffer into pages of roughly @page_size bytes. Repeated columns
    # are only cut where a new row starts.
    def page_ranges(buf, value_bytes)
      n = buf.defs.size
      bytes = n + value_bytes
      pages = (bytes + @page_size - 1) / @page_size
      return [[0, n]] if pages <= 1
      per = (n + pages - 1) / pages
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

    def value_width(col)
      case col.type
      when T::BOOLEAN then 1
      when T::INT32, T::FLOAT then 4
      when T::INT64, T::DOUBLE then 8
      when T::INT96 then 12
      when T::FIXED_LEN_BYTE_ARRAY then col.type_length
      end
    end

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
        Encodings::Delta.encode_binary_packed(values, type == T::INT32 ? 32 : 64)
      when E::DELTA_LENGTH_BYTE_ARRAY then Encodings::Delta.encode_length_byte_array(values)
      when E::DELTA_BYTE_ARRAY then Encodings::Delta.encode_byte_array(values)
      when E::BYTE_STREAM_SPLIT
        width = { T::INT32 => 4, T::FLOAT => 4, T::INT64 => 8, T::DOUBLE => 8 }[type] || type_length
        Encodings::ByteStreamSplit.encode(Encodings::Plain.encode(values, type, type_length), width)
      end
    end

    # Writes a page, returning the uncompressed size including the header
    def write_page(header, body, compressed = nil)
      compressed ||= Compression.compress(@codec, body)
      header.uncompressed_page_size ||= body.bytesize
      header.compressed_page_size = compressed.bytesize
      header.crc = Zlib.crc32(compressed).then { |c| c >= 0x8000_0000 ? c - 0x1_0000_0000 : c }
      encoded = header.encode
      write_raw(encoded)
      write_raw(compressed)
      encoded.bytesize + header.uncompressed_page_size
    end

    def write_data_page_v1(n, rep_bytes, def_bytes, encoded, encoding)
      body = String.new(encoding: Encoding::BINARY)
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
      write_page(header, body)
    end

    def write_data_page_v2(n, nulls, rows, rep_bytes, def_bytes, encoded, encoding)
      compressed = Compression.compress(@codec, encoded)
      header = Format::PageHeader.new(
        type: Format::PageType::DATA_PAGE_V2,
        uncompressed_page_size: rep_bytes.bytesize + def_bytes.bytesize + encoded.bytesize,
        data_page_header_v2: Format::DataPageHeaderV2.new(
          num_values: n, num_nulls: nulls, num_rows: rows, encoding: encoding,
          definition_levels_byte_length: def_bytes.bytesize,
          repetition_levels_byte_length: rep_bytes.bytesize,
          is_compressed: @codec != Format::Codec::UNCOMPRESSED
        )
      )
      write_page(header, "".b, rep_bytes + def_bytes + compressed)
    end

    def statistics_for(col, defs, values)
      max_def = col.max_definition_level
      nulls = max_def.zero? ? 0 : defs.size - defs.count(max_def)
      stats = Format::Statistics.new(null_count: nulls)
      min, max = min_max(col, values)
      if min
        stats.min_value = min
        stats.max_value = max
        stats.is_min_value_exact = true
        stats.is_max_value_exact = true
      end
      stats
    end

    # Min/max for types whose Parquet sort order matches Ruby's comparison of the physical values
    def min_max(col, values)
      return nil if values.empty?
      kind, _, signed = Types.logical_of(col.node)
      case col.type
      when T::BOOLEAN
        [values.include?(false) ? "\x00".b : "\x01".b, values.include?(true) ? "\x01".b : "\x00".b]
      when T::INT32, T::INT64
        return nil if kind == :integer && !signed
        fmt = col.type == T::INT32 ? "l<" : "q<"
        min, max = values.minmax
        [[min].pack(fmt), [max].pack(fmt)]
      when T::FLOAT, T::DOUBLE
        finite = values.reject(&:nan?)
        return nil if finite.empty?
        min, max = finite.minmax
        min = -0.0 if min.zero?
        max = 0.0 if max.zero?
        fmt = col.type == T::FLOAT ? "e" : "E"
        [[min].pack(fmt), [max].pack(fmt)]
      when T::BYTE_ARRAY
        return nil if kind == :decimal
        min, max = values.minmax
        return nil if min.bytesize > 1024 || max.bytesize > 1024
        [min, max]
      end
    end
  end
end
