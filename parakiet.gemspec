# frozen_string_literal: true

require_relative "lib/parakiet/version"

Gem::Specification.new do |spec|
  spec.name = "parakiet"
  spec.version = Parakiet::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.summary = "Pure-Ruby Apache Parquet reader and writer"
  spec.description = "Reads and writes Apache Parquet files without native extensions or Thrift. " \
    "Snappy and LZ4 are implemented in Ruby; ZSTD and Brotli are used when their gems are present."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["lib/**/*.rb", "bin/*", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["parakiet"]
  spec.require_paths = ["lib"]
end
