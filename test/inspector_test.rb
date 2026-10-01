# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# Inspector reads footers, page headers and page indexes only, so it works on every fixture
# (including ones whose codecs are not installed) and must never decompress anything.
class InspectorTest < Minitest::Test
  Inspector = Herringbone::Inspector
  Compression = Herringbone::Compression
  FIXTURES = Dir[File.join(FIXTURES_DIR, "{parquet-testing,generated}", "*.parquet")].sort
  # Files written with repeated fields, where pages don't carry row counts
  PT = File.join(FIXTURES_DIR, "parquet-testing")
  GEN = File.join(FIXTURES_DIR, "generated")

  # Runs the block with the optional codec gems unavailable and decompression forbidden
  def without_decompression(&block)
    forbidden = ->(*) { flunk "the inspector must not decompress pages" }
    Compression.stub(:loaded_library, nil) do
      Compression.stub(:decompress, forbidden, &block)
    end
  end

  def inspect_file(path)
    File.open(path, "rb") { |io| Herringbone::Inspector.new(io).load_all }
  end

  def test_fixtures_exist
    assert_operator FIXTURES.size, :>, 100
  end

  def test_every_fixture_inspects_without_codecs_or_decompression
    without_decompression do
      FIXTURES.each do |path|
        i = inspect_file(path)
        name = File.basename(path)
        i.column_chunks.each { |c| assert_nil c.error, "#{name} #{c.path}: #{c.error}" }
        json = JSON.generate(i.to_h)
        assert_kind_of Hash, JSON.parse(json), name
        refute_empty i.report, name
      end
    end
  end

  def test_page_values_add_up_and_pages_are_contiguous_and_in_bounds
    FIXTURES.each do |path|
      i = inspect_file(path)
      name = File.basename(path)
      i.column_chunks.each do |c|
        where = "#{name} rg#{c.row_group.index} #{c.path}"
        pages = c.pages
        assert_equal c.num_values, c.data_pages.sum(&:num_values), where
        next if pages.empty?
        assert_equal c.start_offset, pages.first.offset, where
        pages.each_cons(2) { |a, b| assert_equal a.end_offset, b.offset, where }
        pages.each_with_index do |p, k|
          assert_operator p.offset, :>=, 4, where
          assert_operator p.end_offset, :<=, i.footer_offset, where
          assert_operator p.header_size, :>, 0, where
          assert_equal k, p.index, where
          refute p.dictionary? && k.positive?, "#{where}: dictionary page after the first page"
        end
        assert_operator c.end_offset, :>=, c.declared_end_offset, where
        if c.dictionary_page
          assert_equal c.dictionary_page.num_values, c.dictionary_size, where
        end
        v2_or_flat = c.data_pages.all? { |p| p.num_rows }
        assert_equal c.row_group.num_rows, c.data_pages.sum(&:num_rows), where if v2_or_flat
      end
    end
  end

  def test_layout_covers_the_file_exactly
    FIXTURES.each do |path|
      i = inspect_file(path)
      name = File.basename(path)
      layout = i.layout
      assert_equal 0, layout.first[:start], name
      layout.each_cons(2) { |a, b| assert_equal a[:start] + a[:length], b[:start], "#{name}: #{a} / #{b}" }
      assert_equal i.file_size, layout.last[:start] + layout.last[:length], name
      assert_equal %i[footer footer_length magic], layout.last(3).map { |s| s[:kind] }, name
      assert_equal File.size(path), i.file_size
    end
  end

  def test_no_unaccounted_bytes_in_well_formed_files
    %w[alltypes_tiny_pages data_index_bloom_encoding_stats data_index_bloom_encoding_with_length
      nested_structs.rust overflow_i16_page_cnt datapage_v2.snappy].each do |f|
      i = inspect_file(File.join(PT, "#{f}.parquet"))
      assert_empty i.layout.select { |s| s[:kind] == :unknown }, f
    end
    FIXTURES.select { |f| f.include?("/generated/") }.each do |path|
      assert_empty inspect_file(path).layout.select { |s| s[:kind] == :unknown }, path
    end
  end

  def test_inline_column_metadata_copies_are_recognised
    i = inspect_file(File.join(PT, "nested_structs.rust.parquet"))
    kinds = i.layout.map { |s| s[:kind] }.tally
    assert_equal i.column_chunks.size, kinds[:column_metadata]
  end

  def test_page_index_matches_page_headers
    %w[alltypes_tiny_pages alltypes_tiny_pages_plain data_index_bloom_encoding_stats int32_with_null_pages].each do |f|
      i = inspect_file(File.join(PT, "#{f}.parquet"))
      assert i.page_index?, f
      check_page_index(i, f)
    end
    i = inspect_file(File.join(GEN, "multi_page_with_index.parquet"))
    assert i.page_index?
    check_page_index(i, "multi_page_with_index")
  end

  def check_page_index(i, name)
    i.column_chunks.each do |c|
      oi = c.offset_index
      next unless oi
      data = c.data_pages
      assert_equal data.size, oi.page_locations.size, "#{name} #{c.path}"
      oi.page_locations.zip(data).each do |loc, page|
        assert_equal page.offset, loc.offset
        assert_equal page.total_size, loc.compressed_page_size
        assert_equal loc.first_row_index, page.first_row_index
      end
      firsts = oi.page_locations.map(&:first_row_index)
      assert_equal 0, firsts.first
      assert_equal firsts.sort, firsts
      assert_equal c.row_group.num_rows, data.sum(&:num_rows), "#{name} #{c.path}"
      ci = c.column_index or next
      assert_equal data.size, ci.null_pages.size
      ci.null_pages.each_with_index do |null_page, k|
        if null_page
          assert_nil ci.min_values[k]
        elsif ci.min_values[k].is_a?(Numeric) && ci.max_values[k].is_a?(Numeric)
          assert_operator ci.min_values[k], :<=, ci.max_values[k]
        end
      end
    end
  end

  def test_tiny_pages_statistics_and_indexes
    i = inspect_file(File.join(PT, "alltypes_tiny_pages.parquet"))
    assert_equal 7300, i.num_rows
    id = i.row_groups[0].column("id")
    assert_equal 0, id.statistics.min
    assert_equal 7299, id.statistics.max
    assert_equal 0, id.statistics.null_count
    assert_equal "min_value/max_value", id.statistics.source
    assert_operator id.pages.size, :>, 100
    ci = id.column_index
    assert_includes %w[ASCENDING UNORDERED], ci.boundary_order
    assert_equal 0, ci.min_values.min
    assert_equal 7299, ci.max_values.max
    assert_equal id.data_pages.size, ci.min_values.size
    s = i.row_groups[0].column("date_string_col").statistics
    assert_equal "01/01/09", s.min
    assert_equal "12/31/10", s.max
    assert_equal Encoding::UTF_8, s.min.encoding
    assert_equal i.row_groups[0].columns[0].pages, id.pages
  end

  def test_statistics_match_the_values_read
    {
      File.join(GEN, "multiple_row_groups.parquet") => nil,
      File.join(GEN, "logical_integers.parquet") => nil,
      File.join(GEN, "logical_decimal.parquet") => nil,
      File.join(GEN, "logical_temporal.parquet") => %w[date ts_us_utc ts_ms_utc],
      File.join(GEN, "enc_plain.parquet") => nil,
      File.join(PT, "alltypes_tiny_pages.parquet") => %w[id tinyint_col bigint_col double_col string_col],
      File.join(PT, "int32_decimal.parquet") => nil
    }.each do |path, only|
      i = inspect_file(path)
      File.open(path, "rb") do |io|
        r = Herringbone::Reader.new(io)
        r.schema.columns.each do |col|
          next if col.max_repetition_level.positive?
          next if only && !only.include?(col.dotted_path)
          r.row_groups.each_index do |rg|
            st = i.row_groups[rg].columns[col.index].statistics
            next unless st&.min
            values = Herringbone::Reader::ColumnChunkReader.new(io, r.row_groups[rg].columns[col.index], col).read.last.compact
            values = values.reject { |v| v.is_a?(Float) && v.nan? }
            next if values.empty?
            assert_equal values.min, st.min, "#{File.basename(path)} #{col.dotted_path} rg#{rg} min"
            assert_equal values.max, st.max, "#{File.basename(path)} #{col.dotted_path} rg#{rg} max"
          end
        end
      end
    end
  end

  def test_unsigned_and_decimal_and_temporal_statistics
    ints = inspect_file(File.join(GEN, "logical_integers.parquet")).row_groups[0]
    assert_equal [0, 18_446_744_073_709_551_615], [ints.column("u64").statistics.min, ints.column("u64").statistics.max]
    assert_equal [-128, 127], [ints.column("i8").statistics.min, ints.column("i8").statistics.max]
    dec = inspect_file(File.join(GEN, "logical_decimal.parquet")).row_groups[0]
    assert_kind_of BigDecimal, dec.column("d_38_10").statistics.max
    assert_equal BigDecimal("-999.99"), dec.column("d_5_2").statistics.min
    tmp = inspect_file(File.join(GEN, "logical_temporal.parquet")).row_groups[0]
    assert_equal Date.new(1, 1, 1, Date::GREGORIAN), tmp.column("date").statistics.min
    assert_kind_of Time, tmp.column("ts_us_utc").statistics.max
    misc = inspect_file(File.join(GEN, "logical_misc.parquet")).row_groups[0]
    assert_equal "ffffffff-ffff-ffff-ffff-ffffffffffff", misc.column("uuid").statistics.max
    assert_equal 65_504.0, misc.column("f16").statistics.max
  end

  def test_statistics_caveats
    legacy = inspect_file(File.join(PT, "fixed_length_decimal_legacy.parquet")).column_chunks.first.statistics
    assert_equal "min/max (legacy)", legacy.source
    assert_match(/legacy/, legacy.caveat)
    int96 = inspect_file(File.join(PT, "int96_timestamp_order.parquet")).column_chunks.first.statistics
    assert_match(/INT96 is undefined/, int96.caveat)
    truncated = inspect_file(File.join(PT, "binary_truncated_min_max.parquet"))
    stats = truncated.column_chunks.map(&:statistics)
    assert(stats.any? { |s| s.max_exact == false })
    assert(truncated.column_chunks.all? { |c| JSON.generate(c.to_h) })
  end

  def test_malformed_chunk_sizes_are_walked_past_the_declared_end
    i = inspect_file(File.join(PT, "nation.dict-malformed.parquet"))
    grown = i.column_chunks.select { |c| c.end_offset > c.declared_end_offset }
    refute_empty grown
    i.column_chunks.each do |c|
      assert_nil c.error
      assert_equal c.num_values, c.data_pages.sum(&:num_values)
    end
  end

  def test_dictionary_offset_zero_and_empty_chunks
    c = inspect_file(File.join(PT, "dict-page-offset-zero.parquet")).column_chunks.first
    assert_nil c.dictionary_page_offset
    assert_equal c.data_page_offset, c.start_offset
    zero = inspect_file(File.join(GEN, "zero_rows.parquet"))
    assert_equal 0, zero.num_rows
    zero.column_chunks.each { |ch| assert_operator ch.start_offset, :>=, 4 }
  end

  def test_bloom_filters_and_encoding_stats
    %w[data_index_bloom_encoding_stats data_index_bloom_encoding_with_length].each do |f|
      i = inspect_file(File.join(PT, "#{f}.parquet"))
      assert i.bloom_filters?, f
      c = i.column_chunks.first
      assert_operator c.bloom_filter_length, :>, 0, f
      assert_equal [:bloom_filter], i.layout.select { |s| s[:kind] == :bloom_filter }.map { |s| s[:kind] }
    end
    c = inspect_file(File.join(PT, "data_index_bloom_encoding_stats.parquet")).column_chunks.first
    refute_empty c.encoding_stats
    assert_equal c.data_pages.size, c.encoding_stats.select { |e| e[:page_type].to_s.start_with?("DATA") }.sum { |e| e[:count] }
  end

  def test_summary_schema_and_metadata
    i = inspect_file(File.join(GEN, "nested_struct_list_struct.parquet"))
    s = i.summary
    assert_equal File.size(File.join(GEN, "nested_struct_list_struct.parquet")), s[:file_size]
    assert_equal i.num_rows, s[:num_rows]
    assert_equal i.columns.size, s[:num_columns]
    assert_equal s[:file_size] - 8 - s[:footer_size], s[:footer_offset]
    leaves = []
    walk = ->(n) { n[:children] ? n[:children].each(&walk) : leaves << n }
    i.schema_tree.each(&walk)
    assert_equal i.columns.map(&:dotted_path), leaves.map { |l| l[:path] }
    assert(leaves.any? { |l| l[:max_repetition_level].positive? })
    arrow = i.key_value_metadata.find { |kv| kv[:key] == "ARROW:schema" }
    assert_equal "arrow_schema", arrow[:format]
    assert_operator arrow[:value].size, :<, 200
    spark = inspect_file(File.join(PT, "int96_from_spark.parquet")).key_value_metadata
    assert(spark.any? { |kv| kv[:format] == "json" && kv[:json].is_a?(Hash) })
    sorted = inspect_file(File.join(PT, "sort_columns.parquet")).row_groups[0].sorting_columns
    assert_equal [{column: "a", descending: true, nulls_first: true}, {column: "b", descending: false, nulls_first: false}], sorted
  end

  def test_column_totals
    i = inspect_file(File.join(GEN, "multiple_row_groups.parquet"))
    assert_operator i.row_groups.size, :>, 1
    t = i.column_totals.find { |x| x[:path] == "id" }
    assert_equal i.row_groups.sum { |rg| rg.column("id").compressed_size }, t[:compressed_size]
    assert_equal i.num_rows, t[:num_values]
    assert_equal 0, t[:min]
    assert_equal i.num_rows - 1, t[:max]
    assert_equal i.row_groups.size, t[:num_data_pages]
  end

  # false is a real min/max, not a missing one
  def test_boolean_min_max_in_totals_and_report
    schema = Herringbone::Schema.define { boolean :b }
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, row_group_rows: 2, page_rows: 1) do |w|
      [false, false, true, true].each { |v| w << [v] }
    end
    i = Inspector.new(StringIO.new(io.string))
    assert_equal [false, true], i.row_groups.map { |rg| rg.columns[0].statistics.min }
    t = i.column_totals.first
    assert_equal false, t[:min]
    assert_equal true, t[:max]
    # our writer puts page statistics in the page index only; give one page header its own
    i.column_chunks.first.pages.first.statistics = Inspector::Stats.new(min: false, max: false)
    text = i.report(pages: true)
    assert_match(/b: BOOLEAN .*\[false \.\. true\]/, text)
    assert_match(/  b: .*\[false \.\. false\]$/, text)
    assert_match(/    0: DATA_PAGE .*\[false \.\. false\]$/, text)
  end

  def test_accepts_io_reader_and_string
    path = File.join(GEN, "codec_snappy.parquet")
    expected = inspect_file(path).to_h[:row_groups]
    File.open(path, "rb") do |io|
      i = Inspector.new(io)
      assert_equal "codec_snappy.parquet", i.name
      assert_equal expected, i.to_h[:row_groups]
      refute io.closed?, "the caller's IO is left open"
    end
    assert_equal expected, Inspector.new(StringIO.new(File.binread(path))).to_h[:row_groups]
    assert_nil Inspector.new(StringIO.new(File.binread(path))).name
  end

  def test_rejects_paths
    [File.join(GEN, "codec_snappy.parquet"), Pathname.new(File.join(GEN, "codec_snappy.parquet")), nil].each do |bad|
      error = assert_raises(ArgumentError) { Inspector.new(bad) }
      assert_match(/expects an IO that supports #seek and #read \(e.g. File.open\(path, "rb"\)\)/, error.message)
    end
  end

  def test_load_all_reads_everything_up_front
    i = inspect_file(File.join(GEN, "multiple_row_groups.parquet"))
    # the IO is closed by now, so everything below must already be loaded
    assert i.instance_variable_get(:@io).closed?
    refute_empty i.column_chunks.first.pages
    assert JSON.generate(i.to_h)
    refute_empty i.report(pages: true)
  end

  def test_rejects_non_parquet
    assert_raises(Herringbone::FormatError) { Inspector.new(StringIO.new("not a parquet file at all")) }
  end

  # ---- page CRCs ----

  def checksums_of(path)
    File.open(path, "rb") do |io|
      i = Inspector.new(io)
      [i, i.verify_checksums]
    end
  end

  def test_checksums_are_not_read_unless_asked
    i = inspect_file(File.join(PT, "datapage_v1-corrupt-checksum.parquet"))
    refute i.checksums_verified?
    assert_nil i.checksum_summary
    assert(i.column_chunks.flat_map(&:pages).all? { |p| p.checksum.nil? && p.crc })
    refute i.summary.key?(:checksums)
    refute i.to_h.key?(:checksum_mismatches)
    refute_match(/CRC MISMATCH|crc ok/, i.report(pages: true))
  end

  def test_verify_checksums_of_parquet_testing_fixtures
    without_decompression do
      {"datapage_v1-uncompressed-checksum" => [4, 0, 0], "datapage_v1-snappy-compressed-checksum" => [4, 0, 0],
       "plain-dict-uncompressed-checksum" => [4, 0, 0], "rle-dict-snappy-checksum" => [2, 0, 2],
       "datapage_v1-corrupt-checksum" => [2, 2, 0], "rle-dict-uncompressed-corrupt-checksum" => [0, 2, 2]}.each do |f, (ok, bad, absent)|
        i, s = checksums_of(File.join(PT, "#{f}.parquet"))
        assert_equal [ok, bad, absent], [s[:ok], s[:mismatch], s[:absent]], f
        assert_equal bad, s[:mismatches].size, f
        assert i.checksums_verified?
        assert_equal s.except(:mismatches), i.summary[:checksums]
      end
    end
    # one data page of each column is corrupt
    _, s = checksums_of(File.join(PT, "datapage_v1-corrupt-checksum.parquet"))
    assert_equal [["a", 0, :DATA_PAGE], ["b", 1, :DATA_PAGE]], s[:mismatches].map { |m| [m[:column], m[:page], m[:type]] }
    s[:mismatches].each { |m| refute_equal m[:crc], m[:actual] }
    # only the dictionary pages carry (corrupt) CRCs here
    i, = checksums_of(File.join(PT, "rle-dict-uncompressed-corrupt-checksum.parquet"))
    assert_equal [%i[DICTIONARY_PAGE mismatch], %i[DATA_PAGE_V2 absent]] * 2, i.column_chunks.flat_map(&:pages).map { |p| [p.type, p.checksum] }
  end

  def test_verify_checksums_of_files_we_write
    schema = Herringbone::Schema.define do
      int64 :id
      string :name
      list :tags, :string
    end
    [1, 2].each do |version|
      %i[none snappy gzip].each do |codec|
        io = StringIO.new("".b)
        Herringbone::Writer.open(io, schema, compression: codec, data_page_version: version, page_rows: 100) do |w|
          500.times { |k| w << [k, k.even? ? nil : "name #{k % 7}", Array.new(k % 3) { |t| "t#{t}" }] }
        end
        i = Inspector.new(StringIO.new(io.string))
        s = i.verify_checksums
        where = "v#{version} #{codec}"
        assert_equal 0, s[:mismatch], where
        assert_equal 0, s[:absent], where
        assert_equal i.column_chunks.sum { |c| c.pages.size }, s[:ok], where
        assert_operator s[:ok], :>, 10, where

        # flip one byte in the body of the last data page of "name"
        page = i.row_groups[0].column("name").data_pages.last
        bytes = io.string.dup
        at = page.body_offset + page.compressed_size - 1
        bytes.setbyte(at, bytes.getbyte(at) ^ 0x01)
        broken = Inspector.new(StringIO.new(bytes))
        s = broken.verify_checksums
        assert_equal 1, s[:mismatch], where
        assert_equal [{row_group: 0, column: "name", page: page.index, type: page.type, offset: page.offset}],
          s[:mismatches].map { |m| m.slice(:row_group, :column, :page, :type, :offset) }, where
        assert_equal :mismatch, broken.row_groups[0].column("name").pages[page.index].checksum
      end
    end
  end

  def test_checksums_in_to_h_and_report
    path = File.join(PT, "datapage_v1-corrupt-checksum.parquet")
    h = File.open(path, "rb") { |io| Inspector.new(io).tap(&:verify_checksums).to_h }
    assert_equal({ok: 2, mismatch: 2, absent: 0}, h[:summary][:checksums])
    assert_equal 2, h[:checksum_mismatches].size
    statuses = h[:row_groups][0][:columns].flat_map { |c| c[:pages].map { |p| p[:checksum] } }
    assert_equal %w[mismatch ok ok mismatch], statuses
    assert JSON.generate(h)
    text = File.open(path, "rb") { |io| Inspector.new(io).tap(&:verify_checksums).report(pages: true) }
    assert_match(/page CRCs: 2 ok, 2 mismatched, 0 without a CRC/, text)
    assert_match(/CRC MISMATCH: row group 0 a page 0 \(DATA_PAGE @4\): header says \h{8}, data has \h{8}/, text)
    assert_match(/0: DATA_PAGE @4 .* CRC MISMATCH/, text)
    assert_match(/1: DATA_PAGE @\d+ .* crc ok/, text)
  end

  def test_checksum_results_survive_closing_the_file
    schema = Herringbone::Schema.define { int64 :id }
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, compression: :none, dictionary: false, page_rows: 1000) do |w|
      30_000.times { |k| w << [k] }
    end
    # corrupt pages far apart, so no read-ahead window holds both
    pages = Inspector.new(StringIO.new(io.string)).column_chunks.first.data_pages.values_at(0, -1)
    bytes = io.string.dup
    pages.each { |p| bytes.setbyte(p.body_offset, bytes.getbyte(p.body_offset) ^ 0x01) }
    file = StringIO.new(bytes)
    i = Inspector.new(file).load_all
    s = i.verify_checksums
    file.close
    assert_equal 2, s[:mismatch]
    assert_equal(pages.map { |p| Zlib.crc32(bytes.byteslice(p.body_offset, p.compressed_size)) }, s[:mismatches].map { |m| m[:actual] })
    assert_equal s, i.checksum_summary
    assert_equal 2, i.summary[:checksums][:mismatch]
    assert_equal 2, i.to_h[:checksum_mismatches].size
    assert_match(/data has \h{8}/, i.report)
  end

  # ---- ARROW:schema ----

  # Expected types were printed by pyarrow (pa.ipc.read_schema on the decoded ARROW:schema
  # value; str(field.type)), with extension types shown as their storage type
  ARROW_EXPECTED = {
    "logical_temporal" => [
      "date: date32[day]", "time_ms: time32[ms]", "time_us: time64[us]", "time_ns: time64[ns]",
      "ts_ms: timestamp[ms]", "ts_us: timestamp[us]", "ts_ns: timestamp[ns]", "ts_ms_utc: timestamp[ms, tz=UTC]",
      "ts_us_utc: timestamp[us, tz=UTC]", "ts_ns_utc: timestamp[ns, tz=UTC]", "ts_us_tz_ny: timestamp[us, tz=America/New_York]"
    ],
    "logical_integers" => %w[i8:int8 i16:int16 i32:int32 i64:int64 u8:uint8 u16:uint16 u32:uint32 u64:uint64].map { |s| s.sub(":", ": ") },
    "logical_decimal" => ["d_5_2: decimal128(5, 2)", "d_9_0: decimal128(9, 0)", "d_18_6: decimal128(18, 6)",
      "d_38_10: decimal128(38, 10)", "d_76_20: decimal256(76, 20)"],
    "logical_misc" => ["uuid: fixed_size_binary[16]", "fsb3: fixed_size_binary[3]", "f16: halffloat", "json: string",
      "large_string: large_string", "binary: binary", "large_binary: large_binary", "f32: float", "f64: double"],
    "dictionary_arrow_type" => ["d: dictionary<values=string, indices=int32, ordered=0>"],
    "required_columns" => ["a: int32 not null", "b: string not null"],
    "all_null_columns" => ["id: int32", "null_int: int32", "null_string: string", "null_double: double",
      "null_list: list<item: int32>", "null_struct: struct<a: int32>", "null_type: null"],
    "nested_list_int_nulls" => ["l: list<item: int32>", "l_required_elems: list<element: int32 not null>"],
    "nested_list_list_string" => ["ll: list<item: list<item: string>>"],
    "nested_map_string_int" => ["m: map<string, int32>"],
    "nested_struct_list_struct" => ["s: struct<a: int32, b: list<item: struct<c: string>>>", "id: int32"],
    "nested_deep_v2" => ["d: struct<m: map<string, list<item: int16>>, s: struct<x: double, y: list<item: bool>>>"],
    "enc_byte_stream_split" => ["f32: float", "f64: double", "i32: int32", "i64: int64", "flba: fixed_size_binary[4]", "f16: halffloat"],
    "format_version_1_0" => ["id: int64", "name: string", "value: double", "flag: bool", "small: int32", "ts: timestamp[ms]"],
    "timestamp_int96" => ["ts: timestamp[us]"]
  }.freeze

  def arrow_lines(fields) = fields.map { |f| "#{f[:name]}: #{f[:type]}#{" not null" unless f[:nullable]}" }

  def test_arrow_schema_matches_pyarrow
    ARROW_EXPECTED.each do |f, expected|
      i = inspect_file(File.join(GEN, "#{f}.parquet"))
      assert_nil i.arrow_schema_error, f
      assert_equal expected, arrow_lines(i.arrow_schema[:fields]), f
      assert_equal "little", i.arrow_schema[:endianness]
    end
    {
      "list_columns" => ["int64_list: list<item: int64>", "utf8_list: list<item: string>"],
      "null_list" => ["emptylist: list<item: null>"],
      "byte_stream_split_extended.gzip" => ["float16_plain: halffloat", "float16_byte_stream_split: halffloat",
        "float_plain: float", "float_byte_stream_split: float", "double_plain: double", "double_byte_stream_split: double",
        "int32_plain: int32", "int32_byte_stream_split: int32", "int64_plain: int64", "int64_byte_stream_split: int64",
        "flba5_plain: fixed_size_binary[5]", "flba5_byte_stream_split: fixed_size_binary[5]",
        "decimal_plain: decimal128(7, 3)", "decimal_byte_stream_split: decimal128(7, 3)"],
      "overflow_i16_page_cnt" => ["inc: bool not null"]
    }.each do |f, expected|
      assert_equal expected, arrow_lines(inspect_file(File.join(PT, "#{f}.parquet")).arrow_schema[:fields]), f
    end
  end

  def test_arrow_schema_nested_children_dictionary_extension_and_metadata
    nested = inspect_file(File.join(GEN, "nested_deep_v2.parquet")).arrow_schema[:fields].first
    m = nested[:children].first
    assert_equal ["m", "map<string, list<item: int16>>"], [m[:name], m[:type]]
    entries = m[:children].first
    assert_equal ["entries", false], [entries[:name], entries[:nullable]]
    assert_equal ["key: string not null", "value: list<item: int16>"], arrow_lines(entries[:children])

    dict = inspect_file(File.join(GEN, "dictionary_arrow_type.parquet")).arrow_schema[:fields].first
    assert_equal({index_type: "int32", ordered: false, id: 0}, dict[:dictionary])

    misc = inspect_file(File.join(GEN, "logical_misc.parquet")).arrow_schema[:fields]
    assert_equal ["arrow.uuid", nil, nil, "arrow.json"], misc.first(4).map { |f| f[:extension] }
    unknown = inspect_file(File.join(PT, "unknown-logical-type.parquet")).arrow_schema[:fields]
    assert_equal({"ARROW:extension:metadata" => "{}", "ARROW:extension:name" => "geoarrow.wkb"}, unknown[1][:metadata])
    assert_equal "geoarrow.wkb", unknown[1][:extension]
    assert_nil unknown[0][:metadata]

    pandas = inspect_file(File.join(PT, "list_columns.parquet")).arrow_schema[:metadata]
    assert_equal ["pandas"], pandas.keys
    assert JSON.parse(pandas["pandas"])
  end

  # Serialized by pyarrow: pa.schema([...]).serialize(), base64-encoded, covering the types the
  # fixtures don't use (and field/schema metadata)
  EXOTIC_ARROW_SCHEMA = <<~B64.delete("\n")
    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
    AAgADAAIAAcACAAAAAAAAAFAAAAAAAAAAA==
  B64

  def test_arrow_schema_exotic_types
    s = Inspector::ArrowSchema.decode(EXOTIC_ARROW_SCHEMA)
    assert_equal [
      "id: int64 not null", "d: duration[us]", "t: time32[s]", "d64: date64[ms]", "iv: month_day_nano_interval",
      "dec: decimal256(40, 5)", "ll: large_list<x: float not null>", "fl: fixed_size_list<item: int8>[3]",
      "u: dense_union<a: int32=5, b: string=7>", "m: map<string, int32, keys_sorted>",
      "ree: run_end_encoded<run_ends: int32, values: string>", "sv: string_view",
      "dict: dictionary<values=large_string, indices=int8, ordered=1>", "ts: timestamp[ns, tz=+01:00]", "st: struct<inner: uint16>"
    ], arrow_lines(s[:fields])
    assert_equal({"origin" => "herringbone test"}, s[:metadata])
    assert_equal({"comment" => "primary key", "PARQUET:field_id" => "1"}, s[:fields][0][:metadata])
    assert_equal({"k" => "v"}, s[:fields].last[:children][0][:metadata])
    assert_equal({index_type: "int8", ordered: true, id: 0}, s[:fields][12][:dictionary])
    lines = Inspector::ArrowSchema.lines(s[:fields])
    assert_includes lines, 'id: int64 (not null; metadata comment="primary key", PARQUET:field_id="1")'
    assert_includes lines, '  inner: uint16 (metadata k="v")'
  end

  def test_arrow_schema_in_metadata_schema_tree_and_report
    i = inspect_file(File.join(GEN, "nested_struct_list_struct.parquet"))
    kv = i.key_value_metadata.find { |x| x[:key] == "ARROW:schema" }
    assert_equal "Arrow schema, 2 fields", kv[:summary]
    assert_equal %w[s id], kv[:arrow_fields]
    assert_equal i.arrow_schema[:fields], kv[:arrow_schema][:fields]
    tree = i.schema_tree
    assert_equal ["struct<a: int32, b: list<item: struct<c: string>>>", "int32"], tree.map { |n| n[:arrow_type] }
    assert_equal ["int32", "list<item: struct<c: string>>"], tree[0][:children].map { |n| n[:arrow_type] }
    report = i.report
    assert_match(/^    s: struct<a: int32, b: list<item: struct<c: string>>>$/, report)
    assert_match(/^  optional INT32 id  \[def 1, rep 0\]  arrow: int32$/, report)
    assert JSON.generate(i.to_h)
    none = inspect_file(File.join(GEN, "logical_integers_no_arrow_schema.parquet"))
    assert_nil none.arrow_schema
    assert_nil none.arrow_schema_error
    assert(none.schema_tree.none? { |n| n.key?(:arrow_type) })
  end

  def test_arrow_schema_decoding_fails_soft
    good = inspect_file(File.join(GEN, "codec_snappy.parquet"))
    value = good.metadata.key_value_metadata.find { |kv| kv.key == "ARROW:schema" }.value
    raw = value.unpack1("m")
    broken = {
      "truncated" => [raw.byteslice(0, raw.bytesize / 2)].pack("m0"),
      "garbage offsets" => [raw.byteslice(0, 12) + ("\xFF".b * (raw.bytesize - 12))].pack("m0"),
      "not base64" => "!!!",
      "not an IPC message" => ["\x10\x00\x00\x00".b + ("\x00".b * 16)].pack("m0")
    }
    broken.each do |label, v|
      assert_raises(Inspector::ArrowSchema::Error, label) { Inspector::ArrowSchema.decode(v) }
      io = StringIO.new("".b)
      schema = Herringbone::Schema.define { int64 :id }
      Herringbone::Writer.open(io, schema, metadata: {"ARROW:schema" => v}) { |w| w << [1] }
      i = Inspector.new(StringIO.new(io.string))
      assert_nil i.arrow_schema, label
      assert_match(/could not decode ARROW:schema/, i.arrow_schema_error, label)
      kv = i.key_value_metadata.first
      assert_equal "arrow_schema", kv[:format], label
      assert_match(/could not decode/, kv[:arrow_error], label)
      assert_match(/Arrow IPC schema message, base64-encoded/, kv[:summary], label)
      assert_match(/could not decode ARROW:schema/, i.report, label)
      assert JSON.generate(i.to_h)
    end
  end

  # ---- page statistics vs ColumnIndex ----

  def test_page_statistics_agree_with_the_column_index_in_fixtures
    FIXTURES.each do |path|
      assert_empty inspect_file(path).index_mismatches, File.basename(path)
    end
    # these have both page statistics and a column index, including truncated binary bounds
    %w[binary_truncated_min_max repeated_primitive_no_list data_index_bloom_encoding_with_length].each do |f|
      i = inspect_file(File.join(PT, "#{f}.parquet"))
      assert(i.column_chunks.any? { |c| c.column_index && c.data_pages.any?(&:statistics) }, f)
    end
  end

  def test_page_statistics_disagreeing_with_the_column_index_are_flagged
    i = inspect_file(File.join(PT, "repeated_primitive_no_list.parquet"))
    c = i.row_groups[0].column("Int32_list")
    page = c.data_pages.first
    assert_equal [0, 8, 1], [page.statistics.min, page.statistics.max, page.num_nulls]
    ci = c.column_index.dup
    ci.min_values = [1]  # narrower than the page: flagged
    ci.max_values = [9]  # wider: allowed
    ci.null_counts = [2]
    c.instance_variable_set(:@column_index, ci)
    c.remove_instance_variable(:@index_mismatches) if c.instance_variable_defined?(:@index_mismatches)
    assert_equal [{page: page.index, data_page: 0, field: :null_count, page_value: 1, index_value: 2},
      {page: page.index, data_page: 0, field: :min, page_value: 0, index_value: 1}], c.index_mismatches
    assert_equal [{row_group: 0, column: "Int32_list"}], i.index_mismatches.map { |m| m.slice(:row_group, :column) }.uniq
    assert_equal 2, c.to_h[:index_mismatches].size
    assert_match(/page statistics vs column index: 2 disagreements/, i.report)
    assert_match(/row group 0 Int32_list page 1: min in page header 0, in column index 1/, i.report)

    strings = i.row_groups[0].column("String_list")
    ci = strings.column_index.dup
    ci.max_values = ["zer"]  # a truncated prefix: allowed
    strings.instance_variable_set(:@column_index, ci)
    assert_empty strings.index_mismatches
    ci = ci.dup
    ci.max_values = ["yes"]
    ci.null_pages = [true]
    strings.instance_variable_set(:@column_index, ci)
    strings.remove_instance_variable(:@index_mismatches)
    assert_equal [:null_page], strings.index_mismatches.map { |m| m[:field] }
    ci = ci.dup
    ci.null_pages = [false, false]
    strings.instance_variable_set(:@column_index, ci)
    strings.remove_instance_variable(:@index_mismatches)
    assert_equal [{page: nil, data_page: nil, field: :page_count, page_value: 1, index_value: 2}], strings.index_mismatches
  end
end
