# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

begin
  require "numo/narray"
  NUMO_AVAILABLE = true
rescue LoadError
  NUMO_AVAILABLE = false
end

# read(as: :numo) / each_batch(as: :numo), checked against as: :columns. Comparisons never use
# assert_equal on whole columns: on a mismatch Minitest would pretty-print a diff of every value,
# which takes minutes on the large fixtures. #assert_numo reports the first differing row.
class NumoReadTest < Minitest::Test
  FILES = Dir[File.join(FIXTURES_DIR, "{parquet-testing,generated}", "*.parquet")].sort
  NumoColumns = Herringbone::Reader::NumoColumns

  def setup
    skip "numo-narray-alt (or numo-narray) is not installed" unless NUMO_AVAILABLE
  end

  def with_reader(path, **opts, &block)
    File.open(path, "rb") { |f| block.call(Herringbone::Reader.new(f, **opts)) }
  end

  def write(rows, schema = nil, **opts)
    io = StringIO.new("".b)
    if schema
      Herringbone::Writer.open(io, schema, **opts) { |w| rows.each { |r| w << r } }
    else
      Herringbone.write(io, rows, **opts)
    end
    Herringbone::Reader.new(StringIO.new(io.string))
  end

  # Whether a Numo element equals what as: :columns returned for that row
  def same_value?(numo, x, v)
    case numo
    when Numo::Bit then v == (x == 1)
    when Numo::SFloat
      return v.nil? || (v.is_a?(Float) && v.nan?) if x.nan?
      v.is_a?(Numeric) && [v].pack("e") == [x].pack("e")
    when Numo::DFloat
      return v.nil? || (v.is_a?(Float) && v.nan?) if x.nan?
      v.is_a?(Numeric) && v.to_f.eql?(x) # integers with nulls: exact up to 2**53
    when Numo::RObject then Marshal.dump(x) == Marshal.dump(v)
    else x == v && v.is_a?(Integer)
    end
  end

  # +numo+ holds +expected+ (as: :columns values): element by element, rows of 2-D arrays
  # against the expected Arrays
  def assert_numo(numo, expected, label)
    assert_kind_of Numo::NArray, numo, label
    assert_equal expected.size, numo.shape[0], "#{label}: row count"
    if numo.ndim == 2
      assert_operator numo.shape[1], :>, 0, label
      rows = numo.to_a
      expected.each_with_index do |row, i|
        ok = row.is_a?(Array) && row.size == numo.shape[1] && row.each_with_index.all? { |v, j| same_value?(numo, rows[i][j], v) }
        flunk "#{label}: row #{i}: #{rows[i].inspect} vs #{row.inspect}" unless ok
      end
    else
      assert_equal 1, numo.ndim, label
      values = numo.to_a
      expected.each_with_index do |v, i|
        flunk "#{label}: row #{i}: #{values[i].inspect} vs #{v.inspect}" unless same_value?(numo, values[i], v)
      end
    end
  end

  # The Numo class as: :numo must produce for +values+ of a field with +spec+
  def expected_class(spec, values)
    case spec.kind
    when :object then Numo::RObject
    when :list
      w = values.first.is_a?(Array) ? values.first.size : 0
      w.positive? && values.all? { |v| v.is_a?(Array) && v.size == w && !v.include?(nil) } ? spec.klass : Numo::RObject
    else
      return spec.klass unless values.include?(nil)
      return Numo::RObject if spec.klass == Numo::Bit
      spec.klass == Numo::SFloat ? Numo::SFloat : Numo::DFloat
    end
  end

  def assert_batch(reader, batch, expected, label)
    assert_equal expected.keys, batch.keys, label
    expected.each do |name, values|
      spec = NumoColumns.spec_for(reader.schema.field(name.to_s))
      numo = batch.fetch(name)
      assert_instance_of expected_class(spec, values), numo, "#{label}: #{name}" unless values.empty?
      assert_numo(numo, values, "#{label}: #{name}")
    end
  end

  # Runs the same read with as: :columns and as: :numo, and each_batch both ways
  def assert_same_reads(reader, label, sizes: [], **opts)
    expected = reader.read(as: :columns, **opts)
    assert_batch(reader, reader.read(as: :numo, **opts), expected, "#{label} read")
    sizes.each do |size|
      col_batches = []
      reader.each_batch(size, as: :columns, **opts) { |b| col_batches << b }
      numo_batches = []
      reader.each_batch(size, as: :numo, **opts) { |b| numo_batches << b }
      assert_equal col_batches.size, numo_batches.size, "#{label}: batch count (size #{size})"
      col_batches.zip(numo_batches).each_with_index do |(c, n), i|
        assert_batch(reader, n, c, "#{label} batch #{i} of #{size}")
      end
    end
  end

  def test_every_fixture_matches_columns
    checked = 0
    FILES.each do |path|
      with_reader(path) do |r|
        begin
          rows = r.read(as: :columns)
        rescue Herringbone::UnsupportedError, Herringbone::FormatError
          next # files the other read modes cannot read either
        end
        n = rows.values.first&.size || 0
        # Tiny batches only on small files, to keep the test fast
        assert_same_reads(r, File.basename(path), sizes: n <= 2000 ? [7, 1024] : [4096])
        checked += 1
      end
    end
    assert_operator checked, :>, 100
  end

  def test_type_mapping
    schema = Herringbone::Schema.define do
      int8 :i8, null: false
      int16 :i16, null: false
      int32 :i32, null: false
      int64 :i64, null: false
      uint8 :u8, null: false
      uint16 :u16, null: false
      uint32 :u32, null: false
      uint64 :u64, null: false
      float :f32
      double :f64
      float16 :f16
      boolean :bool
      time :tod, unit: :micros
      string :s
      date :d
      timestamp :ts
      decimal :dec, precision: 10, scale: 2
      list :emb, :float, element_null: false
      list :tags, :string
      struct :st do
        int32 :a
      end
      map :m, :string, :int32
    end
    rows = Array.new(3) do |i|
      [-i, -300 * i, -70_000 * i, -(2**40) * i, 200 + i, 60_000 + i, 4_000_000_000 + i, 2**64 - 1 - i,
        i + 0.5, i + 0.25, i + 0.5, i.odd?, 1000 * i, "s#{i}", Date.new(2024, 1, 1 + i), Time.utc(2024, 1, 1, i),
        BigDecimal("1.5") + i, [i, i + 1.5, 0.25], ["t"] * i, { a: i }, { "k" => i }]
    end
    r = write(rows, schema)
    cols = r.read(as: :numo)
    {
      "i8" => Numo::Int8, "i16" => Numo::Int16, "i32" => Numo::Int32, "i64" => Numo::Int64,
      "u8" => Numo::UInt8, "u16" => Numo::UInt16, "u32" => Numo::UInt32, "u64" => Numo::UInt64,
      "f32" => Numo::SFloat, "f64" => Numo::DFloat, "f16" => Numo::SFloat, "bool" => Numo::Bit,
      "tod" => Numo::Int64, "s" => Numo::RObject, "d" => Numo::RObject, "ts" => Numo::RObject,
      "dec" => Numo::RObject, "emb" => Numo::SFloat, "tags" => Numo::RObject, "st" => Numo::RObject,
      "m" => Numo::RObject
    }.each { |name, klass| assert_instance_of klass, cols[name], name }
    assert_equal [-2, -600, -140_000, -(2**41), 202, 60_002, 4_000_000_002, 2**64 - 3],
      %w[i8 i16 i32 i64 u8 u16 u32 u64].map { |c| cols[c][2] }
    assert_equal [3, 3], cols["emb"].shape
    assert_equal [[2.0, 3.5, 0.25]], cols["emb"][2, true].to_a.then { |a| [a] }
    assert_equal [Date.new(2024, 1, 3), Time.utc(2024, 1, 1, 2), BigDecimal("3.5")], [cols["d"][2], cols["ts"][2], cols["dec"][2]]
    assert_equal [[], ["t"], %w[t t]], cols["tags"].to_a
    assert_equal({ "a" => 1 }, cols["st"][1])
    assert_equal [0, 1, 0], cols["bool"].to_a
    assert_same_reads(r, "types", sizes: [1, 2])
  end

  def test_nulls
    rows = [
      { i: 1, f: 1.5, s: 1.5, b: true, l: 2**60 + 1 },
      { i: nil, f: nil, s: nil, b: nil, l: nil },
      { i: 3, f: 3.5, s: 3.5, b: false, l: 3 }
    ]
    schema = Herringbone::Schema.define do
      int32 :i
      double :f
      float :s
      boolean :b
      int64 :l
    end
    r = write(rows, schema)
    cols = r.read(as: :numo)
    assert_instance_of Numo::DFloat, cols["i"], "integers with nulls become DFloat"
    assert_equal [1.0, 3.0], [cols["i"][0], cols["i"][2]]
    assert cols["i"][1].nan?
    assert_instance_of Numo::DFloat, cols["f"]
    assert_instance_of Numo::SFloat, cols["s"], "floats keep their type"
    assert cols["s"][1].nan?
    assert_instance_of Numo::RObject, cols["b"], "booleans with nulls are true/false/nil"
    assert_equal [true, nil, false], cols["b"].to_a
    assert_equal (2**60 + 1).to_f, cols["l"][0], "int64 with nulls lose precision above 2**53"
    # Per batch: a batch without nulls keeps the integer type
    batches = r.each_batch(1, as: :numo).to_a
    assert_equal [Numo::Int32, Numo::DFloat, Numo::Int32], batches.map { |b| b["i"].class }
    assert_equal [Numo::Bit, Numo::RObject, Numo::Bit], batches.map { |b| b["b"].class }
    assert_same_reads(r, "nulls", sizes: [1, 2, 3])
  end

  def test_fixed_length_lists_become_2d
    schema = Herringbone::Schema.define do
      list :emb, :float
      list :ids, :int64, element_null: false
    end
    rows = Array.new(50) { |i| [Array.new(4) { |j| i + j / 4.0 }, [i, -i]] }
    r = write(rows, schema, page_rows: 7)
    cols = r.read(as: :numo)
    assert_instance_of Numo::SFloat, cols["emb"]
    assert_equal [50, 4], cols["emb"].shape
    assert_equal [10.0, 10.25, 10.5, 10.75], cols["emb"][10, true].to_a
    assert_instance_of Numo::Int64, cols["ids"]
    assert_equal [50, 2], cols["ids"].shape
    assert_same_reads(r, "2-D", sizes: [1, 7, 50], from: 3, limit: 40)

    # Anything but a full rectangle stays an RObject of Arrays
    [[[1.0, 2.0], [3.0]], [[1.0, 2.0], nil], [[1.0, nil], [2.0, 3.0]], [[], []]].each do |values|
      r = write(values.map { |v| [v, [1]] }, schema)
      emb = r.read(as: :numo)["emb"]
      assert_instance_of Numo::RObject, emb, values.inspect
      assert_equal [values.size], emb.shape
      assert_equal values, emb.to_a
    end
  end

  # Fixed-width columns through every page layout the fast path handles: v1/v2 pages,
  # dictionary on/off, PLAIN / BYTE_STREAM_SPLIT / DELTA_BINARY_PACKED / RLE booleans, with
  # and without nulls, many pages per chunk and several row groups
  def test_encodings_and_page_layouts
    rng = Random.new(7)
    rows = Array.new(1000) do |i|
      null = i % 7 == 3
      { "id" => i, "i32" => rng.rand(-1000..1000), "i64" => rng.rand(-2**62..2**62), "f32" => rng.rand.round(3),
        "f64" => rng.rand * 1e6, "flag" => i % 3 == 0, "n32" => null ? nil : rng.rand(50),
        "n64" => null ? nil : i * 3, "nf" => null ? nil : i / 4.0, "nflag" => null ? nil : i.even?,
        "small" => i % 5 } # few distinct values: dictionary pages of short indices
    end
    schema = Herringbone::Schema.define do
      int64 :id, null: false
      int32 :i32, null: false
      int64 :i64
      float :f32
      double :f64
      boolean :flag
      int32 :n32
      int64 :n64
      double :nf
      boolean :nflag
      int32 :small
    end
    variants = []
    [1, 2].each do |version|
      [true, false].each { |dict| variants << { data_page_version: version, dictionary: dict } }
      variants << { data_page_version: version, dictionary: false,
                    encodings: %w[i32 i64 f32 f64 n32 n64 nf].to_h { |c| [c, :byte_stream_split] } }
      variants << { data_page_version: version, dictionary: false,
                    encodings: %w[id i32 i64 n32 n64 small].to_h { |c| [c, :delta_binary_packed] } }
    end
    variants.each do |opts|
      r = write(rows, schema, page_rows: 64, row_group_rows: 300, compression: :none, **opts)
      label = opts.inspect
      cols = r.read(as: :numo)
      %w[id i32 i64 f32 f64 flag small].each { |c| refute_instance_of Numo::RObject, cols[c], "#{label} #{c}" }
      assert_same_reads(r, label, sizes: [1, 13, 300])
      assert_same_reads(r, "#{label} from/limit", sizes: [50], from: 290, limit: 333)
    end
  end

  def test_where_from_and_limit
    rows = Array.new(3000) { |i| { id: i, v: i.odd? ? nil : i * 1.5, grp: i % 10, name: "n#{i % 13}" } }
    r = write(rows, page_rows: 100, row_group_rows: 1000)
    [
      { where: { grp: 3 } },
      { where: { id: 1234..2345 } },                            # an output column in where: goes the Ruby way
      { where: { id: 1234..2345 }, columns: %w[v grp] },        # pages skipped with the page index
      { where: { name: "n7", grp: 1..5 }, columns: %w[id v] },
      { where: { id: 5000.. } },                                # no rows
      { from: 999 }, { from: 2500, limit: 17 }, { limit: 1 }, { limit: 0 }, { from: 3000 },
      { where: { grp: [1, 2] }, from: 1500, limit: 99 },
      { where: { v: nil }, columns: %w[id] },
      { columns: %w[name v] }
    ].each do |opts|
      assert_same_reads(r, opts.inspect, sizes: [1, 64, 1000], **opts)
    end
    assert_equal 2346 - 1234, r.read(as: :numo, where: { id: 1234..2345 }, columns: ["id"])["id"].size
  end

  def test_zero_rows_and_columns
    r = write([{ a: 1, b: "x", l: [1.0] }])
    empty = r.read(as: :numo, limit: 0)
    assert_equal({ "a" => [Numo::Int64, 0], "b" => [Numo::RObject, 0], "l" => [Numo::RObject, 0] },
      empty.transform_values { |v| [v.class, v.size] })
    assert_equal empty.keys, r.read(as: :numo, where: { a: 2 }).keys
    assert_equal [], r.each_batch(as: :numo, where: { a: 2 }).to_a
    assert_equal({}, r.read(as: :numo, columns: []))
    with_reader(File.join(FIXTURES_DIR, "generated", "zero_rows.parquet")) do |zr|
      assert(zr.read(as: :numo).values.all? { |v| v.is_a?(Numo::NArray) && v.empty? })
    end
  end

  def test_symbol_keys
    io = StringIO.new("".b)
    Herringbone.write(io, [{ a: 1, b: "x" }])
    r = Herringbone::Reader.new(StringIO.new(io.string), keys: :symbol)
    assert_equal %i[a b], r.read(as: :numo).keys
    assert_equal %i[a], r.each_batch(as: :numo, columns: ["a"]).first.keys
  end

  def test_results_are_independent_of_dictionary_cache
    r = write(Array.new(10) { |i| { v: (i % 3).to_f } }, dictionary: true)
    b1, b2 = r.each_batch(5, as: :numo).to_a
    b1["v"].inplace * 100 # mutating a result must not change later batches
    assert_equal [2.0, 0.0, 1.0, 2.0, 0.0], b2["v"].to_a
  end

  def test_hybrid_decoder_numo_and_ruby_reads_interleave
    rng = Random.new(3)
    [0, 1, 2, 3, 7, 8, 10, 16, 17, 20, 31].each do |width|
      max = width.zero? ? 0 : (1 << width) - 1
      values = []
      while values.size < 3000
        # Long RLE runs and scattered values, to get both kinds of runs
        v = rng.rand(0..max)
        values.concat(rng.rand < 0.3 ? [v] * rng.rand(8..40) : Array.new(rng.rand(1..30)) { rng.rand(0..max) })
      end
      data = Herringbone::Encodings::RLE.encode_hybrid(values, width)
      dec = Herringbone::Reader::PageStream::HybridDecoder.new(data, 0, data.bytesize, width)
      got = []
      i = 0
      while got.size < values.size
        n = [rng.rand(1..90), values.size - got.size].min
        got.concat(case i % 3
          when 0 then dec.read(n)
          when 1 then dec.read_numo(n, width > 31 ? Numo::Int64 : Numo::Int32).to_a
          else width == 1 ? dec.read_flags(n).to_a : dec.read_numo(n, Numo::UInt32).to_a
          end)
        i += 1
      end
      assert values == got, "width #{width}: first difference at #{values.each_index.find { |k| values[k] != got[k] }}"
    end
  end
