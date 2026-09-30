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

module Herringbone
  Delta = Encodings::Delta

  module_function

  def open(path, &block) = Reader.open(path, &block)
  def read(path, columns: nil) = Reader.open(path) { |r| r.rows(columns: columns) }

  # Writes an Enumerable of row Hashes. Without a schema, one is inferred from the first rows.
  def write(path, rows, schema: nil, **options)
    schema ||= Schema.infer(rows)
    Writer.open(path, schema, **options) { |w| w.write_rows(rows) }
  end
end
