# frozen_string_literal: true

require "zlib"
require "stringio"

module Herringbone
  # Raised when a file uses (or a writer asks for) a codec whose library is not loaded
  class MissingCodecError < UnsupportedError
    # @return [String] codec name (+"ZSTD"+) and name of the gem providing it (+"zstd-ruby"+)
    attr_reader :codec, :gem_name

    # @param codec [String] codec name, as shown in the message
    # @param gem_name [String] gem to add to the Gemfile
    # @param path [String] what to require to load the gem
    def initialize(codec, gem_name, path)
      @codec = codec
      @gem_name = gem_name
      super("#{codec} compression needs the \"#{gem_name}\" gem, which is not loaded. Add " \
        "`gem \"#{gem_name}\"` to your Gemfile and `require \"#{path}\"` to use #{codec}.")
    end
  end

  # Dispatches page (de)compression by Parquet codec id. Snappy and LZ4 are pure Ruby and GZIP
  # uses zlib, so those always work. LZO is pure Ruby too, but can only be read. ZSTD and Brotli
  # come from optional gems (zstd-ruby, brotli), which the application requires; if they are
  # not loaded, MissingCodecError says what to add.
  # (Snappy also uses the optional snappy gem when it is loaded, see Codecs::Snappy.)
  module Compression
    module_function

    # Codecs backed by optional native gems: codec id => [name, gem, require path, constant]
    LIBRARIES = Ractor.make_shareable({
      Format::Codec::ZSTD => ["ZSTD", "zstd-ruby", "zstd-ruby", :Zstd],
      Format::Codec::BROTLI => ["Brotli", "brotli", "brotli", :Brotli]
    })

    # The library module for a codec backed by an optional gem
    #
    # @param codec [Integer] a codec id that is a key of LIBRARIES
    # @return [Module] the gem's module (+Zstd+ or +Brotli+)
    # @raise [MissingCodecError] when the gem is not loaded
    # @raise [KeyError] for a codec id not in LIBRARIES
    def library(codec)
      name, gem_name, path, const = LIBRARIES.fetch(codec)
      loaded_library(const) || raise(MissingCodecError.new(name, gem_name, path))
    end

    # A separate method so tests can stub it to simulate a missing gem
    #
    # @param const [Symbol] top-level constant the gem defines
    # @return [Module, nil] the gem's module, nil when it is not loaded
    def loaded_library(const)
      Object.const_get(const) if Object.const_defined?(const)
    end

    # Raises MissingCodecError (or UnsupportedError) unless +codec+ can be used
    #
    # @param codec [Integer, Symbol, String] codec id or name (see NAMES)
    # @return [Module, nil] the gem's module for a gem-backed codec, nil for a built-in one
    # @raise [MissingCodecError] when the codec's gem is not loaded
    # @raise [UnsupportedError] for a codec herringbone cannot write (LZO)
    # @raise [ArgumentError] for an unknown codec name
    def ensure_available!(codec)
      codec = codec_id(codec)
      return library(codec) if LIBRARIES.key?(codec)
      return if SUPPORTED.include?(codec)
      raise UnsupportedError, "LZO compression is only supported for reading" if codec == Format::Codec::LZO
      raise UnsupportedError, "#{Format::Codec::NAMES[codec] || codec} compression is not supported"
    end

    # Codec ids that work without optional gems
    SUPPORTED = [
      Format::Codec::UNCOMPRESSED, Format::Codec::SNAPPY, Format::Codec::GZIP,
      Format::Codec::LZ4_RAW, Format::Codec::LZ4
    ].freeze

    # Codec id => name, as given to the writer's compression: option and listed by Herringbone.codecs
    NAMES = {
      Format::Codec::UNCOMPRESSED => :none, Format::Codec::SNAPPY => :snappy, Format::Codec::GZIP => :gzip,
      Format::Codec::LZ4_RAW => :lz4, Format::Codec::LZ4 => :lz4_hadoop, Format::Codec::ZSTD => :zstd,
      Format::Codec::BROTLI => :brotli, Format::Codec::LZO => :lzo
    }.freeze
    # Codec name => codec id, the inverse of NAMES
    CODECS_BY_NAME = NAMES.invert.freeze

    # Codec id for a codec name; Integers are taken to be ids already and returned unchecked
    #
    # @param name [Integer, Symbol, String] codec id, or a name from NAMES (case-insensitive)
    # @return [Integer] the Format::Codec id
    # @raise [ArgumentError] for an unknown name
    def codec_id(name)
      return name if name.is_a?(Integer)
      CODECS_BY_NAME.fetch(name.to_s.downcase.to_sym) do
        raise ArgumentError, "Unknown compression codec #{name.inspect}, expected one of #{NAMES.values.map(&:inspect).join(", ")}"
      end
    end

    # Decompresses a page body, checking the result against the size the page header declares
    #
    # @param codec [Integer] Format::Codec id from the column chunk metadata
    # @param data [String] compressed bytes
    # @param uncompressed_size [Integer] expected decompressed size in bytes
    # @return [String] decompressed bytes (binary)
    # @raise [UnsupportedError] for a codec herringbone does not implement
    # @raise [MissingCodecError] when the codec's gem is not loaded
    # @raise [FormatError] when the decompressed size does not match +uncompressed_size+
    def decompress(codec, data, uncompressed_size)
      return "".b if uncompressed_size.zero? && data.empty?
      out = case codec
      when Format::Codec::UNCOMPRESSED then data
      when Format::Codec::SNAPPY then Codecs::Snappy.decompress(data)
      when Format::Codec::GZIP then gunzip(data)
      when Format::Codec::LZ4_RAW then Codecs::LZ4.decompress_block(data, uncompressed_size)
      when Format::Codec::LZ4 then Codecs::LZ4.decompress_hadoop(data, uncompressed_size)
      when Format::Codec::LZO then Codecs::LZO.decompress_hadoop(data, uncompressed_size)
      when Format::Codec::ZSTD then library(codec).decompress(data)
      when Format::Codec::BROTLI then library(codec).inflate(data)
      else
        raise UnsupportedError, "Unsupported compression codec #{Format::Codec::NAMES[codec] || codec}"
      end
      out = out.b
      if out.bytesize != uncompressed_size
        raise FormatError, "Decompressed #{out.bytesize} bytes, expected #{uncompressed_size}"
      end
      out
    end

    # Compresses a page body
    #
    # @param codec [Integer] Format::Codec id
    # @param data [String] bytes to compress
    # @return [String] compressed bytes (binary)
    # @raise [UnsupportedError] for a codec herringbone does not implement
    # @raise [MissingCodecError] when the codec's gem is not loaded
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
    #
    # @param data [String] gzip data, one or more members
    # @return [String] the members' decompressed bytes concatenated (binary)
    # @raise [Zlib::GzipFile::Error] on corrupt gzip data
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
