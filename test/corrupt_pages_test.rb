# frozen_string_literal: true

require_relative "test_helper"

class CorruptPagesTest < Minitest::Test
  Compression = Herringbone::Compression
  PAGE = Array.new(2000) { |i| "name #{i % 37} #{i}" }.join.b

  # Whatever the codec's library raises (Zlib::DataError, zstd-ruby's RuntimeError, our own
  # Codecs::Snappy::Error...) has to come out as a FormatError
  (Herringbone.codecs - [:none]).each do |name|
    define_method(:"test_damaged_#{name}_data_raises_format_error") do
      codec = Compression.codec_id(name)
      good = Compression.compress(codec, PAGE)
      random = Random.new(1)
      raised = 0
      200.times do
        bad = good.dup
        3.times { bad.setbyte(random.rand(bad.bytesize), random.rand(256)) }
        bad = bad[0, random.rand(bad.bytesize)] if random.rand < 0.1
        begin
          Compression.decompress(codec, bad, PAGE.bytesize)
        rescue Herringbone::FormatError
          raised += 1
        end
      end
      assert_operator raised, :>, 0
    end
  end

  ROWS = Array.new(2000) { |i| {"id" => i, "name" => "name #{i % 37}", "tags" => ["a", "b#{i}"], "f" => i * 1.5} }

  # Damage anywhere in the file, footer and page headers included. Anything but a
  # Herringbone::Error fails the test
  %i[rows numo].each do |as|
    define_method(:"test_damaged_file_read_as_#{as}_raises_only_herringbone_errors") do
      skip "Numo is not loaded" if as == :numo && !Herringbone::Reader::NumoColumns.loaded?
      io = StringIO.new("".b)
      Herringbone.write(io, ROWS)
      random = Random.new(1)
      raised = 0
      400.times do
        bad = io.string.dup
        3.times { bad.setbyte(random.rand(bad.bytesize), random.rand(256)) }
        bad = bad[0, random.rand(bad.bytesize)] if random.rand < 0.1
        begin
          Herringbone::Reader.new(StringIO.new(bad)).read(as: as)
        rescue Herringbone::Error
          raised += 1
        end
      end
      assert_operator raised, :>, 0
    end
  end

  def test_missing_row_group_metadata_raises_format_error
    io = StringIO.new("".b)
    Herringbone.write(io, ROWS.first(10))
    reader = Herringbone::Reader.new(io)
    reader.row_groups.first.num_rows = nil

    error = assert_raises(Herringbone::FormatError) { reader.read }
    assert_match(/The file is damaged: the list of row groups cannot be read/, error.message)
    assert_kind_of TypeError, error.cause
  end

  def test_errors_from_the_callers_block_are_left_alone
    io = StringIO.new("".b)
    Herringbone.write(io, ROWS.first(10))
    assert_raises(NoMethodError) { Herringbone::Reader.new(io).each_row { |row| row.no_such_method } }
  end

  def test_corrupt_page_names_the_codec_and_the_column
    schema = Herringbone::Schema.define { |s| s.string :name }
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, schema, compression: :gzip, dictionary: false) { |w| 500.times { |i| w << ["name #{i}"] } }
    bytes = io.string
    offset = Herringbone::Reader.new(StringIO.new(bytes)).file_metadata.row_groups[0].columns[0].meta_data.data_page_offset
    bytes.setbyte(offset + 60, bytes.getbyte(offset + 60) ^ 0xFF) # well inside the deflate stream

    error = assert_raises(Herringbone::FormatError) { Herringbone::Reader.new(StringIO.new(bytes)).read }
    assert_match(/Cannot decompress \d+ bytes of GZIP data/, error.message)
    assert_match(/\(column name\)/, error.message)
    assert_kind_of Zlib::Error, error.cause
  end

  def test_metadata_that_cannot_be_written_raises_a_herringbone_error
    schema = Herringbone::Schema.define { |s| s.int32 :a }
    error = assert_raises(Herringbone::Error) do
      Herringbone::Writer.open(StringIO.new("".b), schema, metadata: {"k" => "\xFF"}) { |w| w << [1] }
    end
    assert_kind_of Herringbone::Thrift::Error, error
  end
end
