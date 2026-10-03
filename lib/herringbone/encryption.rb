# frozen_string_literal: true

require "openssl"

module Herringbone
  # Parquet modular encryption (Encryption.md in parquet-format): AES-GCM and AES-CTR on top of
  # OpenSSL, and the AADs that tie every encrypted module to its file and its place in the file.
  # Writer takes +encryption:+ and Reader +decryption:+; see FileEncryptor and FileDecryptor.
  #
  # An encrypted module is stored as a 4-byte little-endian length, then a 12-byte nonce, the
  # ciphertext and (GCM only) a 16-byte tag.
  module Encryption
    # Module type: the FileMetaData
    FOOTER = 0
    # Module type: a ColumnMetaData encrypted on its own
    COLUMN_META_DATA = 1
    # Module type: a data page body
    DATA_PAGE = 2
    # Module type: a dictionary page body
    DICTIONARY_PAGE = 3
    # Module type: a data page header
    DATA_PAGE_HEADER = 4
    # Module type: a dictionary page header
    DICTIONARY_PAGE_HEADER = 5
    # Module type: a ColumnIndex
    COLUMN_INDEX = 6
    # Module type: an OffsetIndex
    OFFSET_INDEX = 7
    # Module type: a bloom filter header
    BLOOM_FILTER_HEADER = 8
    # Module type: a bloom filter bitset
    BLOOM_FILTER_BITSET = 9
    # Module type => what it is, for error messages
    MODULE_NAMES = Ractor.make_shareable({
      FOOTER => "footer", COLUMN_META_DATA => "column metadata", DATA_PAGE => "data page",
      DICTIONARY_PAGE => "dictionary page", DATA_PAGE_HEADER => "data page header",
      DICTIONARY_PAGE_HEADER => "dictionary page header", COLUMN_INDEX => "column index",
      OFFSET_INDEX => "offset index", BLOOM_FILTER_HEADER => "bloom filter header",
      BLOOM_FILTER_BITSET => "bloom filter bitset"
    })

    # Bytes of a GCM nonce, also the nonce part of a CTR IV
    NONCE = 12
    # Bytes of a GCM tag
    TAG = 16
    # Bytes of the footer signature in plaintext-footer files: nonce and tag
    SIGNATURE = NONCE + TAG
    # AES-128, AES-192 and AES-256
    KEY_SIZES = [16, 24, 32].freeze
    # Row group, column and page ordinals are stored in AADs as signed 16-bit integers
    MAX_ORDINAL = 0x7FFF
    # Encryptions allowed per key (NIST SP 800-38D, section 8.3)
    MAX_INVOCATIONS = 1 << 32
    # The last 4 bytes of a CTR IV: the counter starts at 1
    CTR_COUNTER = "\x00\x00\x00\x01".b.freeze
    # Bytes of the random file id that is part of every AAD
    FILE_UNIQUE_BYTES = 8
    # Magic bytes at both ends of a file with an encrypted footer
    ENCRYPTED_MAGIC = "PARE"

    module_function

    # @param key [Object] candidate key
    # @param what [String] what the key is for, for the error message
    # @return [String] the key as a binary String
    # @raise [ArgumentError] when +key+ is not a String of 16, 24 or 32 bytes
    def check_key!(key, what)
      unless key.is_a?(String) && KEY_SIZES.include?(key.bytesize)
        got = key.is_a?(String) ? "#{key.bytesize} bytes" : key.class.to_s
        raise ArgumentError, "#{what} must be a 16, 24 or 32-byte String (AES-128/192/256), got #{got}"
      end
      key.b
    end

    # Leaf columns named by a column path (a leaf) or by a field (all of its leaves)
    #
    # @param schema [Schema] schema holding the columns
    # @param name [String, Symbol, Array<String>] dotted path, or an Array of names
    # @return [Array<Schema::Column>] the columns, empty when nothing matches
    def columns_named(schema, name)
      name = name.is_a?(Array) ? name.join(".") : name.to_s
      prefix = "#{name}."
      schema.columns.select { |c| c.dotted_path == name || c.dotted_path.start_with?(prefix) }
    end

    # Reads the footer region (everything between the data and the 4-byte footer length) of a
    # plaintext or encrypted file. Column metadata that can be decrypted replaces the stripped or
    # missing +meta_data+ of its ColumnChunk.
    #
    # @param region [String] the footer region, binary
    # @param magic [String] the file's closing magic, "PAR1" or "PARE"
    # @param decryption [DecryptionConfiguration, nil] the keys
    # @return [Array(Format::FileMetaData, FileDecryptor)] the footer, and its decryptor (nil for
    #   a file that is not encrypted)
    # @raise [DecryptionError] when the footer is encrypted and cannot be decrypted, or its
    #   signature does not match
    # @raise [Thrift::Error] when the footer cannot be decoded
    def read_footer(region, magic, decryption)
      if magic == ENCRYPTED_MAGIC
        crypto, pos = Format::FileCryptoMetaData.decode(region)
        unless decryption
          algorithm = crypto.encryption_algorithm&.aes_gcm_ctr_v1 ? "AES_GCM_CTR_V1" : "AES_GCM_V1"
          metadata = crypto.key_metadata && ", footer key metadata #{crypto.key_metadata.inspect}"
          raise DecryptionError, "The file is encrypted (#{algorithm}#{metadata}), footer included: pass decryption: with its keys"
        end
        decryptor = FileDecryptor.new(decryption, crypto.encryption_algorithm, footer_key_metadata: crypto.key_metadata)
        meta = Format::FileMetaData.decode(decryptor.decrypt_footer(region.byteslice(pos..))).first
      else
        meta, pos = Format::FileMetaData.decode(region)
        return [meta, nil] unless meta.encryption_algorithm
        decryptor = FileDecryptor.new(decryption, meta.encryption_algorithm,
          footer_key_metadata: meta.footer_signing_key_metadata, plaintext_footer: true)
        signature = region.byteslice(pos, SIGNATURE)
        raise FormatError, "Footer signature is missing" unless signature&.bytesize == SIGNATURE
        decryptor.verify_footer(region.byteslice(0, pos), signature)
      end
      decryptor.decrypt_column_metadata(meta)
      [meta, decryptor]
    end

    # AES with one key: GCM and CTR ciphers, reused from module to module, and the count of
    # encryptions done with the key
    class Cipher
      # @param key [String] 16, 24 or 32 bytes
      def initialize(key)
        @key = key
        @bits = key.bytesize * 8
        @gcm = OpenSSL::Cipher.new("aes-#{@bits}-gcm")
        @invocations = 0
      end

      # @param plain [String] bytes to encrypt
      # @param aad [String] additional authenticated data
      # @return [String] the module: length, nonce, ciphertext and tag
      # @raise [Error] after MAX_INVOCATIONS encryptions with this key
      def gcm_encrypt(plain, aad)
        count!
        nonce = OpenSSL::Random.random_bytes(NONCE)
        c = @gcm
        c.encrypt
        c.key = @key
        c.iv = nonce
        c.auth_data = aad
        out = String.new(capacity: plain.bytesize + NONCE + TAG + 4, encoding: Encoding::BINARY)
        out << [plain.bytesize + NONCE + TAG].pack("V") << nonce
        out << c.update(plain) unless plain.empty?
        out << c.final << c.auth_tag
      end

      # @param buf [String] nonce, ciphertext and tag
      # @param aad [String] additional authenticated data
      # @return [String] the plaintext
      # @raise [OpenSSL::Cipher::CipherError] when the tag does not match
      # @raise [FormatError] when +buf+ is too short to hold a nonce and a tag
      def gcm_decrypt(buf, aad)
        raise FormatError, "Encrypted module of #{buf.bytesize} bytes is too short" if buf.bytesize < NONCE + TAG
        c = @gcm
        c.decrypt
        c.key = @key
        c.iv = buf.byteslice(0, NONCE)
        c.auth_tag = buf.byteslice(-TAG, TAG)
        c.auth_data = aad
        ciphertext = buf.byteslice(NONCE, buf.bytesize - NONCE - TAG)
        out = ciphertext.empty? ? "".b : c.update(ciphertext)
        out << c.final
      end

      # The tag GCM gives +plain+ with +nonce+, for footer signatures
      #
      # @param plain [String] the signed bytes
      # @param aad [String] additional authenticated data
      # @param nonce [String, nil] the nonce to use, random when nil
      # @return [String] nonce and tag
      def gcm_sign(plain, aad, nonce = nil)
        count!
        nonce ||= OpenSSL::Random.random_bytes(NONCE)
        c = @gcm
        c.encrypt
        c.key = @key
        c.iv = nonce
        c.auth_data = aad
        c.update(plain) unless plain.empty?
        c.final
        nonce + c.auth_tag
      end

      # @param plain [String] bytes to encrypt
      # @return [String] the module: length, nonce and ciphertext
      def ctr_encrypt(plain)
        count!
        nonce = OpenSSL::Random.random_bytes(NONCE)
        out = String.new(capacity: plain.bytesize + NONCE + 4, encoding: Encoding::BINARY)
        out << [plain.bytesize + NONCE].pack("V") << nonce << ctr(nonce, plain)
      end

      # @param buf [String] nonce and ciphertext
      # @return [String] the plaintext
      # @raise [FormatError] when +buf+ is too short to hold a nonce
      def ctr_decrypt(buf)
        raise FormatError, "Encrypted page of #{buf.bytesize} bytes is too short" if buf.bytesize < NONCE
        ctr(buf.byteslice(0, NONCE), buf.byteslice(NONCE..))
      end

      # @return [String] key size, without the key
      def inspect = "#<#{self.class.name} AES-#{@bits}>"

      private

      # @param nonce [String] 12 bytes
      # @param data [String] bytes to encrypt or decrypt (the same operation in CTR mode)
      # @return [String]
      def ctr(nonce, data)
        c = (@ctr ||= OpenSSL::Cipher.new("aes-#{@bits}-ctr"))
        c.encrypt
        c.key = @key
        c.iv = nonce + CTR_COUNTER
        out = data.empty? ? "".b : c.update(data)
        out << c.final
      end

      # @return [void]
      # @raise [Error] after MAX_INVOCATIONS encryptions
      def count!
        @invocations += 1
        return if @invocations <= MAX_INVOCATIONS
        raise Error, "AES-GCM allows at most 2^32 encryptions per key: use another key"
      end
    end

    # Encrypts and decrypts the modules of one column chunk (or the footer, without ordinals),
    # building each module's AAD
    class ModuleCrypto
      # @param cipher [Cipher] the column's (or footer's) key
      # @param file_aad [String] AAD prefix and file unique id
      # @param ctr [Boolean] whether page bodies use AES-CTR (AES_GCM_CTR_V1)
      # @param row_group [Integer, nil] row group ordinal; nil for the footer
      # @param column [Integer, nil] column ordinal; nil for the footer
      # @param what [String] the column and row group, for error messages
      def initialize(cipher, file_aad, ctr, row_group = nil, column = nil, what = "the footer")
        @cipher = cipher
        @file_aad = file_aad
        @ctr = ctr
        @ordinals = row_group ? [row_group, column].pack("s<s<") : "".b
        @what = what
      end

      # @param type [Integer] module type
      # @param plain [String] the module's plaintext
      # @param page [Integer, nil] data page ordinal within the chunk, for data pages and their headers
      # @return [String] the encrypted module, length prefix included
      # @raise [UnsupportedError] when +page+ is above MAX_ORDINAL
      def encrypt(type, plain, page = nil)
        return @cipher.ctr_encrypt(plain) if @ctr && (type == DATA_PAGE || type == DICTIONARY_PAGE)
        @cipher.gcm_encrypt(plain, aad(type, page))
      end

      # @param type [Integer] module type
      # @param mod [String] the encrypted module, length prefix included
      # @param page [Integer, nil] data page ordinal within the chunk, for data pages and their headers
      # @return [String] the plaintext
      # @raise [DecryptionError] when the tag does not match (wrong key, or changed bytes)
      # @raise [FormatError] when the length prefix does not match the module's size
      def decrypt(type, mod, page = nil)
        len = mod.byteslice(0, 4)&.unpack1("V")
        unless len == mod.bytesize - 4
          raise FormatError, "Encrypted #{MODULE_NAMES[type]} of #{@what} is truncated or corrupt"
        end
        body = mod.byteslice(4, len)
        return @cipher.ctr_decrypt(body) if @ctr && (type == DATA_PAGE || type == DICTIONARY_PAGE)
        @cipher.gcm_decrypt(body, aad(type, page))
      rescue OpenSSL::Cipher::CipherError
        raise DecryptionError, "Cannot decrypt the #{MODULE_NAMES[type]} of #{@what}: wrong key or AAD prefix, " \
          "or the file was changed"
      end

      # @param plain [String] the footer as serialized
      # @return [String] nonce and tag of the footer signature
      def sign(plain) = @cipher.gcm_sign(plain, aad(FOOTER, nil))

      # @param plain [String] the footer as serialized
      # @param signature [String] nonce and tag stored after it
      # @return [Boolean] whether the signature matches
      def signed?(plain, signature)
        expected = @cipher.gcm_sign(plain, aad(FOOTER, nil), signature.byteslice(0, NONCE))
        OpenSSL.fixed_length_secure_compare(expected, signature)
      end

      private

      # @param type [Integer] module type
      # @param page [Integer, nil] page ordinal
      # @return [String] file AAD, module type, row group and column ordinals, page ordinal
      # @raise [UnsupportedError] when +page+ is above MAX_ORDINAL
      def aad(type, page)
        aad = @file_aad + type.chr + @ordinals
        return aad unless page
        raise UnsupportedError, "Encrypted column chunks hold at most #{MAX_ORDINAL + 1} pages" if page > MAX_ORDINAL
        aad << [page].pack("s<")
      end
    end

    # An EncryptionConfiguration applied to a schema: what the writer needs to encrypt each
    # module and the footer
    class FileEncryptor
      # How one column is encrypted
      #
      # @!attribute cipher
      #   @return [Cipher] its key
      # @!attribute key_metadata
      #   @return [String, nil] stored with the column (column keys only)
      # @!attribute footer
      #   @return [Boolean] whether the key is the footer key
      ColumnKey = Struct.new(:cipher, :key_metadata, :footer)

      # @return [Boolean] whether the footer is stored in the clear (and signed)
      attr_reader :plaintext_footer

      # @param config [EncryptionConfiguration] the settings
      # @param schema [Schema] the schema being written
      # @raise [ArgumentError] for an unknown column, or columns named so that one is listed twice
      # @raise [UnsupportedError] when the schema has more columns than AADs can number
      def initialize(config, schema)
        if schema.columns.size > MAX_ORDINAL + 1
          raise UnsupportedError, "Encrypted files hold at most #{MAX_ORDINAL + 1} columns"
        end
        @ciphers = {}
        @footer = ColumnKey.new(cipher_for(config.footer_key), nil, true)
        @footer_key_metadata = config.footer_key_metadata
        @plaintext_footer = config.plaintext_footer?
        @ctr = config.algorithm == :aes_gcm_ctr
        prefix = config.aad_prefix
        store = config.store_aad_prefix?
        unique = OpenSSL::Random.random_bytes(FILE_UNIQUE_BYTES)
        @file_aad = (prefix || "".b) + unique
        settings = {aad_prefix: store ? prefix : nil, aad_file_unique: unique, supply_aad_prefix: store ? nil : true}
        @algorithm = if @ctr
          Format::EncryptionAlgorithm.new(aes_gcm_ctr_v1: Format::AesGcmCtrV1.new(**settings))
        else
          Format::EncryptionAlgorithm.new(aes_gcm_v1: Format::AesGcmV1.new(**settings))
        end
        @schema = schema
        @columns = column_keys(config.columns)
      end

      # @return [String] the magic bytes the file starts and ends with
      def magic = @plaintext_footer ? Writer::MAGIC : ENCRYPTED_MAGIC.b

      # @param index [Integer] leaf column index
      # @return [Boolean] whether the column is encrypted
      def encrypted?(index) = !@columns[index].nil?

      # @param row_group [Integer] row group ordinal
      # @param index [Integer] leaf column index
      # @return [ModuleCrypto, nil] encryption of the chunk's modules, nil for a plaintext column
      # @raise [UnsupportedError] when +row_group+ is above MAX_ORDINAL
      def chunk(row_group, index)
        setting = @columns[index] or return nil
        if row_group > MAX_ORDINAL
          raise UnsupportedError, "Encrypted files hold at most #{MAX_ORDINAL + 1} row groups"
        end
        ModuleCrypto.new(setting.cipher, @file_aad, @ctr, row_group, index,
          "#{@schema.columns[index].dotted_path} (row group #{row_group})")
      end

      # Sets the crypto metadata of the encrypted column chunks, and encrypts their ColumnMetaData
      # when it is not protected by the footer: for columns with their own key, and in plaintext
      # footer mode, where the footer keeps a copy without statistics
      #
      # @param row_groups [Array<Format::RowGroup>] the file's row groups, changed in place
      # @return [void]
      def finish(row_groups)
        row_groups.each do |rg|
          rg.columns.each_with_index do |column_chunk, index|
            setting = @columns[index] or next
            meta = column_chunk.meta_data
            column_chunk.crypto_metadata = if setting.footer
              Format::ColumnCryptoMetaData.new(encryption_with_footer_key: Format::EncryptionWithFooterKey.new)
            else
              Format::ColumnCryptoMetaData.new(encryption_with_column_key: Format::EncryptionWithColumnKey.new(
                path_in_schema: meta.path_in_schema, key_metadata: setting.key_metadata
              ))
            end
            next if setting.footer && !@plaintext_footer
            column_chunk.encrypted_column_metadata = chunk(rg.ordinal, index).encrypt(COLUMN_META_DATA, meta.encode)
            column_chunk.meta_data = @plaintext_footer ? stripped(meta) : nil
          end
        end
      end

      # The bytes between the last data and the footer length: the encrypted footer after its
      # FileCryptoMetaData, or the plaintext footer and its signature
      #
      # @param meta [Format::FileMetaData] the footer; gets the algorithm in plaintext mode
      # @return [String]
      def footer(meta)
        crypto = ModuleCrypto.new(@footer.cipher, @file_aad, @ctr)
        if @plaintext_footer
          meta.encryption_algorithm = @algorithm
          meta.footer_signing_key_metadata = @footer_key_metadata
          bytes = meta.encode
          bytes << crypto.sign(bytes)
        else
          Format::FileCryptoMetaData.new(encryption_algorithm: @algorithm, key_metadata: @footer_key_metadata).encode <<
            crypto.encrypt(FOOTER, meta.encode)
        end
      end

      # @return [String] algorithm and footer mode, without keys
      def inspect
        "#<#{self.class.name} #{@ctr ? "aes_gcm_ctr" : "aes_gcm"} footer=#{@plaintext_footer ? "plaintext" : "encrypted"} " \
          "columns=#{@columns.count(&:itself)}/#{@columns.size}>"
      end

      private

      # @param key [String] checked key
      # @return [Cipher] one per distinct key, so encryptions are counted per key
      def cipher_for(key)
        @ciphers[key] ||= Cipher.new(key)
      end

      # @param requested [Hash{String => EncryptionConfiguration::ColumnKey, Symbol}, nil] the
      #   configuration's columns
      # @return [Array<ColumnKey, nil>] per leaf column
      # @raise [ArgumentError] for an unknown column, or a column named twice
      def column_keys(requested)
        return Array.new(@schema.columns.size, @footer) if requested.nil?
        out = Array.new(@schema.columns.size)
        requested.each do |name, setting|
          columns = Encryption.columns_named(@schema, name)
          raise ArgumentError, "encryption: no such column #{name.inspect}" if columns.empty?
          key = (setting == :footer) ? @footer : ColumnKey.new(cipher_for(setting.key), setting.key_metadata, false)
          columns.each do |col|
            raise ArgumentError, "encryption: column #{col.dotted_path} is listed twice" if out[col.index]
            out[col.index] = key
          end
        end
        out
      end

      # @param meta [Format::ColumnMetaData] the column's metadata
      # @return [Format::ColumnMetaData] a copy without statistics, for plaintext footers
      def stripped(meta)
        copy = Format::ColumnMetaData.decode(meta.encode).first
        copy.statistics = copy.encoding_stats = copy.size_statistics = nil
        copy
      end
    end

    # A DecryptionConfiguration applied to one file: finds the keys (given, or looked up by their
    # key metadata), checks the AAD prefix, decrypts the footer and the column metadata, and
    # hands out a ModuleCrypto per column chunk
    class FileDecryptor
      # @return [Format::EncryptionAlgorithm] the file's algorithm
      attr_reader :algorithm

      # @return [String, nil] key metadata of the footer key
      attr_reader :footer_key_metadata

      # @return [Boolean] whether the footer is stored in the clear (and signed)
      attr_reader :plaintext_footer

      # @param config [DecryptionConfiguration, nil] the keys; nil for none
      # @param algorithm [Format::EncryptionAlgorithm, nil] from the footer or the FileCryptoMetaData
      # @param footer_key_metadata [String, nil] key metadata of the footer key
      # @param plaintext_footer [Boolean] whether the footer is stored in the clear
      # @raise [UnsupportedError] for an unknown algorithm
      # @raise [DecryptionError] when the file needs an AAD prefix that was not given, or stores a
      #   different one
      def initialize(config, algorithm, footer_key_metadata: nil, plaintext_footer: false)
        config ||= DecryptionConfiguration.new
        settings = algorithm&.settings or raise UnsupportedError, "Unknown encryption algorithm"
        @algorithm = algorithm
        @footer_key_metadata = footer_key_metadata
        @plaintext_footer = plaintext_footer
        @ctr = !algorithm.aes_gcm_ctr_v1.nil?
        @footer_key = config.footer_key
        @column_keys = config.columns
        @resolver = config.keys
        supplied = config.aad_prefix
        stored = settings.aad_prefix
        if settings.supply_aad_prefix && supplied.nil?
          raise DecryptionError, "The file was encrypted with an AAD prefix it does not store: pass decryption: {aad_prefix: ...}"
        end
        if stored && supplied && stored != supplied
          raise DecryptionError, "decryption: aad_prefix #{supplied.inspect} does not match the file's #{stored.inspect}"
        end
        @aad_prefix_used = supplied || stored
        @file_aad = (@aad_prefix_used || "".b) + (settings.aad_file_unique || "".b)
        @ciphers = {}
        @resolved = {}
        @footer_verified = false
      end

      # @return [Symbol] +:aes_gcm+ or +:aes_gcm_ctr+
      def algorithm_name = @ctr ? :aes_gcm_ctr : :aes_gcm

      # @return [String, nil] the AAD prefix stored in the file
      def aad_prefix = @algorithm.settings.aad_prefix

      # @return [Boolean] whether the footer signature was checked (plaintext footers, with the key)
      def footer_verified? = @footer_verified

      # @return [String, nil] the footer key, given or looked up; nil when not available
      def footer_key
        @footer_key ||= resolve(@footer_key_metadata, :footer)
      end

      # @param mod [String] the encrypted footer module
      # @return [String] the serialized FileMetaData
      # @raise [DecryptionError] without the footer key, or when it does not decrypt
      def decrypt_footer(mod)
        key = footer_key or raise DecryptionError, "The footer is encrypted and no key was given for it" \
          "#{" (key metadata #{@footer_key_metadata.inspect})" if @footer_key_metadata}: pass decryption: {footer_key: ...} or {keys: ...}"
        ModuleCrypto.new(cipher_for(key), @file_aad, @ctr).decrypt(FOOTER, mod)
      end

      # Checks the signature of a plaintext footer, when the footer key is available (without it
      # the file is read like a legacy reader would)
      #
      # @param plain [String] the serialized FileMetaData
      # @param signature [String] nonce and tag stored after it
      # @return [void]
      # @raise [DecryptionError] when the signature does not match
      def verify_footer(plain, signature)
        key = footer_key or return
        unless ModuleCrypto.new(cipher_for(key), @file_aad, @ctr).signed?(plain, signature)
          raise DecryptionError, "The footer signature does not match: wrong footer key or AAD prefix, or the footer was changed"
        end
        @footer_verified = true
      end

      # Replaces the +meta_data+ of chunks whose ColumnMetaData is encrypted on its own, when
      # their key is available
      #
      # @param meta [Format::FileMetaData] the decoded footer, changed in place
      # @return [void]
      # @raise [DecryptionError] when a column's metadata does not decrypt with the key given for it
      def decrypt_column_metadata(meta)
        paths = nil
        (meta.row_groups || []).each_with_index do |rg, i|
          (rg.columns || []).each_with_index do |chunk, index|
            bytes = chunk.encrypted_column_metadata
            next unless chunk.crypto_metadata && bytes
            paths ||= column_paths(meta)
            cipher = chunk_cipher(chunk, paths[index]) or next
            mod = Encryption.length_prefixed(bytes)
            crypto = ModuleCrypto.new(cipher, @file_aad, @ctr, rg.ordinal || i, index, "#{paths[index]} (row group #{i})")
            chunk.meta_data = Format::ColumnMetaData.decode(crypto.decrypt(COLUMN_META_DATA, mod)).first
          end
        end
      rescue Thrift::Error => e
        raise FormatError, "Corrupt encrypted column metadata: #{e.message}"
      end

      # @param row_group [Integer] row group index in the footer
      # @param ordinal [Integer, nil] the row group's ordinal from the footer
      # @param column [Schema::Column] the leaf column
      # @param chunk [Format::ColumnChunk] its chunk in the row group
      # @return [ModuleCrypto, nil] decryption of the chunk's modules, nil for a plaintext chunk
      # @raise [DecryptionError] when the chunk is encrypted and its key is not available
      def chunk(row_group, ordinal, column, chunk)
        return nil unless chunk.crypto_metadata
        cipher = chunk_cipher(chunk, column.dotted_path) or raise DecryptionError, missing_key(column.dotted_path, chunk)
        ModuleCrypto.new(cipher, @file_aad, @ctr, ordinal || row_group, column.index,
          "#{column.dotted_path} (row group #{row_group})")
      end

      # How the file is encrypted, see Reader#encryption
      #
      # @param schema [Schema] the file's schema, to name the columns
      # @param chunks [Array<Format::ColumnChunk>] the column chunks of a row group
      # @return [Hash{Symbol => Object}]
      def describe(schema, chunks)
        columns = schema.columns.each_with_object({}) do |col, out|
          chunk = chunks[col.index]
          crypto = chunk&.crypto_metadata or next
          with_column_key = crypto.encryption_with_column_key
          out[col.dotted_path] = {
            key: with_column_key ? :column : :footer,
            key_metadata: with_column_key&.key_metadata,
            readable: !chunk_cipher(chunk, col.dotted_path).nil?
          }
        end
        {
          algorithm: algorithm_name, footer: @plaintext_footer ? :plaintext : :encrypted,
          footer_key_metadata: @footer_key_metadata, aad_prefix: aad_prefix,
          supply_aad_prefix: @algorithm.settings.supply_aad_prefix == true,
          footer_verified: @footer_verified, columns: columns
        }
      end

      # @param chunk [Format::ColumnChunk] the chunk's footer entry, with its crypto metadata
      # @param path [String] its column's dotted path
      # @return [String, nil] the chunk's key, nil when it is not encrypted or the key is not available
      def chunk_key(chunk, path)
        crypto = chunk.crypto_metadata or return nil
        if crypto.encryption_with_column_key
          column_key(path, crypto.encryption_with_column_key.key_metadata)
        else
          footer_key
        end
      end

      # The configuration of a file encrypted like this one (see Redaction)
      #
      # @param columns [Hash{String => Hash, Symbol}, nil] encrypted columns of the new file, as the
      #   +columns:+ setting; nil to encrypt them all with the footer key
      # @return [EncryptionConfiguration]
      # @raise [DecryptionError] when the footer key is not available
      def writer_settings(columns)
        key = footer_key or raise DecryptionError, "The output is encrypted like the input, which needs the footer key: " \
          "pass it in decryption:, or pass encryption: for the output"
        settings = {footer_key: key, footer_key_metadata: @footer_key_metadata, plaintext_footer: @plaintext_footer,
                    algorithm: algorithm_name, columns: columns}
        if @aad_prefix_used
          settings[:aad_prefix] = @aad_prefix_used
          settings[:store_aad_prefix] = false if @algorithm.settings.supply_aad_prefix
        end
        EncryptionConfiguration.new(**settings)
      end

      # @return [String] algorithm and footer mode, without keys
      def inspect
        "#<#{self.class.name} #{algorithm_name} footer=#{@plaintext_footer ? "plaintext" : "encrypted"}>"
      end

      private

      # @param chunk [Format::ColumnChunk] an encrypted chunk
      # @param path [String] its column's dotted path
      # @return [Cipher, nil] nil when the key is not available
      def chunk_cipher(chunk, path)
        key = chunk_key(chunk, path)
        key && cipher_for(key)
      end

      # @param path [String] dotted column path
      # @param key_metadata [String, nil] the column's key metadata
      # @return [String, nil] the given key for the column (or a field holding it), else the
      #   looked-up one
      def column_key(path, key_metadata)
        @column_keys.each do |name, key|
          return key if path == name || path.start_with?("#{name}.")
        end
        resolve(key_metadata, path)
      end

      # @param key_metadata [String, nil] stored key metadata
      # @param owner [Symbol, String] what the key is for: +:footer+ or a dotted column path
      # @return [String, nil] the key from the +keys:+ resolver, nil when there is none. Keys
      #   without key metadata are looked up per owner.
      # @raise [ArgumentError] when the resolver returns something that is not a key
      def resolve(key_metadata, owner)
        return nil unless @resolver
        return nil if key_metadata.nil? && !@resolver.respond_to?(:call)
        cache = key_metadata || [:owner, owner]
        @resolved.fetch(cache) do
          key = if @resolver.respond_to?(:call)
            one_argument?(@resolver) ? @resolver.call(key_metadata) : @resolver.call(key_metadata, owner)
          else
            @resolver[key_metadata]
          end
          what = (owner == :footer) ? "the footer" : owner
          key &&= Encryption.check_key!(key, "decryption: keys: the key for #{what}")
          @resolved[cache] = key
        end
      end

      # @param callable [#call] the +keys:+ resolver
      # @return [Boolean] whether it only takes the key metadata (procs drop extra arguments)
      def one_argument?(callable)
        callable = callable.method(:call) unless callable.is_a?(Proc) || callable.is_a?(Method)
        return false if callable.is_a?(Proc) && !callable.lambda?
        callable.arity == 1
      end

      # @param key [String] 16, 24 or 32 bytes
      # @return [Cipher] one per distinct key
      def cipher_for(key)
        @ciphers[key] ||= Cipher.new(key)
      end

      # Dotted paths of the leaf columns, by column ordinal
      #
      # @param meta [Format::FileMetaData] the footer
      # @return [Array<String>]
      def column_paths(meta)
        Schema.from_elements(meta.schema).columns.map(&:dotted_path)
      end

      # @param path [String] dotted column path
      # @param chunk [Format::ColumnChunk] the encrypted chunk whose key is missing
      # @return [String] what is missing, and how to give it
      def missing_key(path, chunk)
        with_column_key = chunk.crypto_metadata.encryption_with_column_key
        metadata = with_column_key ? with_column_key.key_metadata : @footer_key_metadata
        whose = with_column_key ? "its key" : "the footer key"
        "Column #{path} is encrypted and #{whose} was not given#{" (key metadata #{metadata.inspect})" if metadata}: " \
          "pass decryption: {#{with_column_key ? "columns: {#{path.inspect} => key}" : "footer_key: ..."}} or {keys: ...}, " \
          "or leave the column out with columns:"
      end
    end

    # A module stored in a Thrift binary field, with its length prefix (as parquet-mr and Arrow
    # write it) or without
    #
    # @param bytes [String] the field's value
    # @return [String] the module with its length prefix
    def length_prefixed(bytes)
      return bytes if bytes.bytesize >= 4 && bytes.unpack1("V") == bytes.bytesize - 4
      [bytes.bytesize].pack("V") + bytes
    end
  end
end
