# frozen_string_literal: true

require_relative "test_helper"

# Guards the packaged gem: only library code, the executable and docs, and nothing large
class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MAX_FILE_BYTES = 200 * 1024
  MAX_TOTAL_BYTES = 1024 * 1024

  def spec
    @spec ||= Dir.chdir(ROOT) { Gem::Specification.load("herringbone.gemspec") }
  end

  def test_packages_only_code_and_docs
    unexpected = spec.files.reject { |f| f.start_with?("lib/", "bin/") || %w[README.md LICENSE].include?(f) }
    assert_empty unexpected, "files that should not be in the gem"
    assert_includes spec.files, "lib/herringbone.rb"
    assert_includes spec.files, "bin/herringbone"
    refute spec.files.any? { |f| f.end_with?(".parquet", ".bin", ".json", ".log") }
  end

  def test_packaged_files_are_small
    sizes = spec.files.to_h { |f| [f, File.size(File.join(ROOT, f))] }
    big = sizes.select { |_, size| size > MAX_FILE_BYTES }
    assert_empty big, "files over #{MAX_FILE_BYTES} bytes"
    assert_operator sizes.values.sum, :<, MAX_TOTAL_BYTES
  end
end
