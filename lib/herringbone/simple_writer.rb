# frozen_string_literal: true

module Herringbone
  # Writes Parquet the way the CSV gem writes CSV: name the columns, then append rows as Arrays.
  # The column types are inferred from the first Schema::INFER_SAMPLE rows (see Schema.infer), so
  # no schema has to be declared.
  #
  #   File.open("people.parquet", "wb") do |file|
  #     Herringbone::SimpleWriter.open(file) do |sw|
  #       sw.headers!(:id, :name, :age)
  #       sw << [123, "John", 12]
  #       sw << { id: 124, name: "Jane" } # Hashes work too; missing columns are nulls
  #     end
  #   end
  #
  # Every column is nullable. A column that is nil in every sampled row becomes a string, and a file
  # with headers but no rows has only string columns. Only the sample is held in memory; later rows
  # are written as they come. A row that does not fit the inferred types raises SchemaMismatch,
  # explaining what was inferred and how to declare the column, and the writer stops there (the
  # file is left without a footer). Unlike CSV, the headers are mandatory: a Parquet file always
  # has named columns.
  #
  # Columns declared in a block (Schema::Builder DSL) replace inferred ones, e.g. for a column that
  # holds both numbers and text:
  #
  #   Herringbone::SimpleWriter.new(io) { |s| s.string :code }
  class SimpleWriter
    # Opens a writer, yields it and closes it, finishing the file. If the block raises, the file is
    # left unfinished (no footer), as with Writer.open. To declare columns, use #initialize and #close.
    #
    # @param io [IO, #write] destination; written sequentially, never closed
    # @param options [Hash{Symbol => Object}] Writer options (compression:, row_group_bytes:...)
    # @option options [Symbol] :compression (:snappy) codec, see Herringbone.codecs
    # @option options [Integer] :row_group_bytes (16MB) approximate buffered size that triggers a row group
    # @option options [Integer, nil] :row_group_rows (nil) also flush a row group after this many rows
    #   (other Writer options are passed on as well)
    # @yield [writer] the open writer
    # @yieldparam writer [SimpleWriter]
    # @yieldreturn [Object] returned by open
    # @return [SimpleWriter, Object] the writer without a block, the block's value with one
    def self.open(io, **options)
      writer = new(io, **options)
      return writer unless block_given?
      begin
        result = yield writer
      rescue Exception # rubocop:disable Lint/RescueException -- also abort on Interrupt
        writer.abort
        raise
      end
      writer.close
      result
    end

    # @return [Array<String>, nil] the column names, nil until #headers! is called
    attr_reader :headers

    # @param io [IO, #write] destination; nothing is written to it until the column types are known
    # @param options [Hash{Symbol => Object}] Writer options (compression:, row_group_bytes:...)
    # @option options [Symbol] :compression (:snappy) codec, see Herringbone.codecs
    # @option options [Integer] :row_group_bytes (16MB) approximate buffered size that triggers a row group
    # @option options [Integer, nil] :row_group_rows (nil) also flush a row group after this many rows
    #   (other Writer options are passed on as well)
    # @yield [s] optional, declares columns (named in #headers!) that replace inferred ones
    # @yieldparam s [Schema::Builder] the builder to declare columns on
    # @yieldreturn [void]
    # @raise [MissingCodecError] when the codec's optional gem is not loaded
    # @raise [ArgumentError] when the block takes no parameter
    def initialize(io, **options, &overrides)
      Schema::Builder.check_block!(overrides, "Herringbone::SimpleWriter.new(io) { |s| s.string :code }")
      @headers = nil
      @overrides = overrides
      fix = "Herringbone::SimpleWriter.new(io) { |s| s.%s }"
      @writer = InferringWriter.new(io, fix: fix, **options) { |sample| schema_for(sample) }
    end

    # Names the columns, in the order row Arrays list their values. Must be called once, before
    # the first row.
    #
    # @param names [Array<String, Symbol>] column names
    # @return [self]
    # @raise [ArgumentError] when called twice, with no names, or with a name given twice
    def headers!(*names)
      raise ArgumentError, "headers! was already called" if @headers
      names = names.flatten.map(&:to_s)
      raise ArgumentError, "headers! needs at least one column name" if names.empty?
      duplicates = names.tally.select { |_, n| n > 1 }.keys
      raise ArgumentError, "Duplicate column names: #{duplicates.join(", ")}" unless duplicates.empty?
      @headers = names.freeze
      self
    end

    # Appends a row: an Array with one value per header, in header order, or a Hash keyed by
    # header (String or Symbol keys; missing columns are nulls).
    #
    # @param row [Array, Hash]
    # @return [self]
    # @raise [ArgumentError] when #headers! was not called, an Array has the wrong length or a Hash
    #   has keys that are not headers
    # @raise [SchemaMismatch] when a value does not fit its column's inferred type
    def <<(row)
      raise ArgumentError, "Call headers! with the column names before writing rows" unless @headers
      @writer << values_of(row)
      self
    end

    # @return [Integer] rows written so far, including those held back to infer the column types
    def rows_written = @writer.rows_written

    # Writes any rows still held back and finishes the file. The IO is not closed.
    #
    # @return [void]
    # @raise [ArgumentError] when #headers! was never called
    def close
      raise ArgumentError, "Call headers! with the column names before closing" unless @headers
      @writer.close
    end

    # Stops without finishing the file. What was already written stays in the IO.
    #
    # @return [void]
    def abort = @writer.abort

    private

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
        raise ArgumentError, "Rows must be Arrays or Hashes, got #{row.class}"
      end
    end

    # @param sample [Array<Array>] held-back rows, values in header order
    # @return [Schema] inferred from the sample; string columns when it is empty
    # @raise [ArgumentError] when a column cannot be inferred or a declared column is not a header
    def schema_for(sample)
      rows = sample.empty? ? [@headers.to_h { |name| [name, nil] }] : sample.map { |values| @headers.zip(values).to_h }
      schema = Schema.infer(rows, &@overrides)
      extra = schema.fields.map(&:name) - @headers
      raise ArgumentError, "Declared columns not among the headers: #{extra.join(", ")}" unless extra.empty?
      schema
    end
  end
end
