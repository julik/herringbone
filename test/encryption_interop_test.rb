# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "base64"
require "json"
require "open3"
require "tmpdir"

# Encrypted files written by pyarrow and read by Herringbone, and the other way around. pyarrow
# only offers the key tools layer: key metadata is PKMT1 JSON holding data keys wrapped by a KMS.
# test/support/pyarrow_encryption.py "wraps" keys by base64-encoding them, so the key metadata
# can be built and unwrapped here. Set HERRINGBONE_PYTHON to a Python with pyarrow installed.
class EncryptionInteropTest < Minitest::Test
  include WriterHelpers

  PYTHON = ENV["HERRINGBONE_PYTHON"]
  SCRIPT = File.expand_path("support/pyarrow_encryption.py", __dir__)

  def self.pyarrow_status
    return @pyarrow_status if defined?(@pyarrow_status)
    @pyarrow_status = if PYTHON.nil? || PYTHON.empty?
      "HERRINGBONE_PYTHON is not set"
    else
      out, status = Open3.capture2e(PYTHON, SCRIPT, "--check")
      status.success? ? nil : "#{PYTHON} cannot import pyarrow.parquet.encryption: #{out.lines.last}"
    end
  rescue SystemCallError => e
    @pyarrow_status = "#{PYTHON}: #{e.message}"
  end

  def setup
    status = self.class.pyarrow_status
    if status
      # CI sets HERRINGBONE_REQUIRE_INTEROP so a broken Python setup fails instead of skipping
      flunk status if ENV["HERRINGBONE_REQUIRE_INTEROP"]
      skip status
    end
    @dir = Dir.mktmpdir("herringbone-encryption")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # Unwraps the data key from PKMT1 key metadata (see the class comment)
  UNWRAP = ->(metadata) { Base64.strict_decode64(JSON.parse(metadata).fetch("wrappedDEK")) }

  # PKMT1 key metadata for +key+, as pyarrow's key tools write it with the base64 KMS
  def key_metadata(key, master_key, footer)
    material = {"keyMaterialType" => "PKMT1", "internalStorage" => true, "isFooterKey" => footer}
    material = material.merge("kmsInstanceID" => "DEFAULT", "kmsInstanceURL" => "DEFAULT") if footer
    material.merge("masterKeyID" => master_key, "wrappedDEK" => Base64.strict_encode64(key), "doubleWrapping" => false).to_json
  end

  def python(*args)
    out, err, status = Open3.capture3(PYTHON, SCRIPT, *args)
    assert status.success?, "pyarrow_encryption.py #{args.first} failed: #{err}"
    JSON.parse(out)
  end

  def ruby_rows(rows)
    rows.map { |r| r.transform_values { |v| v.is_a?(Time) ? v.utc.strftime("%Y-%m-%dT%H:%M:%S+00:00") : v } }
  end

  {
    column_keys: {columns: {"kc1" => ["ssn", "tags"]}},
    uniform: {uniform: true},
    plaintext_footer: {columns: {"kc1" => ["ssn"]}, plaintext_footer: true},
    ctr_256: {columns: {"kc1" => ["ssn"], "kc2" => ["score"]}, algorithm: "AES_GCM_CTR_V1", key_bits: 256}
  }.each do |name, options|
    define_method("test_reads_pyarrow_#{name}") do
      path = File.join(@dir, "pyarrow.parquet")
      expected = python("write", path, options.to_json)
      File.open(path, "rb") do |f|
        reader = Herringbone::Reader.new(f, decryption: {keys: UNWRAP})
        assert_equal expected, ruby_rows(reader.read)
        assert_equal [expected[1234]], ruby_rows(reader.read(where: {id: 1234}))
        assert_equal (options[:plaintext_footer] ? :plaintext : :encrypted), reader.encryption[:footer]
        assert reader.encryption[:footer_verified] if options[:plaintext_footer]
      end
    end
  end

  # pyarrow 25+ reads and writes uniform encryption with a single key, without a KMS
  def single_key(*args)
    out, err, status = Open3.capture3(PYTHON, SCRIPT, *args)
    skip "pyarrow is older than 25 (no create_decryption_properties)" if status.exitstatus == 3
    assert status.success?, "pyarrow_encryption.py #{args.first} failed: #{err}"
    JSON.parse(out)
  end

  def test_pyarrow_reads_simple_configuration_with_the_key_alone
    key = Random.new(7).bytes(32)
    rows = Array.new(5000) { |i| {"id" => i, "ssn" => i.odd? ? "ssn-#{i}" : nil, "score" => i * 0.5, "tags" => ["t"] * (i % 3)} }
    path = File.join(@dir, "simple.parquet")
    File.open(path, "wb") do |f|
      Herringbone::Writer.open(f, SCHEMA, page_rows: 700, bloom_filters: %w[id],
        encryption: Herringbone::Key.new(key, id: "orders-2026")) { |w| rows.each { |r| w << r } }
    end
    assert_equal rows, single_key("read-key", path, key.unpack1("H*"))
  end

  def test_reads_pyarrow_single_key_files
    key = Random.new(8).bytes(16)
    path = File.join(@dir, "pyarrow_key.parquet")
    expected = single_key("write-key", path, key.unpack1("H*"))
    File.open(path, "rb") do |f|
      assert_equal expected, ruby_rows(Herringbone::Reader.new(f, decryption: {footer_key: key}).read)
    end
  end

  SCHEMA = Herringbone::Schema.define do |s|
    s.int64 :id, null: false
    s.string :ssn
    s.double :score
    s.list :tags, :string
  end

  {
    column_keys_v1: [1, {columns: :ssn}],
    uniform_v2: [2, {}],
    plaintext_footer_v1: [1, {columns: :ssn, plaintext_footer: true}],
    ctr_v2: [2, {columns: :ssn, algorithm: :aes_gcm_ctr}]
  }.each do |name, (version, settings)|
    define_method("test_pyarrow_reads_#{name}") do
      footer_key = "f" * 16
      ssn_key = "s" * 32
      encryption = {footer_key: footer_key, footer_key_metadata: key_metadata(footer_key, "kf", true)}
      encryption[:plaintext_footer] = true if settings[:plaintext_footer]
      encryption[:algorithm] = settings[:algorithm] if settings[:algorithm]
      if settings[:columns]
        encryption[:columns] = {"ssn" => {key: ssn_key, key_metadata: key_metadata(ssn_key, "kc1", false)}, "tags" => :footer}
      end
      rows = Array.new(3000) do |i|
        {"id" => i, "ssn" => i.odd? ? format("ssn-%04d", i % 500) : nil, "score" => i * 0.5, "tags" => ["t#{i % 3}"] * (i % 3)}
      end
      path = File.join(@dir, "herringbone.parquet")
      File.open(path, "wb") do |f|
        Herringbone::Writer.open(f, SCHEMA, data_page_version: version, page_rows: 700, bloom_filters: %w[id ssn],
          encryption: encryption) { |w| rows.each { |r| w << r } }
      end
      assert_equal rows, python("read", path)
    end
  end
end
