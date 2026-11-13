# frozen_string_literal: true

require_relative "test_helper"

# Guards the packaged gem: only library code, the executable, type signatures and docs, and
# nothing large
class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MAX_FILE_BYTES = 200 * 1024
  # The generated signatures cover every method, private ones included, with their docs
  MAX_SIGNATURE_BYTES = 600 * 1024
  MAX_TOTAL_BYTES = 2 * 1024 * 1024

  def spec
    @spec ||= Dir.chdir(ROOT) { Gem::Specification.load("herringbone.gemspec") }
  end

  def test_packages_only_code_and_docs
    unexpected = spec.files.reject { |f| f.start_with?("lib/", "bin/", "sig/", "rbi/") || %w[README.md MANUAL.md CHANGELOG.md LICENSE].include?(f) }
    assert_empty unexpected, "files that should not be in the gem"
    assert_includes spec.files, "lib/herringbone.rb"
    assert_includes spec.files, "bin/herringbone"
    assert_equal %w[rbi/herringbone.rbi sig/herringbone.rbs sig/manifest.yaml], spec.files.grep(%r{\A(sig|rbi)/}).sort
    refute spec.files.any? { |f| f.end_with?(".parquet", ".bin", ".json", ".log") }
  end

  def test_packaged_files_are_small
    sizes = spec.files.to_h { |f| [f, File.size(File.join(ROOT, f))] }
    big = sizes.select { |f, size| size > (f.start_with?("sig/", "rbi/") ? MAX_SIGNATURE_BYTES : MAX_FILE_BYTES) }
    assert_empty big, "files over their size limit"
    assert_operator sizes.values.sum, :<, MAX_TOTAL_BYTES
  end
end
