# frozen_string_literal: true

require "stringio"
require "pathname"
require_relative "herringbone/version"

# Pure-Ruby reader and writer for Apache Parquet files
module Herringbone
  class Error < StandardError; end
  class FormatError < Error; end
  class DecodeError < FormatError; end
  class EncodeError < Error; end
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
  Delta = Encodings::Delta

  module_function

  # All of these take IOs, never paths: Herringbone does not open files itself.
  #   File.open("data.parquet", "rb") { |f| Herringbone.read(f) }

  def open(io, **options, &block) = Reader.open(io, **options, &block)

  # Rows of a file as an Array of Hashes. Options: keys: (:string, :symbol), time_zone: (see Reader)
  # With as: :columns, a Hash of column name => Array of values instead (faster for wide files).
  def read(io, columns: nil, as: :rows, **options)
    raise ArgumentError, "as: must be :rows or :columns, got #{as.inspect}" unless as == :rows || as == :columns
    Reader.open(io, **options) { |r| as == :columns ? r.read_columns(columns: columns) : r.rows(columns: columns) }
  end

  # Writes an Enumerable of rows to +io+. Without a schema, one is inferred from the first rows.
  def write(io, rows, schema: nil, **options)
    schema ||= Schema.infer(rows)
    Writer.open(io, schema, **options) { |w| w.write_rows(rows) }
  end
end
