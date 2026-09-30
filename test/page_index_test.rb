# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "json"

# ColumnIndex / OffsetIndex written by the Writer
class PageIndexTest < Minitest::Test
  F = Herringbone::Format

  def write(schema, rows, **opts)
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, **opts) { |w| w.write_rows(rows) }
    io.string
  end

  def indexes(bytes, row_group = 0)
    reader = Herringbone::Reader.new(StringIO.new(bytes))
    reader.row_groups[row_group].columns.map do |chunk|
      ci = chunk.column_index_offset && F::ColumnIndex.decode(bytes, chunk.column_index_offset).first
      oi = chunk.offset_index_offset && F::OffsetIndex.decode(bytes, chunk.offset_index_offset).first
      assert_equal chunk.column_index_length, ci.encode.bytesize if ci
      assert_equal chunk.offset_index_length, oi.encode.bytesize if oi
      [chunk, ci, oi]
    end
  end

  def page_headers(bytes, oi)
    oi.page_locations.map do |loc|
      header, header_end = F::PageHeader.decode(bytes, loc.offset)
      assert_equal loc.compressed_page_size, header_end - loc.offset + header.compressed_page_size
      header
    end
  end

  def test_offset_index_locates_every_data_page
    rows = Array.new(10_000) { |i| { id: i, name: "n#{i % 50}", tags: Array.new(i % 4) { |k| "t#{k}" } } }
    [1, 2].each do |version|
      bytes = write({ id: :int64, name: :string, tags: [:string] }, rows, page_row_limit: 700, data_page_version: version)
      indexes(bytes).each do |chunk, _, oi|
        headers = page_headers(bytes, oi)
        assert headers.all? { |h| [F::PageType::DATA_PAGE, F::PageType::DATA_PAGE_V2].include?(h.type) }
        assert_equal chunk.meta_data.data_page_offset, oi.page_locations.first.offset
        # first_row_index counts rows, also for the repeated column
        firsts = oi.page_locations.map(&:first_row_index)
        assert_equal 0, firsts.first
        assert_equal firsts, firsts.sort
        assert_operator oi.page_locations.size, :>=, (10_000 / 700.0).ceil
        firsts.each_cons(2) { |a, b| assert_operator b - a, :<=, 700 }
        num_values = headers.sum { |h| (h.data_page_header || h.data_page_header_v2).num_values }
        assert_equal chunk.meta_data.num_values, num_values
      end
    end
  end

  def test_column_index_min_max_nulls_and_order
    rows = Array.new(1000) do |i|
      { asc: i, desc: -i, mixed: (i * 7919) % 1000, maybe: i < 200 || i.odd? ? nil : i.to_f, s: format("k%04d", i) }
    end
    schema = { asc: :int64, desc: :int32, mixed: :int64, maybe: :double, s: :string }
    bytes = write(schema, rows, page_row_limit: 100)
    by_name = indexes(bytes).to_h { |chunk, ci, oi| [chunk.meta_data.path_in_schema.first, [ci, oi]] }

    ci, oi = by_name.fetch("asc")
    assert_equal 10, oi.page_locations.size
    assert_equal F::BoundaryOrder::ASCENDING, ci.boundary_order
    assert_equal (0...10).map { |p| [p * 100].pack("q<") }, ci.min_values
    assert_equal (0...10).map { |p| [p * 100 + 99].pack("q<") }, ci.max_values
    assert_equal [false] * 10, ci.null_pages
    assert_equal [0] * 10, ci.null_counts

    assert_equal F::BoundaryOrder::DESCENDING, by_name.fetch("desc")[0].boundary_order
    assert_equal F::BoundaryOrder::UNORDERED, by_name.fetch("mixed")[0].boundary_order

    maybe = by_name.fetch("maybe")[0]
    assert_equal [true, true] + [false] * 8, maybe.null_pages
    assert_equal ["".b, "".b], maybe.min_values.first(2)
    assert_equal [100, 100] + [50] * 8, maybe.null_counts
    assert_equal [200.0].pack("E"), maybe.min_values[2]

    s = by_name.fetch("s")[0]
    assert_equal "k0000", s.min_values[0]
    assert_equal "k0999", s.max_values[9]
    assert_equal F::BoundaryOrder::ASCENDING, s.boundary_order
  end

  def test_sort_orders_for_unsigned_decimal_and_float16
    rows = [
      { u: 1, d: BigDecimal("-5.5"), h: 1.5 },
      { u: 2**63 + 1, d: BigDecimal("12345678901234567890.5"), h: -2.0 },
      { u: 0, d: BigDecimal("0.25"), h: Float::NAN }
    ]
    schema = Herringbone::Schema.define do
      uint64 :u
      decimal :d, precision: 30, scale: 2
      float16 :h
    end
    bytes = write(schema, rows)
    (u, u_ci), (d, d_ci), (_, h_ci) = indexes(bytes).map { |chunk, ci, _| [chunk, ci] }
    assert_equal [[0].pack("q<")], u_ci.min_values
    assert_equal [[2**63 + 1 - 2**64].pack("q<")], u_ci.max_values, "unsigned order"
    assert_equal [0].pack("q<"), u.meta_data.statistics.min_value
    type_len = d.meta_data.statistics.min_value.bytesize
    assert_equal Herringbone::Types.int_to_be(-550, type_len), d_ci.min_values[0]
    assert_equal Herringbone::Types.int_to_be(1_234_567_890_123_456_789_050, type_len), d_ci.max_values[0]
    assert_equal [Herringbone::Types.float_to_half(-2.0)].pack("v"), h_ci.min_values[0]
    assert_equal [Herringbone::Types.float_to_half(1.5)].pack("v"), h_ci.max_values[0]
  end

  def test_long_strings_are_truncated
    long_min = "a" * 100
    long_max = "b" * 64 + "\xFF".b * 10
    bytes = write({ s: :binary }, [{ s: long_min }, { s: long_max }])
    chunk, ci, = indexes(bytes).first
    assert_equal "a" * 64, ci.min_values[0]
    assert_equal "b" * 63 + "c", ci.max_values[0]
    stats = chunk.meta_data.statistics
    assert_equal "a" * 64, stats.min_value
    refute stats.is_min_value_exact
    refute stats.is_max_value_exact
    assert_operator stats.max_value, :>, long_max
  end

  def test_int96_gets_offset_index_only
    schema = Herringbone::Schema.define { int96 :t }
    chunk, ci, oi = indexes(write(schema, [{ t: Time.utc(2024) }])).first
    assert_nil ci
    assert_nil chunk.column_index_offset
    assert_equal 1, oi.page_locations.size
  end

  def test_nan_only_page_has_no_column_index
    _, ci, oi = indexes(write({ f: :double }, [{ f: Float::NAN }, { f: Float::NAN }])).first
    assert_nil ci
    refute_nil oi
  end

  def test_page_index_can_be_disabled
    bytes = write({ a: :int32 }, [{ a: 1 }], page_index: false)
    chunk, ci, oi = indexes(bytes).first
    assert_nil ci
    assert_nil oi
    assert_nil chunk.offset_index_offset
  end

  def test_indexes_for_every_row_group
    rows = Array.new(3000) { |i| { a: i } }
    bytes = write({ a: :int64 }, rows, row_group_size: 1000, page_row_limit: 250)
    reader = Herringbone::Reader.new(StringIO.new(bytes))
    assert_equal 3, reader.num_row_groups
    3.times do |g|
      _, ci, oi = indexes(bytes, g).first
      assert_equal 4, oi.page_locations.size
      assert_equal [g * 1000].pack("q<"), ci.min_values[0]
    end
  end

  # DataFusion (arrow-rs) uses the page index to skip pages. Runs when HERRINGBONE_PYTHON has it.
  def test_datafusion_prunes_pages
    python = ENV["HERRINGBONE_PYTHON"]
    skip "HERRINGBONE_PYTHON is not set" if python.nil? || python.empty?
    _, status = Open3.capture2e(python, "-c", "import datafusion")
    skip "datafusion is not installed for #{python}" unless status.success?

    Dir.mktmpdir do |dir|
      path = File.join(dir, "pruning.parquet")
      rows = Array.new(50_000) { |i| { id: i, v: (i % 97) * 1.5 } }
      File.open(path, "wb") do |f|
        Herringbone.write(f, rows, schema: { id: { type: :int64, null: false }, v: :double }, page_row_limit: 5000)
      end
      script = File.join(__dir__, "support", "datafusion_prune.py")
      out, err, st = Open3.capture3(python, script, path, "select count(*) as c from t where id between 12000 and 12999")
      assert st.success?, err
      result = JSON.parse(out)
      assert_equal 1000, result["count"]
      assert_equal 50_000, result["page_index_rows_total"]
      assert_equal 5000, result["page_index_rows_matched"], "only the page holding ids 10000..14999 is read"
    end
  end
end
