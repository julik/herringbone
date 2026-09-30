# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "tmpdir"

# Round trips through Herringbone::Writer and Herringbone::Reader
class WriterTest < Minitest::Test
  include WriterHelpers

  E = Herringbone::Format::Encoding
  T = Herringbone::Format::Type
  PT = Herringbone::Format::PageType

  ALL_ROWS = WriterHelpers.all_types_rows(40)
  NESTED_ROWS = WriterHelpers.nested_rows(40)

  # -- option matrix: codec x page version x dictionary --

  WriterHelpers::CODECS.each do |codec|
    [1, 2].each do |version|
      [true, false].each do |dict|
        define_method("test_matrix_#{codec}_v#{version}_#{dict ? "dict" : "nodict"}") do
          opts = { compression: codec, data_page_version: version, dictionary: dict }
          bytes = write_to_string(ALL_TYPES_SCHEMA, ALL_ROWS, **opts)
          assert_roundtrip(ALL_TYPES_SCHEMA, ALL_ROWS, bytes, opts.inspect)
          check_chunk_metadata(bytes, codec, version, dict)
          bytes = write_to_string(NESTED_SCHEMA, NESTED_ROWS, **opts)
          assert_roundtrip(NESTED_SCHEMA, NESTED_ROWS, bytes, opts.inspect)
          check_chunk_metadata(bytes, codec, version, dict)
        end
      end
    end
  end

  def check_chunk_metadata(bytes, codec, version, dict)
    reader = reader_for(bytes)
    codec_id = Herringbone::Compression.codec_id(codec)
    any_dict = false
    reader.row_groups.each do |rg|
      rg.columns.each do |chunk|
        meta = chunk.meta_data
        assert_equal codec_id, meta.codec
        has_dict = meta.encodings.include?(E::RLE_DICTIONARY)
        any_dict ||= has_dict
        refute has_dict, "no dictionary expected" unless dict
        pages = []
        each_page(bytes, chunk) { |h, body| pages << [h, body] }
        assert_equal meta.dictionary_page_offset.nil?, pages.none? { |h, _| h.type == PT::DICTIONARY_PAGE }
        pages.each do |h, body|
          assert_equal Zlib.crc32(body), h.crc & 0xFFFF_FFFF, "page CRC"
          next if h.type == PT::DICTIONARY_PAGE
          assert_equal(version == 1 ? PT::DATA_PAGE : PT::DATA_PAGE_V2, h.type)
        end
        assert_equal pages.sum { |h, _| (h.data_page_header || h.data_page_header_v2)&.num_values || 0 }, meta.num_values
      end
    end
    assert any_dict, "some columns should be dictionary encoded" if dict
  end

  # -- explicit encodings --

  ENCODING_SCHEMA = WriterTestSchemas::ENCODING_SCHEMA
  ENCODINGS = WriterTestSchemas::ENCODINGS

  def encoding_rows(n) = WriterTestSchemas.encoding_rows(n)

  [1, 2].each do |version|
    [true, false].each do |dict|
      [nil, 3].each do |page_bytes|
        define_method("test_explicit_encodings_v#{version}_#{dict}_#{page_bytes || "default"}") do
          rows = encoding_rows(300)
          opts = { data_page_version: version, dictionary: dict, encodings: ENCODINGS, compression: :snappy }
          opts[:page_bytes] = page_bytes if page_bytes
          bytes = write_to_string(ENCODING_SCHEMA, rows, **opts)
          assert_roundtrip(ENCODING_SCHEMA, rows, bytes, opts.inspect)
          reader = reader_for(bytes)
          reader.row_groups[0].columns.each do |chunk|
            path = chunk.meta_data.path_in_schema.join(".")
            want = Herringbone::Writer::ENCODING_NAMES.fetch(ENCODINGS.fetch(path))
            assert_includes chunk.meta_data.encodings, want, path
            refute_includes chunk.meta_data.encodings, E::RLE_DICTIONARY, path
            each_page(bytes, chunk) do |h, _|
              dh = h.data_page_header || h.data_page_header_v2
              assert_equal want, dh.encoding, path if dh
            end
          end
        end
      end
    end
  end

  def test_invalid_explicit_encoding
    schema = Herringbone::Schema.define { string :s }
    assert_raises(ArgumentError) { write_to_string(schema, [{ "s" => "x" }], encodings: { "s" => :byte_stream_split }) }
    assert_raises(ArgumentError) { write_to_string(schema, [{ "s" => "x" }], encodings: { "s" => :bogus }) }
    schema = Herringbone::Schema.define { double :d }
    assert_raises(ArgumentError) { write_to_string(schema, [{ "d" => 1.0 }], encodings: { "d" => :delta_binary_packed }) }
  end

  def test_rle_dictionary_with_single_distinct_value
    schema = Herringbone::Schema.define { string :s }
    rows = Array.new(100) { { "s" => "same" } }
    bytes = write_to_string(schema, rows)
    assert_roundtrip(schema, rows, bytes)
    assert_includes reader_for(bytes).row_groups[0].columns[0].meta_data.encodings, E::RLE_DICTIONARY
  end

  def test_dictionary_column_list
    schema = Herringbone::Schema.define do
      string :a
      string :b
      list :c, :string
    end
    rows = Array.new(50) { |i| { "a" => "x#{i % 2}", "b" => "y#{i % 2}", "c" => ["z#{i % 3}"] } }
    bytes = write_to_string(schema, rows, dictionary: ["b", "c.list.element"])
    assert_roundtrip(schema, rows, bytes)
    encs = reader_for(bytes).row_groups[0].columns.map { |c| c.meta_data.encodings.include?(E::RLE_DICTIONARY) }
    assert_equal [false, true, true], encs
  end

