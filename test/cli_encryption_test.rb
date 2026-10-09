# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

# bin/herringbone on encrypted files: key flags, and keys asked for on stdin
class CliEncryptionTest < Minitest::Test
  BIN = File.expand_path("../bin/herringbone", __dir__)
  DIR = File.join(FIXTURES_DIR, "parquet-testing")
  ENCRYPTED_FOOTER = File.join(DIR, "encrypt_columns_and_footer.parquet.encrypted")
  PLAINTEXT_FOOTER = File.join(DIR, "encrypt_columns_plaintext_footer.parquet.encrypted")
  UNIFORM = File.join(DIR, "uniform_encryption.parquet.encrypted")
  AAD = File.join(DIR, "encrypt_columns_and_footer_disable_aad_storage.parquet.encrypted")

  FOOTER_HEX = "0123456789012345".unpack1("H*")
  DOUBLE_HEX = "1234567890123450".unpack1("H*") # kc1
  FLOAT_HEX = "1234567890123451".unpack1("H*") # kc2

  def run_cli(*args, stdin: "")
    Open3.capture3(RbConfig.ruby, BIN, *args, stdin_data: stdin)
  end

  def test_encrypted_footer_without_keys
    out, err, status = run_cli("inspect", ENCRYPTED_FOOTER, "--no-prompt")
    refute status.success?
    assert_empty out
    assert_match(/footer is encrypted and no key was given for it \(key metadata "kf"\)/, err)
    assert_match(/--footer-key=KEY/, err)
    refute_match(/Key for/, err, "--no-prompt asks for nothing")

    _, err, status = run_cli("inspect", ENCRYPTED_FOOTER)
    refute status.success?, "an empty stdin gives no key"
    assert_match(/Key for the footer \(key metadata "kf"\)/, err)
  end

  def test_keys_asked_on_stdin
    out, err, status = run_cli("inspect", ENCRYPTED_FOOTER, stdin: "#{FOOTER_HEX}\n#{FLOAT_HEX}\n\n")
    assert status.success?, err
    assert_match(/Key for the footer \(key metadata "kf"\), hex:/, err)
    assert_match(/Key for column float_field \(key metadata "kc2"\)/, err)
    assert_match(/Key for column double_field \(key metadata "kc1"\)/, err)
    assert_match(/encryption: aes_gcm, encrypted footer, footer key metadata "kf"/, out)
    assert_match(/  float_field: column key "kc2"$/, out)
    assert_match(/  double_field: column key "kc1" \(no key given\)/, out)
    assert_match(/  double_field: DOUBLE encrypted, metadata unavailable without its key/, out)
    assert_match(/  double_field: encrypted, metadata and pages unavailable without its key/, out)
  end

  def test_key_flags
    out, err, status = run_cli("inspect", ENCRYPTED_FOOTER, "--pages", "--footer-key=#{FOOTER_HEX}",
      "--column-key=double_field=#{DOUBLE_HEX}", "--key=kc2=raw:1234567890123451")
    assert status.success?, err
    assert_empty err, "every key was given, nothing is asked"
    refute_match(/no key given/, out)
    assert_match(/  double_field: SNAPPY .*encrypted/, out)
    assert_match(/    0: DATA_PAGE @\d+ header \d+ \+ \d+\/\d+ bytes, 50 values/, out)
  end

  def test_bare_keys
    out, err, status = run_cli("cat", UNIFORM, "1", "--key=raw:0123456789012345", "--no-prompt")
    assert status.success?, err
    assert_equal 0, JSON.parse(out)["int32_field"]

    Dir.mktmpdir do |dir|
      old_key = Herringbone::Key.generate
      new_key = Herringbone::Key.generate
      path = File.join(dir, "rotated.parquet")
      File.open(path, "wb") { |f| Herringbone.write(f, [{id: 1}], encryption: old_key) }
      out, err, status = run_cli("cat", path, "--key=#{new_key.hex}", "--key=#{old_key.hex}", "--no-prompt")
      assert status.success?, err
      assert_equal({"id" => 1}, JSON.parse(out))
    end
  end

  def test_json_and_html_with_keys
    out, err, status = run_cli("inspect", UNIFORM, "--format=json", "--footer-key=base64:#{["0123456789012345"].pack("m0")}")
    assert status.success?, err
    json = JSON.parse(out)
    assert_equal "encrypted", json["summary"]["encryption"]["footer"]
    assert_equal 8, json["summary"]["encryption"]["columns"].size
    out, err, status = run_cli("inspect", UNIFORM, "--format=html", "--footer-key=0123456789012345")
    assert status.success?, err
    assert_includes out, "<html"
  end

  def test_plaintext_footer_opens_without_keys
    out, err, status = run_cli("inspect", PLAINTEXT_FOOTER, "--no-prompt")
    assert status.success?, err
    assert_match(/encryption: aes_gcm, plaintext footer, footer key metadata "kf"$/, out)
    assert_match(/float_field: column key "kc2" \(no key given\)/, out)

    out, err, status = run_cli("inspect", PLAINTEXT_FOOTER, stdin: "#{FOOTER_HEX}\n\n\n")
    assert status.success?, err
    assert_match(/plaintext footer \(signature verified\)/, out)
  end

  def test_cat_with_keys
    out, err, status = run_cli("cat", PLAINTEXT_FOOTER, "2", "--key=kc1=#{DOUBLE_HEX}", "--key=kc2=#{FLOAT_HEX}", "--no-prompt")
    assert status.success?, err
    rows = out.lines.map { |l| JSON.parse(l) }
    assert_equal [0, 1], rows.map { |r| r["int32_field"] }
    assert_in_delta 1.1111111, rows[1]["double_field"], 1e-9

    _, err, status = run_cli("cat", PLAINTEXT_FOOTER, "1", "--no-prompt")
    refute status.success?
    assert_match(/Column float_field is encrypted and its key was not given/, err)
  end

  def test_aad_prefix
    _, err, status = run_cli("cat", AAD, "1", "--footer-key=#{FOOTER_HEX}", "--no-prompt")
    refute status.success?
    assert_match(/AAD prefix/, err)
    out, err, status = run_cli("cat", AAD, "1", "--footer-key=#{FOOTER_HEX}", "--aad-prefix=tester",
      "--key=kc1=#{DOUBLE_HEX}", "--key=kc2=#{FLOAT_HEX}")
    assert status.success?, err
    assert_equal 0, JSON.parse(out)["int32_field"]
  end

  def test_bad_keys
    _, err, status = run_cli("inspect", UNIFORM, "--footer-key=abc")
    refute status.success?
    assert_match(/--footer-key must be a 16, 24 or 32-byte String/, err)
    _, err, status = run_cli("inspect", UNIFORM, "--column-key=foo")
    refute status.success?
    assert_match(/--column-key expects --column-key=PATH=KEY/, err)
    _, err, status = run_cli("inspect", UNIFORM, "--footer-key=#{"ff" * 16}", "--no-prompt")
    refute status.success?
    assert_match(/Cannot decrypt the footer/, err)
    _, err, status = run_cli("inspect", ENCRYPTED_FOOTER, stdin: "nope\n")
    refute status.success?
    assert_match(/the key for the footer must be a 16, 24 or 32-byte String/, err)
  end
end
