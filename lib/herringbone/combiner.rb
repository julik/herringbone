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

    # One input file
    #
    # @!attribute reader
    #   @return [Reader] reads the input with the combiner's own options
    # @!attribute copier
    #   @return [Reader::ChunkCopier] takes column chunks out of the input
    # @!attribute plan
    #   @return [Plan] where each output column comes from in the input
    # @!attribute first_rows
    #   @return [Array<Integer>] index of the first row of each row group in the input
    # @!attribute name
    #   @return [String] how messages and the report name the input
    Input = Struct.new(:reader, :copier, :plan, :first_rows, :name)

    # How an input maps onto the output schema
    #
    # @!attribute sources
    #   @return [Hash{Integer => Schema::Column}] output column index => the input's column holding
    #     its values; output columns the input lacks are not in it
    # @!attribute copyable
    #   @return [Array<Integer>] output column indices whose input chunks store their values as the
    #     output does, so they can be copied unless encryption is in the way
    # @!attribute filled
    #   @return [Array<String>] see InputReport#filled
    # @!attribute widened
    #   @return [Array<String>] see InputReport#widened
    # @!attribute dropped
    #   @return [Array<String>] see InputReport#dropped
    Plan = Struct.new(:sources, :copyable, :filled, :widened, :dropped)

    # Closing paragraph of the message when inputs do not fit the output schema
    FIT_ADVICE = <<~ADVICE.chomp
      Pass a schema every input fits (schema: :union makes one), or schema: :intersect to keep only
      the fields all inputs have.
    ADVICE

    # Values of +schema:+ besides a Schema
    SCHEMA_MODES = [nil, :union, :intersect].freeze

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
      unless schema.is_a?(Schema) || SCHEMA_MODES.include?(schema)
        raise ArgumentError, "schema: takes :union, :intersect or a Herringbone::Schema, got #{schema.inspect}"
      end
      readers = open_readers(ios_or_readers, decryption)
      @names = readers.each_with_index.map { |reader, k| input_name(reader, k) }
      @schema = output_schema(schema, readers)
      @conflicts = []
      plans = readers.each_with_index.map { |reader, k| plan(reader.schema, k, drop: schema == :intersect) }
      raise_conflicts(fit_header(schema), "the schema", advice: FIT_ADVICE) unless @conflicts.empty?
      @inputs = readers.each_with_index.map do |reader, k|
        firsts = reader.row_groups.each_with_object([0]) { |rg, acc| acc << acc.last + rg.num_rows }
        Input.new(reader, Reader::ChunkCopier.new(reader, reader.io), plans[k], firsts, @names[k])
      end
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
      bad = options.keys & ROW_GROUP_OPTIONS
      raise ArgumentError, "#{bad.join(", ")}: combining keeps the row groups of the inputs" unless bad.empty?
      options[:encryption] = inherited_encryption unless options.key?(:encryption)
      @keep_codecs = !options.key?(:compression)
      options = {metadata: metadata}.merge(options)
      writer = Writer.new(output_io, @schema, row_group_bytes: 1 << 62, **options)
      report = Report.new(rows: 0, row_groups: {copied: 0, rewritten: 0}, inputs: input_reports)
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

    # Readers with the combiner's own options. A Reader given as input lends its IO and its
    # decryption, but not its +keys:+ or +time_zone:+, which would change the values encoded again.
    #
    # @param ios_or_readers [Enumerable<IO, StringIO, Reader>] the inputs
    # @param decryption [Object, nil] keys for the inputs given as IOs
    # @return [Array<Reader>]
    # @raise [ArgumentError] when there are no inputs, or one is neither an IO nor a Reader
    def open_readers(ios_or_readers, decryption)
      if ios_or_readers.is_a?(Reader) || ios_or_readers.respond_to?(:read) || !ios_or_readers.respond_to?(:each)
        raise ArgumentError, "Herringbone.combine takes an Enumerable of IOs or Herringbone::Readers, " \
          "got #{ios_or_readers.class}: Herringbone.combine([a, b], output_io)"
      end
      items = ios_or_readers.to_a
      raise ArgumentError, "Herringbone.combine needs at least one input" if items.empty?
      items.each_with_index.map do |item, k|
        if item.is_a?(Reader)
          Reader.new(item.io, decryption: item.decryption)
        elsif item.respond_to?(:seek) && item.respond_to?(:read)
          Reader.new(item, decryption: decryption)
        else
          hint = "; Herringbone does not open files by path, pass File.open(path, \"rb\")" if item.is_a?(String) || item.respond_to?(:to_path)
          raise ArgumentError, "Input #{k} is a #{item.class}, not an IO or a Herringbone::Reader#{hint}"
        end
      end
    end

    # @param reader [Reader] an input
    # @param k [Integer] its position
    # @return [String] "input 2", or "input 2 (path)" for an IO with a #path
    def input_name(reader, k)
      path = reader.io.path if reader.io.respond_to?(:path)
      path ? "input #{k} (#{path})" : "input #{k}"
    end

    # @param schema [Schema, Symbol, nil] the +schema:+ option
    # @param readers [Array<Reader>] the inputs
    # @return [Schema]
    # @raise [IncompatibleSchema] when the inputs' schemas differ (nil), or do not unite or intersect
    def output_schema(schema, readers)
      case schema
      when Schema then schema
      when nil then same_schema(readers)
      else derived_schema(schema, readers)
      end
    end

    # @param readers [Array<Reader>] the inputs
    # @return [Schema] the schema all inputs have
    # @raise [IncompatibleSchema] naming every field of every input that differs from input 0
    def same_schema(readers)
      first = readers.first.schema
      @conflicts = []
      readers.each_with_index.drop(1).each do |reader, k|
        next if reader.schema == first
        before = @conflicts.size
        differences(first.fields, reader.schema.fields, [], k, "input 0")
        conflict([], nil, nil, "the fields are in another order than in input 0", k) if @conflicts.size == before
      end
      return first if @conflicts.empty?
      raise_conflicts("#{inputs_count("has", "have")} another schema than #{@names[0]}:", "input 0", advice: <<~ADVICE.chomp)
        Combine files with the same schema, or pass schema: :union to fill the fields an input lacks
        with nulls and widen the others, or schema: :intersect to keep only the fields all inputs have.
      ADVICE
    end

    # The union or intersection of the inputs' schemas, input by input. An input that does not
    # fit those before it is set aside, so the inputs after it are still checked.
    #
    # @param mode [Symbol] +:union+ or +:intersect+
    # @param readers [Array<Reader>] the inputs
    # @return [Schema]
    # @raise [IncompatibleSchema] naming every input (and field) that did not fit
    def derived_schema(mode, readers)
      @conflicts = []
      result = readers.first.schema
      readers.each_with_index.drop(1).each do |reader, k|
        result = (mode == :union) ? result + reader.schema : result & reader.schema
      rescue IncompatibleSchema => e
        e.conflicts.each { |c| @conflicts << IncompatibleSchema::Conflict.new(c.path, c.left, c.right, c.reason, k) }
      end
      return result if @conflicts.empty?
      verb = (mode == :union) ? "unite" : "intersect"
      raise_conflicts("Cannot #{verb} the schemas of the inputs, #{inputs_count("does", "do")} not fit those before it:",
        "the inputs before it")
    end

    # Where an input's fields differ from those of another schema, recorded as conflicts
    #
    # @param mine [Array<Schema::Field>] fields of the schema compared with
    # @param theirs [Array<Schema::Field>] fields of the input
    # @param path [Array<String>] path of the enclosing field, empty at the top level
    # @param k [Integer] the input's position
    # @param other [String] what to call the schema compared with, e.g. "input 0"
    # @return [void]
    def differences(mine, theirs, path, k, other)
      by_name = theirs.to_h { |f| [f.name, f] }
      names = mine.map(&:name)
      mine.each do |field|
        twin = by_name[field.name]
        at = path + [field.name]
        if twin.nil?
          conflict(at, nil, nil, "missing here, #{other} has it", k)
        else
          field_differences(field, twin, at, k, other)
        end
      end
      theirs.reject { |f| names.include?(f.name) }.each { |f| conflict(path + [f.name], nil, nil, "only here, #{other} lacks it", k) }
    end

    # @param a [Schema::Field] a field of the schema compared with
    # @param b [Schema::Field] the field of the same name in the input
    # @param path [Array<String>] path of the field
    # @param k [Integer] the input's position
    # @param other [String] what to call the schema compared with
    # @return [void]
    def field_differences(a, b, path, k, other)
      return if a.node.signature.drop(1) == b.node.signature.drop(1)
      mine = describe(a)
      theirs = describe(b)
      if mine != theirs then conflict(path, mine, theirs, nil, k)
      elsif a.optional != b.optional
        conflict(path, a.optional ? "nullable" : "required", b.optional ? "nullable" : "required", nil, k)
      elsif a.node.field_id != b.node.field_id
        conflict(path, "field_id #{a.node.field_id.inspect}", "field_id #{b.node.field_id.inspect}", nil, k)
      else
        before = @conflicts.size
        case a.kind
        when :struct then differences(a.children, b.children, path, k, other)
        when :list then field_differences(a.element, b.element, path + ["element"], k, other)
        when :map
          field_differences(a.key, b.key, path + ["key"], k, other)
          field_differences(a.value, b.value, path + ["value"], k, other)
        end
        return if @conflicts.size > before
        how = if a.leaf? then "annotated"
        elsif a.kind == :struct then "ordered"
        else "laid out"
        end
        conflict(path, nil, nil, "#{how} another way than in #{other}", k)
      end
    end

    # Where each output column comes from in an input, recording the conflicts when the input
    # does not fit. The input must be the same as the output or narrower: uniting its fields with
    # the output's (Schema#+) must leave the output's as they are. Each output leaf is found in
    # the input through the logical tree, by name, so the element of a pyarrow list ("list.item")
    # or of a legacy 2-level list is still the same column.
    #
    # @param input_schema [Schema] the input's schema
    # @param k [Integer] the input's position
    # @param drop [Boolean] whether fields the output lacks are dropped (+schema: :intersect+)
    #   rather than refused
    # @return [Plan, nil] nil when the input does not fit
    def plan(input_schema, k, drop:)
      names = @schema.fields.map(&:name)
      their_names = input_schema.fields.map(&:name)
      common = names & their_names
      if common.empty?
        conflict([], names.join(", "), their_names.join(", "), "no fields in common with the schema", k)
        return
      end
      before = @conflicts.size
      unless drop
        (their_names - names).each { |name| conflict([name], nil, nil, "only here, the schema lacks it", k) }
      end
      @schema.fields.each do |field|
        next if field.optional || their_names.include?(field.name)
        conflict([field.name], nil, nil, "missing here, and the schema requires it", k)
      end
      fitted = fitted_fields(input_schema, common, k, drop) or return
      @schema.fields.each do |field|
        mine = fitted.field(field.name) or next
        field_differences(field, mine, [field.name], k, "the schema")
      end
      return if @conflicts.size > before
      sources = {}
      filled = names - their_names
      widened = []
      dropped = their_names - names
      @schema.fields.each do |field|
        match_columns(field, input_schema.field(field.name), [field.name], sources, filled, widened, dropped)
      end
      copyable = sources.select { |j, source| same_bytes?(@schema.columns[j], source) }.keys
      Plan.new(sources, copyable, filled, widened, dropped)
    end

    # The input's +common+ fields as the output would hold them: united with the output schema,
    # after dropping the struct members the output lacks when +drop+ is set. Equal to the output's
    # fields exactly when the input fits.
    #
    # @param input_schema [Schema] the input's schema
    # @param common [Array<String>] top-level fields both have
    # @param k [Integer] the input's position
    # @param drop [Boolean] whether struct members the output lacks are dropped
    # @return [Schema, nil] nil when a field has no common type with the output's
    def fitted_fields(input_schema, common, k, drop)
      copies = Schema.from_elements(input_schema.to_elements).root.children.select { |n| common.include?(n.name) }
      theirs = Schema.new(Schema::Node.new(name: "schema", repetition: :required, children: copies))
      mine = Schema.from_elements(@schema.to_elements)
      mine = Schema.new(Schema::Node.new(name: "schema", repetition: :required,
        children: mine.root.children.select { |n| common.include?(n.name) }))
      theirs &= mine if drop
      mine + theirs
    rescue IncompatibleSchema => e
      e.conflicts.each { |c| @conflicts << IncompatibleSchema::Conflict.new(c.path, c.left, c.right, c.reason, k) }
      nil
    end

    # @param mine [Schema::Field] a field of the output schema
    # @param theirs [Schema::Field, nil] the field of the same name in the input, of the same kind
    # @param path [Array<String>] path of the field
    # @param sources [Hash{Integer => Schema::Column}] output column index => input column; added to
    # @param filled [Array<String>] fields the input lacks; added to
    # @param widened [Array<String>] fields the output widens; added to
    # @param dropped [Array<String>] fields of the input the output lacks; added to
    # @return [void]
    def match_columns(mine, theirs, path, sources, filled, widened, dropped)
      return unless theirs
      dotted = path.join(".")
      widened << dotted if mine.optional != theirs.optional || (mine.leaf? && describe(mine) != describe(theirs))
      case mine.kind
      when :leaf then sources[mine.column.index] = theirs.column
      when :struct
        by_name = theirs.children_by_name
        mine.children.each do |child|
          filled << "#{dotted}.#{child.name}" unless by_name.key?(child.name)
          match_columns(child, by_name[child.name], path + [child.name], sources, filled, widened, dropped)
        end
        dropped.concat((by_name.keys - mine.children.map(&:name)).map { |name| "#{dotted}.#{name}" })
      when :list then match_columns(mine.element, theirs.element, path + ["element"], sources, filled, widened, dropped)
      when :map
        match_columns(mine.key, theirs.key, path + ["key"], sources, filled, widened, dropped)
        match_columns(mine.value, theirs.value, path + ["value"], sources, filled, widened, dropped)
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

    # @param field [Schema::Field] any field
    # @return [String] its type as messages name it, see Schema::Merge#describe
    def describe(field) = (@describer ||= Schema::Merge.new(:union)).describe(field)

    # @param path [Array<String>] path of the field, empty for the input as a whole
    # @param left [String, nil] the field as the schema compared with has it
    # @param right [String, nil] the field as the input has it
    # @param reason [String, nil] why they do not fit
    # @param k [Integer] the input's position
    # @return [void]
    def conflict(path, left, right, reason, k)
      @conflicts << IncompatibleSchema::Conflict.new(path.join("."), left, right, reason, k)
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

    # @param schema [Schema, Symbol, nil] the +schema:+ option
    # @return [String] the first line of the message when inputs do not fit the output schema
    def fit_header(schema)
      what = {union: "the union of the inputs", intersect: "the intersection of the inputs"}.fetch(schema, "given as schema:")
      "#{inputs_count("does", "do")} not fit the schema (#{what}):"
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
      message = <<~MESSAGE.chomp
        #{header}

        #{groups.join("\n\n")}
      MESSAGE
      message += "\n\n#{advice}" if advice
      raise IncompatibleSchema.new(@conflicts, message: message)
    end

    # @return [Array<InputReport>]
    def input_reports
      @inputs.map do |input|
        plan = input.plan
        InputReport.new(name: input.name, filled: plan.filled, widened: plan.widened.uniq, dropped: plan.dropped)
      end
    end

    # The +encryption:+ option that encrypts the output like the encrypted inputs: the same
    # algorithm, footer mode, footer key and key metadata, and the same key for each column.
    # Plaintext inputs get that encryption too. An AAD prefix the inputs share is kept; differing
    # ones are left out, unless the inputs make readers supply theirs.
    #
    # @return [EncryptionConfiguration, nil] nil when no input is encrypted
    # @raise [ArgumentError] listing how the encrypted inputs differ, when they do
    # @raise [DecryptionError] when a key the output needs was not given
    def inherited_encryption
      encrypted = @inputs.select { |input| input.reader.decryptor }
      return nil if encrypted.empty?
      settings = encrypted.map { |input| [input, input.reader.decryptor.writer_settings(nil).to_h] }
      problems = []
      %i[footer_key footer_key_metadata plaintext_footer algorithm].each do |setting|
        groups = settings.group_by { |_, h| h[setting] }
        next if groups.size == 1
        what = {footer_key: "footer key", footer_key_metadata: "footer key metadata", plaintext_footer: "footer mode",
                algorithm: "algorithm"}.fetch(setting)
        problems << "#{what} differs: " + groups.map { |value, members|
          shown = (setting == :footer_key) ? "" : " (#{value.inspect})"
          "#{members.map { |input, _| input.name }.join(", ")}#{shown}"
        }.join(" / ")
      end
      columns = inherited_columns(encrypted, problems)
      aads = settings.map { |_, h| h.values_at(:aad_prefix, :store_aad_prefix) }.uniq
      aad_prefix, store = aads.first
      if aads.size > 1
        if aads.any? { |_, stored| !stored }
          problems << "AAD prefixes differ, and readers must supply them: " + settings.map { |input, _| input.name }.join(", ")
        end
        aad_prefix = nil
        store = true
      end
      unless problems.empty?
        raise ArgumentError, <<~MESSAGE.chomp
          The encrypted inputs are encrypted differently, so there is no "encrypted like the inputs":

          #{problems.map { |p| "  #{p}" }.join("\n")}

          Pass encryption: for the output (a Herringbone::Key or an EncryptionConfiguration), or
          encryption: false to write it in plaintext.
        MESSAGE
      end
      base = settings.first.last
      EncryptionConfiguration.new(**base.merge(columns: columns, aad_prefix: aad_prefix, store_aad_prefix: store))
    end

    # The +columns:+ of the inherited encryption: nil when every encrypted input encrypts all its
    # columns with the footer key, else output column path => +:footer+ or its own key
    #
    # @param encrypted [Array<Input>] the encrypted inputs
    # @param problems [Array<String>] how the inputs differ; added to
    # @return [Hash{String => Symbol, Hash}, nil]
    # @raise [DecryptionError] when the key of an encrypted column was not given
    def inherited_columns(encrypted, problems)
      layouts = encrypted.filter_map do |input|
        reader = input.reader
        chunks = reader.row_groups.first&.columns or next
        output_of = input.plan.sources.to_h { |j, source| [source.index, j] }
        layout = {}
        uniform = true
        reader.schema.columns.each do |col|
          j = output_of[col.index] or next
          crypto = chunks[col.index]&.crypto_metadata
          next uniform = false unless crypto
          path = @schema.columns[j].dotted_path
          with_column_key = crypto.encryption_with_column_key
          next layout[path] = :footer unless with_column_key
          uniform = false
          key = reader.decryptor.chunk_key(chunks[col.index], col.dotted_path)
          key or raise DecryptionError, "The output is encrypted like #{input.name}, which needs the key of " \
            "#{col.dotted_path}: pass it in decryption:, or pass encryption: for the output"
          layout[path] = {key: key, key_metadata: with_column_key.key_metadata}
        end
        [input, layout, uniform]
      end
      return nil if layouts.all? { |_, _, uniform| uniform }
      merged = {}
      owner = {}
      key_name = ->(setting) { (setting == :footer) ? "the footer key" : "a key of its own" }
      layouts.each do |input, layout, _|
        layout.each do |path, setting|
          if !merged.key?(path)
            merged[path] = setting
            owner[path] = input.name
          elsif merged[path] != setting
            problems << if key_name.call(merged[path]) == key_name.call(setting)
              "#{path} is encrypted with different keys in #{owner[path]} and #{input.name}"
            else
              "#{path} is encrypted with #{key_name.call(merged[path])} in #{owner[path]}, " \
                "with #{key_name.call(setting)} in #{input.name}"
            end
          end
        end
      end
      merged
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
