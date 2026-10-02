# frozen_string_literal: true

require_relative "../test_helper"

class LZOTest < Minitest::Test
  LZO = Herringbone::Codecs::LZO
  DIR = File.join(FIXTURES_DIR, "lzo")
  EOS = "\x11\x00\x00".b
  INPUTS = %w[text runs random far]

  def fixture(name)
    File.binread(File.join(DIR, name))
  end

  def hadoop_chunk(stream)
    [stream.bytesize].pack("N") + stream
  end

  # -- decoder, hand-built streams --

  def test_decodes_literal_only_stream
    assert_equal "hello", LZO.decompress_block("\x16hello".b + EOS, 5)
  end

  def test_decodes_overlapping_match
    # 1 literal "a", then a 10-byte match at distance 1
    assert_equal "a" * 11, LZO.decompress_block("\x12a\x28\x00\x00".b + EOS, 11)
  end

  def test_decodes_extended_literal_run
    lits = "x" * 278 # 18 + 255 + 5
    assert_equal lits, LZO.decompress_block("\x00\x00\x05".b + lits + EOS, 278)
  end

  def test_accepts_non_binary_input
    assert_equal "hello", LZO.decompress_block("\x16hello".b.force_encoding(Encoding::UTF_8) + EOS, 5)
  end

  # -- decoder, streams from liblzo2 --

  def test_decodes_reference_streams
    INPUTS.each do |name|
      data = fixture("#{name}.bin")
      %w[lzo1x_1 lzo1x_999].each do |variant|
        assert_equal data, LZO.decompress_block(fixture("#{name}.#{variant}"), data.bytesize), "#{name}.#{variant}"
      end
    end
  end

  # -- decoder, error handling --

  def test_rejects_distance_before_start
    assert_raises(LZO::Error) { LZO.decompress_block("\x12a\x28\x04\x00".b + EOS, 11) }
  end

  def test_rejects_truncated_streams
    stream = fixture("text.lzo1x_1")
    [stream.bytesize - 1, stream.bytesize - 3, 100, 1, 0].each do |len|
      assert_raises(LZO::Error) { LZO.decompress_block(stream.byteslice(0, len), 29_578) }
    end
  end

  def test_rejects_bytes_after_end_of_stream
    assert_raises(LZO::Error) { LZO.decompress_block("\x16hello".b + EOS + "x", 5) }
  end

  def test_rejects_output_overflow_and_underflow
    assert_raises(LZO::Error) { LZO.decompress_block("\x16hello".b + EOS, 4) }
    assert_raises(LZO::Error) { LZO.decompress_block("\x16hello".b + EOS, 6) }
  end

  # -- hadoop framing --

  def test_decompress_hadoop_with_blocks_and_chunks
    text, runs, random = %w[text runs random].map { |n| fixture("#{n}.bin") }
    framed = [text.bytesize].pack("N") + hadoop_chunk(fixture("text.lzo1x_1")) +
      [runs.bytesize + random.bytesize].pack("N") + hadoop_chunk(fixture("runs.lzo1x_1")) +
      hadoop_chunk(fixture("random.lzo1x_1"))
    expected = text + runs + random
    assert_equal expected, LZO.decompress_hadoop(framed, expected.bytesize)
  end

  def test_chunks_cannot_reference_earlier_chunks
    # The second chunk's match at distance 2 would land on the first chunk's "a"
    framed = [12].pack("N") + hadoop_chunk("\x12a".b + EOS) + hadoop_chunk("\x12b\x28\x04\x00".b + EOS)
    assert_raises(LZO::Error) { LZO.decompress_hadoop(framed, 12) }
  end

  def test_decompress_hadoop_falls_back_to_bare_stream
    data = fixture("text.bin")
    assert_equal data, LZO.decompress_hadoop(fixture("text.lzo1x_999"), data.bytesize)
  end

  def test_decompress_hadoop_raises_on_garbage
    assert_raises(LZO::Error) { LZO.decompress_hadoop("\x00\x00\x00\x10\x00\x00\x00\x02\xFF\xFF".b, 16) }
  end

  # -- parquet --

  def test_reads_parquet_file_with_lzo_pages
    reader = Herringbone::Reader.new(StringIO.new(fixture("lzo.parquet")))
    codecs = reader.file_metadata.row_groups.flat_map { |rg| rg.columns.map { |c| c.meta_data.codec } }
    assert_equal [Herringbone::Format::Codec::LZO], codecs.uniq
    rows = reader.read
    assert_equal 2000, rows.size
    assert_equal({"id" => 1998, "name" => "row 0", "score" => 999.0}, rows[1998])
    assert_nil rows[1999]["score"]
  end

  def test_reads_parquet_mr_file
    # Same expectations as Velox's ParquetReaderTest for this file
    rows = Herringbone::Reader.new(StringIO.new(fixture("velox_lzo.parquet"))).read.map { |r| r["test"] }
    assert_equal 23_547, rows.size
    assert_equal 1, rows.first["intfield"]
    assert_equal 13, rows.last["intfield"]
    strings = rows.flat_map { |r| r["stringarrayfield"] || [] }
    assert_equal "0", strings[0]
    assert_equal "31232", strings[31_232]
  end
end
