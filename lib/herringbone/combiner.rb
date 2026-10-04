# frozen_string_literal: true

module Herringbone
  # Concatenates Parquet files into one, behind Herringbone.combine. Building it opens every input
  # and checks its schema, so mismatches surface before anything is written.
  #
  # Every row group of every input becomes a row group of the output, in order. When an input has
  # the output schema, its column chunks are copied byte for byte and only their offsets (in the
  # column metadata, the page index and the bloom filter references) are rebased. Columns that
  # cannot be copied are encoded again from their values: those the output schema made nullable,
  # those encrypted in the input or to be encrypted in the output. Fields an input lacks are
  # written as nulls.
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
    #   @return [Hash{String => Symbol}] output field name => +:copy+, +:encode+ or +:null+
    # @!attribute first_rows
    #   @return [Array<Integer>] index of the first row of each row group in the input
    Input = Struct.new(:reader, :copier, :plan, :first_rows)

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
    # @raise [ArgumentError] naming the first column that differs
    def common_schema(readers)
      first = readers.first.schema
      readers.each_with_index.drop(1).each do |reader, k|
        diff = first.difference(reader.schema) or next
        raise ArgumentError, "The schema of input #{k} differs from that of input 0: #{mismatch(diff, "input 0", "input #{k}")}. " \
          "Combine files with the same schema, or pass schema: (e.g. a.schema + b.schema) to fill the gaps with nulls"
      end
      first
    end

    # What happens to each output field for an input: copied when the input has it as it is,
    # encoded again when the input has it required and the output optional, written as nulls when
    # the input lacks it
    #
    # @param input_schema [Schema] the input's schema
    # @param k [Integer] the input's position, for error messages
    # @return [Hash{String => Symbol}] output field name => +:copy+, +:encode+ or +:null+
    # @raise [ArgumentError] when the input does not fit the output schema
    def plan(input_schema, k)
      extra = input_schema.fields.map(&:name) - @schema.fields.map(&:name)
      raise ArgumentError, "Input #{k} has the field #{extra.first}, which is not in the schema" unless extra.empty?
      @schema.fields.to_h do |field|
        theirs = input_schema.field(field.name)
        mine = field.node.signature
        action = if theirs.nil?
          raise ArgumentError, "Input #{k} lacks #{field.name}, which the schema requires" unless field.optional
          :null
        elsif theirs.node.signature == mine
          :copy
        elsif field.optional && theirs.node.signature.drop(2) == mine.drop(2) && theirs.node.repetition == :required
          :encode
        else
          diff = field.node.difference(theirs.node)
          raise ArgumentError, "Input #{k} does not fit the schema: #{mismatch(diff, "the schema", "input #{k}")}"
        end
        [field.name, action]
      end
    end

    # @param diff [Schema::Difference] where two schemas differ
    # @param mine [String] what to call the first schema
    # @param theirs [String] what to call the second one
    # @return [String] e.g. "address.zip: optional INT32 zip in input 0, optional BYTE_ARRAY zip (STRING) in input 1"
    def mismatch(diff, mine, theirs)
      path = diff.path.empty? ? "the top level" : diff.path
      return "#{path} is only in #{theirs}" unless diff.mine
      return "#{path} is only in #{mine}" unless diff.theirs
      "#{path}: #{diff.mine} in #{mine}, #{diff.theirs} in #{theirs}"
    end

    # Writes row group +i+ of +input+, copying the column chunks it can
    #
    # @param input [Input] the input file, its reader and its plan
    # @param i [Integer] row group index in the input
    # @param writer [Writer] the output
    # @return [Symbol] +:copied+ or +:rewritten+
    def write_row_group(input, i, writer)
      reader = input.reader
      chunks = reader.row_groups[i].columns
      n = reader.row_groups[i].num_rows
      encode = @schema.fields.select do |field|
        next false if input.plan[field.name] == :null
        input.plan[field.name] == :encode || field.leaves.any? do |col|
          writer.encrypted_column?(col.index) || chunks.fetch(reader.schema.column(col.path).index).crypto_metadata
        end
      end
      unless encode.empty?
        names = encode.map(&:name)
        data = reader.read(as: :columns, columns: names, from: input.first_rows[i], limit: n)
        names.each { |name| writer.buffer_field(name, data[name]) }
      end
      copies = {}
      codecs = {}
      blooms = {}
      @schema.fields.each do |field|
        case input.plan[field.name]
        when :null
          writer.buffer_field(field.name, Array.new(n))
        when :copy, :encode
          field.leaves.each do |col|
            source = reader.schema.column(col.path)
            if encode.include?(field)
              codec, bloom = input.copier.recode_settings(i, source)
              codecs[col.index] = codec if codec && @keep_codecs
              blooms[col.index] = true if bloom
            else
              copies[col.index] = input.copier.copy(i, source)
            end
          end
        end
      end
      writer.write_row_group(n, copies: copies, codecs: codecs, bloom_filters: blooms,
        sorting_columns: sorting_columns(reader, i))
      (copies.size == @schema.columns.size) ? :copied : :rewritten
    end

    # The row group's sorting columns, pointed at the output's columns. A column the output does
    # not have ends the list, since the columns after it were only sorted within its runs.
    #
    # @param reader [Reader] the input file the row group comes from
    # @param i [Integer] row group index
    # @return [Array<Format::SortingColumn>, nil]
    def sorting_columns(reader, i)
      out = []
      (reader.row_groups[i].sorting_columns || []).each do |sc|
        col = reader.schema.columns[sc.column_idx]
        j = col && @schema.column(col.path)&.index
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
