# frozen_string_literal: true

module Herringbone
  # Wraps every IO Herringbone reads a Parquet file from, and lets the reading code use only
  # #read, #seek, #pos and #size. Any object implementing #read and #seek can then be read from
  # (a File, a StringIO, an object fetching ranges from S3), and the reading code cannot start
  # depending on #readpartial, #pread, #eof? or anything else only some IOs have: what it needs
  # beyond the four methods it has to build on top of them.
  #
  # #path is there only to name the file in messages and in Inspector output.
  #
  #   reader = Herringbone::Reader.new(File.open("data.parquet", "rb"))
  #   reader.io      # => #<Herringbone::RestrictedReadableIO data.parquet>
  #   reader.io.path # => "data.parquet"
  class RestrictedReadableIO
    # What #path returns when the IO has no path of its own (a StringIO, a socket-backed IO...)
    UNTITLED = "untitled.parquet"

    # Wraps +io+, unless it is already wrapped
    #
    # @param io [IO, StringIO, RestrictedReadableIO, #read] anything responding to #read and #seek
    # @return [RestrictedReadableIO] +io+ itself when it is one, a new wrapper of it otherwise
    # @raise [ArgumentError] when +io+ does not respond to #read and #seek
    def self.wrap(io)
      io.is_a?(self) ? io : new(io)
    end

    # @param io [IO, StringIO, #read] anything responding to #read and #seek
    # @raise [ArgumentError] when +io+ does not respond to #read and #seek
    def initialize(io)
      unless io.respond_to?(:read) && io.respond_to?(:seek)
        raise ArgumentError, "#{self.class} wraps an IO that supports #seek and #read, got #{io.class}"
      end
      @io = io
    end

    # Reads up to +n_bytes+ from the current position
    #
    # @param n_bytes [Integer] bytes wanted
    # @return [String, nil] at most +n_bytes+, fewer when the end of the IO comes first; nil at the end
    def read(n_bytes)
      @io.read(n_bytes)
    end

    # Moves to +offset+ bytes from the start of the IO
    #
    # @param offset [Integer] absolute position
    # @return [Integer] 0, as IO#seek returns
    def seek(offset)
      @io.seek(offset)
      0
    end

    # @return [Integer] the current position, in bytes from the start of the IO
    def pos
      @io.pos
    end

    # Size of the IO in bytes, asked of the IO when it can tell (File, StringIO, Tempfile...) and
    # found by seeking to its end otherwise
    #
    # @return [Integer] the size in bytes
    def size
      return @io.size if @io.respond_to?(:size)
      at = @io.pos
      begin
        @io.seek(0, IO::SEEK_END)
        @io.pos
      ensure
        @io.seek(at)
      end
    end

    # @return [String] the path of the IO (File#path, Tempfile#path), or UNTITLED when it has none
    def path
      path = @io.path if @io.respond_to?(:path)
      path ? path.to_s : UNTITLED
    end

    # @return [String] e.g. "#<Herringbone::RestrictedReadableIO data.parquet>"
    def inspect
      "#<#{self.class.name} #{path}>"
    end
  end
end
