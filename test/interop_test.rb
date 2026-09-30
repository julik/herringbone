# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

# Cross-validation with pyarrow: files written by herringbone are read by pyarrow (with page CRC
# verification and statistics checks) and by herringbone, and both results are compared with the
# data that was written. Set HERRINGBONE_PYTHON to a Python interpreter that has pyarrow installed.
# HERRINGBONE_FUZZ_SEED and HERRINGBONE_FUZZ_ITERATIONS control the randomized part.
class InteropTest < Minitest::Test
  include WriterHelpers
  extend WriterHelpers

  PYTHON = ENV["HERRINGBONE_PYTHON"]
  DUMP_SCRIPT = File.expand_path("support/pyarrow_dump.py", __dir__)
  FUZZ_SEED = Integer(ENV.fetch("HERRINGBONE_FUZZ_SEED", "20240930"))
  FUZZ_ITERATIONS = Integer(ENV.fetch("HERRINGBONE_FUZZ_ITERATIONS", "50"))

  Case = Struct.new(:name, :schema, :rows, :options, :path, keyword_init: true)

  class << self
    def pyarrow_status
      return @pyarrow_status if defined?(@pyarrow_status)
      @pyarrow_status = if PYTHON.nil? || PYTHON.empty?
        "HERRINGBONE_PYTHON is not set"
      else
        out, status = Open3.capture2e(PYTHON, DUMP_SCRIPT, "--check")
        status.success? ? nil : "#{PYTHON} cannot import pyarrow: #{out.lines.last}"
      end
    rescue SystemCallError => e
      @pyarrow_status = "#{PYTHON}: #{e.message}"
    end

    def cases
      @cases ||= build_cases
    end

    # Writes every case to disk and reads all of them with a single pyarrow process
    def results
      @results ||= begin
        dir = Dir.mktmpdir("herringbone-interop")
        Minitest.after_run { FileUtils.rm_rf(dir) }
        cases.each_value do |c|
          c.path = File.join(dir, "#{c.name}.parquet")
          begin
            Herringbone::Writer.open(c.path, c.schema, **c.options) { |w| w.write_rows(c.rows) }
          rescue StandardError => e
            c.path = nil
            c.options = c.options.merge(write_error: "#{e.class}: #{e.message}")
          end
        end
        paths = cases.values.map(&:path).compact
        out, err, status = Open3.capture3(PYTHON, DUMP_SCRIPT, *paths)
        raise "pyarrow_dump.py failed: #{err}" unless status.success?
        JSON.parse(out)
      end
    end

    def build_cases
      list = []
      all_rows = WriterHelpers.all_types_rows(30, seed: 11)
      nested_rows = WriterHelpers.nested_rows(30, seed: 12)
      WriterHelpers::CODECS.each do |codec|
        next unless WriterHelpers.codec_available?(codec)
        [1, 2].each do |v|
          [true, false].each do |dict|
            opts = { compression: codec, data_page_version: v, dictionary: dict }
            list << Case.new(name: "all_#{codec}_v#{v}_#{dict}", schema: ALL_TYPES_SCHEMA, rows: all_rows, options: opts)
            list << Case.new(name: "nested_#{codec}_v#{v}_#{dict}", schema: NESTED_SCHEMA, rows: nested_rows, options: opts)
          end
        end
      end
      enc_schema = WriterTestSchemas::ENCODING_SCHEMA
      enc_rows = WriterTestSchemas.encoding_rows(200)
      [1, 2].each do |v|
        [nil, 50].each do |ps|
          opts = { data_page_version: v, encodings: WriterTestSchemas::ENCODINGS, compression: Herringbone::Compression.available?(:zstd) ? :zstd : :gzip }
          opts[:page_size] = ps if ps
          list << Case.new(name: "encodings_v#{v}_#{ps || "default"}", schema: enc_schema, rows: enc_rows, options: opts)
        end
      end
      [1, 2].each do |v|
        list << Case.new(name: "pages_all_v#{v}", schema: ALL_TYPES_SCHEMA, rows: all_rows,
          options: { page_size: 30, row_group_size: 11, data_page_version: v })
        list << Case.new(name: "pages_nested_v#{v}", schema: NESTED_SCHEMA, rows: nested_rows,
          options: { page_size: 30, row_group_size: 11, data_page_version: v, compression: :gzip })
      end
      list << Case.new(name: "zero_rows_all", schema: ALL_TYPES_SCHEMA, rows: [], options: {})
      list << Case.new(name: "zero_rows_nested", schema: NESTED_SCHEMA, rows: [], options: { data_page_version: 2 })
      nulls = all_rows.first(10).map { |r| r.to_h { |k, v| [k, ALL_TYPES_SCHEMA.field(k).optional ? nil : v] } }
      list << Case.new(name: "all_nulls_v1", schema: ALL_TYPES_SCHEMA, rows: nulls, options: {})
      list << Case.new(name: "all_nulls_v2", schema: ALL_TYPES_SCHEMA, rows: nulls, options: { data_page_version: 2, dictionary: false })
      list << Case.new(name: "kv_metadata", schema: NESTED_SCHEMA, rows: nested_rows.first(3),
        options: { metadata: { "hello" => "world", "unicode" => "漢字" } })

      fuzz = Fuzz.new(FUZZ_SEED)
      FUZZ_ITERATIONS.times do |i|
        schema, rows, opts = fuzz.case
        list << Case.new(name: format("fuzz_%03d", i), schema: schema, rows: rows, options: opts)
      end
      list.to_h { |c| [c.name, c] }
    end
  end

  def setup
    status = self.class.pyarrow_status
    return unless status
    # CI sets HERRINGBONE_REQUIRE_INTEROP so a broken Python setup fails instead of skipping
    flunk status if ENV["HERRINGBONE_REQUIRE_INTEROP"]
    skip status
  end

  # -- per-case tests --

  def self.define_case_test(name)
    define_method("test_#{name}") { check_case(self.class.cases.fetch(name)) }
  end

  # Case names are known without building data, so tests exist even when pyarrow is unavailable
  WriterHelpers::CODECS.each do |codec|
    [1, 2].each do |v|
      [true, false].each do |dict|
        define_case_test("all_#{codec}_v#{v}_#{dict}")
        define_case_test("nested_#{codec}_v#{v}_#{dict}")
      end
    end
  end
  %w[encodings_v1_default encodings_v1_50 encodings_v2_default encodings_v2_50 pages_all_v1 pages_all_v2
     pages_nested_v1 pages_nested_v2 zero_rows_all zero_rows_nested all_nulls_v1 all_nulls_v2 kv_metadata].each do |n|
    define_case_test(n)
  end

  def test_kv_metadata_visible_to_pyarrow
    r = result_for(self.class.cases.fetch("kv_metadata"))
    assert_equal "world", r["key_value_metadata"]["hello"]
    assert_equal "漢字", r["key_value_metadata"]["unicode"]
  end

  def test_explicit_encodings_reported_by_pyarrow
    %w[encodings_v1_default encodings_v2_50].each do |name|
      r = result_for(self.class.cases.fetch(name))
      r["columns"].each do |rg|
        rg.each do |col|
          want = WriterTestSchemas::ENCODINGS.fetch(col["path"]).to_s.upcase
          assert_includes col["encodings"], want, "#{name} #{col["path"]}"
        end
      end
    end
  end

  def test_fuzz
    failures = []
    FUZZ_ITERATIONS.times do |i|
      c = self.class.cases.fetch(format("fuzz_%03d", i))
      begin
        check_case(c)
      rescue Minitest::Assertion, StandardError => e
        failures << "#{c.name} (seed #{FUZZ_SEED}, options #{c.options.inspect})\n#{c.schema.inspect}\n  #{e.class}: #{e.message[0, 1500]}"
      end
    end
    assert failures.empty?, "#{failures.size}/#{FUZZ_ITERATIONS} fuzz cases failed:\n\n#{failures.join("\n\n")}"
  end

  private

  def result_for(c)
    results = self.class.results
    flunk "herringbone failed to write #{c.name}: #{c.options[:write_error]}" unless c.path
    results.fetch(c.path)
  end

  def check_case(c)
    r = result_for(c)
    assert_nil r["error"], "pyarrow failed to read #{c.name}"
    assert_nil r["checksum"], "page checksum verification failed for #{c.name}"
    assert_equal c.rows.size, r["num_rows"]

    expected = canonical_lines(c.schema, c.rows)
    expected_pyarrow = c.rows.map do |row|
      Canonical.dump(c.schema.fields.to_h { |f| [f.name, pyarrow_view(f, Canonical.value(f, row.fetch(f.name) { row[f.name.to_sym] }))] })
    end
    from_pyarrow = r["rows"].map { |row| Canonical.dump(row) }
    reader = Herringbone::Reader.open(c.path)
    from_herringbone = canonical_lines(reader.schema, reader.rows)

    expected.each_with_index do |e, i|
      assert_equal expected_pyarrow[i], from_pyarrow[i], "#{c.name}: pyarrow row #{i}"
      assert_equal e, from_herringbone[i], "#{c.name}: herringbone row #{i}"
    end
    assert_equal expected.size, from_pyarrow.size
    assert_equal expected.size, from_herringbone.size

    assert_equal [], r["stats_errors"], "#{c.name}: statistics disagree with data"
    check_null_counts(c, reader, r)
    check_codecs(c, r)
  ensure
    reader&.close
  end

  # pyarrow reads ENUM columns (without an ARROW:schema) as binary
  def pyarrow_view(field, cv)
    return nil if cv.nil?
    case field.kind
    when :struct then field.children.to_h { |ch| [ch.name, pyarrow_view(ch, cv[ch.name])] }
    when :list then cv.map { |e| pyarrow_view(field.element, e) }
    when :map then cv.map { |k, v| [pyarrow_view(field.key, k), field.value ? pyarrow_view(field.value, v) : nil] }
    else
      Herringbone::Types.logical_of(field.node).first == :enum ? { "base64" => [cv].pack("m0") } : cv
    end
  end

  def check_null_counts(c, reader, r)
    reader.row_groups.each_index do |g|
      reader.schema.columns.each do |col|
        info = r["columns"][g][col.index]
        defs, = reader.read_column_chunk(g, col)
        nulls = defs ? defs.count { |d| d < col.max_definition_level } : 0
        assert_equal nulls, info["null_count"], "#{c.name}: null_count of #{col.dotted_path} in row group #{g}"
        assert_equal (defs || reader.read_column_chunk(g, col)[2]).size, info["num_values"], "#{c.name}: num_values"
      end
    end
  end

  PYARROW_CODECS = { none: "UNCOMPRESSED", snappy: "SNAPPY", gzip: "GZIP", lz4: "LZ4", lz4_hadoop: "UNKNOWN", # pyarrow has no name for the deprecated Hadoop LZ4 codec
                     
                     zstd: "ZSTD", brotli: "BROTLI" }.freeze

  def check_codecs(c, r)
    want = PYARROW_CODECS.fetch(c.options.fetch(:compression, :snappy))
    r["columns"].flatten.each { |col| assert_equal want, col["codec"], "#{c.name}: codec" }
  end

  # Random nested schemas and data
  class Fuzz
    LEAVES = {
      "bool" => [:boolean], "i8" => [:int8], "i16" => [:int16], "i32" => [:int32], "i64" => [:int64],
      "u8" => [:uint8], "u16" => [:uint16], "u32" => [:uint32], "u64" => [:uint64], "f32" => [:float],
      "f64" => [:double], "f16" => [:float16], "str" => [:string], "bin" => [:binary], "js" => [:json],
      "en" => [:enum], "uid" => [:uuid], "date" => [:date], "t_ms" => [:time, { unit: :millis }],
      "t_us" => [:time, { unit: :micros }], "t_ns" => [:time, { unit: :nanos }],
      "ts_ms" => [:timestamp, { unit: :millis }], "ts_us" => [:timestamp, { unit: :micros }],
      "ts_ns" => [:timestamp, { unit: :nanos }], "ts_local" => [:timestamp, { unit: :micros, utc: false }],
      "i96" => [:int96], "dec_small" => [:decimal, { precision: 9, scale: 2 }],
      "dec_med" => [:decimal, { precision: 18, scale: 4 }], "dec_large" => [:decimal, { precision: 38, scale: 10 }],
      "dec_bin" => [:decimal, { precision: 25, scale: 3, physical: :binary }], "fx" => [:fixed, { length: 5 }]
    }.freeze
    MAP_KEYS = %w[str i32 i64 date].freeze

    def initialize(seed)
      @rng = Random.new(seed)
      @specials = WriterHelpers.specials
    end

    def case
      @n = 0
      specs = Array.new(@rng.rand(1..5)) { spec(1) }
      specs.unshift({ kind: :leaf, name: "row_id", type: "i64", null: false })
      decl = method(:declare)
      schema = Herringbone::Schema.define { specs.each { |s| decl.call(self, s) } }
      rows = Array.new(@rng.rand(0..25)) { |i| specs.to_h { |s| [s[:name], s[:name] == "row_id" ? i : value(s)] } }
      codecs = WriterHelpers::CODECS.select { |c| WriterHelpers.codec_available?(c) }
      opts = {
        compression: codecs.sample(random: @rng), data_page_version: [1, 2].sample(random: @rng),
        dictionary: [true, false].sample(random: @rng)
      }
      opts[:page_size] = [16, 100].sample(random: @rng) if @rng.rand(2).zero?
      opts[:row_group_size] = @rng.rand(1..10) if @rng.rand(3).zero?
      encodings = {}
      schema.columns.each do |col|
        next unless @rng.rand(3).zero?
        valid = Herringbone::Writer::VALID_ENCODINGS.select { |_, types| types.include?(col.type) }.keys
        enc = Herringbone::Writer::ENCODING_NAMES.key(valid.sample(random: @rng))
        encodings[col.dotted_path] = enc
      end
      opts[:encodings] = encodings unless encodings.empty?
      [schema, rows, opts]
    end

    private

    def name = "f#{@n += 1}"

    def spec(depth, leaf_types: LEAVES.keys)
      null = @rng.rand(10) < 7
      kind = depth >= 4 || @rng.rand(10) < 4 ? :leaf : %i[struct list map].sample(random: @rng)
      case kind
      when :leaf then { kind: :leaf, name: name, type: leaf_types.sample(random: @rng), null: null }
      when :struct then { kind: :struct, name: name, null: null, children: Array.new(@rng.rand(1..3)) { spec(depth + 1) } }
      when :list then { kind: :list, name: name, null: null, element: spec(depth + 1) }
      when :map
        { kind: :map, name: name, null: null, key: MAP_KEYS.sample(random: @rng), value: spec(depth + 1) }
      end
    end

    def declare(b, s, as: nil)
      n = as || s[:name]
      decl = method(:declare)
      case s[:kind]
      when :leaf
        type, opts = LEAVES.fetch(s[:type])
        b.public_send(type, n, null: s[:null], **(opts || {}))
      when :struct
        children = s[:children]
        b.struct(n, null: s[:null]) { children.each { |ch| decl.call(self, ch) } }
      when :list
        el = s[:element]
        case el[:kind]
        when :leaf
          type, opts = LEAVES.fetch(el[:type])
          b.list(n, type, null: s[:null], element_null: el[:null], **(opts || {}))
        when :struct
          b.list(n, :struct, null: s[:null], element_null: el[:null]) { el[:children].each { |ch| decl.call(self, ch) } }
        else
          b.list(n, null: s[:null]) { decl.call(self, el, as: "element") }
        end
      when :map
        key_type, = LEAVES.fetch(s[:key])
        v = s[:value]
        case v[:kind]
        when :leaf
          type, opts = LEAVES.fetch(v[:type])
          b.map(n, key_type, type, null: s[:null], value_null: v[:null], **(opts || {}))
        when :struct
          b.map(n, key_type, :struct, null: s[:null], value_null: v[:null]) { v[:children].each { |ch| decl.call(self, ch) } }
        else
          b.map(n, key_type, null: s[:null]) { decl.call(self, v, as: "value") }
        end
      end
    end

    def value(s)
      return nil if s[:null] && @rng.rand(5).zero?
      case s[:kind]
      when :leaf then leaf(s[:type], s[:null])
      when :struct then s[:children].to_h { |ch| [ch[:name], value(ch)] }
      when :list then Array.new(@rng.rand(0..4)) { value(s[:element]) }
      when :map
        h = {}
        @rng.rand(0..3).times { h[leaf(s[:key], false)] = value(s[:value]) }
        h
      end
    end

    def leaf(type, nullable)
      if @rng.rand(4).zero?
        sp = @specials.fetch(type)
        sp = sp.compact unless nullable
        return sp.sample(random: @rng)
      end
      WriterHelpers::RANDOM.fetch(type).call(@rng)
    end
  end
end
