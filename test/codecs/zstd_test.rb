# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

class ZstdTest < Minitest::Test
  Z = Herringbone::Codecs::Zstd
  DIR = File.join(FIXTURES_DIR, "zstd")
  INPUTS = %w[text ints runs random]
  VARIANTS = %w[1 19 check long]

  def fixture(name)
    File.binread(File.join(DIR, name))
  end

  def frame(blocks, descriptor: 0x00, header: "")
    [Z::MAGIC].pack("V") + descriptor.chr + header + blocks
  end

  # A frame with no window descriptor (single segment) and a 1-byte content size
  def single_segment_frame(content_size, blocks, checksum: false)
    frame(blocks, descriptor: 0x20 | (checksum ? 4 : 0), header: content_size.chr)
  end

  def block(type, body, size: body.bytesize, last: true)
    [(size << 3) | (type << 1) | (last ? 1 : 0)].pack("V").byteslice(0, 3) + body
  end

  def raw_block(data, last: true) = block(0, data.b, last: last)

  def rle_block(byte, size, last: true) = block(1, byte.b, size: size, last: last)

  # -- frames from the reference zstd --

  def test_decodes_reference_frames
    INPUTS.each do |name|
      expected = Z.decompress(fixture("#{name}.check.zst"), 1 << 20) # verified by its XXH64
      refute_empty expected
      VARIANTS.each do |variant|
        assert_equal expected, Z.decompress(fixture("#{name}.#{variant}.zst"), expected.bytesize), "#{name}.#{variant}"
      end
    end
  end

  def test_matches_zstd_ruby
    skip "zstd-ruby not installed" unless defined?(::Zstd)
    INPUTS.product(VARIANTS).each do |name, variant|
      data = fixture("#{name}.#{variant}.zst")
      assert_equal ::Zstd.decompress(data), Z.decompress(data, 1 << 20), "#{name}.#{variant}"
    end
  end

  def test_decodes_upstream_golden_frames
    # From zstd's tests/golden-decompression: an empty block, a 128 KiB block, a first
    # block that is RLE, and a block with zero sequences
    assert_equal "", Z.decompress(fixture("golden/empty-block.zst"), 0)
    assert_equal 131_068, Z.decompress(fixture("golden/block-128k.zst"), 1 << 20).bytesize
    assert_equal 1_048_576, Z.decompress(fixture("golden/rle-first-block.zst"), 1 << 20).bytesize
    assert_equal 13, Z.decompress(fixture("golden/zeroSeq_2B.zst"), 13).bytesize
  end

  def test_rejects_upstream_golden_errors
    {
      "off0.bin" => /repeats an offset of 0/,
      "truncated_huff_state" => /Huffman stream is too short/,
      "zeroSeq_extraneous" => /bytes after an empty sequences section/
    }.each do |name, message|
      error = assert_raises(Z::Error, name) { Z.decompress(fixture("golden/error-#{name}.zst"), 1 << 20) }
      assert_match message, error.message
    end
  end

  def test_round_trips_through_zstd_ruby
    skip "zstd-ruby not installed" unless defined?(::Zstd)
    rng = Random.new(8878)
    words = %w[parquet column page the a of]
    inputs = [
      "", "x", rng.bytes(17), rng.bytes(200_000),
      Array.new(30_000) { words[rng.rand(words.size)] }.join(" "),
      Array.new(30_000) { rng.rand(1000) }.pack("q<*"),
      "\0" * 300_000, "ab" * 70_000
    ]
    inputs.each do |data|
      [-5, 1, 3, 12, 19, 22].each do |level|
        compressed = ::Zstd.compress(data, level: level)
        assert_equal data.b, Z.decompress(compressed, data.bytesize), "#{data.bytesize} bytes at level #{level}"
      end
    end
  end

  # -- hand-built frames --

  def test_decodes_raw_and_rle_blocks
    blocks = raw_block("hello ", last: false) + rle_block("z", 5)
    assert_equal "hello zzzzz", Z.decompress(single_segment_frame(11, blocks), 11)
    assert_equal "hello zzzzz", Z.decompress(frame(blocks, header: "\x00"), 11) # window descriptor, no size
  end

  def test_concatenated_and_skippable_frames
    one = single_segment_frame(3, raw_block("one"))
    skippable = [Z::SKIPPABLE_MAGIC | 7, 4].pack("VV") + "junk"
    assert_equal "oneone", Z.decompress(one + skippable + one, 6)
  end

  def test_accepts_non_binary_input
    data = single_segment_frame(5, raw_block("hello")).force_encoding(Encoding::UTF_8)
    out = Z.decompress(data, 5)
    assert_equal "hello", out
    assert_equal Encoding::BINARY, out.encoding
  end

  def test_verifies_the_content_checksum
    checksum = [Herringbone::XXHash.xxh64("hello") & 0xFFFFFFFF].pack("V")
    assert_equal "hello", Z.decompress(single_segment_frame(5, raw_block("hello"), checksum: true) + checksum, 5)

    bad = checksum.dup
    bad.setbyte(0, bad.getbyte(0) ^ 1)
    error = assert_raises(Z::Error) { Z.decompress(single_segment_frame(5, raw_block("hello"), checksum: true) + bad, 5) }
    assert_match(/checksum mismatch/, error.message)
  end

  def test_rejects_malformed_frames
    {
      "" => /input is empty/,
      "\x28\xB5" => /ends inside a frame magic/,
      "PAR1xxxx" => /Not Zstandard data/,
      frame("", descriptor: 0x08) => /reserved bit/,
      frame(raw_block("x"), descriptor: 0x01, header: "\x00\x07") => /needs dictionary 7/,
      single_segment_frame(1, block(3, "x")) => /reserved block type/,
      single_segment_frame(1, "") => /block header at offset \d+ needs 3 bytes/,
      single_segment_frame(5, raw_block("hello", last: false)) => /block header/,
      single_segment_frame(4, raw_block("hello")) => /decompressed to 5 bytes, but its header declares 4/,
      single_segment_frame(5, raw_block("hello")[0, 6]) => /raw block .* needs 5 bytes/,
      [Z::SKIPPABLE_MAGIC, 10].pack("VV") + "short" => /skippable frame runs past/
    }.each do |input, message|
      error = assert_raises(Z::Error, input.inspect) { Z.decompress(input.b, 100) }
      assert_match message, error.message, input.inspect
    end
  end

  def test_rejects_every_truncation
    data = fixture("text.check.zst")
    expected = Z.decompress(data, 1 << 20).bytesize
    [0, 1, 4, 5, 6, 8, 9, 100, data.bytesize / 2, data.bytesize - 5, data.bytesize - 1].each do |len|
      assert_raises(Z::Error, "truncated to #{len}") { Z.decompress(data.byteslice(0, len), expected) }
    end
  end

  # -- decompression bombs --

  def test_stops_at_the_limit_without_a_content_size
    # 4 bytes of input per 128 KiB of output: 40 KB in, 1.3 GB out if nothing stopped it
    bomb = frame(rle_block("A", Z::BLOCK_MAX, last: false) * 10_000 + rle_block("A", 1), header: "\x00")
    error = nil
    elapsed = seconds { error = assert_raises(Z::Error) { Z.decompress(bomb, 1_000_000) } }
    assert_match(/more than the 1000000 bytes expected/, error.message)
    assert_operator elapsed, :<, 1
  end

  def test_rejects_a_declared_content_size_over_the_limit_upfront
    huge = frame(rle_block("A", 10), descriptor: 0xC0, header: "\x00" + [1 << 40].pack("Q<"))
    error = assert_raises(Z::Error) { Z.decompress(huge, 1_000_000) }
    assert_match(/declares 1099511627776 bytes of content, more than the 1000000 bytes left/, error.message)
  end

  def test_rejects_matches_that_reach_past_the_limit
    data = fixture("runs.1.zst")
    expected = Z.decompress(data, 1 << 20).bytesize
    error = assert_raises(Z::Error) { Z.decompress(data, expected - 1) }
    assert_match(/more than the #{expected - 1} bytes expected/, error.message)
  end

  def test_rejects_oversized_blocks
    assert_match(/RLE block of 131073 bytes is larger/, assert_raises(Z::Error) {
      Z.decompress(frame(rle_block("A", Z::BLOCK_MAX + 1), header: "\x00"), 1 << 20)
    }.message)
    assert_match(/raw block of 131073 bytes is larger/, assert_raises(Z::Error) {
      Z.decompress(frame(raw_block("A" * (Z::BLOCK_MAX + 1)), header: "\x00"), 1 << 20)
    }.message)
  end

  def test_does_not_allocate_a_huge_claimed_size_upfront
    # A page header may claim any size: allocating it before decoding anything would be the bomb
    assert_equal "hello", Z.decompress(single_segment_frame(5, raw_block("hello")), 1 << 50)
  end

  # -- fuzzing --

  # Mutated reference frames must decode or raise Z::Error, quickly, and never exceed the
  # limit: anything else (NoMethodError on a nil byte, an endless loop) is a bug. Fixed seeds
  # keep failures reproducible.
  def test_fuzzed_frames_fail_cleanly
    corpus = INPUTS.product(VARIANTS).map { |name, variant| fixture("#{name}.#{variant}.zst") }
    corpus += Dir[File.join(DIR, "golden", "*.zst")].map { |path| File.binread(path) }
    slowest = 0
    3.times do |seed|
      rng = Random.new(seed)
      400.times do |i|
        data = mutate(corpus[rng.rand(corpus.size)].dup, rng)
        limit = [rng.rand(0..5000), 1 << 20].sample(random: rng)
        slowest = [slowest, seconds { decode_fuzzed(data, limit, "seed #{seed}, case #{i}") }].max
      end
    end
    assert_operator slowest, :<, 2, "the slowest fuzzed frame took #{slowest.round(2)}s"
  end

  # Frames whose block headers are valid but whose bodies are random or damaged, so the fuzzing
  # gets past the frame header into the literals, Huffman, FSE and sequence decoders
  def test_fuzzed_block_bodies_fail_cleanly
    bodies = INPUTS.product(VARIANTS).flat_map { |name, variant| compressed_bodies(fixture("#{name}.#{variant}.zst")) }
    rng = Random.new(2026)
    1500.times do |i|
      blocks = Array.new(rng.rand(1..3)) do |b|
        body = case rng.rand(3)
        when 0 then rng.bytes(rng.rand(1..200))
        when 1 then [rng.rand(256), rng.rand(256), rng.rand(256), rng.rand(1..4), rng.rand(256)].pack("C*") + rng.bytes(rng.rand(100))
        else mutate(bodies[rng.rand(bodies.size)].dup, rng, truncate: false)
        end
        block(2, body, last: false)
      end.join
      data = frame(blocks + block(0, "", last: true), header: "\x00")
      decode_fuzzed(data, [rng.rand(0..5000), 1 << 20].sample(random: rng), "case #{i}")
    end
  end

  private

  def seconds
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def decode_fuzzed(data, limit, label)
    out = Timeout.timeout(10) { Z.decompress(data, limit) }
    assert_operator out.bytesize, :<=, limit, label
  rescue Z::Error
    # what corrupt input should do
  rescue Timeout::Error
    flunk "#{label} did not finish in 10s: #{data.unpack1("H*")[0, 200]}"
  rescue => e
    flunk "#{label} raised #{e.class} (#{e.message}) instead of #{Z::Error}: #{data.unpack1("H*")[0, 200]}"
  end

  def mutate(data, rng, truncate: true)
    rng.rand(1..4).times do
      break if data.empty?
      pos = rng.rand(data.bytesize)
      case rng.rand(truncate ? 6 : 5)
      when 0 then data.setbyte(pos, data.getbyte(pos) ^ (1 << rng.rand(8)))
      when 1 then data.setbyte(pos, [0, 0xFF, 0x80, rng.rand(256)].sample(random: rng))
      when 2 then data = data.byteslice(0, pos) + rng.bytes(rng.rand(1..8)) + data.byteslice(pos..)
      when 3 then data = data.byteslice(0, pos) + data.byteslice((pos + rng.rand(1..16))..).to_s
      when 4 then data = data.byteslice(0, pos) + data.byteslice(rng.rand(data.bytesize), rng.rand(1..32)) + data.byteslice(pos..)
      else data = data.byteslice(0, pos)
      end
    end
    data
  end

  # Bodies of the compressed blocks in a frame
  def compressed_bodies(data)
    descriptor = data.getbyte(4)
    single_segment = descriptor[5] == 1
    pos = 5 + (single_segment ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + [single_segment ? 1 : 0, 2, 4, 8][descriptor >> 6]
    bodies = []
    while true
      header = data.getbyte(pos) | (data.getbyte(pos + 1) << 8) | (data.getbyte(pos + 2) << 16)
      size = header >> 3
      type = (header >> 1) & 3
      bodies << data.byteslice(pos + 3, size) if type == 2
      pos += 3 + ((type == 1) ? 1 : size)
      return bodies if header & 1 == 1
    end
  end
end
