# frozen_string_literal: true

module Herringbone
  # Writes rows whose schema is inferred from the rows themselves, reading them only once: the
  # first Schema::INFER_SAMPLE rows are held back, the schema is built from them, and then they and
  # every later row go straight to a Writer. Memory is bounded by the sample, however many rows
  # follow it. Nothing is written to the IO before the schema is known, so a source that can only
  # be iterated once (a cursor, a queue, a lazy Enumerator over an IO) loses no rows.
  #
  # A row that does not fit the inferred schema raises SchemaMismatch and stops the writer: the
  # file is left unfinished (no footer) rather than written with rows missing.
  #
  # With +headers:+, rows are Arrays of values in header order (or Hashes keyed by header), and
  # only the held-back rows are turned into Hashes for inference.
  #
  # Writer.open returns one when it is given no schema, and Herringbone.write uses one when it has
  # to infer the schema.
  class InferringWriter
    # @api private
    # @param io [IO, #write] destination, passed to Writer.new
    # @param fix [String] how a caller declares a column, for SchemaMismatch messages; +%s+ is
    #   replaced by a declaration such as +string :age+
    # @param headers [Array<String, Symbol>, nil] column names, in the order row Arrays list their
    #   values; nil for rows the Writer takes as they are
    # @param options [Hash{Symbol => Object}] Writer options
    # @option options [Symbol] :compression (:snappy) codec, checked before any row is read
    #   (the other Writer options are passed on as well)
    # @yield [sample] builds the schema once the sample is complete (or at #close)
    # @yieldparam sample [Array] the rows held back, at most Schema::INFER_SAMPLE
    # @yieldreturn [Schema]
    # @raise [MissingCodecError] when the codec's optional gem is not loaded
    # @raise [ArgumentError] for a compression level the codec does not take, invalid encryption
    #   settings, or +headers+ that are empty or name a column twice
    def initialize(io, fix:, headers: nil, **options, &schema_for)
      # Fail before reading any rows if the codec's library is missing or the level is wrong
      codec = Compression.codec_id(options.fetch(:compression, :snappy))
      Compression.ensure_available!(codec)
      Compression.check_level!(codec, options[:compression_level])
      options = options.merge(encryption: EncryptionConfiguration.from(options[:encryption])) if options[:encryption]
      @headers = headers && check_headers(headers)
      @io = io
      @fix = fix
      @options = options
      @schema_for = schema_for
      @sample = []
      @sample_size = nil
      @writer = nil
      @mismatch = nil
    end

    # @param row [Object] row to write, in any form the Writer accepts; with +headers+, an Array or
    #   a Hash
    # @return [self]
    # @raise [ArgumentError] when the row does not match the headers
    # @raise [SchemaMismatch] when the row does not fit the inferred schema
    # @raise [Error] after an earlier SchemaMismatch
    def <<(row)
      check_usable!
      row = values_of(row) if @headers
      if @writer
        write(row)
      else
        @sample << row
        start if @sample.size >= Schema::INFER_SAMPLE
      end
      self
    end

    # @return [Integer] rows accepted so far, including the ones held back
    def rows_written = @writer ? @writer.rows_written : @sample.size

    # Writes the held-back rows if the sample never filled up, then finishes the file
    #
    # @return [void]
    # @raise [SchemaMismatch] when a held-back row does not fit the inferred schema
    # @raise [Error] after an earlier SchemaMismatch
    def close
      check_usable!
      start unless @writer
      @writer.close
    end

    # Stops without finishing the file; when the schema was never built nothing was written at all
    #
    # @return [void]
    def abort
      @writer&.abort
    end

    # Short summary for the console, without the held-back rows
    #
    # @return [String] the number of rows held back, or the Writer's summary once it is open
    def inspect
      "#<#{self.class.name} #{@writer ? "writer=#{@writer.inspect}" : "held_back=#{@sample.size}"}>"
    end

    private

    # Builds the schema from the held-back rows, opens the Writer and writes them
    #
    # @return [void]
    # @raise [SchemaMismatch] when a held-back row does not fit
    # @raise [ArgumentError] when a column declared in the block is not among the headers
    def start
      @sample_size = @sample.size
      @writer = Writer.new(@io, infer_schema, **@options)
      sample, @sample = @sample, nil
      sample.each { |row| write(row) }
    end

    # @param row [Object] row for the Writer
    # @return [void]
    # @raise [SchemaMismatch] when the row does not fit; the Writer is aborted
    def write(row)
      @writer << row
    rescue EncodeError => e
      @writer.abort
      @mismatch = SchemaMismatch.new(explain(e), row: e.row, column: e.column, value: e.value)
      raise @mismatch
    end

    # @return [Schema] built by the block from the held-back rows, as Hashes when there are headers
    # @raise [ArgumentError] when a column declared in the block is not among the headers
    def infer_schema
      return @schema_for.call(@sample) unless @headers
      # Without rows, every column is nil and so becomes a string
      rows = @sample.empty? ? [@headers.to_h { |name| [name, nil] }] : @sample.map { |values| @headers.zip(values).to_h }
      schema = @schema_for.call(rows)
      extra = schema.fields.map(&:name) - @headers
      raise ArgumentError, "Declared columns not among the headers (#{@headers.join(", ")}): #{extra.join(", ")}" unless extra.empty?
      schema
    end

    # @param headers [Array<String, Symbol>] column names given as +headers:+
    # @return [Array<String>] the names as frozen Strings
    # @raise [ArgumentError] when there are none or a name is given twice
    def check_headers(headers)
      names = Array(headers).map(&:to_s)
      raise ArgumentError, "headers: needs at least one column name" if names.empty?
      duplicates = names.tally.select { |_, n| n > 1 }.keys
      raise ArgumentError, "headers: names a column more than once: #{duplicates.join(", ")}" unless duplicates.empty?
      names.freeze
    end

    # @param row [Array, Hash] row given to #<<
    # @return [Array] its values in header order
    # @raise [ArgumentError] when it does not match the headers
    def values_of(row)
      case row
      when Array
        unless row.size == @headers.size
          raise ArgumentError, "Expected #{@headers.size} values (#{@headers.join(", ")}), got #{row.size}"
        end
        row
      when Hash
        unknown = row.keys.map(&:to_s) - @headers
        raise ArgumentError, "Not among the headers (#{@headers.join(", ")}): #{unknown.join(", ")}" unless unknown.empty?
        @headers.map { |name| row.fetch(name) { row[name.to_sym] } }
      else
        raise ArgumentError, "With headers:, rows must be Arrays or Hashes, got #{row.class}"
      end
    end

    # @return [void]
    # @raise [Error] after a SchemaMismatch
    def check_usable!
      return unless @mismatch
      raise Error, "This writer stopped at a schema mismatch and cannot continue " \
        "(the file is unfinished):\n#{@mismatch.message}"
    end

    # A multi-line explanation of an EncodeError against the inferred schema
    #
    # @param error [EncodeError] error raised by the Writer
    # @return [String]
    def explain(error)
      column = error.column && @writer.schema.column(error.column)
      column ||= error.column && @writer.schema.columns.find { |c| c.dotted_path.start_with?("#{error.column}.") }
      top = error.column&.split(".")&.first
      lines = ["Row #{error.row} does not fit the schema inferred from the first #{@sample_size} rows."]
      lines << "  column:   #{error.column}" if error.column
      lines << "  inferred: #{describe(column)}" if column
      lines << "  got:      #{error.value.inspect[0, 200]} (#{error.value.class})" unless error.value.nil?
      lines << "  error:    #{error.message.sub(/\ARow \d+: /, "")}"
      lines << ""
      lines << "Column types are decided from the first #{Schema::INFER_SAMPLE} rows (or all of them, when there are"
      lines << "fewer), so a later value of a different type cannot be written to the same column."
      if top
        lines << "Declare the column with a type that holds every value, for example:"
        lines << "  #{format(@fix, declaration_for(top, error.value))}"
      end
      lines << "or pass a complete schema. The file was left unfinished (no footer)."
      lines.join("\n")
    end

    # @param column [Schema::Column] leaf column
    # @return [String] its type as the Builder DSL names it, e.g. "int64" or "timestamp (micros)"
    def describe(column)
      kind, *details = Types.logical_of(column.node)
      type = case kind
      when nil then Format::Type::NAMES[column.type].downcase
      when :integer then "#{details[1] ? "int" : "uint"}#{details[0]}"
      when :timestamp, :time then "#{"local_" unless details[1]}#{kind} (#{details[0]})"
      when :decimal then "decimal(#{details[1]}, #{details[0]})"
      else kind.to_s
      end
      (column.path.size > 1) ? "#{type} (at #{column.dotted_path})" : type
    end

    # A Builder DSL declaration whose type can hold +value+, to suggest in the explanation
    #
    # @param name [String] top-level field name
    # @param value [Object] the value that did not fit
    # @return [String] e.g. "string :age"
    def declaration_for(name, value)
      type = case value
      when Float, BigDecimal, Rational then "double"
      when Time, DateTime then "timestamp"
      when Hash, Array then "json"
      else "string"
      end
      "#{type} :#{name}"
    end
  end
end
