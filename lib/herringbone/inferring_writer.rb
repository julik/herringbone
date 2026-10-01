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
  # Used by Herringbone.write and SimpleWriter.
  #
  # @api private
  class InferringWriter
    # @param io [IO, #write] destination, passed to Writer.new
    # @param fix [String] how a caller declares a column, for SchemaMismatch messages; +%s+ is
    #   replaced by a declaration such as +string :age+
    # @param options [Hash{Symbol => Object}] Writer options
    # @option options [Symbol] :compression (:snappy) codec, checked before any row is read
    #   (the other Writer options are passed on as well)
    # @yield [sample] builds the schema once the sample is complete (or at #close)
    # @yieldparam sample [Array] the rows held back, at most Schema::INFER_SAMPLE
    # @yieldreturn [Schema]
    # @raise [MissingCodecError] when the codec's optional gem is not loaded
    def initialize(io, fix:, **options, &schema_for)
      # Fail before reading any rows if the codec's library is missing
      Compression.ensure_available!(Compression.codec_id(options.fetch(:compression, :snappy)))
      @io = io
      @fix = fix
      @options = options
      @schema_for = schema_for
      @sample = []
      @sample_size = nil
      @writer = nil
      @mismatch = nil
    end

    # @param row [Object] row to write, in any form the Writer accepts
    # @return [self]
    # @raise [SchemaMismatch] when the row does not fit the inferred schema
    # @raise [Error] after an earlier SchemaMismatch
    def <<(row)
      check_usable!
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

    private

    # Builds the schema from the held-back rows, opens the Writer and writes them
    #
    # @return [void]
    # @raise [SchemaMismatch] when a held-back row does not fit
    def start
      @sample_size = @sample.size
      @writer = Writer.new(@io, @schema_for.call(@sample), **@options)
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
      when :timestamp, :time then "#{kind} (#{details[0]})"
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
