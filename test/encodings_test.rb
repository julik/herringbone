# frozen_string_literal: true

require_relative "test_helper"

# Unit tests for the low-level encodings and the Thrift compact protocol
class RLEEncodingTest < Minitest::Test
  RLE = Herringbone::Encodings::RLE

  # Reference LSB-first bit packer, independent of the implementation under test
  def reference_pack(values, width)
    return "".b if width.zero? || values.empty?
    padded = (values.size + 7) / 8 * 8
    big = 0
    values.each_with_index { |v, i| big |= v << (i * width) }
    nbytes = padded * width / 8
    Array.new(nbytes) { |i| (big >> (8 * i)) & 0xFF }.pack("C*")
  end

  def random_values(rng, count, width)
    return Array.new(count, 0) if width.zero?
    max = (1 << width) - 1
    Array.new(count) do |i|
      case i % 5
      when 0 then max
      when 1 then 0
      else rng.rand(max + 1)
      end
    end
  end

  (0..64).each do |width|
    define_method("test_pack_unpack_bits_width_#{width}") do
      rng = Random.new(width)
      [0, 1, 7, 8, 9, 16, 33, 100].each do |count|
        values = random_values(rng, count, width)
        packed = RLE.pack_bits(values, width)
        assert_equal reference_pack(values, width), packed, "pack width=#{width} count=#{count}"
        assert_equal Encoding::BINARY, packed.encoding
        assert_equal values, RLE.unpack_bits(packed, 0, count, width), "unpack width=#{width} count=#{count}"
        # at an offset inside a larger buffer
        buf = "\xAB\xCD\xEF".b + packed + "\xFF\xFF".b
        assert_equal values, RLE.unpack_bits(buf, 3, count, width), "unpack at offset width=#{width}"
      end
    end
  end

  def test_unpack_bits_treats_missing_trailing_bytes_as_zero
    assert_equal [1, 0, 0], RLE.unpack_bits("\x01".b, 0, 3, 16)
    assert_equal [5, 0], RLE.unpack_bits("\x05".b, 0, 2, 8)
    assert_equal [0, 0], RLE.unpack_bits("".b, 0, 2, 40)
  end

  def test_unpack_bits_width_zero
    assert_equal [0, 0, 0], RLE.unpack_bits("".b, 0, 3, 0)
  end

  def test_hybrid_roundtrips
    rng = Random.new(42)
    cases = {
      "empty" => [],
      "single" => [1],
      "one run" => [3] * 100,
      "run of exactly 8" => [2] * 8,
      "run of 7" => [2] * 7,
      "literals only" => Array.new(37) { |i| i % 4 },
      "literals then run" => [0, 1, 2, 3, 0, 1, 2, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      "unaligned literals then run" => [0, 1, 2] + [3] * 30 + [1, 2],
      "run then literals" => [1] * 20 + [0, 1, 0, 1, 1],
      "alternating runs" => ([0] * 9 + [1] * 11) * 5,
      "length 13" => Array.new(13) { |i| i & 1 },
      "random" => Array.new(1001) { rng.rand(4) },
      "random runs" => Array.new(50) { [rng.rand(8)] * rng.rand(1..20) }.flatten
    }
    [1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 24, 31, 32].each do |width|
      cases.each do |name, values|
        vals = values.map { |v| v & ((1 << width) - 1) }
        vals = vals.each_with_index.map { |v, i| (i % 11 == 10) ? (1 << width) - 1 : v } unless name == "one run"
        enc = RLE.encode_hybrid(vals, width)
        dec = RLE.decode_hybrid(enc, 0, enc.bytesize, width, vals.size)
        assert_equal vals, dec, "width=#{width} #{name}"
      end
    end
  end

  def test_hybrid_width_zero
    enc = RLE.encode_hybrid([0] * 20, 0)
    assert_equal [0] * 20, RLE.decode_hybrid(enc, 0, enc.bytesize, 0, 20)
    enc = RLE.encode_hybrid([0] * 3, 0)
    assert_equal [0] * 3, RLE.decode_hybrid(enc, 0, enc.bytesize, 0, 3)
  end

  def test_hybrid_uses_rle_runs_for_long_runs
    enc = RLE.encode_hybrid([5] * 1000, 3)
    # header varint (1000 << 1) = 2 bytes + 1 value byte
    assert_equal 3, enc.bytesize
  end

  def test_decode_hybrid_hand_crafted
    # RLE run: header (4 << 1) = 8, value 3 (1 byte for width 2)
    # bit-packed: header (1 << 1) | 1 = 3, 8 values of width 2: 0,1,2,3,0,1,2,3 -> 0b11100100 x2
    data = [8, 3, 3, 0b11100100, 0b11100100].pack("C*")
    assert_equal [3, 3, 3, 3, 0, 1, 2, 3, 0, 1], RLE.decode_hybrid(data, 0, data.bytesize, 2, 10)
  end

  def test_decode_hybrid_respects_start_position
    enc = RLE.encode_hybrid([1, 0, 1, 1], 1)
    data = "junk".b + enc
    assert_equal [1, 0, 1, 1], RLE.decode_hybrid(data, 4, data.bytesize, 1, 4)
  end

  def test_decode_hybrid_raises_when_exhausted
    enc = RLE.encode_hybrid([1] * 8, 1)
    assert_raises(Herringbone::FormatError) { RLE.decode_hybrid(enc, 0, enc.bytesize, 1, 9) }
  end

  def test_legacy_bit_packed
    # MSB-first: values 0..7 with width 3 -> 000 001 010 011 100 101 110 111
    data = ["000001010011100101110111"].pack("B*")
    assert_equal (0..7).to_a, RLE.decode_legacy_bit_packed(data, 0, 3, 8)
  end

  def test_legacy_bit_packed_rejects_truncated_data
    data = ["000001010011100101110111"].pack("B*")
    assert_raises(Herringbone::FormatError) { RLE.decode_legacy_bit_packed(data, 0, 3, 9) }
    assert_raises(Herringbone::FormatError) { RLE.decode_legacy_bit_packed(data, 1, 3, 8) }
    assert_raises(Herringbone::FormatError) { RLE.decode_legacy_bit_packed(data, 10, 3, 8) }
  end
end

class DeltaEncodingTest < Minitest::Test
  Delta = Herringbone::Encodings::Delta

  I32_MIN = -2**31
  I32_MAX = 2**31 - 1
  I64_MIN = -2**63
  I64_MAX = 2**63 - 1

  def roundtrip(values, bits)
    enc = Delta.encode_binary_packed(values, bits)
    dec, pos = Delta.decode_binary_packed(enc, 0, bits, values.size)
    assert_equal values, dec, "bits=#{bits} n=#{values.size}"
    assert_equal enc.bytesize, pos, "decoder must consume the whole encoding (bits=#{bits} n=#{values.size})"
    # header count is honoured when count is not given
    dec2, = Delta.decode_binary_packed(enc, 0, bits)
    assert_equal values, dec2
    enc
  end

  def test_binary_packed_counts
    rng = Random.new(1)
    [32, 64].each do |bits|
      [0, 1, 2, 3, 31, 32, 33, 127, 128, 129, 255, 256, 257, 1000].each do |n|
        roundtrip(Array.new(n) { rng.rand(-1000..1000) }, bits)
        roundtrip(Array.new(n) { |i| i * 3 }, bits) # constant delta -> width 0 miniblocks
        roundtrip(Array.new(n, 7), bits)
      end
    end
  end

  def test_binary_packed_extremes_int32
    values = [I32_MIN, I32_MAX, I32_MIN, 0, I32_MAX, I32_MAX, -1, I32_MIN, 1] * 20
    roundtrip(values, 32)
    roundtrip([I32_MAX, I32_MIN], 32) # delta wraps
    roundtrip([I32_MIN], 32)
    roundtrip([I32_MAX] * 200, 32)
    rng = Random.new(2)
    roundtrip(Array.new(500) { rng.rand(I32_MIN..I32_MAX) }, 32)
  end

  def test_binary_packed_extremes_int64
    values = [I64_MIN, I64_MAX, I64_MIN, 0, I64_MAX, I64_MAX, -1, I64_MIN, 1] * 20
    roundtrip(values, 64)
    roundtrip([I64_MAX, I64_MIN], 64)
    roundtrip([I64_MIN, I64_MAX], 64)
    roundtrip([I64_MIN], 64)
    rng = Random.new(3)
    roundtrip(Array.new(500) { rng.rand(I64_MIN..I64_MAX) }, 64)
  end

  def test_binary_packed_hand_crafted
    # From the Parquet spec example: 1, 2, 3, 4, 5 -> block 128, 4 miniblocks, 5 values, first 1,
    # min delta 1, widths 0
    enc = Delta.encode_binary_packed([1, 2, 3, 4, 5], 32)
    header = [0x80, 0x01, 0x04, 0x05, 0x02]
    assert_equal header, enc.bytes.first(5)
    assert_equal [1, 2, 3, 4, 5], Delta.decode_binary_packed(enc, 0, 32).first
  end

  def test_binary_packed_decode_with_count_smaller_than_header
    enc = Delta.encode_binary_packed((1..300).to_a, 64)
    assert_equal (1..10).to_a, Delta.decode_binary_packed(enc, 0, 64, 10).first
  end

  def test_decoder_accepts_arbitrary_widths_for_unused_miniblocks
    # 3 values, block 128 / 4 miniblocks; unused miniblocks declare non-zero widths
    data = [0x80, 0x01, 0x04, 0x03, 0x02, 0x00, 0x01, 0x05, 0x07, 0x09].pack("C*") + "\x06".b + "\x00".b * 3
    vals, pos = Delta.decode_binary_packed(data, 0, 32)
    # first=1, min_delta=0, deltas (width 1): bits 0,1 -> +0, +1
    assert_equal [1, 1, 2], vals
    assert_equal data.bytesize, pos
  end

  def test_rejects_bad_header
    bad = [0x80, 0x01, 0x00, 0x01, 0x00].pack("C*") # zero miniblocks
    assert_raises(Herringbone::FormatError) { Delta.decode_binary_packed(bad, 0, 32) }
    bad = [0x0c, 0x03, 0x01, 0x00].pack("C*") # 12/3 = 4 values per miniblock, not multiple of 8
    assert_raises(Herringbone::FormatError) { Delta.decode_binary_packed(bad, 0, 32) }
  end

  def test_wrap
    assert_equal I32_MIN, Delta.wrap(I32_MAX + 1, 32)
    assert_equal(-1, Delta.wrap(2**64 - 1, 64))
    assert_equal I64_MAX, Delta.wrap(I64_MAX, 64)
  end

  def test_length_byte_array
    [[], [""], ["", "", ""], ["a"], %w[hello world foo], ["x" * 1000, "", "y"], ["\x00\xFF".b, "é漢字"],
      Array.new(300) { |i| "v#{i}" * (i % 7) }].each do |values|
      enc = Delta.encode_length_byte_array(values)
      dec, pos = Delta.decode_length_byte_array(enc, 0, values.size)
      assert_equal values.map(&:b), dec
      assert_equal enc.bytesize, pos
    end
  end

  def test_byte_array
    [[], [""], ["", "a", ""], %w[apple application apply apt banana band bandana],
      ["same", "same", "same"], ["abc", "ab", "a", ""], ["prefix\x00\xFF".b, "prefix\x00\xFE".b],
      ["日本語", "日本", "日本語テキスト"], Array.new(400) { |i| format("key-%05d", i / 3) }].each do |values|
      enc = Delta.encode_byte_array(values)
      dec, pos = Delta.decode_byte_array(enc, 0, values.size)
      assert_equal values.map(&:b), dec
      assert_equal enc.bytesize, pos
    end
  end

  def test_byte_array_uses_prefixes
    values = Array.new(100) { |i| "a-very-long-common-prefix-#{i}" }
    assert_operator Delta.encode_byte_array(values).bytesize, :<, Delta.encode_length_byte_array(values).bytesize
  end

  def test_byte_array_rejects_bad_prefix
    enc = Delta.encode_binary_packed([3], 32) + Delta.encode_length_byte_array(["x"])
    assert_raises(Herringbone::FormatError) { Delta.decode_byte_array(enc, 0, 1) }
  end

  def test_byte_array_rejects_negative_prefix
    enc = Delta.encode_binary_packed([0, -1], 32) + Delta.encode_length_byte_array(["abc", "x"])
    assert_raises(Herringbone::FormatError) { Delta.decode_byte_array(enc, 0, 2) }
  end

  def test_page_decoder_rejects_negative_prefix
    enc = Delta.encode_binary_packed([0, -1], 32) + Delta.encode_length_byte_array(["abc", "x"])
    decoder = Herringbone::Reader::PageStream::DeltaByteArrayDecoder.new(enc, 0)
    assert_raises(Herringbone::FormatError) { decoder.read(2) }
  end

  def test_length_byte_array_decodes_fewer_values_than_encoded
    values = Array.new(100) { |i| "v" * (i % 37) }
    enc = Delta.encode_length_byte_array(values)
    [0, 1, 2, 33, 99].each do |count|
      dec, pos = Delta.decode_length_byte_array(enc, 0, count)
      assert_equal values.first(count), dec
      assert_equal enc.bytesize - values.drop(count).sum(&:bytesize), pos
    end
  end

  def test_byte_array_decodes_fewer_values_than_encoded
    values = Array.new(100) { |i| format("key-%05d", i * 7919 % 1000) }
    enc = Delta.encode_byte_array(values)
    [0, 1, 2, 33, 99].each do |count|
      dec, = Delta.decode_byte_array(enc, 0, count)
      assert_equal values.first(count), dec
    end
  end
end

class ByteStreamSplitTest < Minitest::Test
  BSS = Herringbone::Encodings::ByteStreamSplit
  Plain = Herringbone::Encodings::Plain
  T = Herringbone::Format::Type

  def test_roundtrip_widths
    rng = Random.new(5)
    [1, 2, 3, 4, 8, 12, 16].each do |width|
      [0, 1, 5, 100].each do |count|
        plain = rng.bytes(width * count)
        enc = BSS.encode(plain, width)
        assert_equal plain.bytesize, enc.bytesize
        dec, pos = BSS.decode("zz".b + enc, 2, count, width)
        assert_equal plain, dec
        assert_equal 2 + enc.bytesize, pos
      end
    end
  end

  def test_layout
    plain = [0x04030201, 0x08070605].pack("V*")
    assert_equal [1, 5, 2, 6, 3, 7, 4, 8].pack("C*"), BSS.encode(plain, 4)
  end

  def test_floats
    values = [1.5, -0.0, Float::INFINITY, -Float::INFINITY, 3.14159, Float::MAX]
    enc = BSS.encode(Plain.encode(values, T::DOUBLE), 8)
    dec, = BSS.decode(enc, 0, values.size, 8)
    assert_equal values, Plain.decode(dec, 0, values.size, T::DOUBLE).first
  end

  def test_truncated
    assert_raises(Herringbone::FormatError) { BSS.decode("\x00".b * 7, 0, 2, 4) }
  end
end

class PlainEncodingTest < Minitest::Test
  Plain = Herringbone::Encodings::Plain
  T = Herringbone::Format::Type

  def roundtrip(values, type, length = nil)
    enc = Plain.encode(values, type, length)
    assert_equal Encoding::BINARY, enc.encoding unless values.empty?
    dec, pos = Plain.decode("~".b + enc, 1, values.size, type, length)
    assert_equal enc.bytesize + 1, pos
    dec
  end

  def test_boolean
    [0, 1, 7, 8, 9, 17].each do |n|
      values = Array.new(n) { |i| i % 3 == 0 }
      assert_equal values, roundtrip(values, T::BOOLEAN)
    end
    assert_equal "\x05".b, Plain.encode([true, false, true], T::BOOLEAN)
  end

  def test_int32
    values = [0, 1, -1, 2**31 - 1, -2**31, 12_345]
    assert_equal values, roundtrip(values, T::INT32)
    assert_equal [1, 0, 0, 0].pack("C*"), Plain.encode([1], T::INT32)
  end

  def test_int64
    values = [0, 1, -1, 2**63 - 1, -2**63, 2**40]
    assert_equal values, roundtrip(values, T::INT64)
  end

  def test_float_and_double
    f = roundtrip([1.5, -0.0, Float::INFINITY, -2.25], T::FLOAT)
    assert_equal [1.5, -0.0, Float::INFINITY, -2.25], f
    assert_equal(-1, 1.0 / f[1] <=> 0)
    assert roundtrip([Float::NAN], T::FLOAT).first.nan?
    values = [Math::PI, -0.0, Float::MIN, Float::MAX, -Float::INFINITY, 5e-324]
    assert_equal values, roundtrip(values, T::DOUBLE)
    assert roundtrip([Float::NAN], T::DOUBLE).first.nan?
  end

  def test_int96
    values = [[0, 2_440_588], [86_399_999_999_999, 0], [2**64 - 1, 2**32 - 1]]
    assert_equal values, roundtrip(values, T::INT96)
    assert_equal 36, Plain.encode(values, T::INT96).bytesize
  end

  def test_byte_array
    values = ["", "a", "\x00\xFF".b, "é" * 10, "x" * 70_000]
    assert_equal values.map(&:b), roundtrip(values, T::BYTE_ARRAY)
    assert_equal "\x02\x00\x00\x00hi".b, Plain.encode(["hi"], T::BYTE_ARRAY)
  end

  def test_fixed_len_byte_array
    values = ["abc", "\x00\x00\x00".b, "\xFF\xFE\xFD".b]
    assert_equal values.map(&:b), roundtrip(values, T::FIXED_LEN_BYTE_ARRAY, 3)
    assert_raises(Herringbone::EncodeError) { Plain.encode(["ab"], T::FIXED_LEN_BYTE_ARRAY, 3) }
  end

  def test_empty
    [T::BOOLEAN, T::INT32, T::INT64, T::FLOAT, T::DOUBLE, T::INT96, T::BYTE_ARRAY].each do |t|
      assert_equal [], roundtrip([], t)
    end
    assert_equal [], roundtrip([], T::FIXED_LEN_BYTE_ARRAY, 4)
  end

  def test_truncated_input_raises
    assert_raises(Herringbone::FormatError) { Plain.decode("\x00\x00".b, 0, 1, T::INT32) }
    assert_raises(Herringbone::FormatError) { Plain.decode("\x00".b * 8, 0, 1, T::INT96) }
    assert_raises(Herringbone::FormatError) { Plain.decode("\x05\x00\x00\x00ab".b, 0, 1, T::BYTE_ARRAY) }
    assert_raises(Herringbone::FormatError) { Plain.decode("\x05\x00".b, 0, 1, T::BYTE_ARRAY) }
    assert_raises(Herringbone::FormatError) { Plain.decode("ab".b, 0, 1, T::FIXED_LEN_BYTE_ARRAY, 3) }
    assert_raises(Herringbone::FormatError) { Plain.decode("".b, 0, 9, T::BOOLEAN) }
  end
end

class ThriftCompactTest < Minitest::Test
  F = Herringbone::Format
  Th = Herringbone::Thrift

  # A struct exercising field-id deltas > 15, negative ids of every type
  class Sample < Herringbone::Thrift::Struct
    field 1, :flag, :bool
    field 2, :tiny, :byte
    field 3, :small, :i16
    field 5, :num, :i32
    field 21, :big, :i64
    field 40, :ratio, :double
    field 300, :blob, :binary
    field 301, :text, :string
    field 302, :flags, [:list, :bool]
    field 1000, :nums, [:list, :i64]
    field 1001, :children, [:list, F::KeyValue]
    field 1002, :nested, F::Statistics
  end

  def roundtrip(obj)
    bytes = obj.encode
    decoded, pos = obj.class.decode(bytes)
    assert_equal bytes.bytesize, pos
    assert_equal obj, decoded
    decoded
  end

  def test_sample_struct_roundtrip
    obj = Sample.new(
      flag: false, tiny: -128, small: -32_768, num: -2**31, big: -2**63, ratio: -1.5e300,
      blob: "\x00\xFF\x80".b, text: "héllo 漢字", flags: [true, false, true] * 7,
      nums: [0, -1, 1, 2**63 - 1, -2**63] * 4,
      children: Array.new(20) { |i| F::KeyValue.new(key: "k#{i}", value: i.even? ? "v" : nil) },
      nested: F::Statistics.new(null_count: 0, min_value: "", is_max_value_exact: true, is_min_value_exact: false)
    )
    d = roundtrip(obj)
    assert_equal false, d.flag
    assert_equal(-128, d.tiny)
    assert_equal Encoding::UTF_8, d.text.encoding
    assert_equal "héllo 漢字", d.text
    assert_equal false, d.nested.is_min_value_exact
    obj2 = Sample.new(flag: true, tiny: 127, small: 32_767, num: 2**31 - 1, big: 2**63 - 1, ratio: 0.0)
    assert_equal true, roundtrip(obj2).flag
    assert_equal Sample.new, roundtrip(Sample.new)
  end

  def test_field_header_long_form
    bytes = Sample.new(num: 1, big: 2).encode
    # num: delta 5 short form (0x55), zigzag(1)=2; big: delta 16 -> long form: type 6, zigzag(21)=42
    assert_equal [0x55, 0x02, 0x06, 42, 0x04, 0x00], bytes.bytes
  end

  def test_list_size_boundaries
    [0, 1, 14, 15, 16, 200].each do |n|
      roundtrip(Sample.new(nums: Array.new(n) { |i| i - 7 }, flags: Array.new(n) { |i| i.odd? }))
    end
    bytes = Sample.new(nums: [1] * 14).encode
    assert_equal 0xE6, bytes.bytes[3] # size 14 in the header nibble, element type i64
    bytes = Sample.new(nums: [1] * 15).encode
    assert_equal [0xF6, 15], bytes.bytes[3, 2]
  end

  def file_metadata
    schema = [F::SchemaElement.new(name: "schema", num_children: 1)]
    schema << F::SchemaElement.new(name: "g", repetition_type: 1, num_children: 20)
    20.times do |i|
      schema << F::SchemaElement.new(name: "c#{i}", type: F::Type::INT64, repetition_type: 1,
        logical_type: F::LogicalType.new(timestamp: F::TimestampType.new(is_adjusted_to_utc: i.even?, unit: F::TimeUnit.nanos)))
    end
    stats = F::Statistics.new(max_value: "\xFF".b, min_value: "\x00".b, null_count: 3, is_max_value_exact: true, is_min_value_exact: false)
    col = F::ColumnChunk.new(file_offset: 4, meta_data: F::ColumnMetaData.new(
      type: 2, encodings: [0, 3, 8], path_in_schema: %w[g c0], codec: 6, num_values: 10,
      total_uncompressed_size: 100, total_compressed_size: 80, data_page_offset: 4, statistics: stats,
      encoding_stats: [F::PageEncodingStats.new(page_type: 0, encoding: 8, count: 1)]
    ))
    F::FileMetaData.new(
      version: 2, schema: schema, num_rows: -5,
      row_groups: [F::RowGroup.new(columns: [col] * 20, num_rows: 10, total_byte_size: 1000, ordinal: -1,
        sorting_columns: [F::SortingColumn.new(column_idx: 0, descending: true, nulls_first: false)])],
      key_value_metadata: [F::KeyValue.new(key: "a", value: "b")], created_by: "test",
      column_orders: Array.new(20) { F::ColumnOrder.new(type_order: F::TypeDefinedOrder.new) }
    )
  end

  def test_file_metadata_roundtrip
    md = file_metadata
    d = roundtrip(md)
    assert_equal 22, d.schema.size
    assert_equal :nanos, d.schema[2].logical_type.timestamp.unit.to_sym
    assert_equal false, d.schema[3].logical_type.timestamp.is_adjusted_to_utc
    assert_equal(-5, d.num_rows)
    assert_equal(-1, d.row_groups[0].ordinal)
    assert_equal true, d.row_groups[0].sorting_columns[0].descending
    assert_equal false, d.row_groups[0].columns[0].meta_data.statistics.is_min_value_exact
  end

  # -- hand-crafted unknown fields --

  def varint(n)
    out = []
    loop do
      if n < 0x80
        out << n
        return out
      end
      out << ((n & 0x7F) | 0x80)
      n >>= 7
    end
  end

  def zz(n) = varint(n.negative? ? ((-n) << 1) - 1 : n << 1)

  # field header in long form (so any id works irrespective of the previous one)
  def fh(id, wire) = [wire] + zz(id)

  def binary(s) = varint(s.bytesize) + s.bytes

  def unknown_fields
    b = []
    b += fh(100, Th::T_TRUE)                              # bool true
    b += fh(101, Th::T_FALSE)                             # bool false
    b += fh(102, Th::T_BYTE) + [0xFF]                     # byte
    b += fh(103, Th::T_I16) + zz(-300)                    # i16
    b += fh(104, Th::T_I64) + zz(-2**62)                  # i64
    b += fh(105, Th::T_DOUBLE) + [1.25].pack("E").bytes   # double
    b += fh(106, Th::T_BINARY) + binary("unknown\x00\xFF".b)
    # list<i32> with 20 elements (long size form)
    b += fh(107, Th::T_LIST) + [0xF0 | Th::T_I32] + varint(20) + (1..20).flat_map { |i| zz(-i) }
    # list<bool> of 3 (bools in lists are one byte each)
    b += fh(108, Th::T_LIST) + [(3 << 4) | Th::T_TRUE, 1, 2, 1]
    # set<binary> of 2
    b += fh(109, Th::T_SET) + [(2 << 4) | Th::T_BINARY] + binary("x") + binary("yz")
    # map<binary, i32> of 2
    b += fh(110, Th::T_MAP) + varint(2) + [(Th::T_BINARY << 4) | Th::T_I32] + binary("k1") + zz(1) + binary("k2") + zz(-2)
    # empty map
    b += fh(111, Th::T_MAP) + [0]
    # nested struct: { 1: i32, 2: struct { 1: list<struct{1: binary}>, 20: bool }, 3: map<i32, struct> }
    inner_struct = [(1 << 4) | Th::T_BINARY] + binary("deep") + [0]
    nested = []
    nested += [(1 << 4) | Th::T_I32] + zz(7)
    nested += [(1 << 4) | Th::T_STRUCT]
    nested += [(1 << 4) | Th::T_LIST, (2 << 4) | Th::T_STRUCT] + inner_struct + inner_struct
    nested += [Th::T_TRUE] + zz(20)
    nested += [0]
    nested += [(1 << 4) | Th::T_MAP] + varint(1) + [(Th::T_I32 << 4) | Th::T_STRUCT] + zz(5) + inner_struct
    nested += [0]
    b += fh(112, Th::T_STRUCT) + nested
    # list<list<i64>>
    b += fh(113, Th::T_LIST) + [(2 << 4) | Th::T_LIST] + [(1 << 4) | Th::T_I64] + zz(9) + [(0 << 4) | Th::T_I64]
    b
  end

  def test_skips_unknown_fields_of_every_type
    b = []
    b += fh(1, Th::T_I32) + zz(1)
    b += unknown_fields
    b += fh(3, Th::T_I64) + zz(42)
    b += fh(6, Th::T_BINARY) + binary("me")
    b += fh(99, Th::T_STRUCT) + unknown_fields + [0] # unknown struct containing unknown fields
    b << 0
    bytes = b.pack("C*")
    md, pos = F::FileMetaData.decode(bytes)
    assert_equal bytes.bytesize, pos
    assert_equal 1, md.version
    assert_equal 42, md.num_rows
    assert_equal "me", md.created_by
    assert_nil md.schema
  end

  def test_skips_map_with_bool_values
    # Bool map keys/values are written as one byte each in the compact protocol
    b = fh(50, Th::T_MAP) + varint(2) + [(Th::T_I32 << 4) | Th::T_TRUE] + zz(1) + [1] + zz(2) + [2]
    b += fh(6, Th::T_BINARY) + binary("after")
    b << 0
    md, = F::FileMetaData.decode(b.pack("C*"))
    assert_equal "after", md.created_by
  end

  def test_skips_known_field_with_unexpected_wire_type
    b = fh(3, Th::T_BINARY) + binary("oops") + fh(6, Th::T_BINARY) + binary("ok") + [0]
    md, = F::FileMetaData.decode(b.pack("C*"))
    assert_nil md.num_rows
    assert_equal "ok", md.created_by
  end

  def test_short_form_field_ids_after_unknown
    # version (id 1, short), unknown id 4 (short, delta 3) list<i32>, then key_value_metadata id 5 (delta 1)
    b = [(1 << 4) | Th::T_I32] + zz(2)
    b += [(1 << 4) | Th::T_I32] + zz(3) # id 2 as i32 -> incompatible with list type, skipped
    b += [(2 << 4) | Th::T_LIST, (1 << 4) | Th::T_I32] + zz(1)
    b += [(1 << 4) | Th::T_LIST, (1 << 4) | Th::T_STRUCT] + [(1 << 4) | Th::T_BINARY] + binary("k") + [0]
    b << 0
    md, = F::FileMetaData.decode(b.pack("C*"))
    assert_equal 2, md.version
    assert_nil md.schema
    assert_equal "k", md.key_value_metadata[0].key
  end

  def test_truncated_input_raises
    bytes = file_metadata.encode
    [1, 10, bytes.bytesize / 2, bytes.bytesize - 1].each do |len|
      assert_raises(Th::Error) { F::FileMetaData.decode(bytes.byteslice(0, len)) }
    end
  end

  def test_varint_limits
    w = Th::Writer.new
    w.write_zigzag(-2**63)
    w.write_zigzag(2**63 - 1)
    r = Th::Reader.new(w.buf)
    assert_equal(-2**63, r.read_zigzag)
    assert_equal 2**63 - 1, r.read_zigzag
    assert_raises(Th::Error) { Th::Writer.new.write_varint(-1) }
  end
end
