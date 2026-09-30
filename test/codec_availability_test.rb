# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"

# ZSTD and Brotli come from optional gems: check the failure modes when they are missing
class CodecAvailabilityTest < Minitest::Test
  Compression = Herringbone::Compression
  ZSTD_FILE = File.join(FIXTURES_DIR, "generated", "codec_zstd.parquet")
  BROTLI_FILE = File.join(FIXTURES_DIR, "generated", "codec_brotli.parquet")

  def open_fixture(path, &block)
    File.open(path, "rb") { |f| Herringbone::Reader.open(f, &block) }
  end

  # Runs the block as if the optional codec gems were not installed
  def without_codec_gems(&block)
    Compression.instance_variable_set(:@libraries, {})
    missing = ->(path) { raise LoadError, "cannot load such file -- #{path}" }
    Compression.stub(:require_library, missing, &block)
  ensure
    Compression.instance_variable_set(:@libraries, {})
  end

  def test_writer_fails_upfront_for_missing_codec
    without_codec_gems do
      error = assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.new(StringIO.new, { a: :int32 }, compression: :zstd)
      end
      assert_equal "ZSTD", error.codec
      assert_equal "zstd-ruby", error.gem_name
      assert_match(/needs the "zstd-ruby" gem/, error.message)
      assert_match(/cannot load such file -- zstd-ruby/, error.message)
      assert_match(/Add `gem "zstd-ruby"` to your Gemfile/, error.message)

      error = assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.new(StringIO.new, { a: :int32 }, compression: :brotli)
      end
      assert_equal "brotli", error.gem_name
    end
  end

  def test_writer_writes_nothing_for_missing_codec
    io = StringIO.new("".b)
    without_codec_gems do
      assert_raises(Herringbone::MissingCodecError) do
        Herringbone::Writer.open(io, { a: :int32 }, compression: :zstd) { |w| w << [1] }
      end
    end
    assert_empty io.string, "the codec is checked before anything is written"
  end

  def test_missing_codec_is_an_unsupported_error
    assert_operator Herringbone::MissingCodecError, :<, Herringbone::UnsupportedError
  end

  def test_pure_ruby_codecs_need_no_gems
    without_codec_gems do
      %i[none snappy gzip lz4 lz4_raw lz4_hadoop].each do |codec|
        assert Compression.available?(codec), codec.to_s
        io = StringIO.new("".b)
        Herringbone::Writer.open(io, { a: :int32 }, compression: codec) { |w| w << [1] }
        assert_equal [{ "a" => 1 }], Herringbone::Reader.new(StringIO.new(io.string)).rows
      end
      refute Compression.available?(:zstd)
      refute Compression.available?(:brotli)
    end
  end

  def test_reading_names_codec_gem_and_column
    without_codec_gems do
      open_fixture(ZSTD_FILE) do |reader|
        assert_equal [:zstd], reader.codecs
        assert_equal [:zstd], reader.missing_codecs
        assert_raises(Herringbone::MissingCodecError) { reader.ensure_codecs_available! }
        error = assert_raises(Herringbone::MissingCodecError) { reader.rows }
        assert_match(/needs the "zstd-ruby" gem/, error.message)
        assert_match(/\(column \w+\)\z/, error.message)
        assert_equal "zstd-ruby", error.gem_name
      end
      open_fixture(BROTLI_FILE) do |reader|
        assert_equal [:brotli], reader.missing_codecs
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
      Herringbone::Writer.new(StringIO.new, { a: :int32 }, compression: :lzo)
    end
    assert_equal "LZO compression is not supported", error.message
    refute Compression.available?(:lzo)
  end

  def test_default_codec_is_snappy
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, { a: :int32 }) { |w| w << [1] }
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal [:snappy], reader.codecs
  end

  def test_installed_codec_gems_are_used
    %i[zstd brotli].each do |codec|
      skip "#{codec} gem not installed" unless Compression.available?(codec)
      io = StringIO.new("".b)
      Herringbone::Writer.open(io, { a: :int32 }, compression: codec) { |w| w << [1] }
      assert_equal [codec], Herringbone::Reader.new(StringIO.new(io.string)).codecs
    end
  end
end
