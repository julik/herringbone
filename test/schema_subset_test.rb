# frozen_string_literal: true

require_relative "test_helper"

# Schema#only and Schema#except
class SchemaSubsetTest < Minitest::Test
  SCHEMA = Herringbone::Schema.define do |s|
    s.int64 :id, null: false, field_id: 1
    s.string :name
    s.enum :status, values: %w[pending paid]
    s.struct :address do |address|
      address.string :city
      address.int32 :zip
    end
    s.list :tags, :string
    s.map :scores, :string, :double
    s.decimal :price, precision: 12, scale: 2
  end

  def names(schema) = schema.fields.map(&:name)

  def test_only_keeps_the_given_fields_in_schema_order
    assert_equal %w[id address price], names(SCHEMA.only(:price, "id", :address))
  end

  def test_except_drops_the_given_fields
    assert_equal %w[id status address scores price], names(SCHEMA.except(:name, "tags"))
  end

  def test_names_can_come_as_an_array
    assert_equal %w[id name], names(SCHEMA.only(%w[id name]))
    assert_equal %w[id name], names(SCHEMA.except([:status, :address], :tags, :scores, :price))
  end

  def test_kept_fields_are_unchanged
    expected = Herringbone::Schema.define do |s|
      s.int64 :id, null: false, field_id: 1
      s.struct :address do |address|
        address.string :city
        address.int32 :zip
      end
      s.map :scores, :string, :double
    end
    assert_equal expected, SCHEMA.only(:id, :address, :scores)
    assert_equal expected, SCHEMA.except(:name, :status, :tags, :price)
    assert_equal SCHEMA, SCHEMA.only(*names(SCHEMA))
  end

  def test_the_subset_has_its_own_columns_and_levels
    subset = SCHEMA.only(:tags, :address)
    assert_equal [%w[address city], %w[address zip], %w[tags list element]], subset.columns.map(&:path)
    assert_equal [0, 1, 2], subset.columns.map(&:index)
    assert_equal [2, 2, 3], subset.columns.map(&:max_definition_level)
    assert_equal :list, subset.field(:tags).kind
  end

  def test_the_subset_shares_no_nodes_and_keeps_enum_values
    subset = SCHEMA.only(:status)
    refute_same SCHEMA.field(:status).node, subset.field(:status).node
    assert_same subset.root, subset.field(:status).node.parent
    assert_same SCHEMA.root, SCHEMA.field(:status).node.parent
    assert_equal %w[pending paid], subset.field(:status).node.enum_values
  end

  def test_the_root_name_is_kept
    schema = Herringbone::Schema.from_elements(SCHEMA.to_elements.tap { |e| e[0].name = "spark_schema" })
    assert_equal "spark_schema", schema.except(:name).root.name
  end

  def test_unknown_names_raise
    error = assert_raises(ArgumentError) { SCHEMA.only(:id, :nope, :city) }
    assert_equal "Schema#only: no top-level field nope, city. " \
      "The schema has id, name, status, address, tags, scores, price", error.message
    error = assert_raises(ArgumentError) { SCHEMA.except(:nope) }
    assert_match(/\ASchema#except: no top-level field nope\./, error.message)
  end

  def test_no_names_raise
    error = assert_raises(ArgumentError) { SCHEMA.only }
    assert_equal "Schema#only needs the names of top-level fields, e.g. schema.only(:id, :name)", error.message
    assert_raises(ArgumentError) { SCHEMA.except }
  end

  def test_leaving_out_every_field_raises
    error = assert_raises(ArgumentError) { SCHEMA.except(*names(SCHEMA)) }
    assert_match(/\AA schema needs at least one field/, error.message)
  end

  def test_writes_and_reads_with_the_subset
    subset = SCHEMA.except(:status, :scores)
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, subset) do |w|
      w << {id: 1, name: "Anna", address: {city: "Amsterdam", zip: 1000}, tags: %w[a b], price: BigDecimal("9.99")}
    end
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal subset, reader.schema
    assert_equal [{"id" => 1, "name" => "Anna", "address" => {"city" => "Amsterdam", "zip" => 1000},
                   "tags" => %w[a b], "price" => BigDecimal("9.99")}], reader.read
  end
end
