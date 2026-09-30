# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/canonical"

# Reads every fixture and compares the result with the pyarrow-generated expectations
class ConformanceTest < Minitest::Test
  TYPE_NAMES = Parakiet::Format::Type::NAMES

  # Files whose expected behaviour differs on purpose, with the reason
  SKIPS = {
    "parquet-testing/int96_from_spark.parquet" =>
      "pyarrow overflows int64 nanoseconds for out-of-range INT96 values; covered in reader_test.rb"
  }.freeze

  Dir[File.join(FIXTURES_DIR, "{parquet-testing,generated}", "expected", "*.json")].sort.each do |json_path|
    expected = JSON.parse(File.read(json_path))
    parquet_path = File.join(File.dirname(json_path), "..", File.basename(json_path, ".json"))
    name = "#{File.basename(File.dirname(File.dirname(json_path)))}/#{File.basename(parquet_path)}"

    define_method("test_#{name.gsub(/[^a-z0-9]+/i, "_")}") do
      skip SKIPS[name] if SKIPS[name]
      skip "pyarrow cannot read this file either: #{expected["error"]}" if expected["error"] && !expected["rows"]
      begin
        check_file(parquet_path, expected)
      rescue Parakiet::UnsupportedError => e
        raise unless e.message.include?("gem")
        skip e.message
      end
    end
  end

  private

  def check_file(path, expected)
    Parakiet::Reader.open(path) do |reader|
      assert_equal expected["num_rows"], reader.num_rows, "num_rows"
      assert_equal expected["num_row_groups"], reader.num_row_groups, "num_row_groups"
      expected_schema = expected["schema"].map do |c|
        [c["path"], c["physical_type"], c["max_definition_level"], c["max_repetition_level"]]
      end
      actual_schema = reader.schema.columns.map do |c|
        [c.path, TYPE_NAMES[c.type].to_s, c.max_definition_level, c.max_repetition_level]
      end
      assert_equal expected_schema, actual_schema, "schema"

      next unless expected["rows"]

      schema = reader.schema
      lines = []
      first_rows = []
      reader.each_row do |row|
        canonical = Canonical.row(schema, row)
        first_rows << canonical if first_rows.size < 50
        lines << Canonical.dump(canonical)
      end
      assert_equal expected["rows"], JSON.parse(Canonical.dump(first_rows)), "first rows"
      assert_equal expected["row_hash"], Canonical.row_hash(lines), "row hash of all rows"
    end
  end
end
