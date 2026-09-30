# frozen_string_literal: true

require "zlib"
require "stringio"
require "zstd-ruby"
require "brotli"

module Parakiet
  # Dispatches page (de)compression by Parquet codec id. Snappy and LZ4 are pure Ruby,
  # GZIP uses zlib, ZSTD and Brotli use the zstd-ruby and brotli gems.
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
      return "".b if uncompressed_size.zero? && data.empty?
      out = case codec
      when Format::Codec::UNCOMPRESSED then data
      when Format::Codec::SNAPPY then Codecs::Snappy.decompress(data)
      when Format::Codec::GZIP then gunzip(data)
      when Format::Codec::LZ4_RAW then Codecs::LZ4.decompress_block(data, uncompressed_size)
      when Format::Codec::LZ4 then Codecs::LZ4.decompress_hadoop(data, uncompressed_size)
      when Format::Codec::ZSTD then ::Zstd.decompress(data)
      when Format::Codec::BROTLI then ::Brotli.inflate(data)
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
      when Format::Codec::ZSTD then ::Zstd.compress(data)
      when Format::Codec::BROTLI then ::Brotli.deflate(data)
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
  end
end
