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
end
