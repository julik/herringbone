# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "herringbone"
# Herringbone uses the optional gems only once they are loaded, as an application requires them
%w[zstd-ruby brotli xxhash snappy numo/narray].each do |lib|
  require lib
rescue LoadError
end
require "minitest/autorun"

FIXTURES_DIR = File.expand_path("fixtures", __dir__)
