# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"

# Malformed Thrift must end in Thrift::Error, quickly and without exhausting memory or the stack
class ThriftTest < Minitest::Test
  Thrift = Herringbone::Thrift
  FileMetaData = Herringbone::Format::FileMetaData

  # Field id 99 is unknown to FileMetaData, so its value is skipped
  UNKNOWN_FIELD = 99

  def varint(n)
    s = "".b
    while n >= 0x80
      s << ((n & 0x7F) | 0x80)
      n >>= 7
    end
    s << n
  end

  def zigzag(n)
    varint(n.negative? ? ((-n) << 1) - 1 : n << 1)
  end

  # Field header with the id as a separate zigzag varint
  def long_field(id, wire)
    [wire].pack("C") + varint(id << 1)
  end

  def parquet_file(footer)
    "PAR1".b + footer + [footer.bytesize].pack("V") + "PAR1"
  end

  def assert_thrift_error(buf, klass = FileMetaData)
    Timeout.timeout(2) do
      assert_raises(Thrift::Error) { Thrift::Reader.new(buf).read_struct(klass) }
    end
  end

  # -- skipping a value never reads past the end of the buffer --

  def test_skipping_a_huge_list_of_doubles_fails_fast
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_LIST) + "\xF7".b + varint(2**62)
  end

  def test_skipping_a_huge_map_of_doubles_fails_fast
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_MAP) + varint(2**62) + "\x77".b
  end

  def test_reading_a_truncated_double_fails
    assert_raises(Thrift::Error) { Thrift::Reader.new("\x01\x02\x03".b).read_value(Thrift::T_DOUBLE, :double) }
  end

  # -- nesting depth is limited --

  def test_deeply_nested_skipped_structs_fail
    # each 0x1C opens a struct in field id + 1
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_STRUCT) + "\x1C".b * 100_000
  end

  def test_deeply_nested_skipped_lists_fail
    # each 0x19 is a one-element list of lists
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_LIST) + "\x19".b * 100_000
  end

  # -- list sizes are checked against the bytes left --

  # FileMetaData field 2 is the schema, a list of SchemaElement
  def schema_list(size)
    "\x29\xFC".b + varint(size)
  end

  def test_list_larger_than_memory_fails
    assert_thrift_error schema_list(2**40)
  end

  def test_list_larger_than_an_array_can_be_fails
    assert_thrift_error schema_list(2**62)
  end

  def test_list_size_beyond_64_bits_fails
    assert_thrift_error schema_list(2**70)
  end

  # -- integers fit their declared type --

  def test_varint_longer_than_ten_bytes_fails
    # FileMetaData field 3 is num_rows, an i64
    assert_thrift_error "\x36".b + "\x80".b * 10 + "\x00\x00".b
  end

  def test_i64_beyond_64_bits_fails
    assert_thrift_error "\x36".b + varint(2**64) + "\x00".b
  end

  def test_i32_beyond_32_bits_fails
    # FileMetaData field 1 is version, an i32
    assert_thrift_error "\x15".b + varint(2**40) + "\x00".b
  end

  def test_i16_beyond_16_bits_fails
    # RowGroup field 7 is ordinal, an i16
    assert_thrift_error "\x74".b + zigzag(2**15) + "\x00".b, Herringbone::Format::RowGroup
    assert_thrift_error "\x74".b + zigzag(-(2**15) - 1) + "\x00".b, Herringbone::Format::RowGroup
  end

  def test_i16_at_its_limits_is_read
    [2**15 - 1, -(2**15)].each do |n|
      group = Thrift::Reader.new("\x74".b + zigzag(n) + "\x00".b).read_struct(Herringbone::Format::RowGroup)
      assert_equal n, group.ordinal
    end
  end

  def test_i32_below_32_bits_fails
    assert_thrift_error "\x15".b + zigzag(-(2**31) - 1) + "\x00".b
  end

  def test_i32_out_of_range_inside_a_list_fails
    # ColumnMetaData field 2 is encodings, a list of i32
    assert_thrift_error "\x29\x15".b + zigzag(2**31) + "\x00".b, Herringbone::Format::ColumnMetaData
  end

  def test_ten_byte_varint_up_to_64_bits_is_read
    fmd = Thrift::Reader.new("\x36".b + "\xFF".b * 9 + "\x01\x00".b).read_struct(FileMetaData)
    assert_equal(-(2**63), fmd.num_rows)
  end

  def test_skipped_varint_beyond_64_bits_fails
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_I64) + varint(2**64) + "\x00".b
  end

  def test_skipped_varint_longer_than_ten_bytes_fails
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_I32) + "\x80".b * 11 + "\x00\x00".b
  end

  # -- forged sizes of strings, sets and maps --

  def test_string_longer_than_the_buffer_fails
    # FileMetaData field 6 is created_by, a string
    assert_thrift_error "\x68".b + varint(2**40) + "abc".b
    assert_thrift_error "\x68".b + varint(2**63) + "abc".b
  end

  def test_string_one_byte_longer_than_the_buffer_fails
    assert_thrift_error "\x68".b + varint(4) + "abc".b
  end

  def test_skipped_binary_longer_than_the_buffer_fails
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_BINARY) + varint(2**62) + "abc".b
  end

  def test_skipping_a_huge_set_fails_fast
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_SET) + "\xF7".b + varint(2**62)
  end

  def test_skipping_a_huge_list_nested_in_a_list_fails_fast
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_LIST) + "\x19\xF7".b + varint(2**62)
  end

  def test_map_larger_than_the_bytes_left_fails
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_MAP) + varint(4) + "\x11\x01\x01".b
  end

  def test_list_exactly_as_large_as_the_bytes_left_is_skipped
    reader = Thrift::Reader.new("\xF1".b + varint(20) + "\x01".b * 20)
    reader.skip(Thrift::T_LIST)
    assert_equal 22, reader.pos
  end

  def test_list_one_larger_than_the_bytes_left_fails
    assert_raises(Thrift::Error) { Thrift::Reader.new("\xF1".b + varint(21) + "\x01".b * 20).skip(Thrift::T_LIST) }
  end

  # -- nesting depth limit, exactly --

  # Skipped structs nested +levels+ deep inside the top-level FileMetaData
  def nested_structs(levels)
    long_field(UNKNOWN_FIELD, Thrift::T_STRUCT) + "\x1C".b * (levels - 1) + "\x00".b * levels + "\x00".b
  end

  def test_structs_nested_up_to_the_limit_are_skipped
    fmd = Thrift::Reader.new(nested_structs(Thrift::MAX_DEPTH - 1)).read_struct(FileMetaData)
    assert_equal({}, fmd.to_h)
  end

  def test_structs_nested_one_level_past_the_limit_fail
    assert_thrift_error nested_structs(Thrift::MAX_DEPTH)
  end

  # Skipped lists nested +levels+ deep, the innermost one empty
  def nested_lists(levels)
    long_field(UNKNOWN_FIELD, Thrift::T_LIST) + "\x19".b * (levels - 1) + "\x09\x00".b
  end

  def test_lists_nested_up_to_the_limit_are_skipped
    fmd = Thrift::Reader.new(nested_lists(Thrift::MAX_DEPTH - 1)).read_struct(FileMetaData)
    assert_equal({}, fmd.to_h)
  end

  def test_lists_nested_one_level_past_the_limit_fail
    assert_thrift_error nested_lists(Thrift::MAX_DEPTH)
  end

  def test_deeply_nested_skipped_maps_fail
    # each map holds one entry, an i32 key and a map value
    assert_thrift_error long_field(UNKNOWN_FIELD, Thrift::T_MAP) + "\x01\x5B\x00".b * 100_000 + "\x00".b
  end

  class Node < Herringbone::Thrift::Struct
    field 1, :child, Node
  end

  def chain(levels)
    (levels - 1).times.reduce(Node.new) { |node, _| Node.new(child: node) }
  end

  def test_decoded_structs_nested_up_to_the_limit_are_read
    node = chain(Thrift::MAX_DEPTH)
    assert_equal node, Node.decode(node.encode).first
  end

  def test_decoded_structs_nested_past_the_limit_fail
    assert_thrift_error chain(Thrift::MAX_DEPTH + 1).encode, Node
  end

  def test_depth_is_restored_after_an_error
    reader = Thrift::Reader.new(nested_structs(Thrift::MAX_DEPTH) + Node.new.encode)
    assert_raises(Thrift::Error) { reader.read_struct(FileMetaData) }
    assert_equal 0, reader.instance_variable_get(:@depth)
  end

  # -- through Herringbone::Reader, all of it is a FormatError --

  def assert_corrupt_footer(footer)
    Timeout.timeout(2) do
      assert_raises(Herringbone::FormatError) { Herringbone::Reader.new(StringIO.new(parquet_file(footer))) }
    end
  end

  def test_reader_rejects_a_footer_skipping_a_huge_list
    assert_corrupt_footer long_field(UNKNOWN_FIELD, Thrift::T_LIST) + "\xF7".b + varint(2**62)
  end

  def test_reader_rejects_a_deeply_nested_footer
    assert_corrupt_footer long_field(UNKNOWN_FIELD, Thrift::T_STRUCT) + "\x1C".b * 100_000
  end

  def test_reader_rejects_a_footer_with_a_huge_list
    assert_corrupt_footer schema_list(2**70)
  end

  def test_reader_rejects_a_footer_with_a_forged_string_length
    assert_corrupt_footer "\x68".b + varint(2**40) + "abc".b
  end

  def test_reader_rejects_a_footer_with_an_oversized_integer
    assert_corrupt_footer "\x15".b + varint(2**40) + "\x00".b
  end
end