end

# These do not need Numo, so they run in every bundle
class NumoMissingTest < Minitest::Test
  NumoColumns = Herringbone::Reader::NumoColumns

  def test_as_numo_without_numo_names_the_gems
    io = StringIO.new("".b)
    Herringbone.write(io, [{ a: 1 }])
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    loaded = NumoColumns.instance_variable_get(:@loaded)
    NumoColumns.instance_variable_set(:@loaded, false)
    missing = -> { raise LoadError, "cannot load such file -- numo/narray" }
    NumoColumns.stub(:require_library, missing) do
      [-> { reader.read(as: :numo) }, -> { reader.each_batch(as: :numo) { } }].each do |call|
        error = assert_raises(Herringbone::UnsupportedError) { call.call }
        assert_match(/needs the "numo-narray-alt" gem \(or "numo-narray"\)/, error.message)
        assert_match(/cannot load such file -- numo\/narray/, error.message)
        assert_match(/Add `gem "numo-narray-alt"` to your Gemfile/, error.message)
      end
    end
    assert_equal [{ "a" => 1 }], reader.read, "other read modes do not need Numo"
  ensure
    NumoColumns.instance_variable_set(:@loaded, loaded)
  end

  def test_rejects_unknown_as
    io = StringIO.new("".b)
    Herringbone.write(io, [{ a: 1 }])
    error = assert_raises(ArgumentError) { Herringbone::Reader.new(StringIO.new(io.string)).each_batch(as: :numpy) { } }
    assert_match(/:rows, :columns or :numo/, error.message)
  end
end
