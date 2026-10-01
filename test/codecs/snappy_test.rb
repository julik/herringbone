# frozen_string_literal: true

require_relative "../test_helper"

class SnappyTest < Minitest::Test
  Snappy = Herringbone::Codecs::Snappy

  def roundtrip(data)
    compressed = Snappy.compress(data)
    assert_equal Encoding::BINARY, compressed.encoding
    out = Snappy.decompress(compressed)
    assert_equal Encoding::BINARY, out.encoding
    assert_equal data.b, out
    compressed
  end

  def test_roundtrip_empty
    assert_equal "\x00".b, roundtrip("")
  end

  def test_roundtrip_one_byte
    assert_equal "\x01\x00x".b, roundtrip("x")
  end

  def test_roundtrip_short_inputs
    (2..40).each { |n| roundtrip("ab" * n) }
    roundtrip("hello world hello world")
  end

  def test_roundtrip_random
    roundtrip(Random.new(1).bytes(10_000))
  end

  def test_roundtrip_highly_repetitive
    data = "a" * 100_000
    compressed = roundtrip(data)
    assert_operator compressed.bytesize, :<, data.bytesize / 20
    roundtrip("abc" * 50_000)
  end

  def test_roundtrip_over_one_block
    r = Random.new(2)
    data = Array.new(20_000) { (r.rand < 0.5) ? "row#{r.rand(100)}," : r.bytes(3) }.join
    assert_operator data.bytesize, :>, 65_536
    roundtrip(data)
  end

  def test_roundtrip_over_one_megabyte
    r = Random.new(3)
    words = %w[parquet column page row group snappy dictionary]
    data = Array.new(200_000) { words[r.rand(words.size)] }.join(" ")
    assert_operator data.bytesize, :>, 1_000_000
    compressed = roundtrip(data)
    assert_operator compressed.bytesize, :<, data.bytesize / 2
  end

  def test_roundtrip_long_literals
    # literal lengths needing 1, 2 and 3 extra length bytes
    [61, 256, 257, 65_536].each { |n| roundtrip(Random.new(n).bytes(n)) }
  end

  def test_non_binary_input_is_accepted
    assert_equal "héllo héllo héllo".b, Snappy.decompress(Snappy.compress("héllo héllo héllo"))
  end

  def test_overlapping_copy_offset_1
    # "a" then copy len 64 at offset 1 (2-byte offset form)
    assert_equal "a" * 65, Snappy.decompress("\x41\x00a\xFE\x01\x00".b)
  end

  def test_overlapping_copy_offset_2
    # "ab" then copy len 8 at offset 2 (1-byte offset form)
    assert_equal "ababababab", Snappy.decompress("\x0A\x04ab\x11\x02".b)
  end

  def test_overlapping_copy_offset_3_uneven_length
    # "abc" then copy len 7 at offset 3
    assert_equal "abcabcabca", Snappy.decompress("\x0A\x08abc\x0D\x03".b)
  end

  def test_overlapping_copy_where_offset_equals_length_minus_one
    # "abcde" then copy len 6 at offset 5
    assert_equal "abcdeabcdea", Snappy.decompress("\x0B\x10abcde\x09\x05".b)
  end

  def test_copy_with_4_byte_offset
    # "abcd" then copy len 4 at offset 4 using the 4-byte offset form
    assert_equal "abcdabcd", Snappy.decompress("\x08\x0Cabcd\x0F\x04\x00\x00\x00".b)
  end

  def test_literal_length_encodings
    data = "z" * 300
    # 1-byte length (tag 60)
    assert_equal data[0, 100], Snappy.decompress("\x64\xF0\x63".b + data[0, 100])
    # 2-byte length (tag 61)
    assert_equal data, Snappy.decompress("\xAC\x02\xF4\x2B\x01".b + data)
    # 3- and 4-byte lengths (tags 62, 63)
    assert_equal "q", Snappy.decompress("\x01\xF8\x00\x00\x00q".b)
    assert_equal "q", Snappy.decompress("\x01\xFC\x00\x00\x00\x00q".b)
  end

  def test_decompresses_pyarrow_fixtures
    %w[text runs mixed].each do |name|
      expected = File.binread(File.join(FIXTURES_DIR, "snappy", "#{name}.bin"))
      compressed = File.binread(File.join(FIXTURES_DIR, "snappy", "#{name}.snappy"))
      assert_equal expected, Snappy.decompress(compressed), name
      roundtrip(expected)
    end
  end

  def test_corrupt_inputs_raise
    [
      "",                         # missing preamble
      "\x80".b,                   # truncated varint
      "\xFF\xFF\xFF\xFF\xFF\x01".b, # varint too long
      "\x05\x10ab".b,             # literal overruns input
      "\x05\xF0".b,               # truncated literal length byte
      "\x04\x00a\x01".b,          # truncated copy
      "\x04\x00a\x01\x00".b,      # copy offset 0
      "\x08\x00a\x01\x02".b,      # copy offset beyond output
      "\x03\x00a".b,              # output shorter than declared
      "\x01\x04ab".b,             # output longer than declared
      "\x02\x00a\x05\x01".b      # copy overruns declared length
    ].each do |bad|
      assert_raises(Snappy::Error, bad.inspect) { Snappy.decompress(bad) }
    end
  end

  def test_error_is_standard_error
    assert_operator Snappy::Error, :<, StandardError
  end
