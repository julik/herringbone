# frozen_string_literal: true

require "bigdecimal"
require "date"
require_relative "canonical"

# Shared schemas, data generators and helpers for the writer and interop tests
module WriterHelpers
  CODECS = %i[none snappy gzip lz4 lz4_hadoop zstd brotli].freeze

  def self.codec_available?(codec)
    Parakiet::Compression.compress(Parakiet::Compression.codec_id(codec), "x".b)
    true
  rescue Parakiet::UnsupportedError
    false
  end

  ALL_TYPES_SCHEMA = Parakiet::Schema.define do
    int64 :id, null: false
    boolean :bool
    boolean :bool_req, null: false
    int8 :i8
    int16 :i16
    int32 :i32
    int64 :i64
    uint8 :u8
    uint16 :u16
    uint32 :u32
    uint64 :u64
    float :f32
    double :f64
    float16 :f16
    string :str
    string :str_req, null: false
    binary :bin
    json :js
    enum :en
    uuid :uid
    date :date
    time :t_ms, unit: :millis
    time :t_us, unit: :micros
    time :t_ns, unit: :nanos
    timestamp :ts_ms, unit: :millis
    timestamp :ts_us, unit: :micros
    timestamp :ts_ns, unit: :nanos
    timestamp :ts_local, unit: :micros, utc: false
    int96 :i96
    decimal :dec_small, precision: 9, scale: 2
    decimal :dec_med, precision: 18, scale: 4
    decimal :dec_large, precision: 38, scale: 10
    decimal :dec_bin, precision: 25, scale: 3, physical: :binary
    fixed :fx, length: 5
  end

  NESTED_SCHEMA = Parakiet::Schema.define do
    int32 :id, null: false
    list :l_nullable, :int32
    list :l_required_el, :string, element_null: false
    list :l_required, :int64, null: false
    list :ll do
      list :element, :int32
    end
    list :lsl, :struct do
      string :name
      list :vals, :double
    end
    map :m_struct, :string, :struct do
      int32 :a
      list :b, :string
    end
    map :m_nullval, :string, :int64
    map :m_reqval, :int32, :string, value_null: false
    struct :s do
      int32 :x
      struct :inner do
        string :y
        list :z, :int32
      end
    end
    struct :s_req, null: false do
      int32 :x, null: false
      string :y
    end
  end

  I64_MIN = -2**63
  I64_MAX = 2**63 - 1
  I32_MIN = -2**31
  I32_MAX = 2**31 - 1

  # Values that exercise the edges of every type. Row i takes SPECIALS[col][i % size] for the first
  # rows and random values afterwards.
  def self.specials
    {
      "bool" => [true, false, nil],
      "bool_req" => [true, false],
      "i8" => [-128, 127, 0, nil],
      "i16" => [-32_768, 32_767, 0, nil],
      "i32" => [I32_MIN, I32_MAX, 0, -1, nil],
      "i64" => [I64_MIN, I64_MAX, 0, -1, nil],
      "u8" => [0, 255, nil],
      "u16" => [0, 65_535, nil],
      "u32" => [0, 2**32 - 1, 2**31, nil],
      "u64" => [0, 2**64 - 1, 2**63, 2**63 + 12_345, nil],
      "f32" => [1.5, -0.0, Float::INFINITY, -Float::INFINITY, Float::NAN, 3.4028234663852886e+38, 1.401298464324817e-45, nil],
      "f64" => [Math::PI, -0.0, 0.0, Float::NAN, Float::INFINITY, -Float::INFINITY, Float::MAX, 5e-324, -1e-300, nil],
      "f16" => [1.5, -2.0, 0.0, -0.0, 65_504.0, Float::INFINITY, -Float::INFINITY, 6.103515625e-05, 5.960464477539063e-08, nil],
      "str" => ["", "héllo", "漢字テキスト", "emoji 🎉", "plain", nil],
      "str_req" => ["", "ÿ", "z"],
      "bin" => ["".b, "\x00\xFF\x80\n".b, (0..255).to_a.pack("C*"), nil],
      "js" => ['{"a":1}', "[]", "null", nil],
      "en" => %w[RED GREEN BLUE] + [nil],
      "uid" => ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff", "123e4567-e89b-12d3-a456-426614174000", nil],
      "date" => [Date.new(1, 1, 1, Date::GREGORIAN), Date.new(9999, 12, 31), Date.new(1970, 1, 1), Date.new(1969, 12, 31), Date.new(2000, 2, 29), nil],
      "t_ms" => [0, 86_399_999, 12_345, nil],
      "t_us" => [0, 86_399_999_999, nil],
      "t_ns" => [0, 86_399_999_999_999, 1, nil],
      "ts_ms" => [Time.at(0).utc, Time.at(-1, 500, :millisecond).utc, Time.utc(1900, 1, 1), Time.utc(2262, 4, 11), Time.utc(1, 1, 1), nil],
      "ts_us" => [Time.at(-86_400_123, 456_789, :microsecond).utc, Time.utc(9999, 12, 31, 23, 59, 59), Time.at(1_700_000_000, 1, :microsecond).utc, nil],
      "ts_ns" => [Time.at(-1, 1, :nanosecond).utc, Time.at(9_223_372_036, 854_775_807, :nanosecond).utc, Time.at(-9_223_372_036, 145_224_192, :nanosecond).utc, nil],
      "ts_local" => [Time.utc(2020, 5, 6, 7, 8, 9), Time.utc(1950, 1, 1), nil],
      "i96" => [Time.at(0).utc, Time.at(-1, 999_999_999, :nanosecond).utc, Time.utc(1700, 1, 1, 0, 0, 0, 1), Time.utc(2200, 12, 31, 23, 59, 59), nil],
      "dec_small" => [BigDecimal("9999999.99"), BigDecimal("-9999999.99"), BigDecimal("0"), BigDecimal("0.01"), nil],
      "dec_med" => [BigDecimal("99999999999999.9999"), BigDecimal("-99999999999999.9999"), BigDecimal("-0.0001"), nil],
      "dec_large" => [BigDecimal("9" * 28 + "." + "9" * 10), BigDecimal("-" + "9" * 28 + "." + "9" * 10), BigDecimal("1e-10"), BigDecimal("0"), nil],
      "dec_bin" => [BigDecimal("9" * 22 + ".999"), BigDecimal("-128.000"), BigDecimal("127"), BigDecimal("-0.001"), BigDecimal("0"), nil],
      "fx" => ["abcde", "\x00\x00\x00\x00\x00".b, "\xFF\xFE\xFD\xFC\xFB".b, nil]
    }
  end

  RANDOM = {
    "bool" => ->(r) { r.rand(2).zero? },
    "i8" => ->(r) { r.rand(-128..127) },
    "i16" => ->(r) { r.rand(-32_768..32_767) },
    "i32" => ->(r) { r.rand(I32_MIN..I32_MAX) },
    "i64" => ->(r) { r.rand(I64_MIN..I64_MAX) },
    "u8" => ->(r) { r.rand(0..255) },
    "u16" => ->(r) { r.rand(0..65_535) },
    "u32" => ->(r) { r.rand(0..2**32 - 1) },
    "u64" => ->(r) { r.rand(0..2**64 - 1) },
    "f32" => ->(r) { [r.rand * 1000 - 500].pack("e").unpack1("e") },
    "f64" => ->(r) { r.rand * 1e6 - 5e5 },
    "f16" => ->(r) { r.rand(-1024..1024) / 4.0 },
    "str" => ->(r) { Array.new(r.rand(0..12)) { %w[a b c é 漢 🎉 z].sample(random: r) }.join },
    "bin" => ->(r) { r.bytes(r.rand(0..10)) },
    "js" => ->(r) { %({"k":#{r.rand(100)}}) },
    "en" => ->(r) { %w[RED GREEN BLUE].sample(random: r) },
    "uid" => ->(r) { r.bytes(16).unpack1("H*").then { |h| "#{h[0, 8]}-#{h[8, 4]}-#{h[12, 4]}-#{h[16, 4]}-#{h[20, 12]}" } },
    "date" => ->(r) { Date.new(1970, 1, 1) + r.rand(-100_000..100_000) },
    "t_ms" => ->(r) { r.rand(0...86_400_000) },
    "t_us" => ->(r) { r.rand(0...86_400_000_000) },
    "t_ns" => ->(r) { r.rand(0...86_400_000_000_000) },
    "ts_ms" => ->(r) { Time.at(0, r.rand(-2**40..2**40), :millisecond).utc },
    "ts_us" => ->(r) { Time.at(0, r.rand(-2**50..2**50), :microsecond).utc },
    "ts_ns" => ->(r) { Time.at(0, r.rand(-2**62..2**62), :nanosecond).utc },
    "ts_local" => ->(r) { Time.at(0, r.rand(-2**50..2**50), :microsecond).utc },
    "i96" => ->(r) { Time.at(0, r.rand(-2**62..2**62), :nanosecond).utc },
    "dec_small" => ->(r) { BigDecimal(r.rand(-999_999_999..999_999_999)) / 100 },
    "dec_med" => ->(r) { BigDecimal(r.rand(-10**18 + 1..10**18 - 1)) / 10_000 },
    "dec_large" => ->(r) { BigDecimal(r.rand(-10**38 + 1..10**38 - 1)) / 10**10 },
    "dec_bin" => ->(r) { BigDecimal(r.rand(-10**25 + 1..10**25 - 1)) / 1000 },
    "fx" => ->(r) { r.bytes(5) }
  }.freeze

  def self.all_types_rows(n, seed: 1)
    rng = Random.new(seed)
    sp = specials
    Array.new(n) do |i|
      row = { "id" => i }
      ALL_TYPES_SCHEMA.fields.each do |f|
        next if f.name == "id"
        list = sp.fetch(f.name)
        row[f.name] = if i < 12
          list[i % list.size]
        elsif f.optional && rng.rand(5).zero?
          nil
        else
          gen = RANDOM[f.name.sub(/_req\z/, "")]
          gen.call(rng)
        end
      end
      row
    end
  end

  def self.nested_rows(n, seed: 2)
    rng = Random.new(seed)
    fixed = [
      { "id" => 0, "l_nullable" => nil, "l_required_el" => nil, "l_required" => [], "ll" => nil, "lsl" => nil,
        "m_struct" => nil, "m_nullval" => nil, "m_reqval" => nil, "s" => nil, "s_req" => { "x" => 0, "y" => nil } },
      { "id" => 1, "l_nullable" => [], "l_required_el" => [], "l_required" => [1], "ll" => [], "lsl" => [],
        "m_struct" => {}, "m_nullval" => {}, "m_reqval" => {}, "s" => { "x" => nil, "inner" => nil }, "s_req" => { "x" => 1, "y" => "" } },
      { "id" => 2, "l_nullable" => [nil], "l_required_el" => [""], "l_required" => [I64_MIN, I64_MAX], "ll" => [nil, [], [nil], [1, nil, 2]],
        "lsl" => [nil, { "name" => nil, "vals" => nil }, { "name" => "n", "vals" => [] }, { "name" => "é", "vals" => [nil, 1.5, Float::NAN] }],
        "m_struct" => { "a" => nil, "b" => { "a" => nil, "b" => nil }, "c" => { "a" => 1, "b" => [] }, "d" => { "a" => 2, "b" => ["x", nil] } },
        "m_nullval" => { "k" => nil, "k2" => 5 }, "m_reqval" => { 1 => "one", -1 => "" },
        "s" => { "x" => 1, "inner" => { "y" => nil, "z" => nil } }, "s_req" => { "x" => -1, "y" => "why" } },
      { "id" => 3, "l_nullable" => [nil, nil, nil], "l_required_el" => %w[a b c], "l_required" => [0] * 20, "ll" => [[1], [2, 3], [], nil],
        "lsl" => [{ "name" => "x", "vals" => [1.0] }], "m_struct" => { "" => { "a" => 3, "b" => [nil] } },
        "m_nullval" => { "a" => 1 }, "m_reqval" => { 7 => "seven" },
        "s" => { "x" => nil, "inner" => { "y" => "y", "z" => [] } }, "s_req" => { "x" => 3, "y" => nil } },
      { "id" => 4, "l_nullable" => nil, "l_required_el" => nil, "l_required" => [], "ll" => [[]], "lsl" => [nil],
        "m_struct" => { "only" => nil }, "m_nullval" => nil, "m_reqval" => {},
        "s" => { "x" => 5, "inner" => { "y" => "q", "z" => [nil, 1] } }, "s_req" => { "x" => 4, "y" => "" } }
    ]
    rows = fixed.first(n)
    (fixed.size...n).each do |i|
      maybe = ->(v) { rng.rand(4).zero? ? nil : v }
      int = -> { rng.rand(-1000..1000) }
      str = -> { %w[a bb ccc é 漢字 xyz].sample(random: rng) }
      arr = ->(max, &b) { Array.new(rng.rand(0..max)) { b.call } }
      rows << {
        "id" => i,
        "l_nullable" => maybe.(arr.(4) { maybe.(int.()) }),
        "l_required_el" => maybe.(arr.(3) { str.() }),
        "l_required" => arr.(5) { rng.rand(I64_MIN..I64_MAX) },
        "ll" => maybe.(arr.(3) { maybe.(arr.(3) { maybe.(int.()) }) }),
        "lsl" => maybe.(arr.(3) { maybe.({ "name" => maybe.(str.()), "vals" => maybe.(arr.(3) { maybe.(rng.rand) }) }) }),
        "m_struct" => maybe.(arr.(3) { [str.(), maybe.({ "a" => maybe.(int.()), "b" => maybe.(arr.(2) { maybe.(str.()) }) })] }.to_h),
        "m_nullval" => maybe.(arr.(4) { [str.(), maybe.(int.())] }.to_h),
        "m_reqval" => maybe.(arr.(4) { [int.(), str.()] }.to_h),
        "s" => maybe.({ "x" => maybe.(int.()), "inner" => maybe.({ "y" => maybe.(str.()), "z" => maybe.(arr.(3) { maybe.(int.()) }) }) }),
        "s_req" => { "x" => int.(), "y" => maybe.(str.()) }
      }
    end
    rows
  end

  def write_to_string(schema, rows, **options)
    io = StringIO.new("".b)
    w = Parakiet::Writer.new(io, schema, **options)
    rows.each { |r| w << r }
    w.close
    io.string
  end

  def reader_for(bytes)
    Parakiet::Reader.new(StringIO.new(bytes))
  end

  def canonical_lines(schema, rows)
    rows.map { |r| Canonical.dump(Canonical.row(schema, r)) }
  end

  # Asserts that +rows+ read back from +bytes+ equal +expected+, compared in canonical form
  def assert_roundtrip(schema, expected, bytes, msg = nil)
    reader = reader_for(bytes)
    actual = reader.rows
    assert_equal expected.size, reader.num_rows, "num_rows #{msg}"
    exp = canonical_lines(schema, expected)
    act = canonical_lines(reader.schema, actual)
    exp.each_with_index do |e, i|
      assert_equal e, act[i], "row #{i} #{msg}"
    end
    assert_equal exp.size, act.size, msg
    actual
  end

  # Walks the pages of a column chunk, yielding [header, body_bytes]
  def each_page(bytes, chunk)
    meta = chunk.meta_data
    start = [meta.dictionary_page_offset, meta.data_page_offset].compact.min
    buf = bytes.byteslice(start, meta.total_compressed_size)
    pos = 0
    while pos < buf.bytesize
      header, pos = Parakiet::Format::PageHeader.decode(buf, pos)
      body = buf.byteslice(pos, header.compressed_page_size)
      pos += header.compressed_page_size
      yield header, body
    end
    assert_equal buf.bytesize, pos, "pages must exactly fill total_compressed_size"
  end
end

# Schema and data for the explicit encodings tests
module WriterTestSchemas
  I32_MIN = WriterHelpers::I32_MIN
  I32_MAX = WriterHelpers::I32_MAX
  I64_MIN = WriterHelpers::I64_MIN
  I64_MAX = WriterHelpers::I64_MAX

  ENCODING_SCHEMA = Parakiet::Schema.define do
    int32 :i32
    int64 :i64, null: false
    int32 :i32_bss
    int64 :i64_bss
    float :f32
    double :f64
    string :s_dlba
    string :s_dba
    binary :b_dba
    fixed :fx_dba, length: 4
    fixed :fx_bss, length: 3
    decimal :dec_bss, precision: 30, scale: 2
    boolean :bool_rle
    boolean :bool_rle_req, null: false
    list :l_delta, :int64
    date :d_delta
    uint64 :u64_delta
  end

  ENCODINGS = {
    "i32" => :delta_binary_packed, "i64" => :delta_binary_packed, "i32_bss" => :byte_stream_split,
    "i64_bss" => :byte_stream_split, "f32" => :byte_stream_split, "f64" => :byte_stream_split,
    "s_dlba" => :delta_length_byte_array, "s_dba" => :delta_byte_array, "b_dba" => :delta_byte_array,
    "fx_dba" => :delta_byte_array, "fx_bss" => :byte_stream_split, "dec_bss" => :byte_stream_split,
    "bool_rle" => :rle, "bool_rle_req" => :rle, "l_delta.list.element" => :delta_binary_packed,
    "d_delta" => :delta_binary_packed, "u64_delta" => :delta_binary_packed
  }.freeze

  def self.encoding_rows(n)
    rng = Random.new(9)
    Array.new(n) do |i|
      maybe = ->(v) { (i % 7 == 3) ? nil : v }
      {
        "i32" => maybe.([I32_MIN, I32_MAX, 0, rng.rand(-100..100)][i % 4]),
        "i64" => [I64_MIN, I64_MAX, 0, rng.rand(I64_MIN..I64_MAX)][i % 4],
        "i32_bss" => maybe.(rng.rand(I32_MIN..I32_MAX)),
        "i64_bss" => maybe.(rng.rand(I64_MIN..I64_MAX)),
        "f32" => maybe.([1.5, -0.0, Float::NAN, Float::INFINITY, 0.25][i % 5]),
        "f64" => maybe.([rng.rand, -0.0, Float::NAN, -Float::INFINITY][i % 4]),
        "s_dlba" => maybe.(["", "é" * (i % 5), "abc#{i}"][i % 3]),
        "s_dba" => maybe.(["prefix/#{i / 3}/x", "", "prefix/"][i % 3]),
        "b_dba" => maybe.(rng.bytes(i % 6)),
        "fx_dba" => maybe.(["aaaa", "aaab", "\x00\x00\x00\x00".b, "zzzz"][i % 4]),
        "fx_bss" => maybe.(rng.bytes(3)),
        "dec_bss" => maybe.(BigDecimal(rng.rand(-10**27..10**27)) / 100),
        "bool_rle" => maybe.(i % 11 < 8),
        "bool_rle_req" => i.odd?,
        "l_delta" => maybe.(Array.new(i % 4) { |j| j == 1 ? nil : rng.rand(I64_MIN..I64_MAX) }),
        "d_delta" => maybe.(Date.new(2000, 1, 1) + i * 1000 - 20_000),
        "u64_delta" => maybe.([2**64 - 1, 0, 2**63][i % 3])
      }
    end
  end
end
