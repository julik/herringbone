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
    Compression.instance_variable_set(:@libraries, {})
    missing = ->(path) { raise LoadError, "cannot load such file -- #{path}" }
    forbidden = ->(*) { flunk "the inspector must not decompress pages" }
    Compression.stub(:require_library, missing) do
      Compression.stub(:decompress, forbidden, &block)
    end
  ensure
    Compression.instance_variable_set(:@libraries, {})
  end

  def inspect_file(path)
    File.open(path, "rb") { |io| Herringbone.inspect_file(io) }
  end

  def with_reader(path, &block)
    File.open(path, "rb") { |io| block.call(Herringbone::Reader.new(io)) }
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
    assert_equal i.pages(0, "id"), id.pages
    assert_equal i.pages(0, 0), id.pages
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
      with_reader(path) do |r|
        r.schema.columns.each do |col|
          next if col.max_repetition_level.positive?
          next if only && !only.include?(col.dotted_path)
          r.row_groups.each_index do |rg|
            st = i.row_groups[rg].columns[col.index].statistics
            next unless st&.min
            values = r.read_column_chunk(rg, col).last.compact
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
    assert_equal [{ column: "a", descending: true, nulls_first: true }, { column: "b", descending: false, nulls_first: false }], sorted
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

  def test_accepts_io_reader_and_string
    path = File.join(GEN, "codec_snappy.parquet")
    expected = inspect_file(path).to_h[:row_groups]
    File.open(path, "rb") do |io|
      i = Inspector.new(io)
      assert_equal "codec_snappy.parquet", i.name
      assert_equal expected, i.to_h[:row_groups]
      refute io.closed?, "the caller's IO is left open"
    end
    with_reader(path) do |r|
      assert_equal expected, Inspector.new(r).to_h[:row_groups]
      assert_equal r.num_rows, r.each_row.count # reader still usable
    end
    assert_equal expected, Inspector.from_string(File.binread(path)).to_h[:row_groups]
    assert_nil Inspector.from_string(File.binread(path)).name
  end

  def test_rejects_paths
    [File.join(GEN, "codec_snappy.parquet"), Pathname.new(File.join(GEN, "codec_snappy.parquet")), nil].each do |bad|
      error = assert_raises(ArgumentError) { Inspector.new(bad) }
      assert_match(/expects an IO that supports #seek and #read \(e.g. File.open\(path, "rb"\)\)/, error.message)
    end
  end

  def test_inspect_file_loads_everything_up_front
    i = inspect_file(File.join(GEN, "multiple_row_groups.parquet"))
    # the IO is closed by now, so everything below must already be loaded
    assert i.instance_variable_get(:@io).closed?
    refute_empty i.column_chunks.first.pages
    assert JSON.generate(i.to_h)
    refute_empty i.report(pages: true)
  end

  def test_rejects_non_parquet
    assert_raises(Herringbone::FormatError) { Inspector.from_string("not a parquet file at all") }
  end
end
