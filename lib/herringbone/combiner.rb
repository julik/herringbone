# frozen_string_literal: true

module Herringbone
  # Concatenates Parquet files into one, behind Herringbone.combine. Building it opens every input
  # and checks its schema, so mismatches surface before anything is written.
  #
  # Every row group of every input becomes a row group of the output, in order. When an input has
  # the output schema, its column chunks are copied byte for byte and only their offsets (in the
  # column metadata, the page index and the bloom filter references) are rebased. That goes for
  # each leaf column of an input whose stored bytes the output schema keeps, even when the input's
  # schema is narrower. Columns that cannot be copied are encoded again from their values: those
  # the output schema widens in physical type, time unit or nullability, and those encrypted in the
  # input or to be encrypted in the output. Fields an input lacks are written as nulls.
  class Combiner
    # What #apply did
    #
    # @!attribute rows
    #   @return [Integer] rows written
    # @!attribute row_groups
    #   @return [Hash{Symbol => Integer}] +{copied:, rewritten:}+ row group counts: a row group is
    #     rewritten when at least one of its column chunks had to be encoded again
    Report = Struct.new(:rows, :row_groups, keyword_init: true)

    # One input file
    #
    # @!attribute reader
    #   @return [Reader] the input's reader
    # @!attribute copier
    #   @return [Reader::ChunkCopier] takes column chunks out of the input
    # @!attribute plan
    #   @return [Plan] where each output column comes from in the input
    # @!attribute first_rows
    #   @return [Array<Integer>] index of the first row of each row group in the input
    Input = Struct.new(:reader, :copier, :plan, :first_rows)

    # How an input maps onto the output schema
    #
    # @!attribute sources
    #   @return [Hash{Integer => Schema::Column}] output column index => the input's column holding
    #     its values; output columns the input lacks are not in it
    # @!attribute copyable
    #   @return [Array<Integer>] output column indices whose input chunks store their values as the
    #     output does, so they can be copied unless encryption is in the way
    Plan = Struct.new(:sources, :copyable)

    # Converted annotations of time and timestamp columns => their unit
    CONVERTED_UNITS = {
      Format::ConvertedType::TIME_MILLIS => :millis, Format::ConvertedType::TIME_MICROS => :micros,
      Format::ConvertedType::TIMESTAMP_MILLIS => :millis, Format::ConvertedType::TIMESTAMP_MICROS => :micros
    }.freeze

    # Writer options that make no sense here, since row groups keep their boundaries
    ROW_GROUP_OPTIONS = %i[row_group_bytes row_group_rows].freeze
    # Footer metadata that describes the columns, and goes stale when the schema changes
    COLUMN_METADATA_KEYS = %w[ARROW:schema pandas].freeze

    # @return [Schema] the schema of the output
    attr_reader :schema

    # @param ios [Array<IO, StringIO>] the input files, read with #seek and #read
    # @param schema [Schema, nil] the output schema; nil when every input has the same schema
    # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, Array, #call, nil] keys of
    #   encrypted inputs, see Reader.new
    # @raise [ArgumentError] when there are no inputs, the inputs' schemas differ and +schema+ is
    #   not given, or an input does not fit +schema+
    # @raise [FormatError] when an input's footer cannot be read
    # @raise [DecryptionError] when an input's footer is encrypted and cannot be decrypted
    def initialize(ios, schema: nil, decryption: nil)
      raise ArgumentError, "Herringbone.combine takes an Array of IOs, got #{ios.class}" unless ios.is_a?(Array)
      raise ArgumentError, "Herringbone.combine needs at least one input" if ios.empty?
      readers = ios.map { |io| Reader.new(io, decryption: decryption) }
      @schema = schema || common_schema(readers)
      raise ArgumentError, "Expected a Herringbone::Schema, got #{@schema.class}" unless @schema.is_a?(Schema)
      @inputs = readers.each_with_index.map do |reader, k|
        firsts = reader.row_groups.each_with_object([0]) { |rg, acc| acc << acc.last + rg.num_rows }
        Input.new(reader, Reader::ChunkCopier.new(reader, ios[k]), plan(reader.schema, k), firsts)
      end
    end

    # @param output [IO, #write] destination, written sequentially; not closed
    # @param options [Hash{Symbol => Object}] Writer options for chunks encoded again, and
    #   +metadata:+ / +encryption:+ for the output
    # @option options [Symbol] :compression (codec of each source chunk) codec for chunks encoded
    #   again; written nulls use the Writer's default
    # @option options [Hash{String => String}] :metadata (the first input's) footer key/value metadata
    # @option options [EncryptionConfiguration, Hash{Symbol => Object}, Key, String, false] :encryption
    #   see Writer; required when an input is encrypted (false for a plaintext output)
    # @option options [Integer, nil] :compression_level (nil) level for that codec, see Writer
    # @option options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
    #   columns whose encoded chunks get a bloom filter, besides those whose source chunk had one
    # @option options [Integer] :page_bytes (1MB) approximate uncompressed data page size
    # @option options [Integer] :page_rows (20_000) maximum rows per data page
    # @option options [Integer] :data_page_version (1) 1 or 2
    # @option options [Boolean, Array<String>] :dictionary (true) see Writer
    # @option options [Hash{String => Symbol}] :encodings ({}) see Writer
    # @return [Report]
    # @raise [ArgumentError] for +row_group_bytes:+ / +row_group_rows:+, for an encrypted input
    #   without +encryption:+, or an invalid writer option
    # @raise [DecryptionError] when an input's column is encrypted and its key was not given
    def apply(output, **options)
      bad = options.keys & ROW_GROUP_OPTIONS
      raise ArgumentError, "#{bad.join(", ")}: combining keeps the row groups of the inputs" unless bad.empty?
      encrypted = @inputs.index { |input| input.reader.decryptor }
      if encrypted && !options.key?(:encryption)
        raise ArgumentError, "Input #{encrypted} is encrypted: pass encryption: for the output, or encryption: false " \
          "to write it in plaintext"
      end
      @keep_codecs = !options.key?(:compression)
      options = {metadata: metadata}.merge(options)
      writer = Writer.new(output, @schema, row_group_bytes: 1 << 62, **options)
      report = Report.new(rows: 0, row_groups: {copied: 0, rewritten: 0})
      begin
        @inputs.each do |input|
          input.reader.row_groups.each_index do |i|
            next if input.reader.row_groups[i].num_rows.zero?
            kind = write_row_group(input, i, writer)
            report.row_groups[kind] += 1
          end
        end
      rescue Exception # rubocop:disable Lint/RescueException -- also abort on Interrupt
        writer.abort
        raise
      end
      writer.close
      report.rows = writer.rows_written
      report
    end

    private

    # @param readers [Array<Reader>] the inputs
    # @return [Schema] the schema all inputs have
    # @raise [ArgumentError] naming the top-level fields that differ
    def common_schema(readers)
      first = readers.first.schema
      readers.each_with_index.drop(1).each do |reader, k|
        next if reader.schema == first
        raise ArgumentError, "The schema of input #{k} differs from that of input 0 in #{differing_fields(first, reader.schema)}. " \
          "Combine files with the same schema, or pass schema: (e.g. a.schema + b.schema) to fill the gaps with nulls"
      end
      first
    end

    # @param a [Schema] one schema
    # @param b [Schema] a schema that is not == to +a+
    # @return [String] the top-level fields that are not the same in both, e.g. "address, phone"
    def differing_fields(a, b)
      names = a.fields.map(&:name) | b.fields.map(&:name)
      differ = names.reject { |name| a.field(name)&.node&.signature == b.field(name)&.node&.signature }
      differ.empty? ? "the order of the fields" : differ.join(", ")
    end

    # Where each output column comes from in an input. The input must be narrower than the output
    # or the same: uniting its fields with the output's (Schema#+) must leave the output's as they
    # are. Then each output leaf is found in the input through the logical tree, by name, so the
    # element of a pyarrow list ("list.item") or a legacy 2-level one is still the same column.
    #
    # @param input_schema [Schema] the input's schema
    # @param k [Integer] the input's position, for error messages
    # @return [Plan]
    # @raise [ArgumentError] when the input does not fit the output schema
    def plan(input_schema, k)
      extra = input_schema.fields.map(&:name) - @schema.fields.map(&:name)
      raise ArgumentError, "Input #{k} has the field #{extra.first}, which is not in the schema" unless extra.empty?
      united = begin
        @schema + input_schema
      rescue IncompatibleSchema => e
        raise ArgumentError, "Input #{k} does not fit the schema (the schema's type first, then the input's):\n" +
          e.conflicts.map { |c| "  #{c}" }.join("\n")
      end
      sources = {}
      @schema.fields.each do |field|
        theirs = input_schema.field(field.name)
        mine = field.node.signature
        if theirs.nil?
          raise ArgumentError, "Input #{k} lacks #{field.name}, which the schema requires" unless field.optional
        elsif united.field(field.name).node.signature == mine
          match_columns(field, theirs, sources)
        elsif united.field(field.name).node.signature.drop(2) == mine.drop(2)
          raise ArgumentError, "Input #{k} does not fit the schema: #{field.name} is nullable in the input and required in the schema"
        else
          raise ArgumentError, "Input #{k} does not fit the schema: #{field.name} is wider in the input than in the schema " \
            "(a wider type, or nullable or more members); pass the union of the schemas"
        end
      end
      copyable = sources.select { |j, source| same_bytes?(@schema.columns[j], source) }.keys
      Plan.new(sources, copyable)
    end

    # @param mine [Schema::Field] a field of the output schema
    # @param theirs [Schema::Field, nil] the field of the same name in the input, of the same kind
    # @param sources [Hash{Integer => Schema::Column}] output column index => input column; added to
    # @return [void]
    def match_columns(mine, theirs, sources)
      return unless theirs
      case mine.kind
      when :leaf then sources[mine.column.index] = theirs.column
      when :struct
        by_name = theirs.children_by_name
        mine.children.each { |child| match_columns(child, by_name[child.name], sources) }
      when :list then match_columns(mine.element, theirs.element, sources)
      when :map
        match_columns(mine.key, theirs.key, sources)
        match_columns(mine.value, theirs.value, sources)
      end
    end

    # Whether a chunk of +theirs+ holds the values of +mine+ byte for byte. For a column of an
    # input that fits the output, the widenings that keep the bytes are those of the annotation
    # alone: int8 into int32, uint16 into int32, string into binary... Equal levels mean that no
    # field on the way became nullable, since nullability only ever widens here.
    #
    # @param mine [Schema::Column] a column of the output schema
    # @param theirs [Schema::Column] the input's column for it
    # @return [Boolean]
    def same_bytes?(mine, theirs)
      mine.type == theirs.type && mine.type_length == theirs.type_length &&
        mine.max_definition_level == theirs.max_definition_level &&
        mine.max_repetition_level == theirs.max_repetition_level &&
        time_unit(mine.node) == time_unit(theirs.node)
    end

    # @param node [Schema::Node] a leaf
    # @return [Symbol, nil] the unit of a time or timestamp column, nil for other columns
    def time_unit(node)
      lt = node.logical_type
      (lt&.timestamp || lt&.time)&.unit&.to_sym || CONVERTED_UNITS[node.converted_type]
    end

    # Writes row group +i+ of +input+, copying the column chunks it can. A field with a column that
    # cannot be copied is read as a whole, since Reader and Writer handle top-level fields; the
    # columns of it that can be copied still are.
    #
    # @param input [Input] the input file, its reader and its plan
    # @param i [Integer] row group index in the input
    # @param writer [Writer] the output
    # @return [Symbol] +:copied+ or +:rewritten+
    def write_row_group(input, i, writer)
      reader = input.reader
      sources = input.plan.sources
      chunks = reader.row_groups[i].columns
      n = reader.row_groups[i].num_rows
      copy = @schema.columns.select do |col|
        source = sources[col.index]
        input.plan.copyable.include?(col.index) && !writer.encrypted_column?(col.index) &&
          !chunks.fetch(source.index).crypto_metadata
      end.map(&:index)
      present, absent = @schema.fields.partition { |field| reader.schema.field(field.name) }
      absent.each { |field| writer.buffer_field(field.name, Array.new(n)) }
      encode = present.reject { |field| field.leaves.all? { |col| copy.include?(col.index) } }.map(&:name)
      unless encode.empty?
        data = reader.read(as: :columns, columns: encode, from: input.first_rows[i], limit: n)
        encode.each { |name| writer.buffer_field(name, data[name]) }
      end
      copies = {}
      codecs = {}
      blooms = {}
      @schema.columns.each do |col|
        source = sources[col.index] or next
        if copy.include?(col.index)
          copies[col.index] = input.copier.copy(i, source)
        else
          codec, bloom = input.copier.recode_settings(i, source)
          codecs[col.index] = codec if codec && @keep_codecs
          blooms[col.index] = true if bloom
        end
      end
      writer.write_row_group(n, copies: copies, codecs: codecs, bloom_filters: blooms,
        sorting_columns: sorting_columns(input, i))
      (copies.size == @schema.columns.size) ? :copied : :rewritten
    end

    # The row group's sorting columns, pointed at the output's columns. A column the output does
    # not have ends the list, since the columns after it were only sorted within its runs.
    #
    # @param input [Input] the input file the row group comes from
    # @param i [Integer] row group index
    # @return [Array<Format::SortingColumn>, nil]
    def sorting_columns(input, i)
      out = []
      output_index = input.plan.sources.to_h { |j, source| [source.index, j] }
      (input.reader.row_groups[i].sorting_columns || []).each do |sc|
        j = output_index[sc.column_idx]
        break unless j
        out << Format::SortingColumn.new(column_idx: j, descending: sc.descending, nulls_first: sc.nulls_first)
      end
      out.empty? ? nil : out
    end

    # @return [Hash{String => String, nil}] the first input's key/value metadata, without the keys
    #   that describe the columns when the output schema is another
    def metadata
      first = @inputs.first.reader
      meta = first.metadata
      (first.schema == @schema) ? meta : meta.except(*COLUMN_METADATA_KEYS)
    end
  end
end
