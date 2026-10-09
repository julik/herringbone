# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# Parts of Herringbone load on first use, so each check runs in a fresh Ruby
class AutoloadTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)
  PLAIN = File.join(FIXTURES_DIR, "parquet-testing", "alltypes_plain.parquet")
  BLOOM = File.join(FIXTURES_DIR, "parquet-testing", "data_index_bloom_encoding_stats.parquet")
  ENCRYPTED = File.join(FIXTURES_DIR, "parquet-testing", "uniform_encryption.parquet.encrypted")

  # Runs +code+ after requiring herringbone and returns what was loaded:
  # { "files" => herringbone files relative to lib/, "openssl" => Boolean }
  def loaded_after(code)
    script = <<~RUBY
      $LOAD_PATH.unshift #{LIB.inspect}
      require "herringbone"
      #{code}
      files = $LOADED_FEATURES.select { |f| f.start_with?(#{LIB.inspect}) }.map { |f| f.delete_prefix(#{(LIB + "/").inspect}).delete_suffix(".rb") }
      puts Marshal.dump({"files" => files.sort, "openssl" => defined?(OpenSSL::Cipher) ? true : false}).unpack1("H*")
    RUBY
    # Without Bundler, since bundler/setup from Bundler 4 loads OpenSSL by itself
    env = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script, unsetenv_others: true)
    assert status.success?, err
    Marshal.load([out.lines.last.strip].pack("H*")) # standard:disable Security/MarshalLoad
  end

  def test_require_loads_almost_nothing
    assert_equal({"files" => %w[herringbone herringbone/version], "openssl" => false}, loaded_after(""))
  end

  def test_reading_and_writing_plain_files_leave_the_rest_unloaded
    read = loaded_after("Herringbone::Reader.new(File.open(#{PLAIN.inspect}, 'rb')).read")
    write = loaded_after("Herringbone.write(StringIO.new, [{id: 1, name: 'x'}])")
    [read, write].each do |result|
      refute result["openssl"], "OpenSSL is only loaded for encrypted files"
      %w[inspector visualizer redaction encryption key encryption_configuration simple_writer bloom_filter xxhash
        reader/numo reader/scan codecs/lz4 codecs/lzo].each do |name|
        refute_includes result["files"], "herringbone/#{name}"
      end
    end
    refute_includes write["files"], "herringbone/reader"
    refute_includes read["files"], "herringbone/writer"
  end

  def test_features_load_when_used
    where = loaded_after("Herringbone::Reader.new(File.open(#{BLOOM.inspect}, 'rb')).read(where: {'String' => 'Hello'})")
    assert_includes where["files"], "herringbone/reader/scan"
    assert_includes where["files"], "herringbone/bloom_filter"
    encrypted = loaded_after("Herringbone::Reader.new(File.open(#{ENCRYPTED.inspect}, 'rb'), decryption: {footer_key: '0123456789012345'}).read")
    assert encrypted["openssl"]
    assert_includes encrypted["files"], "herringbone/encryption"
  end

  def test_eager_load_loads_everything
    all = Dir[File.join(LIB, "**", "*.rb")].map { |f| f.delete_prefix("#{LIB}/").delete_suffix(".rb") }.sort
    assert_equal all, loaded_after("Herringbone.eager_load!")["files"]
  end
end
