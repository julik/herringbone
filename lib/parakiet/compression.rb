# frozen_string_literal: true

require "zlib"
require "stringio"

module Parakiet
  # Dispatches page (de)compression by Parquet codec id. Snappy and LZ4 are pure Ruby;
  # ZSTD and Brotli are used if the zstd-ruby / brotli gems can be loaded.
  module Compression
    module_function

    CODECS_BY_NAME = {
      none: Format::Codec::UNCOMPRESSED, uncompressed: Format::Codec::UNCOMPRESSED,
      snappy: Format::Codec::SNAPPY, gzip: Format::Codec::GZIP, brotli: Format::Codec::BROTLI,
      lz4: Format::Codec::LZ4_RAW, lz4_raw: Format::Codec::LZ4_RAW, lz4_hadoop: Format::Codec::LZ4,
      zstd: Format::Codec::ZSTD
    }.freeze

    def codec_id(name)
      return name if name.is_a?(Integer)
      CODECS_BY_NAME.fetch(name.to_s.downcase.to_sym) { raise ArgumentError, "Unknown compression codec #{name.inspect}" }
    end

    def decompress(codec, data, uncompressed_size)
      out = case codec
      when Format::Codec::UNCOMPRESSED then data
      when Format::Codec::SNAPPY then Codecs::Snappy.decompress(data)
      when Format::Codec::GZIP then gunzip(data)
      when Format::Codec::LZ4_RAW then Codecs::LZ4.decompress_block(data, uncompressed_size)
      when Format::Codec::LZ4 then Codecs::LZ4.decompress_hadoop(data, uncompressed_size)
      when Format::Codec::ZSTD then zstd.decompress(data)
      when Format::Codec::BROTLI then brotli.inflate(data)
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
      when Format::Codec::ZSTD then zstd.compress(data)
      when Format::Codec::BROTLI then brotli.deflate(data)
      else
        raise UnsupportedError, "Unsupported compression codec #{Format::Codec::NAMES[codec] || codec}"
      end.b
    end

    # Handles files whose gzip data consists of several concatenated members
    def gunzip(data)
      io = StringIO.new(data)
      out = String.new(encoding: Encoding::BINARY)
      loop do
        gz = Zlib::GzipReader.new(io)
        out << gz.read
        unused = gz.unused
        gz.finish
        break if unused.nil? || unused.empty?
        io.pos -= unused.bytesize
      end
      out
    end

    def zstd
      @zstd ||= begin
        require "zstd-ruby"
        ::Zstd
      rescue LoadError
        raise UnsupportedError, "ZSTD compression requires the zstd-ruby gem"
      end
    end

    def brotli
      @brotli ||= begin
        require "brotli"
        ::Brotli
      rescue LoadError
        raise UnsupportedError, "Brotli compression requires the brotli gem"
      end
    end
  end
end
