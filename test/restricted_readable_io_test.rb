# frozen_string_literal: true

require_relative "test_helper"

class RestrictedReadableIOTest < Minitest::Test
  RestrictedReadableIO = Herringbone::RestrictedReadableIO
  PLAIN = File.join(FIXTURES_DIR, "parquet-testing", "alltypes_plain.parquet")

  # Responds to nothing but what RestrictedReadableIO needs: no #size, #path, #eof?, #pread...
  class BareIO
    attr_reader :calls

    def initialize(bytes)
      @io = StringIO.new(bytes)
      @calls = []
    end

    def read(n_bytes)
      @calls << :read
      @io.read(n_bytes)
    end

    def seek(offset, whence = IO::SEEK_SET)
      @calls << :seek
      @io.seek(offset, whence)
    end

    def pos
      @calls << :pos
      @io.pos
    end
  end

  def test_exposes_only_the_restricted_subset
    added = RestrictedReadableIO.public_instance_methods - Object.public_instance_methods
    assert_equal %i[path pos read seek size], added.sort
  end

  def test_wrap_does_not_wrap_twice
    wrapped = RestrictedReadableIO.wrap(StringIO.new("abc"))
    assert_same wrapped, RestrictedReadableIO.wrap(wrapped)
    refute_same wrapped, RestrictedReadableIO.new(wrapped)
  end

  def test_rejects_what_cannot_read_and_seek
    ["bytes", nil, Object.new].each do |bad|
      error = assert_raises(ArgumentError) { RestrictedReadableIO.new(bad) }
      assert_match(/supports #seek and #read, got #{bad.class}/, error.message)
    end
  end

  def test_forwards_read_seek_and_pos
    io = RestrictedReadableIO.new(StringIO.new("abcdef"))
    assert_equal 0, io.seek(2)
    assert_equal "cd", io.read(2)
    assert_equal 4, io.pos
    assert_equal "ef", io.read(10), "fewer bytes than asked for at the end"
    assert_nil io.read(1)
    io.seek(0)
    assert_equal "", io.read(0)
  end

  def test_seek_is_absolute_only
    assert_raises(ArgumentError) { RestrictedReadableIO.new(StringIO.new("abc")).seek(0, IO::SEEK_END) }
  end

  def test_size_is_asked_of_the_io_when_it_can_tell
    io = Object.new
    def io.read(n) = nil
    def io.seek(offset) = 0
    def io.size = 123
    assert_equal 123, RestrictedReadableIO.new(io).size
  end

  def test_size_of_an_io_without_size_is_found_by_seeking_and_keeps_the_position
    bare = BareIO.new("abcdef")
    io = RestrictedReadableIO.new(bare)
    io.seek(2)
    assert_equal 6, io.size
    assert_equal 2, io.pos
    assert_equal "cd", io.read(2)
  end

  def test_path
    File.open(PLAIN, "rb") { |f| assert_equal PLAIN, RestrictedReadableIO.new(f).path }
    assert_equal RestrictedReadableIO::UNTITLED, RestrictedReadableIO.new(StringIO.new).path
    assert_equal "#<Herringbone::RestrictedReadableIO untitled.parquet>", RestrictedReadableIO.new(StringIO.new).inspect
  end

  def test_path_of_an_io_whose_path_is_nil
    io = StringIO.new
    def io.path = nil
    assert_equal RestrictedReadableIO::UNTITLED, RestrictedReadableIO.new(io).path
  end

  def test_reader_wraps_the_io_and_exposes_the_wrapper
    File.open(PLAIN, "rb") do |f|
      reader = Herringbone::Reader.new(f)
      assert_instance_of RestrictedReadableIO, reader.io
      assert_equal PLAIN, reader.io.path
      assert_same reader.io, Herringbone::Reader.new(reader.io).io
    end
  end

  def test_files_are_read_with_nothing_but_read_seek_and_pos
    bare = BareIO.new(File.binread(PLAIN))
    expected = File.open(PLAIN, "rb") { |f| Herringbone::Reader.new(f).read }
    assert_equal expected, Herringbone::Reader.new(bare).read
    assert_equal 8, Herringbone::Inspector.new(BareIO.new(File.binread(PLAIN))).load_all.num_rows
    assert_equal %i[pos read seek], bare.calls.uniq.sort
  end
end
