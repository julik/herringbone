# frozen_string_literal: true

require_relative "test_helper"

# Writing without a declared schema: Herringbone.write inferring from the rows it is given, also
# from Array rows named by headers: (CSV-style)
class InferringWriteTest < Minitest::Test
  def read(io) = Herringbone::Reader.new(StringIO.new(io.string)).read

  # An Enumerator over a queue yields every row only once, like a database cursor or a socket
  def one_shot(rows)
    queue = rows.dup
    Enumerator.new { |y| while (row = queue.shift) do y << row end }
  end

  def test_write_reads_a_one_shot_source_once
    rows = (1..2500).map { |i| {id: i, name: "n#{i}"} } # more than the inference sample
    io = StringIO.new("".b)
    assert_equal 2500, Herringbone.write(io, one_shot(rows))
    assert_equal rows.map { |r| r.transform_keys(&:to_s) }, read(io)
  end

  def test_write_reads_a_short_one_shot_source_once
    io = StringIO.new("".b)
    assert_equal 5, Herringbone.write(io, one_shot((1..5).map { |i| {id: i} }))
    assert_equal (1..5).map { |i| {"id" => i} }, read(io)
  end

  def test_write_produces_each_lazy_row_once
    produced = 0
    rows = (1..Float::INFINITY).lazy.map { |i| (produced += 1) && {id: i} }.take(1500)
    Herringbone.write(StringIO.new("".b), rows)
    assert_equal 1500, produced
  end

  def test_write_takes_schema_overrides_in_a_block
    io = StringIO.new("".b)
    Herringbone.write(io, one_shot([{id: 1, payload: {"a" => [1]}}])) { |s| s.json :payload }
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal :json, Herringbone::Types.logical_of(reader.schema.column("payload").node).first
    assert_equal [{"id" => 1, "payload" => '{"a":[1]}'}], reader.read
  end

  def test_write_with_nothing_to_infer_from_writes_nothing
    io = StringIO.new("".b)
    assert_raises(ArgumentError) { Herringbone.write(io, []) }
    assert_raises(ArgumentError) { Herringbone.write(io, [[1, 2]]) }
    assert_empty io.string
  end

  def test_missing_codec_fails_before_reading_rows
    skip "zstd-ruby is installed" if Herringbone.codecs.include?(:zstd)
    rows = one_shot([{id: 1}])
    assert_raises(Herringbone::MissingCodecError) { Herringbone.write(StringIO.new("".b), rows, compression: :zstd) }
    assert_equal({id: 1}, rows.next)
  end

  def test_a_row_that_does_not_fit_raises_schema_mismatch_and_stops
    io = StringIO.new("".b)
    fix = "Herringbone.write(io, rows, headers: [...]) { |s| s.%s }"
    sw = Herringbone::InferringWriter.new(io, fix: fix, headers: [:id, :age]) { |sample| Herringbone::Schema.infer(sample) }
    1000.times { |i| sw << [i, i % 90] }
    error = assert_raises(Herringbone::SchemaMismatch) { sw << [1000, "twelve"] }
    assert_kind_of Herringbone::EncodeError, error
    assert_equal [1000, "age", "twelve"], [error.row, error.column, error.value]
    assert_equal <<~MESSAGE.chomp, error.message
      Row 1000 does not fit the schema inferred from the first 1000 rows.
        column:   age
        inferred: int64
        got:      "twelve" (String)
        error:    Cannot write "twelve" to age: invalid value for Integer(): "twelve"

      Column types are decided from the first 1000 rows (or all of them, when there are
      fewer), so a later value of a different type cannot be written to the same column.
      Declare the column with a type that holds every value, for example:
        Herringbone.write(io, rows, headers: [...]) { |s| s.string :age }
      or pass a complete schema. The file was left unfinished (no footer).
    MESSAGE
    later = assert_raises(Herringbone::Error) { sw << [1001, 3] }
    assert_match(/stopped at a schema mismatch/, later.message)
    assert_raises(Herringbone::Error) { sw.close }
    assert_equal "PAR1", io.string, "rows still buffered, no footer"
  end

  def test_a_mismatch_within_the_sample_stops_at_close
    io = StringIO.new("".b)
    # inferred as int64, which 2**70 does not fit
    error = assert_raises(Herringbone::SchemaMismatch) { Herringbone.write(io, [[1], [2], [2**70], [4]], headers: [:n]) }
    assert_equal 2, error.row
    assert_match(/inferred from the first 4 rows/, error.message)
  end

  def test_write_raises_schema_mismatch_with_its_own_fix
    rows = one_shot((1..1000).map { |i| {amount: i} } + [{amount: {"a" => 1}}])
    error = assert_raises(Herringbone::SchemaMismatch) { Herringbone.write(StringIO.new("".b), rows) }
    assert_includes error.message, "Herringbone.write(io, rows) { |s| s.json :amount }"
  end

  def test_inspect_shows_held_back_rows_then_the_writer
    writer = Herringbone::InferringWriter.new(StringIO.new("".b), fix: "%s") { |sample| Herringbone::Schema.infer(sample) }
    500.times { |i| writer << {"id" => i, "name" => "name #{i}"} }
    assert_equal "#<Herringbone::InferringWriter held_back=500>", writer.inspect
    500.upto(49_999) { |i| writer << {"id" => i, "name" => "name #{i}"} }
    assert_operator writer.inspect.bytesize, :<, 200
    assert_match(/\A#<Herringbone::InferringWriter writer=#<Herringbone::Writer open rows_written=50000 /, writer.inspect)
  end

  def test_write_with_headers_like_csv
    io = StringIO.new("".b)
    rows = Enumerator.new do |y|
      y << [123, "John", 12]
      y << {:id => 124, "name" => "Jane"}
      y << [125, nil, 40]
    end
    assert_equal 3, Herringbone.write(io, rows, headers: [:id, :name, :age], compression: :gzip)
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal %w[id name age], reader.schema.fields.map(&:name)
    assert_equal [
      {"id" => 123, "name" => "John", "age" => 12},
      {"id" => 124, "name" => "Jane", "age" => nil},
      {"id" => 125, "name" => nil, "age" => 40}
    ], reader.read
  end

  def test_write_with_headers_streams_past_the_sample
    io = StringIO.new("".b)
    Herringbone.write(io, one_shot(3000.times.map { |i| [i, i / 2.0] }), headers: %w[i half], row_group_rows: 1000)
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 3, reader.row_groups.size
    assert_equal 2999, reader.read.last["i"]
  end

  def test_write_with_headers_takes_schema_overrides_in_a_block
    io = StringIO.new("".b)
    Herringbone.write(io, [[1, 7], [2, "B12"]], headers: [:id, :code]) { |s| s.string :code }
    assert_equal %w[7 B12], read(io).map { |r| r["code"] }
    error = assert_raises(ArgumentError) { Herringbone.write(StringIO.new("".b), [[1]], headers: [:id]) { |s| s.string :other } }
    assert_match(/Declared columns not among the headers \(id\): other/, error.message)
  end

  def test_write_with_headers_and_no_rows_writes_string_columns
    io = StringIO.new("".b)
    assert_equal 0, Herringbone.write(io, [], headers: [:a, :b])
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 0, reader.num_rows
    assert_equal %w[a b], reader.schema.fields.map(&:name)
    assert_equal [Herringbone::Format::Type::BYTE_ARRAY] * 2, reader.schema.columns.map(&:type)
  end

  def test_write_checks_headers_and_rows
    io = StringIO.new("".b)
    assert_raises(ArgumentError) { Herringbone.write(io, [[1]], headers: []) }
    assert_match(/more than once: a/, assert_raises(ArgumentError) { Herringbone.write(io, [[1, 2]], headers: [:a, "a"]) }.message)
    assert_raises(ArgumentError) { Herringbone.write(io, [[1]], headers: [:a, :b]) }
    assert_raises(ArgumentError) { Herringbone.write(io, ["1,2"], headers: [:a, :b]) }
    assert_raises(ArgumentError) { Herringbone.write(io, [{a: 1, c: 2}], headers: [:a, :b]) }
    error = assert_raises(ArgumentError) { Herringbone.write(io, [[1]]) }
    assert_match(/pass headers:/, error.message)
  end

  def test_write_refuses_headers_with_a_schema
    schema = Herringbone::Schema.define { |s| s.int64 :a }
    error = assert_raises(ArgumentError) { Herringbone.write(StringIO.new("".b), [[1]], schema: schema, headers: [:a]) }
    assert_match(/schema: already names the columns/, error.message)
  end

  def test_write_with_headers_leaves_no_footer_when_the_rows_fail
    io = StringIO.new("".b)
    rows = Enumerator.new do |y|
      1500.times { |i| y << [i] }
      raise "boom"
    end
    assert_raises(RuntimeError) { Herringbone.write(io, rows, headers: [:a], row_group_rows: 500) }
    assert io.string.start_with?("PAR1")
    refute io.string.end_with?("PAR1")
  end
end
