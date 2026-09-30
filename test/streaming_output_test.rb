# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"

# The writer only ever appends to its output: these tests write through IOs that support nothing
# but #write (as a network upload stream, e.g. aws-sdk-s3's upload_stream, may) and through a pipe.
class StreamingOutputTest < Minitest::Test
  include WriterHelpers

  # Responds to #write only. Anything else an IO might offer (seek, pos, rewind, read, flush...)
  # raises, and #write returns nil, so the writer cannot rely on its return value. The Strings
  # passed to #write are kept as they are (not copied), which also catches a writer that reuses
  # a buffer after handing it over.
  class WriteOnlyIO < BasicObject
    attr_reader :chunks

    def initialize
      @chunks = []
      @copy = ::String.new(encoding: ::Encoding::BINARY)
    end

    def write(*strings)
      strings.each do |s|
        ::Kernel.raise ::ArgumentError, "expected a String, got #{s.class}" unless ::String === s
        @chunks << s
        @copy << s.b
      end
      nil
    end

    def respond_to?(name, _include_all = false) = name.to_sym == :write
    def is_a?(_klass) = false

    def bytes
      joined = @chunks.map(&:b).join
      ::Kernel.raise "a chunk changed after it was written" unless joined == @copy
      joined
    end

    def method_missing(name, *)
      ::Kernel.raise ::NoMethodError, "WriteOnlyIO does not support ##{name}"
    end

    def respond_to_missing?(*) = false
  end

  SCHEMA = Herringbone::Schema.define do
    int64 :id, null: false
    string :name
    string :blob
    double :score
    timestamp :at
    list :tags, :string
    struct :address do
      string :city
    end
  end

  def rows(n, blob_every: 0)
    Array.new(n) do |i|
      {
        "id" => i,
        "name" => i % 7 == 0 ? nil : "name-#{i % 97}",
        "blob" => blob_every.positive? && (i % blob_every).zero? ? ("x#{i}" * 40_000) : "b#{i}",
        "score" => i * 0.5,
        "at" => Time.at(1_700_000_000 + i).utc,
        "tags" => i.even? ? ["t#{i % 5}", "u"] : [],
        "address" => i % 3 == 0 ? nil : { "city" => "city-#{i % 11}" }
      }
    end
  end

  OPTIONS = { row_group_rows: 1500, page_rows: 400, bloom_filters: %w[id name address.city] }.freeze

  [1, 2].each do |version|
    define_method("test_write_only_io_round_trip_v#{version}") do
      data = rows(5000, blob_every: 500)
      io = WriteOnlyIO.new
      Herringbone::Writer.open(io, SCHEMA, data_page_version: version, **OPTIONS) do |w|
        data.each { |r| w << r }
      end
      bytes = io.bytes
      assert io.chunks.all? { |c| c.encoding == Encoding::BINARY }, "every chunk is binary"
      assert_equal write_to_string(SCHEMA, data, data_page_version: version, **OPTIONS), bytes,
        "same bytes as writing to a StringIO"
      assert_roundtrip(SCHEMA, data, bytes)

      reader = reader_for(bytes)
      assert_equal 4, reader.row_groups.size
      reader.row_groups.each_with_index do |rg, g|
        rg.columns.each do |chunk|
          assert chunk.offset_index_offset, "offset index"
          stats = chunk.meta_data.statistics
          assert stats && stats.null_count, "statistics"
        end
        assert reader.bloom_filter(g, "id").might_contain?(g * 1500)
        assert reader.bloom_filter(g, "address.city")
      end
      assert_equal [4321], reader.read(where: { id: 4321 }).map { |r| r["id"] }
      plan = reader.scan_plan(where: { id: 4321 })
      assert_equal [2], plan.map { |p| p[:row_group] }
      assert_operator plan[0][:rows], :<=, 400, "page index narrows the read to one page"
    end
  end

  def test_write_only_io_all_types_and_nesting
    [WriterHelpers.all_types_rows(300), WriterHelpers.nested_rows(300)].zip([ALL_TYPES_SCHEMA, NESTED_SCHEMA]).each do |data, schema|
      io = WriteOnlyIO.new
      Herringbone.write(io, data, schema: schema, row_group_rows: 100, bloom_filters: true, data_page_version: 2)
      assert_roundtrip(schema, data, io.bytes)
    end
  end

  def test_aborted_write_leaves_only_a_prefix
    io = WriteOnlyIO.new
    assert_raises(RuntimeError) do
      Herringbone::Writer.open(io, SCHEMA, row_group_rows: 100) do |w|
        rows(250).each { |r| w << r }
        raise "boom"
      end
    end
    bytes = io.bytes
    assert bytes.start_with?("PAR1")
    refute bytes.end_with?("PAR1"), "no footer is written"
  end

  # A pipe stands in for a network stream: it only moves forward and blocks when full
  def test_pipe_with_reader_thread
    data = rows(20_000, blob_every: 2000)
    read_end, write_end = IO.pipe
    consumer = Thread.new do
      read_end.binmode
      out = String.new(encoding: Encoding::BINARY)
      while (chunk = read_end.read(16_384))
        out << chunk
      end
      out
    end
    Herringbone::Writer.open(write_end, SCHEMA, **OPTIONS) { |w| data.each { |r| w << r } }
    write_end.close
    bytes = consumer.value
    read_end.close
    assert_operator bytes.bytesize, :>, 500_000 # well over the pipe buffer
    assert_equal 14, reader_for(bytes).row_groups.size
    assert_roundtrip(SCHEMA, data, bytes)
  end

  # Rails sets Encoding.default_internal, which makes a text-mode IO transcode what is written;
  # the writer switches the IO to binary mode so binary pages go through untouched.
  def test_text_mode_pipe_with_default_internal
    previous = Encoding.default_internal
    Encoding.default_internal = Encoding::UTF_8
    read_end, write_end = IO.pipe
    refute write_end.binmode?
    consumer = Thread.new { read_end.binmode.read }
    data = rows(2000)
    Herringbone.write(write_end, data, schema: SCHEMA)
    write_end.close
    assert_roundtrip(SCHEMA, data, consumer.value)
  ensure
    Encoding.default_internal = previous
    write_end&.close unless write_end&.closed?
    consumer&.join
    read_end&.close
  end
end
