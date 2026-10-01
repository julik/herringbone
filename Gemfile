# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.0"
gem "rake"

group :test do
  # Optional: only used by test/active_record_test.rb, which skips without them
  gem "activerecord", ">= 7.0", "< 9"
  gem "sqlite3", ">= 1.6"
end

# Optional compression libraries. Herringbone requires them on first use of ZSTD / Brotli.
# CI also runs the suite with BUNDLE_WITHOUT=codecs to check the behaviour without them.
group :codecs do
  gem "zstd-ruby"
  gem "brotli"
end

# Optional native XXH64 for bloom filters. Herringbone uses it when it can be required and falls
# back to pure Ruby otherwise. CI also runs the suite with BUNDLE_WITHOUT=codecs:speedups.
group :speedups do
  gem "xxhash"
end

# Optional: Herringbone requires "numo/narray" on first use of read(as: :numo) / each_batch(as: :numo).
# numo-narray-alt is the maintained fork that Rover and ankane's ML gems depend on (plain
# numo-narray works too). CI also runs the suite with BUNDLE_WITHOUT=codecs:speedups:numo.
group :numo do
  gem "numo-narray-alt"
end
