# frozen_string_literal: true

require "stringio"
require "pathname"
require_relative "herringbone/version"

# Pure-Ruby reader and writer for Apache Parquet files
module Herringbone
  # Base class of every error Herringbone raises on purpose
  class Error < StandardError; end
  # The file is not valid Parquet (bad metadata, corrupt pages...)
  class FormatError < Error; end

  # A value cannot be written to its column
  class EncodeError < Error
    # @return [Integer, nil] index of the row being written (0 for the first), when known
    attr_reader :row
    # @return [String, nil] dotted path of the column the value was meant for, when known
    attr_reader :column
    # @return [Object] the value that could not be written (nil when it was a missing required value)
    attr_reader :value

    # @param message [String, nil] the error message
    # @param row [Integer, nil] index of the row being written
    # @param column [String, nil] dotted path of the column
    # @param value [Object] the value that could not be written
    def initialize(message = nil, row: nil, column: nil, value: nil)
      super(message)
      @row = row
      @column = column
      @value = value
    end
  end

  # A row does not fit a schema that was inferred from earlier rows (Herringbone.write without
  # +schema:+, SimpleWriter). The message says what was inferred, from how many rows, and how to
  # declare the column instead.
  class SchemaMismatch < EncodeError; end

  # The file (or the writer configuration) uses a Parquet feature Herringbone does not implement,
  # such as encryption or a codec whose library is unavailable
  class UnsupportedError < Error; end
end

require_relative "herringbone/io_buffer_support"
require_relative "herringbone/codecs/snappy"
require_relative "herringbone/codecs/lz4"
require_relative "herringbone/codecs/lzo"
require_relative "herringbone/thrift"
require_relative "herringbone/format"
require_relative "herringbone/encodings/rle"
require_relative "herringbone/encodings/plain"
require_relative "herringbone/encodings/delta"
require_relative "herringbone/compression"
require_relative "herringbone/types"
require_relative "herringbone/schema"
require_relative "herringbone/active_record"
require_relative "herringbone/reader"
require_relative "herringbone/byte_values"
require_relative "herringbone/writer"
require_relative "herringbone/inferring_writer"
require_relative "herringbone/simple_writer"
require_relative "herringbone/xxhash"
require_relative "herringbone/bloom_filter"
require_relative "herringbone/inspector"
require_relative "herringbone/visualizer"
require_relative "herringbone/redaction"

