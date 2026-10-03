# frozen_string_literal: true

require "openssl"

module Herringbone
  # An encryption key and its id. The id is stored in the files the key encrypts (in the clear),
  # so a reader holding several keys can pick the right one; without an id of your own it is a
  # fingerprint of the key (an HMAC, which reveals nothing about the key), the same every time.
  #
  #   key = Herringbone::Key.generate                         # random AES-256 key, fingerprint id
  #   key = Herringbone::Key.from_hex(ENV["PARQUET_KEY"])     # 32 or 64 hex digits
  #   key = Herringbone::Key.new(bytes, id: "2026-10")
  #
  #   Herringbone.write(io, rows, encryption: key)
  #   Herringbone::Reader.new(io, decryption: key)            # or [new_key, old_key, ...]
  #
  # Where a key may be given as a String instead (+encryption:+, +decryption:+,
  # SimpleWriter#encrypt!), the String must be its hex: raw bytes are easy to mangle and to confuse
  # with text, so they go through Key.new.
  #
  # Instances are frozen; #inspect and #to_s show the id but not the key.
  class Key
    # Message the fingerprint id is an HMAC of
    FINGERPRINT_MESSAGE = "herringbone key id"

    # @return [String] the id stored in files encrypted with the key
    attr_reader :id

    # @return [String] the key material, 16, 24 or 32 bytes (binary)
    attr_reader :bytes

    # @param id [String, nil] the id; nil for the key's fingerprint
    # @param bits [Integer] 128, 192 or 256
    # @return [Key] a random key
    # @raise [ArgumentError] for another size
    def self.generate(id: nil, bits: 256)
      raise ArgumentError, "Key.generate: bits must be 128, 192 or 256, got #{bits.inspect}" unless [128, 192, 256].include?(bits)
      new(OpenSSL::Random.random_bytes(bits / 8), id: id)
    end

    # @param hex [String] 32, 48 or 64 hex digits
    # @param id [String, nil] the id; nil for the key's fingerprint
    # @return [Key]
    # @raise [ArgumentError] when +hex+ is not hex, or not of a key's length
    def self.from_hex(hex, id: nil)
      hex = hex.to_s.strip
      raise ArgumentError, "Key.from_hex: expected 32, 48 or 64 hex digits, got #{hex.size} characters" unless hex.match?(/\A(\h\h)+\z/)
      new([hex].pack("H*"), id: id)
    end

    # A Key, or a key given as its hex (with the fingerprint id): 32, 48 or 64 hex digits, as
    # +Key#hex+ gives them and as keys usually sit in environment variables. Any other String is
    # refused, raw key bytes included: those go through Key.new, so a key is never guessed at.
    #
    # @param value [Key, String] a key, or its hex
    # @return [Key]
    # @raise [ArgumentError] for anything else
    def self.from(value)
      return value if value.is_a?(Key)
      unless value.is_a?(String)
        raise ArgumentError, "Expected a Herringbone::Key or the hex of a key, got #{value.class}"
      end
      hex = value.strip
      return from_hex(hex) if hex.match?(/\A(?:\h{32}|\h{48}|\h{64})\z/)
      got = if hex.match?(/\A\h*\z/) then "#{hex.size} hex digits"
      elsif Encryption::KEY_SIZES.include?(value.bytesize) then "#{value.bytesize} bytes that are not hex (raw key bytes?)"
      else "a #{value.bytesize}-byte String that is not hex"
      end
      raise ArgumentError, "Give a key as 32 or 64 hex digits (Herringbone::Key#hex) or as a Herringbone::Key " \
        "(Herringbone::Key.new(bytes) for raw bytes), got #{got}"
    end

    # @param bytes [String] 16, 24 or 32 bytes (AES-128, 192 or 256)
    # @return [String] the fingerprint of +bytes+: 16 hex digits of an HMAC-SHA256 keyed with them
    def self.fingerprint(bytes)
      OpenSSL::HMAC.digest("SHA256", bytes, FINGERPRINT_MESSAGE).unpack1("H16")
    end

    # @param bytes [String] 16, 24 or 32 bytes (AES-128, 192 or 256); +Key.generate+ makes one
    # @param id [String, nil] the id; nil for the key's fingerprint
    # @raise [ArgumentError] when +bytes+ is not 16, 24 or 32 bytes long, or +id+ is empty
    def initialize(bytes, id: nil)
      @bytes = Encryption.check_key!(bytes, "Key").freeze
      @id = (id.nil? ? Key.fingerprint(@bytes) : id.to_s).dup.freeze
      raise ArgumentError, "Key: id must not be empty" if @id.empty?
      freeze
    end

    # @return [String] the key material as hex
    def hex = @bytes.unpack1("H*")

    # @return [Integer] 128, 192 or 256
    def bits = @bytes.bytesize * 8

    # @param other [Object] object to compare with
    # @return [Boolean] whether +other+ is a Key with the same id and bytes
    def ==(other) = other.is_a?(Key) && other.id == @id && other.bytes == @bytes
    alias_method :eql?, :==

    # @return [Integer] hash of the id and bytes
    def hash = [Key, @id, @bytes].hash

    # @return [String] the id and size, without the key
    def inspect = "#<#{self.class.name} id=#{@id.inspect} AES-#{bits}>"
    alias_method :to_s, :inspect
  end
end
