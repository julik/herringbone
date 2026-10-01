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
  class EncodeError < Error; end
  # The file (or the writer configuration) uses a Parquet feature Herringbone does not implement,
  # such as encryption or a codec whose library is unavailable
  class UnsupportedError < Error; end
end

require_relative "herringbone/io_buffer_support"
require_relative "herringbone/codecs/snappy"
require_relative "herringbone/codecs/lz4"
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
require_relative "herringbone/xxhash"
require_relative "herringbone/bloom_filter"
require_relative "herringbone/inspector"
require_relative "herringbone/visualizer"

module Herringbone
  module_function

  # Writes +records+ to +io+ (any IO responding to #write; Herringbone never opens files by path)
  # and returns the number of rows written. +records+ is an Enumerable of rows, or an ActiveRecord
  # model or relation, which is read with find_each. Without +schema+, the schema comes from the
  # model's columns (Schema.from_active_record) or is inferred from the first rows (Schema.infer).
  # Other options go to Writer.
  #
  #   File.open("orders.parquet", "wb") { |f| Herringbone.write(f, Order.where(created_at: 1.year.ago..)) }
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
  # @return [Integer] number of rows written
  # @raise [ArgumentError] when the schema has to be inferred and +records+ is empty, or an option is invalid
  # @raise [EncodeError] when a row does not fit the schema
  def write(io, records, schema: nil, **options)
    model = if records.respond_to?(:klass) then records.klass
    elsif records.respond_to?(:columns) && records.respond_to?(:find_each) then records
    end
    schema ||= model ? Schema.from_active_record(model) : Schema.infer(records)
    Writer.open(io, schema, **options) do |writer|
      if records.respond_to?(:find_each)
        records.find_each { |record| writer << record }
      else
        records.each { |record| writer << record }
      end
      writer.rows_written
    end
  end

  # Compression codecs this process can read and write, e.g. [:none, :snappy, :gzip, :lz4, :lz4_hadoop, :zstd].
  # :zstd and :brotli are listed when the zstd-ruby / brotli gems can be loaded.
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
