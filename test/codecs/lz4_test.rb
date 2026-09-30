# frozen_string_literal: true

require_relative "../test_helper"

class LZ4Test < Minitest::Test
  LZ4 = Herringbone::Codecs::LZ4
  DIR = File.join(FIXTURES_DIR, "lz4")

  def fixture(name)
    File.binread(File.join(DIR, name))
  end

  def roundtrip(data)
    data = data.b
    block = LZ4.compress_block(data)
    assert_equal data, LZ4.decompress_block(block, data.bytesize)
    assert_equal data, LZ4.decompress_hadoop(LZ4.compress_hadoop(data), data.bytesize)
    block
  end

  # -- decoder, hand-built blocks --

  def test_decodes_literal_only_block
    assert_equal "hello", LZ4.decompress_block("\x50hello".b, 5)
  end

  def test_decodes_empty_block
    assert_equal "", LZ4.decompress_block("\x00".b, 0)
    assert_equal "", LZ4.decompress_block("".b, 0)
  end

  def test_decodes_overlapping_match_with_offset_one
    # literal "a", then match offset 1 length 4+6 -> "a" * 11, then 5 literals
    block = "\x16a\x01\x00\x50bcdef".b
    assert_equal "a" * 11 + "bcdef", LZ4.decompress_block(block, 16)
  end

  def test_decodes_overlapping_match_with_multibyte_pattern
    # literal "abc", match offset 3 length 4+10 = 14 -> "abc" repeated, partial tail
    block = "\x3Aabc\x03\x00\x00".b
    assert_equal ("abc" * 6)[0, 17], LZ4.decompress_block(block, 17)
  end

  def test_decodes_extended_lengths
    lits = "x" * 300 # 15 + 255 + 30
    match_len = 4 + 15 + 255 + 255 + 2
    block = "\xFF".b + [255, 30].pack("C*") + lits + "\x01\x00".b + [255, 255, 2].pack("C*") + "\x00".b
    expected = lits + "x" * match_len
    assert_equal expected, LZ4.decompress_block(block, expected.bytesize)
  end

  # -- decoder, error handling --

  def test_rejects_zero_offset
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x10a\x00\x00\x00".b, 5) }
  end

  def test_rejects_offset_before_start
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x10a\x02\x00\x00".b, 5) }
  end

  def test_rejects_truncated_literals
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x50hel".b, 5) }
  end

  def test_rejects_truncated_extended_length
    assert_raises(LZ4::Error) { LZ4.decompress_block("\xF0\xFF".b, 300) }
  end

  def test_rejects_truncated_offset
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x40abcd\x01".b, 20) }
  end

  def test_rejects_output_overflow_and_underflow
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x50hello".b, 4) }
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x50hello".b, 6) }
    assert_raises(LZ4::Error) { LZ4.decompress_block("\x1Fa\x01\x00\xFF\xFF\xFF\x00".b, 100) }
  end

  def test_rejects_garbage
    rng = Random.new(1234)
    50.times do
      junk = rng.bytes(rng.rand(1..64))
      begin
        LZ4.decompress_block(junk, 128)
      rescue LZ4::Error
        # expected; anything other than LZ4::Error fails the test
      end
    end
  end

  # -- compressor --

  def test_roundtrips_edge_sizes
    (0..40).each { |n| roundtrip("ab" * n) }
    (0..20).each { |n| roundtrip(Random.new(n).bytes(n)) }
  end

  def test_roundtrips_runs_and_repeats
    roundtrip("\x00" * 100_000)
    roundtrip("abc" * 10_000 + "tail")
    roundtrip(("The quick brown fox jumps over the lazy dog. " * 500))
  end

  def test_roundtrips_random_and_semi_compressible
    rng = Random.new(7)
    roundtrip(rng.bytes(100_000))
    words = %w[alpha beta gamma parquet column row page]
    semi = +""
    semi << (rng.rand < 0.8 ? words.sample(random: rng) : rng.bytes(rng.rand(1..10))) while semi.bytesize < 200_000
    roundtrip(semi)
  end

  def test_roundtrips_long_offsets_beyond_window
    rng = Random.new(3)
    chunk = rng.bytes(1000)
    data = chunk + rng.bytes(70_000) + chunk # repeat lies beyond the 64K window
    roundtrip(data)
  end

  def test_compresses_repetitive_data
    assert_operator LZ4.compress_block("\x00" * 100_000).bytesize, :<, 500
  end

  def test_accepts_non_binary_input
    s = "héllo wörld " * 50
    block = LZ4.compress_block(s)
    assert_equal Encoding::BINARY, block.encoding
    assert_equal s.b, LZ4.decompress_block(block, s.bytesize)
  end

  def test_last_literals_rules
    data = "abcdefgh" * 100
    block = LZ4.compress_block(data)
    # The final sequence must carry at least 5 literals and no match.
    ip = 0
    last_lits = nil
    while ip < block.bytesize
      token = block.getbyte(ip)
      ip += 1
      lit = token >> 4
      if lit == 15
        loop do
          b = block.getbyte(ip)
          ip += 1
          lit += b
          break if b != 255
        end
      end
      ip += lit
      last_lits = lit
      break if ip == block.bytesize
      ip += 2
      next unless (token & 15) == 15
      loop do
        b = block.getbyte(ip)
        ip += 1
        break if b != 255
      end
    end
    assert_operator last_lits, :>=, 5
  end

  # -- hadoop framing --

  def test_compress_hadoop_framing
    data = "hello hello hello hello hello"
    framed = LZ4.compress_hadoop(data)
    usize, csize = framed.unpack("NN")
    assert_equal data.bytesize, usize
    assert_equal framed.bytesize - 8, csize
  end

  def test_decompress_hadoop_multiple_frames
    a = "first chunk " * 20
    b = "second chunk " * 30
    framed = LZ4.compress_hadoop(a) + LZ4.compress_hadoop(b)
    assert_equal (a + b).b, LZ4.decompress_hadoop(framed, a.bytesize + b.bytesize)
  end

  def test_decompress_hadoop_falls_back_to_raw_block
    data = "raw block payload " * 10
    assert_equal data.b, LZ4.decompress_hadoop(LZ4.compress_block(data), data.bytesize)
  end

  def test_decompress_hadoop_raises_on_garbage
    assert_raises(LZ4::Error) { LZ4.decompress_hadoop("\x00\x00\x00\x10\x00\x00\x00\x02\xFF\xFF".b, 16) }
  end

  def test_parquet_testing_hadoop_and_non_hadoop_pages
    strings = LZ4.decompress_hadoop(fixture("hadoop_lz4_compressed.0.1.0.14.page"), 14)
    assert_equal "\x03\x00\x00\x00abc\x03\x00\x00\x00def".b, strings
    assert_equal strings, LZ4.decompress_hadoop(fixture("non_hadoop_lz4_compressed.0.1.0.14.page"), 14)

    doubles = LZ4.decompress_hadoop(fixture("hadoop_lz4_compressed.0.2.0.24.page"), 24)
    assert_equal [42.0, 7.7, 42.125], doubles.unpack("E3")
    assert_equal doubles, LZ4.decompress_hadoop(fixture("non_hadoop_lz4_compressed.0.2.0.24.page"), 24)
  end

  # -- pyarrow cross-validation vectors --

  def test_decodes_pyarrow_raw_blocks
    %w[semi incompressible].each do |name|
      data = fixture("#{name}.bin")
      assert_equal data, LZ4.decompress_block(fixture("#{name}.lz4raw"), data.bytesize)
    end
  end

  def test_decodes_pyarrow_frames
    %w[semi incompressible].each do |name|
      data = fixture("#{name}.bin")
      assert_equal data, LZ4.decompress_frame(fixture("#{name}.lz4frame"), data.bytesize)
      assert_equal data, LZ4.decompress_hadoop(fixture("#{name}.lz4frame"), data.bytesize)
    end
  end

  def test_compress_is_deterministic_and_competitive
    data = fixture("semi.bin")
    ours = LZ4.compress_block(data)
    assert_equal ours, LZ4.compress_block(data)
    assert_operator ours.bytesize, :<, fixture("semi.lz4raw").bytesize * 1.1
  end

  # -- frame format, hand-built --

  def frame(flg, blocks, content_size: nil, content_checksum: false, block_checksum: false)
    out = [0x184D2204].pack("V") << flg << 0x40
    out << [content_size].pack("Q<") if content_size
    out << 0 # header checksum, not verified
    blocks.each do |data, raw|
      out << [data.bytesize | (raw ? 0x80000000 : 0)].pack("V") << data
      out << "\x00\x00\x00\x00".b if block_checksum
    end
    out << [0].pack("V")
    out << "\x00\x00\x00\x00".b if content_checksum
    out
  end

  def test_frame_with_checksums_content_size_and_linked_blocks
    first = "linked block data " * 4
    # second block: a match reaching back into the first block (B.Indep = 0)
    second = "\x0F\x48\x00\x00\x50tail!".b
    expected = first + first[0, 19] + "tail!"
    data = frame(0x40 | 0x10 | 0x08 | 0x04, [[LZ4.compress_block(first), false], [second, false]],
      content_size: expected.bytesize, content_checksum: true, block_checksum: true)
    assert_equal expected.b, LZ4.decompress_frame(data, expected.bytesize)
    assert_equal expected.b, LZ4.decompress_hadoop(data, expected.bytesize)
  end

  def test_frame_with_uncompressed_block_and_skippable_frame
    skippable = [0x184D2A50, 3].pack("VV") + "xyz"
    data = skippable + frame(0x60, [["plain bytes", true]]) + frame(0x60, [[LZ4.compress_block("more"), false]])
    assert_equal "plain bytesmore", LZ4.decompress_frame(data, 15)
  end

  def test_frame_errors
    assert_raises(LZ4::Error) { LZ4.decompress_frame([0x184D2204].pack("V") + "\x60".b, 10) }
    assert_raises(LZ4::Error) { LZ4.decompress_frame(frame(0x00, []), 0) } # bad version
    assert_raises(LZ4::Error) { LZ4.decompress_frame(frame(0x60, [["abc", true]])[0..-3], 3) }
    assert_raises(LZ4::Error) { LZ4.decompress_frame([0xDEADBEEF].pack("V"), 3) }
  end
end
