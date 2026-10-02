# frozen_string_literal: true

require_relative "lib/herringbone/version"

Gem::Specification.new do |spec|
  spec.name = "herringbone"
  spec.version = Herringbone::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.summary = "Pure-Ruby Apache Parquet reader and writer"
  spec.description = "Reads and writes Apache Parquet files in Ruby, without Thrift or native extensions " \
    "of its own. Snappy and LZ4 are implemented in Ruby and GZIP uses zlib; ZSTD and Brotli are " \
    "available when the zstd-ruby / brotli gems are installed."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["lib/**/*.rb", "bin/*", "README.md", "MANUAL.md", "CHANGELOG.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["herringbone"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bigdecimal"
end
