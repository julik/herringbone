# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Schema.from_active_record, tested against duck-typed models and (when the gems are
# installed) a real in-memory SQLite ActiveRecord model.
class ActiveRecordTest < Minitest::Test
  T = Herringbone::Format::Type
  C = Herringbone::Format::ConvertedType

  FakeColumn = Struct.new(:name, :type, :sql_type, :null, :limit, :precision, :scale, :array, keyword_init: true) do
    def initialize(null: true, array: false, **kw) = super
  end
  # A column that does not respond to #array (non-Postgres adapters)
  PlainColumn = Struct.new(:name, :type, :sql_type, :null, :limit, :precision, :scale, keyword_init: true) do
    def initialize(null: true, **kw) = super
  end
  FakeModel = Struct.new(:columns, :primary_key, :defined_enums, keyword_init: true) do
    def initialize(primary_key: "id", defined_enums: {}, **kw) = super
    def to_s = "FakeModel"
  end
  # A model without defined_enums
  BareModel = Struct.new(:columns, :primary_key)

  def col(name, type, sql_type = type.to_s, **kw) = FakeColumn.new(name: name, type: type, sql_type: sql_type, **kw)

  def node(schema, name) = schema.root.children.find { |n| n.name == name }

  def kind(node) = Herringbone::Types.logical_of(node)

  def schema_for(*columns, **opts)
    Herringbone::Schema.from_active_record(FakeModel.new(columns: columns, primary_key: "id"), **opts)
  end

  def test_integer_widths
    s = schema_for(
      col("id", :integer, "integer", null: false, limit: 4),
      col("i", :integer, "integer", limit: 4),
      col("i_nil", :integer, "INTEGER"),
      col("int11", :integer, "int(11)", limit: 4),
      col("serial", :integer, "serial"),
      col("small", :integer, "smallint", limit: 2),
      col("int2", :integer, "int2"),
      col("small_by_limit", :integer, "integer(2)", limit: 2),
      col("tiny", :integer, "tinyint", limit: 1),
      col("big", :integer, "bigint", limit: 8),
      col("big20", :integer, "bigint(20)", limit: 8),
      col("big_by_limit", :integer, "integer", limit: 8),
      col("bigserial", :integer, "bigserial"),
      col("u32", :integer, "int unsigned", limit: 4),
      col("u64", :integer, "bigint(20) unsigned", limit: 8)
    )
    assert_equal T::INT64, node(s, "id").type
    assert_equal T::INT32, node(s, "i").type
    assert_equal T::INT32, node(s, "i_nil").type
    assert_equal T::INT32, node(s, "int11").type
    assert_equal T::INT32, node(s, "serial").type
    assert_equal [:integer, 16, true], kind(node(s, "small"))
    assert_equal [:integer, 16, true], kind(node(s, "int2"))
    assert_equal [:integer, 16, true], kind(node(s, "small_by_limit"))
    assert_equal [:integer, 8, true], kind(node(s, "tiny"))
    %w[big big20 big_by_limit bigserial].each { |n| assert_equal T::INT64, node(s, n).type, n }
    assert_equal [:integer, 32, false], kind(node(s, "u32"))
    assert_equal [:integer, 64, false], kind(node(s, "u64"))
  end

  def test_integer_primary_key_is_int64_and_required
    s = schema_for(col("id", :integer, "INTEGER", null: true), col("n", :integer, "integer"))
    assert_equal T::INT64, node(s, "id").type
    assert_equal :required, node(s, "id").repetition
    assert_equal T::INT32, node(s, "n").type
  end

  def test_composite_primary_key
    model = FakeModel.new(columns: [col("a", :integer, "integer"), col("b", :string, "varchar")], primary_key: %w[a b])
    s = Herringbone::Schema.from_active_record(model)
    assert_equal %i[required required], s.root.children.map(&:repetition)
    assert_equal T::INT64, node(s, "a").type
  end

  def test_scalar_mappings
    s = schema_for(
      col("f8", :float, "float"),
      col("dp", :float, "double precision"),
      col("f4", :float, "float4"),
      col("real", :float, "real"),
      col("price", :decimal, "decimal(12,2)", precision: 12, scale: 2),
      col("whole", :decimal, "numeric(10)", precision: 10),
      col("loose", :decimal, "numeric"),
      col("loose_scaled", :decimal, "numeric", scale: 3),
      col("cash", :money, "money", precision: 19, scale: 2),
      col("flag", :boolean, "boolean"),
      col("name", :string, "character varying"),
      col("body", :text, "text"),
      col("email", :citext, "citext"),
      col("blob", :binary, "bytea"),
      col("born", :date, "date"),
      col("at", :datetime, "timestamp(6) without time zone", precision: 6),
      col("at_ts", :timestamp, "timestamp"),
      col("at_tz", :timestamptz, "timestamp with time zone"),
      col("clock", :time, "time"),
      col("doc", :json, "json"),
      col("docb", :jsonb, "jsonb"),
      col("uid", :uuid, "uuid"),
      col("ip", :inet, "inet"),
      col("net", :cidr, "cidr"),
      col("mac", :macaddr, "macaddr"),
      col("weird", :tsvector, "tsvector"),
      col("untyped", nil, "whatever")
    )
    assert_equal T::DOUBLE, node(s, "f8").type
    assert_equal T::DOUBLE, node(s, "dp").type
    assert_equal T::FLOAT, node(s, "f4").type
    assert_equal T::DOUBLE, node(s, "real").type # "real" is 8 bytes in SQLite, so keep it lossless
    assert_equal [:decimal, 2, 12], kind(node(s, "price"))
    assert_equal [:decimal, 0, 10], kind(node(s, "whole"))
    assert_equal [:decimal, 9, 38], kind(node(s, "loose"))
    assert_equal [:decimal, 3, 38], kind(node(s, "loose_scaled"))
    assert_equal [:decimal, 2, 19], kind(node(s, "cash"))
    assert_equal T::BOOLEAN, node(s, "flag").type
    %w[name body email ip net mac weird untyped].each { |n| assert_equal [:string], kind(node(s, n)), n }
    assert_equal T::BYTE_ARRAY, node(s, "blob").type
    assert_equal [nil], kind(node(s, "blob"))
    assert_equal [:date], kind(node(s, "born"))
    %w[at at_ts at_tz].each { |n| assert_equal [:timestamp, :micros, true], kind(node(s, n)), n }
    assert_equal :time, kind(node(s, "clock")).first
    assert_equal :micros, kind(node(s, "clock"))[1]
    assert_equal [:json], kind(node(s, "doc"))
    assert_equal [:json], kind(node(s, "docb"))
    assert_equal [:uuid], kind(node(s, "uid"))
  end

  def test_nullability
    s = schema_for(col("a", :string, null: false), col("b", :string, null: true), col("c", :string, null: nil))
    assert_equal %i[required optional optional], s.root.children.map(&:repetition)
  end

  def test_hstore_is_a_string_map
    s = schema_for(col("attrs", :hstore, "hstore", null: false))
    f = s.field("attrs")
    assert_equal :map, f.kind
    refute f.optional
    assert_equal [:string], kind(f.key.node)
    assert_equal [:string], kind(f.value.node)
    assert f.value.optional
  end

  def test_postgres_arrays
    s = schema_for(
      col("tags", :string, "character varying", array: true),
      col("nums", :integer, "bigint", array: true, null: false),
      col("amounts", :decimal, "numeric(8,2)", precision: 8, scale: 2, array: true),
      col("maps", :hstore, "hstore", array: true),
      PlainColumn.new(name: "suffixed", type: :integer, sql_type: "smallint[]"),
      PlainColumn.new(name: "matrix", type: :float, sql_type: "float4[][]")
    )
    tags = s.field("tags")
    assert_equal :list, tags.kind
    assert tags.optional
    assert tags.element.optional
    assert_equal [:string], kind(tags.element.node)
    nums = s.field("nums")
    refute nums.optional
    assert_equal T::INT64, nums.element.node.type
    assert_equal [:decimal, 2, 8], kind(s.field("amounts").element.node)
    assert_equal :map, s.field("maps").element.kind
    assert_equal [:integer, 16, true], kind(s.field("suffixed").element.node)
    assert_equal T::FLOAT, s.field("matrix").element.node.type
  end

  def test_enums
    model = FakeModel.new(
      columns: [col("id", :integer, "integer"), col("status", :integer, "integer", null: false), col("kind", :string, "varchar")],
      defined_enums: {"status" => {"pending" => 0, "shipped" => 1}, "kind" => {"a" => "a"}}
    )
    s = Herringbone::Schema.from_active_record(model)
    assert_equal [:string], kind(node(s, "status"))
    assert_equal :required, node(s, "status").repetition
    assert_equal [:string], kind(node(s, "kind"))
    assert_equal({"pending" => 0, "shipped" => 1}, node(s, "status").enum_values)

    # Labels and stored values are accepted and written as labels; anything else is rejected
    io = StringIO.new("".b)
    w = Herringbone::Writer.new(io, s)
    w << {"id" => 1, "status" => "shipped", "kind" => "a"}
    w << {"id" => 2, "status" => 0}
    w.close
    assert_equal %w[shipped pending], Herringbone::Reader.new(StringIO.new(io.string)).read.map { |r| r["status"] }
    bad = Herringbone::Writer.new(StringIO.new("".b), s)
    assert_raises(Herringbone::Error) { bad << {"id" => 3, "status" => "lost"} }

    s = Herringbone::Schema.from_active_record(model, parquet_enum: true)
    assert_equal [:enum], kind(node(s, "status"))
    assert_equal [:enum], kind(node(s, "kind"))
  end

  def test_model_without_defined_enums
    s = Herringbone::Schema.from_active_record(BareModel.new([col("id", :integer, "integer"), col("x", :string)], "id"))
    assert_equal %w[id x], s.root.children.map(&:name)
  end

  def test_only_and_except_keep_column_order
    columns = %w[id b a c].map { |n| col(n, :string) }
    model = FakeModel.new(columns: columns)
    assert_equal %w[id b a c], Herringbone::Schema.from_active_record(model).root.children.map(&:name)
    assert_equal %w[b c], Herringbone::Schema.from_active_record(model, only: [:c, "b"]).root.children.map(&:name)
    assert_equal %w[id c], Herringbone::Schema.from_active_record(model, except: %w[a b]).root.children.map(&:name)
    assert_equal %w[b], Herringbone::Schema.from_active_record(model, only: %w[a b], except: :a).root.children.map(&:name)
    assert_raises(ArgumentError) { Herringbone::Schema.from_active_record(model, only: :nope) }
  end

  def test_round_trip_with_fake_model
    model = FakeModel.new(
      columns: [
        col("id", :integer, "bigint", null: false, limit: 8),
        col("name", :string, "varchar", null: false),
        col("status", :integer, "integer"),
        col("price", :decimal, "decimal(10,2)", precision: 10, scale: 2),
        col("ratio", :float, "float"),
        col("paid", :boolean, "boolean"),
        col("ship_on", :date, "date"),
        col("created_at", :datetime, "datetime(6)", precision: 6, null: false),
        col("uid", :uuid, "uuid"),
        col("clock", :time, "time"),
        col("doc", :jsonb, "jsonb"),
        col("tags", :string, "text", array: true),
        col("attrs", :hstore, "hstore")
      ],
      defined_enums: {"status" => {"pending" => 0, "shipped" => 1}}
    )
    schema = Herringbone::Schema.from_active_record(model)
    t = Time.utc(2024, 5, 6, 7, 8, 9, 123_456)
    rows = [
      {"id" => 1, "name" => "Anna", "status" => "pending", "price" => BigDecimal("9.99"), "ratio" => 0.5,
       "paid" => true, "ship_on" => Date.new(2024, 1, 2), "created_at" => t,
       "uid" => "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "clock" => Time.utc(2000, 1, 1, 12, 34, 56, 789_000),
       "doc" => {"a" => [1, 2]}, "tags" => ["x", nil], "attrs" => {"k" => "v"}},
      {"id" => 2**40, "name" => "Bob", "status" => nil, "price" => nil, "ratio" => nil, "paid" => false,
       "ship_on" => nil, "created_at" => t + 1, "uid" => nil, "clock" => nil, "doc" => nil, "tags" => [], "attrs" => nil}
    ]
    io = StringIO.new("".b)
    w = Herringbone::Writer.new(io, schema)
    rows.each { |r| w << r }
    w.close
    read = Herringbone::Reader.new(StringIO.new(io.string)).read
    # TIME reads back as microseconds since midnight, JSON as text
    expected = rows.map(&:dup)
    expected[0]["clock"] = ((12 * 60 + 34) * 60 + 56) * 1_000_000 + 789_000
    expected[0]["doc"] = '{"a":[1,2]}'
    assert_equal expected, read
  end

  # -- real ActiveRecord --

  def with_active_record
    begin
      require "active_record"
      require "sqlite3"
    rescue LoadError
      skip "activerecord and sqlite3 are not installed"
    end
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    yield
  ensure
    ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
  end

  def test_real_active_record_model
    with_active_record do
      ActiveRecord::Schema.define do
        create_table :herringbone_orders, force: true do |t|
          t.string :customer, null: false
          t.integer :status, null: false, default: 0
          t.decimal :total, precision: 10, scale: 2
          t.float :ratio
          t.boolean :paid, null: false, default: false
          t.date :ship_on
          t.time :cutoff
          t.json :payload
          t.text :notes
          t.bigint :big
          t.integer :small, limit: 2
          t.timestamps
        end
      end
      order = Class.new(ActiveRecord::Base) do
        self.table_name = "herringbone_orders"
        enum :status, {pending: 0, shipped: 1, cancelled: 2}
        def self.name = "HerringboneOrder"
      end

      order.create!(customer: "Anna", status: :shipped, total: BigDecimal("12.34"), ratio: 0.25, paid: true,
        ship_on: Date.new(2024, 3, 4), cutoff: "12:34:56.789", payload: {"a" => [1, 2]}, notes: "fragile", big: 2**40, small: -3)
      order.create!(customer: "Bob")

      schema = Herringbone::Schema.from_active_record(order)
      assert_equal order.column_names, schema.root.children.map(&:name)
      assert_equal T::INT64, node(schema, "id").type
      assert_equal :required, node(schema, "id").repetition
      assert_equal [:string], kind(node(schema, "status"))
      assert_equal :required, node(schema, "customer").repetition
      assert_equal :optional, node(schema, "notes").repetition
      assert_equal [:decimal, 2, 10], kind(node(schema, "total"))
      assert_equal [:json], kind(node(schema, "payload"))
      assert_equal T::INT64, node(schema, "big").type
      assert_equal [:integer, 16, true], kind(node(schema, "small"))
      assert_equal [:timestamp, :micros, true], kind(node(schema, "created_at"))

      io = StringIO.new("".b)
      w = Herringbone::Writer.new(io, schema)
      order.find_each { |o| w << o.attributes }
      w.close

      read = Herringbone::Reader.new(StringIO.new(io.string)).read
      expected = order.order(:id).map do |o|
        # JSON is read back as text, TIME as microseconds since midnight
        o.attributes.merge("payload" => o.payload&.to_json, "created_at" => o.created_at.utc,
          "updated_at" => o.updated_at.utc,
          "cutoff" => o.cutoff && ((o.cutoff.hour * 60 + o.cutoff.min) * 60 + o.cutoff.sec) * 1_000_000 + o.cutoff.usec)
      end
      assert_equal 2, read.size
      assert_equal expected, read
      assert_equal "shipped", read[0]["status"]
      assert_equal "pending", read[1]["status"]
      assert_equal({"a" => [1, 2]}, JSON.parse(read[0]["payload"]))
      assert_nil read[1]["payload"]
      assert_equal 45_296_789_000, read[0]["cutoff"]
    end
  end

  def test_write_models_and_relations
    with_active_record do
      ActiveRecord::Schema.define do
        create_table :herringbone_exports, force: true do |t|
          t.string :name, null: false
          t.integer :kind, null: false, default: 0
          t.decimal :amount, precision: 8, scale: 2
          t.timestamps
        end
      end
      model = Class.new(ActiveRecord::Base) do
        self.table_name = "herringbone_exports"
        enum :kind, {free: 0, pro: 1}
        def self.name = "HerringboneExport"
      end
      25.times { |i| model.create!(name: "n#{i}", kind: i.even? ? :free : :pro, amount: BigDecimal(i) / 4) }

      io = StringIO.new("".b)
      assert_equal 25, Herringbone.write(io, model)
      rows = Herringbone::Reader.new(StringIO.new(io.string)).read
      assert_equal model.order(:id).pluck(:name), rows.map { |r| r["name"] }
      assert_equal %w[free pro free], rows.first(3).map { |r| r["kind"] }
      assert_equal BigDecimal("0.25"), rows[1]["amount"]

      io = StringIO.new("".b)
      schema = Herringbone::Schema.from_active_record(model, only: %w[id name])
      assert_equal 12, Herringbone.write(io, model.where(kind: :pro), schema: schema, compression: :gzip)
      reader = Herringbone::Reader.new(StringIO.new(io.string))
      assert_equal %w[id name], reader.schema.fields.map(&:name)
      assert_equal 12, reader.num_rows

      # An Array of records has no columns to read: the schema is inferred from the attributes
      io = StringIO.new("".b)
      assert_equal 3, Herringbone.write(io, model.order(:id).first(3))
      assert_equal %w[n0 n1 n2], Herringbone::Reader.new(StringIO.new(io.string)).read.map { |r| r["name"] }

      Dir.mktmpdir do |dir|
        path = File.join(dir, "export.parquet")
        File.open(path, "wb") { |f| Herringbone.write(f, model.all) }
        assert_equal 25, File.open(path, "rb") { |f| Herringbone::Reader.new(f).num_rows }
      end
    end
  end
end
