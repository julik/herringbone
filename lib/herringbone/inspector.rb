# frozen_string_literal: true

require "json"

module Herringbone
  # Examines a Parquet file using only its footer, page headers and page indexes. Values are
  # never decompressed or decoded, so this works for files whose codecs are not installed and
  # stays fast for big files (it seeks from page header to page header).
  #
  #   File.open("data.parquet", "rb") do |io|
  #     inspector = Herringbone::Inspector.new(io)   # or a Reader
  #     ...
  #   end
  #
  #   inspector.summary                      # => { size:, num_rows:, created_by:, ... }
  #   inspector.row_groups[0].columns[1].pages
  #   inspector.pages(0, "name")             # page headers of one column chunk
  #   inspector.column_totals                # per-column sums across row groups
  #   inspector.to_h                         # everything, JSON-serializable
  #   puts inspector.report                  # readable text summary (bin/herringbone inspect --text)
  #
  # Page headers and indexes are read lazily; Herringbone.inspect_file(io) (or #load_all) reads
  # them all up front, after which the inspector no longer needs the IO. The IO is never closed.
  class Inspector
    T = Format::Type
    MAGIC = "PAR1"
    WINDOW = 64 * 1024

    # Just enough of parquet.thrift's BloomFilterHeader to learn the filter's size
    class BloomFilterHeader < Thrift::Struct
      field 1, :num_bytes, :i32
    end

    # Decoded min/max statistics (from a column chunk, a page header or a page index entry)
    Stats = Struct.new(:min, :max, :null_count, :distinct_count, :min_exact, :max_exact, :source, :caveat,
      keyword_init: true) do
      def to_h = Inspector.jsonable(super.compact)
    end

    # One page header of a column chunk
    PageInfo = Struct.new(:index, :type, :offset, :header_size, :compressed_size, :uncompressed_size,
      :num_values, :num_nulls, :num_rows, :first_row_index, :encoding, :definition_level_encoding,
      :repetition_level_encoding, :definition_levels_byte_length, :repetition_levels_byte_length,
      :is_compressed, :is_sorted, :statistics, :crc, keyword_init: true) do
      def total_size = header_size + compressed_size
      def end_offset = offset + total_size
      def dictionary? = type == :DICTIONARY_PAGE
      def data? = type == :DATA_PAGE || type == :DATA_PAGE_V2

      def to_h
        h = super
        h[:statistics] = statistics&.to_h
        h[:crc] = !crc.nil?
        Inspector.jsonable(h.compact)
      end
    end

    # ColumnIndex of one column chunk, with min/max decoded per page (nil for all-null pages)
    ColumnIndexInfo = Struct.new(:offset, :length, :null_pages, :min_values, :max_values, :boundary_order,
      :null_counts, :repetition_level_histograms, :definition_level_histograms, keyword_init: true) do
      def to_h = Inspector.jsonable(super.compact)
    end

    PageLocation = Struct.new(:offset, :compressed_page_size, :first_row_index, keyword_init: true)

    OffsetIndexInfo = Struct.new(:offset, :length, :page_locations, :unencoded_byte_array_data_bytes,
      keyword_init: true) do
      def to_h
        h = super
        h[:page_locations] = page_locations.map(&:to_h)
        h.compact
      end
    end

    # One column chunk of a row group
    class ColumnChunkInfo
      attr_reader :inspector, :row_group, :column, :chunk, :meta, :error

      def initialize(inspector, row_group, column, chunk)
        @inspector = inspector
        @row_group = row_group
        @column = column
        @chunk = chunk
        @meta = chunk.meta_data
      end

      def path = @column.dotted_path
      def column_index_number = @column.index
      def codec = Format::Codec::NAMES[@meta.codec] || @meta.codec
      def encodings = (@meta.encodings || []).map { |e| Inspector.encoding_name(e) }
      def num_values = @meta.num_values
      def compressed_size = @meta.total_compressed_size
      def uncompressed_size = @meta.total_uncompressed_size
      def data_page_offset = @meta.data_page_offset
      def external_file = @chunk.file_path

      def compression_ratio
        compressed_size.to_i.positive? ? uncompressed_size.to_f / compressed_size : nil
      end

      # Some writers store 0 when there is no dictionary page, and some store a data_page_offset
      # of 0 for empty chunks (which would point at the magic bytes)
      def dictionary_page_offset
        d = @meta.dictionary_page_offset
        d && d >= 4 && (d < @meta.data_page_offset.to_i || @meta.data_page_offset.to_i < 4) ? d : nil
      end

      # Where the chunk's first page starts
      def start_offset = dictionary_page_offset || data_page_offset

      # The end according to the metadata; some writers under-report it (see #end_offset)
      def declared_end_offset = start_offset + compressed_size

      # The end of the last page actually found (the declared end if the pages could not be walked)
      def end_offset
        last = pages.last
        last ? [last.end_offset, declared_end_offset].max : declared_end_offset
      end

      def encoding_stats
        (@meta.encoding_stats || []).map do |s|
          { page_type: Format::PageType::NAMES[s.page_type] || s.page_type,
            encoding: Inspector.encoding_name(s.encoding), count: s.count }
        end
      end

      def statistics
        return @statistics if defined?(@statistics)
        @statistics = @inspector.decode_statistics(@meta.statistics, @column)
      end

      def size_statistics
        s = @meta.size_statistics
        s&.to_h
      end

      def key_value_metadata
        (@meta.key_value_metadata || []).to_h { |kv| [kv.key, kv.value] }
      end

      def bloom_filter_offset = @meta.bloom_filter_offset

      # Bytes taken by the bloom filter (header + bitset); read from its header when the footer has no length
      def bloom_filter_length
        return nil unless bloom_filter_offset
        return @meta.bloom_filter_length if @meta.bloom_filter_length
        return @bloom_filter_length if defined?(@bloom_filter_length)
        @bloom_filter_length = @inspector.bloom_filter_size(bloom_filter_offset)
      end

      def column_index_range
        o = @chunk.column_index_offset
        o && @chunk.column_index_length ? [o, @chunk.column_index_length] : nil
      end

      def offset_index_range
        o = @chunk.offset_index_offset
        o && @chunk.offset_index_length ? [o, @chunk.offset_index_length] : nil
      end

      # All page headers, in file order. Errors while walking (corrupt or truncated headers) end
      # the walk; #error then says what went wrong and #pages holds the pages found before it.
      def pages
        @pages ||= begin
          list, @error = @inspector.walk_pages(self)
          apply_offset_index(list)
          list
        end
      end

      def data_pages = pages.select(&:data?)
      def dictionary_page = pages.find(&:dictionary?)

      # Number of entries in the dictionary (from its page header)
      def dictionary_size = dictionary_page&.num_values

      def column_index
        return @column_index if defined?(@column_index)
        @column_index = @inspector.read_column_index(self)
      end

      def offset_index
        return @offset_index if defined?(@offset_index)
        @offset_index = @inspector.read_offset_index(self)
      end

      def null_count
        return statistics.null_count if statistics&.null_count
        counts = data_pages.map(&:num_nulls)
        counts.all? ? counts.sum : nil
      end

      def to_h(pages: true, page_indexes: true)
        h = {
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
          dictionary: dictionary_page && { offset: dictionary_page.offset, num_values: dictionary_page.num_values,
            compressed_size: dictionary_page.compressed_size, uncompressed_size: dictionary_page.uncompressed_size,
            is_sorted: dictionary_page.is_sorted },
          statistics: statistics&.to_h,
          size_statistics: size_statistics,
          key_value_metadata: key_value_metadata.empty? ? nil : key_value_metadata,
          bloom_filter: bloom_filter_offset && { offset: bloom_filter_offset, length: bloom_filter_length },
          column_index_offset: column_index_range&.first,
          column_index_length: column_index_range&.last,
          offset_index_offset: offset_index_range&.first,
          offset_index_length: offset_index_range&.last,
          external_file: external_file,
          num_pages: self.pages.size,
          num_data_pages: data_pages.size,
          error: error
        }
        h[:pages] = self.pages.map(&:to_h) if pages
        if page_indexes
          h[:column_index] = column_index&.to_h
          h[:offset_index] = offset_index&.to_h
        end
        Inspector.jsonable(h.compact)
      end

      def inspect
        "#<#{self.class.name} #{path} rg=#{@row_group.index} #{codec} #{compressed_size}/#{uncompressed_size} bytes>"
      end

      private

      # Page row counts come from the offset index when there is one (v1 pages don't carry them)
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

      def num_rows = @row_group.num_rows
      def first_row = @first_row
      def total_byte_size = @row_group.total_byte_size
      def compressed_size = @row_group.total_compressed_size || @columns.sum(&:compressed_size)
      def uncompressed_size = @columns.sum { |c| c.uncompressed_size.to_i }
      def start_offset = @columns.map(&:start_offset).min
      def end_offset = @columns.map(&:end_offset).max
      def column(path) = @columns.find { |c| c.path == path.to_s || c.column.path == Array(path) }

      def sorting_columns
        (@row_group.sorting_columns || []).map do |s|
          { column: @columns[s.column_idx]&.path || s.column_idx, descending: s.descending, nulls_first: s.nulls_first }
        end
      end

      def to_h(pages: true, page_indexes: true)
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
          columns: @columns.map { |c| c.to_h(pages: pages, page_indexes: page_indexes) }
        }.compact)
      end

      def inspect
        "#<#{self.class.name} #{index} rows=#{num_rows} columns=#{@columns.size}>"
      end
    end

    attr_reader :metadata, :schema, :file_size, :footer_size

    # A label for the file (the basename of the IO's path, when it has one)
    attr_reader :name

    # +source+ is a random-access IO (responds to #seek and #read, e.g. File.open(path, "rb")) or a
    # Reader. The IO is left open.
    def initialize(source)
      @io = source.is_a?(Reader) ? source.io : source
      unless @io.respond_to?(:read) && @io.respond_to?(:seek)
        raise ArgumentError, "Herringbone::Inspector expects an IO that supports #seek and #read " \
          "(e.g. File.open(path, \"rb\")) or a Herringbone::Reader, got #{source.class}"
      end
      @name = @io.respond_to?(:path) && @io.path ? File.basename(@io.path.to_s) : nil
      read_footer
      @schema = Schema.from_elements(@metadata.schema)
    end

    def self.from_string(bytes) = new(StringIO.new(bytes.b))

    def num_rows = @metadata.num_rows
    def created_by = @metadata.created_by
    def version = @metadata.version
    def columns = @schema.columns
    def footer_offset = @file_size - 8 - @footer_size

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

    def column_chunks = row_groups.flat_map(&:columns)

    # Page headers of one column chunk; +column+ is a leaf index, a dotted path or a path Array
    def pages(row_group, column) = chunk(row_group, column).pages

    def chunk(row_group, column)
      rg = row_groups.fetch(row_group)
      if column.is_a?(Integer)
        rg.columns.fetch(column)
      else
        rg.column(column.is_a?(Array) ? column.join(".") : column) or raise ArgumentError, "No such column #{column.inspect}"
      end
    end

    # Walks every page header and page index now (e.g. before closing the file)
    def load_all
      column_chunks.each do |c|
        c.pages
        c.column_index
        c.offset_index
        c.bloom_filter_length
      end
      self
    end

    def page_index? = column_chunks.any? { |c| c.column_index_range || c.offset_index_range }
    def bloom_filters? = column_chunks.any?(&:bloom_filter_offset)

    def key_value_metadata
      (@metadata.key_value_metadata || []).map { |kv| describe_key_value(kv.key, kv.value) }
    end

    def column_orders
      orders = @metadata.column_orders or return nil
      orders.map { |o| o.type_order ? "TYPE_DEFINED_ORDER" : "UNKNOWN" }
    end

    def summary
      codecs = column_chunks.map(&:codec).uniq
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
        column_orders: column_orders
      }
    end

    # Schema tree: Hashes with name, repetition, types, levels (leaves) and children (groups)
    def schema_tree
      leaf_by_node = @schema.columns.to_h { |c| [c.node, c] }
      build = lambda do |node|
        h = { name: node.name, repetition: node.repetition }
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
      @schema.root.children.map { |c| build.call(c) }
    end

    # Per leaf column: sums over all row groups, plus overall min/max where comparable
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
          codecs: chunks.map(&:codec).uniq,
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
          min: mins.all? ? safe_extreme(mins, :min) : nil,
          max: maxes.all? ? safe_extreme(maxes, :max) : nil
        }.compact
      end
    end

    # Byte ranges of the whole file, in offset order: magic, pages (or whole chunks when their pages
    # could not be walked), bloom filters, page indexes, footer. Gaps right after a chunk at its
    # file_offset are inline :column_metadata copies; other gaps are reported as :unknown. Each entry: { kind:, start:, length:, row_group:, column:, page: }
    def layout
      segs = [{ kind: :magic, start: 0, length: 4 }]
      column_chunks.each do |c|
        rg = c.row_group.index
        col = c.column.index
        if c.pages.empty?
          segs << { kind: :chunk, start: c.start_offset, length: c.compressed_size, row_group: rg, column: col }
        else
          c.pages.each_with_index do |p, i|
            segs << { kind: p.dictionary? ? :dictionary_page : :data_page, start: p.offset, length: p.total_size,
                      row_group: rg, column: col, page: i }
          end
        end
        if c.bloom_filter_offset
          segs << { kind: :bloom_filter, start: c.bloom_filter_offset, length: c.bloom_filter_length.to_i,
                    row_group: rg, column: col }
        end
        if (r = c.column_index_range)
          segs << { kind: :column_index, start: r[0], length: r[1], row_group: rg, column: col }
        end
        if (r = c.offset_index_range)
          segs << { kind: :offset_index, start: r[0], length: r[1], row_group: rg, column: col }
        end
      end
      segs << { kind: :footer, start: footer_offset, length: @footer_size }
      segs << { kind: :footer_length, start: @file_size - 8, length: 4 }
      segs << { kind: :magic, start: @file_size - 4, length: 4 }
      segs.sort_by! { |s| s[:start] }
      # Some writers (old parquet-rs, parquet-mr for a while) store a copy of the ColumnMetaData
      # right after the chunk, at ColumnChunk.file_offset
      meta_copies = column_chunks.each_with_object({}) do |c, h|
        fo = c.chunk.file_offset
        h[fo] = c if fo && fo >= c.end_offset
      end
      out = []
      pos = 0
      segs.each do |s|
        if s[:start] > pos
          c = meta_copies[pos]
          out << if c
            { kind: :column_metadata, start: pos, length: s[:start] - pos, row_group: c.row_group.index, column: c.column.index }
          else
            { kind: :unknown, start: pos, length: s[:start] - pos }
          end
        end
        out << s
        pos = [pos, s[:start] + s[:length]].max
      end
      out
    end

    def to_h(pages: true, page_indexes: true)
      Inspector.jsonable({
        summary: summary,
        key_value_metadata: key_value_metadata,
        schema: schema_tree,
        row_groups: row_groups.map { |rg| rg.to_h(pages: pages, page_indexes: page_indexes) },
        column_totals: column_totals
      })
    end

    def to_json(*args) = to_h.to_json(*args)

    # Readable text summary. With pages: true, lists every page header too.
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
      kvs = key_value_metadata
      unless kvs.empty?
        out << "key/value metadata:"
        kvs.each { |kv| out << "  #{kv[:key]} (#{kv[:format]}, #{kv[:bytesize]} bytes): #{kv[:summary] || kv[:value].to_s[0, 80].inspect}" }
      end
      out << "schema:"
      walk = lambda do |n, depth|
        type = n[:children] ? "group" : [n[:physical_type], n[:type_length] && "(#{n[:type_length]})"].compact.join
        ann = n[:logical_type] || n[:converted_type]
        levels = n[:children] ? "" : "  [def #{n[:max_definition_level]}, rep #{n[:max_repetition_level]}]"
        out << "#{"  " * depth}#{n[:repetition]} #{type} #{n[:name]}#{ann ? " (#{ann})" : ""}#{levels}"
        (n[:children] || []).each { |c| walk.call(c, depth + 1) }
      end
      schema_tree.each { |n| walk.call(n, 1) }
      out << "columns:"
      column_totals.each do |t|
        range = t.key?(:min) ? "  [#{Inspector.display(t[:min])} .. #{Inspector.display(t[:max])}]" : ""
        out << "  #{t[:path]}: #{t[:type]} #{t[:codecs].join(",")} #{t[:encodings].join(",")} " \
          "#{Inspector.human_bytes(t[:compressed_size])}/#{Inspector.human_bytes(t[:uncompressed_size])}" \
          "#{ratio_text(t[:uncompressed_size], t[:compressed_size])}, #{t[:num_values]} values" \
          "#{t[:null_count] ? ", #{t[:null_count]} nulls" : ""}, #{t[:num_data_pages]} data pages#{range}"
      end
      row_groups.each do |rg|
        sorting = rg.sorting_columns.map { |c| "#{c[:column]}#{c[:descending] ? " desc" : ""}" }
        out << "row group #{rg.index}: #{rg.num_rows} rows, #{Inspector.human_bytes(rg.compressed_size)} " \
          "at #{rg.start_offset}..#{rg.end_offset}#{sorting.empty? ? "" : ", sorted by #{sorting.join(", ")}"}"
        rg.columns.each do |c|
          st = c.statistics
          range = st && (st.min || st.max) ? " [#{Inspector.display(st.min)} .. #{Inspector.display(st.max)}]" : ""
          extras = []
          extras << "dict #{c.dictionary_size} entries" if c.dictionary_page
          extras << "column index" if c.column_index_range
          extras << "offset index" if c.offset_index_range
          extras << "bloom filter" if c.bloom_filter_offset
          extras << "ERROR: #{c.error}" if c.error
          out << "  #{c.path}: #{c.codec} #{c.encodings.join(",")} " \
            "#{c.compressed_size}/#{c.uncompressed_size} bytes#{ratio_text(c.uncompressed_size, c.compressed_size)}, " \
            "#{c.num_values} values, #{c.pages.size} pages#{extras.empty? ? "" : ", #{extras.join(", ")}"}#{range}"
          next unless pages
          c.pages.each do |p|
            st = p.statistics
            out << "    #{p.index}: #{p.type} @#{p.offset} header #{p.header_size} + #{p.compressed_size}/#{p.uncompressed_size} bytes, " \
              "#{p.num_values} values#{p.num_nulls ? ", #{p.num_nulls} nulls" : ""}#{p.num_rows ? ", #{p.num_rows} rows" : ""}" \
              "#{p.encoding ? " #{p.encoding}" : ""}#{p.crc ? " crc" : ""}" \
              "#{st && (st.min || st.max) ? " [#{Inspector.display(st.min)} .. #{Inspector.display(st.max)}]" : ""}"
          end
        end
      end
      out.join("\n")
    end

    def inspect
      "#<#{self.class.name} #{@name || "(IO)"} rows=#{num_rows} row_groups=#{row_groups.size} size=#{@file_size}>"
    end

    # ---- used by the info objects ----

    # Walks page headers from the chunk's first page. Returns [pages, error_message_or_nil].
    # Mirrors the reader's tolerance: a chunk may extend past its declared total_compressed_size.
    def walk_pages(chunk)
      return [[], "column chunk stored in external file #{chunk.external_file}"] if chunk.external_file
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
          header, header_size = read_page_header(pos, limit)
          page = page_info(pages.size, header, pos, header_size, chunk.column)
        rescue Thrift::Error, FormatError => e
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
      [pages, seen < total ? "found #{seen} of #{total} values in page headers" : nil]
    end

    def read_column_index(chunk)
      offset, length = chunk.column_index_range
      return nil unless offset && length.positive?
      ci = Format::ColumnIndex.decode(read_at(offset, length)).first
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
    rescue Thrift::Error
      nil
    end

    def read_offset_index(chunk)
      offset, length = chunk.offset_index_range
      return nil unless offset && length.positive?
      oi = Format::OffsetIndex.decode(read_at(offset, length)).first
      OffsetIndexInfo.new(
        offset: offset, length: length,
        page_locations: (oi.page_locations || []).map do |l|
          PageLocation.new(offset: l.offset, compressed_page_size: l.compressed_page_size, first_row_index: l.first_row_index)
        end,
        unencoded_byte_array_data_bytes: oi.unencoded_byte_array_data_bytes
      )
    rescue Thrift::Error
      nil
    end

    # Size in bytes of the bloom filter at +offset+ (its Thrift header plus the bitset)
    def bloom_filter_size(offset)
      buf = read_at(offset, 64)
      header, size = BloomFilterHeader.decode(buf)
      header.num_bytes ? size + header.num_bytes : nil
    rescue Thrift::Error
      nil
    end

    # Decodes a Format::Statistics into Ruby values via the column's type converter
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
    rescue StandardError
      Inspector.hex(bytes)
    end

    # ---- class helpers ----

    def self.encoding_name(e) = Format::Encoding::NAMES[e]&.to_s || e.to_s

    def self.type_name(column)
      node = column.node
      phys = T::NAMES[node.type].to_s
      phys += "(#{node.type_length})" if node.type == T::FIXED_LEN_BYTE_ARRAY && node.type_length
      logical = logical_type_name(node)
      logical ? "#{phys} #{logical}" : phys
    end

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
        c == "DECIMAL" ? "DECIMAL(#{node.precision}, #{node.scale || 0})" : c
      end
    end

    # :signed, :unsigned or :unknown, per the Parquet sort order rules for the column's type
    def self.sort_order(column)
      kind, _a, signed = Types.logical_of(column.node)
      case kind
      when :integer then signed == false ? :unsigned : :signed
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
    def self.text(s)
      return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?
      u = s.dup.force_encoding(Encoding::UTF_8)
      return u if u.valid_encoding? && !u.match?(/[\x00-\x08\x0e-\x1f\x7f]/)
      hex(s)
    end

    def self.hex(bytes)
      b = bytes.b
      b.bytesize > 64 ? "0x#{b.byteslice(0, 64).unpack1("H*")}… (#{b.bytesize} bytes)" : "0x#{b.unpack1("H*")}"
    end

    # A short display form of a decoded value
    def self.display(v, max: 40)
      s = case v
      when String then v.encoding == Encoding::BINARY ? text(v) : v
      when nil then "null"
      else jsonable(v).to_s
      end
      s = s.inspect if v.is_a?(String)
      s.size > max ? "#{s[0, max - 1]}…" : s
    end

    def self.human_bytes(n)
      return "?" unless n
      units = %w[B KB MB GB TB]
      f = n.to_f
      i = 0
      while f >= 1024 && i < units.size - 1
        f /= 1024
        i += 1
      end
      i.zero? ? "#{n} B" : format("%.#{f < 10 ? 2 : 1}f %s", f, units[i])
    end

    private

    def ratio_text(uncompressed, compressed)
      compressed.to_i.positive? && uncompressed ? format(" (%.2fx)", uncompressed.to_f / compressed) : ""
    end

    def safe_extreme(values, which)
      vals = values.compact
      return nil if vals.empty?
      if vals.all? { |v| v == true || v == false }
        return which == :min ? vals.all? : vals.any?
      end
      return nil unless vals.map(&:class).uniq.size == 1
      which == :min ? vals.min : vals.max
    rescue ArgumentError, NoMethodError
      nil
    end

    def read_footer
      @io.seek(0, IO::SEEK_END)
      @file_size = @io.pos
      raise FormatError, "File too small to be Parquet (#{@file_size} bytes)" if @file_size < 12
      tail = read_at(@file_size - 8, 8)
      raise UnsupportedError, "Encrypted Parquet files are not supported" if tail.byteslice(4, 4) == "PARE"
      raise FormatError, "Missing PAR1 footer magic" unless tail.byteslice(4, 4) == MAGIC
      @footer_size = tail.unpack1("V")
      raise FormatError, "Footer length #{@footer_size} exceeds file size" if @footer_size + 12 > @file_size
      @metadata = Format::FileMetaData.decode(read_at(footer_offset, @footer_size)).first
    rescue Thrift::Error => e
      raise FormatError, "Corrupt file metadata: #{e.message}"
    end

    # Reads +len+ bytes at +pos+ through a small read-ahead window, so walking many small pages
    # does not cost a syscall per header
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

    # Decodes the page header at +pos+, reading more bytes when it is larger than the first guess
    # (page statistics of long strings can make headers big)
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
        info.is_compressed = d.is_compressed.nil? ? true : d.is_compressed
        info.statistics = decode_statistics(d.statistics, column)
      elsif (d = h.dictionary_page_header)
        info.num_values = d.num_values
        info.encoding = Inspector.encoding_name(d.encoding)
        info.is_sorted = d.is_sorted
      end
      info
    end

    def describe_key_value(key, value)
      value = value.to_s
      h = { key: key, bytesize: value.bytesize }
      if key == "ARROW:schema"
        h[:format] = "arrow_schema"
        h[:summary] = "Arrow IPC schema message, base64-encoded (#{value.bytesize} bytes)"
        h[:value] = value.size > 120 ? "#{value[0, 120]}…" : value
        names = arrow_field_names(value)
        h[:arrow_fields] = names if names
      elsif value.lstrip.start_with?("{", "[") && value.bytesize < 4 * 1024 * 1024
        begin
          h[:json] = JSON.parse(value)
          h[:format] = "json"
          h[:summary] = key == "pandas" ? pandas_summary(h[:json]) : "JSON"
        rescue JSON::ParserError
          h[:format] = "text"
        end
        h[:value] = value.size > 4000 ? "#{value[0, 4000]}…" : value
      else
        t = Inspector.text(value.b)
        h[:format] = t.start_with?("0x") && value.bytesize.positive? ? "binary" : "text"
        h[:value] = t.size > 4000 ? "#{t[0, 4000]}…" : t
      end
      h
    end

    def pandas_summary(json)
      return "pandas metadata" unless json.is_a?(Hash)
      cols = json["columns"]&.size
      "pandas #{json["pandas_version"]} metadata, #{cols || "?"} columns"
    end

    # Field names from an Arrow IPC schema message, found by scanning for its flatbuffer strings.
    # Best effort: only used to label the blob, nil when nothing sensible is found.
    def arrow_field_names(b64)
      bytes = b64.unpack1("m")
      schema_cols = columns.map { |c| c.path.first }.uniq
      found = schema_cols.select { |n| bytes.include?(n.b) }
      found.empty? ? nil : found
    rescue ArgumentError
      nil
    end
  end

  module_function

  # Inspects a Parquet file's layout without decoding values; see Inspector. +io+ is a
  # random-access IO (or a Reader). Reads all page headers and page indexes up front, so the
  # returned Inspector no longer needs the IO; the IO is not closed.
  def inspect_file(io)
    Inspector.new(io).load_all
  end
end
