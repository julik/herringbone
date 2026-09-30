# frozen_string_literal: true

require "stringio"
require "pathname"
require_relative "parakiet/version"

# Pure-Ruby reader and writer for Apache Parquet files
module Parakiet
  class Error < StandardError; end
  class FormatError < Error; end
  class DecodeError < FormatError; end
  class EncodeError < Error; end
  class UnsupportedError < Error; end
end

require_relative "parakiet/io_buffer_support"
require_relative "parakiet/codecs/snappy"
require_relative "parakiet/codecs/lz4"
require_relative "parakiet/thrift"
require_relative "parakiet/format"
require_relative "parakiet/encodings/rle"
require_relative "parakiet/encodings/plain"
require_relative "parakiet/encodings/delta"
require_relative "parakiet/compression"
require_relative "parakiet/types"
require_relative "parakiet/schema"
require_relative "parakiet/active_record"
require_relative "parakiet/reader"
require_relative "parakiet/writer"

module Parakiet
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