end

# The optional `snappy` gem and the pure-Ruby codec must be interchangeable
class SnappyBackendTest < Minitest::Test
  Snappy = Herringbone::Codecs::Snappy

  def teardown
    Snappy.backend = nil
  end

  def with_backend(name)
    Snappy.backend = name
    yield
  ensure
    Snappy.backend = nil
  end

  def samples
    rng = Random.new(42)
    [
      "".b,
      "a".b,
      ("abcd" * 10_000).b,
      Array.new(70_000) { rng.rand(256) }.pack("C*"),       # incompressible, over one 64KB block
      (("hello parquet " * 50) + rng.bytes(3_000)) * 40,    # mixed
      Array.new(200_000) { |i| [i, i * 3].pack("q<l<") }.join # page-like numbers
    ]
  end

  def test_pure_ruby_backend_can_be_forced
    with_backend(:ruby) do
      assert_equal :ruby, Snappy.backend
      samples.each { |data| assert_equal data, Snappy.decompress(Snappy.compress(data)) }
    end
  end

  def test_backends_read_each_others_blocks
    skip "the snappy gem is not installed" unless native?
    samples.each do |data|
      from_ruby = with_backend(:ruby) { Snappy.compress(data) }
      from_native = with_backend(:native) { Snappy.compress(data) }
      assert_equal data, with_backend(:native) { Snappy.decompress(from_ruby) }
      assert_equal data, with_backend(:ruby) { Snappy.decompress(from_native) }
      assert_equal Encoding::BINARY, with_backend(:native) { Snappy.decompress(from_ruby) }.encoding
    end
  end

  def test_native_errors_are_wrapped
    skip "the snappy gem is not installed" unless native?
    with_backend(:native) do
      assert_raises(Snappy::Error) { Snappy.decompress("\xFF\xFF\xFFgarbage".b) }
    end
  end

  def test_files_round_trip_with_either_backend
    rows = Array.new(5_000) { |i| {id: i, name: "name #{i % 97}", score: i * 0.5} }
    %i[ruby native].each do |backend|
      next if backend == :native && !native?
      bytes = with_backend(backend) do
        io = StringIO.new("".b)
        Herringbone.write(io, rows)
        io.string
      end
      %i[ruby native].each do |reading|
        next if reading == :native && !native?
        got = with_backend(reading) { Herringbone::Reader.new(StringIO.new(bytes), keys: :symbol).read }
        assert got == rows, "written with #{backend}, read with #{reading}"
      end
    end
  end

  def test_backend_validation
    assert_raises(ArgumentError) { Snappy.backend = :fast }
    if native?
      Snappy.backend = :native
      assert_equal :native, Snappy.backend
    else
      assert_raises(Herringbone::UnsupportedError) { Snappy.backend = :native }
    end
  end

  def native?
    Snappy.send(:native_library) ? true : false
  end
end
