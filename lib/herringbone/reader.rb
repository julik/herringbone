# frozen_string_literal: true

module Herringbone
  # Reads Parquet files from a random-access IO. Herringbone never opens files by path: the
  # caller opens (and closes) the IO.
  #
  #   File.open("data.parquet", "rb") do |file|
  #     reader = Herringbone::Reader.new(file)
  #     reader.each_row { |row| p row }                       # rows as Hashes with String keys
  #     reader.each_batch(1000, as: :columns) { |batch| ... }  # { "id" => [...], ... } per batch
  #     reader.read(columns: ["id"], where: { id: 1..10 })     # everything at once
  #   end
  #
  # Rows are read in batches: pages are read and decoded one at a time per column, so memory use
  # depends on the batch size and the page size, not on the size of the row groups.
  #
  # Options:
  #   keys:      :string (default) or :symbol, for row Hashes and Hashes built from structs.
  #              Map keys are always the stored values.
  #   time_zone: return timestamps in this zone instead of UTC. A UTC offset ("+02:00", or
  #              seconds as an Integer), a timezone object Time#getlocal accepts (e.g. a
  #              TZInfo::Timezone), or anything responding to #at such as an
  #              ActiveSupport::TimeZone (Time.zone), which yields ActiveSupport::TimeWithZone.
  #   decryption: keys for a file written with Parquet modular encryption:
  #              { footer_key: "...", columns: { "ssn" => "..." }, aad_prefix: "..." }, and/or
  #              keys: ->(key_metadata) { ... } (or a Hash) to look keys up by the key metadata
  #              stored in the file. Keys are 16, 24 or 32-byte Strings. Plaintext columns of a
  #              file with a plaintext footer can be read without keys.
  class Reader
    # The 4 bytes a Parquet file starts and ends with
    MAGIC = "PAR1"
    # The 4 bytes a Parquet file with an encrypted footer starts and ends with
    ENCRYPTED_MAGIC = "PARE"
    # Rows per batch in #each_batch when no size is given
    DEFAULT_BATCH_SIZE = 1024
    # Accepted values of the +keys:+ option
    KEY_MODES = %i[string symbol].freeze
    # Accepted values of the +as:+ option
    AS_MODES = %i[rows columns numo].freeze

    # @return [Schema] the schema, built from the footer's flattened SchemaElements
    attr_reader :schema

    # @return [Format::FileMetaData] the file's FileMetaData (the decoded Thrift footer)
    attr_reader :file_metadata

    # +io+ must support #seek and #read (a File opened with "rb", StringIO, Tempfile...)
    #
    # @param io [IO, StringIO] random-access source of the Parquet bytes; the caller closes it
    # @param keys [Symbol, String] +:string+ or +:symbol+, the key type of row and struct Hashes
    # @param time_zone [String, Integer, Object, nil] zone timestamps are returned in (see the
    #   class docs); nil keeps them in UTC
    # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, #call, nil] keys for an
    #   encrypted file (see the class docs); a callable is used as +keys:+
    # @option decryption [String] :footer_key key of the footer (and of the columns encrypted with it)
    # @option decryption [Hash{String => String}] :columns column path or field name => key
    # @option decryption [#call, Hash{String => String}] :keys key metadata => key, for the keys not
    #   given above; returns nil for a key that is not available
    # @option decryption [String] :aad_prefix the file's AAD prefix, when it does not store it (or
    #   to check the stored one)
    # @raise [ArgumentError] when +io+ cannot seek and read, or +keys+ / +time_zone+ /
    #   +decryption+ are invalid
    # @raise [FormatError] when the footer is missing or cannot be decoded
    # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted, or its
    #   signature or a column's metadata does not check out
    def initialize(io, keys: :string, time_zone: nil, decryption: nil)
      unless io.respond_to?(:seek) && io.respond_to?(:read)
        raise ArgumentError, "Herringbone::Reader expects an IO that supports #seek and #read " \
          "(e.g. File.open(path, \"rb\")), got #{io.is_a?(String) ? "a String" : io.class}" \
          "#{" (wrap Parquet bytes in a StringIO)" if io.is_a?(String)}"
      end
      keys = keys.to_sym if keys.is_a?(String)
      raise ArgumentError, "keys: must be :string or :symbol, got #{keys.inspect}" unless KEY_MODES.include?(keys)
      @symbolize = keys == :symbol
      @zone_converter = zone_converter(time_zone)
      @decryption = decryption.nil? ? nil : DecryptionConfiguration.from(decryption)
      @io = io
      @file_metadata = read_footer
      @schema = Schema.from_elements(@file_metadata.schema)
    end

    # Total number of rows, as stated in the footer (some writers store 0)
    #
    # @return [Integer] the footer's num_rows
    def num_rows = @file_metadata.num_rows

    # The row groups listed in the footer
    #
    # @return [Array<Format::RowGroup>] row group metadata, in file order
    def row_groups = @file_metadata.row_groups

    # The footer's key/value metadata as a Hash (what the writer's metadata: option stores)
    #
    # @return [Hash{String => String, nil}] key => value; empty when the footer has none
    def metadata
      (@file_metadata.key_value_metadata || []).to_h { |kv| [kv.key, kv.value] }
    end

    # Yields batches of up to +size+ rows (all batches are full except the last one; batches span
    # row groups). Only one page per column and the current batch are held in memory.
    #
    # as: :rows (default) yields an Array of row Hashes; as: :columns yields a Hash of top-level
    # field name => Array of that field's values in the batch, which skips building a Hash per row
    # and is noticeably faster when you process data column by column. as: :numo yields a Hash of
    # field name => Numo array (needs the numo-narray-alt or numo-narray gem; see NumoColumns
    # for the type mapping). With as: :numo, whether an integer column becomes DFloat (nulls) or
    # a list column 2-D is decided per batch, from the values in it.
    #
    # where: only yields rows matching all conditions (see Reader::Filter). Row groups and pages
    # that cannot match are skipped using statistics, bloom filters and the page index, and the
    # remaining rows are checked one by one. Filtered columns need not be in +columns+.
    # from: skips the first rows of the file (jumping over pages with the page index), and
    # limit: stops after yielding that many rows.
    #
    # @param size [Integer] maximum number of rows per batch
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return;
    #   nil returns all of them
    # @param as [Symbol] +:rows+, +:columns+ or +:numo+, the shape of each batch
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, see Filter
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @param limit [Integer, nil] maximum number of rows to yield in total
    # @yield [batch] once per batch
    # @yieldparam batch [Array<Hash>, Hash{String, Symbol => Array}, Hash{String, Symbol => Numo::NArray}]
    #   row Hashes (+:rows+), or field name => values of the batch (+:columns+, +:numo+)
    # @yieldreturn [void]
    # @return [Reader, Enumerator] self, or an Enumerator of batches when no block is given
    # @raise [ArgumentError] for a non-positive +size+, unknown +as+, negative +from+ / +limit+,
    #   or an unknown column in +columns+ or +where+
    # @raise [UnsupportedError] with +as: :numo+ when Numo is not loaded
    def each_batch(size = DEFAULT_BATCH_SIZE, columns: nil, as: :rows, where: nil, from: nil, limit: nil)
      return enum_for(:each_batch, size, columns: columns, as: as, where: where, from: from, limit: limit) unless block_given?
      size = Integer(size)
      raise ArgumentError, "Batch size must be positive, got #{size}" unless size.positive?
      raise ArgumentError, "as: must be :rows, :columns or :numo, got #{as.inspect}" unless AS_MODES.include?(as)
      raise ArgumentError, "limit: must not be negative" if limit&.negative?
      return validate_read_options(columns, where, from) if limit&.zero?
      if as == :numo
        each_numo_batch(size, columns, where, from, limit) { |batch| yield batch }
        return self
      end
      columnar = as == :columns
      symbolize = @symbolize
      out_fields = select_fields(columns)
      filter = (where && !where.empty?) ? Filter.new(@schema, where) : nil
      fields = filter ? out_fields | filter.fields : out_fields
      names = row_keys(out_fields, symbolize)
      nout = out_fields.size
      converters = @schema.columns.map { |col| converter_for(col) }
      assemblers = fields.map { |f| Assembler.new(f, symbolize) }
      left_to_yield = limit
      pending = pending_rows = nil
      emit = lambda do |data, k|
        if columnar
          if pending
            pending.each_with_index { |col, j| col.concat(data[j]) }
          else
            pending = data
          end
          pending_rows = (pending_rows || 0) + k
          if pending_rows >= size
            yield names.zip(pending).to_h
            pending = pending_rows = nil
          end
        else
          rows = build_rows(names, data, k)
          if pending
            pending.concat(rows)
          else
            pending = rows
          end
          pending_rows = pending.size
          if pending_rows >= size
            yield pending
            pending = pending_rows = nil
          end
        end
      end

      plan_rows(filter, from).each do |rg_index, ranges|
        rg = row_groups[rg_index]
        partial = ranges != [[0, rg.num_rows]]
        cursors = fields.map do |f|
          f.leaves.map do |col|
            reader = chunk_reader(rg_index, col, converter: converters[col.index], lazy: true)
            reader.locations = page_index(rg_index, col)[1]&.page_locations if partial
            [col.index, ColumnCursor.new(reader)]
          end
        end
        ranges.each do |first, stop|
          cursors.each { |cs| cs.each { |_, cursor| cursor.seek(first) } }
          left = stop - first
          while left.positive?
            # Rows still missing from the current batch (pending_rows counts rows in both modes)
            k = pending ? size - pending_rows : size
            raise Error, "Internal error: batch needs #{k} rows" unless k.positive? # never loop without progress
            k = left if left < k
            data = assemblers.each_with_index.map do |asm, j|
              asm.read_rows(k, cursors[j].to_h { |idx, cursor| [idx, cursor.take(k)] })
            end
            left -= k
            kept = k
            if filter
              keep = filter.matching_rows(data, fields, k, symbolize)
              kept = keep.size
              next if kept.zero?
              data = data.first(nout).map { |col| keep.map { |i| col[i] } } if kept < k
            end
            data = data.first(nout) if data.size > nout
            if left_to_yield && kept >= left_to_yield
              emit.call(data.map { |col| col.first(left_to_yield) }, left_to_yield)
              yield(columnar ? names.zip(pending).to_h : pending) if pending
              return self
            end
            left_to_yield -= kept if left_to_yield
            emit.call(data, kept)
          end
        end
      end
      yield(columnar ? names.zip(pending).to_h : pending) if pending
      self
    end

    # What a read with +where:+ / +from:+ would touch, without reading any data: an Array of
    # { row_group:, rows:, ranges: [[first_row, end_row), ...] } for the row groups that are
    # read. Row groups ruled out entirely are left out.
    #
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, as in #each_batch
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @return [Array<Hash{Symbol => Object}>] +{row_group: Integer, rows: Integer,
    #   ranges: Array<Array(Integer, Integer)>}+ per row group that would be read
    # @raise [ArgumentError] for a negative +from+ or an unknown column in +where+
    def scan_plan(where: nil, from: nil)
      filter = (where && !where.empty?) ? Filter.new(@schema, where) : nil
      plan_rows(filter, from).map do |rg_index, ranges|
        {row_group: rg_index, rows: ranges.sum { |s, e| e - s }, ranges: ranges}
      end
    end

    # Yields each row as a Hash of top-level field name => value. Takes the options of each_batch
    # except as:.
    #
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return;
    #   nil returns all of them
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, see Filter
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @param limit [Integer, nil] maximum number of rows to yield
    # @yield [row] once per row
    # @yieldparam row [Hash{String, Symbol => Object}] top-level field name => value
    # @yieldreturn [void]
    # @return [Reader, Enumerator] self, or an Enumerator of rows when no block is given
    # @raise [ArgumentError] for a negative +from+ / +limit+ or an unknown column
    def each_row(columns: nil, where: nil, from: nil, limit: nil, &block)
      return enum_for(:each_row, columns: columns, where: where, from: from, limit: limit) unless block
      each_batch(columns: columns, where: where, from: from, limit: limit) { |rows| rows.each(&block) }
      self
    end

    # Reads the whole file (or the selected rows) at once: an Array of row Hashes, or with
    # as: :columns a Hash of top-level field name => Array of values, or with as: :numo a Hash of
    # top-level field name => Numo array. Takes the options of each_batch.
    #
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return;
    #   nil returns all of them
    # @param as [Symbol] +:rows+, +:columns+ or +:numo+, the shape of the result
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, see Filter
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @param limit [Integer, nil] maximum number of rows to return
    # @return [Array<Hash>, Hash{String, Symbol => Array}, Hash{String, Symbol => Numo::NArray}]
    #   row Hashes (+:rows+), or field name => all values (+:columns+, +:numo+)
    # @raise [ArgumentError] for an unknown +as+, negative +from+ / +limit+ or an unknown column
    # @raise [UnsupportedError] with +as: :numo+ when Numo is not loaded
    def read(columns: nil, as: :rows, where: nil, from: nil, limit: nil)
      if as == :numo
        raise ArgumentError, "limit: must not be negative" if limit&.negative?
        out = nil
        if limit&.zero?
          validate_read_options(columns, where, from)
        else
          # One batch (num_rows is not trusted: some writers store 0), so the column types are
          # decided from all the rows read
          each_numo_batch(1 << 62, columns, where, from, limit) { |batch| out = batch }
        end
        out ||= numo_empty(columns)
      elsif as == :columns
        out = row_keys(select_fields(columns), @symbolize).to_h { |name| [name, []] }
        each_batch(65_536, columns: columns, as: :columns, where: where, from: from, limit: limit) do |batch|
          batch.each { |name, values| out[name].concat(values) }
        end
      else
        out = []
        each_batch(columns: columns, as: as, where: where, from: from, limit: limit) { |rows| out.concat(rows) }
      end
      out
    end

    # Internal (used by reads with where:/from:): [ColumnIndex or nil, OffsetIndex or nil] of a
    # leaf column in a row group. Cached per chunk; a missing or damaged index reads as nil.
    #
    # @param row_group_index [Integer] position of the row group in the footer
    # @param column [Schema::Column, String, Array<String>] leaf column, or its dotted / Array path
    # @return [Array(Format::ColumnIndex, Format::OffsetIndex)] either element may be nil
    # @raise [ArgumentError] when +column+ does not name a leaf column
    # @raise [IndexError] when the row group does not exist
    def page_index(row_group_index, column)
      column = @schema.column(column) unless column.is_a?(Schema::Column)
      raise ArgumentError, "No such leaf column" unless column
      @page_indexes ||= {}
      @page_indexes[[row_group_index, column.index]] ||= begin
        chunk = row_groups.fetch(row_group_index).columns.fetch(column.index)
        crypto = (chunk.column_index_offset || chunk.offset_index_offset) && chunk_crypto(row_group_index, column)
        [read_struct(Format::ColumnIndex, chunk.column_index_offset, chunk.column_index_length, crypto, crypto && Encryption::COLUMN_INDEX),
          read_struct(Format::OffsetIndex, chunk.offset_index_offset, chunk.offset_index_length, crypto, crypto && Encryption::OFFSET_INDEX)]
      end
    end

    # How the file is encrypted, without needing its keys; nil for a file that is not encrypted.
    # +columns+ lists the encrypted columns (as the first row group has them), with the key
    # metadata of their own key, if any, and whether their key is available.
    #
    #   reader.encryption
    #   # => { algorithm: :aes_gcm, footer: :encrypted, footer_key_metadata: "kf", aad_prefix: nil,
    #   #      supply_aad_prefix: false, footer_verified: false,
    #   #      columns: { "ssn" => { key: :column, key_metadata: "kc1", readable: true } } }
    #
    # @return [Hash{Symbol => Object}, nil] +:algorithm+ (+:aes_gcm+ or +:aes_gcm_ctr+), +:footer+
    #   (+:encrypted+ or +:plaintext+), +:footer_key_metadata+, +:aad_prefix+ (when stored),
    #   +:supply_aad_prefix+, +:footer_verified+ (whether a plaintext footer's signature was
    #   checked) and +:columns+
    def encryption = @decryptor&.describe(@schema, row_groups.first&.columns || [])

    # Internal (used by Redaction): the keys and settings of an encrypted file
    #
    # @return [Encryption::FileDecryptor, nil] nil for a file that is not encrypted
    attr_reader :decryptor

    # Internal: the decryption of one column chunk's modules
    #
    # @param row_group_index [Integer] position of the row group in the footer
    # @param column [Schema::Column] leaf column
    # @return [Encryption::ModuleCrypto, nil] nil when the chunk is not encrypted
    # @raise [DecryptionError] when the chunk is encrypted and its key was not given
    def chunk_crypto(row_group_index, column)
      return nil unless @decryptor
      rg = row_groups.fetch(row_group_index)
      @decryptor.chunk(row_group_index, rg.ordinal, column, rg.columns.fetch(column.index))
    end

    # Internal: a ColumnChunkReader for a leaf column of a row group, decrypting when needed
    #
    # @param row_group_index [Integer] position of the row group in the footer
    # @param column [Schema::Column] leaf column
    # @param options [Hash{Symbol => Object}] passed to ColumnChunkReader.new
    # @option options [Proc, nil] :converter physical value => Ruby value
    # @option options [Boolean] :lazy leave non-dictionary values physical
    # @return [ColumnChunkReader]
    # @raise [DecryptionError] when the chunk is encrypted and its key was not given
    def chunk_reader(row_group_index, column, **options)
      chunk = row_groups.fetch(row_group_index).columns.fetch(column.index)
      ColumnChunkReader.new(@io, chunk, column, crypto: chunk_crypto(row_group_index, column), **options)
    end

    # Short summary for the console, without the schema
    #
    # @return [String] row count, row group count and the writer's created_by
    def inspect
      "#<#{self.class.name} rows=#{num_rows} row_groups=#{row_groups.size} created_by=#{@file_metadata.created_by.inspect}>"
    end

    private

    # as: :numo. Flat numeric/boolean output columns go through NumoCursors (no Ruby object per
    # value); the other output columns, and every column a where: filter needs, are assembled as
    # Ruby values like as: :columns and converted when a batch is complete.
    #
    # @param size [Integer] maximum number of rows per batch
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, see Filter
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @param limit [Integer, nil] maximum number of rows to yield in total
    # @yield [batch] once per batch
    # @yieldparam batch [Hash{String, Symbol => Numo::NArray}] field name => values of the batch
    # @yieldreturn [void]
    # @return [void]
    # @raise [UnsupportedError] when Numo is not loaded
    def each_numo_batch(size, columns, where, from, limit)
      NumoColumns.load!
      symbolize = @symbolize
      out_fields = select_fields(columns)
      filter = (where && !where.empty?) ? Filter.new(@schema, where) : nil
      filter_fields = filter ? filter.fields : []
      names = row_keys(out_fields, symbolize)
      specs = out_fields.map { |f| NumoColumns.spec_for(f) }
      fast = out_fields.each_index.select { |j| specs[j].fast? && !filter_fields.include?(out_fields[j]) }
      ruby_fields = (out_fields.each_index.to_a - fast).map { |j| out_fields[j] } | filter_fields
      # Where each output column comes from: index into the fast cursors or the Ruby fields
      sources = out_fields.each_index.map { |j| (i = fast.index(j)) ? [:fast, i] : [:ruby, ruby_fields.index(out_fields[j])] }
      converters = @schema.columns.map { |col| converter_for(col) }
      assemblers = ruby_fields.map { |f| Assembler.new(f, symbolize) }
      # Rows decoded per step: Ruby values are kept to slices of the batch, Numo arrays need not be
      step = ruby_fields.empty? ? 1 << 20 : 65_536
      left_to_yield = limit
      pending = Array.new(out_fields.size) { [] }
      pending_rows = 0
      flush = lambda do
        batch = sources.each_with_index.map do |(kind, _), j|
          (kind == :fast) ? NumoColumns.finish_fixed(specs[j], pending[j]) : NumoColumns.finish_values(specs[j], pending[j])
        end
        pending = Array.new(out_fields.size) { [] }
        pending_rows = 0
        yield names.zip(batch).to_h
      end

      plan_rows(filter, from).each do |rg_index, ranges|
        rg = row_groups[rg_index]
        partial = ranges != [[0, rg.num_rows]]
        open = lambda do |col|
          reader = chunk_reader(rg_index, col, converter: converters[col.index], lazy: true)
          reader.locations = page_index(rg_index, col)[1]&.page_locations if partial
          reader
        end
        ruby_cursors = ruby_fields.map { |f| f.leaves.map { |col| [col.index, ColumnCursor.new(open.call(col))] } }
        fast_cursors = fast.map { |j| NumoCursor.new(open.call(out_fields[j].column), specs[j]) }
        ranges.each do |first, stop|
          ruby_cursors.each { |cs| cs.each { |_, cursor| cursor.seek(first) } }
          fast_cursors.each { |cursor| cursor.seek(first) }
          left = stop - first
          while left.positive?
            k = size - pending_rows
            raise Error, "Internal error: batch needs #{k} rows" unless k.positive? # never loop without progress
            k = step if k > step
            k = left if left < k
            data = assemblers.each_with_index.map do |asm, j|
              asm.read_rows(k, ruby_cursors[j].to_h { |idx, cursor| [idx, cursor.take(k)] })
            end
            numo = fast_cursors.map { |cursor| cursor.take(k) }
            left -= k
            kept = k
            if filter
              keep = filter.matching_rows(data, ruby_fields, k, symbolize)
              kept = keep.size
              next if kept.zero?
              if kept < k
                data = data.map { |col| keep.map { |i| col[i] } }
                index = Numo::Int64.cast(keep)
                numo = numo.map { |values, valid| [values[index].dup, valid && valid[index].dup] }
              end
            end
            if left_to_yield && kept > left_to_yield
              kept = left_to_yield
              data = data.map { |col| col.first(kept) }
              numo = numo.map { |values, valid| [values[0...kept].dup, valid && valid[0...kept].dup] }
            end
            sources.each_with_index do |(kind, i), j|
              pending[j] << ((kind == :fast) ? numo[i] : data[i])
            end
            pending_rows += kept
            left_to_yield -= kept if left_to_yield
            flush.call if pending_rows >= size || left_to_yield&.zero?
            return if left_to_yield&.zero? # standard:disable Lint/NonLocalExitFromIterator
          end
        end
      end
      flush.call if pending_rows.positive?
    end

    # Checks the columns:, where: and from: options of a read that returns no rows (limit: 0),
    # so it raises for bad options like any other read
    #
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return
    # @param where [Hash{String, Symbol => Object}, nil] column => condition, see Filter
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @return [Reader] self
    # @raise [ArgumentError] for an unknown column, a bad condition or a negative +from+
    def validate_read_options(columns, where, from)
      select_fields(columns)
      Filter.new(@schema, where) if where && !where.empty?
      raise ArgumentError, "from: must not be negative" if Integer(from || 0).negative?
      self
    end

    # read(as: :numo) of no rows: an empty array of each column's type
    #
    # @param columns [Array<String, Symbol>, String, Symbol, nil] top-level fields to return
    # @return [Hash{String, Symbol => Numo::NArray}] field name => zero-length Numo array
    def numo_empty(columns)
      NumoColumns.load!
      fields = select_fields(columns)
      row_keys(fields, @symbolize).zip(fields.map { |f|
        spec = NumoColumns.spec_for(f)
        (spec.kind == :fixed) ? spec.klass.new(0) : Numo::RObject.new(0)
      }).to_h
    end

    # [[row_group_index, [[first_row, end_row), ...]], ...] to read, after ruling out row groups
    # (statistics, bloom filters) and pages (page index), and skipping the first +from+ rows
    #
    # @param filter [Filter, nil] the where: conditions, if any
    # @param from [Integer, nil] number of rows at the start of the file to skip
    # @return [Array<Array(Integer, Array<Array(Integer, Integer)>)>] row group index and its
    #   half-open row ranges, for row groups that have rows left to read
    # @raise [ArgumentError] for a negative +from+
    def plan_rows(filter, from)
      from = Integer(from || 0)
      raise ArgumentError, "from: must not be negative" if from.negative?
      offset = 0
      plan = []
      row_groups.each_with_index do |rg, i|
        n = rg.num_rows
        first = from - offset
        offset += n
        next if n.zero? || first >= n
        ranges = [[first.positive? ? first : 0, n]]
        if filter
          next unless filter.row_group_may_match?(self, i)
          ranges = Filter.intersect(ranges, filter.page_ranges(self, i))
        end
        plan << [i, ranges] unless ranges.empty?
      end
      plan
    end

    # Decodes one Thrift struct stored elsewhere in the file (ColumnIndex, OffsetIndex)
    #
    # @param klass [Class] Format struct class to decode with (responds to .decode)
    # @param offset [Integer, nil] file offset of the struct
    # @param length [Integer, nil] byte length of the struct
    # @param crypto [Encryption::ModuleCrypto, nil] decryption of the chunk's modules
    # @param type [Integer, nil] the struct's module type, when encrypted
    # @return [Object, nil] the decoded +klass+ instance, or nil when absent, truncated or corrupt
    # @raise [DecryptionError] when an encrypted struct does not decrypt
    def read_struct(klass, offset, length, crypto = nil, type = nil)
      return nil unless offset && length&.positive?
      @io.seek(offset)
      bytes = @io.read(length)
      return nil unless bytes&.bytesize == length
      bytes = crypto.decrypt(type, bytes.b) if crypto
      klass.decode(bytes.b).first
    rescue Thrift::Error, FormatError
      nil # a damaged index only means pages cannot be skipped
    end

    # The top-level fields named by a +columns:+ option
    #
    # @param columns [Array<String, Symbol>, String, Symbol, nil] field names; nil selects all
    # @return [Array<Schema::Field>] the fields, in the order requested
    # @raise [ArgumentError] when a name is not a top-level field
    def select_fields(columns)
      return @schema.fields unless columns
      Array(columns).map { |c| @schema.field(c) or raise ArgumentError, "No such column #{c.inspect}" }
    end

    # Hash keys for the given fields (frozen, deduplicated Strings, or Symbols)
    #
    # @param fields [Array<Schema::Field>] top-level fields being returned
    # @param symbolize [Boolean] whether to key by Symbol instead of String
    # @return [Array<String>, Array<Symbol>] one key per field
    def row_keys(fields, symbolize)
      fields.map { |f| symbolize ? f.name.to_sym : -f.name }
    end

    # Turns column-wise batch data into row Hashes
    #
    # @param names [Array<String>, Array<Symbol>] Hash key per output field
    # @param data [Array<Array>] values per output field, each holding +k+ entries
    # @param k [Integer] number of rows in the batch
    # @return [Array<Hash>] +k+ row Hashes
    def build_rows(names, data, k)
      return Array.new(k) { {} } if names.empty?
      return data.first.map { |v| {names.first => v} } if names.size == 1
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

    # The column's value converter, with the time zone applied to timestamps
    #
    # @param column [Schema::Column] leaf column being read
    # @return [Proc, nil] physical value => Ruby value, or nil when values are used as decoded
    def converter_for(column)
      base = column.converter
      zc = @zone_converter
      return base unless zc && base && instant_column?(column)
      ->(v) { zc.call(base.call(v)) }
    end

    # Timestamps that denote an instant (UTC-adjusted TIMESTAMP, INT96). Local timestamps
    # (isAdjustedToUTC = false) are wall-clock values and are left as they are.
    #
    # @param column [Schema::Column] leaf column to check
    # @return [Boolean] true when the time zone applies to this column's values
    def instant_column?(column)
      return true if column.type == Format::Type::INT96
      kind, _unit, utc = Types.logical_of(column.node)
      kind == :timestamp && utc
    end

    # A UTC offset string: "+02", "+0200", "+02:00" or "+02:00:00" (sign required)
    OFFSET_PATTERN = /\A([+-])(\d\d)(?::?(\d\d)(?::?(\d\d))?)?\z/

    # A lambda turning a UTC Time into the zone, or nil for UTC
    #
    # @param zone [String, Integer, Object, nil] the +time_zone:+ option: a UTC offset (String or
    #   seconds), a zone name (ActiveSupport or TZInfo), an object responding to #at or
    #   #utc_to_local, or nil
    # @return [Proc, nil] Time => Time (or ActiveSupport::TimeWithZone), nil for UTC
    # @raise [ArgumentError] for an unknown, unsupported or out-of-range zone
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
          return zone_converter(((m[1] == "-") ? -1 : 1) * (m[2].to_i * 3600 + m[3].to_i * 60 + m[4].to_i))
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

    # Reads and decodes the footer: the FileMetaData Thrift struct, its 4-byte little-endian
    # length and the closing magic.
    #
    # In an encrypted file the footer is decrypted (or its signature checked), and so is the
    # metadata of the columns whose key is available.
    #
    # @return [Format::FileMetaData] the decoded footer
    # @raise [FormatError] when the file is too short, lacks the magic or the footer is corrupt
    # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted
    def read_footer
      @io.seek(0, IO::SEEK_END)
      size = @io.pos
      raise FormatError, "File too small to be Parquet (#{size} bytes)" if size < 12
      @io.seek(size - 8)
      tail = @io.read(8)
      magic = tail.byteslice(4, 4)
      raise FormatError, "Missing PAR1 footer magic" unless magic == MAGIC || magic == ENCRYPTED_MAGIC
      footer_len = tail.unpack1("V")
      raise FormatError, "Footer length #{footer_len} exceeds file size" if footer_len + 12 > size
      @io.seek(size - 8 - footer_len)
      footer = @io.read(footer_len).b
      if magic == MAGIC
        meta = Format::FileMetaData.decode(footer).first
        return meta unless meta.encryption_algorithm
      end
      meta, @decryptor = Encryption.read_footer(footer, magic, @decryption)
      meta
    rescue Thrift::Error => e
      raise FormatError, "Corrupt file metadata: #{e.message}"
    end

    # Rebuilds nested values of one top-level field from the levels of its leaf columns
    # (the "record assembly" half of the Dremel algorithm).
    class Assembler
      # @param field [Schema::Field] top-level field to assemble
      # @param symbolize [Boolean] whether struct Hashes are keyed by Symbol instead of String
      def initialize(field, symbolize = false)
        @field = field
        @symbolize = symbolize
        @keys = {} # struct child Field => Hash key
      end

      # Assembles +n+ values of the field from +chunks+ (leaf column index =>
      # [defs, reps, values] holding exactly those rows)
      #
      # @param n [Integer] number of rows in +chunks+
      # @param chunks [Hash{Integer => Array(Array<Integer>, Array<Integer>, Array)}] leaf column
      #   index => [definition levels, repetition levels, values]; levels may be nil
      # @return [Array] +n+ assembled values (nil, scalars, Arrays, Hashes)
      # @raise [FormatError] when the levels do not add up to +n+ rows
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
          return defs.map { |d| (d == max) ? vals[vi += 1] : nil }
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
      #
      # @param field [Schema::Field] list field whose element is a leaf with repetition level 1
      # @return [Array<Array, nil>] one list (or nil) per row
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

      # Hash key for a struct member, memoized
      #
      # @param field [Schema::Field] struct child
      # @return [String, Symbol] frozen name, or Symbol when symbolizing
      def key_for(field)
        @keys[field] ||= @symbolize ? field.name.to_sym : -field.name
      end

      # Assembles one value of +field+ at the current entry cursors, recursing into children
      #
      # @param field [Schema::Field] field to assemble
      # @return [Object, nil] scalar, Hash (struct, map), Array (list) or nil
      # @raise [FormatError] when the definition levels run out
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

      # Moves every leaf of +field+ past one entry (a null or empty value takes a single entry)
      #
      # @param field [Schema::Field] field whose leaves to advance
      # @return [void]
      def skip(field)
        field.leaves.each { |col| @ei[col.index] += 1 }
      end
    end
  end
end

require_relative "reader/page_stream"
require_relative "reader/column_chunk_reader"
require_relative "reader/column_cursor"
require_relative "reader/bloom_filters"

module Herringbone
  class Reader
    autoload :Filter, File.expand_path("reader/scan", __dir__)
    autoload :NumoColumns, File.expand_path("reader/numo", __dir__)
    autoload :NumoCursor, File.expand_path("reader/numo", __dir__)
  end
end
