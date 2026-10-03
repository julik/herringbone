# frozen_string_literal: true

module Herringbone
  # How Writer encrypts a file (Parquet modular encryption), checked as soon as it is built. The
  # +encryption:+ option of Writer, Herringbone.write, SimpleWriter and Herringbone.redact takes
  # one, or a Hash of the same keywords, which is turned into one with EncryptionConfiguration.from.
  #
  #   config = Herringbone::EncryptionConfiguration.new(
  #     footer_key: FOOTER_KEY, footer_key_metadata: "orders-footer",
  #     columns: { "ssn" => { key: SSN_KEY, key_metadata: "pii" }, "email" => :footer }
  #   )
  #   Herringbone::Writer.open(io, schema, encryption: config) { |w| ... }
  #
  # Which column names exist is only known once the schema is, so unknown columns raise when the
  # Writer is created. Instances are frozen, and #inspect leaves the keys out.
  class EncryptionConfiguration
    # Values of +algorithm:+: AES_GCM_V1 and AES_GCM_CTR_V1
    ALGORITHMS = %i[aes_gcm aes_gcm_ctr].freeze

    # A column encrypted with a key of its own
    #
    # @!attribute [r] key
    #   @return [String] 16, 24 or 32 bytes, binary
    # @!attribute [r] key_metadata
    #   @return [String, nil] stored with the column, for readers to find the key by
    ColumnKey = Struct.new(:key, :key_metadata) do
      # @return [String] the key metadata, without the key
      def inspect = "#<ColumnKey AES-#{key.bytesize * 8} key_metadata=#{key_metadata.inspect}>"
      alias_method :to_s, :inspect
    end

    # @return [String] key of the footer, and of the columns encrypted with it (binary)
    attr_reader :footer_key

    # @return [String, nil] stored for the footer key, for readers to find it by
    attr_reader :footer_key_metadata

    # @return [Hash{String => ColumnKey, Symbol}, nil] column path or field name => its own key, or
    #   +:footer+ for the footer key; nil when every column is encrypted with the footer key
    attr_reader :columns

    # @return [Symbol] +:aes_gcm+ (AES_GCM_V1) or +:aes_gcm_ctr+ (AES_GCM_CTR_V1, pages with AES-CTR)
    attr_reader :algorithm

    # @return [String, nil] identity of the file, part of the AAD of every encrypted module
    attr_reader :aad_prefix

    # Encryption that the most Parquet readers can decrypt given nothing but the key: every
    # column and the footer encrypted with one key, AES_GCM_V1, no AAD prefix. The key's id is
    # stored in the file, so a reader holding several keys picks the right one. Passing a Key or
    # the bytes of a key as +encryption:+ does the same.
    #
    #   key = Herringbone::Key.generate
    #   Herringbone.write(io, rows, encryption: key)
    #   Herringbone::Reader.new(io, decryption: key)              # or [key, older_key, ...]
    #
    # Readers that take the key alone: pyarrow 25+
    # (+pyarrow.parquet.encryption.create_decryption_properties(key.bytes)+), Arrow C++, arrow-go
    # and ParquetSharp (as the footer key, or by id with a string key id retriever), arrow-rs and
    # DataFusion, Trino 478+, and parquet-java / Spark with a decryption properties factory that
    # returns the key.
    #
    # The finer settings are left out on purpose: pyarrow's single-key API, arrow-rs and DuckDB
    # read neither per-column keys nor AES-CTR, DuckDB needs an encrypted footer and no AAD
    # prefix, and arrow-rs has no 192-bit keys.
    #
    # @param key [Key, String] the key, or its bytes (the id is then the key's fingerprint)
    # @return [EncryptionConfiguration]
    # @raise [ArgumentError] when the key is not 16 or 32 bytes long
    def self.simple(key)
      key = Key.from(key)
      if key.bits == 192
        raise ArgumentError, "encryption: use a 128 or 256-bit key: arrow-rs and DataFusion cannot read 192-bit keys"
      end
      new(footer_key: key)
    end

    # Turns the +encryption:+ option into a configuration
    #
    # @param value [EncryptionConfiguration, Hash{Symbol, String => Object}, Key, String] a
    #   configuration, the keywords of #initialize, or a key (see .simple)
    # @return [EncryptionConfiguration]
    # @raise [ArgumentError] for anything else, and for invalid settings
    def self.from(value)
      case value
      when EncryptionConfiguration then value
      when Key, String then simple(value)
      when Hash
        options = value.transform_keys(&:to_sym)
        unknown = options.keys - instance_method(:initialize).parameters.map(&:last)
        raise ArgumentError, "encryption: unknown option #{unknown.join(", ")}" unless unknown.empty?
        new(**options)
      else
        raise ArgumentError, "encryption: expected a Herringbone::Key, an EncryptionConfiguration or a Hash, got #{value.class}"
      end
    end

    # @param footer_key [Key, String] the key, or 16, 24 or 32 bytes (AES-128, 192 or 256); required
    # @param footer_key_metadata [String, nil] stored in the file for the footer key; defaults to
    #   the id of a Key
    # @param columns [Hash{String, Symbol, Array<String> => String, Hash, Symbol}, nil] column path
    #   (+"address.city"+) or field name (all of its columns) => a Key (stored with its id), the
    #   bytes of a key, +{key:, key_metadata:}+, or +:footer+ for the footer key. Columns left out are not encrypted; nil encrypts them all
    #   with the footer key.
    # @param plaintext_footer [Boolean] store the footer in the clear (signed with the footer key),
    #   so readers without keys can read the plaintext columns; it then keeps no statistics of the
    #   encrypted columns
    # @param algorithm [Symbol] +:aes_gcm+ or +:aes_gcm_ctr+, which encrypts pages with AES-CTR:
    #   faster, but page contents are not authenticated
    # @param aad_prefix [String, nil] identity of the file (a table and partition name, say), which
    #   binds the encrypted modules to it
    # @param store_aad_prefix [Boolean] false leaves the AAD prefix out of the file, so readers must
    #   supply it
    # @raise [ArgumentError] for a key of the wrong size, a bad column setting, an unknown algorithm,
    #   or +store_aad_prefix: false+ without an AAD prefix
    def initialize(footer_key: nil, footer_key_metadata: nil, columns: nil, plaintext_footer: false,
      algorithm: :aes_gcm, aad_prefix: nil, store_aad_prefix: true)
      footer_key_metadata ||= footer_key.id if footer_key.is_a?(Key)
      footer_key = footer_key.bytes if footer_key.is_a?(Key)
      @footer_key = Encryption.check_key!(footer_key, "encryption: footer_key").freeze
      @footer_key_metadata = footer_key_metadata&.to_s&.b&.freeze
      @columns = columns.nil? ? nil : column_settings(columns)
      @plaintext_footer = plaintext_footer ? true : false
      algorithm = algorithm.to_sym if algorithm.is_a?(String)
      unless ALGORITHMS.include?(algorithm)
        raise ArgumentError, "encryption: algorithm must be :aes_gcm or :aes_gcm_ctr, got #{algorithm.inspect}"
      end
      @algorithm = algorithm
      @aad_prefix = aad_prefix&.to_s&.b&.freeze
      @store_aad_prefix = store_aad_prefix ? true : false
      raise ArgumentError, "encryption: store_aad_prefix: false needs an aad_prefix" if !@store_aad_prefix && @aad_prefix.nil?
      freeze
    end

    # @return [Boolean] whether the footer is stored in the clear (and signed)
    def plaintext_footer? = @plaintext_footer

    # @return [Boolean] whether the file stores the AAD prefix (false: readers must supply it)
    def store_aad_prefix? = @store_aad_prefix

    # @return [Boolean] whether every column is encrypted with the footer key
    def uniform? = @columns.nil?

    # @return [Hash{Symbol => Object}] the settings as keywords of #initialize, keys included
    def to_h
      {
        footer_key: @footer_key, footer_key_metadata: @footer_key_metadata,
        columns: @columns&.transform_values { |v| v.is_a?(ColumnKey) ? v.to_h : v },
        plaintext_footer: @plaintext_footer, algorithm: @algorithm, aad_prefix: @aad_prefix,
        store_aad_prefix: @store_aad_prefix
      }
    end

    # @param other [Object] object to compare with
    # @return [Boolean] whether +other+ is a configuration with the same settings and keys
    def ==(other) = other.is_a?(EncryptionConfiguration) && other.to_h == to_h

    # @return [String] the settings, without keys
    def inspect
      columns = if @columns
        @columns.map { |name, v| "#{name}=#{v.is_a?(ColumnKey) ? (v.key_metadata || "key").inspect : v}" }.join(",")
      else
        "all"
      end
      "#<#{self.class.name} #{@algorithm} footer=#{@plaintext_footer ? "plaintext" : "encrypted"}" \
        "#{" footer_key_metadata=#{@footer_key_metadata.inspect}" if @footer_key_metadata} columns=#{columns}" \
        "#{" aad_prefix=#{@aad_prefix.inspect}#{" (not stored)" unless @store_aad_prefix}" if @aad_prefix}>"
    end
    alias_method :to_s, :inspect

    private

    # @param columns [Hash] the +columns:+ argument
    # @return [Hash{String => ColumnKey, Symbol}] frozen, keyed by dotted path or field name
    # @raise [ArgumentError] for a bad setting or a name given twice
    def column_settings(columns)
      raise ArgumentError, "encryption: columns: expected a Hash, got #{columns.class}" unless columns.is_a?(Hash)
      out = {}
      columns.each do |name, setting|
        name = name.is_a?(Array) ? name.join(".") : name.to_s
        raise ArgumentError, "encryption: column #{name} is listed twice" if out.key?(name)
        out[name.freeze] = case setting
        when :footer, true then :footer
        when String then ColumnKey.new(Encryption.check_key!(setting, "encryption: key of #{name}").freeze, nil).freeze
        when Key then ColumnKey.new(setting.bytes, setting.id.b.freeze).freeze
        when ColumnKey then column_key(name, setting.to_h)
        when Hash then column_key(name, setting.transform_keys(&:to_sym))
        else
          raise ArgumentError, "encryption: expected a key, {key:, key_metadata:} or :footer for #{name}, got #{setting.class}"
        end
      end
      out.freeze
    end

    # @param name [String] the column
    # @param setting [Hash{Symbol => Object}] +key:+ and +key_metadata:+
    # @return [ColumnKey]
    # @raise [ArgumentError] for unknown settings or a key of the wrong size
    def column_key(name, setting)
      unknown = setting.keys - ColumnKey.members
      raise ArgumentError, "encryption: unknown option #{unknown.join(", ")} for #{name}" unless unknown.empty?
      if setting[:key].is_a?(Key)
        setting = {key_metadata: setting[:key].id}.merge(setting.compact).merge(key: setting[:key].bytes)
      end
      key = Encryption.check_key!(setting[:key], "encryption: key of #{name}").freeze
      ColumnKey.new(key, setting[:key_metadata]&.to_s&.b&.freeze).freeze
    end
  end

  # The keys Reader (and Inspector, Herringbone.redact) needs for an encrypted file. The
  # +decryption:+ option takes one, a Hash of the same keywords, a Key (or an Array of them, a
  # keyring), or a callable that returns the key for a key id (see DecryptionConfiguration.from).
  #
  #   Herringbone::Reader.new(io, decryption: key)
  #   Herringbone::Reader.new(io, decryption: [key, older_key])        # picked by the id in the file
  #   Herringbone::Reader.new(io, decryption: ->(key_id) { vault.read("parquet/#{key_id}") })
  #
  #   Herringbone::DecryptionConfiguration.new(footer_key: FOOTER_KEY, columns: { "ssn" => SSN_KEY })
  #   Herringbone::DecryptionConfiguration.new(keys: { "2026-10" => KEY })
  #   Herringbone::DecryptionConfiguration.new(keys: ->(key_id) { vault.read("parquet/#{key_id}") })
  #
  # Explicit keys win; the others are looked up with +keys:+. Instances are frozen, and #inspect
  # leaves the keys out.
  class DecryptionConfiguration
    # @return [String, nil] key of the footer (and of the columns encrypted with it), binary
    attr_reader :footer_key

    # @return [Hash{String => String}] column path or field name => key
    attr_reader :columns

    # @return [#call, Hash{String => String}, nil] looks keys up by their key metadata
    attr_reader :keys

    # @return [String, nil] the file's AAD prefix: needed when the file does not store it, and
    #   checked against the stored one otherwise
    attr_reader :aad_prefix

    # Turns the +decryption:+ option into a configuration
    #
    # A keyring (a Key, the bytes of a key, or an Array of those) looks keys up by the id stored
    # in the file; a single key is also used when the file names no id or another one, as for
    # files from tools that store none.
    #
    # @param value [DecryptionConfiguration, Hash{Symbol, String => Object}, Key, String,
    #   Array<Key, String>, #call, nil] a configuration, the keywords of #initialize, a keyring,
    #   a callable to use as +keys:+, or nil
    # @return [DecryptionConfiguration, nil] nil for nil
    # @raise [ArgumentError] for anything else, and for invalid settings
    def self.from(value)
      return new(keys: value) if value.respond_to?(:call)
      case value
      when nil, DecryptionConfiguration then value
      when Key, String then from([value])
      when Array
        keys = value.map { |key| Key.from(key) }
        raise ArgumentError, "decryption: the keyring is empty" if keys.empty?
        new(footer_key: (keys.size == 1) ? keys.first : nil, keys: keys.to_h { |key| [key.id, key] })
      when Hash
        options = value.transform_keys(&:to_sym)
        unknown = options.keys - instance_method(:initialize).parameters.map(&:last)
        raise ArgumentError, "decryption: unknown option #{unknown.join(", ")}" unless unknown.empty?
        new(**options)
      else
        raise ArgumentError, "decryption: expected a Herringbone::Key, a DecryptionConfiguration, a Hash or a callable, got #{value.class}"
      end
    end

    # @param footer_key [Key, String, nil] 16, 24 or 32 bytes
    # @param columns [Hash{String, Symbol, Array<String> => Key, String}] column path or field name => key
    # @param keys [#call, Hash{String => Key, String}, nil] key metadata (a Key's id) => key, for the
    #   keys not given above. A callable gets the key metadata stored for the key (nil when the
    #   file stores none) and, when it takes a second parameter, what the key is for: +:footer+ or
    #   the dotted path of the column. It returns the key (a Key or bytes), or nil when it is not
    #   available. Each key is looked up once per Reader.
    # @param aad_prefix [String, nil] the file's AAD prefix
    # @raise [ArgumentError] for a key of the wrong size, or +keys:+ that is neither a Hash nor callable
    def initialize(footer_key: nil, columns: {}, keys: nil, aad_prefix: nil)
      footer_key = footer_key.bytes if footer_key.is_a?(Key)
      @footer_key = footer_key && Encryption.check_key!(footer_key, "decryption: footer_key").freeze
      raise ArgumentError, "decryption: columns: expected a Hash, got #{columns.class}" unless columns.is_a?(Hash)
      @columns = columns.to_h do |name, key|
        name = name.is_a?(Array) ? name.join(".") : name.to_s
        key = key.bytes if key.is_a?(Key)
        [name.freeze, Encryption.check_key!(key, "decryption: key of #{name}").freeze]
      end.freeze
      if keys && !keys.respond_to?(:call) && !keys.is_a?(Hash)
        raise ArgumentError, "decryption: keys: expected a Hash or a callable, got #{keys.class}"
      end
      @keys = keys
      @aad_prefix = aad_prefix&.to_s&.b&.freeze
      freeze
    end

    # @return [String] what is configured, without keys
    def inspect
      "#<#{self.class.name}#{" footer_key" if @footer_key}" \
        "#{" columns=#{@columns.keys.join(",")}" unless @columns.empty?}" \
        "#{" keys=#{@keys.is_a?(Hash) ? "Hash" : "callable"}" if @keys}" \
        "#{" aad_prefix=#{@aad_prefix.inspect}" if @aad_prefix}>"
    end
    alias_method :to_s, :inspect
  end
end
