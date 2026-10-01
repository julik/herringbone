# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "pathname"

# Writer conveniences: row shapes, schemas, type coercions, error messages, file handling
class ErgonomicsTest < Minitest::Test
  A_SCHEMA = Herringbone::Schema.define { int32 :a }

  def roundtrip(schema, rows, **opts)
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, **opts) { |w| rows.each { |r| w << r } }
    Herringbone::Reader.new(StringIO.new(io.string)).read
  end

  def test_nested_schema_dsl
    schema = Herringbone::Schema.define do
      int64 :id, null: false
      string :name
      list :tags, :string
      struct :address do
        string :city
        string :zip, null: false
      end
      decimal :price, precision: 10, scale: 2
      list :matrix do
        list :element, :int32
      end
      map :scores, :string, :double
      list :points, :struct, element_null: false do
        double :x
        double :y
      end
      timestamp "created_at", unit: :millis
    end
    assert_equal %w[id name tags address price matrix scores points created_at], schema.fields.map(&:name)
    assert_equal :required, schema.field("id").node.repetition
    assert_equal :list, schema.field("tags").kind
    assert_equal :struct, schema.field("address").kind
    refute schema.field("address").children_by_name["zip"].optional
    assert_equal :map, schema.field("scores").kind
    refute schema.field("points").element.optional

    row = {
      "id" => 1, "name" => "x", "tags" => ["a"], "address" => {"city" => "A", "zip" => "1011"},
      "price" => BigDecimal("1.25"), "matrix" => [[1, 2], []], "scores" => {"a" => 1.0},
      "points" => [{"x" => 1.0, "y" => 2.0}], "created_at" => Time.utc(2024, 1, 1, 0, 0, 0, 123_000)
    }
    assert_equal [row], roundtrip(schema, [row])
  end

  def test_writer_needs_a_schema
    error = assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, {a: :int32}) }
    assert_match(/Expected a Herringbone::Schema/, error.message)
  end

  def test_array_rows_in_schema_order
    schema = Herringbone::Schema.define {
      int64 :id
      string :name
      list :tags, :string
    }
    rows = roundtrip(schema, [[1, "a", ["x"]], [2, nil, nil]])
    assert_equal [{"id" => 1, "name" => "a", "tags" => ["x"]}, {"id" => 2, "name" => nil, "tags" => nil}], rows
    error = assert_raises(Herringbone::EncodeError) { roundtrip(schema, [[1, "a"]]) }
    assert_match(/expected 3 values/, error.message)
  end

  Point = Struct.new(:x, :y)
  Record = Struct.new(:attributes)

  def test_struct_and_attributes_rows
    schema = Herringbone::Schema.define {
      int32 :x
      int32 :y
    }
    assert_equal [{"x" => 1, "y" => 2}], roundtrip(schema, [Point.new(1, 2)])
    assert_equal [{"x" => 3, "y" => 4}], roundtrip(schema, [Record.new({"x" => 3, "y" => 4})])
    if defined?(Data) && Data.respond_to?(:define)
      pt = Data.define(:x, :y)
      assert_equal [{"x" => 5, "y" => 6}], roundtrip(schema, [pt.new(x: 5, y: 6)])
    end
  end

  def test_json_columns_serialize_objects
    schema = Herringbone::Schema.define { json :payload }
    rows = roundtrip(schema, [{payload: {"a" => [1, 2], "b" => nil}}, {payload: [1, "x"]}, {payload: '{"raw":true}'}])
    assert_equal ['{"a":[1,2],"b":null}', '[1,"x"]', '{"raw":true}'], rows.map { |r| r["payload"] }
  end

  def test_time_of_day_columns_accept_times_and_strings
    schema = Herringbone::Schema.define {
      time :at, unit: :millis
      time :us
      time :ns, unit: :nanos
    }
    t = Time.utc(2000, 1, 1, 13, 45, 30, 250_000.5r)
    rows = roundtrip(schema, [{at: t, us: "13:45:30.25", ns: t}, {at: "07:05", us: 5, ns: nil}])
    assert_equal 49_530_250, rows[0]["at"]
    assert_equal 49_530_250_000, rows[0]["us"]
    assert_equal 49_530_250_000_500, rows[0]["ns"]
    assert_equal 25_500_000, rows[1]["at"]
    assert_equal 5, rows[1]["us"]
  end

  def test_date_and_timestamp_coercions
    schema = Herringbone::Schema.define {
      date :d
      timestamp :t
      timestamp :local, utc: false
    }
    rows = roundtrip(schema, [
      {d: "2024-02-29", t: "2024-02-29T10:00:00.5+02:00", local: Time.new(2024, 2, 29, 10, 0, 0, "+02:00")},
      {d: Time.utc(2024, 3, 1, 23), t: Date.new(2024, 3, 1), local: nil},
      {d: DateTime.new(2024, 3, 2, 5), t: DateTime.new(2024, 3, 2, 5, 0, 0, "+01:00"), local: nil}
    ])
    assert_equal [Date.new(2024, 2, 29), Date.new(2024, 3, 1), Date.new(2024, 3, 2)], rows.map { |r| r["d"] }
    assert_equal Time.utc(2024, 2, 29, 8, 0, 0.5r), rows[0]["t"]
    assert_equal Time.utc(2024, 3, 1), rows[1]["t"]
    assert_equal Time.utc(2024, 3, 2, 4), rows[2]["t"]
    # Local timestamps keep the wall clock time
    assert_equal Time.utc(2024, 2, 29, 10), rows[0]["local"]
  end

  # Stands in for ActiveSupport::TimeWithZone, which is not a Time subclass
  class FakeTimeWithZone
    def initialize(time) = @time = time
    def to_i = @time.to_i
    def nsec = @time.nsec
    def utc_offset = 3600
  end

  def test_time_with_zone_like_objects
    schema = Herringbone::Schema.define { timestamp :t }
    t = Time.utc(2024, 5, 1, 12, 0, 0, 5)
    assert_equal [{"t" => t}], roundtrip(schema, [{t: FakeTimeWithZone.new(t)}])
  end

  def test_boolean_coercions
    schema = Herringbone::Schema.define { boolean :b }
    input = [true, false, 1, 0, "t", "f", "true", "FALSE", "1", "0", "yes", "No", :true] # standard:disable Lint/BooleanSymbol
    assert_equal [true, false, true, false, true, false, true, false, true, false, true, false, true],
      roundtrip(schema, input.map { |v| {b: v} }).map { |r| r["b"] }
  end

  def test_numeric_coercions
    schema = Herringbone::Schema.define {
      int32 :i
      double :f
      decimal :d, precision: 8, scale: 3
    }
    rows = roundtrip(schema, [
      {i: "12", f: "1.5", d: "3.14159"},
      {i: 3.0, f: BigDecimal("2.25"), d: 2},
      {i: BigDecimal("7"), f: 1r / 4, d: 1r / 3},
      {i: 5r, f: 3, d: 0.1}
    ])
    assert_equal [12, 3, 7, 5], rows.map { |r| r["i"] }
    assert_equal [1.5, 2.25, 0.25, 3.0], rows.map { |r| r["f"] }
    assert_equal %w[3.142 2.0 0.333 0.1], rows.map { |r| r["d"].to_s("F") }
    assert_raises(Herringbone::EncodeError) { roundtrip(schema, [{i: 1.5}]) }
  end

  def test_strings_accept_symbols_and_other_objects
    schema = Herringbone::Schema.define { string :s }
    assert_equal ["sym", "42"], roundtrip(schema, [{s: :sym}, {s: 42}]).map { |r| r["s"] }
  end

  def test_enum_is_a_string_column_by_default
    schema = Herringbone::Schema.define { enum :status }
    node = schema.columns.first.node
    assert_equal :string, node.logical_type.kind.first
    annotated = Herringbone::Schema.define { enum :status, parquet_enum: true }
    assert_equal :enum, annotated.columns.first.node.logical_type.kind.first
  end

  def test_enum_values_like_rails
    statuses = {"pending" => 0, "paid" => 1, "shipped" => 2}
    schema = Herringbone::Schema.define { enum :status, values: statuses, null: false }
    rows = roundtrip(schema, [{status: "paid"}, {status: :shipped}, {status: 0}])
    assert_equal %w[paid shipped pending], rows.map { |r| r["status"] }
    error = assert_raises(Herringbone::EncodeError) { roundtrip(schema, [{status: "lost"}]) }
    assert_match(/not one of pending, paid, shipped/, error.message)
    list = Herringbone::Schema.define { enum :kind, values: %w[a b] }
    assert_raises(Herringbone::EncodeError) { roundtrip(list, [{kind: "c"}]) }
  end

  def test_error_messages_name_row_and_column_path
    schema = Herringbone::Schema.define do
      int64 :id
      struct(:address) { string :city, null: false }
    end
    error = assert_raises(Herringbone::EncodeError) do
      roundtrip(schema, [{id: 1, address: {city: "x"}}, {id: 2, address: {city: nil}}])
    end
    assert_match(/\ARow 1: /, error.message)
    assert_match(/address\.city/, error.message)
    error = assert_raises(Herringbone::EncodeError) { roundtrip(schema, [{id: "abc"}]) }
    assert_match(/\ARow 0: Cannot write "abc" to id/, error.message)
  end

  def test_infer_improvements
    rows = [
      {"a" => 1, "b" => nil, "c" => 1.5, "d" => DateTime.new(2024, 1, 1), "e" => {"x" => 1}, "f" => [1]},
      {"a" => 2, "b" => nil, "c" => 2, "d" => Time.now, "e" => nil, "f" => []}
    ]
    schema = Herringbone::Schema.infer(rows) {
      json :e
      string :extra
    }
    kinds = schema.columns.to_h { |c| [c.dotted_path, Herringbone::Types.logical_of(c.node).first] }
    assert_equal :string, kinds["b"]
    assert_equal Herringbone::Format::Type::DOUBLE, schema.column("c").type
    assert_equal :timestamp, kinds["d"]
    assert_equal :json, kinds["e"]
    assert_equal :list, schema.field("f").kind
    assert_equal %w[a b c d e f extra], schema.fields.map(&:name), "declared fields replace inferred ones in place"
    error = assert_raises(ArgumentError) { Herringbone::Schema.infer([{x: Object.new}]) }
    assert_match(/Schema.infer\(rows\) \{ string :x \}/, error.message)
    assert_equal [1, 2], roundtrip(schema, rows).map { |r| r["a"] }
  end

  def test_writer_rejects_paths
    [+"out.parquet", Pathname.new("out.parquet"), nil, 42].each do |target|
      error = assert_raises(ArgumentError) { Herringbone::Writer.new(target, A_SCHEMA) }
      assert_match(/expects an IO that responds to #write/, error.message)
    end
    assert_raises(ArgumentError) { Herringbone.write("out.parquet", [{a: 1}]) }
  end

  def test_failed_block_aborts_without_footer
    io = StringIO.new("".b)
    assert_raises(RuntimeError) do
      Herringbone::Writer.open(io, A_SCHEMA) do |w|
        w << {a: 1}
        raise "boom"
      end
    end
    refute io.closed?
    assert_equal "PAR1", io.string, "only the leading magic, no footer after a failed write"
  end

  def test_open_returns_block_value_and_leaves_io_open
    io = StringIO.new("".b)
    assert_equal :done, Herringbone::Writer.open(io, A_SCHEMA) { |w|
      w << [7]
      :done
    }
    refute io.closed?
    assert_equal [{"a" => 7}], Herringbone::Reader.new(StringIO.new(io.string)).read
  end

  def test_open_without_block
    io = StringIO.new("".b)
    w = Herringbone::Writer.open(io, A_SCHEMA)
    w << [1]
    w.close
    assert_equal [{"a" => 1}], Herringbone::Reader.new(StringIO.new(io.string)).read
  end

  def test_writes_to_a_file_opened_by_the_caller
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.parquet")
      assert_equal 2, File.open(path, "wb") { |f| Herringbone.write(f, [{a: 1}, {a: 2}]) }
      assert_equal [1, 2], File.open(path, "rb") { |f| Herringbone::Reader.new(f).read }.map { |r| r["a"] }
    end
  end

  def test_open_with_io
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, A_SCHEMA) { |w| w << [1] }
    assert_equal [{"a" => 1}], Herringbone::Reader.new(StringIO.new(io.string)).read
  end

  def test_row_group_bytes_bounds_row_groups
    schema = Herringbone::Schema.define {
      int64 :id
      string :s
    }
    rows = Array.new(20_000) { |i| {id: i, s: format("%090d", i)} } # ~110 bytes per row, all distinct
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, row_group_bytes: 500_000) { |w| rows.each { |r| w << r } }
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    sizes = reader.row_groups.map(&:num_rows)
    assert_equal 20_000, sizes.sum
    assert sizes.size.between?(3, 10), "expected row groups of roughly 500KB, got #{sizes.inspect}"
    assert_equal rows.last[:id], reader.read(as: :columns, columns: ["id"])["id"].last

    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, row_group_rows: 3000) { |w| rows.each { |r| w << r } }
    assert_equal [3000] * 6 + [2000], Herringbone::Reader.new(StringIO.new(io.string)).row_groups.map(&:num_rows)
  end

  def test_created_by
    io = StringIO.new("".b)
    Herringbone.write(io, [{a: 1}])
    assert_equal "herringbone-ruby #{Herringbone::VERSION}", Herringbone::Reader.new(StringIO.new(io.string)).file_metadata.created_by
  end
end