def test_dictionary_encoded_floats_keep_negative_zero
    schema = Herringbone::Schema.define do
      double :d
      float :f
    end
    rows = [{ "d" => 0.0, "f" => 0.0 }, { "d" => -0.0, "f" => -0.0 }, { "d" => Float::NAN, "f" => 1.0 }]
    bytes = write_to_string(schema, rows, dictionary: %w[d f])
    signs = reader_for(bytes).read.first(2).map { |r| [r["d"], r["f"]].map { |v| (1.0 / v).positive? } }
    assert_equal [[true, true], [false, false]], signs
  end
  
  def test_boolean_columns_are_never_dictionary_encoded
    schema = Herringbone::Schema.define { boolean :b }
    rows = Array.new(20) { |i| { "b" => i.odd? ? nil : i % 4 == 0 } }
    bytes = write_to_string(schema, rows, dictionary: ["b"])
    assert_roundtrip(schema, rows, bytes)
    encs = reader_for(bytes).row_groups[0].columns[0].meta_data.encodings
    refute_includes encs, E::RLE_DICTIONARY
  end
  
  def test_decimal_nan_and_infinity_raise_encode_error
    schema = Herringbone::Schema.define { decimal :a, precision: 10, scale: 2 }
    [Float::NAN, Float::INFINITY].each do |v|
      assert_raises(Herringbone::EncodeError) { write_to_string(schema, [{ "a" => v }]) }
    end
    [BigDecimal("NaN"), BigDecimal("Infinity")].each do |v|
      assert_raises(Herringbone::EncodeError) { write_to_string(schema, [{ "a" => v }]) }
    end
  end

  def test_dictionary_fallback_for_high_cardinality
    schema = Herringbone::Schema.define { int64 :a }
    rows = Array.new(1000) { |i| { "a" => i } }
    bytes = write_to_string(schema, rows)
    assert_roundtrip(schema, rows, bytes)
    refute_includes reader_for(bytes).row_groups[0].columns[0].meta_data.encodings, E::RLE_DICTIONARY
  end

  # -- row groups and pages --

  def test_multiple_row_groups
    [1, 3, 7, 40].each do |rgs|
      bytes = write_to_string(NESTED_SCHEMA, NESTED_ROWS, row_group_rows: rgs)
      assert_roundtrip(NESTED_SCHEMA, NESTED_ROWS, bytes, "row_group_rows=#{rgs}")
      reader = reader_for(bytes)
      assert_equal (40.0 / rgs).ceil, reader.row_groups.size
      assert_equal [rgs] * (40 / rgs) + (40 % rgs).nonzero?.then { |r| r ? [r] : [] }, reader.row_groups.map(&:num_rows)
      reader.row_groups.each_with_index { |rg, i| assert_equal i, rg.ordinal }
      first = reader.read(as: :columns, columns: ["id"], limit: rgs)
      assert_equal NESTED_ROWS.first(rgs).map { |r| r["id"] }, first["id"]
    end
  end

  def test_multiple_row_groups_all_types
    bytes = write_to_string(ALL_TYPES_SCHEMA, ALL_ROWS, row_group_rows: 6, dictionary: true)
    assert_roundtrip(ALL_TYPES_SCHEMA, ALL_ROWS, bytes)
    assert_equal 7, reader_for(bytes).row_groups.size
  end

  def test_row_group_flush_boundary_exact
    schema = Herringbone::Schema.define { int32 :a }
    rows = Array.new(10) { |i| { "a" => i } }
    bytes = write_to_string(schema, rows, row_group_rows: 5)
    assert_equal [5, 5], reader_for(bytes).row_groups.map(&:num_rows)
    assert_roundtrip(schema, rows, bytes)
  end

  [1, 2].each do |version|
    [true, false].each do |dict|
      define_method("test_many_pages_v#{version}_#{dict}") do
        [ALL_TYPES_SCHEMA, NESTED_SCHEMA].zip([ALL_ROWS, NESTED_ROWS]).each do |schema, rows|
          bytes = write_to_string(schema, rows, page_bytes: 40, data_page_version: version, dictionary: dict)
          assert_roundtrip(schema, rows, bytes, "page_bytes=40 v#{version}")
          reader = reader_for(bytes)
          reader.schema.columns.each do |col|
            chunk = reader.row_groups[0].columns[col.index]
            data_pages = 0
            each_page(bytes, chunk) do |h, body|
              next if h.type == PT::DICTIONARY_PAGE
              data_pages += 1
              next unless col.max_repetition_level.positive?
              first_rep = first_repetition_level(h, body, chunk.meta_data.codec, col)
              assert_equal 0, first_rep, "page of #{col.dotted_path} must start at a row boundary"
              if h.data_page_header_v2
                assert_operator h.data_page_header_v2.num_rows, :>, 0
              end
            end
            assert_operator data_pages, :>, 1, "#{col.dotted_path} should be split into pages"
          end
        end
      end
    end
  end

  def first_repetition_level(header, body, codec, col)
    width = col.max_repetition_level.bit_length
    if (v2 = header.data_page_header_v2)
      Herringbone::Encodings::RLE.decode_hybrid(body, 0, v2.repetition_levels_byte_length, width, 1).first
    else
      data = Herringbone::Compression.decompress(codec, body, header.uncompressed_page_size)
      len = data.unpack1("V")
      Herringbone::Encodings::RLE.decode_hybrid(data, 4, 4 + len, width, 1).first
    end
  end

  def test_repeated_rows_larger_than_page_are_not_split
    schema = Herringbone::Schema.define { list :l, :int64 }
    rows = [{ "l" => (1..500).to_a }, { "l" => [] }, { "l" => (1..300).to_a }, { "l" => nil }]
    [1, 2].each do |v|
      bytes = write_to_string(schema, rows, page_bytes: 16, data_page_version: v)
      assert_roundtrip(schema, rows, bytes)
      reader = reader_for(bytes)
      counts = []
      each_page(bytes, reader.row_groups[0].columns[0]) do |h, _|
        counts << (h.data_page_header || h.data_page_header_v2).num_values
      end
      assert_equal [500, 301, 1], counts # cuts only at row starts, after the page is full
    end
  end

  # -- edge cases --

  def test_zero_rows
    [ALL_TYPES_SCHEMA, NESTED_SCHEMA].each do |schema|
      [1, 2].each do |v|
        bytes = write_to_string(schema, [], data_page_version: v)
        reader = reader_for(bytes)
        assert_equal 0, reader.num_rows
        assert_equal [], reader.read
        assert_equal schema.columns.map(&:path), reader.schema.columns.map(&:path)
      end
    end
  end

  def test_all_null_columns
    optional = ALL_TYPES_SCHEMA.fields.select(&:optional).map(&:name)
    rows = Array.new(20) do |i|
      ALL_ROWS[i].merge(optional.to_h { |n| [n, nil] })
    end
    [true, false].each do |dict|
      [1, 2].each do |v|
        bytes = write_to_string(ALL_TYPES_SCHEMA, rows, dictionary: dict, data_page_version: v)
        assert_roundtrip(ALL_TYPES_SCHEMA, rows, bytes)
        reader = reader_for(bytes)
        reader.row_groups[0].columns.each do |chunk|
          name = chunk.meta_data.path_in_schema.first
          next unless optional.include?(name)
          stats = chunk.meta_data.statistics
          assert_equal 20, stats.null_count, name
          assert_nil stats.min_value, name
          assert_nil stats.max_value, name
        end
      end
    end
  end

  def test_all_null_nested
    rows = Array.new(10) { |i| { "id" => i, "l_required" => [], "s_req" => { "x" => i } } }
    bytes = write_to_string(NESTED_SCHEMA, rows)
    expected = rows.map { |r| NESTED_SCHEMA.fields.to_h { |f| [f.name, r[f.name]] }.merge("s_req" => { "x" => r["s_req"]["x"], "y" => nil }) }
    assert_roundtrip(NESTED_SCHEMA, expected, bytes)
  end

  def test_symbol_keys_and_missing_keys
    schema = Herringbone::Schema.define do
      int32 :a
      struct :s do
        string :b
      end
    end
    bytes = write_to_string(schema, [{ a: 1, s: { b: "x" } }, {}, { "s" => {} }])
    assert_equal [{ "a" => 1, "s" => { "b" => "x" } }, { "a" => nil, "s" => nil }, { "a" => nil, "s" => { "b" => nil } }], reader_for(bytes).read
  end

  def test_map_accepts_array_of_pairs
    schema = Herringbone::Schema.define { map :m, :string, :int32 }
    bytes = write_to_string(schema, [{ "m" => [["a", 1], ["b", nil]] }])
    assert_equal [{ "m" => { "a" => 1, "b" => nil } }], reader_for(bytes).read
  end

  def test_string_encoding_of_read_values
    schema = Herringbone::Schema.define do
      string :s
      binary :b
      json :j
      enum :e
    end
    bytes = write_to_string(schema, [{ "s" => "é", "b" => "é", "j" => "{}", "e" => "A" }])
    row = reader_for(bytes).read.first
    assert_equal Encoding::UTF_8, row["s"].encoding
    assert_equal "é", row["s"]
    assert_equal Encoding::BINARY, row["b"].encoding
    assert_equal "é".b, row["b"]
    assert_equal Encoding::UTF_8, row["j"].encoding
    assert_equal Encoding::UTF_8, row["e"].encoding
  end

  def test_special_values_directly
    bytes = write_to_string(ALL_TYPES_SCHEMA, ALL_ROWS.first(12))
    rows = reader_for(bytes).read
    assert_equal 2**64 - 1, rows[1]["u64"]
    assert_equal 2**63, rows[2]["u64"]
    assert_equal 2**32 - 1, rows[1]["u32"]
    assert rows[4]["f32"].nan?
    assert rows[3]["f64"].nan?
    assert_equal(-Float::INFINITY, rows[6]["f16"])
    zero = rows[1]["f64"]
    assert_equal(-1, (1.0 / zero) <=> 0, "-0.0 preserved")
    zero = rows[3]["f16"]
    assert_equal(-1, (1.0 / zero) <=> 0, "-0.0 preserved in float16")
    assert_equal Date.new(1, 1, 1, Date::GREGORIAN), rows[0]["date"]
    assert_equal "0001-01-01", rows[0]["date"].iso8601
    assert_equal "9999-12-31", rows[1]["date"].iso8601
    assert_equal Time.at(-1, 500, :millisecond).utc, rows[1]["ts_ms"]
    assert_equal Time.utc(1, 1, 1), rows[4]["ts_ms"]
    assert_equal Time.at(-1, 1, :nanosecond).utc, rows[0]["ts_ns"]
    assert_equal Time.utc(1700, 1, 1, 0, 0, 0, 1), rows[2]["i96"]
    assert_equal BigDecimal("-9999999.99"), rows[1]["dec_small"]
    assert_equal BigDecimal("-" + "9" * 28 + "." + "9" * 10), rows[1]["dec_large"]
    assert_equal "ffffffff-ffff-ffff-ffff-ffffffffffff", rows[1]["uid"]
    assert rows.all? { |r| r["ts_ms"].nil? || r["ts_ms"].utc? }
  end

  def test_date_before_gregorian_reform_with_default_calendar
    schema = Herringbone::Schema.define { date :d }
    bytes = write_to_string(schema, [{ "d" => Date.new(1, 1, 1) }, { "d" => Date.new(1500, 3, 1) }])
    assert_equal %w[0001-01-01 1500-03-01], reader_for(bytes).read.map { |r| r["d"].iso8601 }
  end

  def test_float16_rounding
    schema = Herringbone::Schema.define { float16 :h }
    # exactly representable
    vals = [0.5, 1.0, 2.0**-24, 65_504.0, -1000.5, 0.333251953125]
    bytes = write_to_string(schema, vals.map { |v| { "h" => v } })
    assert_equal vals, reader_for(bytes).read.map { |r| r["h"] }
    # rounding: nearest-even, overflow to infinity, underflow to zero
    assert_equal 0x3C00, Herringbone::Types.float_to_half(1.0 + 2.0**-11) # tie -> even
    assert_equal 0x3C02, Herringbone::Types.float_to_half(1.0 + 3 * 2.0**-11) # tie -> even (up)
    assert_equal 0x7C00, Herringbone::Types.float_to_half(65_520.0)
    assert_equal 0x7BFF, Herringbone::Types.float_to_half(65_519.0)
    assert_equal 0x0000, Herringbone::Types.float_to_half(2.0**-26)
    assert_equal 0x0001, Herringbone::Types.float_to_half(2.0**-25 + 2.0**-30)
    assert_equal 0x8000, Herringbone::Types.float_to_half(-0.0)
  end

  def test_float16_double_rounding
    assert_equal 0x3C01, Herringbone::Types.float_to_half(1.0 + 2.0**-11 + 2.0**-40)
  end

  # -- errors --

  def test_required_nil_raises
    schema = Herringbone::Schema.define do
      int32 :a, null: false
      struct :s do
        int32 :x, null: false
      end
      list :l, :int32, element_null: false
      list :lr, :int32, null: false
      map :m, :string, :int32, value_null: false
    end
    good = { "a" => 1, "s" => { "x" => 1 }, "l" => [1], "lr" => [], "m" => { "k" => 1 } }
    write_to_string(schema, [good])
    [
      { "a" => nil }, { "s" => { "x" => nil } }, { "s" => {} }, { "l" => [1, nil] }, { "lr" => nil },
      { "m" => { "k" => nil } }, { "m" => { nil => 1 } }
    ].each do |bad|
      assert_raises(Herringbone::EncodeError, bad.inspect) { write_to_string(schema, [good.merge(bad)]) }
    end
  end

  def test_wrong_types_raise_encode_error
    cases = {
      proc { int32 :a } => ["x", Object.new, [1], "12abc"],
      proc { int64 :a } => ["nope", {}],
      proc { double :a } => ["x", [1.0]],
      proc { date :a } => ["2020-13-45", "yesterday", 5.5],
      proc { timestamp :a } => ["not a time", 5.5],
      proc { time :a } => ["25:00", "noon", 5.5],
      proc { boolean :a } => ["maybe", 2],
      proc { enum :a, values: %w[x y] } => ["z", :w],
      proc { decimal :a, precision: 10, scale: 2 } => ["abc", Object.new],
      proc { list :a, :int32 } => [5, "str"],
      proc { map :a, :string, :int32 } => [5, "str"],
      proc { list :a, :int32 } => [["x"]],
      proc { fixed :a, length: 4 } => ["abc", "abcde"],
      proc { uuid :a } => ["not-a-uuid"]
    }
    cases.each do |defn, values|
      schema = Herringbone::Schema.define(&defn)
      values.each do |v|
        assert_raises(Herringbone::EncodeError, "#{schema.columns.first.dotted_path} <- #{v.inspect}") do
          write_to_string(schema, [{ "a" => v }])
        end
      end
    end
  end

  def test_struct_given_non_hash_raises_encode_error
    schema = Herringbone::Schema.define do
      struct :s do
        int32 :x
      end
    end
    assert_raises(Herringbone::EncodeError) { write_to_string(schema, [{ "s" => 5 }]) }
  end

  def test_out_of_range_integers_raise
    { proc { int32 :a } => [2**40, 2**31], proc { int64 :a } => [2**70, 2**63], proc { int8 :a } => [300, -129],
      proc { uint8 :a } => [256, -1], proc { decimal :a, precision: 5, scale: 2 } => [10**8], proc { int32 :a } => [1.5] }.each do |defn, values|
      schema = Herringbone::Schema.define(&defn)
      values.each do |v|
        assert_raises(Herringbone::EncodeError, v.inspect) { write_to_string(schema, [{ "a" => v }]) }
      end
    end
  end

  def test_writer_state_is_consistent_after_encode_error
    schema = Herringbone::Schema.define do
      int64 :a
      int64 :b, null: false
    end
    io = StringIO.new("".b)
    w = Herringbone::Writer.new(io, schema)
    w << { "a" => 1, "b" => 2 }
    assert_raises(Herringbone::EncodeError) { w << { "a" => 3, "b" => nil } }
    w << { "a" => 5, "b" => 6 }
    w.close
    rows = reader_for(io.string).read
    assert_equal [{ "a" => 1, "b" => 2 }, { "a" => 5, "b" => 6 }], rows
  end

  def test_closed_writer_rejects_rows
    io = StringIO.new("".b)
    w = Herringbone::Writer.new(io, Herringbone::Schema.define { int32 :a })
    w.close
    assert_raises(Herringbone::Error) { w << { "a" => 1 } }
    size = io.string.bytesize
    w.close # idempotent
    assert_equal size, io.string.bytesize
  end

  def test_invalid_options
    schema = Herringbone::Schema.define { int32 :a }
    assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, schema, data_page_version: 3) }
    assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, schema, compression: :lzo_nope) }
  end

  # -- metadata --

  def test_key_value_metadata
    schema = Herringbone::Schema.define { int32 :a }
    meta = { "k" => "v", "unicode" => "漢字", "empty" => "", :sym => "s", "big" => "x" * 10_000 }
    bytes = write_to_string(schema, [{ "a" => 1 }], metadata: meta)
    reader = reader_for(bytes)
    assert_equal meta.transform_keys(&:to_s), reader.metadata
    assert_match(/herringbone/, reader.file_metadata.created_by)
    assert_nil reader_for(write_to_string(schema, [])).file_metadata.key_value_metadata
  end

  def test_file_structure
    bytes = write_to_string(ALL_TYPES_SCHEMA, ALL_ROWS)
    assert_equal "PAR1", bytes.byteslice(0, 4)
    assert_equal "PAR1", bytes.byteslice(-4, 4)
    reader = reader_for(bytes)
    md = reader.file_metadata
    assert_equal 40, md.num_rows
    offset = 4
    md.row_groups.each do |rg|
      assert_equal offset, rg.file_offset
      rg.columns.each do |c|
        m = c.meta_data
        start = [m.dictionary_page_offset, m.data_page_offset].compact.min
        assert_equal offset, start
        assert_equal offset, c.file_offset
        offset += m.total_compressed_size
      end
      assert_equal rg.total_compressed_size, offset - rg.file_offset
    end
    # Page indexes sit between the last row group and the footer: column indexes, then offset indexes
    index_ranges = md.row_groups.flat_map(&:columns).flat_map do |c|
      [[c.column_index_offset, c.column_index_length], [c.offset_index_offset, c.offset_index_length]]
    end.select(&:first).sort
    index_ranges.each do |start, length|
      assert_equal offset, start
      offset += length
    end
    footer_len = bytes.byteslice(-8, 4).unpack1("V")
    assert_equal bytes.bytesize - 8 - footer_len, offset
  end

  def test_statistics
    bytes = write_to_string(ALL_TYPES_SCHEMA, ALL_ROWS, row_group_rows: 13)
    reader = reader_for(bytes)
    reader.row_groups.each_with_index do |rg, g|
      rows = ALL_ROWS[g * 13, 13]
      rg.columns.each do |chunk|
        name = chunk.meta_data.path_in_schema.first
        col = reader.schema.column([name])
        stats = chunk.meta_data.statistics
        vals = rows.map { |r| r[name] }
        assert_equal vals.count(&:nil?), stats.null_count, name
        present = vals.compact
        min, max = expected_min_max(name, col, present)
        if min.nil?
          assert_nil stats.min_value, name if name == "i96"
          next
        end
        # Byte arrays longer than 64 bytes are truncated (min to a prefix, max to an incremented prefix)
        assert stats.min_value.b <= min.b && min.b.start_with?(stats.min_value.b), "min of #{name} in row group #{g}"
        assert_equal max.b, stats.max_value.b, "max of #{name} in row group #{g}" if max.bytesize <= 64
        assert_operator stats.max_value.b, :>=, max.b.byteslice(0, 64), "max of #{name} in row group #{g}"
      end
    end
  end

  def expected_min_max(name, col, vals)
    return nil if vals.empty?
    phys = vals.map { |v| col.encoder.call(v) }
    kind, = Herringbone::Types.logical_of(col.node)
    case col.type
    when T::BOOLEAN then [phys.include?(false) ? "\x00".b : "\x01".b, phys.include?(true) ? "\x01".b : "\x00".b]
    when T::INT32, T::INT64
      fmt = col.type == T::INT32 ? "l<" : "q<"
      if kind == :integer && name.start_with?("u")
        # Unsigned columns sort by the unsigned value of the stored (wrapped) integer
        mask = (1 << (col.type == T::INT32 ? 32 : 64)) - 1
        [[phys.min_by { |v| v & mask }].pack(fmt), [phys.max_by { |v| v & mask }].pack(fmt)]
      else
        [[phys.min].pack(fmt), [phys.max].pack(fmt)]
      end
    when T::FLOAT, T::DOUBLE
      fin = phys.reject(&:nan?)
      return nil if fin.empty?
      fmt = col.type == T::FLOAT ? "e" : "E"
      mn = fin.min
      mx = fin.max
      mn = -0.0 if mn.zero?
      mx = 0.0 if mx.zero?
      [[mn].pack(fmt), [mx].pack(fmt)]
    when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY
      case kind
      when :decimal
        # Big-endian two's complement: sorts by the signed integer
        by = ->(b) { i = b.unpack1("H*").to_i(16); i >= (1 << (b.bytesize * 8 - 1)) ? i - (1 << (b.bytesize * 8)) : i }
        [phys.min_by(&by), phys.max_by(&by)]
      when :float16
        halves = phys.reject { |b| Herringbone::Types.half_to_float(b.unpack1("v")).nan? }
        return nil if halves.empty?
        by = ->(b) { Herringbone::Types.half_to_float(b.unpack1("v")) }
        [halves.min_by(&by), halves.max_by(&by)]
      else
        [phys.min, phys.max]
      end
    end
  end

  # -- schema inference and convenience API --

  def test_schema_infer_roundtrip
    rows = [
      { "i" => 1, "f" => 1.5, "s" => "é", "b" => "\xFF".b, "t" => Time.at(1, 5, :microsecond).utc, "d" => Date.new(2020, 1, 2),
        "bool" => true, "dec" => BigDecimal("1.25"), "sym" => :abc, "h" => { "x" => 1, "y" => [1, 2] }, "l" => [[1], []],
        "lh" => [{ "k" => "v" }] },
      { "i" => nil, "f" => 2, "s" => nil, "b" => nil, "t" => nil, "d" => nil, "bool" => false, "dec" => 3,
        "sym" => nil, "h" => nil, "l" => nil, "lh" => [] },
      { i: -5, f: nil, s: "x", b: "\x00".b, t: Time.at(0).utc, d: Date.new(1970, 1, 1), bool: nil, dec: nil, sym: :x,
        h: { x: nil, y: [] }, l: [[nil]], lh: [nil, { k: nil }] }
    ]
    schema = Herringbone::Schema.infer(rows)
    types = schema.columns.to_h { |c| [c.dotted_path, T::NAMES[c.type]] }
    assert_equal :INT64, types["i"]
    assert_equal :DOUBLE, types["f"]
    assert_equal :BYTE_ARRAY, types["s"]
    assert_equal :BOOLEAN, types["bool"]
    assert_equal :FIXED_LEN_BYTE_ARRAY, types["dec"]
    io = StringIO.new("".b)
    assert_equal 3, Herringbone.write(io, rows)
    begin
      reader = Herringbone::Reader.new(StringIO.new(io.string))
      read = reader.read
      assert_equal 1, read[0]["i"]
      assert_equal 2.0, read[1]["f"]
      assert_equal "é", read[0]["s"]
      assert_equal "\xFF".b, read[0]["b"]
      assert_equal Time.at(1, 5, :microsecond).utc, read[0]["t"]
      assert_equal Date.new(2020, 1, 2), read[0]["d"]
      assert_equal BigDecimal("1.25"), read[0]["dec"]
      assert_equal BigDecimal("3"), read[1]["dec"]
      assert_equal "abc", read[0]["sym"]
      assert_equal({ "x" => 1, "y" => [1, 2] }, read[0]["h"])
      assert_equal({ "x" => nil, "y" => [] }, read[2]["h"])
      assert_equal [[1], []], read[0]["l"]
      assert_equal [[nil]], read[2]["l"]
      assert_equal [nil, { "k" => nil }], read[2]["lh"]
      assert_equal [], read[1]["lh"]
      assert_equal(-5, read[2]["i"])
      assert_equal 3, reader.num_rows
      assert_equal [{ "i" => 1 }, { "i" => nil }, { "i" => -5 }], reader.read(columns: ["i"])
    end
  end

  def test_schema_infer_errors
    assert_raises(ArgumentError) { Herringbone::Schema.infer([]) }
    assert_equal :string, Herringbone::Types.logical_of(Herringbone::Schema.infer([{ "a" => nil }]).columns.first.node).first
    assert_raises(ArgumentError) { Herringbone::Schema.infer([{ "a" => 1 }, { "a" => "x" }]) }
  end

  def test_writer_open_with_block_writes_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.parquet")
      File.open(path, "wb") do |f|
        Herringbone::Writer.open(f, NESTED_SCHEMA, compression: :gzip) { |w| NESTED_ROWS.each { |r| w << r } }
      end
      assert_roundtrip(NESTED_SCHEMA, NESTED_ROWS, File.binread(path))
    end
  end

  def test_large_values_and_many_rows
    schema = Herringbone::Schema.define do
      string :big
      int64 :n, null: false
    end
    rows = Array.new(5000) { |i| { "big" => i % 1000 == 0 ? "x" * 100_000 : "v#{i % 50}", "n" => i } }
    bytes = write_to_string(schema, rows, page_bytes: 8192, row_group_rows: 2000)
    reader = reader_for(bytes)
    assert_equal rows, reader.read
    assert_equal (0...5000).to_a, reader.read(as: :columns, columns: ["n"])["n"]
  end
end
