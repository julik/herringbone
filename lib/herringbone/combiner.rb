# frozen_string_literal: true

module Herringbone
  # Concatenates Parquet files into one, behind Herringbone.combine. Building it reads the footer of
  # every input and checks every input against the output schema, so all mismatches surface at
  # once, before anything is written.
  #
  # Every row group of every input becomes a row group of the output, in order. Column chunks are
  # copied byte for byte wherever the output stores a column's values as the input does, and only
  # their offsets (in the column metadata, the page index and the bloom filter references) are
  # rebased. That holds per leaf column, so a narrower input still has most of its chunks copied.
  # Columns that cannot be copied are encoded again from their values: those the output widens in
  # physical type, time unit or nullability, and those encrypted in the input or to be encrypted in
  # the output. Fields an input lacks are written as nulls.
  class Combiner
    # What #apply did
    #
    # @!attribute rows
    #   @return [Integer] rows written
    # @!attribute row_groups
    #   @return [Hash{Symbol => Integer}] +{copied:, rewritten:}+ row group counts: a row group is
    #     rewritten when at least one of its column chunks had to be encoded again
    # @!attribute inputs
    #   @return [Array<InputReport>] how each input was fitted to the output schema, in input order
    Report = Struct.new(:rows, :row_groups, :inputs, keyword_init: true)

    # How one input was fitted to the output schema. Paths are dotted field paths ("address.zip").
    #
    # @!attribute name
    #   @return [String] "input 2", with the IO's path when it has one: "input 2 (2026-03.parquet)"
    # @!attribute filled
    #   @return [Array<String>] fields the input lacks, written as nulls
    # @!attribute widened
    #   @return [Array<String>] fields the output holds in a wider type, or nullable
    # @!attribute dropped
    #   @return [Array<String>] fields of the input the output does not have (+schema: :intersect+)
    InputReport = Struct.new(:name, :filled, :widened, :dropped, keyword_init: true)

    # One input file: its Reader (with the combiner's own options), its ChunkCopier, output column
    # index => the input's column holding its values (output columns the input lacks are not in
    # it), and its InputReport
    Input = Struct.new(:reader, :copier, :sources, :report)

    # Closing paragraph of the message when inputs do not fit the output schema
    FIT_ADVICE = <<~ADVICE.chomp
      Pass a schema every input fits (schema: :union makes one), or schema: :intersect to keep only
      the fields all inputs have.
    ADVICE

    # Encryption settings the inherited encryption takes from the inputs => how messages name them
    ENCRYPTION_SETTINGS = {
      footer_key: "footer key", footer_key_metadata: "footer key metadata", plaintext_footer: "footer mode",
      algorithm: "algorithm", aad_prefix: "AAD prefix", store_aad_prefix: "AAD prefix storage"
    }.freeze
    # Settings whose values messages leave out
    SECRET_SETTINGS = %i[footer_key aad_prefix].freeze

    # Converted annotations of time and timestamp columns => their unit
    CONVERTED_UNITS = {
      Format::ConvertedType::TIME_MILLIS => :millis, Format::ConvertedType::TIME_MICROS => :micros,
      Format::ConvertedType::TIMESTAMP_MILLIS => :millis, Format::ConvertedType::TIMESTAMP_MICROS => :micros
    }.freeze

    # @return [Schema] the schema of the output
    attr_reader :schema

    # @param ios_or_readers [Enumerable<IO, StringIO, Reader>] the input files: IOs read with #seek
    #   and #read, or Readers (which bring their own +decryption:+); enumerated once, and none is
    #   closed
    # @param schema [Schema, Symbol, nil] the output schema: nil when every input has the same one,
    #   +:union+ for the union of the inputs' schemas, +:intersect+ for their intersection, or a
    #   Schema each input must fit
    # @param decryption [DecryptionConfiguration, Hash{Symbol => Object}, Array, #call, nil] keys of
    #   encrypted inputs given as IOs, see Reader.new
    # @raise [ArgumentError] when there are no inputs, an input is neither an IO nor a Reader, or
    #   +schema:+ is not one of the above
    # @raise [IncompatibleSchema] listing every input (and every field of it) that does not fit
    # @raise [FormatError] when an input's footer cannot be read
    # @raise [DecryptionError] when an input's footer is encrypted and cannot be decrypted
    def initialize(ios_or_readers, schema: nil, decryption: nil)
      unless schema.is_a?(Schema) || [nil, :union, :intersect].include?(schema)
        raise ArgumentError, "schema: takes :union, :intersect or a Herringbone::Schema, got #{schema.inspect}"
      end
      readers = open_readers(ios_or_readers, decryption)
      @names = readers.each_with_index.map do |reader, k|
        path = reader.io.path
        path.equal?(RestrictedReadableIO::UNTITLED) ? "input #{k}" : "input #{k} (#{path})"
      end
      @conflicts = []
      @schema = output_schema(schema, readers)
      @inputs = readers.each_with_index.map { |reader, k| fit(reader, k, schema == :intersect) }
      return if @conflicts.empty?
      what = {union: "the union of the inputs", intersect: "the intersection of the inputs"}.fetch(schema, "given as schema:")
      raise_conflicts("#{inputs_count("does", "do")} not fit the schema (#{what}):", "the schema", advice: FIT_ADVICE)
    end

    # @param output_io [IO, #write] destination, written sequentially; not closed
    # @param options [Hash{Symbol => Object}] Writer options for chunks encoded again, and
    #   +metadata:+ / +encryption:+ for the output
    # @option options [Symbol] :compression (codec of each source chunk) codec for chunks encoded
    #   again; written nulls use the Writer's default
    # @option options [Hash{String => String}] :metadata (the first input's) footer key/value metadata
    # @option options [EncryptionConfiguration, Hash{Symbol => Object}, Key, String, false] :encryption
    #   (encrypted like the encrypted inputs, if any) see Writer; false for a plaintext output
    # @option options [Integer, nil] :compression_level (nil) level for that codec, see Writer
    # @option options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
    #   columns whose encoded chunks get a bloom filter, besides those whose source chunk had one
    # @option options [Integer] :page_bytes (1MB) approximate uncompressed data page size
    # @option options [Integer] :page_rows (20_000) maximum rows per data page
    # @option options [Integer] :data_page_version (1) 1 or 2
    # @option options [Boolean, Array<String>] :dictionary (true) see Writer
    # @option options [Hash{String => Symbol}] :encodings ({}) see Writer
    # @return [Report]
    # @raise [ArgumentError] for +row_group_bytes:+ / +row_group_rows:+, an invalid writer option,
    #   or encrypted inputs that are encrypted differently while +encryption:+ is not given
    # @raise [DecryptionError] when a column is encrypted and its key was not given
    def apply(output_io, **options)
      options = {metadata: @inputs.first.copier.metadata(@schema)}.merge(options)
      options[:encryption] = inherited_encryption unless options.key?(:encryption)
      @keep_codecs = !options.key?(:compression)
      report = Report.new(rows: 0, row_groups: {copied: 0, rewritten: 0}, inputs: @inputs.map(&:report))
      Writer.open_for_copies(output_io, @schema, "combining keeps the row groups of the inputs", **options) do |writer|
        @inputs.each do |input|
          from = 0
          input.reader.row_groups.each_with_index do |rg, i|
            report.row_groups[write_row_group(input, i, from, writer)] += 1 unless rg.num_rows.zero?
            from += rg.num_rows
          end
        end
        report.rows = writer.rows_written
      end
      report
    end

    private

    # Readers with the combiner's own options. A Reader given as input lends its IO and its
    # decryption, but not its +keys:+ or +time_zone:+, which would change the values encoded again.
    #
    # @param ios_or_readers [Enumerable<IO, StringIO, Reader>] the inputs
    # @param decryption [Object, nil] keys for the inputs given as IOs
    # @return [Array<Reader>]
    # @raise [ArgumentError] when there are no inputs, or one is neither an IO nor a Reader
    def open_readers(ios_or_readers, decryption)
      # A single IO is Enumerable too (over its lines), hence the check for #read
      if ios_or_readers.respond_to?(:read) || !ios_or_readers.respond_to?(:each)
        raise ArgumentError, "Herringbone.combine takes an Enumerable of IOs or Herringbone::Readers, " \
          "got #{ios_or_readers.class}: Herringbone.combine([a, b], output_io)"
      end
      readers = ios_or_readers.each_with_index.map do |item, k|
        next Reader.new(item.io, decryption: item.decryption) if item.is_a?(Reader)
        next Reader.new(item, decryption: decryption) if item.respond_to?(:seek) && item.respond_to?(:read)
        hint = "; Herringbone does not open files by path, pass File.open(path, \"rb\")" if item.is_a?(String) || item.respond_to?(:to_path)
        raise ArgumentError, "Input #{k} is a #{item.class}, not an IO or a Herringbone::Reader#{hint}"
      end
      raise ArgumentError, "Herringbone.combine needs at least one input" if readers.empty?
      readers
    end

    # @param schema [Schema, Symbol, nil] the +schema:+ option
    # @param readers [Array<Reader>] the inputs
    # @return [Schema]
    # @raise [IncompatibleSchema] when the inputs' schemas differ (nil), or do not unite or intersect
    def output_schema(schema, readers)
      return schema if schema.is_a?(Schema)
      first = readers.first.schema
      readers.each_with_index.drop(1).each do |reader, k|
        if schema.nil?
          next if reader.schema == first
          before = @conflicts.size
          differences(first, reader.schema, k, "input 0")
          if @conflicts.size == before
            reordered = reader.schema.fields.map(&:name) != first.fields.map(&:name)
            conflict([], nil, nil, reordered ? "the fields are in another order than in input 0" :
              "the same fields as input 0, annotated or laid out another way", k)
          end
        else
          first = (schema == :union) ? first + reader.schema : first & reader.schema
        end
      rescue IncompatibleSchema => e
        e.conflicts.each { |c| conflict(c.path, c.left, c.right, c.reason, k) }
      end
      return first if @conflicts.empty?
      if schema.nil?
        raise_conflicts("#{inputs_count("has", "have")} another schema than #{@names[0]}:", "input 0", advice: <<~ADVICE.chomp)
          Combine files with the same schema, or pass schema: :union to fill the fields an input lacks
          with nulls and widen the others, or schema: :intersect to keep only the fields all inputs have.
        ADVICE
      end
      raise_conflicts("Cannot #{(schema == :union) ? "unite" : "intersect"} the schemas of the inputs, " \
        "#{inputs_count("does", "do")} not fit those before it:", "the inputs before it")
    end

    # Each field of +mine+ with the field of the same name in +theirs+ (nil when there is none),
    # then the same for their members down through structs, lists and maps
    #
    # @param mine [Schema] the schema walked
    # @param theirs [Schema] the schema its fields are looked up in
    # @return [Array<Array(Schema::Field, Schema::Field, String)>] field, twin and dotted path
    def pairs(mine, theirs)
      walk = lambda do |a, b, path|
        [[a, b, path.join(".")]] + case (b && a.kind == b.kind) ? a.kind : nil
        when :struct
          by_name = b.children_by_name
          a.children.flat_map { |c| walk.call(c, by_name[c.name], path + [c.name]) }
        when :list then walk.call(a.element, b.element, path + ["element"])
        when :map then walk.call(a.key, b.key, path + ["key"]) + ((a.value && b.value) ? walk.call(a.value, b.value, path + ["value"]) : [])
        else []
        end
      end
      mine.fields.flat_map { |f| walk.call(f, theirs.field(f.name), [f.name]) }
    end

    # Where the fields of +theirs+ differ from those of +mine+, recorded as conflicts
    #
    # @param mine [Schema] the schema compared with
    # @param theirs [Schema] the input's schema
    # @param k [Integer] the input's position
    # @param other [String] what to call +mine+, e.g. "input 0"
    # @param skip [Array<String>] paths not to compare
    # @return [void]
    def differences(mine, theirs, k, other, skip: [])
      pairs(mine, theirs).each do |a, b, path|
        next if skip.include?(path)
        if b.nil? then conflict(path, nil, nil, "missing here, #{other} has it", k)
        elsif (da = describe(a)) != (db = describe(b)) then conflict(path, da, db, nil, k)
        elsif a.optional != b.optional
          conflict(path, a.optional ? "nullable" : "required", b.optional ? "nullable" : "required", nil, k)
        elsif a.node.field_id != b.node.field_id
          conflict(path, "field_id #{a.node.field_id.inspect}", "field_id #{b.node.field_id.inspect}", nil, k)
        end
      end
      pairs(theirs, mine).each { |_, a, path| conflict(path, nil, nil, "only here, #{other} lacks it", k) unless a }
    end

    # Fits an input to the output schema, recording the conflicts when it does not fit. The input
    # must be the same as the output or narrower: uniting it with the output (Schema#+) must leave
    # the output as it is. Each output leaf is found in the input through the logical tree, by
    # name, so the element of a pyarrow list ("list.item") or of a legacy 2-level list is still the
    # same column.
    #
    # @param reader [Reader] the input
    # @param k [Integer] its position
    # @param drop [Boolean] whether fields the output lacks are dropped (+schema: :intersect+)
    #   rather than refused
    # @return [Input]
    def fit(reader, k, drop)
      theirs = reader.schema
      pairs = pairs(@schema, theirs)
      filled = pairs.filter_map { |_, b, path| path unless b }
      dropped = pairs(theirs, @schema).filter_map { |_, a, path| path unless a }
      if pairs.all? { |_, b, _| b.nil? }
        conflict([], @schema.fields.map(&:name).join(", "), theirs.fields.map(&:name).join(", "), "no fields in common with the schema", k)
      else
        pairs.each { |a, b, path| conflict(path, nil, nil, "missing here, and the schema requires it", k) if b.nil? && !a.optional }
        begin
          fitted = @schema + (drop ? theirs & @schema : theirs)
          differences(@schema, fitted, k, "the schema", skip: filled)
        rescue IncompatibleSchema => e
          e.conflicts.each { |c| conflict(c.path, c.left, c.right, c.reason, k) }
        end
      end
      sources = pairs.filter_map { |a, b, _| [a.column.index, b.column] if b && a.leaf? && b.leaf? }.to_h
      widened = pairs.filter_map { |a, b, path| path if b && (a.optional != b.optional || (a.leaf? && describe(a) != describe(b))) }
      report = InputReport.new(name: @names[k], filled: filled, widened: widened, dropped: dropped)
      Input.new(reader, Reader::ChunkCopier.new(reader), sources, report)
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

    # @param field [Schema::Field] any field
    # @return [String] its type as messages name it, see Schema::Merge#describe
    def describe(field) = (@describer ||= Schema::Merge.new(:union)).describe(field)

    # @param path [String, Array<String>] path of the field, empty for the input as a whole
    # @param left [String, nil] the field as the schema compared with has it
    # @param right [String, nil] the field as the input has it
    # @param reason [String, nil] why they do not fit
    # @param k [Integer] the input's position
    # @return [void]
    def conflict(path, left, right, reason, k)
      @conflicts << IncompatibleSchema::Conflict.new(Array(path).join("."), left, right, reason, k)
    end

    # @param singular [String] the verb for one input, e.g. "does"
    # @param plural [String] the verb for several, e.g. "do"
    # @return [String] the inputs with conflicts and the verb: "2 of 5 inputs do", "1 of 5 inputs
    #   does", or "The input does" when there is only one
    def inputs_count(singular, plural)
      n = @conflicts.map(&:input).uniq.size
      return "The input #{singular}" if @names.size == 1
      "#{n} of #{@names.size} inputs #{(n == 1) ? singular : plural}"
    end

    # Raises the conflicts, grouped by input, as one IncompatibleSchema:
    #
    #   2 of 3 inputs do not fit the schema (schema:):
    #
    #     input 1 (2026-02.parquet)
    #       price        double in the schema, string here (no common type)
    #       address.zip  required in the schema, nullable here
    #
    # @param header [String] the first line
    # @param other [String] what to call the schema the inputs are compared with, e.g. "the schema"
    # @param advice [String, nil] a closing paragraph
    # @return [void]
    # @raise [IncompatibleSchema] always
    def raise_conflicts(header, other, advice: nil)
      groups = @conflicts.group_by(&:input).map do |k, conflicts|
        width = conflicts.map { |c| c.path.size }.max
        lines = conflicts.map do |c|
          if c.path.empty? && c.left
            "#{c.reason}\n      #{other}: #{c.left.delete_prefix("fields ")}\n      here: #{c.right.delete_prefix("fields ")}"
          elsif c.path.empty?
            c.reason
          else
            detail = [("#{c.left} in #{other}, #{c.right} here" if c.left), ("(#{c.reason})" if c.reason && c.left), (c.reason unless c.left)]
            "#{c.path.ljust(width)}  #{detail.compact.join(" ")}"
          end
        end
        "  #{@names[k]}\n#{lines.map { |l| "    #{l}" }.join("\n")}"
      end
      message = [header, groups.join("\n\n"), advice].compact.join("\n\n")
      raise IncompatibleSchema.new(@conflicts, message: message)
    end

    # The +encryption:+ option that encrypts the output like the encrypted inputs: the same
    # algorithm, footer mode, footer key and key metadata, AAD prefix, and the same key for each
    # column. Plaintext inputs get that encryption too.
    #
    # @return [EncryptionConfiguration, nil] nil when no input is encrypted
    # @raise [ArgumentError] listing how the encrypted inputs differ, when they do
    # @raise [DecryptionError] when a key the output needs was not given
    def inherited_encryption
      encrypted = @inputs.select { |input| input.reader.decryptor }
      return nil if encrypted.empty?
      settings = encrypted.map { |input| input.reader.decryptor.writer_settings(nil).to_h.except(:columns) }
      problems = settings.first.keys.filter_map do |setting|
        groups = encrypted.zip(settings).group_by { |_, h| h[setting] }
        next if groups.size == 1
        "#{ENCRYPTION_SETTINGS.fetch(setting)} differs: " + groups.map { |value, members|
          "#{members.map { |input, _| input.report.name }.join(", ")}#{" (#{value.inspect})" unless SECRET_SETTINGS.include?(setting)}"
        }.join(" / ")
      end
      columns = {}
      owners = {}
      layouts = encrypted.map { |input| input.copier.encrypted_columns(input.sources.to_h { |j, col| [@schema.columns[j].dotted_path, col] }) }
      encrypted.zip(layouts).each do |input, layout|
        layout.each do |path, setting|
          owner = owners[path] ||= input.report.name
          columns[path] ||= setting
          problems << "#{path} is encrypted with another key in #{input.report.name} than in #{owner}" if columns[path] != setting
        end
      end
      unless problems.empty?
        raise ArgumentError, <<~MESSAGE.chomp
          The encrypted inputs are encrypted differently, so there is no "encrypted like the inputs":

          #{problems.map { |p| "  #{p}" }.join("\n")}

          Pass encryption: for the output (a Herringbone::Key or an EncryptionConfiguration), or
          encryption: false to write it in plaintext.
        MESSAGE
      end
      uniform = encrypted.zip(layouts).all? { |input, layout| layout.size == input.sources.size && layout.values.all?(:footer) }
      EncryptionConfiguration.new(**settings.first, columns: uniform ? nil : columns)
    end

    # Writes row group +i+ of +input+, copying the column chunks it can. A field with a column that
    # cannot be copied is read as a whole, since Reader and Writer handle top-level fields; the
    # columns of it that can be copied still are.
    #
    # @param input [Input] the input file
    # @param i [Integer] row group index in the input
    # @param from [Integer] index of the row group's first row in the input
    # @param writer [Writer] the output
    # @return [Symbol] +:copied+ or +:rewritten+
    def write_row_group(input, i, from, writer)
      chunks = input.reader.row_groups[i].columns
      n = input.reader.row_groups[i].num_rows
      copies = {}
      codecs = {}
      blooms = {}
      input.sources.each do |j, source|
        if same_bytes?(@schema.columns[j], source) && !writer.encrypted_column?(j) && !chunks.fetch(source.index).crypto_metadata
          copies[j] = input.copier.copy(i, source)
        else
          codec, bloom = input.copier.recode_settings(i, source)
          codecs[j] = codec if codec && @keep_codecs
          blooms[j] = true if bloom
        end
      end
      encode = @schema.fields.reject { |field| field.leaves.all? { |col| copies.key?(col.index) } }
      present = encode.map(&:name) & input.reader.schema.fields.map(&:name)
      data = present.empty? ? {} : input.reader.read(as: :columns, columns: present, from: from, limit: n)
      encode.each { |field| writer.buffer_field(field.name, data.fetch(field.name) { Array.new(n) }) }
      sorting = input.copier.sorting_columns(i, input.sources.to_h { |j, source| [source.index, j] })
      writer.write_row_group(n, copies: copies, codecs: codecs, bloom_filters: blooms, sorting_columns: sorting)
      (copies.size == @schema.columns.size) ? :copied : :rewritten
    end
  end
end
