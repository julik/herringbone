# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "tmpdir"

# Writes and reads Parquet from several Ractors at once
class RactorTest < Minitest::Test
  # Fixtures the readers go through, covering the codecs, encodings and nesting the files use
  FIXTURES = %w[
    alltypes_plain.snappy.parquet alltypes_tiny_pages.parquet nested_map_string_int.parquet
    nested_struct_list_struct.parquet logical_temporal.parquet logical_decimal.parquet
    enc_delta_mixed_v2_zstd.parquet enc_byte_stream_split.parquet codec_gzip.parquet
    codec_lz4.parquet codec_zstd.parquet codec_brotli.parquet bloom_filters_arrow.parquet
  ].freeze

  def setup
    @experimental = Warning[:experimental]
    Warning[:experimental] = false
    @dir = Dir.mktmpdir
  end

  def teardown
    Warning[:experimental] = @experimental
    FileUtils.rm_rf(@dir)
  end

  def test_concurrent_writers_and_readers
    # Ruby 3.0 does not let other Ractors read instance variables of modules, even frozen ones
    skip "Ractors need Ruby 3.1" if RUBY_VERSION < "3.1"
    readable = FIXTURES.map { |name| fixture_path(name) }.select { |path| readable?(path) }
    written = 2.times.map { |i| File.join(@dir, "written_#{i}.parquet").freeze }
    codecs = Ractor.make_shareable(WriterHelpers::CODECS.dup)

    schemas = Ractor.make_shareable([WriterHelpers::ALL_TYPES_SCHEMA, WriterHelpers::NESTED_SCHEMA])
    # Rows are copied into each Ractor: Ruby 3.0 cannot make a Time shareable
    nested = WriterHelpers.nested_rows(50)
    writers = written.each_with_index.map do |path, i|
      rows = WriterHelpers.all_types_rows(200 + i)
      Ractor.new(path, i, rows, nested, schemas, codecs) do |path, i, rows, nested, (all_types, nested_schema), codecs|
        opts = {bloom_filters: ["str", "i64"], row_group_rows: 64, data_page_version: i + 1, dictionary: i.zero?}
        File.open(path, "wb") { |f| Herringbone.write(f, rows, schema: all_types, **opts) }
        nested_counts = codecs.map do |codec|
          Herringbone.write(StringIO.new, nested, schema: nested_schema, compression: codec, data_page_version: 2 - i)
        end
        inferred = Herringbone.write(StringIO.new, rows.map { |r| r.slice("id", "str", "f64", "ts_us", "dec_med") })
        simple = StringIO.new
        Herringbone::SimpleWriter.open(simple) do |sw|
          sw.headers!(:id, :name)
          rows.each { |r| sw << [r["id"], r["str"]] }
        end
        [rows.length, nested_counts.uniq, inferred, Herringbone::Reader.new(simple).read.length]
      end
    end
    readers = 2.times.map do |i|
      Ractor.new(readable.rotate(i * 5)) do |paths|
        paths.map do |path|
          File.open(path, "rb") do |f|
            reader = Herringbone::Reader.new(f, keys: :symbol)
            first = reader.schema.fields.first.name
            [
              File.basename(path),
              reader.read.length,
              reader.each_batch(3).sum(&:length),
              reader.read(as: :columns, columns: [first]).fetch(first.to_sym).length,
              reader.each_row(limit: 5).count
            ]
          end
        end
      end
    end

    write_results = writers.map { |r| ractor_value(r) }
    assert_equal [[200, [50], 200, 200], [201, [50], 201, 201]], write_results
    read_results = readers.map { |r| ractor_value(r).sort }
    assert_equal read_results[0], read_results[1]
    read_results[0].each do |name, rows, batched, column, limited|
      assert_equal [rows, rows, [rows, 5].min], [batched, column, limited], name
    end

    rereaders = written.map do |path|
      Ractor.new(path) do |path|
        File.open(path, "rb") do |f|
          reader = Herringbone::Reader.new(f)
          numo = begin
            reader.read(as: :numo, columns: ["i32", "f64"]).fetch("i32").size
          rescue Herringbone::UnsupportedError
            :no_numo
          end
          found = reader.read(where: {"str" => "plain"}, columns: ["id"]).length
          [reader.read.length, reader.read(where: {"str" => "nope"}).length, found, numo]
        end
      end
    end
    rereads = rereaders.map { |r| ractor_value(r) }
    assert_equal [[200, 0], [201, 0]], rereads.map { |r| r.first(2) }
    rereads.each { |r| assert_operator r[2], :>, 0 }
    rereads.each_with_index { |r, i| assert_includes [200 + i, :no_numo], r[3] }
  end

  private

  # Whether the codecs of the file's column chunks are available
  def readable?(path)
    meta = File.open(path, "rb") { |f| Herringbone::Reader.new(f).file_metadata }
    meta.row_groups.flat_map { |rg| rg.columns.map { |c| Herringbone::Compression::NAMES[c.meta_data.codec] } }
      .all? { |codec| WriterHelpers::CODECS.include?(codec) }
  end

  def fixture_path(name)
    [File.join(FIXTURES_DIR, "parquet-testing", name), File.join(FIXTURES_DIR, "generated", name)]
      .find { |p| File.exist?(p) }.freeze
  end

  # Ractor#take became Ractor#value in Ruby 3.5
  def ractor_value(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end
