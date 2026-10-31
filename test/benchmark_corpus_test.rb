# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/suite/corpus"
require "tmpdir"
require "fileutils"

class BenchmarkCorpusTest < Minitest::Test
  CONFIG = BenchmarkSuite::Corpus::DEFAULT.merge("rows" => 40, "runs" => 1, "group_rows" => 10).freeze

  def setup
    @directory = Dir.mktmpdir("herringbone-corpus-test-")
    @corpus = BenchmarkSuite::Corpus.new(File.join(@directory, "corpus"), CONFIG)
    @manifest_path = File.join(@corpus.directory, "manifest.json")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_producer_identity_and_repetition_count_do_not_prevent_reuse
    manifest = @corpus.prepare
    manifest["producer"] = {"herringbone" => "another version", "generator_sha256" => "another source"}
    File.write(@manifest_path, JSON.generate(manifest))
    more_repetitions = BenchmarkSuite::Corpus.new(@corpus.directory, CONFIG.merge("runs" => 2))

    assert_equal manifest, more_repetitions.prepare
  end

  def test_unversioned_manifest_is_rejected_without_overwriting_it
    assert_manifest_rejected do |manifest|
      manifest.delete("manifest_version")
      manifest.delete("recipe_version")
    end
  end

  def test_unknown_manifest_version_is_rejected_without_overwriting_it
    assert_manifest_rejected { |manifest| manifest["manifest_version"] = 99 }
  end

  def test_unknown_recipe_version_is_rejected_without_overwriting_it
    assert_manifest_rejected { |manifest| manifest["recipe_version"] = 99 }
  end

  def test_typed_and_coercible_records_represent_the_same_values
    typed = @corpus.record(1)
    coercible = @corpus.record(1, coercible: true)

    assert_instance_of Integer, typed["int64"]
    assert_instance_of String, coercible["int64"]
    assert_instance_of Time, typed["micros"]
    assert_instance_of String, coercible["micros"]
    assert_operator @corpus.expected(1)["uint64"], :>, (1 << 63)
  end

  def test_extra_output_rows_are_rejected
    path = File.join(@directory, "extra.parquet")
    write_rows(path, 11)

    error = assert_raises(RuntimeError) { @corpus.verify([path], "read", shards: [0]) }

    assert_match(/unexpected extra output rows/, error.message)
  end

  def test_missing_output_rows_are_rejected
    path = File.join(@directory, "short.parquet")
    write_rows(path, 9)

    error = assert_raises(RuntimeError) { @corpus.verify([path], "read", shards: [0]) }

    assert_match(/row count mismatch/, error.message)
  end

  def test_wrong_schema_is_rejected
    path = File.join(@directory, "legacy.parquet")
    write_rows(path, 10, legacy: true)

    error = assert_raises(RuntimeError) { @corpus.verify([path], "read", shards: [0]) }

    assert_match(/schema mismatch/, error.message)
  end

  private

  def write_rows(path, count, legacy: false)
    File.open(path, "wb") do |io|
      Herringbone::Writer.open(io, @corpus.schema(legacy), **@corpus.writer_options) do |writer|
        count.times { |index| writer << @corpus.record(index, legacy: legacy) }
      end
    end
  end

  def assert_manifest_rejected
    manifest = @corpus.prepare
    yield manifest
    contents = JSON.generate(manifest)
    File.write(@manifest_path, contents)

    error = assert_raises(RuntimeError) { @corpus.prepare }

    assert_includes error.message, "generate a corpus in a new directory"
    assert_equal contents, File.read(@manifest_path)
  end
end
