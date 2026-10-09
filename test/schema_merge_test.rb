# frozen_string_literal: true

require_relative "test_helper"

# Schema#==, Schema#union (+) and Schema#intersect (&)
class SchemaMergeTest < Minitest::Test
  Schema = Herringbone::Schema
  Node = Herringbone::Schema::Node
  T = Herringbone::Format::Type
  C = Herringbone::Format::ConvertedType

  def define(&block) = Schema.define(&block)

  # A schema with the single nullable column "v"
  def leaf(type, **opts) = define { |s| s.column :v, type, **opts }

  def raw_leaf(**attrs) = Schema.new(Node.new(name: "schema", repetition: :required, children: [Node.new(name: "v", **attrs)]))

  def assert_widens(left, right, expected)
    [[left, right], [right, left]].each do |a, b|
      [a + b, a & b].each do |merged|
        assert_equal expected, merged, "#{a.fields[0].node.signature.inspect} with #{b.fields[0].node.signature.inspect}"
      end
    end
  end

  def assert_incompatible(left, right, reason = nil)
    [[left, right], [right, left]].each do |a, b|
      %i[union intersect].each do |op|
        error = assert_raises(Herringbone::IncompatibleSchema) { a.public_send(op, b) }
        assert_equal 1, error.conflicts.size
        assert_equal "v", error.conflicts[0].path
        assert_includes error.conflicts[0].reason, reason if reason
      end
    end
  end

  # -- == --

  def test_equal_schemas
    a = define { |s|
      s.int64 :id, null: false
      s.list :tags, :string
      s.struct(:address) { |address| address.string :city }
    }
    b = define { |s|
      s.int64 :id, null: false
      s.list :tags, :string
      s.struct(:address) { |address| address.string :city }
    }
    assert_equal a, b
    assert a.eql?(b)
    assert_equal a.hash, b.hash
    assert_equal [a], [a, b].uniq
  end

  def test_equality_survives_the_footer_round_trip
    a = define { |s|
      s.decimal :price, precision: 12, scale: 2
      s.timestamp :at, unit: :millis, utc: false
      s.map(:scores, :string, :double)
    }
    assert_equal a, Schema.from_elements(a.to_elements)
  end

  def test_equality_ignores_the_root_name_and_enum_values
    a = define { |s| s.enum :status, values: %w[open closed] }
    b = Schema.new(Node.new(name: "spark_schema", repetition: :required, children: [Node.new(name: "status", **Herringbone::Types.physical_attributes(:string))]))
    assert_equal a, b
  end

  def test_inequality
    base = define { |s|
      s.int32 :a
      s.string :b
    }
    others = {
      "order" => define { |s|
        s.string :b
        s.int32 :a
      },
      "name" => define { |s|
        s.int32 :a
        s.string :c
      },
      "nullability" => define { |s|
        s.int32 :a, null: false
        s.string :b
      },
      "width" => define { |s|
        s.int64 :a
        s.string :b
      },
      "annotation" => define { |s|
        s.int32 :a
        s.binary :b
      },
      "field id" => define { |s|
        s.int32 :a, field_id: 1
        s.string :b
      },
      "extra field" => define { |s|
        s.int32 :a
        s.string :b
        s.string :c
      },
      "missing field" => define { |s| s.int32 :a }
    }
    others.each { |what, other| refute_equal base, other, what }
    refute_equal base, "schema"
    refute_equal base, nil
  end

  def test_inequality_of_type_parameters
    refute_equal leaf(:fixed, length: 16), leaf(:fixed, length: 8)
    refute_equal leaf(:decimal, precision: 10, scale: 2), leaf(:decimal, precision: 10, scale: 3)
    refute_equal leaf(:timestamp, unit: :millis), leaf(:timestamp, unit: :micros)
    refute_equal leaf(:timestamp), leaf(:timestamp, utc: false)
  end

  def test_inequality_of_nested_fields
    a = define { |s| s.struct(:address) { |address| address.string :city } }
    b = define { |s| s.struct(:address) { |address| address.string :town } }
    c = define { |s| s.list :address, :string }
    refute_equal a, b
    refute_equal a, c
  end

  # -- Integers --

  INTEGERS = {
    %i[int8 int16] => :int16, %i[int8 int32] => :int32, %i[int8 int64] => :int64,
    %i[int16 int32] => :int32, %i[int16 int64] => :int64, %i[int32 int64] => :int64,
    %i[uint8 uint16] => :uint16, %i[uint8 uint32] => :uint32, %i[uint8 uint64] => :uint64,
    %i[uint16 uint32] => :uint32, %i[uint16 uint64] => :uint64, %i[uint32 uint64] => :uint64,
    # unsigned with signed: a signed integer twice as wide as the unsigned one, at least
    %i[uint8 int8] => :int16, %i[uint8 int16] => :int16, %i[uint8 int32] => :int32, %i[uint8 int64] => :int64,
    %i[uint16 int8] => :int32, %i[uint16 int16] => :int32, %i[uint16 int32] => :int32, %i[uint16 int64] => :int64,
    %i[uint32 int8] => :int64, %i[uint32 int16] => :int64, %i[uint32 int32] => :int64, %i[uint32 int64] => :int64
  }

  INTEGERS.each do |(a, b), widened|
    define_method("test_#{a}_and_#{b}_widen_to_#{widened}") do
      assert_widens leaf(a), leaf(b), leaf(widened)
    end
  end

  %i[int8 int16 int32 int64].each do |signed|
    define_method("test_uint64_and_#{signed}_are_incompatible") do
      assert_incompatible leaf(:uint64), leaf(signed), "uint64 does not fit any signed integer"
    end
  end

  def test_every_integer_with_itself
    %i[int8 int16 int32 int64 uint8 uint16 uint32 uint64].each do |type|
      assert_widens leaf(type), leaf(type), leaf(type)
    end
  end

  def test_legacy_integer_annotations_widen_like_logical_ones
    int8 = raw_leaf(type: T::INT32, converted_type: C::INT_8)
    uint32 = raw_leaf(type: T::INT32, converted_type: C::UINT_32)
    assert_widens int8, leaf(:int16), leaf(:int16)
    assert_widens uint32, leaf(:int32), leaf(:int64)
    assert_widens raw_leaf(type: T::INT32, converted_type: C::INT_32), leaf(:int32), leaf(:int32)
  end

  # -- Floats --

  FLOATS = {
    %i[float16 float] => :float, %i[float16 double] => :double, %i[float double] => :double,
    # integers join floats whose significand holds them: 11 bits in a float16, 24 in a float, 53 in a double
    %i[int8 float16] => :float16, %i[uint8 float16] => :float16,
    %i[int16 float16] => :float, %i[uint16 float16] => :float,
    %i[int32 float16] => :double, %i[uint32 float16] => :double,
    %i[int8 float] => :float, %i[int16 float] => :float, %i[uint16 float] => :float,
    %i[int32 float] => :double, %i[uint32 float] => :double,
    %i[int8 double] => :double, %i[int32 double] => :double, %i[uint32 double] => :double
  }

  FLOATS.each do |(a, b), widened|
    define_method("test_#{a}_and_#{b}_widen_to_#{widened}") do
      assert_widens leaf(a), leaf(b), leaf(widened)
    end
  end

  %i[int64 uint64].product(%i[float16 float double]).each do |int, float|
    define_method("test_#{int}_and_#{float}_are_incompatible") do
      assert_incompatible leaf(int), leaf(float), "#{int} does not fit a double exactly"
    end
  end

  # -- Times and timestamps --

  %i[timestamp time].each do |kind|
    {%i[millis micros] => :micros, %i[millis nanos] => :nanos, %i[micros nanos] => :nanos}.each do |(a, b), finer|
      [true, false].each do |utc|
        define_method("test_#{kind}_#{a}_and_#{b}_#{utc ? "utc" : "local"}_widen_to_#{finer}") do
          assert_widens leaf(kind, unit: a, utc: utc), leaf(kind, unit: b, utc: utc), leaf(kind, unit: finer, utc: utc)
        end
      end
    end

    define_method("test_#{kind}_utc_and_local_are_incompatible") do
      assert_incompatible leaf(kind, unit: :micros), leaf(kind, unit: :micros, utc: false), "one is adjusted to UTC and the other is not"
      assert_incompatible leaf(kind, unit: :millis), leaf(kind, unit: :nanos, utc: false)
    end
  end

  def test_time_millis_widens_from_int32_to_int64_storage
    merged = leaf(:time, unit: :millis) + leaf(:time, unit: :micros)
    assert_equal T::INT64, merged.columns[0].type
  end

  def test_legacy_timestamp_annotation_widens_like_a_logical_one
    millis = raw_leaf(type: T::INT64, converted_type: C::TIMESTAMP_MILLIS)
    assert_widens millis, leaf(:timestamp, unit: :micros), leaf(:timestamp, unit: :micros)
    assert_widens millis, leaf(:timestamp, unit: :millis), leaf(:timestamp, unit: :millis)
    assert_incompatible millis, leaf(:timestamp, unit: :micros, utc: false)
  end

  def test_times_and_timestamps_are_incompatible
    assert_incompatible leaf(:time), leaf(:timestamp), "no common type"
    assert_incompatible leaf(:date), leaf(:timestamp)
    assert_incompatible leaf(:int96), leaf(:timestamp, unit: :nanos)
    assert_incompatible leaf(:timestamp), leaf(:int64)
  end

  # -- Text and binary --

  def test_text_widens_to_string
    string = leaf(:string)
    enum = leaf(:enum, parquet_enum: true)
    json = leaf(:json)
    assert_widens string, enum, string
    assert_widens string, json, string
    assert_widens enum, json, string
    assert_widens enum, enum, enum
    assert_widens json, json, json
  end

  def test_text_with_binary_widens_to_binary
    [leaf(:string), leaf(:enum, parquet_enum: true), leaf(:json)].each do |text|
      assert_widens text, leaf(:binary), leaf(:binary)
    end
  end

  def test_legacy_utf8_annotation_widens_like_a_logical_one
    utf8 = raw_leaf(type: T::BYTE_ARRAY, converted_type: C::UTF8)
    assert_widens utf8, leaf(:string), leaf(:string)
    assert_widens utf8, leaf(:binary), leaf(:binary)
  end

  def test_text_and_binary_are_incompatible_with_other_byte_types
    assert_incompatible leaf(:string), leaf(:bson)
    assert_incompatible leaf(:binary), leaf(:bson)
    assert_incompatible leaf(:string), leaf(:uuid)
    assert_incompatible leaf(:binary), leaf(:fixed, length: 4)
  end

  # -- Decimals --

  def test_decimals_must_have_the_same_precision_and_scale
    reason = "decimals need the same precision and scale"
    assert_incompatible leaf(:decimal, precision: 10, scale: 2), leaf(:decimal, precision: 12, scale: 2), reason
    assert_incompatible leaf(:decimal, precision: 10, scale: 2), leaf(:decimal, precision: 10, scale: 3), reason
    assert_incompatible leaf(:decimal, precision: 10), leaf(:int64), "no common type"
    assert_incompatible leaf(:decimal, precision: 10), leaf(:double)
  end

  def test_the_same_decimal_stored_differently_gets_the_default_storage
    fixed = leaf(:decimal, precision: 8, scale: 2, physical: :fixed)
    assert_widens fixed, leaf(:decimal, precision: 8, scale: 2), leaf(:decimal, precision: 8, scale: 2)
    assert_widens fixed, leaf(:decimal, precision: 8, scale: 2, physical: :binary), leaf(:decimal, precision: 8, scale: 2)
  end

  def test_legacy_decimal_annotation_matches_a_logical_one
    legacy = raw_leaf(type: T::INT32, converted_type: C::DECIMAL, precision: 5, scale: 1)
    assert_widens legacy, leaf(:decimal, precision: 5, scale: 1), leaf(:decimal, precision: 5, scale: 1)
  end

  # -- Everything else --

  def test_types_with_nothing_in_common
    {
      boolean: %i[int32 string double date binary],
      date: %i[int32 int64 string],
      uuid: [[:fixed, {length: 16}], :string],
      float16: [[:fixed, {length: 2}]],
      int96: %i[int64 binary],
      string: %i[int32 int64 double date],
      bson: %i[json]
    }.each do |left, rights|
      rights.each do |right|
        type, opts = right
        assert_incompatible leaf(left), leaf(type, **(opts || {})), "no common type"
      end
    end
    assert_incompatible leaf(:fixed, length: 16), leaf(:fixed, length: 8), "no common type"
  end

  def test_types_without_parameters_with_themselves
    %i[boolean date uuid int96 bson float16 binary].each do |type|
      assert_widens leaf(type), leaf(type), leaf(type)
    end
    assert_widens leaf(:fixed, length: 3), leaf(:fixed, length: 3), leaf(:fixed, length: 3)
  end

  def test_unknown_annotations_only_match_themselves
    interval = raw_leaf(type: T::FIXED_LEN_BYTE_ARRAY, type_length: 12, converted_type: C::INTERVAL)
    assert_widens interval, interval, interval
    assert_incompatible interval, leaf(:fixed, length: 12), "no common type"
    error = assert_raises(Herringbone::IncompatibleSchema) { interval + leaf(:fixed, length: 12) }
    assert_equal "interval", error.conflicts[0].left
  end

  # -- Nullability and field ids --

  def test_union_nullability
    a = define { |s|
      s.int64 :both_required, null: false
      s.int64 :required_and_optional, null: false
      s.int64 :both_optional
      s.int64 :only_left, null: false
    }
    b = define { |s|
      s.int64 :both_required, null: false
      s.int64 :required_and_optional
      s.int64 :both_optional
      s.int64 :only_right, null: false
    }
    expected = define { |s|
      s.int64 :both_required, null: false
      s.int64 :required_and_optional
      s.int64 :both_optional
      s.int64 :only_left
      s.int64 :only_right
    }
    assert_equal expected, a + b
  end

  def test_intersection_nullability
    a = define { |s|
      s.int64 :both_required, null: false
      s.int64 :required_and_optional, null: false
      s.int64 :only_left, null: false
    }
    b = define { |s|
      s.int64 :both_required, null: false
      s.int64 :only_right
      s.int64 :required_and_optional
    }
    expected = define { |s|
      s.int64 :both_required, null: false
      s.int64 :required_and_optional
    }
    assert_equal expected, a & b
    assert_equal expected, b & a
  end

  def test_widening_keeps_nullability
    a = define { |s| s.int32 :v, null: false }
    b = define { |s| s.int64 :v, null: false }
    assert_equal define { |s| s.int64 :v, null: false }, a + b
    assert_equal leaf(:int64), a + leaf(:int64)
  end

  def test_field_ids
    assert_equal leaf(:int64, field_id: 3), leaf(:int32, field_id: 3) + leaf(:int64, field_id: 3)
    assert_equal leaf(:int64, field_id: 3), leaf(:int32, field_id: 3) + leaf(:int64)
    assert_equal leaf(:int64, field_id: 3), leaf(:int32) & leaf(:int64, field_id: 3)
    assert_equal leaf(:int32, field_id: 3), leaf(:int32, field_id: 3) & leaf(:int32)
  end

  def test_different_field_ids_are_incompatible
    error = assert_raises(Herringbone::IncompatibleSchema) { leaf(:int32, field_id: 1) + leaf(:int32, field_id: 2) }
    assert_equal ["v", "field_id 1", "field_id 2"], error.conflicts[0].to_a.first(3)
    assert_raises(Herringbone::IncompatibleSchema) { leaf(:int32, field_id: 1) & leaf(:int32, field_id: 2) }
  end

  def test_enum_values_are_kept_only_when_both_sides_agree
    open_closed = define { |s| s.enum :status, values: %w[open closed] }
    other = define { |s| s.enum :status, values: %w[open closed pending] }
    assert_equal %w[open closed], (open_closed + define { |s| s.enum :status, values: %w[open closed] }).fields[0].node.enum_values
    assert_nil (open_closed + other).fields[0].node.enum_values
    assert_nil (open_closed + define { |s| s.json :status }).fields[0].node.enum_values
  end

  # -- Order --

  def test_union_takes_the_receivers_order_then_the_others
    a = define { |s|
      s.int32 :c
      s.int32 :a
    }
    b = define { |s|
      s.int32 :b
      s.int32 :a
      s.int32 :d
    }
    assert_equal %w[c a b d], (a + b).fields.map(&:name)
    assert_equal %w[b a d c], (b + a).fields.map(&:name)
    assert_equal %w[a], (b & a).fields.map(&:name)
  end

  def test_union_and_intersection_with_itself
    a = define { |s|
      s.int64 :id, null: false
      s.list :tags, :string
      s.map :scores, :string, :double
      s.struct(:address) { |address| address.string :city }
    }
    assert_equal a, a + a
    assert_equal a, a & a
  end

  # -- Nesting --

  def test_union_of_struct_members
    a = define { |s|
      s.struct(:address, null: false) { |address|
        address.string :city, null: false
        address.int32 :zip
      }
    }
    b = define { |s|
      s.struct(:address, null: false) { |address|
        address.int64 :zip
        address.string :street, null: false
        address.string :city, null: false
      }
    }
    expected = define { |s|
      s.struct(:address, null: false) { |address|
        address.string :city, null: false
        address.int64 :zip
        address.string :street
      }
    }
    assert_equal expected, a + b
  end

  def test_intersection_of_struct_members
    a = define { |s|
      s.struct(:address) { |address|
        address.string :city
        address.int32 :zip
      }
    }
    b = define { |s|
      s.struct(:address) { |address|
        address.int64 :zip
        address.string :street
      }
    }
    assert_equal define { |s| s.struct(:address) { |address| address.int64 :zip } }, a & b
  end

  def test_intersection_of_structs_without_common_members
    a = define { |s|
      s.int32 :id
      s.struct(:address) { |address| address.string :city }
    }
    b = define { |s|
      s.int32 :id
      s.struct(:address) { |address| address.string :street }
    }
    error = assert_raises(Herringbone::IncompatibleSchema) { a & b }
    assert_equal "address: fields city vs fields street (no fields in common)", error.conflicts[0].to_s
  end

  def test_intersection_without_common_fields
    error = assert_raises(Herringbone::IncompatibleSchema) { leaf(:int32) & define { |s| s.int32 :w } }
    assert_equal "Cannot intersect the schemas, 1 field does not fit:\n  (top level): fields v vs fields w (no fields in common)", error.message
  end

  def test_list_elements_widen
    a = define { |s| s.list :tags, :int32, element_null: false }
    b = define { |s| s.list :tags, :int64, element_null: false, null: false }
    assert_equal define { |s| s.list :tags, :int64, element_null: false }, a + b
    assert_equal define { |s| s.list :tags, :int32 }, a + define { |s| s.list :tags, :int32 }
  end

  def test_lists_of_structs_merge_their_members
    a = define { |s|
      s.list(:points, :struct) { |points|
        points.float :x
        points.float :y
      }
    }
    b = define { |s|
      s.list(:points, :struct) { |points|
        points.double :x
        points.double :z
      }
    }
    union = define { |s|
      s.list(:points, :struct) { |points|
        points.double :x
        points.float :y
        points.double :z
      }
    }
    assert_equal union, a + b
    assert_equal define { |s| s.list(:points, :struct) { |points| points.double :x } }, a & b
  end

  def test_nested_lists_widen
    a = define { |s| s.list(:matrix) { |matrix| matrix.list :element, :int32 } }
    b = define { |s| s.list(:matrix) { |matrix| matrix.list :element, :int64 } }
    assert_equal define { |s| s.list(:matrix) { |matrix| matrix.list :element, :int64 } }, a + b
  end

  def test_map_keys_and_values_widen
    a = define { |s| s.map :scores, :int32, :float }
    b = define { |s| s.map :scores, :int64, :double }
    merged = a + b
    assert_equal define { |s| s.map :scores, :int64, :double }, merged
    assert_equal :required, merged.columns[0].node.repetition
  end

  def test_maps_of_structs_merge_their_members
    a = define { |s| s.map(:things, :string, :struct) { |things| things.int32 :a } }
    b = define { |s| s.map(:things, :string, :struct) { |things| things.int32 :b } }
    expected = define { |s|
      s.map(:things, :string, :struct) { |things|
        things.int32 :a
        things.int32 :b
      }
    }
    assert_equal expected, a + b
  end

  def test_legacy_two_level_list_widens_into_a_standard_one
    legacy = Schema.new(Node.new(name: "schema", repetition: :required, children: [
      Node.new(name: "tags", repetition: :optional, converted_type: C::LIST, children: [
        Node.new(name: "array", repetition: :repeated, type: T::INT32)
      ])
    ]))
    assert_equal define { |s| s.list :tags, :int64, element_null: false }, legacy + define { |s| s.list :tags, :int64, element_null: false }
    assert_equal define { |s| s.list :tags, :int32, element_null: false }, legacy & define { |s| s.list :tags, :int32, element_null: false }
  end

  def test_bare_repeated_fields
    repeated = ->(type) { raw_leaf(repetition: :repeated, **Herringbone::Types.physical_attributes(type)) }
    assert_equal repeated.call(:int64), repeated.call(:int32) + repeated.call(:int64)
    assert_equal repeated.call(:int32), repeated.call(:int32) & repeated.call(:int32)
    # a bare repeated field is a list of required elements, so it widens into a list like any other
    assert_equal define { |s| s.list :v, :int64 }, repeated.call(:int32) + define { |s| s.list :v, :int64 }
  end

  def test_field_id_of_a_bare_repeated_field_stays_on_the_list
    bare = raw_leaf(repetition: :repeated, type: T::INT32, field_id: 1)
    list = define { |s| s.list(:v, field_id: 1) { |v| v.int64 :element, null: false, field_id: 2 } }
    assert_equal list, bare + list
    assert_equal raw_leaf(repetition: :repeated, type: T::INT64, field_id: 1), bare + raw_leaf(repetition: :repeated, type: T::INT64)
  end

  def test_bare_repeated_field_in_only_one_schema
    repeated = Schema.new(Node.new(name: "schema", repetition: :required, children: [
      Node.new(name: "id", type: T::INT32),
      Node.new(name: "v", repetition: :repeated, type: T::INT32)
    ]))
    error = assert_raises(Herringbone::IncompatibleSchema) { define { |s| s.int32 :id } + repeated }
    assert_equal "v: absent vs repeated int32 (a repeated field cannot be null, so both schemas need it)", error.conflicts[0].to_s
    assert_equal define { |s| s.int32 :id }, repeated & define { |s| s.int32 :id }
  end

  def test_different_kinds_of_field
    leaf = define { |s| s.string :v }
    struct = define { |s| s.struct(:v) { |v| v.string :city } }
    list = define { |s| s.list :v, :string }
    map = define { |s| s.map :v, :string, :string }
    [leaf, struct, list, map].combination(2).each do |a, b|
      error = assert_raises(Herringbone::IncompatibleSchema) { a + b }
      assert_match(/do not mix/, error.conflicts[0].reason)
    end
    error = assert_raises(Herringbone::IncompatibleSchema) { leaf & struct }
    assert_equal "v: string vs struct (a leaf and a struct do not mix)", error.conflicts[0].to_s
  end

  # -- Reporting --

  def test_every_incompatible_field_is_reported_at_once
    a = define { |s|
      s.int64 :id, null: false
      s.string :name
      s.int32 :fine
      s.struct(:address) { |address|
        address.int32 :zip
        address.list :lines, :string
      }
      s.map :scores, :string, :double
      s.timestamp :at
    }
    b = define { |s|
      s.double :id
      s.int32 :name
      s.int64 :fine
      s.struct(:address) { |address|
        address.string :zip
        address.list :lines, :boolean
      }
      s.map :scores, :int32, :int64
      s.timestamp :at, utc: false
    }
    error = assert_raises(Herringbone::IncompatibleSchema) { a + b }
    assert_equal <<~MESSAGE.chomp, error.message
      Cannot unite the schemas, 7 fields do not fit:
        id: int64 vs double (int64 does not fit a double exactly)
        name: string vs int32 (no common type)
        address.zip: int32 vs string (no common type)
        address.lines.element: string vs boolean (no common type)
        scores.key: string vs int32 (no common type)
        scores.value: double vs int64 (int64 does not fit a double exactly)
        at: timestamp(micros, UTC) vs timestamp(micros, local) (one is adjusted to UTC and the other is not)
    MESSAGE
    assert_equal %w[id name address.zip address.lines.element scores.key scores.value at], error.conflicts.map(&:path)
    assert_kind_of Herringbone::Error, error
  end

  # -- API --

  def test_operators_are_aliases
    a = leaf(:int32)
    b = define { |s|
      s.int64 :v
      s.string :w
    }
    assert_equal a.union(b), a + b
    assert_equal a.intersect(b), a & b
  end

  def test_other_must_be_a_schema
    assert_raises(ArgumentError) { leaf(:int32) + "v" }
    assert_raises(ArgumentError) { leaf(:int32) & nil }
  end

  def test_result_shares_no_nodes_with_the_inputs
    a = define { |s| s.struct(:address) { |address| address.string :city } }
    b = define { |s| s.int32 :id }
    merged = a + b
    merged.root.children[0].children[0].name = "town"
    assert_equal "city", a.fields[0].children[0].name
    refute_same a.root.children[0], merged.root.children[0]
    assert_same merged.root, merged.root.children[0].parent
  end

  def test_rows_of_both_schemas_fit_the_union
    a = define { |s|
      s.int32 :id, null: false
      s.uint16 :count
      s.timestamp :at, unit: :millis
      s.struct(:address) { |address| address.string :city }
    }
    b = define { |s|
      s.int64 :id, null: false
      s.int16 :count
      s.timestamp :at, unit: :micros
      s.struct(:address) { |address| address.string :zip }
      s.list :tags, :json
    }
    at = Time.utc(2026, 10, 9, 12, 0, 0, 123_456)
    rows = [
      {"id" => 2**31 - 1, "count" => 65_535, "at" => Time.utc(2026, 1, 1), "address" => {"city" => "Lyon"}},
      {"id" => 2**40, "count" => -5, "at" => at, "address" => {"zip" => "69001"}, "tags" => ['{"a":1}']}
    ]
    io = StringIO.new
    Herringbone.write(io, rows, schema: a + b)
    read = Herringbone::Reader.new(StringIO.new(io.string)).read
    assert_equal [2**31 - 1, 2**40], read.map { |r| r["id"] }
    assert_equal [65_535, -5], read.map { |r| r["count"] }
    assert_equal at, read[1]["at"]
    assert_equal [{"city" => "Lyon", "zip" => nil}, {"city" => nil, "zip" => "69001"}], read.map { |r| r["address"] }
    assert_equal [nil, ['{"a":1}']], read.map { |r| r["tags"] }
  end
end
