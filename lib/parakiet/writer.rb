# frozen_string_literal: true

module Parakiet
  # Writes Parquet files.
  #
  #   schema = Parakiet::Schema.define do
  #     int64 :id, null: false
  #     string :name
  #     list :tags, :string
  #   end
  #   Parakiet::Writer.open("out.parquet", schema, compression: :snappy) do |w|
  #     w << { "id" => 1, "name" => "one", "tags" => ["a", "b"] }
  #   end
  #
  # Options:
  #   compression:     :snappy (default), :gzip, :lz4 (LZ4_RAW), :zstd, :brotli, :none
  #   row_group_size:  rows per row group (default 100_000)
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

    attr_reader :schema

    def self.open(path, schema, **options)
      io = File.open(path, "wb")
      writer = new(io, schema, **options)
      return writer unless block_given?
      begin
        yield writer
        writer.close
      ensure
        io.close unless io.closed?
      end
    end

    def initialize(io, schema, compression: :snappy, row_group_size: 100_000, page_size: 1024 * 1024,
      data_page_version: 1, dictionary: true, encodings: {}, statistics: true, metadata: {})
      @io = io
      @schema = schema
      @codec = Compression.codec_id(compression)
      @row_group_size = Integer(row_group_size)
      @page_size = Integer(page_size)
      @data_page_version = Integer(data_page_version)
      raise ArgumentError, "data_page_version must be 1 or 2" unless [1, 2].include?(@data_page_version)
      @dictionary = dictionary
      @encodings = encodings.to_h { |path, enc| [path.to_s, encoding_id(path, enc)] }
      @statistics = statistics
      @metadata = metadata
      @row_groups = []
      @total_rows = 0
      @pos = 0
      @closed = false
      write_raw(MAGIC)
      reset_buffers
    end

    # Appends a row (a Hash keyed by top-level field names, as Strings or Symbols)
    def <<(row)
      raise Error, "Writer is closed" if @closed
      row = row.to_h unless row.is_a?(Hash)
      @plan.each do |field, name, sym, buf, encoder|
        value = row.fetch(name) { row[sym] }
        if buf.nil?
          shred(field, value, 0, 0)
        elsif value.nil?
          raise EncodeError, "Field #{name} is required but got nil" unless field.optional
          buf.defs << 0
        else
          buf.defs << field.def_level
          begin
            buf.values << encoder.call(value)
          rescue ArgumentError, TypeError, NoMethodError => e
            raise EncodeError, "Cannot write #{value.inspect} to #{name}: #{e.message}"
          end
        end
      end
      @buffered_rows += 1
      flush_row_group if @buffered_rows >= @row_group_size
      self
    end
    alias_method :write, :<<

    def write_rows(rows)
      rows.each { |row| self << row }
      self
    end

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
        created_by: "parakiet version #{VERSION}",
        column_orders: @schema.columns.map { Format::ColumnOrder.new(type_order: Format::TypeDefinedOrder.new) }
      )
      footer = meta.encode
      write_raw(footer)
      write_raw([footer.bytesize].pack("V"))
      write_raw(MAGIC)
      @io.flush if @io.respond_to?(:flush)
      @closed = true
    end

    private

    ColumnBuffer = Struct.new(:defs, :reps, :values)

    def reset_buffers
      @buffers = @schema.columns.map do |col|
        ColumnBuffer.new([], col.max_repetition_level.positive? ? [] : nil, [])
      end
      # Top-level, non-repeated leaves are written directly, everything else is shredded
      @plan = @schema.fields.map do |field|
        flat = field.leaf? && field.column.max_repetition_level.zero?
        [field, field.name, field.name.to_sym, flat ? @buffers[field.column.index] : nil, flat ? field.column.encoder : nil]
      end
      @buffered_rows = 0
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
      hash = hash.to_h unless hash.is_a?(Hash)
      hash.fetch(name) { hash[name.to_sym] }
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
        rescue ArgumentError, TypeError, NoMethodError => e
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

    def write_column_chunk(col, buf)
      type = col.type
      values = buf.values
      path = col.dotted_path
      dict_values = nil
      indices = nil
      if use_dictionary?(col) && !values.empty?
        dict_values, indices = build_dictionary(values, type, col.type_length)
      end
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
      page_ranges(buf, col).each do |from, to|
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
        statistics: @statistics ? statistics_for(col, buf) : nil
      )
      Format::ColumnChunk.new(file_offset: chunk_start, meta_data: meta)
    end

    def use_dictionary?(col)
      case @dictionary
      when true then ![T::BOOLEAN, T::FLOAT, T::DOUBLE].include?(col.type) && !@encodings.key?(col.dotted_path)
      when false, nil then false
      else Array(@dictionary).map(&:to_s).include?(col.dotted_path)
      end
    end

    # Returns [dictionary_values, indices] or nil when a dictionary is not worthwhile
    def build_dictionary(values, type, type_length)
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
    def page_ranges(buf, col)
      n = buf.defs.size
      width = value_width(col)
      values = buf.values
      bytes = n + (width ? values.size * width : values.sum(&:bytesize) + 4 * values.size)
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

    def statistics_for(col, buf)
      max_def = col.max_definition_level
      nulls = max_def.zero? ? 0 : buf.defs.count { |d| d < max_def }
      stats = Format::Statistics.new(null_count: nulls)
      min, max = min_max(col, buf.values)
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
