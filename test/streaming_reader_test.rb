# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "tmpdir"

# Batch-wise reading (each_batch / each_row), rows that span pages, keys: and time_zone:
class StreamingReaderTest < Minitest::Test
  include WriterHelpers

  F = Herringbone::Format
  E = F::Encoding
  RLE = Herringbone::Encodings::RLE
  Plain = Herringbone::Encodings::Plain

  ALL_ROWS = WriterHelpers.all_types_rows(60)
  NESTED_ROWS = WriterHelpers.nested_rows(80)

  # Rewrites a file so that every column chunk is cut into data pages of +per_page+ entries,
  # regardless of row boundaries (as some writers do for v1 pages), uncompressed, optionally
  # with a dictionary page.
  def resplit(bytes, per_page:, version: 1, dictionary: false)
    reader = reader_for(bytes)
    meta = reader.file_metadata
    out = "PAR1".b
    meta.row_groups.each do |rg|
      rg_start = out.bytesize
      rg.columns.each_with_index do |chunk, i|
        col = reader.schema.columns[i]
        defs, reps, vals = Herringbone::Reader::ColumnChunkReader.new(StringIO.new(bytes), chunk, col, converter: nil).read
        n = (defs || reps || vals).size
        start = out.bytesize
        dict_offset = nil
        if dictionary
          dict = []
          index = {}
          # Keyed by bytes for Floats, where 0.0.eql?(-0.0)
          ids = vals.map { |v|
            key = v.is_a?(Float) ? [v].pack("G") : v
            index.fetch(key) { index[key] = (dict << v).size - 1 }
          }
          body = Plain.encode(dict, col.type, col.type_length)
          header = F::PageHeader.new(type: F::PageType::DICTIONARY_PAGE, uncompressed_page_size: body.bytesize,
            compressed_page_size: body.bytesize,
            dictionary_page_header: F::DictionaryPageHeader.new(num_values: dict.size, encoding: E::PLAIN))
          dict_offset = start
          out << header.encode << body
          id_width = [RLE.bit_width(dict.size - 1), 1].max
        end
        data_offset = out.bytesize
        vi = 0
        (0...n).step(per_page) do |from|
          cnt = [per_page, n - from].min
          d = defs && defs[from, cnt]
          r = reps && reps[from, cnt]
          nv = d ? d.count(col.max_definition_level) : cnt
          values = if dictionary
            [id_width].pack("C") + RLE.encode_hybrid(ids[vi, nv], id_width)
          else
            Plain.encode(vals[vi, nv], col.type, col.type_length)
          end
          vi += nv
          encoding = dictionary ? E::RLE_DICTIONARY : E::PLAIN
          rep_bytes = r ? RLE.encode_hybrid(r, col.max_repetition_level.bit_length) : "".b
          def_bytes = d ? RLE.encode_hybrid(d, col.max_definition_level.bit_length) : "".b
          if version == 1
            body = "".b
            body << [rep_bytes.bytesize].pack("V") << rep_bytes if r
            body << [def_bytes.bytesize].pack("V") << def_bytes if d
            body << values
            header = F::PageHeader.new(type: F::PageType::DATA_PAGE, uncompressed_page_size: body.bytesize,
              compressed_page_size: body.bytesize,
              data_page_header: F::DataPageHeader.new(num_values: cnt, encoding: encoding,
                definition_level_encoding: E::RLE, repetition_level_encoding: E::RLE))
          else
            body = rep_bytes + def_bytes + values
            header = F::PageHeader.new(type: F::PageType::DATA_PAGE_V2, uncompressed_page_size: body.bytesize,
              compressed_page_size: body.bytesize,
              data_page_header_v2: F::DataPageHeaderV2.new(num_values: cnt, num_nulls: cnt - nv,
                num_rows: r ? r.count(0) : cnt, encoding: encoding, definition_levels_byte_length: def_bytes.bytesize,
                repetition_levels_byte_length: rep_bytes.bytesize, is_compressed: false))
          end
          out << header.encode << body
        end
        cm = chunk.meta_data
        cm.codec = F::Codec::UNCOMPRESSED
        cm.encodings = [E::PLAIN, E::RLE, (E::RLE_DICTIONARY if dictionary)].compact
        cm.encoding_stats = nil
        cm.data_page_offset = data_offset
        cm.dictionary_page_offset = dict_offset
        cm.total_compressed_size = cm.total_uncompressed_size = out.bytesize - start
        chunk.file_offset = start
        chunk.offset_index_offset = chunk.offset_index_length = nil
        chunk.column_index_offset = chunk.column_index_length = nil
      end
      rg.file_offset = rg_start
      rg.total_compressed_size = out.bytesize - rg_start
    end
    footer = meta.encode
    out << footer << [footer.bytesize].pack("V") << "PAR1"
  end

  def assert_rows(schema, expected, actual, msg = nil)
    exp = canonical_lines(schema, expected)
    act = canonical_lines(schema, actual)
    assert_equal exp.size, act.size, "row count #{msg}"
    exp.each_with_index { |e, i| assert_equal e, act[i], "row #{i} #{msg}" }
  end

  def count_data_pages(bytes, rg, col)
    reader = reader_for(bytes)
    column = reader.schema.columns[col]
    cr = Herringbone::Reader::ColumnChunkReader.new(StringIO.new(bytes), reader.row_groups[rg].columns[col], column)
    n = 0
    n += 1 while cr.next_page
    n
  end

  [1, 2].each do |version|
    [false, true].each do |dict|
      define_method("test_rows_spanning_pages_v#{version}#{"_dict" if dict}") do
        [[NESTED_SCHEMA, NESTED_ROWS], [ALL_TYPES_SCHEMA, ALL_ROWS]].each do |schema, rows|
          original = write_to_string(schema, rows, row_group_rows: 25, compression: :none)
          [1, 3, 7].each do |per_page|
            bytes = resplit(original, per_page: per_page, version: version, dictionary: dict)
            label = "#{schema.fields.size} fields, #{per_page} entries per page"
            reader = reader_for(bytes)
            assert_operator count_data_pages(bytes, 0, 1), :>, 3, label
            [1, 7, 1024, 10**9].each do |size|
              batches = reader.each_batch(size).to_a
              assert_rows(schema, rows, batches.flatten(1), "#{label}, batch size #{size}")
              assert batches[0..-2].all? { |b| b.size == size }, "only the last batch may be short"
              assert_operator batches.last.size, :<=, size
            end
            assert_rows(schema, rows, reader.each_row.to_a, label)
            # The column-order path agrees with the row one
            data = reader.read(as: :columns)
            full = data.values.first.each_index.map { |i| data.transform_values { |v| v[i] } }
            assert_rows(schema, rows, full, "read(as: :columns), #{label}")
          end
        end
      end
    end
  end

  def test_nested_rows_longer_than_many_pages
    schema = Herringbone::Schema.define do
      int32 :id, null: false
      list :l, :int64
      map :m, :string, :struct do
        list :xs, :int32
      end
    end
    rows = [
      {"id" => 0, "l" => (1..50).to_a, "m" => {"a" => {"xs" => (1..20).to_a}, "b" => nil}},
      {"id" => 1, "l" => nil, "m" => {}},
      {"id" => 2, "l" => [], "m" => nil},
      {"id" => 3, "l" => [nil] * 30, "m" => {"c" => {"xs" => []}}},
      {"id" => 4, "l" => [7], "m" => {"d" => {"xs" => nil}}}
    ]
    [1, 2].each do |version|
      bytes = resplit(write_to_string(schema, rows), per_page: 4, version: version)
      [1, 2, 3, 100].each do |size|
        assert_rows(schema, rows, reader_for(bytes).each_batch(size).flat_map(&:itself), "v#{version} batch #{size}")
      end
      assert_equal [[0, 1], [2, 3], [4]], reader_for(bytes).each_batch(2, columns: ["id"]).map { |b| b.map { |r| r["id"] } }
    end
  end

  def test_many_small_pages_from_the_writer
    [1, 2].each do |version|
      [NESTED_SCHEMA, ALL_TYPES_SCHEMA].zip([NESTED_ROWS, ALL_ROWS]).each do |schema, rows|
        bytes = write_to_string(schema, rows, page_bytes: 40, data_page_version: version, row_group_rows: 30)
        [1, 7, 500].each do |size|
          assert_rows(schema, rows, reader_for(bytes).each_batch(size).to_a.flatten(1), "v#{version} batch #{size}")
        end
      end
    end
  end

  def test_projection
    bytes = resplit(write_to_string(NESTED_SCHEMA, NESTED_ROWS, row_group_rows: 30), per_page: 5)
    reader = reader_for(bytes)
    cols = %w[m_struct id lsl]
    rows = reader.each_batch(7, columns: cols).to_a.flatten(1)
    assert_equal cols, rows.first.keys
    expected = NESTED_ROWS.map { |r| r.slice(*cols) }
    assert_equal canonical_lines(NESTED_SCHEMA, expected.map { |r| NESTED_SCHEMA.fields.to_h { |f| [f.name, r[f.name]] } }),
      canonical_lines(NESTED_SCHEMA, rows.map { |r| NESTED_SCHEMA.fields.to_h { |f| [f.name, r[f.name]] } })
    assert_equal [{}] * NESTED_ROWS.size, reader.read(columns: [])
    assert_raises(ArgumentError) { reader.each_batch(10, columns: ["nope"]) { nil } }
  end

  def test_each_batch_spans_row_groups
    schema = Herringbone::Schema.define { int64 :id, null: false }
    rows = Array.new(95) { |i| {"id" => i} }
    reader = reader_for(write_to_string(schema, rows, row_group_rows: 10))
    assert_equal 10, reader.row_groups.size
    sizes = reader.each_batch(30).map(&:size)
    assert_equal [30, 30, 30, 5], sizes
    assert_equal (0...95).to_a, reader.each_batch(7).flat_map { |b| b.map { |r| r["id"] } }
    assert_equal [95], reader.each_batch(10**9).map(&:size)
    assert_raises(ArgumentError) { reader.each_batch(0) { nil } }
    assert_kind_of Enumerator, reader.each_batch
    assert_equal 95, reader.each_row.count
  end

  def test_empty_file
    schema = Herringbone::Schema.define { int64 :id }
    reader = reader_for(write_to_string(schema, []))
    assert_equal [], reader.each_batch.to_a
    assert_equal [], reader.read
  end

  def test_symbol_keys
    schema = Herringbone::Schema.define do
      int64 :id
      struct :s do
        string :a
        struct :inner do
          int32 :b
        end
      end
      map :m, :string, :struct do
        int32 :x
      end
      map :plain, :string, :int32
      list :ls, :struct do
        string :name
      end
    end
    row = {"id" => 1, "s" => {"a" => "A", "inner" => {"b" => 2}}, "m" => {"k" => {"x" => 3}},
           "plain" => {"p" => 4}, "ls" => [{"name" => "n"}, nil]}
    expected = {id: 1, s: {a: "A", inner: {b: 2}}, m: {"k" => {x: 3}}, plain: {"p" => 4}, ls: [{name: "n"}, nil]}
    bytes = write_to_string(schema, [row])
    assert_equal [row], reader_for(bytes).read
    reader = Herringbone::Reader.new(StringIO.new(bytes), keys: :symbol)
    assert_equal [expected], reader.read
    assert_equal [expected], reader.each_row.to_a
    assert_equal [[expected]], reader.each_batch.to_a
    assert_equal [{s: expected[:s]}], reader.each_row(columns: ["s"]).to_a
    assert_equal({id: [1], plain: [{"p" => 4}]}, reader.read(as: :columns, columns: %w[id plain]))
    assert_equal [row], Herringbone::Reader.new(StringIO.new(bytes), keys: "string").read
    assert_raises(ArgumentError) { Herringbone::Reader.new(StringIO.new(bytes), keys: :nope) }
  end

  def test_reader_needs_an_io_and_leaves_it_open
    bytes = write_to_string(Herringbone::Schema.define { int64 :id }, [{id: 1}])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "io.parquet")
      File.binwrite(path, bytes)
      [path, Pathname.new(path)].each do |arg|
        error = assert_raises(ArgumentError) { Herringbone::Reader.new(arg) }
        assert_match(/expects an IO that supports #seek and #read/, error.message)
      end
      assert_match(/StringIO/, assert_raises(ArgumentError) { Herringbone::Reader.new(bytes) }.message)
      File.open(path, "rb") do |f|
        assert_equal [{"id" => 1}], Herringbone::Reader.new(f).read
        refute f.closed?, "the IO belongs to the caller"
      end
    end
  end

  TS_SCHEMA = Herringbone::Schema.define do
    timestamp :ts
    timestamp :ts_ms, unit: :millis
    timestamp :ts_ns, unit: :nanos
    timestamp :local, utc: false
    int96 :i96
    list :tl, :timestamp
    date :d
  end
  T0 = Time.utc(2024, 3, 31, 0, 30, 0, 123_456)

  def ts_bytes
    write_to_string(TS_SCHEMA, [
      {ts: T0, ts_ms: T0, ts_ns: T0, local: Time.utc(2024, 1, 1, 12), i96: T0, tl: [T0, nil], d: Date.new(2024, 3, 31)},
      {ts: nil, tl: nil}
    ])
  end

  def test_time_zone_offsets
    bytes = ts_bytes
    row = reader_for(bytes).read.first
    assert row["ts"].utc?
    ["+02:00", 7200, "+0200"].each do |zone|
      rows = Herringbone::Reader.new(StringIO.new(bytes), time_zone: zone).read
      r = rows.first
      %w[ts ts_ms ts_ns i96].each do |k|
        assert_equal 7200, r[k].utc_offset, "#{k} with #{zone.inspect}"
        assert_equal row[k], r[k], k # same instant
        assert_equal row[k].nsec, r[k].nsec
      end
      assert_equal [7200, nil], r["tl"].map { |t| t&.utc_offset }
      assert_equal 2, r["ts"].hour
      # Local (not UTC-adjusted) timestamps are wall-clock values and stay as they are
      assert r["local"].utc?
      assert_equal Time.utc(2024, 1, 1, 12), r["local"]
      assert_equal Date.new(2024, 3, 31), r["d"]
      assert_nil rows[1]["ts"]
    end
    zoned = ->(zone) { Herringbone::Reader.new(StringIO.new(bytes), time_zone: zone) }
    assert zoned.call("UTC").read.first["ts"].utc?
    assert_equal(-18_000, zoned.call("-05:00").read.first["ts"].utc_offset)
    assert_equal(-18_000, zoned.call(-18_000).each_row.first["ts_ms"].utc_offset)
    assert_equal 3600, zoned.call(3600).read(as: :columns, columns: ["ts"])["ts"].first.utc_offset
    assert_raises(ArgumentError) { Herringbone::Reader.new(StringIO.new(bytes), time_zone: "+25:00") }
    assert_raises(ArgumentError) { Herringbone::Reader.new(StringIO.new(bytes), time_zone: Object.new) }
  end

  # Anything responding to #at, like ActiveSupport::TimeZone
  class FakeZone
    def at(time) = [:in_zone, time]
  end

  def test_time_zone_object_responding_to_at
    r = Herringbone::Reader.new(StringIO.new(ts_bytes), time_zone: FakeZone.new).read.first
    assert_equal [:in_zone, T0], r["ts"]
    assert_equal [:in_zone, T0], r["i96"]
    assert_equal Time.utc(2024, 1, 1, 12), r["local"]
  end

  def test_time_zone_tzinfo_and_active_support
    begin
      require "tzinfo"
    rescue LoadError
      skip "tzinfo is not installed"
    end
    tz = TZInfo::Timezone.get("Europe/Amsterdam")
    r = Herringbone::Reader.new(StringIO.new(ts_bytes), time_zone: tz).read.first
    assert_equal 3600, r["ts"].utc_offset # 00:30 UTC on the day CEST starts (01:00 UTC) is still CET
    assert_equal T0, r["ts"]
    assert_equal 7200, Herringbone::Reader.new(StringIO.new(ts_bytes), time_zone: tz).read.first["ts"].then { |t| (t + 3600).getlocal(tz).utc_offset }
  end

  def test_time_zone_active_support
    begin
      require "active_support"
      require "active_support/time"
    rescue LoadError
      skip "activesupport is not installed"
    end
    zone = ActiveSupport::TimeZone["Europe/Amsterdam"]
    r = Herringbone::Reader.new(StringIO.new(ts_bytes), time_zone: zone).read.first
    assert_kind_of ActiveSupport::TimeWithZone, r["ts"]
    assert_equal T0, r["ts"]
    assert_equal 123_456_000, r["ts_ns"].nsec
    assert_equal "Europe/Amsterdam", r["ts"].time_zone.name
    # Zone names are looked up through ActiveSupport when it is loaded
    r = Herringbone::Reader.new(StringIO.new(ts_bytes), time_zone: "Europe/Amsterdam").read.first
    assert_equal T0, r["ts"]
    assert_equal 3600, r["ts"].utc_offset
  end

  def test_int96_fixture_with_time_zone
    path = File.join(FIXTURES_DIR, "parquet-testing", "int96_from_spark.parquet")
    skip "fixture missing" unless File.exist?(path)
    utc, zoned = File.open(path, "rb") do |f|
      [Herringbone::Reader.new(f).read, Herringbone::Reader.new(f, time_zone: "+05:30").read]
        .map { |rows| rows.map(&:values).flatten.compact }
    end
    assert_equal utc, zoned
    assert zoned.all? { |t| t.utc_offset == 19_800 }
  end

  def test_page_reads_are_lazy
    schema = Herringbone::Schema.define {
      int64 :id, null: false
      string :s
    }
    rows = Array.new(5000) { |i| {"id" => i, "s" => "row #{i}"} }
    bytes = write_to_string(schema, rows, page_bytes: 1024, compression: :none)
    io = CountingIO.new(bytes)
    reader = Herringbone::Reader.new(io)
    io.bytes_read = 0
    first = reader.each_batch(10).first
    assert_equal({"id" => 0, "s" => "row 0"}, first.first)
    assert_operator io.bytes_read, :<, bytes.bytesize / 4, "reading the first batch should not read whole chunks"
  end

  class CountingIO < StringIO
    attr_accessor :bytes_read

    def read(*args)
      s = super
      @bytes_read = (@bytes_read || 0) + s.bytesize if s
      s
    end
  end

  def test_under_reported_chunk_sizes_are_tolerated
    schema = Herringbone::Schema.define {
      int64 :id, null: false
      list :l, :string
    }
    rows = Array.new(300) { |i| {"id" => i, "l" => [i.to_s] * (i % 4)} }
    bytes = write_to_string(schema, rows, page_bytes: 256)
    reader = reader_for(bytes)
    reader.row_groups.each do |rg|
      rg.columns.each do |c|
        c.meta_data.total_compressed_size = 10
        c.meta_data.dictionary_page_offset = 0 if c.meta_data.dictionary_page_offset.nil?
      end
    end
    footer = reader.file_metadata.encode
    body = bytes.byteslice(0, bytes.bytesize - 8 - bytes.byteslice(-8, 4).unpack1("V"))
    patched = body + footer + [footer.bytesize].pack("V") + "PAR1"
    assert_rows(schema, rows, reader_for(patched).each_batch(13).to_a.flatten(1))
  end

  def test_truncated_file_raises_format_error
    schema = Herringbone::Schema.define { int64 :id, null: false }
    bytes = write_to_string(schema, Array.new(1000) { |i| {"id" => i} }, page_bytes: 512, compression: :none)
    reader = reader_for(bytes)
    reader.row_groups[0].num_rows = 2000
    reader.row_groups[0].columns[0].meta_data.num_values = 2000
    assert_raises(Herringbone::FormatError) { reader.each_batch(100) { nil } }
  end
end
