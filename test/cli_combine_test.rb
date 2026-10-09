# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# bin/herringbone combine
class CliCombineTest < Minitest::Test
  BIN = File.expand_path("../bin/herringbone", __dir__)

  def run_cli(*args, stdin: "")
    Open3.capture3(RbConfig.ruby, BIN, *args, stdin_data: stdin, binmode: true)
  end

  def write(path, rows, **options)
    File.open(path, "wb") { |f| Herringbone.write(f, rows, **options) }
    path
  end

  def rows_of(path, **options)
    File.open(path, "rb") { |f| Herringbone::Reader.new(f, **options).read }
  end

  def test_combines_into_the_output
    Dir.mktmpdir do |dir|
      a = write(File.join(dir, "a.parquet"), [{id: 1}, {id: 2}])
      b = write(File.join(dir, "b.parquet"), [{id: 3}])
      out = File.join(dir, "out.parquet")
      stdout, err, status = run_cli("combine", a, b, "--output=#{out}")
      assert status.success?, err
      assert_empty stdout
      assert_match(/3 rows, 2 row groups copied, 0 encoded again/, err)
      assert_equal [1, 2, 3], rows_of(out).map { |r| r["id"] }
    end
  end

  def test_writes_to_redirected_stdout
    Dir.mktmpdir do |dir|
      a = write(File.join(dir, "a.parquet"), [{id: 1}])
      stdout, err, status = run_cli("combine", a, a)
      assert status.success?, err
      assert_equal [{"id" => 1}, {"id" => 1}], Herringbone::Reader.new(StringIO.new(stdout)).read
    end
  end

  def test_different_schemas_need_union
    Dir.mktmpdir do |dir|
      a = write(File.join(dir, "a.parquet"), [{id: 1, name: "a"}])
      b = write(File.join(dir, "b.parquet"), [{id: 2, tag: "x"}])
      out = File.join(dir, "out.parquet")
      _, err, status = run_cli("combine", a, b, "--output=#{out}")
      refute status.success?
      assert_match(/1 of 2 inputs has another schema than input 0 \(#{Regexp.escape(a)}\):/, err)
      assert_match(/    name  missing here, input 0 has it\n    tag   only here, input 0 lacks it/, err)
      assert_match(/give --schema=union/, err)
      refute File.exist?(out), "A file without its footer is removed"

      _, err, status = run_cli("combine", a, b, "--output=#{out}", "--schema=union", "--compression=gzip")
      assert status.success?, err
      assert_equal [{"id" => 1, "name" => "a", "tag" => nil}, {"id" => 2, "name" => nil, "tag" => "x"}], rows_of(out)

      _, err, status = run_cli("combine", a, b, "--output=#{out}", "--schema=intersect")
      assert status.success?, err
      assert_equal [{"id" => 1}, {"id" => 2}], rows_of(out)
    end
  end

  def test_encrypted_inputs
    Dir.mktmpdir do |dir|
      key = Herringbone::Key.generate
      new_key = Herringbone::Key.generate
      a = write(File.join(dir, "a.parquet"), [{id: 1}], encryption: key)
      b = write(File.join(dir, "b.parquet"), [{id: 2}])
      out = File.join(dir, "out.parquet")
      _, err, status = run_cli("combine", a, b, "--output=#{out}", "--key=#{key.hex}")
      assert status.success?, err
      assert_equal [1, 2], rows_of(out, decryption: key).map { |r| r["id"] }, "encrypted like the encrypted input"

      _, err, status = run_cli("combine", a, b, "--output=#{out}", "--key=#{key.hex}", "--encrypt-key=#{new_key.hex}")
      assert status.success?, err
      assert_equal [1, 2], rows_of(out, decryption: new_key).map { |r| r["id"] }

      _, err, status = run_cli("combine", a, b, "--output=#{out}", "--plaintext", stdin: "#{key.hex}\n")
      assert status.success?, err
      assert_equal 1, err.scan("Key for the footer").size, "The key is asked for once, though the footer is read twice"
      assert_equal [1, 2], rows_of(out).map { |r| r["id"] }
    end
  end

  def test_refuses_an_output_that_is_an_input
    Dir.mktmpdir do |dir|
      a = write(File.join(dir, "a.parquet"), [{id: 1}])
      _, err, status = run_cli("combine", a, a, "--output=#{a}")
      refute status.success?
      assert_match(/is one of the inputs/, err)
      assert_equal [{"id" => 1}], rows_of(a)
    end
  end

  def test_usage
    [%w[combine], %w[combine a.parquet --output=], %w[combine a.parquet --output=x --plaintext --encrypt-key=00],
      %w[combine a.parquet --output=x --pages], %w[combine a.parquet --output=x --union],
      %w[combine a.parquet --output=x --schema=all]].each do |args|
      _, err, status = run_cli(*args)
      refute status.success?
      assert_match(/usage: herringbone/, err)
    end
  end
end
