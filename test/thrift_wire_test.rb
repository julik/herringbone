# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

# Thrift compact protocol: round trips, the exact bytes written, skipping and real Parquet metadata
class ThriftWireTest < Minitest::Test
  Thrift = Herringbone::Thrift
  Format = Herringbone::Format
  PARQUET_TESTING = File.join(FIXTURES_DIR, "parquet-testing")

  class Inner < Herringbone::Thrift::Struct
    field 1, :id, :i32
    field 2, :label, :string
  end

  class Everything < Herringbone::Thrift::Struct
    field 1, :flag, :bool
    field 2, :tiny, :byte
    field 3, :short, :i16
    field 4, :int, :i32
    field 5, :long, :i64
    field 6, :real, :double
    field 7, :blob, :binary
    field 8, :text, :string
    field 9, :ints, [:list, :i32]
    field 10, :flags, [:list, :bool]
    field 11, :texts, [:list, :string]
    field 12, :inner, Inner
    field 13, :inners, [:list, Inner]
    field 14, :matrix, [:list, [:list, :i64]]
    field 15, :doubles, [:list, :double]
    field 40, :far, :i32
  end

  # Knows only two of Everything's fields, as an older reader would
  class Sparse < Herringbone::Thrift::Struct
    field 4, :int, :i32
    field 40, :far, :i32
  end

  class Pair < Herringbone::Thrift::Struct
    field 1, :a, :i32
    field 2, :b, :i32
  end

  class Node < Herringbone::Thrift::Struct
    field 1, :child, Node
  end

  def varint(n)
    Thrift::Writer.new.tap { |w| w.write_varint(n) }.buf
  end

  def zigzag(n)
    Thrift::Writer.new.tap { |w| w.write_zigzag(n) }.buf
  end

  def hex(s)
    s.unpack1("H*")
  end

  def round_trip(obj)
    bytes = obj.encode
    decoded, pos = obj.class.decode(bytes)
    assert_equal bytes.bytesize, pos
    decoded
  end

  def full_everything
    Everything.new(
      flag: true, tiny: -7, short: -300, int: 70_000, long: -(2**40), real: 2.5,
      blob: "\x00\xFF\x80".b, text: "Grüße", ints: [1, -1, 0], flags: [true, false, true],
      texts: ["", "a", "ü"], inner: Inner.new(id: 3, label: "x"),
      inners: [Inner.new(id: 1), Inner.new(label: "two")], matrix: [[1, 2], [], [-3]],
      doubles: [0.5, -1.25], far: 9
    )
  end

  def parquet_footer(name)
    data = File.binread(File.join(PARQUET_TESTING, name))
    len = data.byteslice(-8, 4).unpack1("V")
    [data, data.byteslice(-8 - len, len)]
  end

  # -- round trips --

  def test_round_trips_every_field_type
    obj = full_everything
    assert_equal obj, round_trip(obj)
  end

  def test_round_trips_bools
    assert_equal true, round_trip(Everything.new(flag: true)).flag
    assert_equal false, round_trip(Everything.new(flag: false)).flag
  end

  def test_round_trips_byte_boundaries
    [-128, -1, 0, 1, 127].each do |v|
      assert_equal v, round_trip(Everything.new(tiny: v)).tiny
    end
  end

  def test_round_trips_integer_boundaries
    {short: 16, int: 32, long: 64}.each do |name, bits|
      [-(2**(bits - 1)), -(2**(bits - 1)) + 1, -1, 0, 1, 2**(bits - 1) - 1].each do |v|
        assert_equal v, round_trip(Everything.new(name => v)).public_send(name), "#{name} = #{v}"
      end
    end
  end

  def test_round_trips_special_doubles
    [0.0, 1.0, -1.5, Float::INFINITY, -Float::INFINITY, Float::MAX, Float::MIN, Float::EPSILON,
      5e-324].each do |v|
      assert_equal v, round_trip(Everything.new(real: v)).real
    end
  end

  def test_round_trips_nan
    assert_predicate round_trip(Everything.new(real: Float::NAN)).real, :nan?
  end

  def test_round_trips_negative_zero
    real = round_trip(Everything.new(real: -0.0)).real
    assert_equal 0.0, real
    assert_equal(-Float::INFINITY, 1 / real)
  end

  def test_round_trips_empty_strings
    decoded = round_trip(Everything.new(blob: "".b, text: ""))
    assert_equal "", decoded.blob
    assert_equal "", decoded.text
  end

  def test_round_trips_every_byte_value_in_binary
    all_bytes = (0..255).to_a.pack("C*")
    decoded = round_trip(Everything.new(blob: all_bytes))
    assert_equal all_bytes, decoded.blob
    assert_equal Encoding::BINARY, decoded.blob.encoding
  end

  def test_strings_come_back_as_utf8
    decoded = round_trip(Everything.new(text: "日本語"))
    assert_equal "日本語", decoded.text
    assert_equal Encoding::UTF_8, decoded.text.encoding
  end

  def test_long_binary_round_trips
    blob = Random.new(42).bytes(70_000)
    assert_equal blob, round_trip(Everything.new(blob: blob)).blob
  end

  def test_round_trips_empty_lists
    decoded = round_trip(Everything.new(ints: [], flags: [], texts: [], inners: [], matrix: []))
    assert_equal [], decoded.ints
    assert_equal [], decoded.flags
    assert_equal [], decoded.texts
    assert_equal [], decoded.inners
    assert_equal [], decoded.matrix
  end

  def test_round_trips_long_lists
    ints = (-500..500).to_a
    flags = Array.new(100) { |i| i.odd? }
    decoded = round_trip(Everything.new(ints: ints, flags: flags))
    assert_equal ints, decoded.ints
    assert_equal flags, decoded.flags
  end

  def test_round_trips_list_sizes_around_the_short_header_limit
    [13, 14, 15, 16].each do |n|
      assert_equal((1..n).to_a, round_trip(Everything.new(ints: (1..n).to_a)).ints)
    end
  end

  def test_round_trips_lists_of_structs_with_unset_fields
    inners = [Inner.new, Inner.new(id: 0), Inner.new(label: "")]
    assert_equal inners, round_trip(Everything.new(inners: inners)).inners
  end

  def test_round_trips_deeply_nested_lists
    matrix = [[2**62, -(2**62)], [0], [], Array.new(20) { |i| i }]
    assert_equal matrix, round_trip(Everything.new(matrix: matrix)).matrix
  end

  def test_round_trips_recursive_structs
    node = Node.new(child: Node.new(child: Node.new))
    assert_equal node, round_trip(node)
  end

  # -- optional fields --

  def test_nil_fields_are_left_out
    assert_equal "\x00".b, Everything.new.encode
    assert_equal "\x00".b, Everything.new(int: nil, text: nil, inner: nil).encode
  end

  def test_unset_fields_decode_as_nil
    decoded = round_trip(Everything.new(int: 1))
    (Everything.fields.map(&:name) - [:int]).each do |name|
      assert_nil decoded.public_send(name), name
    end
  end

  def test_empty_struct_decodes_with_everything_nil
    decoded, pos = Everything.decode("\x00".b)
    assert_equal 1, pos
    assert_equal({}, decoded.to_h)
  end

  # -- wire format --

  def test_varint_bytes
    assert_equal "00", hex(varint(0))
    assert_equal "7f", hex(varint(127))
    assert_equal "8001", hex(varint(128))
    assert_equal "ac02", hex(varint(300))
    assert_equal "ffffffffffffffffff01", hex(varint(2**64 - 1))
  end

  def test_negative_varint_is_refused
    assert_raises(Thrift::Error) { varint(-1) }
  end

  def test_zigzag_bytes
    assert_equal "00", hex(zigzag(0))
    assert_equal "01", hex(zigzag(-1))
    assert_equal "02", hex(zigzag(1))
    assert_equal "03", hex(zigzag(-2))
    assert_equal "04", hex(zigzag(2))
    assert_equal "feffffff0f", hex(zigzag(2**31 - 1))
    assert_equal "ffffffff0f", hex(zigzag(-(2**31)))
    assert_equal "feffffffffffffffff01", hex(zigzag(2**63 - 1))
    assert_equal "ffffffffffffffffff01", hex(zigzag(-(2**63)))
  end

  def test_reader_decodes_zigzag_boundaries
    [0, -1, 1, 2**31 - 1, -(2**31), 2**63 - 1, -(2**63)].each do |n|
      assert_equal n, Thrift::Reader.new(zigzag(n)).read_zigzag
    end
  end

  def test_scalar_field_bytes
    assert_equal "450a00", hex(Everything.new(int: 5).encode)
    assert_equal "340400", hex(Everything.new(short: 2).encode)
    assert_equal "560100", hex(Everything.new(long: -1).encode)
    assert_equal "23ff00", hex(Everything.new(tiny: -1).encode)
    assert_equal "67000000000000f03f00", hex(Everything.new(real: 1.0).encode)
    assert_equal "780300018000", hex(Everything.new(blob: "\x00\x01\x80".b).encode)
    assert_equal "8802c3a900", hex(Everything.new(text: "é").encode)
  end

  def test_bools_live_in_the_field_header
    assert_equal "1100", hex(Everything.new(flag: true).encode)
    assert_equal "1200", hex(Everything.new(flag: false).encode)
    assert_equal "11130000", hex(Everything.new(flag: true, tiny: 0).encode)
  end

  def test_consecutive_fields_use_delta_headers
    assert_equal "1500150200", hex(Pair.new(a: 0, b: 1).encode)
    assert_equal "250200", hex(Pair.new(b: 1).encode)
  end

  def test_delta_of_fifteen_still_fits_the_header
    assert_equal "f90700", hex(Everything.new(doubles: []).encode)
  end

  def test_field_id_gaps_over_fifteen_use_the_long_form
    # field 40 after field 4 is a gap of 36
    assert_equal "4502055002", hex(Everything.new(int: 1, far: 1).encode)[0, 10]
    assert_equal "05500200", hex(Everything.new(far: 1).encode)
  end

  def test_long_form_field_header_followed_by_a_delta
    buf = "\x05".b + zigzag(40) + "\x02".b + "\x15\x04\x00".b
    decoded, = Everything.decode(buf)
    assert_equal 1, decoded.far
    assert_nil decoded.int
  end

  def test_decoder_accepts_long_form_headers_for_small_ids
    decoded, = Pair.decode("\x05".b + zigzag(2) + zigzag(7) + "\x05".b + zigzag(1) + zigzag(3) + "\x00".b)
    assert_equal 3, decoded.a
    assert_equal 7, decoded.b
  end

  def test_short_list_header
    assert_equal "9925020400", hex(Everything.new(ints: [1, 2]).encode)
    assert_equal "990500", hex(Everything.new(ints: []).encode)
  end

  def test_list_header_holds_fourteen_elements
    encoded = Everything.new(ints: Array.new(14, 0)).encode
    assert_equal "99e5", hex(encoded)[0, 4]
    assert_equal 2 + 14 + 1, encoded.bytesize
  end

  def test_list_of_fifteen_switches_to_the_long_header
    encoded = Everything.new(ints: Array.new(15, 0)).encode
    assert_equal "99f50f", hex(encoded)[0, 6]
    assert_equal 3 + 15 + 1, encoded.bytesize
  end

  def test_list_of_300_has_a_two_byte_varint_size
    assert_equal "99f5ac02", hex(Everything.new(ints: Array.new(300, 0)).encode)[0, 8]
  end

  def test_bools_in_lists_are_full_bytes
    assert_equal "a93101020100", hex(Everything.new(flags: [true, false, true]).encode)
  end

  def test_bools_in_lists_read_zero_as_false
    decoded, = Everything.decode("\xA9\x31\x01\x00\x02\x00".b)
    assert_equal [true, false, false], decoded.flags
  end

  def test_nested_struct_bytes
    assert_equal "cc15060000", hex(Everything.new(inner: Inner.new(id: 3)).encode)
    assert_equal "cc0000", hex(Everything.new(inner: Inner.new).encode)
  end

  def test_list_of_structs_bytes
    assert_equal "d92c15020015000000", hex(Everything.new(inners: [Inner.new(id: 1), Inner.new(id: 0)]).encode)
  end

  def test_nested_list_bytes
    assert_equal "e9292602040600", hex(Everything.new(matrix: [[1, 2], []]).encode)
  end

  def test_stop_byte_ends_the_struct
    encoded = Everything.new(int: 1).encode
    assert_equal Thrift::T_STOP, encoded.getbyte(-1)
  end

  def test_writer_appends_to_the_given_buffer
    buf = "head".b
    Thrift::Writer.new(buf).write_struct(Pair.new(a: 1))
    assert_equal "head\x15\x02\x00".b, buf
  end

  def test_writer_refuses_integers_it_could_not_read_back
    [[:tiny, 128], [:tiny, -129], [:short, 2**15], [:short, -2**15 - 1], [:int, 2**31],
      [:int, -2**31 - 1], [:long, 2**63], [:long, -2**63 - 1]].each do |name, value|
      assert_raises(Thrift::Error, "#{name}=#{value}") { Everything.new(name => value).encode }
    end
  end

  def test_writer_refuses_an_out_of_range_integer_inside_a_list
    assert_raises(Thrift::Error) { Everything.new(ints: [1, 2**31]).encode }
    assert_raises(Thrift::Error) { Everything.new(matrix: [[2**63]]).encode }
  end

  def test_writer_refuses_values_that_are_not_integers
    assert_raises(Thrift::Error) { Everything.new(ints: [1, nil]).encode }
    assert_raises(Thrift::Error) { Everything.new(tiny: "x").encode }
    assert_raises(Thrift::Error) { Everything.new(int: 1.5).encode }
  end

  def test_writer_refuses_strings_that_are_not_utf8
    assert_raises(Thrift::Error) { Everything.new(text: "\xFF").encode }
    assert_raises(Thrift::Error) { Everything.new(text: "\xFF".b).encode }
    assert_raises(Thrift::Error) { Everything.new(texts: ["ok", "\xC3"]).encode }
    assert_raises(Thrift::Error) { Everything.new(text: (+"\xFF").force_encoding(Encoding::Shift_JIS)).encode }
  end

  def test_writer_converts_strings_to_utf8
    latin = "café".encode(Encoding::ISO_8859_1)
    assert_equal "café", round_trip(Everything.new(text: latin)).text
    assert_equal "日本語", round_trip(Everything.new(text: "日本語".encode(Encoding::UTF_16LE))).text
    assert_equal "café", round_trip(Everything.new(text: "café".b)).text
    assert_equal "plain", round_trip(Everything.new(text: "plain".encode(Encoding::US_ASCII))).text
  end

  def test_writer_leaves_binary_fields_alone
    assert_equal "\xFF".b, round_trip(Everything.new(blob: "\xFF")).blob
  end

  def test_binary_comes_back_as_binary_from_a_utf8_buffer
    buf = Everything.new(blob: "abc", text: "abc").encode.dup.force_encoding(Encoding::UTF_8)
    decoded = Everything.decode(buf).first
    assert_equal Encoding::BINARY, decoded.blob.encoding
    assert_equal Encoding::UTF_8, decoded.text.encoding
  end

  def test_negative_offset_is_refused
    assert_raises(Thrift::Error) { Pair.decode("\x15\x02\x00".b, -3) }
  end

  class PairWithMore < Pair
    field 3, :c, :i32
  end

  class PlainPairSubclass < Pair
  end

  def test_struct_subclasses_inherit_fields
    assert_equal "\x15\x02\x00".b, PlainPairSubclass.new(a: 1).encode
    assert_equal [:a, :b, :c], PairWithMore.fields.map(&:name)
    assert_equal({a: 1, c: 3}, round_trip(PairWithMore.new(a: 1, c: 3)).to_h)
    assert_equal [:a, :b], Pair.fields.map(&:name)
  end

  def test_equal_structs_are_eql_and_hash_alike
    one = Pair.new(a: 1, b: 2)
    other = Pair.new(a: 1, b: 2)
    assert one.eql?(other)
    assert_equal one.hash, other.hash
    assert_equal [one], [one, other].uniq
    refute_equal Pair.new(a: 1).hash, PlainPairSubclass.new(a: 1).hash
  end

  def test_wire_type_for
    assert_equal Thrift::T_TRUE, Thrift.wire_type_for(:bool)
    assert_equal Thrift::T_BINARY, Thrift.wire_type_for(:string)
    assert_equal Thrift::T_LIST, Thrift.wire_type_for([:list, :i32])
    assert_equal Thrift::T_STRUCT, Thrift.wire_type_for(Inner)
    assert_raises(KeyError) { Thrift.wire_type_for(:float) }
  end

  def test_compatible_wire_types
    assert Thrift.compatible?(Thrift::T_FALSE, :bool)
    assert Thrift.compatible?(Thrift::T_I16, :i64)
    assert Thrift.compatible?(Thrift::T_I64, :i16)
    assert Thrift.compatible?(Thrift::T_SET, [:list, :i32])
    assert Thrift.compatible?(Thrift::T_BINARY, :string)
    refute Thrift.compatible?(Thrift::T_BYTE, :i32)
    refute Thrift.compatible?(Thrift::T_I32, :byte)
    refute Thrift.compatible?(Thrift::T_I32, :double)
    refute Thrift.compatible?(Thrift::T_LIST, Inner)
    refute Thrift.compatible?(Thrift::T_STRUCT, [:list, Inner])
  end

  # -- reading what other writers produce --

  def test_integer_widths_are_interchangeable_on_the_wire
    decoded, = Everything.decode("\x36".b + zigzag(-5) + "\x16".b + zigzag(7) + "\x00".b)
    assert_equal(-5, decoded.short)
    assert_equal 7, decoded.int
  end

  def test_a_set_is_read_where_a_list_is_declared
    decoded, = Everything.decode("\x9A\x25\x02\x04\x00".b)
    assert_equal [1, 2], decoded.ints
  end

  def test_fields_may_come_in_any_order
    decoded, = Pair.decode("\x25\x04\x05".b + zigzag(1) + zigzag(9) + "\x00".b)
    assert_equal 9, decoded.a
    assert_equal 2, decoded.b
  end

  def test_a_repeated_field_keeps_the_last_value
    decoded, = Pair.decode("\x15\x02\x05".b + zigzag(1) + zigzag(5) + "\x00".b)
    assert_equal 5, decoded.a
  end

  def far_is_one
    "\x05".b + zigzag(40) + "\x02\x00".b
  end

  def test_a_field_of_the_wrong_wire_type_is_skipped
    # field 4 (an i32) arrives as a string, field 5 after it is still read
    decoded, = Everything.decode("\x48\x03abc\x16\x02\x00".b)
    assert_nil decoded.int
    assert_equal 1, decoded.long
  end

  def test_a_list_of_the_wrong_element_type_is_skipped_whole
    decoded, = Everything.decode("\x99\x28\x01a\x01b".b + far_is_one)
    assert_nil decoded.ints
    assert_equal 1, decoded.far
  end

  def test_a_list_of_bools_where_ints_are_declared_is_skipped
    decoded, = Everything.decode("\x99\x21\x01\x02".b + far_is_one)
    assert_nil decoded.ints
    assert_equal 1, decoded.far
  end

  def test_an_empty_list_of_the_wrong_element_type_is_empty
    decoded, = Everything.decode("\x99\x08\x00".b)
    assert_equal [], decoded.ints
  end

  def test_struct_where_a_scalar_is_declared_is_skipped
    decoded, = Everything.decode("\x4C\x15\x02\x00\x16\x02\x00".b)
    assert_nil decoded.int
    assert_equal 1, decoded.long
  end

  # -- skipping unknown fields --

  def test_unknown_fields_of_every_type_are_skipped
    decoded, pos = Sparse.decode(full_everything.encode)
    assert_equal full_everything.encode.bytesize, pos
    assert_equal 70_000, decoded.int
    assert_equal 9, decoded.far
  end

  def test_unknown_fields_are_skipped_with_boundary_values
    obj = Everything.new(
      flag: false, tiny: -128, short: -(2**15), int: 2**31 - 1, long: -(2**63), real: Float::NAN,
      blob: "", text: "", ints: [], flags: Array.new(20, false), texts: Array.new(16, "x"),
      inner: Inner.new, inners: [], matrix: [[], [2**63 - 1]], doubles: [-0.0], far: -(2**31)
    )
    decoded, pos = Sparse.decode(obj.encode)
    assert_equal obj.encode.bytesize, pos
    assert_equal 2**31 - 1, decoded.int
    assert_equal(-(2**31), decoded.far)
  end

  def test_unknown_map_is_skipped
    # field 3, a map<i32, string> of 2 entries, then field 4 = 1
    map = "\x3B".b + varint(2) + "\x58".b + zigzag(1) + "\x01a".b + zigzag(2) + "\x01b".b
    decoded, = Sparse.decode(map + "\x15\x02\x00".b)
    assert_equal 1, decoded.int
  end

  def test_unknown_map_of_bools_and_structs_is_skipped
    # map<bool, struct> with one entry: key true as a full byte, then a struct
    map = "\x3B".b + varint(1) + "\x1C".b + "\x01".b + "\x15\x02\x00".b
    decoded, = Sparse.decode(map + "\x15\x04\x00".b)
    assert_equal 2, decoded.int
  end

  def test_unknown_empty_map_is_skipped
    decoded, = Sparse.decode("\x3B\x00\x15\x06\x00".b)
    assert_equal 3, decoded.int
  end

  def test_unknown_set_is_skipped
    decoded, = Sparse.decode("\x3A\x35\x02\x04\x06\x15\x02\x00".b)
    assert_equal 1, decoded.int
  end

  def test_unknown_long_form_field_inside_a_skipped_struct
    inner = "\x05".b + zigzag(1000) + zigzag(1) + "\x18\x01z\x00".b
    decoded, = Sparse.decode("\x3C".b + inner + "\x15\x02\x00".b)
    assert_equal 1, decoded.int
  end

  def test_unknown_field_id_with_a_huge_gap
    decoded, = Sparse.decode("\x08".b + zigzag(32_000) + "\x01x\x05".b + zigzag(4) + zigzag(2) + "\x00".b)
    assert_equal 2, decoded.int
  end

  def test_unknown_wire_type_is_an_error
    [13, 14, 15].each do |wire|
      assert_raises(Thrift::Error) { Sparse.decode([0x30 | wire, 0].pack("C*")) }
    end
  end

  def test_skip_refuses_the_stop_type
    assert_raises(Thrift::Error) { Thrift::Reader.new("\x00".b).skip(Thrift::T_STOP) }
  end

  # -- unions --

  def test_logical_type_round_trips_with_kind
    ts = Format::TimestampType.new(is_adjusted_to_utc: true, unit: Format::TimeUnit.micros)
    decoded = round_trip(Format::LogicalType.new(timestamp: ts))
    assert_equal [:timestamp, ts], decoded.kind
    assert_equal :micros, decoded.timestamp.unit.to_sym
  end

  def test_every_logical_type_member_round_trips
    {
      string: Format::StringType.new, map: Format::MapType.new, list: Format::ListType.new,
      enum: Format::EnumType.new, decimal: Format::DecimalType.new(scale: 2, precision: 10),
      date: Format::DateType.new,
      time: Format::TimeType.new(is_adjusted_to_utc: false, unit: Format::TimeUnit.nanos),
      timestamp: Format::TimestampType.new(is_adjusted_to_utc: true, unit: Format::TimeUnit.millis),
      integer: Format::IntType.new(bit_width: 8, is_signed: false), unknown: Format::NullType.new,
      json: Format::JsonType.new, bson: Format::BsonType.new, uuid: Format::UUIDType.new,
      float16: Format::Float16Type.new, variant: Format::VariantType.new(specification_version: 1)
    }.each do |name, member|
      decoded = round_trip(Format::LogicalType.new(name => member))
      assert_equal [name, member], decoded.kind, name
    end
  end

  def test_union_bytes
    assert_equal "1c0000", hex(Format::LogicalType.new(string: Format::StringType.new).encode)
    # integer is field 10, a delta of 10 from 0
    assert_equal "ac1340120000", hex(Format::LogicalType.new(integer: Format::IntType.new(bit_width: 64, is_signed: false)).encode)
    assert_equal "2c0000", hex(Format::TimeUnit.micros.encode)
  end

  def test_time_unit_to_sym
    %i[millis micros nanos].each do |unit|
      assert_equal unit, round_trip(Format::TimeUnit.public_send(unit)).to_sym
    end
    assert_nil Format::TimeUnit.new.to_sym
  end

  def test_unknown_union_member_decodes_as_an_empty_union
    # member 17 is not in our parquet.thrift yet
    decoded, pos = Format::LogicalType.decode("\x0C".b + zigzag(17) + "\x15\x02\x00\x00".b)
    assert_equal 6, pos
    assert_nil decoded.kind
    assert_equal({}, decoded.to_h)
    assert_equal Format::LogicalType.new, decoded
  end

  def test_reserved_union_member_decodes_as_an_empty_union
    decoded, = Format::LogicalType.decode("\x9C\x00\x00".b)
    assert_nil decoded.kind
  end

  def test_empty_union_kind_is_nil
    assert_nil Format::LogicalType.new.kind
  end

  def test_unknown_logical_type_from_a_real_file
    _, footer = parquet_footer("unknown-logical-type.parquet")
    fmd, = Format::FileMetaData.decode(footer)
    logical = fmd.schema.map(&:logical_type).compact
    refute_empty logical
    assert logical.any? { |lt| lt.kind.nil? }
  end

  def test_unknown_column_order_from_a_real_file
    _, footer = parquet_footer("int96_timestamp_order.parquet")
    fmd, = Format::FileMetaData.decode(footer)
    assert_equal [{}], fmd.column_orders.map(&:to_h)
  end

  # -- to_h, ==, inspect, initialize --

  def test_to_h_converts_nested_structs_and_leaves_out_nils
    obj = Everything.new(int: 1, inner: Inner.new(id: 2), inners: [Inner.new(label: "x")], ints: [1])
    assert_equal({int: 1, ints: [1], inner: {id: 2}, inners: [{label: "x"}]}, obj.to_h)
  end

  def test_equality
    assert_equal Pair.new(a: 1, b: 2), Pair.new(b: 2, a: 1)
    refute_equal Pair.new(a: 1), Pair.new(a: 1, b: 2)
    refute_equal Pair.new(a: 1), Pair.new(a: 2)
    refute_equal Pair.new, Inner.new
    refute_equal Pair.new(a: 1), {a: 1}
    assert_equal Format::TimeUnit.millis, Format::TimeUnit.millis
    refute_equal Format::TimeUnit.millis, Format::TimeUnit.micros
  end

  def test_inspect
    assert_equal "#<Pair a=1 b=2>", Pair.new(a: 1, b: 2).inspect
    assert_equal "#<Inner label=\"x\">", Inner.new(label: "x").inspect
  end

  def test_unknown_attribute_is_refused
    assert_raises(ArgumentError) { Pair.new(c: 1) }
  end

  def test_fields_are_sorted_by_id_and_indexed
    assert_equal Everything.fields.map(&:id).sort, Everything.fields.map(&:id)
    assert_equal :far, Everything.fields_by_id.fetch(40).name
    assert_equal :@far, Everything.fields_by_id.fetch(40).ivar
    assert_predicate Everything.fields, :frozen?
  end

  # -- decoding at an offset --

  def test_decode_at_an_offset_returns_the_end_position
    encoded = Pair.new(a: 1, b: 2).encode
    buf = "garbage!".b + encoded + "trailing".b
    decoded, pos = Pair.decode(buf, 8)
    assert_equal Pair.new(a: 1, b: 2), decoded
    assert_equal 8 + encoded.bytesize, pos
  end

  def test_decoding_back_to_back_structs
    structs = [Pair.new(a: 1), full_everything, Pair.new, Pair.new(a: -1, b: 2**31 - 1)]
    buf = structs.map(&:encode).join
    pos = 0
    structs.each do |s|
      decoded, pos = s.class.decode(buf, pos)
      assert_equal s, decoded
    end
    assert_equal buf.bytesize, pos
  end

  def test_reader_keeps_its_position
    reader = Thrift::Reader.new("xx\x15\x02\x00\x05".b, 2)
    assert_equal Pair.new(a: 1), reader.read_struct(Pair)
    assert_equal 5, reader.pos
  end

  def test_decode_past_the_end_is_an_error
    assert_raises(Thrift::Error) { Pair.decode("\x15\x02\x00".b, 3) }
    assert_raises(Thrift::Error) { Pair.decode("".b) }
  end

  # -- truncated input --

  def assert_every_truncation_fails(encoded, klass)
    Timeout.timeout(10) do
      encoded.bytesize.times do |len|
        assert_raises(Thrift::Error, "#{klass} truncated to #{len} bytes") do
          klass.decode(encoded.byteslice(0, len))
        end
      end
    end
  end

  def test_every_truncation_of_a_struct_with_all_types_fails
    assert_every_truncation_fails full_everything.encode, Everything
  end

  def test_every_truncation_of_a_struct_seen_by_a_sparse_reader_fails
    assert_every_truncation_fails full_everything.encode, Sparse
  end

  def test_every_truncation_of_a_long_list_fails
    assert_every_truncation_fails Everything.new(ints: (0..40).to_a, texts: Array.new(20, "ab")).encode, Everything
  end

  def test_every_truncation_of_a_real_footer_fails
    _, footer = parquet_footer("alltypes_plain.parquet")
    assert_every_truncation_fails footer, Format::FileMetaData
  end

  def test_every_truncation_of_a_real_page_header_fails
    data, footer = parquet_footer("datapage_v2.snappy.parquet")
    fmd, = Format::FileMetaData.decode(footer)
    offset = fmd.row_groups.first.columns.first.meta_data.data_page_offset
    _, stop = Format::PageHeader.decode(data, offset)
    assert_every_truncation_fails data.byteslice(offset, stop - offset), Format::PageHeader
  end

  def test_corrupted_bytes_raise_only_thrift_errors
    _, footer = parquet_footer("alltypes_plain.parquet")
    outcomes = Hash.new(0)
    Timeout.timeout(10) do
      footer.bytesize.times do |i|
        [0x00, 0x0F, 0x1C, 0x7F, 0x80, 0xFF].each do |v|
          buf = footer.dup
          buf.setbyte(i, v)
          Format::FileMetaData.decode(buf)
          outcomes[:decoded] += 1
        rescue Thrift::Error
          outcomes[:refused] += 1
        end
      end
    end
    assert_equal footer.bytesize * 6, outcomes.values.sum
    assert_operator outcomes[:refused], :>, 0
  end

  # -- real Parquet metadata --

  # These carry fields or union members our parquet.thrift does not declare (newer statistics,
  # geospatial types, unknown logical types and column orders), which re-encoding leaves out
  FOOTERS_WITH_UNDECLARED_FIELDS = %w[
    dict-page-offset-zero.parquet floating_orders_nan_count.parquet geospatial-with-nan.parquet
    geospatial.parquet int96_timestamp_order.parquet unknown-logical-type.parquet
  ]

  def plaintext_fixtures
    Dir[File.join(PARQUET_TESTING, "*.parquet")].sort
  end

  def test_real_footers_reencode_byte_for_byte
    names = plaintext_fixtures.map { |path| File.basename(path) } - FOOTERS_WITH_UNDECLARED_FIELDS
    assert_operator names.size, :>, 50
    names.each do |name|
      _, footer = parquet_footer(name)
      fmd, pos = Format::FileMetaData.decode(footer)
      assert_equal footer.bytesize, pos, name
      assert_equal footer, fmd.encode, name
    end
  end

  def test_footers_with_undeclared_fields_survive_a_second_round_trip
    FOOTERS_WITH_UNDECLARED_FIELDS.each do |name|
      _, footer = parquet_footer(name)
      fmd, pos = Format::FileMetaData.decode(footer)
      assert_equal footer.bytesize, pos, name
      reencoded = fmd.encode
      assert_operator reencoded.bytesize, :<, footer.bytesize, name
      again, = Format::FileMetaData.decode(reencoded)
      assert_equal fmd, again, name
      assert_equal reencoded, again.encode, name
    end
  end

  def test_real_page_headers_reencode_byte_for_byte
    plaintext_fixtures.each do |path|
      data, footer = parquet_footer(File.basename(path))
      fmd, = Format::FileMetaData.decode(footer)
      mismatches = []
      count = 0
      fmd.row_groups.each do |rg|
        rg.columns.each do |cc|
          md = cc.meta_data
          pos = [md.dictionary_page_offset, md.data_page_offset].compact.select(&:positive?).min
          stop = pos + md.total_compressed_size
          while pos < stop
            header, header_end = Format::PageHeader.decode(data, pos)
            count += 1
            mismatches << pos unless header.encode == data.byteslice(pos, header_end - pos)
            pos = header_end + header.compressed_page_size
          end
        end
      end
      assert_operator count, :>, 0, path
      assert_empty mismatches, "#{File.basename(path)}: page headers at #{mismatches.first(5)} re-encode differently"
    end
  end
end
