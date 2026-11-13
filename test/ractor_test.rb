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
    # Ractors cannot autoload before Ruby 3.4; later Rubies load from any Ractor
    Herringbone.eager_load! if RUBY_VERSION < "3.4"
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
        Herringbone.write(simple, rows.map { |r| [r["id"], r["str"]] }, headers: [:id, :name])
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

  # Shareable rows reach the writer by reference, without being copied. (send(row, move: true)
  # cannot move Time or Date, and corrupts moved Hashes of Strings on Ruby 3.2 and 3.4.)
  def test_rows_sent_to_a_writer_ractor_are_not_copied
    skip "Ractors need Ruby 3.1" if RUBY_VERSION < "3.1"
    schemas = {
      "all_types.parquet" => WriterHelpers::ALL_TYPES_SCHEMA,
      "nested.parquet" => WriterHelpers::NESTED_SCHEMA
    }
    writers = schemas.to_h do |name, schema|
      writer = Ractor.new(File.join(@dir, name), Ractor.make_shareable(schema)) do |path, schema|
        seen = []
        File.open(path, "wb") do |f|
          w = Herringbone::Writer.new(f, schema, row_group_rows: 50)
          while (row = Ractor.receive) != :done
            seen << row.object_id if seen.size < 3
            w << row
          end
          w.close
          [w.rows_written, seen]
        end
      end
      [name, writer]
    end

    rows = {
      "all_types.parquet" => WriterHelpers.all_types_rows(120),
      "nested.parquet" => WriterHelpers.nested_rows(80)
    }
    rows.each do |name, list|
      list.each { |row| writers[name].send(Ractor.make_shareable(row)) }
      writers[name].send(:done)
    end

    rows.each do |name, list|
      count, seen = ractor_value(writers[name])
      assert_equal list.size, count, name
      assert_equal list.first(3).map(&:object_id), seen, "#{name}: the writer gets the same objects"
    end
    read = ->(name, columns) { File.open(File.join(@dir, name), "rb") { |f| Herringbone::Reader.new(f).read(columns: columns) } }
    assert_equal rows["all_types.parquet"].map { |r| r.slice("id", "str", "ts_us") }, read.call("all_types.parquet", %w[id str ts_us])
    assert_equal rows["nested.parquet"].map { |r| r.slice("id", "m_nullval") }, read.call("nested.parquet", %w[id m_nullval])
  end

  # Combining goes through Schema::Merge and the Combiner, whose tables a Ractor reads too
  def test_combine_in_a_ractor
    skip "Ractors need Ruby 3.1" if RUBY_VERSION < "3.1"
    inputs = 2.times.map do |i|
      path = File.join(@dir, "part_#{i}.parquet").freeze
      File.open(path, "wb") do |f|
        Herringbone::Writer.open(f, WriterHelpers::ALL_TYPES_SCHEMA) do |w|
          WriterHelpers.all_types_rows(30).each { |row| w << row }
        end
      end
      path
    end
    output = File.join(@dir, "combined.parquet").freeze
    combiner = Ractor.new(inputs, output) do |inputs, output|
      ios = inputs.map { |path| File.open(path, "rb") }
      File.open(output, "wb") { |f| Herringbone.combine(ios, f).rows }
    ensure
      ios&.each(&:close)
    end
    assert_equal 60, ractor_value(combiner)
  end

  # The redaction and its blocks are made inside the Ractor, so nothing has to be shareable but the paths
  def test_redact_in_a_ractor
    skip "Ractors need Ruby 3.1" if RUBY_VERSION < "3.1"
    schema = Herringbone::Schema.define do |s|
      s.int64 :user_id, null: false
      s.string :email
      s.string :name
      s.uint32 :score
    end
    input = File.join(@dir, "people.parquet").freeze
    File.open(input, "wb") do |f|
      Herringbone::Writer.open(f, schema, row_group_rows: 25) do |w|
        100.times { |i| w << {user_id: i % 10, email: "user#{i}@example.com", name: "Name #{i}", score: i} }
      end
    end
    output = File.join(@dir, "redacted.parquet").freeze
    redactor = Ractor.new(input, output) do |input, output|
      File.open(input, "rb") do |source|
        File.open(output, "wb") do |f|
          Herringbone.redact(source, f) do |r|
            r.where(user_id: 7).delete
            r.where(user_id: 3).replace(name: nil)
            r.replace(:email) { |email| email.sub(/@.+/, "@example.org") }
            r.drop :score
          end
        end
      end
      :done
    end
    assert_equal :done, ractor_value(redactor)

    rows = File.open(output, "rb") { |f| Herringbone::Reader.new(f).read }
    assert_equal 90, rows.size, "user 7 is gone"
    refute rows.any? { |row| row["user_id"] == 7 }
    assert rows.select { |row| row["user_id"] == 3 }.all? { |row| row["name"].nil? }
    assert rows.all? { |row| row["email"].end_with?("@example.org") }
    assert_equal %w[user_id email name], rows.first.keys
  end

  # Any constant a Ractor touches must be shareable, or reading it raises Ractor::IsolationError
  def test_constants_are_shareable
    skip "Ractors need Ruby 3.1" if RUBY_VERSION < "3.1"
    Herringbone.eager_load!
    unshareable = []
    walk = lambda do |mod|
      mod.constants(false).each do |name|
        value = mod.const_get(name, false)
        if value.is_a?(Module)
          walk.call(value) if value.name&.start_with?("#{mod.name}::")
        elsif !Ractor.shareable?(value)
          unshareable << "#{mod}::#{name}"
        end
      end
    end
    walk.call(Herringbone)
    assert_empty unshareable
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
