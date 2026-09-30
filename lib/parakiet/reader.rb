# frozen_string_literal: true

module Parakiet
  # Reads Parquet files.
  #
  #   Parakiet::Reader.open("data.parquet") do |reader|
  #     reader.each_row { |row| p row }            # rows as Hashes with String keys
  #     reader.column("name")                      # all values of a top-level field
  #     reader.each_row(columns: ["id"]) { ... }   # projection
  #   end
  class Reader
    include Enumerable

    MAGIC = "PAR1"

    attr_reader :metadata, :schema

    def self.open(path)
      io = File.open(path, "rb")
      reader = new(io)
      return reader unless block_given?
      begin
        yield reader
      ensure
        io.close
      end
    end

    # +source+ is an IO (opened in binary mode), a path, or a String of Parquet bytes when
    # +string: true+ is given.
    def initialize(source)
      @io = case source
      when String then File.open(source, "rb")
      when Pathname then File.open(source.to_s, "rb")
      else source
      end
      @metadata = read_footer
      @schema = Schema.from_elements(@metadata.schema)
    end

    def self.from_string(bytes)
      new(StringIO.new(bytes.b))
    end

    def close
      @io.close
    end

    def num_rows = @metadata.num_rows
    def row_groups = @metadata.row_groups
    def num_row_groups = @metadata.row_groups.size
    def created_by = @metadata.created_by

    def key_value_metadata
      (@metadata.key_value_metadata || []).to_h { |kv| [kv.key, kv.value] }
    end

    # Yields each row as a Hash of top-level field name => value
    def each_row(columns: nil, &block)
      return enum_for(:each_row, columns: columns) unless block
      fields = select_fields(columns)
      row_groups.each_index do |rg|
        data = read_row_group_fields(rg, fields)
        n = row_groups[rg].num_rows
        names = fields.map(&:name)
        n.times do |i|
          row = {}
          names.each_with_index { |name, j| row[name] = data[j][i] }
          yield row
        end
      end
      self
    end
    alias_method :each, :each_row

    # Rows as an Array of Hashes
    def rows(columns: nil) = each_row(columns: columns).to_a

    # All values of a single top-level field, across all row groups
    def column(name)
      field = @schema.field(name) or raise ArgumentError, "No such column #{name.inspect}"
      row_groups.each_index.flat_map { |rg| read_row_group_fields(rg, [field]).first }
    end

    # Hash of field name => Array of values, for the given row group
    def read_row_group(index, columns: nil)
      fields = select_fields(columns)
      fields.map(&:name).zip(read_row_group_fields(index, fields)).to_h
    end

    # Raw column data for a leaf column: [definition_levels, repetition_levels, values].
    # Levels are nil when the column's max level is 0.
    def read_column_chunk(row_group_index, column)
      column = @schema.column(column) unless column.is_a?(Schema::Column)
      raise ArgumentError, "No such leaf column" unless column
      chunk = row_groups.fetch(row_group_index).columns.fetch(column.index)
      ColumnChunkReader.new(@io, chunk, column).read
    end

    def inspect
      "#<#{self.class.name} rows=#{num_rows} row_groups=#{num_row_groups} created_by=#{created_by.inspect}>"
    end

    private

    def select_fields(columns)
      return @schema.fields unless columns
      Array(columns).map { |c| @schema.field(c) or raise ArgumentError, "No such column #{c.inspect}" }
    end

    def read_row_group_fields(rg, fields)
      rg_meta = row_groups.fetch(rg)
      n = rg_meta.num_rows
      fields.map do |field|
        chunks = {}
        field.leaves.each do |col|
          chunks[col.index] = ColumnChunkReader.new(@io, rg_meta.columns.fetch(col.index), col).read
        end
        Assembler.new(field, chunks).read_rows(n)
      end
    end

    def read_footer
      @io.seek(0, IO::SEEK_END)
      size = @io.pos
      raise FormatError, "File too small to be Parquet (#{size} bytes)" if size < 12
      @io.seek(size - 8)
      tail = @io.read(8)
      raise FormatError, "Missing PAR1 footer magic" unless tail.byteslice(4, 4) == MAGIC
      raise UnsupportedError, "Encrypted Parquet files are not supported" if tail.byteslice(4, 4) == "PARE"
      footer_len = tail.unpack1("V")
      raise FormatError, "Footer length #{footer_len} exceeds file size" if footer_len + 12 > size
      @io.seek(size - 8 - footer_len)
      footer = @io.read(footer_len)
      Format::FileMetaData.decode(footer).first
    rescue Thrift::Error => e
      raise FormatError, "Corrupt file metadata: #{e.message}"
    end

    # Decodes all pages of one column chunk into levels and values
    class ColumnChunkReader
      T = Format::Type
      E = Format::Encoding

      def initialize(io, chunk, column)
        @io = io
        @chunk = chunk
        @column = column
        @meta = chunk.meta_data or raise UnsupportedError, "Column chunk without metadata (encrypted?)"
        raise UnsupportedError, "Column chunks in external files are not supported" if chunk.file_path
        @max_def = column.max_definition_level
        @max_rep = column.max_repetition_level
        @converter = column.converter
      end

      def read
        buf = read_bytes
        defs = @max_def.positive? ? [] : nil
        reps = @max_rep.positive? ? [] : nil
        values = []
        pos = 0
        total = @meta.num_values
        seen = 0
        while seen < total && pos < buf.bytesize
          header, pos = decode_page_header(buf, pos)
          size = header.compressed_page_size
          # Some old writers under-report total_compressed_size; read on past the declared end
          extend_buffer(buf, pos + size - buf.bytesize) if pos + size > buf.bytesize
          raise FormatError, "Page overruns column chunk" if pos + size > buf.bytesize
          body = buf.byteslice(pos, size)
          pos += size
          case header.type
          when Format::PageType::DICTIONARY_PAGE
            read_dictionary(header, body)
          when Format::PageType::DATA_PAGE
            seen += read_data_page_v1(header, body, defs, reps, values)
          when Format::PageType::DATA_PAGE_V2
            seen += read_data_page_v2(header, body, defs, reps, values)
          end
        end
        raise FormatError, "Column #{@column.dotted_path}: read #{seen} of #{total} values" if seen < total
        [defs, reps, values]
      rescue Thrift::Error => e
        raise FormatError, "Corrupt page header in #{@column.dotted_path}: #{e.message}"
      end

      private

      def read_bytes
        start = @meta.data_page_offset
        dict = @meta.dictionary_page_offset
        # Some writers store 0 when there is no dictionary page
        start = dict if dict && dict.positive? && dict < start
        @start = start
        @io.seek(start)
        len = @meta.total_compressed_size
        (@io.read(len) || "".b).b
      end

      def extend_buffer(buf, nbytes)
        @io.seek(@start + buf.bytesize)
        more = @io.read(nbytes)
        buf << more.b if more
      end

      def decode_page_header(buf, pos)
        Format::PageHeader.decode(buf, pos)
      rescue Thrift::Error
        # The header may straddle the declared end of the chunk
        before = buf.bytesize
        extend_buffer(buf, 1024)
        raise if buf.bytesize == before
        Format::PageHeader.decode(buf, pos)
      end

      def decompress(body, size)
        Compression.decompress(@meta.codec, body, size)
      end

      def read_dictionary(header, body)
        dh = header.dictionary_page_header
        data = decompress(body, header.uncompressed_page_size)
        vals, = Encodings::Plain.decode(data, 0, dh.num_values, @column.type, @column.type_length)
        vals.map!(&@converter) if @converter
        @dictionary = vals
      end

      def read_data_page_v1(header, body, defs, reps, values)
        dh = header.data_page_header
        n = dh.num_values
        data = decompress(body, header.uncompressed_page_size)
        pos = 0
        if @max_rep.positive?
          levels, pos = read_levels(data, pos, dh.repetition_level_encoding, @max_rep, n)
          reps.concat(levels)
        end
        non_null = n
        if @max_def.positive?
          levels, pos = read_levels(data, pos, dh.definition_level_encoding, @max_def, n)
          non_null = levels.count(@max_def)
          defs.concat(levels)
        end
        values.concat(decode_values(data, pos, non_null, dh.encoding))
        n
      end

      def read_data_page_v2(header, body, defs, reps, values)
        dh = header.data_page_header_v2
        n = dh.num_values
        rep_len = dh.repetition_levels_byte_length
        def_len = dh.definition_levels_byte_length
        if @max_rep.positive?
          reps.concat(Encodings::RLE.decode_hybrid(body, 0, rep_len, RLE_WIDTH[@max_rep], n))
        end
        non_null = n
        if @max_def.positive?
          levels = Encodings::RLE.decode_hybrid(body, rep_len, rep_len + def_len, RLE_WIDTH[@max_def], n)
          non_null = levels.count(@max_def)
          defs.concat(levels)
        end
        data = body.byteslice(rep_len + def_len, body.bytesize - rep_len - def_len)
        if dh.is_compressed != false
          data = decompress(data, header.uncompressed_page_size - rep_len - def_len)
        end
        values.concat(decode_values(data, 0, non_null, dh.encoding))
        n
      end

      RLE_WIDTH = Hash.new { |h, k| h[k] = k.bit_length }

      def read_levels(data, pos, encoding, max, n)
        width = RLE_WIDTH[max]
        case encoding
        when E::RLE
          len = data.byteslice(pos, 4).unpack1("V")
          start = pos + 4
          [Encodings::RLE.decode_hybrid(data, start, start + len, width, n), start + len]
        when E::BIT_PACKED
          [Encodings::RLE.decode_legacy_bit_packed(data, pos, width, n), pos + (n * width + 7) / 8]
        else
          raise UnsupportedError, "Unsupported level encoding #{E::NAMES[encoding] || encoding}"
        end
      end

      def decode_values(data, pos, count, encoding)
        type = @column.type
        vals = case encoding
        when E::PLAIN
          Encodings::Plain.decode(data, pos, count, type, @column.type_length).first
        when E::PLAIN_DICTIONARY, E::RLE_DICTIONARY
          raise FormatError, "Dictionary-encoded page without a dictionary in #{@column.dotted_path}" unless @dictionary
          return [] if count.zero?
          width = data.getbyte(pos)
          indices = Encodings::RLE.decode_hybrid(data, pos + 1, data.bytesize, width, count)
          dict = @dictionary
          raise FormatError, "Dictionary index out of range in #{@column.dotted_path}" if indices.max >= dict.size
          return indices.map! { |i| dict[i] }
        when E::RLE
          raise UnsupportedError, "RLE value encoding is only supported for BOOLEAN" unless type == T::BOOLEAN
          len = data.byteslice(pos, 4).unpack1("V")
          Encodings::RLE.decode_hybrid(data, pos + 4, pos + 4 + len, 1, count).map! { |v| v == 1 }
        when E::DELTA_BINARY_PACKED
          bits = type == T::INT32 ? 32 : 64
          vals, = Encodings::Delta.decode_binary_packed(data, pos, bits, count)
          raise FormatError, "DELTA_BINARY_PACKED page has #{vals.size} values, need #{count}" if vals.size < count
          vals
        when E::DELTA_LENGTH_BYTE_ARRAY
          Encodings::Delta.decode_length_byte_array(data, pos, count).first
        when E::DELTA_BYTE_ARRAY
          Encodings::Delta.decode_byte_array(data, pos, count).first
        when E::BYTE_STREAM_SPLIT
          width = case type
          when T::INT32, T::FLOAT then 4
          when T::INT64, T::DOUBLE then 8
          when T::FIXED_LEN_BYTE_ARRAY then @column.type_length
          else raise UnsupportedError, "BYTE_STREAM_SPLIT is not valid for #{T::NAMES[type]}"
          end
          plain, = Encodings::ByteStreamSplit.decode(data, pos, count, width)
          Encodings::Plain.decode(plain, 0, count, type, @column.type_length).first
        else
          raise UnsupportedError, "Unsupported encoding #{E::NAMES[encoding] || encoding}"
        end
        vals.map!(&@converter) if @converter
        vals
      end
    end

    # Rebuilds nested values of one top-level field from the levels of its leaf columns
    # (the "record assembly" half of the Dremel algorithm).
    class Assembler
      def initialize(field, chunks)
        @field = field
        @defs = {}
        @reps = {}
        @vals = {}
        chunks.each do |idx, (d, r, v)|
          @defs[idx] = d
          @reps[idx] = r
          @vals[idx] = v
        end
        @ei = Hash.new(0) # entry cursor per leaf column
        @vi = Hash.new(0) # value cursor per leaf column
      end

      def read_rows(n)
        f = @field
        if f.leaf? && f.column.max_repetition_level.zero?
          idx = f.column.index
          defs = @defs[idx]
          vals = @vals[idx]
          return vals unless defs
          max = f.column.max_definition_level
          return vals if vals.size == defs.size
          vi = -1
          return defs.map { |d| d == max ? vals[vi += 1] : nil }
        end
        return read_simple_list(f) if f.kind == :list && f.element.leaf? && f.element.column.max_repetition_level == 1

        out = Array.new(n) { read(f) }
        f.leaves.each do |col|
          if @ei[col.index] != (@defs[col.index] || @vals[col.index]).size
            raise FormatError, "Column #{col.dotted_path} has leftover entries after assembling #{n} rows"
          end
        end
        out
      end

      private

      # Fast path for a top-level list of primitives (the most common nested shape)
      def read_simple_list(field)
        col = field.element.column
        defs = @defs[col.index]
        reps = @reps[col.index]
        vals = @vals[col.index]
        max_def = col.max_definition_level
        list_def = field.def_level
        item_def = field.item_def
        out = []
        cur = nil
        vi = 0
        i = 0
        n = defs.size
        while i < n
          d = defs[i]
          if reps[i].zero?
            if d < list_def
              out << nil
              i += 1
              next
            end
            cur = []
            out << cur
            if d < item_def
              i += 1
              next
            end
          end
          if d == max_def
            cur << vals[vi]
            vi += 1
          else
            cur << nil
          end
          i += 1
        end
        out
      end

      def read(field)
        c = field.first_leaf.index
        kind = field.kind
        if field.optional || kind == :list || kind == :map
          d = @defs[c][@ei[c]]
          raise FormatError, "Ran out of levels while assembling #{field.name}" if d.nil?
          if d < field.def_level
            skip(field)
            return nil
          end
        end

        case kind
        when :leaf
          @ei[c] += 1
          v = @vi[c]
          @vi[c] = v + 1
          @vals[c][v]
        when :struct
          h = {}
          field.children.each { |ch| h[ch.name] = read(ch) }
          h
        when :list
          if d < field.item_def
            skip(field)
            return []
          end
          out = []
          reps = @reps[c]
          rl = field.rep_level
          while true
            out << read(field.element)
            r = reps[@ei[c]]
            break if r.nil? || r < rl
          end
          out
        when :map
          if d < field.item_def
            skip(field)
            return {}
          end
          out = {}
          reps = @reps[c]
          rl = field.rep_level
          while true
            k = read(field.key)
            out[k] = field.value ? read(field.value) : nil
            r = reps[@ei[c]]
            break if r.nil? || r < rl
          end
          out
        end
      end

      def skip(field)
        field.leaves.each { |col| @ei[col.index] += 1 }
      end
    end
  end
end
