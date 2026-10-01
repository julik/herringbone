# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"

# where:, from:, limit:, scan_plan and page skipping
class ScanTest < Minitest::Test
  Filter = Herringbone::Reader::Filter

  # Counts the bytes read, to prove pages were skipped
  class CountingIO < StringIO
    attr_reader :bytes_read

    def initialize(*)
      super
      @bytes_read = 0
    end

    def read(*args)
      out = super
      @bytes_read += out.bytesize if out
      out
    end
  end

  ROWS = Array.new(20_000) do |i|
    {
      id: i,
      day: Date.new(2024, 1, 1) + i / 500,
      status: %w[new paid shipped][i % 3],
      email: "user#{(i * 7919) % 20_000}@example.com",
      amount: BigDecimal(i) / 100,
      maybe: (i % 5 == 0) ? nil : i,
      tags: Array.new(i % 3) { |k| "t#{k}" },
      addr: (i % 7 == 0) ? nil : {city: %w[AMS BER PAR][i % 3], zip: format("%04d", i % 10_000)}
    }
  end
  SCHEMA = Herringbone::Schema.define do
    int64 :id, null: false
    date :day
    string :status
    string :email
    decimal :amount, precision: 12, scale: 2
    int64 :maybe
    list :tags, :string
    struct :addr do
      string :city
      string :zip
    end
  end

  def write(rows = ROWS, **opts)
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, SCHEMA, page_rows: 500, row_group_rows: 5000, **opts) { |w| rows.each { |r| w << r } }
    io.string
  end

  def reader(bytes = FILES[:v1])
    Herringbone::Reader.new(StringIO.new(bytes), keys: :symbol)
  end

  def expected(where, from: nil, limit: nil)
    rows = ROWS.drop(from || 0).select do |row|
      where.all? do |key, test|
        value = key.to_s.split(".").reduce(row) { |h, k| h&.[](k.to_sym) }
        Filter.matches?(test.is_a?(Symbol) ? test.to_s : test, value)
      end
    end
    limit ? rows.first(limit) : rows
  end

  FILES = {}
  def setup
    FILES[:v1] ||= write(bloom_filters: ["email"])
    FILES[:v2] ||= write(data_page_version: 2, compression: :gzip)
    FILES[:plain] ||= write(dictionary: false)
    FILES[:no_index] ||= WriterHelpers.strip_page_index(write)
  end

  QUERIES = [
    {id: 12_345},
    {id: 4_990..5_010},
    {id: 19_990..},
    {id: ...7},
    {day: Date.new(2024, 1, 20)},
    {status: "paid", id: 100...200},
    {status: :shipped, id: [3, 5, 8, 11, 17_999]},
    {email: "user0@example.com"},
    {email: "nobody@example.com"},
    {amount: BigDecimal("12.34")..BigDecimal("12.40")},
    {maybe: nil, id: ...100},
    {"addr.city" => "BER", :id => 10_000...10_050},
    {"addr.city" => nil, :id => ...50},
    {id: ->(v) { v % 4_000 == 0 }},
    {id: 50_000},
    {id: 1..0}
  ].freeze

  def test_results_match_a_full_scan
    FILES.each do |name, bytes|
      r = reader(bytes)
      QUERIES.each do |where|
        assert_equal expected(where), r.read(where: where), "#{name}: #{where.inspect}"
        columns = r.read(as: :columns, where: where, columns: %w[id tags])
        assert_equal expected(where).map { |row| row[:id] }, columns[:id], "#{name}: #{where.inspect} as columns"
        assert_equal expected(where).map { |row| row[:tags] }, columns[:tags]
      end
    end
  end

  def test_from_and_limit
    FILES.each do |name, bytes|
      r = reader(bytes)
      [[nil, nil], [0, 3], [4_999, 3], [5_000, 1], [12_345, 700], [19_998, 10], [25_000, nil], [nil, 0]].each do |from, limit|
        assert_equal expected({}, from: from, limit: limit), r.read(from: from, limit: limit), "#{name}: from #{from} limit #{limit}"
      end
      assert_equal expected({status: "new"}, from: 7_000, limit: 5), r.read(where: {status: "new"}, from: 7_000, limit: 5)
      batches = r.each_batch(64, limit: 200).map(&:size)
      assert_equal [64, 64, 64, 8], batches
    end
  end

  def test_plan_skips_row_groups_and_pages
    r = reader
    plan = r.scan_plan(where: {id: 12_345})
    assert_equal [{row_group: 2, rows: 500, ranges: [[2_000, 2_500]]}], plan
    assert_equal [], r.scan_plan(where: {id: 50_000})
    assert_equal [], r.scan_plan(where: {email: "nobody@example.com"}), "bloom filters rule out every row group"
    assert_equal [0], r.scan_plan(where: {email: "user0@example.com"}).map { |p| p[:row_group] },
      "the email is in exactly one row group (row 0)"
    assert_equal [[0, 5_000]], r.scan_plan.first[:ranges]
    assert_equal({row_group: 1, rows: 4_000, ranges: [[1_000, 5_000]]}, r.scan_plan(from: 6_000).first)
    # Without a page index only whole row groups are ruled out
    no_index = reader(FILES[:no_index]).scan_plan(where: {id: 12_345})
    assert_equal [{row_group: 2, rows: 5_000, ranges: [[0, 5_000]]}], no_index
  end

  def test_skipped_pages_are_not_read
    bytes_read = lambda do |&read|
      io = CountingIO.new(FILES[:plain])
      read.call(Herringbone::Reader.new(io, keys: :symbol))
      io.bytes_read
    end
    full = bytes_read.call(&:read)
    lookup = bytes_read.call { |r| assert_equal 1, r.read(where: {id: 12_345}).size }
    assert_operator lookup, :<, full / 10, "a point lookup reads a small fraction of the file (#{lookup} of #{full} bytes)"
    tail = bytes_read.call { |r| assert_equal 5, r.read(from: 19_000, limit: 5).size }
    assert_operator tail, :<, full / 10
  end

  def test_fixtures_with_page_indexes_from_other_writers
    {
      "parquet-testing/alltypes_tiny_pages.parquet" => {"id" => 3_000...3_050, "bool_col" => true},
      "parquet-testing/alltypes_tiny_pages_plain.parquet" => {"int_col" => 5, "id" => ...200},
      "generated/multi_page_with_index.parquet" => nil
    }.each do |fixture, where|
      File.open(File.join(FIXTURES_DIR, fixture), "rb") do |f|
        r = Herringbone::Reader.new(f)
        all = r.read
        where ||= {r.schema.fields.first.name => all[all.size / 2][r.schema.fields.first.name]}
        want = all.select { |row| where.all? { |k, test| Filter.matches?(test, row[k]) } }
        assert_equal want, r.read(where: where), fixture
        assert_equal all.drop(all.size / 3).first(17), r.read(from: all.size / 3, limit: 17), fixture
        # Pages can only be skipped where there is more than one of them
        pages = r.page_index(0, r.schema.column(where.keys.first.to_s))[1]&.page_locations&.size.to_i
        if pages > 1
          assert_operator r.scan_plan(where: where).sum { |p| p[:rows] }, :<, r.num_rows, "#{fixture} skips pages"
        end
      end
    end
  end

  def test_bad_conditions
    r = reader
    assert_raises(ArgumentError) { r.read(where: {nope: 1}) }
    assert_raises(ArgumentError) { r.read(where: {"tags.list.element" => "t0"}) }
    assert_raises(ArgumentError) { r.read(where: [:id, 1]) }
    assert_raises(ArgumentError) { r.read(from: -1) }
    assert_raises(ArgumentError) { r.read(limit: -1) }
    assert_equal [], r.read(where: {id: "not a number"})
  end

  def test_limit_zero_still_validates_arguments
    r = reader
    [:rows, :columns].each do |as|
      assert_raises(ArgumentError, as) { r.read(as: as, columns: %w[nope], limit: 0) }
      assert_raises(ArgumentError, as) { r.read(as: as, where: {nope: 1}, limit: 0) }
      assert_raises(ArgumentError, as) { r.read(as: as, from: -1, limit: 0) }
      assert_raises(ArgumentError, as) { r.each_batch(as: as, columns: %w[nope], limit: 0) { nil } }
      assert_raises(ArgumentError, as) { r.each_batch(as: as, where: {nope: 1}, limit: 0).to_a }
    end
    assert_raises(ArgumentError) { r.each_row(from: -1, limit: 0) { nil } }
    assert_equal [], r.read(columns: %w[id], where: {id: 1}, from: 1, limit: 0)
    assert_equal({id: []}, r.read(as: :columns, columns: %w[id], limit: 0))
    assert_equal [], r.each_batch(limit: 0).to_a
  end

  def test_filter_columns_need_not_be_projected
    r = reader
    got = r.read(columns: %w[email], where: {id: 7})
    assert_equal [{email: ROWS[7][:email]}], got
  end

  def test_helpers
    bytes = FILES[:v1]
    assert_equal expected({id: 1..3}), reader(bytes).read(where: {id: 1..3})
    assert_equal({"id" => [4, 5]}, Herringbone::Reader.new(StringIO.new(bytes)).read(as: :columns, columns: ["id"], from: 4, limit: 2))
    assert_equal [ROWS[9][:id]], reader.each_row(where: {id: 9}).map { |row| row[:id] }
  end
end
