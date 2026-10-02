# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

# ZSTD and Brotli come from optional gems: check the failure modes when they are missing
class CodecAvailabilityTest < Minitest::Test
  Compression = Herringbone::Compression
  ZSTD_FILE = File.join(FIXTURES_DIR, "generated", "codec_zstd.parquet")
  BROTLI_FILE = File.join(FIXTURES_DIR, "generated", "codec_brotli.parquet")

  A_SCHEMA = Herringbone::Schema.define { int32 :a }

  def open_fixture(path)
    File.open(path, "rb") { |f| yield Herringbone::Reader.new(f) }
  end

  # Codecs of a file's column chunks, as named by Herringbone.codecs
  def file_codecs(bytes)
    meta = Herringbone::Reader.new(StringIO.new(bytes)).file_metadata
    meta.row_groups.flat_map { |rg| rg.columns.map { |c| Compression::NAMES[c.meta_data.codec] } }.uniq
  end

  # Runs the block as if the optional codec gems were not installed
  def without_codec_gems(&block)
    Compression.stub(:loaded_library, nil, &block)
  end

  def test_writer_fails_upfront_for_missing_codec
    without_codec_gems do
      error = assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.new(StringIO.new, A_SCHEMA, compression: :zstd)
      end
      assert_equal "ZSTD", error.codec
      assert_equal "zstd-ruby", error.gem_name
      assert_match(/needs the "zstd-ruby" gem/, error.message)
      assert_match(/Add `gem "zstd-ruby"` to your Gemfile and `require "zstd-ruby"`/, error.message)

      error = assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.new(StringIO.new, A_SCHEMA, compression: :brotli)
      end
      assert_equal "brotli", error.gem_name
    end
  end

  def test_writer_writes_nothing_for_missing_codec
    io = StringIO.new("".b)
    without_codec_gems do
      assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.open(io, A_SCHEMA, compression: :zstd) { |w| w << [1] }
      end
    end
    assert_empty io.string, "the codec is checked before anything is written"
  end

  def test_missing_codec_is_an_unsupported_error
    assert_operator Herringbone::MissingCodecError, :<, Herringbone::UnsupportedError
  end

  def test_pure_ruby_codecs_need_no_gems
    without_codec_gems do
      assert_equal %i[none snappy gzip lz4 lz4_hadoop], Herringbone.codecs
      Herringbone.codecs.each do |codec|
        io = StringIO.new("".b)
        Herringbone::Writer.open(io, A_SCHEMA, compression: codec) { |w| w << [1] }
        assert_equal [{"a" => 1}], Herringbone::Reader.new(StringIO.new(io.string)).read
        assert_equal [codec], file_codecs(io.string)
      end
    end
  end

  def test_reading_names_codec_gem_and_column
    without_codec_gems do
      open_fixture(ZSTD_FILE) do |reader|
        error = assert_raises(Herringbone::MissingCodecError) { reader.read }
        assert_match(/needs the "zstd-ruby" gem/, error.message)
        assert_match(/\(column \w+\)\z/, error.message)
        assert_equal "zstd-ruby", error.gem_name
      end
      open_fixture(BROTLI_FILE) do |reader|
        assert_equal "brotli", assert_raises(Herringbone::MissingCodecError) { reader.read }.gem_name
      end
    end
  end

  def test_metadata_is_readable_without_the_codec
    without_codec_gems do
      open_fixture(ZSTD_FILE) do |reader|
        assert_operator reader.num_rows, :>, 0
        refute_empty reader.schema.columns
      end
    end
  end

  def test_lzo_is_reported_as_unsupported
    error = assert_raises(Herringbone::UnsupportedError) do
      Herringbone::Writer.new(StringIO.new, A_SCHEMA, compression: :lzo)
    end
    assert_equal "LZO compression is only supported for reading", error.message
    refute_includes Herringbone.codecs, :lzo
    assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, A_SCHEMA, compression: :lz4_raw) }
  end

  def test_default_codec_is_snappy
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, A_SCHEMA) { |w| w << [1] }
    assert_equal [:snappy], file_codecs(io.string)
  end

  def test_installed_codec_gems_are_used
    %i[zstd brotli].each do |codec|
      skip "#{codec} gem not installed" unless Herringbone.codecs.include?(codec)
      io = StringIO.new("".b)
      Herringbone::Writer.open(io, A_SCHEMA, compression: codec) { |w| w << [1] }
      assert_equal [codec], file_codecs(io.string)
    end
  end
end
