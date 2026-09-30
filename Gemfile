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
