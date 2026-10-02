# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "open3"
require "tmpdir"
require "json"

# XXH64, split block bloom filters, and writing/reading them in Parquet files
class BloomFilterTest < Minitest::Test
  include WriterHelpers

  BF = Herringbone::BloomFilter

  # Row groups whose bloom filter for +column+ may hold +value+ (row groups without one included)
  def may_contain(reader, column, value)
    (0...reader.row_groups.size).select do |g|
      filter = reader.bloom_filter(g, column)
      filter.nil? || filter.might_contain?(value)
    end
  end

  # One row group's values, column by column
  def row_group_data(reader, g, columns: nil)
    first = reader.row_groups.first(g).sum(&:num_rows)
    reader.read(as: :columns, columns: columns, from: first, limit: reader.row_groups[g].num_rows)
  end
  XX = Herringbone::XXHash
  PARQUET_TESTING = File.join(FIXTURES_DIR, "parquet-testing")
  ARROW_FIXTURE = File.join(FIXTURES_DIR, "generated", "bloom_filters_arrow.parquet")

  # "" is the published XXH64 test vector (0xEF46DB3751D8E999); the others were computed with the
  # reference implementation (python-xxhash 3.x / xxHash 0.8, seed 0) and cover every tail length
  # path (<32 bytes, 4-byte and 1-byte tails, 32-byte stripes)
  VECTORS = {
    "" => 0xEF46DB3751D8E999,
    "a" => 15_154_266_338_359_012_955,
    "abc" => 4_952_883_123_889_572_249,
    "12345678" => 15_190_693_258_008_001_866,
    "hello world" => 5_020_219_685_658_847_592,
    "0123456789abcdefghij" => 5_026_792_210_645_229_750,
    (0...32).to_a.pack("C*") => 14_696_824_831_085_589_172,
    (0...100).to_a.pack("C*") => 7_692_681_977_284_421_015,
    "x" * 1000 => 5_528_630_022_282_608_865
  }.freeze

  def test_xxh64_vectors
    VECTORS.each do |input, expected|
      assert_equal expected, XX.xxh64(input.b), "XXH64 of #{input.bytesize} bytes"
    end
  end

  def test_xxh64_integer_fast_paths_match_bytes
    rng = Random.new(3)
    200.times do
      q = rng.rand(2**64)
      assert_equal XX.xxh64([q].pack("Q<")), XX.xxh64_u64(q)
      l = rng.rand(2**32)
      assert_equal XX.xxh64([l].pack("L<")), XX.xxh64_u32(l)
    end
    assert_equal XX.xxh64([-1].pack("q<")), BF.hash_physical(-1, Herringbone::Format::Type::INT64)
    assert_equal XX.xxh64([-5].pack("l<")), BF.hash_physical(-5, Herringbone::Format::Type::INT32)
    assert_equal XX.xxh64([1.5].pack("e")), BF.hash_physical(1.5, Herringbone::Format::Type::FLOAT)
    assert_equal XX.xxh64([-2.25].pack("E")), BF.hash_physical(-2.25, Herringbone::Format::Type::DOUBLE)
    assert_equal XX.xxh64([7, 2_440_588].pack("Q<L<")), BF.hash_physical([7, 2_440_588], Herringbone::Format::Type::INT96)
  end

  def with_xxhash_backend(backend)
    XX.backend = backend
    yield
  ensure
    XX.backend = nil
  end

  # The pure-Ruby version is checked directly, whichever backend is in use
  def test_pure_ruby_xxh64_vectors
    VECTORS.each { |input, expected| assert_equal expected, XX.ruby_xxh64(input.b) }
    with_xxhash_backend(:ruby) do
      assert_equal :ruby, XX.backend
      VECTORS.each { |input, expected| assert_equal expected, XX.xxh64(input.b) }
      assert_equal XX.xxh64([2**64 - 5].pack("Q<")), XX.xxh64_u64(-5)
      assert_equal XX.xxh64([2**32 - 5].pack("L<")), XX.xxh64_u32(-5)
    end
  end

  def test_backends_give_identical_hashes
    skip "the xxhash gem is not installed" unless XX.native_available?
    rng = Random.new(11)
    strings = Array.new(300) { |i| rng.bytes(i % 100) } + ["héllo wörld", "\u{1F600}" * 9, "x" * 1000]
    lanes = Array.new(300) { rng.rand(2**64) } + [0, 1, 2**62, 2**63, 2**64 - 1, -1, -(2**63)]
    words = Array.new(300) { rng.rand(2**32) } + [0, 2**31, 2**32 - 1, -1, -(2**31)]
    results = %i[ruby native].map do |backend|
      with_xxhash_backend(backend) do
        assert_equal backend, XX.backend
        [strings.map { |s| XX.xxh64(s) }, XX.xxh64_all(strings), lanes.map { |v| XX.xxh64_u64(v) },
          XX.xxh64_u64_all(lanes), words.map { |v| XX.xxh64_u32(v) }, XX.xxh64_u32_all(words)]
      end
    end
    assert_equal results[0], results[1]
    assert_equal results[0][0], results[0][1]
    assert_equal results[0][2], results[0][3]
    assert_equal results[0][4], results[0][5]
  end

  def test_backend_selection
    with_xxhash_backend(:ruby) { assert_equal :ruby, XX.backend }
    with_xxhash_backend(nil) { assert_equal XX.native_available? ? :native : :ruby, XX.backend }
    if XX.native_available?
      with_xxhash_backend(:native) { assert_equal :native, XX.backend }
    else
      assert_raises(Herringbone::UnsupportedError) { XX.backend = :native }
    end
    assert_raises(ArgumentError) { XX.backend = :fast }
  ensure
    XX.backend = nil
  end

  def test_insert_hashes_matches_insert_hash
    hashes = Array.new(2000) { |i| XX.xxh64("v#{i}") } + [0, 2**64 - 1]
    one_by_one = BF.new(1024)
    hashes.each { |h| one_by_one.insert_hash(h) }
    assert_equal one_by_one.bitset, BF.new(1024).insert_hashes(hashes).bitset
    assert(hashes.all? { |h| one_by_one.might_contain_hash?(h) })
  end

  # The writer hashes distinct physical values once; floats are compared by their bytes
  def test_hash_physical_all_distinct
    t = Herringbone::Format::Type
    assert_equal BF.hash_physical_all([1, 2], t::INT64), BF.hash_physical_all([1, 2, 1, 2], t::INT64, distinct: true)
    assert_equal BF.hash_physical_all(%w[a b], t::BYTE_ARRAY), BF.hash_physical_all(%w[a b a], t::BYTE_ARRAY, distinct: true)
    nan2 = [0x7FF8_0000_0000_0001].pack("Q<").unpack1("E")
    [t::FLOAT, t::DOUBLE].each do |type|
      values = [0.0, -0.0, Float::NAN, 1.5, 0.0, 1.5]
      values << nan2 if type == t::DOUBLE
      hashes = BF.hash_physical_all(values, type, distinct: true)
      assert_equal values.map { |v| BF.hash_physical(v, type) }.uniq, hashes
      assert_equal ((type == t::DOUBLE) ? 5 : 4), hashes.size
    end
    rows = [0.0, -0.0, 0.0, Float::NAN].map { |v| {d: v} }
    reader = reader_for(write_to_string(Herringbone::Schema.define { |s| s.double :d }, rows, bloom_filters: true))
    [0.0, -0.0, Float::NAN].each { |v| assert_equal [0], may_contain(reader, "d", v), v.inspect }
  end

  def test_optimal_num_bytes
    assert_equal 128, BF.optimal_num_bytes(100, 0.01) # same size Arrow C++ picks for ndv 100
    assert_equal 32, BF.optimal_num_bytes(1, 0.5)
    assert_equal 1024 * 1024, BF.optimal_num_bytes(10_000_000, 0.01)
    assert_equal 16 * 1024 * 1024, BF.optimal_num_bytes(10_000_000, 0.01, max_bytes: 128 * 1024 * 1024)
    assert_equal 64 * 1024, BF.optimal_num_bytes(10_000_000, 0.01, max_bytes: 100_000) # rounded down to a power of two
    [[1000, 0.1], [12_345, 0.05], [99_999, 0.001]].each do |ndv, fpp|
      n = BF.optimal_num_bytes(ndv, fpp)
      assert_equal 0, n & (n - 1), "power of two"
      assert_operator n * 8, :>=, -8 * ndv / Math.log(1 - fpp**(1.0 / 8))
    end
    assert_raises(ArgumentError) { BF.optimal_num_bytes(10, 0) }
    assert_raises(ArgumentError) { BF.optimal_num_bytes(10, 1.5) }
  end

  def test_no_false_negatives_and_fpp_close_to_requested
    ndv = 100_000
    fpp = 0.01
    # Exactly the size the spec formula asks for (a multiple of the block size, not a power of
    # two), so the measured rate can be compared with the requested one
    bytes = ((-8 * ndv / Math.log(1 - fpp**(1.0 / 8))) / 8 / 32).ceil * 32
    filter = BF.new(bytes)
    ndv.times { |i| filter.insert("present-#{i}") }
    assert(ndv.times.all? { |i| filter.might_contain?("present-#{i}") }, "no false negatives")
    false_positives = ndv.times.count { |i| filter.might_contain?("absent-#{i}") }
    rate = false_positives.fdiv(ndv)
    # The spec's sizing formula treats the bitset as uniform; with values spread over blocks
    # (Poisson with mean ndv / blocks) the expected rate of a split block filter is a bit higher
    lambda = ndv.fdiv(bytes / 32)
    term = Math.exp(-lambda)
    expected = (0..200).sum do |k|
      term *= lambda / k if k.positive?
      term * (1 - (31.0 / 32)**k)**8
    end
    assert_in_delta expected, rate, expected * 0.15, "measured false positive rate #{rate}, expected #{expected}"
    assert_operator rate, :<, 2 * fpp

    # The power-of-two size the writer uses only lowers the rate
    sized = BF.new(BF.optimal_num_bytes(ndv, fpp))
    ndv.times { |i| sized.insert("present-#{i}") }
    assert_operator ndv.times.count { |i| sized.might_contain?("absent-#{i}") }.fdiv(ndv), :<, rate
  end

  def test_encode_decode
    filter = BF.new(64)
    %w[a b c].each { |v| filter.insert(v) }
    bytes = filter.encode
    header, pos = Herringbone::Format::BloomFilterHeader.decode(bytes)
    assert_equal 64, header.num_bytes
    refute_nil header.algorithm.block
    refute_nil header.hash_function.xxhash
    refute_nil header.compression.uncompressed
    assert_equal 64, bytes.bytesize - pos
    decoded = BF.decode(bytes)
    assert_equal filter.bitset, decoded.bitset
    assert(%w[a b c].all? { |v| decoded.might_contain?(v) })
    refute decoded.might_contain?("zzz")
    assert_raises(ArgumentError) { BF.new(33) }
    assert_raises(ArgumentError) { filter.might_contain?(1) }
    assert_raises(ArgumentError) { filter.might_contain?(nil) }
  end

  def test_bitset_size_is_validated
    assert_raises(ArgumentError) { BF.new(bitset: "\0".b * 33) }
    assert_raises(ArgumentError) { BF.new(bitset: "\0".b * 31) }
    assert_raises(ArgumentError) { BF.new(bitset: "".b) }
    assert_equal 64, BF.new(bitset: "\0".b * 64).num_bytes
  end

  def test_supported_header_is_a_boolean
    header = Herringbone::Format::BloomFilterHeader.decode(BF.new(32).encode).first
    assert_same true, BF.supported_header?(header)
    header.compression = nil
    assert_same true, BF.supported_header?(header)
    assert_same false, BF.supported_header?(header.dup.tap { |h| h.algorithm = nil })
    header.hash_function = nil
    assert_same false, BF.supported_header?(header)
    assert_same false, BF.supported_header?(Herringbone::Format::BloomFilterHeader.new)
  end

  def test_corrupt_filter_header_is_a_format_error
    bytes = write_to_string(Herringbone::Schema.define { |s| s.int64 :id }, [{id: 1}], bloom_filters: true).dup
    offset = reader_for(bytes).row_groups[0].columns[0].meta_data.bloom_filter_offset
    bytes[offset, 4] = "\xFF".b * 4
    reader = reader_for(bytes)
    assert_raises(Herringbone::FormatError) { reader.bloom_filter(0, "id") }
    reader.row_groups[0].columns[0].meta_data.bloom_filter_length = nil
    assert_raises(Herringbone::FormatError) { reader.bloom_filter(0, "id") }
    assert_equal [{"id" => 1}], reader.read(where: {id: 1}) # where: treats it as "may match"
  end

  def test_hand_computed_bits
    # A single block: the word bits come straight from the spec's salts
    filter = BF.new(32)
    h = XX.xxh64("x")
    filter.insert("x")
    words = filter.bitset.unpack("V*")
    lo = h & 0xFFFF_FFFF
    expected = BF::SALT.map { |salt| 1 << (((lo * salt) & 0xFFFF_FFFF) >> 27) }
    assert_equal expected, words
  end

  # --- parquet-testing fixtures (written by parquet-mr and parquet-rs) ---

  def test_parquet_testing_fixtures
    %w[data_index_bloom_encoding_stats data_index_bloom_encoding_with_length].each do |name|
      File.open(File.join(PARQUET_TESTING, "#{name}.parquet"), "rb") do |f|
        reader = Herringbone::Reader.new(f)
        values = reader.read(as: :columns, columns: ["String"])["String"].compact
        assert_equal 14, values.size
        filter = reader.bloom_filter(0, "String")
        refute_nil filter, name
        values.each { |v| assert filter.might_contain?(v), "#{name}: #{v.inspect}" }
        %w[foo bar nope zzz Hello!].each { |v| refute filter.might_contain?(v), "#{name}: #{v.inspect}" }
        assert_equal [0], may_contain(reader, "String", "Hello")
        assert_equal [], may_contain(reader, "String", "nope")
      end
    end
  end

  def test_parquet_testing_fixture_without_length
    File.open(File.join(PARQUET_TESTING, "data_index_bloom_encoding_stats.parquet"), "rb") do |f|
      reader = Herringbone::Reader.new(f)
      assert_nil reader.row_groups[0].columns[0].meta_data.bloom_filter_length
      assert_equal 1024, reader.bloom_filter(0, "String").num_bytes
      assert_equal 1024, reader.bloom_filter(0, ["String"]).num_bytes
    end
  end

  # --- Arrow C++ (pyarrow) fixture, see test/fixtures/generate_fixtures.py ---

  def test_arrow_fixture
    File.open(ARROW_FIXTURE, "rb") do |f|
      reader = Herringbone::Reader.new(f)
      assert_equal 2, reader.row_groups.size
      reader.row_groups.size.times do |g|
        data = row_group_data(reader, g)
        reader.schema.columns.each do |col|
          filter = reader.bloom_filter(g, col.dotted_path)
          refute_nil filter, col.dotted_path
          data.fetch(col.dotted_path).compact.each do |v|
            assert filter.might_contain?(v), "row group #{g}, #{col.dotted_path}: #{v.inspect}"
          end
        end
      end
      assert_equal [1], may_contain(reader, "str", "str-150")
      assert_equal [0], may_contain(reader, "i64", -5_000_000_000)
      assert_equal [1], may_contain(reader, "i32", 200)
      assert_equal [0], may_contain(reader, "f32", -7.0)
      assert_equal [1], may_contain(reader, "f64", 75)
      assert_equal [0], may_contain(reader, "date", Date.new(2020, 1, 5))
      assert_equal [1], may_contain(reader, "ts", Time.utc(2020, 1, 1, 1, 41, 40))
      assert_equal [1], may_contain(reader, "dec_small", BigDecimal("101"))
      assert_equal [0], may_contain(reader, "dec_big", BigDecimal("1234.567"))
      assert_equal [0, 1], may_contain(reader, "dict_str", "cat-3")
      absent = {"str" => "str-x", "i64" => 1, "i32" => 1, "f64" => 0.3, "date" => Date.new(1999, 1, 1),
                "dec_big" => BigDecimal("0.001"), "dict_str" => "dog", "fixed" => "\xAA".b * 16}
      absent.each { |col, v| assert_equal [], may_contain(reader, col, v), col }
    end
  end

  # --- Writer ---

  def test_round_trip_all_types
    bytes = write_to_string(ALL_TYPES_SCHEMA, rows = WriterHelpers.all_types_rows(300), bloom_filters: true, row_group_rows: 100)
    reader = reader_for(bytes)
    assert_equal 3, reader.row_groups.size
    reader.schema.columns.each do |col|
      supported = col.type != Herringbone::Format::Type::BOOLEAN
      reader.row_groups.size.times do |g|
        filter = reader.bloom_filter(g, col.dotted_path)
        unless supported
          assert_nil filter, col.dotted_path
          next
        end
        refute_nil filter, col.dotted_path
        # Values as read back, and as originally written (Dates, Times, BigDecimals, UUID Strings...)
        read_back = row_group_data(reader, g, columns: [col.dotted_path]).fetch(col.dotted_path).compact
        written = rows[g * 100, 100].map { |r| r[col.dotted_path] }.compact
        (read_back + written).each do |v|
          assert filter.might_contain?(v), "row group #{g}, #{col.dotted_path}: #{v.inspect}"
        end
      end
    end
  end

  def test_logical_values_and_absent_values
    schema = Herringbone::Schema.define do |s|
      s.int32 :i32
      s.int64 :i64
      s.uint64 :u64
      s.float :f32
      s.double :f64
      s.string :str
      s.binary :bin
      s.fixed :fx, length: 4
      s.uuid :uid
      s.date :date
      s.timestamp :ts, unit: :micros
      s.decimal :dec, precision: 9, scale: 2
      s.decimal :dec_fixed, precision: 30, scale: 3
    end
    n = 1000
    rows = Array.new(n) do |i|
      {
        "i32" => i * 3, "i64" => i * 1_000_000_007, "u64" => 2**63 + i, "f32" => i * 0.5, "f64" => i * 0.25,
        "str" => "s#{i}", "bin" => [i].pack("N"), "fx" => [i].pack("N"),
        "uid" => format("00000000-0000-4000-8000-%012d", i), "date" => Date.new(2000, 1, 1) + i,
        "ts" => Time.utc(2020, 1, 1) + i, "dec" => BigDecimal(i) / 100, "dec_fixed" => BigDecimal(i) / 1000
      }
    end
    absent = {
      "i32" => 1, "i64" => 5, "u64" => 12, "f32" => 0.25, "f64" => 0.1, "str" => "nope", "bin" => "nope",
      "fx" => "nope", "uid" => "ffffffff-0000-4000-8000-000000000000", "date" => Date.new(1999, 1, 1),
      "ts" => Time.utc(2019, 1, 1), "dec" => BigDecimal("0.005") + 100, "dec_fixed" => BigDecimal("-1")
    }
    bytes = write_to_string(schema, rows, bloom_filters: true, dictionary: false)
    reader = reader_for(bytes)
    rows.first(200).each do |row|
      row.each { |name, v| assert_equal [0], may_contain(reader, name, v), "#{name}: #{v.inspect}" }
    end
    # 1000 distinct values at fpp 0.01: an absent value is rejected, except for a rare false positive
    rejected = absent.count { |name, v| may_contain(reader, name, v).empty? }
    assert_operator rejected, :>=, absent.size - 1
    assert_raises(ArgumentError) { may_contain(reader, "i32", "not a number") }
    assert_raises(ArgumentError) { may_contain(reader, "nope", 1) }
  end

  def test_sizes_from_counted_distinct_values_or_ndv
    schema = Herringbone::Schema.define { |s|
      s.int64 :id, null: false
      s.string :cat
      s.string :s
    }
    rows = Array.new(5000) { |i| {id: i, cat: "c#{i % 10}", s: "s#{i}"} }
    bytes = write_to_string(schema, rows, bloom_filters: {"id" => {ndv: 100_000, fpp: 0.05}, "cat" => true, "s" => {fpp: 0.1}})
    reader = reader_for(bytes)
    assert_equal BF.optimal_num_bytes(100_000, 0.05), reader.bloom_filter(0, "id").num_bytes
    assert_equal BF.optimal_num_bytes(10, 0.01), reader.bloom_filter(0, "cat").num_bytes # dictionary size
    assert_equal BF.optimal_num_bytes(5000, 0.1), reader.bloom_filter(0, "s").num_bytes
    assert_equal reader.row_groups[0].columns[0].meta_data.bloom_filter_length,
      reader.bloom_filter(0, "id").encode.bytesize
  end

  def test_max_bytes_and_default_off
    rows = Array.new(2000) { |i| {id: i} }
    bytes = write_to_string(Herringbone::Schema.define { |s| s.int64 :id }, rows, bloom_filters: {id: {max_bytes: 256}})
    assert_equal 256, reader_for(bytes).bloom_filter(0, "id").num_bytes
    plain = reader_for(write_to_string(Herringbone::Schema.define { |s| s.int64 :id }, rows))
    assert_nil plain.bloom_filter(0, "id")
    assert_nil plain.row_groups[0].columns[0].meta_data.bloom_filter_offset
    assert_equal [0], may_contain(plain, "id", -1) # no filter: may contain anything
  end

  def test_nested_and_null_columns
    schema = Herringbone::Schema.define do |s|
      s.list :tags, :string
      s.struct :s do |nested|
        nested.int32 :x
      end
      s.string :empty
    end
    rows = Array.new(50) { |i| {tags: ["t#{i}", "u#{i}"], s: {x: i}, empty: nil} }
    reader = reader_for(write_to_string(schema, rows, bloom_filters: ["tags.list.element", "s.x", "empty"]))
    assert_equal [0], may_contain(reader, "tags.list.element", "u7")
    assert_equal [0], may_contain(reader, %w[s x], 49)
    assert_equal [], may_contain(reader, "tags.list.element", "v7")
    assert_equal 32, reader.bloom_filter(0, "empty").num_bytes
    assert_equal [], may_contain(reader, "empty", "anything")
  end

  def test_options_are_validated
    schema = Herringbone::Schema.define { |s|
      s.boolean :b
      s.int32 :i
    }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: ["b"]) }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: ["nope"]) }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: {"i" => {ndv: 0}}) }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: {"i" => {fpp: 1}}) }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: {"i" => {size: 1}}) }
    assert_raises(ArgumentError) { write_to_string(schema, [], bloom_filters: {"i" => 5}) }
    # true skips BOOLEAN columns; false/nil entries are ignored
    reader = reader_for(write_to_string(schema, [{b: true, i: 1}], bloom_filters: true))
    assert_nil reader.bloom_filter(0, "b")
    refute_nil reader.bloom_filter(0, "i")
    reader = reader_for(write_to_string(schema, [{b: true, i: 1}], bloom_filters: {"i" => false}))
    assert_nil reader.bloom_filter(0, "i")
  end

  # Row group chunks stay contiguous; each row group's bloom filters follow its chunks in column
  # order; page indexes still sit right before the footer
  def test_file_layout
    bytes = write_to_string(ALL_TYPES_SCHEMA, WriterHelpers.all_types_rows(40), bloom_filters: true, row_group_rows: 13)
    md = reader_for(bytes).file_metadata
    assert_equal 4, md.row_groups.size
    offset = 4
    md.row_groups.each do |rg|
      assert_equal offset, rg.file_offset
      rg.columns.each do |c|
        assert_equal offset, c.file_offset
        assert_equal offset, [c.meta_data.dictionary_page_offset, c.meta_data.data_page_offset].compact.min
        offset += c.meta_data.total_compressed_size
      end
      assert_equal rg.total_compressed_size, offset - rg.file_offset
      rg.columns.each do |c|
        m = c.meta_data
        next if m.type == Herringbone::Format::Type::BOOLEAN
        assert_equal offset, m.bloom_filter_offset
        offset += m.bloom_filter_length
      end
    end
    index_ranges = md.row_groups.flat_map(&:columns).flat_map do |c|
      [[c.column_index_offset, c.column_index_length], [c.offset_index_offset, c.offset_index_length]]
    end.select(&:first).sort
    index_ranges.each do |start, length|
      assert_equal offset, start
      offset += length
    end
    assert_equal bytes.bytesize - 8 - bytes.byteslice(-8, 4).unpack1("V"), offset
  end

  # --- Other implementations (HERRINGBONE_PYTHON with pyarrow / datafusion) ---

  def python_with(mod)
    python = ENV["HERRINGBONE_PYTHON"]
    skip "HERRINGBONE_PYTHON is not set" if python.nil? || python.empty?
    _, status = Open3.capture2e(python, "-c", "import #{mod}")
    skip "#{mod} is not installed for #{python}" unless status.success?
    python
  end

  def test_pyarrow_reads_files_with_bloom_filters
    python = python_with("pyarrow")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bloom.parquet")
      rows = Array.new(3000) { |i| {id: i, s: "value-#{i}"} }
      File.open(path, "wb") do |f|
        Herringbone.write(f, rows, schema: Herringbone::Schema.define { |s|
          s.int64 :id
          s.string :s
        }, bloom_filters: true, row_group_rows: 1000)
      end
      script = <<~PY
        import json, sys
        import pyarrow.parquet as pq
        t = pq.read_table(sys.argv[1])
        md = pq.read_metadata(sys.argv[1])
        locs = [[[md.row_group(g).column(c).bloom_filter_offset, md.row_group(g).column(c).bloom_filter_length]
                 for c in range(md.num_columns)] for g in range(md.num_row_groups)]
        print(json.dumps({"rows": t.num_rows, "sum": sum(t.column("id").to_pylist()), "locs": locs}))
      PY
      out, err, st = Open3.capture3(python, "-c", script, path)
      assert st.success?, err
      result = JSON.parse(out)
      assert_equal 3000, result["rows"]
      assert_equal 2999 * 3000 / 2, result["sum"]
      File.open(path, "rb") do |f|
        expected = Herringbone::Reader.new(f).row_groups.map do |rg|
          rg.columns.map { |c| [c.meta_data.bloom_filter_offset, c.meta_data.bloom_filter_length] }
        end
        assert_equal expected, result["locs"]
      end
    end
  end

  # DataFusion (arrow-rs) skips row groups whose bloom filter rules out an equality predicate
  def test_datafusion_prunes_row_groups_with_bloom_filters
    python = python_with("datafusion")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bloom.parquet")
      # Values are spread so every row group's min/max covers the probe: only the bloom filter can prune
      rows = Array.new(30_000) { |i| {id: (i * 7919) % 30_000, s: "key-#{(i * 7919) % 30_000}"} }
      File.open(path, "wb") do |f|
        Herringbone.write(f, rows, schema: Herringbone::Schema.define { |s|
          s.int64 :id
          s.string :s
        }, bloom_filters: true, row_group_rows: 10_000)
      end
      script = File.join(__dir__, "support", "datafusion_bloom_prune.py")
      out, err, st = Open3.capture3(python, script, path, "select count(*) as c from t where s = 'key-15000x'")
      assert st.success?, err
      result = JSON.parse(out)
      assert_equal 0, result["count"]
      assert_equal 3, result["bloom_filter_row_groups_total"]
      assert_equal 0, result["bloom_filter_row_groups_matched"], "all row groups pruned by their bloom filters"

      out, err, st = Open3.capture3(python, script, path, "select count(*) as c from t where s = 'key-15000'")
      assert st.success?, err
      result = JSON.parse(out)
      assert_equal 1, result["count"]
      assert_equal 1, result["bloom_filter_row_groups_matched"]

      out, err, st = Open3.capture3(python, script, path, "select count(*) as c from t where id = 12345")
      assert st.success?, err
      result = JSON.parse(out)
      assert_equal 1, result["count"]
      assert_equal 1, result["bloom_filter_row_groups_matched"]
    end
  end
end
