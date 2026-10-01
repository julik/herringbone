# frozen_string_literal: true

require_relative "test_helper"

# each_batch(as: :columns) and read(as: :columns)
class ColumnarReadTest < Minitest::Test
  FILES = Dir[File.join(FIXTURES_DIR, "{parquet-testing,generated}", "*.parquet")].sort

  def with_reader(path, &block)
    File.open(path, "rb") { |f| block.call(Herringbone::Reader.new(f)) }
  end

  # Equality that treats NaNs as equal. Deliberately not assert_equal: on a mismatch it would
  # pretty-print a diff of every row, which takes minutes on the large fixtures.
  def same?(a, b)
    Marshal.dump(a) == Marshal.dump(b)
  end

  # Rows rebuilt from column batches must equal what the row API returns
  def test_columns_match_rows_for_every_fixture
    checked = 0
    FILES.each do |path|
      with_reader(path) do |r|
        begin
          rows = r.read
        rescue Herringbone::UnsupportedError, Herringbone::FormatError
          next # files the row API cannot read either (covered by the conformance tests)
        end
        # Tiny batches only on small files, to keep the test fast
        ((rows.size <= 2000) ? [7, 1024] : [4096]).each do |size|
          rebuilt = []
          r.each_batch(size, as: :columns) do |batch|
            n = batch.values.first&.size || 0
            assert batch.values.all? { |v| v.size == n }, "#{File.basename(path)}: ragged batch"
            assert_operator n, :<=, size
            n.times { |i| rebuilt << batch.transform_values { |v| v[i] } }
          end
          assert_equal rows.size, rebuilt.size, File.basename(path)
          # Marshal treats NaNs as equal, unlike ==
          assert Marshal.dump(rows) == Marshal.dump(rebuilt),
            "#{File.basename(path)}: column batches differ from rows (batch size #{size})"
        end
        columns = r.read(as: :columns)
        assert_equal r.schema.fields.map(&:name), columns.keys
        if columns.any?
          assert same?(rows.map { |row| row[columns.keys.first] }, columns.values.first), "#{File.basename(path)}: read(as: :columns)"
        end
        checked += 1
      end
    end
    assert_operator checked, :>, 100
  end

  def test_batches_are_full_and_span_row_groups
    io = StringIO.new("".b)
    Herringbone.write(io, Array.new(2500) { |i| {id: i, tags: ["t#{i % 3}"] * (i % 3)} }, row_group_rows: 700)
    r = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 4, r.row_groups.size
    sizes = []
    ids = []
    r.each_batch(1000, as: :columns) do |batch|
      sizes << batch["id"].size
      ids.concat(batch["id"])
      assert_equal batch["id"].size, batch["tags"].size
    end
    assert_equal [1000, 1000, 500], sizes
    assert_equal (0...2500).to_a, ids
  end

  # Regression: with more columns than the batch size, a batch spanning a row group boundary
  # computed a negative row count and never finished
  def test_wide_file_with_small_batches_across_row_groups
    rows = Array.new(50) { |i| (0...12).to_h { |c| ["c#{c}", i * 100 + c] } }
    io = StringIO.new("".b)
    Herringbone.write(io, rows, row_group_rows: 20)
    r = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 3, r.row_groups.size
    [1, 3, 7, 11, 13, 50, 100].each do |size|
      column_batches = r.each_batch(size, as: :columns).to_a
      row_batches = r.each_batch(size).to_a
      assert_equal row_batches.map(&:size), column_batches.map { |b| b["c0"].size }, "batch size #{size}"
      assert_equal rows.map { |row| row["c5"] }, column_batches.flat_map { |b| b["c5"] }
    end
  end

  def test_projection_keys_and_helpers
    io = StringIO.new("".b)
    Herringbone.write(io, [{a: 1, b: "x", c: 1.5}, {a: 2, b: nil, c: nil}])
    bytes = io.string
    r = Herringbone::Reader.new(StringIO.new(bytes))
    assert_equal({"a" => [1, 2], "c" => [1.5, nil]}, r.each_batch(10, as: :columns, columns: %w[a c]).first)
    assert_equal({a: [1, 2], b: ["x", nil], c: [1.5, nil]}, Herringbone::Reader.new(StringIO.new(bytes), keys: :symbol).read(as: :columns))
    assert_equal({"b" => ["x", nil]}, r.read(as: :columns, columns: ["b"]))
    assert_equal [{"a" => 1}, {"a" => 2}], r.read(columns: ["a"])
    assert_raises(ArgumentError) { r.each_batch(10, as: :cells).first }
    assert_raises(ArgumentError) { r.read(as: :cells) }
  end

  def test_empty_file
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, Herringbone::Schema.define { int32 :a }) { |_| }
    r = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal [], r.each_batch(10, as: :columns).to_a
    assert_equal({"a" => []}, r.read(as: :columns))
  end
end
