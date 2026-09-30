# frozen_string_literal: true

require "zlib"
require "stringio"

module Herringbone
  # Raised when a file uses (or a writer asks for) a codec whose library is not installed
  class MissingCodecError < UnsupportedError
    attr_reader :codec, :gem_name

    def initialize(codec, gem_name, load_error)
      @codec = codec
      @gem_name = gem_name
      super("#{codec} compression needs the \"#{gem_name}\" gem, which could not be loaded " \
        "(#{load_error.message}). Add `gem \"#{gem_name}\"` to your Gemfile to use #{codec}.")
    end
  end

  # Dispatches page (de)compression by Parquet codec id. Snappy and LZ4 are pure Ruby and GZIP
  # uses zlib, so those always work. ZSTD and Brotli come from optional gems (zstd-ruby, brotli),
  # which are required on first use; if they are missing, MissingCodecError says what to add.
  module Compression
    module_function

    # Codecs backed by optional native gems: codec id => [name, gem, require path, constant]
    LIBRARIES = {
      Format::Codec::ZSTD => ["ZSTD", "zstd-ruby", "zstd-ruby", :Zstd],
      Format::Codec::BROTLI => ["Brotli", "brotli", "brotli", :Brotli]
    }.freeze

    @libraries = {}
    @library_mutex = Mutex.new

    # The library module for a codec backed by an optional gem, requiring it on first use
    def library(codec)
      @libraries.fetch(codec) do
        @library_mutex.synchronize do
          @libraries.fetch(codec) do
            name, gem_name, path, const = LIBRARIES.fetch(codec)
            begin
              require_library(path)
            rescue LoadError => e
              raise MissingCodecError.new(name, gem_name, e)
            end
            @libraries[codec] = Object.const_get(const)
          end
        end
      end
    end

    def require_library(path)
      require path
    end

    # Raises MissingCodecError (or UnsupportedError) unless +codec+ can be used
    def ensure_available!(codec)
      codec = codec_id(codec)
      return library(codec) if LIBRARIES.key?(codec)
      return if SUPPORTED.include?(codec)
      raise UnsupportedError, "#{Format::Codec::NAMES[codec] || codec} compression is not supported"
    end

    # Whether +codec+ (a name like :zstd or a codec id) can be used in this process
    def available?(codec)
      ensure_available!(codec)
      true
    rescue UnsupportedError
      false
    end

    SUPPORTED = [
      Format::Codec::UNCOMPRESSED, Format::Codec::SNAPPY, Format::Codec::GZIP,
      Format::Codec::LZ4_RAW, Format::Codec::LZ4
    ].freeze

    CODECS_BY_NAME = {
      none: Format::Codec::UNCOMPRESSED, uncompressed: Format::Codec::UNCOMPRESSED,
      snappy: Format::Codec::SNAPPY, gzip: Format::Codec::GZIP, brotli: Format::Codec::BROTLI,
      lz4: Format::Codec::LZ4_RAW, lz4_raw: Format::Codec::LZ4_RAW, lz4_hadoop: Format::Codec::LZ4,
      zstd: Format::Codec::ZSTD, lzo: Format::Codec::LZO
    }.freeze

    # Canonical name of each codec id, as accepted by codec_id
    NAMES = {
      Format::Codec::UNCOMPRESSED => :none, Format::Codec::SNAPPY => :snappy, Format::Codec::GZIP => :gzip,
      Format::Codec::LZO => :lzo, Format::Codec::BROTLI => :brotli, Format::Codec::LZ4 => :lz4_hadoop,
      Format::Codec::ZSTD => :zstd, Format::Codec::LZ4_RAW => :lz4_raw
    }.freeze

    def codec_id(name)
      return name if name.is_a?(Integer)
      CODECS_BY_NAME.fetch(name.to_s.downcase.to_sym) { raise ArgumentError, "Unknown compression codec #{name.inspect}" }
    end

    def decompress(codec, data, uncompressed_size)
      return "".b if uncompressed_size.zero? && data.empty?
      out = case codec
      when Format::Codec::UNCOMPRESSED then data
      when Format::Codec::SNAPPY then Codecs::Snappy.decompress(data)
      when Format::Codec::GZIP then gunzip(data)
      when Format::Codec::LZ4_RAW then Codecs::LZ4.decompress_block(data, uncompressed_size)
      when Format::Codec::LZ4 then Codecs::LZ4.decompress_hadoop(data, uncompressed_size)
      when Format::Codec::ZSTD then library(codec).decompress(data)
      when Format::Codec::BROTLI then library(codec).inflate(data)
      else
        raise UnsupportedError, "Unsupported compression codec #{Format::Codec::NAMES[codec] || codec}"
      end
      out = out.b
      if out.bytesize != uncompressed_size
        raise DecodeError, "Decompressed #{out.bytesize} bytes, expected #{uncompressed_size}"
      end
      out
    end

    def compress(codec, data)
      case codec
      when Format::Codec::UNCOMPRESSED then data
      when Format::Codec::SNAPPY then Codecs::Snappy.compress(data)
      when Format::Codec::GZIP then Zlib.gzip(data)
      when Format::Codec::LZ4_RAW then Codecs::LZ4.compress_block(data)
      when Format::Codec::LZ4 then Codecs::LZ4.compress_hadoop(data)
      when Format::Codec::ZSTD then library(codec).compress(data)
      when Format::Codec::BROTLI then library(codec).deflate(data)
      else
        raise UnsupportedError, "Unsupported compression codec #{Format::Codec::NAMES[codec] || codec}"
      end.b
    end

    # Handles files whose gzip data consists of several concatenated members
    def gunzip(data)
      io = StringIO.new(data)
      out = String.new(encoding: Encoding::BINARY)
      while true
        gz = Zlib::GzipReader.new(io)
        out << gz.read
        unused = gz.unused
        gz.finish
        break if unused.nil? || unused.empty?
        io.pos -= unused.bytesize
      end
      out
    end
  end
end
