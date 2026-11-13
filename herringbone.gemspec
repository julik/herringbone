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
  spec.homepage = "https://github.com/julik/herringbone"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}/blob/main/MANUAL.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["lib/**/*.rb", "bin/*", "sig/*", "rbi/*", "README.md", "MANUAL.md", "CHANGELOG.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["herringbone"]
  spec.require_paths = ["lib"]

  spec.add_dependency "bigdecimal"
end
