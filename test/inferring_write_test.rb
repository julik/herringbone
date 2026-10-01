# frozen_string_literal: true

require_relative "test_helper"

# Writing without a declared schema: Herringbone.write inferring from the rows it is given, and
# SimpleWriter (CSV-style headers and Array rows)
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
    Herringbone.write(io, one_shot([{id: 1, payload: {"a" => [1]}}])) { json :payload }
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
    sw = Herringbone::SimpleWriter.new(io)
    sw.headers!(:id, :age)
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
        Herringbone::SimpleWriter.new(io) { string :age }
      or pass a complete schema. The file was left unfinished (no footer).
    MESSAGE
    later = assert_raises(Herringbone::Error) { sw << [1001, 3] }
    assert_match(/stopped at a schema mismatch/, later.message)
    assert_raises(Herringbone::Error) { sw.close }
    assert_equal "PAR1", io.string, "rows still buffered, no footer"
  end

  def test_a_mismatch_within_the_sample_stops_at_close
    io = StringIO.new("".b)
    sw = Herringbone::SimpleWriter.new(io)
    sw.headers!(:n)
    sw << [1] << [2] << [2**70] << [4] # inferred as int64, which 2**70 does not fit
    error = assert_raises(Herringbone::SchemaMismatch) { sw.close }
    assert_equal 2, error.row
    assert_match(/inferred from the first 4 rows/, error.message)
  end

  def test_write_raises_schema_mismatch_with_its_own_fix
    rows = one_shot((1..1000).map { |i| {amount: i} } + [{amount: {"a" => 1}}])
    error = assert_raises(Herringbone::SchemaMismatch) { Herringbone.write(StringIO.new("".b), rows) }
    assert_includes error.message, "Herringbone.write(io, rows) { json :amount }"
  end

  def test_simple_writer_like_csv
    io = StringIO.new("".b)
    result = Herringbone::SimpleWriter.open(io, compression: :gzip) do |sw|
      sw.headers!(:id, :name, :age)
      sw << [123, "John", 12]
      sw << {:id => 124, "name" => "Jane"}
      sw << [125, nil, 40]
      sw.rows_written
    end
    assert_equal 3, result
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal %w[id name age], reader.schema.fields.map(&:name)
    assert_equal [
      {"id" => 123, "name" => "John", "age" => 12},
      {"id" => 124, "name" => "Jane", "age" => nil},
      {"id" => 125, "name" => nil, "age" => 40}
    ], reader.read
  end

  def test_simple_writer_streams_past_the_sample
    io = StringIO.new("".b)
    Herringbone::SimpleWriter.open(io, row_group_rows: 1000) do |sw|
      sw.headers!(%w[i half])
      3000.times { |i| sw << [i, i / 2.0] }
    end
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 3, reader.row_groups.size
    assert_equal 2999, reader.read.last["i"]
  end

  def test_simple_writer_takes_schema_overrides_in_a_block
    io = StringIO.new("".b)
    sw = Herringbone::SimpleWriter.new(io) { string :code }
    sw.headers!(:id, :code)
    sw << [1, 7] << [2, "B12"]
    sw.close
    assert_equal %w[7 B12], read(io).map { |r| r["code"] }
    sw = Herringbone::SimpleWriter.new(StringIO.new("".b)) { string :other }
    sw.headers!(:id)
    assert_raises(ArgumentError) { sw.close }
  end

  def test_simple_writer_without_rows_writes_string_columns
    io = StringIO.new("".b)
    Herringbone::SimpleWriter.open(io) { |sw| sw.headers!(:a, :b) }
    reader = Herringbone::Reader.new(StringIO.new(io.string))
    assert_equal 0, reader.num_rows
    assert_equal %w[a b], reader.schema.fields.map(&:name)
  end

  def test_simple_writer_needs_headers
    sw = Herringbone::SimpleWriter.new(StringIO.new("".b))
    assert_raises(ArgumentError) { sw << [1] }
    assert_raises(ArgumentError) { sw.close }
    assert_raises(ArgumentError) { sw.headers! }
    assert_raises(ArgumentError) { sw.headers!(:a, "a") }
    sw.headers!(:a, :b)
    assert_raises(ArgumentError) { sw.headers!(:c) }
    assert_raises(ArgumentError) { sw << [1] }
    assert_raises(ArgumentError) { sw << "1,2" }
    assert_raises(ArgumentError) { sw << {a: 1, c: 2} }
  end

  def test_simple_writer_block_failure_leaves_no_footer
    io = StringIO.new("".b)
    assert_raises(RuntimeError) do
      Herringbone::SimpleWriter.open(io, row_group_rows: 500) do |sw|
        sw.headers!(:a)
        1500.times { |i| sw << [i] }
        raise "boom"
      end
    end
    assert io.string.start_with?("PAR1")
    refute io.string.end_with?("PAR1")
  end
end