module Herringbone
  module_function

  # Writes +records+ to +io+ (any IO responding to #write; Herringbone never opens files by path)
  # and returns the number of rows written. +records+ is an Enumerable of rows, or an ActiveRecord
  # model or relation, which is read with find_each. Without +schema+, the schema comes from the
  # model's columns (Schema.from_active_record) or is inferred from the first rows (Schema.infer);
  # fields declared in the block replace inferred ones. +records+ is iterated once, so a source
  # that can only be read once (a cursor, a lazy Enumerator over an IO) works too. Other options go
  # to Writer.
  #
  #   File.open("orders.parquet", "wb") { |f| Herringbone.write(f, Order.where(created_at: 1.year.ago..)) }
  #   Herringbone.write(io, events.lazy.map(&:to_h)) { |s| s.json :payload }
  #
  # @param io [IO, #write] destination; written sequentially, never closed
  # @param records [Enumerable<Hash, Array, Object>, Class, #find_each] rows (Hashes, Arrays in schema
  #   order, or objects responding to #attributes or #to_h), or an ActiveRecord model or relation
  # @param schema [Schema, nil] schema to write with; derived from +records+ when nil
  # @param options [Hash{Symbol => Object}] passed to Writer.new
  # @option options [Symbol] :compression (:snappy) codec, see Herringbone.codecs
  # @option options [Integer] :row_group_bytes (16MB) approximate buffered size that triggers a row group
  # @option options [Integer, nil] :row_group_rows (nil) also flush a row group after this many rows
  # @option options [Integer] :page_bytes (1MB) approximate uncompressed data page size
  # @option options [Integer] :page_rows (20_000) maximum rows per data page
  # @option options [Integer] :data_page_version (1) 1 or 2
  # @option options [Boolean, Array<String>] :dictionary (true) dictionary-encode all eligible columns,
  #   none, or only the listed dotted column paths
  # @option options [Hash{String => Symbol}] :encodings ({}) dotted column path => value encoding
  #   for non-dictionary pages
  # @option options [Hash{String => String}] :metadata ({}) key/value metadata for the footer
  # @option options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
  #   columns to write split block bloom filters for, see Writer
  # @yield [s] optional, declares fields that replace inferred ones (see Schema.infer); ignored when
  #   the schema is not inferred
  # @yieldparam s [Schema::Builder] the builder to declare fields on
  # @yieldreturn [void]
  # @return [Integer] number of rows written
  # @raise [ArgumentError] when the schema has to be inferred and +records+ is empty or holds Array
  #   rows, an option is invalid, or the block takes no parameter
  # @raise [EncodeError] when a row does not fit the schema
  # @raise [SchemaMismatch] when a row does not fit the inferred schema; the file is left unfinished
  def write(io, records, schema: nil, **options, &overrides)
    Schema::Builder.check_block!(overrides, "Herringbone.write(io, rows) { |s| s.json :payload }")
    model = if records.respond_to?(:klass) then records.klass
    elsif records.respond_to?(:columns) && records.respond_to?(:find_each) then records
    end
    schema ||= Schema.from_active_record(model) if model
    writer = if schema
      Writer.new(io, schema, **options)
    else
      fix = "Herringbone.write(io, rows) { |s| s.%s }"
      InferringWriter.new(io, fix: fix, **options) { |sample| Schema.infer(sample, &overrides) }
    end
    begin
      if records.respond_to?(:find_each)
        records.find_each { |record| writer << record }
      else
        records.each { |record| writer << record }
      end
    rescue Exception # rubocop:disable Lint/RescueException -- also abort on Interrupt
      writer.abort
      raise
    end
    writer.close
    writer.rows_written
  end

  # Rewrites +input+ into +output+ with rows removed or values replaced, building the Redaction from
  # the block (or taking +redaction+). A shortcut for Redaction#apply.
  #
  #   Herringbone.redact(input, output) do |r|
  #     r.where(user_id: 42).delete
  #     r.replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", KEY, email) }
  #   end
  #
  # @param input [IO, StringIO] the Parquet file, read with #seek and #read; not closed
  # @param output [IO, #write] destination, written sequentially; not closed
  # @param redaction [Redaction, nil] the redaction to apply, instead of a block
  # @param writer_options [Hash{Symbol => Object}] Writer options for re-encoded column chunks, and
  #   +metadata:+ to replace the footer key/value metadata, see Redaction#apply
  # @option writer_options [Symbol] :compression (codec of each source chunk) codec for re-encoded chunks
  # @option writer_options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
  #   columns whose re-encoded chunks get a bloom filter, besides those whose source chunk had one
  # @option writer_options [Hash{String => String}] :metadata (the input's) footer key/value metadata
  # @option writer_options [Integer] :page_bytes (1MB) approximate uncompressed data page size
  # @option writer_options [Integer] :page_rows (20_000) maximum rows per data page
  # @option writer_options [Integer] :data_page_version (1) 1 or 2
  # @option writer_options [Boolean, Array<String>] :dictionary (true) see Writer
  # @option writer_options [Hash{String => Symbol}] :encodings ({}) see Writer
  # @yield [r] declares the statements on a new Redaction (see Redaction.new)
  # @yieldparam r [Redaction] the redaction being built
  # @yieldreturn [void]
  # @return [Redaction::Report] what was done
  # @raise [ArgumentError] when given both or neither of +redaction+ and a block, a block that takes
  #   no parameter, or when the redaction does not fit the file's schema
  # @raise [EncodeError] when a replacement value cannot be written to its column
  def redact(input, output, redaction = nil, **writer_options, &block)
    raise ArgumentError, "Herringbone.redact takes a Redaction or a block, not both" if redaction && block
    raise ArgumentError, "Herringbone.redact needs a Redaction or a block" unless redaction || block
    if block&.arity&.zero?
      raise ArgumentError, "The block receives the redaction: Herringbone.redact(input, output) { |r| r.where(user_id: 42).delete }"
    end
    (redaction || Redaction.new(&block)).apply(input, output, **writer_options)
  end

  # Compression codecs this process can read and write, e.g. [:none, :snappy, :gzip, :lz4, :lz4_hadoop, :zstd].
  # :zstd and :brotli are listed when the zstd-ruby / brotli gems are loaded.
  #
  # @return [Array<Symbol>] codec names accepted by the writer's +compression:+ option
  def codecs
    Compression::NAMES.values.select do |name|
      Compression.ensure_available!(name)
      true
    rescue UnsupportedError
      false
    end
  end
end
