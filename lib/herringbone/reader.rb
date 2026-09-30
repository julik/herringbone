# frozen_string_literal: true

module Herringbone
  # Reads Parquet files from a random-access IO. Herringbone never opens files by path: the
  # caller opens (and closes) the IO.
  #
  #   File.open("data.parquet", "rb") do |file|
  #     reader = Herringbone::Reader.new(file)
  #     reader.each_row { |row| p row }            # rows as Hashes with String keys
  #     reader.each_batch(1000) { |rows| ... }     # Arrays of row Hashes
  #     reader.column("name")                      # all values of a top-level field
  #     reader.each_row(columns: ["id"]) { ... }   # projection
  #   end
  #
  # Rows are read in batches: pages are read and decoded one at a time per column, so memory use
  # depends on the batch size and the page size, not on the size of the row groups.
  #
  # Options (for Reader.new / Reader.open, and per call for each_row, each_batch and rows):
  #   keys:      :string (default) or :symbol, for row Hashes and Hashes built from structs.
  #              Map keys are always the stored values.
  #   time_zone: return timestamps in this zone instead of UTC. A UTC offset ("+02:00", or
  #              seconds as an Integer), a timezone object Time#getlocal accepts (e.g. a
  #              TZInfo::Timezone), or anything responding to #at such as an
  #              ActiveSupport::TimeZone (Time.zone), which yields ActiveSupport::TimeWithZone.
  class Reader
    include Enumerable

    MAGIC = "PAR1"
    DEFAULT_BATCH_SIZE = 1024
    KEY_MODES = %i[string symbol].freeze

    attr_reader :metadata, :schema, :io

    # Yields a Reader for +io+ and returns the block's value (or returns the Reader without a
    # block). The IO is not closed: it belongs to the caller.
    def self.open(io, **options)
      reader = new(io, **options)
      return reader unless block_given?
      yield reader
    end

    # +io+ must support #seek and #read (a File opened with "rb", StringIO, Tempfile...).
    # Use Reader.from_string for a String of Parquet bytes.
    def initialize(io, keys: :string, time_zone: nil)
      unless io.respond_to?(:seek) && io.respond_to?(:read)
        raise ArgumentError, "Herringbone::Reader expects an IO that supports #seek and #read " \
          "(e.g. File.open(path, \"rb\")), got #{io.class == String ? "a String" : io.class}" \
          "#{" (use Reader.from_string for Parquet bytes)" if io.is_a?(String)}"
      end
      @keys = check_keys(keys)
      @time_zone = time_zone
      @zone_converter = zone_converter(time_zone)
      @io = io
      @metadata = read_footer
      @schema = Schema.from_elements(@metadata.schema)
    end

    def self.from_string(bytes, **options)
      new(StringIO.new(bytes.b), **options)
    end

    # Does nothing: the IO belongs to the caller, who closes it. Kept for compatibility.
    def close
      nil
    end

    def num_rows = @metadata.num_rows
    def row_groups = @metadata.row_groups
    def num_row_groups = @metadata.row_groups.size
    def created_by = @metadata.created_by

    def key_value_metadata
      (@metadata.key_value_metadata || []).to_h { |kv| [kv.key, kv.value] }
    end

    # Compression codecs used by the file's column chunks, e.g. [:snappy, :zstd]
    def codecs
      codec_ids.map { |id| Compression::NAMES.fetch(id, id) }
    end

    # Codecs this file uses that cannot be decoded here (e.g. [:zstd] without the zstd-ruby gem)
    def missing_codecs
      codec_ids.reject { |id| Compression.available?(id) }.map { |id| Compression::NAMES.fetch(id, id) }
    end

    # Raises MissingCodecError / UnsupportedError now, rather than partway through reading
    def ensure_codecs_available!
      codec_ids.each { |id| Compression.ensure_available!(id) }
      self
    end

    # Yields batches of up to +size+ rows (all batches are full except the last one; batches span
    # row groups). Only one page per column and the current batch are held in memory.
    #
    # as: :rows (default) yields an Array of row Hashes; as: :columns yields a Hash of top-level
    # field name => Array of that field's values in the batch, which skips building a Hash per row
    # and is noticeably faster when you process data column by column.
    def each_batch(size = DEFAULT_BATCH_SIZE, columns: nil, keys: @keys, time_zone: @time_zone, as: :rows)
      return enum_for(:each_batch, size, columns: columns, keys: keys, time_zone: time_zone, as: as) unless block_given?
      size = Integer(size)
      raise ArgumentError, "Batch size must be positive, got #{size}" unless size.positive?
      raise ArgumentError, "as: must be :rows or :columns, got #{as.inspect}" unless as == :rows || as == :columns
      columnar = as == :columns
      symbolize = check_keys(keys) == :symbol
      fields = select_fields(columns)
      names = row_keys(fields, symbolize)
      converters = converters_for(time_zone)
      assemblers = fields.map { |f| Assembler.new(f, symbolize) }
      pending = pending_rows = nil
      row_groups.each do |rg|
        left = rg.num_rows
        next unless left.positive?
        cursors = fields.map do |f|
          f.leaves.map do |col|
            reader = ColumnChunkReader.new(@io, rg.columns.fetch(col.index), col, converter: converters[col.index], lazy: true)
            [col.index, ColumnCursor.new(reader)]
          end
        end
        while left.positive?
          # Rows still missing from the current batch (pending_rows counts rows in both modes)
          k = pending ? size - pending_rows : size
          raise Error, "Internal error: batch needs #{k} rows" unless k.positive? # never loop without progress
          k = left if left < k
          data = assemblers.each_with_index.map do |asm, j|
            asm.read_rows(k, cursors[j].to_h { |idx, cursor| [idx, cursor.take(k)] })
          end
          left -= k
          if columnar
            if pending
              pending.each_with_index { |col, j| col.concat(data[j]) }
            else
              pending = data
            end
            pending_rows = (pending_rows || 0) + k
            next if pending_rows < size
            yield names.zip(pending).to_h
            pending = pending_rows = nil
          else
            rows = build_rows(names, data, k)
            if pending
              pending.concat(rows)
            else
              pending = rows
            end
            pending_rows = pending.size
            next if pending_rows < size
            yield pending
            pending = pending_rows = nil
          end
        end
      end
      yield(columnar ? names.zip(pending).to_h : pending) if pending
      self
    end

    # All rows in column order: a Hash of top-level field name => Array of values, read in
    # batches (so only the resulting Arrays are held, not whole decoded row groups)
    def read_columns(columns: nil, keys: @keys, time_zone: @time_zone, batch_size: 65_536)
      fields = select_fields(columns)
      out = row_keys(fields, check_keys(keys) == :symbol).to_h { |name| [name, []] }
      each_batch(batch_size, columns: columns, keys: keys, time_zone: time_zone, as: :columns) do |batch|
        batch.each { |name, values| out[name].concat(values) }
      end
      out
    end

    # Yields each row as a Hash of top-level field name => value
    def each_row(columns: nil, keys: @keys, time_zone: @time_zone, batch_size: DEFAULT_BATCH_SIZE, &block)
      return enum_for(:each_row, columns: columns, keys: keys, time_zone: time_zone, batch_size: batch_size) unless block
      each_batch(batch_size, columns: columns, keys: keys, time_zone: time_zone) { |rows| rows.each(&block) }
      self
    end
    alias_method :each, :each_row

    # Rows as an Array of Hashes
    def rows(columns: nil, keys: @keys, time_zone: @time_zone)
      out = []
      each_batch(columns: columns, keys: keys, time_zone: time_zone) { |batch| out.concat(batch) }
      out
    end

    # All values of a single top-level field, across all row groups
    def column(name)
      field = @schema.field(name) or raise ArgumentError, "No such column #{name.inspect}"
      row_groups.each_index.flat_map { |rg| read_row_group_fields(rg, [field]).first }
    end

    # Hash of field name => Array of values, for the given row group
    def read_row_group(index, columns: nil)
      fields = select_fields(columns)
      row_keys(fields, @keys == :symbol).zip(read_row_group_fields(index, fields)).to_h
    end

    # Raw column data for a leaf column: [definition_levels, repetition_levels, values].
    # Levels are nil when the column's max level is 0.
    def read_column_chunk(row_group_index, column)
      column = @schema.column(column) unless column.is_a?(Schema::Column)
      raise ArgumentError, "No such leaf column" unless column
      chunk = row_groups.fetch(row_group_index).columns.fetch(column.index)
      ColumnChunkReader.new(@io, chunk, column, converter: converter_for(column, @zone_converter)).read
    end

    def codec_ids
      row_groups.flat_map { |rg| rg.columns.map { |c| c.meta_data&.codec } }.compact.uniq
    end
    private :codec_ids

    def inspect
      "#<#{self.class.name} rows=#{num_rows} row_groups=#{num_row_groups} created_by=#{created_by.inspect}>"
    end

    private

    def select_fields(columns)
      return @schema.fields unless columns
      Array(columns).map { |c| @schema.field(c) or raise ArgumentError, "No such column #{c.inspect}" }
    end

    def check_keys(keys)
      keys = keys.to_sym if keys.is_a?(String)
      return keys if KEY_MODES.include?(keys)
      raise ArgumentError, "keys: must be :string or :symbol, got #{keys.inspect}"
    end

    def row_keys(fields, symbolize)
      fields.map { |f| symbolize ? f.name.to_sym : -f.name }
    end

    def build_rows(names, data, k)
      return Array.new(k) { {} } if names.empty?
      return data.first.map { |v| { names.first => v } } if names.size == 1
      nf = names.size
      Array.new(k) do |i|
        row = {}
        j = 0
        while j < nf
          row[names[j]] = data[j][i]
          j += 1
        end
        row
      end
    end

    # Converters per leaf column index, with the time zone applied to timestamps
    def converters_for(time_zone)
      zc = time_zone.equal?(@time_zone) ? @zone_converter : zone_converter(time_zone)
      @schema.columns.map { |col| converter_for(col, zc) }
    end

    def converter_for(column, zone_converter)
      base = column.converter
      return base unless zone_converter && base && instant_column?(column)
      ->(v) { zone_converter.call(base.call(v)) }
    end

    # Timestamps that denote an instant (UTC-adjusted TIMESTAMP, INT96). Local timestamps
    # (isAdjustedToUTC = false) are wall-clock values and are left as they are.
    def instant_column?(column)
      return true if column.type == Format::Type::INT96
      kind, _unit, utc = Types.logical_of(column.node)
      kind == :timestamp && utc
    end

    OFFSET_PATTERN = /\A([+-])(\d\d)(?::?(\d\d)(?::?(\d\d))?)?\z/

    # A lambda turning a UTC Time into the zone, or nil for UTC
    def zone_converter(zone)
      case zone
      when nil then nil
      when Integer
        return nil if zone.zero?
        Time.at(0).getlocal(zone) # validates the range
        ->(t) { t.getlocal(zone) }
      when String
        return nil if zone.match?(/\A(?:utc|z)\z/i)
        if (m = OFFSET_PATTERN.match(zone))
          # As seconds, since Ruby 3.0 only parses "+HH:MM" offset strings
          return zone_converter((m[1] == "-" ? -1 : 1) * (m[2].to_i * 3600 + m[3].to_i * 60 + m[4].to_i))
        end
        if defined?(::ActiveSupport::TimeZone) && (tz = ::ActiveSupport::TimeZone[zone])
          return ->(t) { tz.at(t) }
        end
        if defined?(::TZInfo::Timezone)
          tz = ::TZInfo::Timezone.get(zone)
          return ->(t) { t.getlocal(tz) }
        end
        raise ArgumentError, "Unknown time zone #{zone.inspect}: use a UTC offset like \"+02:00\", " \
          "a timezone object (e.g. TZInfo::Timezone.get(#{zone.inspect})) or an ActiveSupport::TimeZone"
      else
        return ->(t) { zone.at(t) } if zone.respond_to?(:at)
        if zone.respond_to?(:utc_to_local)
          Time.at(0).getlocal(zone)
          return ->(t) { t.getlocal(zone) }
        end
        raise ArgumentError, "Unsupported time_zone: #{zone.inspect}"
      end
    rescue ArgumentError => e
      raise if e.message.start_with?("Unknown time zone", "Unsupported time_zone", "Invalid time_zone")
      raise ArgumentError, "Invalid time_zone #{zone.inspect}: #{e.message}"
    end

    def read_row_group_fields(rg, fields)
      rg_meta = row_groups.fetch(rg)
      n = rg_meta.num_rows
      symbolize = @keys == :symbol
      fields.map do |field|
        chunks = {}
        field.leaves.each do |col|
          reader = ColumnChunkReader.new(@io, rg_meta.columns.fetch(col.index), col,
            converter: converter_for(col, @zone_converter))
          chunks[col.index] = reader.read
        end
        Assembler.new(field, symbolize).read_rows(n, chunks)
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

    # Rebuilds nested values of one top-level field from the levels of its leaf columns
    # (the "record assembly" half of the Dremel algorithm).
    class Assembler
      def initialize(field, symbolize = false)
        @field = field
        @symbolize = symbolize
        @keys = {} # struct child Field => Hash key
      end

      # Assembles +n+ values of the field from +chunks+ (leaf column index =>
      # [defs, reps, values] holding exactly those rows)
      def read_rows(n, chunks)
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

      def key_for(field)
        @keys[field] ||= @symbolize ? field.name.to_sym : -field.name
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
          field.children.each { |ch| h[key_for(ch)] = read(ch) }
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

require_relative "reader/page_stream"
require_relative "reader/column_chunk_reader"
require_relative "reader/column_cursor"
