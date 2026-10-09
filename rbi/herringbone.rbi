# typed: strong
# Pure-Ruby reader and writer for Apache Parquet files
module Herringbone
  VERSION = T.let(T.unsafe(nil), String)

  # Loads every part of Herringbone now instead of on first use. Ractors cannot autoload before
  # Ruby 3.4, so call this before starting Ractors that use Herringbone there; it also moves the
  # loading out of the first request in a forking server.
  sig { void }
  def self.eager_load!; end

  # Writes +records+ to +io+ (any IO responding to #write; Herringbone never opens files by path)
  # and returns the number of rows written. +records+ is an Enumerable of rows, or an ActiveRecord
  # model or relation, which is read with find_each. Without +schema+, the schema comes from the
  # model's columns (Schema.from_active_record) or is inferred from the first rows (Schema.infer);
  # fields declared in the block replace inferred ones. +records+ is iterated once, so a source
  # that can only be read once (a cursor, a lazy Enumerator over an IO) works too. Other options go
  # to Writer.
  # 
  #   File.open("orders.parquet", "wb") { |f| Herringbone.write(f, Order.where(created_at: 1.year.ago..)) }
  #   Herringbone.write(io, events.lazy.map(&:to_h)) { |s| s.json :payload }
  # 
  # _@param_ `io` — destination; written sequentially, never closed
  # 
  # _@param_ `records` — rows (Hashes, Arrays in schema order, or objects responding to #attributes or #to_h), or an ActiveRecord model or relation
  # 
  # _@param_ `schema` — schema to write with; derived from +records+ when nil
  # 
  # _@param_ `options` — passed to Writer.new
  # 
  # _@return_ — number of rows written
  sig do
    params(
      io: T.any(IO, T.untyped),
      records: T.any(T::Enumerable[T.any(T::Hash[T.untyped, T.untyped], T::Array[T.untyped], Object)], Class, T.untyped),
      schema: T.nilable(Schema),
      options: T::Hash[Symbol, Object],
      overrides: T.proc.params(s: Schema::Builder).void
    ).returns(Integer)
  end
  def write(io, records, schema: nil, **options, &overrides); end

  # Writes +records+ to +io+ (any IO responding to #write; Herringbone never opens files by path)
  # and returns the number of rows written. +records+ is an Enumerable of rows, or an ActiveRecord
  # model or relation, which is read with find_each. Without +schema+, the schema comes from the
  # model's columns (Schema.from_active_record) or is inferred from the first rows (Schema.infer);
  # fields declared in the block replace inferred ones. +records+ is iterated once, so a source
  # that can only be read once (a cursor, a lazy Enumerator over an IO) works too. Other options go
  # to Writer.
  # 
  #   File.open("orders.parquet", "wb") { |f| Herringbone.write(f, Order.where(created_at: 1.year.ago..)) }
  #   Herringbone.write(io, events.lazy.map(&:to_h)) { |s| s.json :payload }
  # 
  # _@param_ `io` — destination; written sequentially, never closed
  # 
  # _@param_ `records` — rows (Hashes, Arrays in schema order, or objects responding to #attributes or #to_h), or an ActiveRecord model or relation
  # 
  # _@param_ `schema` — schema to write with; derived from +records+ when nil
  # 
  # _@param_ `options` — passed to Writer.new
  # 
  # _@return_ — number of rows written
  sig do
    params(
      io: T.any(IO, T.untyped),
      records: T.any(T::Enumerable[T.any(T::Hash[T.untyped, T.untyped], T::Array[T.untyped], Object)], Class, T.untyped),
      schema: T.nilable(Schema),
      options: T::Hash[Symbol, Object],
      overrides: T.proc.params(s: Schema::Builder).void
    ).returns(Integer)
  end
  def self.write(io, records, schema: nil, **options, &overrides); end

  # Rewrites +io_or_reader+ into +output_io+ with rows removed or values replaced, building the
  # Redaction from the block (or taking +redaction+). A shortcut for Redaction#apply.
  # 
  #   Herringbone.redact(io, output_io) do |r|
  #     r.where(user_id: 42).delete
  #     r.replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", KEY, email) }
  #   end
  # 
  # _@param_ `io_or_reader` — the Parquet file, read with #seek and #read, or a Reader of it, whose IO and decryption are used; not closed
  # 
  # _@param_ `output_io` — destination, written sequentially; not closed
  # 
  # _@param_ `redaction` — the redaction to apply, instead of a block
  # 
  # _@param_ `writer_options` — Writer options for re-encoded column chunks, and +metadata:+ to replace the footer key/value metadata, see Redaction#apply
  # 
  # _@return_ — what was done
  sig do
    params(
      io_or_reader: T.any(IO, StringIO, Reader),
      output_io: T.any(IO, T.untyped),
      redaction: T.nilable(Redaction),
      writer_options: T::Hash[Symbol, Object],
      block: T.proc.params(r: Redaction).void
    ).returns(Redaction::Report)
  end
  def redact(io_or_reader, output_io, redaction = nil, **writer_options, &block); end

  # Rewrites +io_or_reader+ into +output_io+ with rows removed or values replaced, building the
  # Redaction from the block (or taking +redaction+). A shortcut for Redaction#apply.
  # 
  #   Herringbone.redact(io, output_io) do |r|
  #     r.where(user_id: 42).delete
  #     r.replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", KEY, email) }
  #   end
  # 
  # _@param_ `io_or_reader` — the Parquet file, read with #seek and #read, or a Reader of it, whose IO and decryption are used; not closed
  # 
  # _@param_ `output_io` — destination, written sequentially; not closed
  # 
  # _@param_ `redaction` — the redaction to apply, instead of a block
  # 
  # _@param_ `writer_options` — Writer options for re-encoded column chunks, and +metadata:+ to replace the footer key/value metadata, see Redaction#apply
  # 
  # _@return_ — what was done
  sig do
    params(
      io_or_reader: T.any(IO, StringIO, Reader),
      output_io: T.any(IO, T.untyped),
      redaction: T.nilable(Redaction),
      writer_options: T::Hash[Symbol, Object],
      block: T.proc.params(r: Redaction).void
    ).returns(Redaction::Report)
  end
  def self.redact(io_or_reader, output_io, redaction = nil, **writer_options, &block); end

  # Concatenates Parquet files into +output_io+: every row group of every input, in order. A
  # shortcut for Combiner. Column chunks are copied byte for byte (only offsets are rebased)
  # wherever the output stores a column's values as the input does, so files with the same schema
  # are combined without decoding anything.
  # 
  #   Herringbone.combine([jan, feb, mar], output_io)                      # the same schema
  #   Herringbone.combine([old, new], output_io, schema: :union)           # all fields, nulls in the gaps
  #   Herringbone.combine([a, b], output_io, schema: :intersect)           # the fields all inputs have
  # 
  # Without +schema:+ every input must have the schema of the first (see Schema#==). With
  # +schema: :union+ the output has the fields of all inputs, widened as Schema#union widens them,
  # and fields an input lacks are written as nulls. With +schema: :intersect+ it has the fields all
  # inputs have, and the others are dropped. A Schema given as +schema:+ must hold every input: each
  # must have the same fields or fewer, in the same or narrower types. Every input is checked
  # before anything is written, and IncompatibleSchema lists all that do not fit.
  # 
  # The output is encrypted like the encrypted inputs, if any (plaintext inputs included), unless
  # +encryption:+ says otherwise; +encryption: false+ writes it in plaintext. Inputs encrypted
  # differently need +encryption:+. Herringbone never opens files by path: pass open IOs, which
  # are read twice (footers first, then chunks), so keep them open until +combine+ returns and
  # mind the limit on open files when combining very many of them.
  # 
  # _@param_ `ios_or_readers` — the Parquet files: IOs read with #seek and #read, or Readers, which bring their own decryption; enumerated once, none is closed
  # 
  # _@param_ `output_io` — destination, written sequentially; not closed
  # 
  # _@param_ `schema` — +:union+, +:intersect+, a Schema every input fits, or nil to require the inputs to have the same schema
  # 
  # _@param_ `decryption` — keys of encrypted inputs given as IOs, see Reader.new
  # 
  # _@param_ `writer_options` — Writer options for chunks encoded again (and written nulls), +metadata:+ and +encryption:+
  # 
  # _@return_ — rows written, how many row groups were copied or rewritten, and per
  # input which fields were filled with nulls, widened or dropped
  sig do
    params(
      ios_or_readers: T::Enumerable[T.any(IO, StringIO, Reader)],
      output_io: T.any(IO, T.untyped),
      schema: T.nilable(T.any(Schema, Symbol)),
      decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object], T::Array[T.untyped], T.untyped)),
      writer_options: T::Hash[Symbol, Object]
    ).returns(Combiner::Report)
  end
  def combine(ios_or_readers, output_io, schema: nil, decryption: nil, **writer_options); end

  # Concatenates Parquet files into +output_io+: every row group of every input, in order. A
  # shortcut for Combiner. Column chunks are copied byte for byte (only offsets are rebased)
  # wherever the output stores a column's values as the input does, so files with the same schema
  # are combined without decoding anything.
  # 
  #   Herringbone.combine([jan, feb, mar], output_io)                      # the same schema
  #   Herringbone.combine([old, new], output_io, schema: :union)           # all fields, nulls in the gaps
  #   Herringbone.combine([a, b], output_io, schema: :intersect)           # the fields all inputs have
  # 
  # Without +schema:+ every input must have the schema of the first (see Schema#==). With
  # +schema: :union+ the output has the fields of all inputs, widened as Schema#union widens them,
  # and fields an input lacks are written as nulls. With +schema: :intersect+ it has the fields all
  # inputs have, and the others are dropped. A Schema given as +schema:+ must hold every input: each
  # must have the same fields or fewer, in the same or narrower types. Every input is checked
  # before anything is written, and IncompatibleSchema lists all that do not fit.
  # 
  # The output is encrypted like the encrypted inputs, if any (plaintext inputs included), unless
  # +encryption:+ says otherwise; +encryption: false+ writes it in plaintext. Inputs encrypted
  # differently need +encryption:+. Herringbone never opens files by path: pass open IOs, which
  # are read twice (footers first, then chunks), so keep them open until +combine+ returns and
  # mind the limit on open files when combining very many of them.
  # 
  # _@param_ `ios_or_readers` — the Parquet files: IOs read with #seek and #read, or Readers, which bring their own decryption; enumerated once, none is closed
  # 
  # _@param_ `output_io` — destination, written sequentially; not closed
  # 
  # _@param_ `schema` — +:union+, +:intersect+, a Schema every input fits, or nil to require the inputs to have the same schema
  # 
  # _@param_ `decryption` — keys of encrypted inputs given as IOs, see Reader.new
  # 
  # _@param_ `writer_options` — Writer options for chunks encoded again (and written nulls), +metadata:+ and +encryption:+
  # 
  # _@return_ — rows written, how many row groups were copied or rewritten, and per
  # input which fields were filled with nulls, widened or dropped
  sig do
    params(
      ios_or_readers: T::Enumerable[T.any(IO, StringIO, Reader)],
      output_io: T.any(IO, T.untyped),
      schema: T.nilable(T.any(Schema, Symbol)),
      decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object], T::Array[T.untyped], T.untyped)),
      writer_options: T::Hash[Symbol, Object]
    ).returns(Combiner::Report)
  end
  def self.combine(ios_or_readers, output_io, schema: nil, decryption: nil, **writer_options); end

  # Compression codecs this process can read and write, e.g. [:none, :snappy, :gzip, :lz4, :lz4_hadoop, :zstd].
  # :zstd and :brotli are listed when the zstd-ruby / brotli gems are loaded.
  # 
  # _@return_ — codec names accepted by the writer's +compression:+ option
  sig { returns(T::Array[Symbol]) }
  def codecs; end

  # Compression codecs this process can read and write, e.g. [:none, :snappy, :gzip, :lz4, :lz4_hadoop, :zstd].
  # :zstd and :brotli are listed when the zstd-ruby / brotli gems are loaded.
  # 
  # _@return_ — codec names accepted by the writer's +compression:+ option
  sig { returns(T::Array[Symbol]) }
  def self.codecs; end

  # Base class of every error Herringbone raises on purpose
  class Error < StandardError
  end

  # The file is not valid Parquet (bad metadata, corrupt pages...)
  class FormatError < Herringbone::Error
  end

  # A value cannot be written to its column
  class EncodeError < Herringbone::Error
    # _@param_ `message` — the error message
    # 
    # _@param_ `row` — index of the row being written
    # 
    # _@param_ `column` — dotted path of the column
    # 
    # _@param_ `value` — the value that could not be written
    sig do
      params(
        message: T.nilable(String),
        row: T.nilable(Integer),
        column: T.nilable(String),
        value: T.nilable(Object)
      ).void
    end
    def initialize(message = nil, row: nil, column: nil, value: nil); end

    # _@return_ — index of the row being written (0 for the first), when known
    sig { returns(T.nilable(Integer)) }
    attr_reader :row

    # _@return_ — dotted path of the column the value was meant for, when known
    sig { returns(T.nilable(String)) }
    attr_reader :column

    # _@return_ — the value that could not be written (nil when it was a missing required value)
    sig { returns(Object) }
    attr_reader :value
  end

  # A row does not fit a schema that was inferred from earlier rows (Herringbone.write without
  # +schema:+, SimpleWriter). The message says what was inferred, from how many rows, and how to
  # declare the column instead.
  class SchemaMismatch < Herringbone::EncodeError
  end

  # The file (or the writer configuration) uses a Parquet feature Herringbone does not implement,
  # such as a codec whose library is unavailable
  class UnsupportedError < Herringbone::Error
  end

  # Schemas that do not fit together: two schemas that cannot be united or intersected
  # (Schema#union, Schema#intersect), or inputs of Herringbone.combine that do not fit the output
  # schema or each other. The message lists every field that does not fit, one per line, e.g.
  # 
  #   Cannot unite the schemas, 2 fields do not fit:
  #     price: int64 vs double (int64 does not fit a double exactly)
  #     address.zip: int32 vs string (no common type)
  class IncompatibleSchema < Herringbone::Error
    # _@param_ `conflicts` — the fields that do not fit
    # 
    # _@param_ `operation` — what was attempted, "unite" or "intersect", for the message
    # 
    # _@param_ `message` — the message, instead of one built from +operation+
    sig { params(conflicts: T::Array[Conflict], operation: T.nilable(String), message: T.nilable(String)).void }
    def initialize(conflicts, operation: nil, message: nil); end

    # _@return_ — every field that does not fit, in schema (and input) order
    sig { returns(T::Array[Conflict]) }
    attr_reader :conflicts

    # A field that does not fit: its dotted path, how each side declares it, why the two do not
    # fit, and for Herringbone.combine the position of the input it was found in
    class Conflict < Struct
      # _@return_ — e.g. "address.zip: int32 vs string (no common type)"
      sig { returns(String) }
      def to_s; end

      # Returns the value of attribute path
      sig { returns(Object) }
      attr_accessor :path

      # Returns the value of attribute left
      sig { returns(Object) }
      attr_accessor :left

      # Returns the value of attribute right
      sig { returns(Object) }
      attr_accessor :right

      # Returns the value of attribute reason
      sig { returns(Object) }
      attr_accessor :reason

      # Returns the value of attribute input
      sig { returns(Object) }
      attr_accessor :input
    end
  end

  # An encrypted file or column cannot be read: its key was not given, the key or AAD prefix is
  # wrong, or the encrypted bytes were changed
  class DecryptionError < Herringbone::Error
  end

  # Pure-Ruby compression codecs for Parquet pages: Snappy, and LZ4 (raw blocks and the Hadoop framing).
  # Compression dispatches to these; GZIP uses Zlib and ZSTD/BROTLI use external gems.
  module Codecs
    # Pure-Ruby LZ4: raw block format (Parquet LZ4_RAW), Hadoop-framed blocks
    # (Parquet's deprecated LZ4) and a decoder for the LZ4 frame format.
    # 
    # @api private
    module LZ4
      # Decompress a raw LZ4 block that must expand to exactly uncompressed_size bytes.
      # 
      # _@param_ `input` — raw LZ4 block
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def decompress_block(input, uncompressed_size); end

      # Decompress a raw LZ4 block that must expand to exactly uncompressed_size bytes.
      # 
      # _@param_ `input` — raw LZ4 block
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def self.decompress_block(input, uncompressed_size); end

      # Parquet LZ4 (codec 5). Tries Hadoop framing, then the LZ4 frame format,
      # then a bare raw block (Arrow falls back hadoop -> raw; some writers emitted frames).
      # 
      # _@param_ `input` — compressed page data
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def decompress_hadoop(input, uncompressed_size); end

      # Parquet LZ4 (codec 5). Tries Hadoop framing, then the LZ4 frame format,
      # then a bare raw block (Arrow falls back hadoop -> raw; some writers emitted frames).
      # 
      # _@param_ `input` — compressed page data
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def self.decompress_hadoop(input, uncompressed_size); end

      # Decode LZ4 frame format data (one or more frames, skippable frames ignored).
      # Checksums are skipped, not verified.
      # 
      # _@param_ `input` — one or more concatenated LZ4 frames
      # 
      # _@param_ `max_size` — upper bound on the decompressed size
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT, possibly shorter than +max_size+
      sig { params(input: String, max_size: Integer).returns(String) }
      def decompress_frame(input, max_size); end

      # Decode LZ4 frame format data (one or more frames, skippable frames ignored).
      # Checksums are skipped, not verified.
      # 
      # _@param_ `input` — one or more concatenated LZ4 frames
      # 
      # _@param_ `max_size` — upper bound on the decompressed size
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT, possibly shorter than +max_size+
      sig { params(input: String, max_size: Integer).returns(String) }
      def self.decompress_frame(input, max_size); end

      # Compress into a single raw LZ4 block.
      # 
      # _@param_ `input` — bytes to compress
      # 
      # _@param_ `skip` — zero bytes to put before the block, for a header filled in later
      # 
      # _@return_ — raw LZ4 block in ASCII-8BIT
      sig { params(input: String, skip: Integer).returns(String) }
      def compress_block(input, skip: 0); end

      # Compress into a single raw LZ4 block.
      # 
      # _@param_ `input` — bytes to compress
      # 
      # _@param_ `skip` — zero bytes to put before the block, for a header filled in later
      # 
      # _@return_ — raw LZ4 block in ASCII-8BIT
      sig { params(input: String, skip: Integer).returns(String) }
      def self.compress_block(input, skip: 0); end

      # Single Hadoop-framed block: [BE uncompressed size][BE compressed size][raw block]
      # 
      # _@param_ `input` — bytes to compress
      # 
      # _@return_ — Hadoop-framed LZ4 data in ASCII-8BIT
      sig { params(input: String).returns(String) }
      def compress_hadoop(input); end

      # Single Hadoop-framed block: [BE uncompressed size][BE compressed size][raw block]
      # 
      # _@param_ `input` — bytes to compress
      # 
      # _@return_ — Hadoop-framed LZ4 data in ASCII-8BIT
      sig { params(input: String).returns(String) }
      def self.compress_hadoop(input); end

      # _@param_ `str` — input in any encoding
      # 
      # _@return_ — +str+ itself if already binary, otherwise a binary copy
      sig { params(str: String).returns(String) }
      def binary(str); end

      # _@param_ `str` — input in any encoding
      # 
      # _@return_ — +str+ itself if already binary, otherwise a binary copy
      sig { params(str: String).returns(String) }
      def self.binary(str); end

      # _@param_ `src` — binary input
      # 
      # _@param_ `i` — byte offset
      # 
      # _@return_ — unsigned little-endian 32-bit value at +i+
      sig { params(src: String, i: Integer).returns(Integer) }
      def le32(src, i); end

      # _@param_ `src` — binary input
      # 
      # _@param_ `i` — byte offset
      # 
      # _@return_ — unsigned little-endian 32-bit value at +i+
      sig { params(src: String, i: Integer).returns(Integer) }
      def self.le32(src, i); end

      # Same as le32 but via getbyte, for Rubies without unpack1(offset:).
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `i` — byte offset
      # 
      # _@return_ — unsigned little-endian 32-bit value at +i+
      sig { params(src: String, i: Integer).returns(Integer) }
      def u32(src, i); end

      # Same as le32 but via getbyte, for Rubies without unpack1(offset:).
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `i` — byte offset
      # 
      # _@return_ — unsigned little-endian 32-bit value at +i+
      sig { params(src: String, i: Integer).returns(Integer) }
      def self.u32(src, i); end

      # Appends the extension of a literal or match length: 255-bytes followed by the remainder.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `len` — length minus the 15 already stored in the token
      # 
      # _@return_ — +out+
      sig { params(out: String, len: Integer).returns(String) }
      def write_length(out, len); end

      # Appends the extension of a literal or match length: 255-bytes followed by the remainder.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `len` — length minus the 15 already stored in the token
      # 
      # _@return_ — +out+
      sig { params(out: String, len: Integer).returns(String) }
      def self.write_length(out, len); end

      # Appends the final, literals-only sequence that terminates every block.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `anchor` — offset of the first pending literal in +src+
      # 
      # _@param_ `lit_len` — number of trailing literal bytes (may be zero)
      # 
      # _@return_ — +out+, or nil when there are no literals
      sig do
        params(
          out: String,
          src: String,
          anchor: Integer,
          lit_len: Integer
        ).returns(T.nilable(String))
      end
      def emit_last_literals(out, src, anchor, lit_len); end

      # Appends the final, literals-only sequence that terminates every block.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `anchor` — offset of the first pending literal in +src+
      # 
      # _@param_ `lit_len` — number of trailing literal bytes (may be zero)
      # 
      # _@return_ — +out+, or nil when there are no literals
      sig do
        params(
          out: String,
          src: String,
          anchor: Integer,
          lit_len: Integer
        ).returns(T.nilable(String))
      end
      def self.emit_last_literals(out, src, anchor, lit_len); end

      # Decode one raw block from src[ip...iend], appending to out (which may already
      # hold earlier data that matches can reference). out may not grow beyond limit.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the block in +src+
      # 
      # _@param_ `iend` — offset just past the block
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — input offset where decoding stopped
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def decode_block(src, ip, iend, out, limit); end

      # Decode one raw block from src[ip...iend], appending to out (which may already
      # hold earlier data that matches can reference). out may not grow beyond limit.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the block in +src+
      # 
      # _@param_ `iend` — offset just past the block
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — input offset where decoding stopped
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def self.decode_block(src, ip, iend, out, limit); end

      # Arrow-compatible Hadoop frame parsing; returns nil if the data does not fit the framing.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `uncompressed_size` — exact decompressed size expected over all blocks
      # 
      # _@return_ — decompressed bytes, or nil if +src+ is not valid Hadoop-framed LZ4
      sig { params(src: String, uncompressed_size: Integer).returns(T.nilable(String)) }
      def try_hadoop(src, uncompressed_size); end

      # Arrow-compatible Hadoop frame parsing; returns nil if the data does not fit the framing.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `uncompressed_size` — exact decompressed size expected over all blocks
      # 
      # _@return_ — decompressed bytes, or nil if +src+ is not valid Hadoop-framed LZ4
      sig { params(src: String, uncompressed_size: Integer).returns(T.nilable(String)) }
      def self.try_hadoop(src, uncompressed_size); end

      # Decodes the descriptor and data blocks of one LZ4 frame (after its magic number),
      # skipping content size and checksums.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the frame descriptor (just past the magic)
      # 
      # _@param_ `n` — byte size of +src+
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — offset just past the frame
      sig do
        params(
          src: String,
          ip: Integer,
          n: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def decode_frame(src, ip, n, out, limit); end

      # Decodes the descriptor and data blocks of one LZ4 frame (after its magic number),
      # skipping content size and checksums.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the frame descriptor (just past the magic)
      # 
      # _@param_ `n` — byte size of +src+
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — offset just past the frame
      sig do
        params(
          src: String,
          ip: Integer,
          n: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def self.decode_frame(src, ip, n, out, limit); end

      # Raised for corrupt, truncated or unsupported LZ4 input.
      class Error < StandardError
      end
    end

    # Pure-Ruby LZO1X decompressor, for reading Parquet files written by parquet-mr with
    # hadoop-lzo. There is no compressor: nothing but hadoop-lzo writes LZO, and nothing
    # outside the JVM reads it.
    # 
    # Written from the bitstream description in the Linux kernel's
    # Documentation/staging/lzo.rst, not from the (GPL) LZO sources.
    # 
    # @api private
    module LZO
      # Parquet LZO (codec 3). hadoop-lzo writes Hadoop block framing; data that does not fit
      # the framing is decoded as one bare LZO1X stream.
      # 
      # _@param_ `input` — compressed page data
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def decompress_hadoop(input, uncompressed_size); end

      # Parquet LZO (codec 3). hadoop-lzo writes Hadoop block framing; data that does not fit
      # the framing is decoded as one bare LZO1X stream.
      # 
      # _@param_ `input` — compressed page data
      # 
      # _@param_ `uncompressed_size` — exact decompressed size, from the page header
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def self.decompress_hadoop(input, uncompressed_size); end

      # Decompress one bare LZO1X stream that must expand to exactly uncompressed_size bytes.
      # 
      # _@param_ `input` — LZO1X stream, ending with the end-of-stream marker
      # 
      # _@param_ `uncompressed_size` — exact decompressed size
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def decompress_block(input, uncompressed_size); end

      # Decompress one bare LZO1X stream that must expand to exactly uncompressed_size bytes.
      # 
      # _@param_ `input` — LZO1X stream, ending with the end-of-stream marker
      # 
      # _@param_ `uncompressed_size` — exact decompressed size
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String, uncompressed_size: Integer).returns(String) }
      def self.decompress_block(input, uncompressed_size); end

      # _@param_ `str` — input in any encoding
      # 
      # _@return_ — +str+ itself if already binary, otherwise a binary copy
      sig { params(str: String).returns(String) }
      def binary(str); end

      # _@param_ `str` — input in any encoding
      # 
      # _@return_ — +str+ itself if already binary, otherwise a binary copy
      sig { params(str: String).returns(String) }
      def self.binary(str); end

      # Hadoop's BlockCompressorStream layout: blocks of (uncompressed size, then chunks of
      # (compressed size, LZO stream) until the block is filled). Each chunk is a separate stream.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `uncompressed_size` — exact decompressed size expected over all blocks
      # 
      # _@return_ — decompressed bytes, or nil if +src+ is not valid Hadoop-framed LZO
      sig { params(src: String, uncompressed_size: Integer).returns(T.nilable(String)) }
      def try_hadoop(src, uncompressed_size); end

      # Hadoop's BlockCompressorStream layout: blocks of (uncompressed size, then chunks of
      # (compressed size, LZO stream) until the block is filled). Each chunk is a separate stream.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `uncompressed_size` — exact decompressed size expected over all blocks
      # 
      # _@return_ — decompressed bytes, or nil if +src+ is not valid Hadoop-framed LZO
      sig { params(src: String, uncompressed_size: Integer).returns(T.nilable(String)) }
      def self.try_hadoop(src, uncompressed_size); end

      # Decode one LZO1X stream from src[ip...iend], appending to out. Matches may only reach
      # back to where this stream's output starts. out may not grow beyond limit.
      # 
      # Every instruction is a match optionally followed by 0-3 literals (its low two bits, the
      # "state"), or a run of 4+ literals. What an instruction byte below 16 means depends on
      # the state the previous instruction left behind.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the stream in +src+
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — input offset just past the end-of-stream marker
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def decode_block(src, ip, iend, out, limit); end

      # Decode one LZO1X stream from src[ip...iend], appending to out. Matches may only reach
      # back to where this stream's output starts. out may not grow beyond limit.
      # 
      # Every instruction is a match optionally followed by 0-3 literals (its low two bits, the
      # "state"), or a run of 4+ literals. What an instruction byte below 16 means depends on
      # the state the previous instruction left behind.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the stream in +src+
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — input offset just past the end-of-stream marker
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer
        ).returns(Integer)
      end
      def self.decode_block(src, ip, iend, out, limit); end

      # Reads a length extension: a byte of 0 for each 255, then the nonzero remainder.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the first extension byte
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `bias` — added to the extension
      # 
      # _@return_ — the length, and the offset just past the extension
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          bias: Integer
        ).returns([Integer, Integer])
      end
      def extended_length(src, ip, iend, bias); end

      # Reads a length extension: a byte of 0 for each 255, then the nonzero remainder.
      # 
      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the first extension byte
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `bias` — added to the extension
      # 
      # _@return_ — the length, and the offset just past the extension
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          bias: Integer
        ).returns([Integer, Integer])
      end
      def self.extended_length(src, ip, iend, bias); end

      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the literals in +src+
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@param_ `len` — number of literal bytes
      # 
      # _@return_ — offset just past the literals
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer,
          len: Integer
        ).returns(Integer)
      end
      def copy_literals(src, ip, iend, out, limit, len); end

      # _@param_ `src` — binary input
      # 
      # _@param_ `ip` — offset of the literals in +src+
      # 
      # _@param_ `iend` — offset just past the stream
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@param_ `len` — number of literal bytes
      # 
      # _@return_ — offset just past the literals
      sig do
        params(
          src: String,
          ip: Integer,
          iend: Integer,
          out: String,
          limit: Integer,
          len: Integer
        ).returns(Integer)
      end
      def self.copy_literals(src, ip, iend, out, limit, len); end

      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `base` — size of +out+ when the current stream started
      # 
      # _@param_ `dist` — how far back the match starts
      # 
      # _@param_ `len` — match length, which may exceed +dist+ (a repeating pattern)
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — +out+
      sig do
        params(
          out: String,
          base: Integer,
          dist: Integer,
          len: Integer,
          limit: Integer
        ).returns(String)
      end
      def copy_match(out, base, dist, len, limit); end

      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `base` — size of +out+ when the current stream started
      # 
      # _@param_ `dist` — how far back the match starts
      # 
      # _@param_ `len` — match length, which may exceed +dist+ (a repeating pattern)
      # 
      # _@param_ `limit` — maximum total byte size of +out+
      # 
      # _@return_ — +out+
      sig do
        params(
          out: String,
          base: Integer,
          dist: Integer,
          len: Integer,
          limit: Integer
        ).returns(String)
      end
      def self.copy_match(out, base, dist, len, limit); end

      # Raised for corrupt or truncated LZO input.
      class Error < StandardError
      end
    end

    # Pure-Ruby implementation of the raw Snappy block format (as used by Parquet),
    # see https://github.com/google/snappy/blob/main/format_description.txt
    # 
    # When the `snappy` gem (a binding to Google's libsnappy) is loaded, it is used instead:
    # 12x faster decompression and 27x faster compression. It is optional and only a speedup: if
    # it is missing, the pure-Ruby code below is used silently. Both produce raw Snappy blocks the
    # other reads.
    # 
    # 32-bit loads are done with four getbyte calls rather than unpack1(offset:) to stay
    # compatible with Ruby 3.0 - the speed difference on MRI is marginal.
    # 
    # @api private
    module Snappy
      # _@param_ `input` — raw snappy block
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String).returns(String) }
      def decompress(input); end

      # _@param_ `input` — raw snappy block
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(input: String).returns(String) }
      def self.decompress(input); end

      # The backend in use: :native (the snappy gem) or :ruby
      # 
      # _@return_ — +:native+ or +:ruby+
      sig { returns(Symbol) }
      def backend; end

      # The backend in use: :native (the snappy gem) or :ruby
      # 
      # _@return_ — +:native+ or +:ruby+
      sig { returns(Symbol) }
      def self.backend; end

      # For tests and benchmarks: :ruby forces pure Ruby, :native the snappy gem
      # (UnsupportedError if it is not loaded), nil goes back to the default
      # 
      # _@param_ `name` — +:ruby+, +:native+ or nil
      sig { params(name: T.nilable(Symbol)).void }
      def backend=(name); end

      # For tests and benchmarks: :ruby forces pure Ruby, :native the snappy gem
      # (UnsupportedError if it is not loaded), nil goes back to the default
      # 
      # _@param_ `name` — +:ruby+, +:native+ or nil
      sig { params(name: T.nilable(Symbol)).void }
      def self.backend=(name); end

      # The native library to use: the snappy gem when it is loaded, unless backend= forced one.
      # 
      # _@return_ — the +::Snappy+ module, or nil when the pure-Ruby code should run
      sig { returns(T.nilable(Module)) }
      def native; end

      # The native library to use: the snappy gem when it is loaded, unless backend= forced one.
      # 
      # _@return_ — the +::Snappy+ module, or nil when the pure-Ruby code should run
      sig { returns(T.nilable(Module)) }
      def self.native; end

      # Not memoized, so that it works the same in every Ractor and once the gem is required later.
      # 
      # _@return_ — the +::Snappy+ module, or false if it is not loaded or lacks inflate/deflate
      sig { returns(T.any(Module, T::Boolean)) }
      def native_library; end

      # Not memoized, so that it works the same in every Ractor and once the gem is required later.
      # 
      # _@return_ — the +::Snappy+ module, or false if it is not loaded or lacks inflate/deflate
      sig { returns(T.any(Module, T::Boolean)) }
      def self.native_library; end

      # Decompresses into a preallocated IO::Buffer: copies do not allocate intermediate Strings.
      # 
      # _@param_ `src` — raw snappy block in ASCII-8BIT
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(src: String).returns(String) }
      def decompress_io_buffer(src); end

      # Decompresses into a preallocated IO::Buffer: copies do not allocate intermediate Strings.
      # 
      # _@param_ `src` — raw snappy block in ASCII-8BIT
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(src: String).returns(String) }
      def self.decompress_io_buffer(src); end

      # Decompresses by appending to a String; the fallback when IO::Buffer is not available.
      # 
      # _@param_ `src` — raw snappy block in ASCII-8BIT
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(src: String).returns(String) }
      def decompress_string(src); end

      # Decompresses by appending to a String; the fallback when IO::Buffer is not available.
      # 
      # _@param_ `src` — raw snappy block in ASCII-8BIT
      # 
      # _@return_ — decompressed bytes in ASCII-8BIT
      sig { params(src: String).returns(String) }
      def self.decompress_string(src); end

      # Several Strings are compressed as their concatenation without joining them: fragments are
      # compressed straight out of the part holding them, and only a fragment straddling two parts
      # is copied out. The output is the same as for the joined input.
      # 
      # _@param_ `input` — bytes to compress, or the parts of them
      # 
      # _@return_ — raw snappy block in ASCII-8BIT
      sig { params(input: T.any(String, T::Array[String])).returns(String) }
      def compress(input); end

      # Several Strings are compressed as their concatenation without joining them: fragments are
      # compressed straight out of the part holding them, and only a fragment straddling two parts
      # is copied out. The output is the same as for the joined input.
      # 
      # _@param_ `input` — bytes to compress, or the parts of them
      # 
      # _@return_ — raw snappy block in ASCII-8BIT
      sig { params(input: T.any(String, T::Array[String])).returns(String) }
      def self.compress(input); end

      # _@param_ `str` — bytes in any encoding
      # 
      # _@return_ — +str+, or a binary copy when it is in another encoding
      sig { params(str: String).returns(String) }
      def binary(str); end

      # _@param_ `str` — bytes in any encoding
      # 
      # _@return_ — +str+, or a binary copy when it is in another encoding
      sig { params(str: String).returns(String) }
      def self.binary(str); end

      # Skips past parts that are used up
      # 
      # _@param_ `parts` — the input parts
      # 
      # _@param_ `index` — index of the current part
      # 
      # _@param_ `offset` — offset in the current part
      # 
      # _@return_ — index of a part with bytes left at the offset, and that offset
      sig { params(parts: T::Array[String], index: Integer, offset: Integer).returns([Integer, Integer]) }
      def next_part(parts, index, offset); end

      # Skips past parts that are used up
      # 
      # _@param_ `parts` — the input parts
      # 
      # _@param_ `index` — index of the current part
      # 
      # _@param_ `offset` — offset in the current part
      # 
      # _@return_ — index of a part with bytes left at the offset, and that offset
      sig { params(parts: T::Array[String], index: Integer, offset: Integer).returns([Integer, Integer]) }
      def self.next_part(parts, index, offset); end

      # Reads the uncompressed-length preamble (a little-endian base-128 varint) at the start of +src+.
      # 
      # _@param_ `src` — raw snappy block
      # 
      # _@param_ `n` — byte size of +src+
      # 
      # _@return_ — the declared uncompressed length and the offset just past the varint
      sig { params(src: String, n: Integer).returns([Integer, Integer]) }
      def read_varint(src, n); end

      # Reads the uncompressed-length preamble (a little-endian base-128 varint) at the start of +src+.
      # 
      # _@param_ `src` — raw snappy block
      # 
      # _@param_ `n` — byte size of +src+
      # 
      # _@return_ — the declared uncompressed length and the offset just past the varint
      sig { params(src: String, n: Integer).returns([Integer, Integer]) }
      def self.read_varint(src, n); end

      # Appends +value+ as a little-endian base-128 varint (the length preamble).
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `value` — non-negative length to encode
      # 
      # _@return_ — +out+
      sig { params(out: String, value: Integer).returns(String) }
      def write_varint(out, value); end

      # Appends +value+ as a little-endian base-128 varint (the length preamble).
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `value` — non-negative length to encode
      # 
      # _@return_ — +out+
      sig { params(out: String, value: Integer).returns(String) }
      def self.write_varint(out, value); end

      # Mirrors CompressFragment from the reference implementation. Table entries are
      # positions relative to `base`; matches never cross the block boundary.
      # The 4-byte little-endian word at every position of the block is unpacked up front
      # (in C, via String#unpack) so hashing and match checks are single Array lookups.
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `len` — fragment length, at most BLOCK_SIZE
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `table` — zeroed hash table of 1 << HASH_BITS fragment-relative positions
      sig do
        params(
          src: String,
          base: Integer,
          len: Integer,
          out: String,
          table: T::Array[Integer]
        ).void
      end
      def compress_block(src, base, len, out, table); end

      # Mirrors CompressFragment from the reference implementation. Table entries are
      # positions relative to `base`; matches never cross the block boundary.
      # The 4-byte little-endian word at every position of the block is unpacked up front
      # (in C, via String#unpack) so hashing and match checks are single Array lookups.
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `len` — fragment length, at most BLOCK_SIZE
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `table` — zeroed hash table of 1 << HASH_BITS fragment-relative positions
      sig do
        params(
          src: String,
          base: Integer,
          len: Integer,
          out: String,
          table: T::Array[Integer]
        ).void
      end
      def self.compress_block(src, base, len, out, table); end

      # words[k][j] is the 4-byte little-endian value at base + 4 * j + k, so the word at
      # relative position i is words[i & 3][i >> 2]
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `len` — fragment length
      # 
      # _@return_ — four arrays of 32-bit words, one per byte phase
      sig { params(src: String, base: Integer, len: Integer).returns(T::Array[T::Array[Integer]]) }
      def block_words(src, base, len); end

      # words[k][j] is the 4-byte little-endian value at base + 4 * j + k, so the word at
      # relative position i is words[i & 3][i >> 2]
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `len` — fragment length
      # 
      # _@return_ — four arrays of 32-bit words, one per byte phase
      sig { params(src: String, base: Integer, len: Integer).returns(T::Array[T::Array[Integer]]) }
      def self.block_words(src, base, len); end

      # Like match_length, but compares 4 bytes at a time using the unpacked block words,
      # which avoids allocating substrings for the (common) short matches.
      # Falls back to match_length once a match reaches 64 bytes.
      # 
      # _@param_ `words` — fragment words from block_words
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `s1` — absolute offset of the earlier occurrence
      # 
      # _@param_ `s2` — absolute offset of the current position (s1 < s2)
      # 
      # _@param_ `limit` — absolute offset not to read past (the fragment end)
      # 
      # _@return_ — number of equal bytes starting at s1 and s2
      sig do
        params(
          words: T::Array[T::Array[Integer]],
          src: String,
          base: Integer,
          s1: Integer,
          s2: Integer,
          limit: Integer
        ).returns(Integer)
      end
      def match_length_words(words, src, base, s1, s2, limit); end

      # Like match_length, but compares 4 bytes at a time using the unpacked block words,
      # which avoids allocating substrings for the (common) short matches.
      # Falls back to match_length once a match reaches 64 bytes.
      # 
      # _@param_ `words` — fragment words from block_words
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `base` — offset of the fragment in +src+
      # 
      # _@param_ `s1` — absolute offset of the earlier occurrence
      # 
      # _@param_ `s2` — absolute offset of the current position (s1 < s2)
      # 
      # _@param_ `limit` — absolute offset not to read past (the fragment end)
      # 
      # _@return_ — number of equal bytes starting at s1 and s2
      sig do
        params(
          words: T::Array[T::Array[Integer]],
          src: String,
          base: Integer,
          s1: Integer,
          s2: Integer,
          limit: Integer
        ).returns(Integer)
      end
      def self.match_length_words(words, src, base, s1, s2, limit); end

      # Number of equal bytes at s1 and s2 (s1 < s2), not reading past limit. Gallops
      # with byteslice comparisons (memcmp) to avoid per-byte loops on long matches.
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `s1` — absolute offset of the earlier occurrence
      # 
      # _@param_ `s2` — absolute offset of the current position
      # 
      # _@param_ `limit` — absolute offset not to read past
      # 
      # _@return_ — number of equal bytes
      sig do
        params(
          src: String,
          s1: Integer,
          s2: Integer,
          limit: Integer
        ).returns(Integer)
      end
      def match_length(src, s1, s2, limit); end

      # Number of equal bytes at s1 and s2 (s1 < s2), not reading past limit. Gallops
      # with byteslice comparisons (memcmp) to avoid per-byte loops on long matches.
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `s1` — absolute offset of the earlier occurrence
      # 
      # _@param_ `s2` — absolute offset of the current position
      # 
      # _@param_ `limit` — absolute offset not to read past
      # 
      # _@return_ — number of equal bytes
      sig do
        params(
          src: String,
          s1: Integer,
          s2: Integer,
          limit: Integer
        ).returns(Integer)
      end
      def self.match_length(src, s1, s2, limit); end

      # Appends a literal element: the tag (with a 1-4 byte length extension for long literals)
      # followed by the bytes themselves. Does nothing for an empty literal.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `pos` — offset of the literal bytes in +src+
      # 
      # _@param_ `len` — number of literal bytes
      # 
      # _@return_ — +out+, or nil when +len+ is zero
      sig do
        params(
          out: String,
          src: String,
          pos: Integer,
          len: Integer
        ).returns(T.nilable(String))
      end
      def emit_literal(out, src, pos, len); end

      # Appends a literal element: the tag (with a 1-4 byte length extension for long literals)
      # followed by the bytes themselves. Does nothing for an empty literal.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `src` — whole input in ASCII-8BIT
      # 
      # _@param_ `pos` — offset of the literal bytes in +src+
      # 
      # _@param_ `len` — number of literal bytes
      # 
      # _@return_ — +out+, or nil when +len+ is zero
      sig do
        params(
          out: String,
          src: String,
          pos: Integer,
          len: Integer
        ).returns(T.nilable(String))
      end
      def self.emit_literal(out, src, pos, len); end

      # Offsets are always < 64KB (matches stay within a block), so 4-byte offsets are never needed.
      # Long matches are split into copies of at most 64 bytes, never leaving a remainder under 4.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `offset` — backward distance to the match source, 1...65536
      # 
      # _@param_ `len` — match length, at least 4
      # 
      # _@return_ — +out+
      sig { params(out: String, offset: Integer, len: Integer).returns(String) }
      def emit_copy(out, offset, len); end

      # Offsets are always < 64KB (matches stay within a block), so 4-byte offsets are never needed.
      # Long matches are split into copies of at most 64 bytes, never leaving a remainder under 4.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `offset` — backward distance to the match source, 1...65536
      # 
      # _@param_ `len` — match length, at least 4
      # 
      # _@return_ — +out+
      sig { params(out: String, offset: Integer, len: Integer).returns(String) }
      def self.emit_copy(out, offset, len); end

      # Appends one copy element: the 2-byte form (1-byte offset) when len is 4..11 and offset < 2048,
      # otherwise the 3-byte form with a 2-byte offset.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `offset` — backward distance to the match source, 1...65536
      # 
      # _@param_ `len` — copy length, 4..64
      # 
      # _@return_ — +out+
      sig { params(out: String, offset: Integer, len: Integer).returns(String) }
      def emit_copy_upto64(out, offset, len); end

      # Appends one copy element: the 2-byte form (1-byte offset) when len is 4..11 and offset < 2048,
      # otherwise the 3-byte form with a 2-byte offset.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `offset` — backward distance to the match source, 1...65536
      # 
      # _@param_ `len` — copy length, 4..64
      # 
      # _@return_ — +out+
      sig { params(out: String, offset: Integer, len: Integer).returns(String) }
      def self.emit_copy_upto64(out, offset, len); end

      # Raised for corrupt or truncated Snappy input, and for input too large to compress.
      class Error < StandardError
      end
    end
  end

  # Decoders and encoders for the Parquet value and level encodings: PLAIN, the RLE / bit-packed
  # hybrid, the DELTA_* family and BYTE_STREAM_SPLIT. They work on binary Strings and byte offsets,
  # and know nothing about pages or columns.
  module Encodings
    # Bit packing (LSB-first, as used by Parquet) and the RLE / bit-packed hybrid encoding
    # used for repetition/definition levels, dictionary indices and RLE booleans.
    # 
    # @api private
    module RLE
      # Unpacks +count+ values of +width+ bits each, starting at byte +offset+ of +data+.
      # Missing trailing bytes are treated as zeroes.
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `offset` — byte offset of the first packed value
      # 
      # _@param_ `count` — number of values to unpack
      # 
      # _@param_ `width` — bits per value, 0..64
      # 
      # _@return_ — +count+ unsigned values
      sig do
        params(
          data: String,
          offset: Integer,
          count: Integer,
          width: Integer
        ).returns(T::Array[Integer])
      end
      def unpack_bits(data, offset, count, width); end

      # Unpacks +count+ values of +width+ bits each, starting at byte +offset+ of +data+.
      # Missing trailing bytes are treated as zeroes.
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `offset` — byte offset of the first packed value
      # 
      # _@param_ `count` — number of values to unpack
      # 
      # _@param_ `width` — bits per value, 0..64
      # 
      # _@return_ — +count+ unsigned values
      sig do
        params(
          data: String,
          offset: Integer,
          count: Integer,
          width: Integer
        ).returns(T::Array[Integer])
      end
      def self.unpack_bits(data, offset, count, width); end

      # Slow path for widths above 32 bits (used by DELTA_BINARY_PACKED with 64-bit values)
      # 
      # _@param_ `chunk` — packed bytes, starting at the first value
      # 
      # _@param_ `count` — number of values to unpack
      # 
      # _@param_ `width` — bits per value, 33..64
      # 
      # _@return_ — +count+ unsigned values
      sig { params(chunk: String, count: Integer, width: Integer).returns(T::Array[Integer]) }
      def unpack_wide(chunk, count, width); end

      # Slow path for widths above 32 bits (used by DELTA_BINARY_PACKED with 64-bit values)
      # 
      # _@param_ `chunk` — packed bytes, starting at the first value
      # 
      # _@param_ `count` — number of values to unpack
      # 
      # _@param_ `width` — bits per value, 33..64
      # 
      # _@return_ — +count+ unsigned values
      sig { params(chunk: String, count: Integer, width: Integer).returns(T::Array[Integer]) }
      def self.unpack_wide(chunk, count, width); end

      # Packs +values+ with +width+ bits each; the value count is padded up to a multiple of 8.
      # 
      # _@param_ `values` — non-negative integers that fit in +width+ bits
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — packed bytes in ASCII-8BIT, +width+ bytes per group of 8 values
      sig { params(values: T::Array[Integer], width: Integer).returns(String) }
      def pack_bits(values, width); end

      # Packs +values+ with +width+ bits each; the value count is padded up to a multiple of 8.
      # 
      # _@param_ `values` — non-negative integers that fit in +width+ bits
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — packed bytes in ASCII-8BIT, +width+ bytes per group of 8 values
      sig { params(values: T::Array[Integer], width: Integer).returns(String) }
      def self.pack_bits(values, width); end

      # Reads an unsigned LEB128 varint (hybrid run headers, DELTA_BINARY_PACKED headers).
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the varint
      # 
      # _@return_ — the decoded value and the offset just past it
      sig { params(data: String, pos: Integer).returns([Integer, Integer]) }
      def read_uleb(data, pos); end

      # Reads an unsigned LEB128 varint (hybrid run headers, DELTA_BINARY_PACKED headers).
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the varint
      # 
      # _@return_ — the decoded value and the offset just past it
      sig { params(data: String, pos: Integer).returns([Integer, Integer]) }
      def self.read_uleb(data, pos); end

      # Appends +n+ as an unsigned LEB128 varint.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `n` — non-negative integer to encode
      # 
      # _@return_ — +out+
      sig { params(out: String, n: Integer).returns(String) }
      def write_uleb(out, n); end

      # Appends +n+ as an unsigned LEB128 varint.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `n` — non-negative integer to encode
      # 
      # _@return_ — +out+
      sig { params(out: String, n: Integer).returns(String) }
      def self.write_uleb(out, n); end

      # Decodes the RLE/bit-packed hybrid from +data+ between +pos+ and +limit+,
      # returning exactly +count+ values (missing values are an error).
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the first run header
      # 
      # _@param_ `limit` — byte offset just past the encoded data
      # 
      # _@param_ `width` — bits per value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — exactly +count+ values
      sig do
        params(
          data: String,
          pos: Integer,
          limit: Integer,
          width: Integer,
          count: Integer
        ).returns(T::Array[Integer])
      end
      def decode_hybrid(data, pos, limit, width, count); end

      # Decodes the RLE/bit-packed hybrid from +data+ between +pos+ and +limit+,
      # returning exactly +count+ values (missing values are an error).
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the first run header
      # 
      # _@param_ `limit` — byte offset just past the encoded data
      # 
      # _@param_ `width` — bits per value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — exactly +count+ values
      sig do
        params(
          data: String,
          pos: Integer,
          limit: Integer,
          width: Integer,
          count: Integer
        ).returns(T::Array[Integer])
      end
      def self.decode_hybrid(data, pos, limit, width, count); end

      # Encodes +values+ with the RLE/bit-packed hybrid. Repeated runs of 8+ equal values
      # become RLE runs, everything else goes into bit-packed groups of 8.
      # Output has no length prefix; callers that need one (levels in data page v1) add it.
      # 
      # _@param_ `values` — non-negative integers that fit in +width+ bits
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — encoded runs in ASCII-8BIT
      sig { params(values: T::Array[Integer], width: Integer).returns(String) }
      def encode_hybrid(values, width); end

      # Encodes +values+ with the RLE/bit-packed hybrid. Repeated runs of 8+ equal values
      # become RLE runs, everything else goes into bit-packed groups of 8.
      # Output has no length prefix; callers that need one (levels in data page v1) add it.
      # 
      # _@param_ `values` — non-negative integers that fit in +width+ bits
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — encoded runs in ASCII-8BIT
      sig { params(values: T::Array[Integer], width: Integer).returns(String) }
      def self.encode_hybrid(values, width); end

      # Appends values[from...to] as one bit-packed run, zero-padded to whole groups of 8.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `values` — all values being encoded
      # 
      # _@param_ `from` — index of the first literal value
      # 
      # _@param_ `to` — index just past the last literal value
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — +out+
      sig do
        params(
          out: String,
          values: T::Array[Integer],
          from: Integer,
          to: Integer,
          width: Integer
        ).returns(String)
      end
      def flush_literals(out, values, from, to, width); end

      # Appends values[from...to] as one bit-packed run, zero-padded to whole groups of 8.
      # 
      # _@param_ `out` — binary output buffer, appended to
      # 
      # _@param_ `values` — all values being encoded
      # 
      # _@param_ `from` — index of the first literal value
      # 
      # _@param_ `to` — index just past the last literal value
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — +out+
      sig do
        params(
          out: String,
          values: T::Array[Integer],
          from: Integer,
          to: Integer,
          width: Integer
        ).returns(String)
      end
      def self.flush_literals(out, values, from, to, width); end

      # Number of bits needed to store values up to +max_value+ (0 for 0).
      # 
      # _@param_ `max_value` — largest value to encode; nil counts as 0
      # 
      # _@return_ — bit width
      sig { params(max_value: T.nilable(Integer)).returns(Integer) }
      def bit_width(max_value); end

      # Number of bits needed to store values up to +max_value+ (0 for 0).
      # 
      # _@param_ `max_value` — largest value to encode; nil counts as 0
      # 
      # _@return_ — bit width
      sig { params(max_value: T.nilable(Integer)).returns(Integer) }
      def self.bit_width(max_value); end

      # Legacy BIT_PACKED level encoding (deprecated): MSB-first bit order, no header.
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the packed levels
      # 
      # _@param_ `width` — bits per value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — +count+ levels
      sig do
        params(
          data: String,
          pos: Integer,
          width: Integer,
          count: Integer
        ).returns(T::Array[Integer])
      end
      def decode_legacy_bit_packed(data, pos, width, count); end

      # Legacy BIT_PACKED level encoding (deprecated): MSB-first bit order, no header.
      # 
      # _@param_ `data` — binary input
      # 
      # _@param_ `pos` — byte offset of the packed levels
      # 
      # _@param_ `width` — bits per value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — +count+ levels
      sig do
        params(
          data: String,
          pos: Integer,
          width: Integer,
          count: Integer
        ).returns(T::Array[Integer])
      end
      def self.decode_legacy_bit_packed(data, pos, width, count); end
    end

    # DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY
    # 
    # @api private
    module Delta
      # _@param_ `n` — zigzag-encoded unsigned integer
      # 
      # _@return_ — the signed integer it represents
      sig { params(n: Integer).returns(Integer) }
      def zigzag_decode(n); end

      # _@param_ `n` — zigzag-encoded unsigned integer
      # 
      # _@return_ — the signed integer it represents
      sig { params(n: Integer).returns(Integer) }
      def self.zigzag_decode(n); end

      # _@param_ `n` — signed integer
      # 
      # _@return_ — zigzag-encoded form (0, -1, 1, -2 map to 0, 1, 2, 3)
      sig { params(n: Integer).returns(Integer) }
      def zigzag_encode(n); end

      # _@param_ `n` — signed integer
      # 
      # _@return_ — zigzag-encoded form (0, -1, 1, -2 map to 0, 1, 2, 3)
      sig { params(n: Integer).returns(Integer) }
      def self.zigzag_encode(n); end

      # Wraps an integer into the signed range of +bits+ bits
      # 
      # _@param_ `v` — integer to wrap
      # 
      # _@param_ `bits` — target width, 32 or 64
      # 
      # _@return_ — +v+ modulo 2^bits, as a two's complement signed integer
      sig { params(v: Integer, bits: Integer).returns(Integer) }
      def wrap(v, bits); end

      # Wraps an integer into the signed range of +bits+ bits
      # 
      # _@param_ `v` — integer to wrap
      # 
      # _@param_ `bits` — target width, 32 or 64
      # 
      # _@return_ — +v+ modulo 2^bits, as a two's complement signed integer
      sig { params(v: Integer, bits: Integer).returns(Integer) }
      def self.wrap(v, bits); end

      # Decodes DELTA_BINARY_PACKED integers. +bits+ is 32 or 64 (for wraparound).
      # Returns [values, new_pos]. If +count+ is nil, the total from the header is used. A smaller
      # +count+ decodes only that many values, but the returned offset is still the end of the
      # whole encoded block, so data following it can be read from there.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the block header
      # 
      # _@param_ `bits` — integer width that deltas wrap around in, 32 or 64
      # 
      # _@param_ `count` — maximum number of values to decode
      # 
      # _@return_ — the decoded values and the offset just past the encoded block
      sig do
        params(
          data: String,
          pos: Integer,
          bits: Integer,
          count: T.nilable(Integer)
        ).returns([T::Array[Integer], Integer])
      end
      def decode_binary_packed(data, pos, bits = 64, count = nil); end

      # Decodes DELTA_BINARY_PACKED integers. +bits+ is 32 or 64 (for wraparound).
      # Returns [values, new_pos]. If +count+ is nil, the total from the header is used. A smaller
      # +count+ decodes only that many values, but the returned offset is still the end of the
      # whole encoded block, so data following it can be read from there.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the block header
      # 
      # _@param_ `bits` — integer width that deltas wrap around in, 32 or 64
      # 
      # _@param_ `count` — maximum number of values to decode
      # 
      # _@return_ — the decoded values and the offset just past the encoded block
      sig do
        params(
          data: String,
          pos: Integer,
          bits: Integer,
          count: T.nilable(Integer)
        ).returns([T::Array[Integer], Integer])
      end
      def self.decode_binary_packed(data, pos, bits = 64, count = nil); end

      # Encodes integers with DELTA_BINARY_PACKED, using BLOCK_SIZE values per block in MINIBLOCKS
      # miniblocks. Deltas wrap at +bits+ so INT32 columns never need more than 32-bit widths.
      # 
      # _@param_ `values` — signed integers that fit in +bits+ bits
      # 
      # _@param_ `bits` — physical integer width, 32 or 64
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[Integer], bits: Integer).returns(String) }
      def encode_binary_packed(values, bits = 64); end

      # Encodes integers with DELTA_BINARY_PACKED, using BLOCK_SIZE values per block in MINIBLOCKS
      # miniblocks. Deltas wrap at +bits+ so INT32 columns never need more than 32-bit widths.
      # 
      # _@param_ `values` — signed integers that fit in +bits+ bits
      # 
      # _@param_ `bits` — physical integer width, 32 or 64
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[Integer], bits: Integer).returns(String) }
      def self.encode_binary_packed(values, bits = 64); end

      # Decodes DELTA_LENGTH_BYTE_ARRAY: DELTA_BINARY_PACKED lengths followed by the concatenated bytes.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the lengths block
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary slices of +data+ and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def decode_length_byte_array(data, pos, count); end

      # Decodes DELTA_LENGTH_BYTE_ARRAY: DELTA_BINARY_PACKED lengths followed by the concatenated bytes.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the lengths block
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary slices of +data+ and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def self.decode_length_byte_array(data, pos, count); end

      # Encodes byte strings with DELTA_LENGTH_BYTE_ARRAY.
      # 
      # _@param_ `values` — byte strings, in any encoding
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[String]).returns(String) }
      def encode_length_byte_array(values); end

      # Encodes byte strings with DELTA_LENGTH_BYTE_ARRAY.
      # 
      # _@param_ `values` — byte strings, in any encoding
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[String]).returns(String) }
      def self.encode_length_byte_array(values); end

      # Decodes DELTA_BYTE_ARRAY (incremental encoding): DELTA_BINARY_PACKED prefix lengths, then
      # the suffixes as DELTA_LENGTH_BYTE_ARRAY. Each value is the previous value's prefix plus its suffix.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the prefix lengths block
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary values and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def decode_byte_array(data, pos, count); end

      # Decodes DELTA_BYTE_ARRAY (incremental encoding): DELTA_BINARY_PACKED prefix lengths, then
      # the suffixes as DELTA_LENGTH_BYTE_ARRAY. Each value is the previous value's prefix plus its suffix.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the prefix lengths block
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary values and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def self.decode_byte_array(data, pos, count); end

      # Encodes byte strings with DELTA_BYTE_ARRAY, sharing the common byte prefix with the previous value.
      # 
      # _@param_ `values` — byte strings, in any encoding
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[String]).returns(String) }
      def encode_byte_array(values); end

      # Encodes byte strings with DELTA_BYTE_ARRAY, sharing the common byte prefix with the previous value.
      # 
      # _@param_ `values` — byte strings, in any encoding
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[String]).returns(String) }
      def self.encode_byte_array(values); end
    end

    # BYTE_STREAM_SPLIT: byte k of every value is stored in stream k.
    # 
    # @api private
    module ByteStreamSplit
      # Returns the value bytes re-interleaved into PLAIN layout
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first stream
      # 
      # _@param_ `count` — number of values
      # 
      # _@param_ `width` — byte width of one value
      # 
      # _@return_ — PLAIN-layout bytes and the offset just past the streams
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          width: Integer
        ).returns([String, Integer])
      end
      def decode(data, pos, count, width); end

      # Returns the value bytes re-interleaved into PLAIN layout
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first stream
      # 
      # _@param_ `count` — number of values
      # 
      # _@param_ `width` — byte width of one value
      # 
      # _@return_ — PLAIN-layout bytes and the offset just past the streams
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          width: Integer
        ).returns([String, Integer])
      end
      def self.decode(data, pos, count, width); end

      # Splits PLAIN-layout fixed-width values into +width+ byte streams. Inverse of decode.
      # 
      # _@param_ `plain` — PLAIN-encoded values, a multiple of +width+ bytes
      # 
      # _@param_ `width` — byte width of one value
      # 
      # _@return_ — the concatenated streams in ASCII-8BIT
      sig { params(plain: String, width: Integer).returns(String) }
      def encode(plain, width); end

      # Splits PLAIN-layout fixed-width values into +width+ byte streams. Inverse of decode.
      # 
      # _@param_ `plain` — PLAIN-encoded values, a multiple of +width+ bytes
      # 
      # _@param_ `width` — byte width of one value
      # 
      # _@return_ — the concatenated streams in ASCII-8BIT
      sig { params(plain: String, width: Integer).returns(String) }
      def self.encode(plain, width); end
    end

    # PLAIN encoding for all physical types. Values are returned in their physical
    # Ruby form (Integer, Float, true/false, binary String); logical conversion happens elsewhere.
    # 
    # @api private
    module Plain
      # Decodes +count+ values of +type+ from +data+ starting at +pos+.
      # Returns [values, new_pos].
      # INT96 values come back as [nanoseconds_of_day, julian_day] pairs.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@param_ `type` — physical type, a Format::Type constant
      # 
      # _@param_ `type_length` — byte width, required for FIXED_LEN_BYTE_ARRAY
      # 
      # _@return_ — the decoded values and the offset just past them
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          type: Integer,
          type_length: T.nilable(Integer)
        ).returns([T::Array[T.untyped], Integer])
      end
      def decode(data, pos, count, type, type_length = nil); end

      # Decodes +count+ values of +type+ from +data+ starting at +pos+.
      # Returns [values, new_pos].
      # INT96 values come back as [nanoseconds_of_day, julian_day] pairs.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first value
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@param_ `type` — physical type, a Format::Type constant
      # 
      # _@param_ `type_length` — byte width, required for FIXED_LEN_BYTE_ARRAY
      # 
      # _@return_ — the decoded values and the offset just past them
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          type: Integer,
          type_length: T.nilable(Integer)
        ).returns([T::Array[T.untyped], Integer])
      end
      def self.decode(data, pos, count, type, type_length = nil); end

      # Decodes PLAIN BYTE_ARRAY values: each is a 4-byte little-endian length followed by the bytes.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first length prefix
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary slices of +data+ and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def decode_byte_arrays(data, pos, count); end

      # Decodes PLAIN BYTE_ARRAY values: each is a 4-byte little-endian length followed by the bytes.
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first length prefix
      # 
      # _@param_ `count` — number of values to decode
      # 
      # _@return_ — binary slices of +data+ and the offset just past them
      sig { params(data: String, pos: Integer, count: Integer).returns([T::Array[String], Integer]) }
      def self.decode_byte_arrays(data, pos, count); end

      # Encodes values of a physical type with PLAIN. Inverse of decode; INT96 values are
      # [nanoseconds_of_day, julian_day] pairs and booleans are packed LSB-first, 8 per byte.
      # 
      # _@param_ `values` — values in their physical Ruby form, without nulls
      # 
      # _@param_ `type` — physical type, a Format::Type constant
      # 
      # _@param_ `type_length` — byte width, required for FIXED_LEN_BYTE_ARRAY
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[T.untyped], type: Integer, type_length: T.nilable(Integer)).returns(String) }
      def encode(values, type, type_length = nil); end

      # Encodes values of a physical type with PLAIN. Inverse of decode; INT96 values are
      # [nanoseconds_of_day, julian_day] pairs and booleans are packed LSB-first, 8 per byte.
      # 
      # _@param_ `values` — values in their physical Ruby form, without nulls
      # 
      # _@param_ `type` — physical type, a Format::Type constant
      # 
      # _@param_ `type_length` — byte width, required for FIXED_LEN_BYTE_ARRAY
      # 
      # _@return_ — encoded bytes in ASCII-8BIT
      sig { params(values: T::Array[T.untyped], type: Integer, type_length: T.nilable(Integer)).returns(String) }
      def self.encode(values, type, type_length = nil); end
    end
  end

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
    # _@param_ `id` — the id; nil for the key's fingerprint
    # 
    # _@param_ `bits` — 128, 192 or 256
    # 
    # _@return_ — a random key
    sig { params(id: T.nilable(String), bits: Integer).returns(Key) }
    def self.generate(id: nil, bits: 256); end

    # _@param_ `hex` — 32, 48 or 64 hex digits
    # 
    # _@param_ `id` — the id; nil for the key's fingerprint
    sig { params(hex: String, id: T.nilable(String)).returns(Key) }
    def self.from_hex(hex, id: nil); end

    # A Key, or a key given as its hex (with the fingerprint id): 32, 48 or 64 hex digits, as
    # +Key#hex+ gives them and as keys usually sit in environment variables. Any other String is
    # refused, raw key bytes included: those go through Key.new, so a key is never guessed at.
    # 
    # _@param_ `value` — a key, or its hex
    sig { params(value: T.any(Key, String)).returns(Key) }
    def self.from(value); end

    # _@param_ `bytes` — 16, 24 or 32 bytes (AES-128, 192 or 256)
    # 
    # _@return_ — the fingerprint of +bytes+: 16 hex digits of an HMAC-SHA256 keyed with them
    sig { params(bytes: String).returns(String) }
    def self.fingerprint(bytes); end

    # _@param_ `bytes` — 16, 24 or 32 bytes (AES-128, 192 or 256); +Key.generate+ makes one
    # 
    # _@param_ `id` — the id; nil for the key's fingerprint
    sig { params(bytes: String, id: T.nilable(String)).void }
    def initialize(bytes, id: nil); end

    # _@return_ — the key material as hex
    sig { returns(String) }
    def hex; end

    # _@return_ — 128, 192 or 256
    sig { returns(Integer) }
    def bits; end

    # _@param_ `other` — object to compare with
    # 
    # _@return_ — whether +other+ is a Key with the same id and bytes
    sig { params(other: Object).returns(T::Boolean) }
    def ==(other); end

    # _@return_ — hash of the id and bytes
    sig { returns(Integer) }
    def hash; end

    # _@return_ — the id and size, without the key
    sig { returns(String) }
    def inspect; end

    # _@return_ — the id stored in files encrypted with the key
    sig { returns(String) }
    attr_reader :id

    # _@return_ — the key material, 16, 24 or 32 bytes (binary)
    sig { returns(String) }
    attr_reader :bytes
  end

  # Conversion between physical Parquet values and Ruby objects, driven by the
  # logical type (or legacy converted type) of a column.
  # 
  #   STRING/ENUM/JSON      <-> String (UTF-8)
  #   BYTE_ARRAY/FLBA/BSON  <-> String (binary)
  #   INTEGER (signed/uns.) <-> Integer
  #   DATE                  <-> Date
  #   TIMESTAMP, INT96      <-> Time (UTC)
  #   TIME                  <-> Integer in the column's unit since midnight
  #   DECIMAL               <-> BigDecimal
  #   UUID                  <-> String "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  #   FLOAT16               <-> Float
  # 
  # @api private
  module Types
    # Shorthand for building a LogicalType union.
    # 
    # _@param_ `kw` — the single union member to set; any LogicalType field is accepted, those used in this module are listed below
    sig { params(kw: T::Hash[Symbol, Thrift::Struct]).returns(Format::LogicalType) }
    def lt(**kw); end

    # Shorthand for building a LogicalType union.
    # 
    # _@param_ `kw` — the single union member to set; any LogicalType field is accepted, those used in this module are listed below
    sig { params(kw: T::Hash[Symbol, Thrift::Struct]).returns(Format::LogicalType) }
    def self.lt(**kw); end

    # TimeUnit union for a unit name.
    # 
    # _@param_ `unit` — +:millis+/+:ms+, +:micros+/+:us+ or +:nanos+/+:ns+
    sig { params(unit: T.any(Symbol, String)).returns(Format::TimeUnit) }
    def time_unit(unit); end

    # TimeUnit union for a unit name.
    # 
    # _@param_ `unit` — +:millis+/+:ms+, +:micros+/+:us+ or +:nanos+/+:ns+
    sig { params(unit: T.any(Symbol, String)).returns(Format::TimeUnit) }
    def self.time_unit(unit); end

    # Physical attributes of an annotated integer column, with both the INTEGER logical type
    # and the matching INT_n/UINT_n converted type.
    # 
    # _@param_ `bits` — bit width: 8, 16, 32 or 64 (64 is stored as INT64, the rest as INT32)
    # 
    # _@param_ `signed` — whether the integers are signed
    # 
    # _@return_ — +:type+, +:converted_type+ and +:logical_type+
    sig { params(bits: Integer, signed: T::Boolean).returns(T::Hash[Symbol, Object]) }
    def int_type(bits, signed); end

    # Physical attributes of an annotated integer column, with both the INTEGER logical type
    # and the matching INT_n/UINT_n converted type.
    # 
    # _@param_ `bits` — bit width: 8, 16, 32 or 64 (64 is stored as INT64, the rest as INT32)
    # 
    # _@param_ `signed` — whether the integers are signed
    # 
    # _@return_ — +:type+, +:converted_type+ and +:logical_type+
    sig { params(bits: Integer, signed: T::Boolean).returns(T::Hash[Symbol, Object]) }
    def self.int_type(bits, signed); end

    # Physical attributes (type, logical type etc.) for a DSL type name
    # 
    # _@param_ `type` — column type name, e.g. +:string+, +:int64+, +:decimal+, +:timestamp+
    # 
    # _@param_ `opts` — type-specific options
    # 
    # _@return_ — keyword arguments for Schema::Node.new: +:type+ and,
    # where applicable, +:type_length+, +:converted_type+, +:logical_type+, +:scale+, +:precision+
    sig { params(type: T.any(Symbol, String), opts: T::Hash[Symbol, Object]).returns(T::Hash[Symbol, Object]) }
    def physical_attributes(type, **opts); end

    # Physical attributes (type, logical type etc.) for a DSL type name
    # 
    # _@param_ `type` — column type name, e.g. +:string+, +:int64+, +:decimal+, +:timestamp+
    # 
    # _@param_ `opts` — type-specific options
    # 
    # _@return_ — keyword arguments for Schema::Node.new: +:type+ and,
    # where applicable, +:type_length+, +:converted_type+, +:logical_type+, +:scale+, +:precision+
    sig { params(type: T.any(Symbol, String), opts: T::Hash[Symbol, Object]).returns(T::Hash[Symbol, Object]) }
    def self.physical_attributes(type, **opts); end

    # Minimal number of bytes to hold a signed integer of +precision+ decimal digits
    # 
    # _@param_ `precision` — number of decimal digits
    # 
    # _@return_ — byte length for a FIXED_LEN_BYTE_ARRAY decimal
    sig { params(precision: Integer).returns(Integer) }
    def decimal_bytes(precision); end

    # Minimal number of bytes to hold a signed integer of +precision+ decimal digits
    # 
    # _@param_ `precision` — number of decimal digits
    # 
    # _@return_ — byte length for a FIXED_LEN_BYTE_ARRAY decimal
    sig { params(precision: Integer).returns(Integer) }
    def self.decimal_bytes(precision); end

    # Normalized logical kind of a node: [symbol, details]
    # 
    # The LogicalType wins when present; otherwise the legacy converted type is mapped onto
    # the same shapes. Details depend on the kind:
    #   [:integer, bit_width, signed]
    #   [:decimal, scale, precision]
    #   [:timestamp, unit, adjusted_to_utc]   (unit is :millis, :micros or :nanos)
    #   [:time, unit, adjusted_to_utc]
    #   [kind]                                for other annotations (:string, :date, :uuid ...)
    #   [nil]                                 for unannotated columns
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — kind Symbol (or nil) followed by its details
    sig { params(node: Schema::Node).returns(T::Array[T.untyped]) }
    def logical_of(node); end

    # Normalized logical kind of a node: [symbol, details]
    # 
    # The LogicalType wins when present; otherwise the legacy converted type is mapped onto
    # the same shapes. Details depend on the kind:
    #   [:integer, bit_width, signed]
    #   [:decimal, scale, precision]
    #   [:timestamp, unit, adjusted_to_utc]   (unit is :millis, :micros or :nanos)
    #   [:time, unit, adjusted_to_utc]
    #   [kind]                                for other annotations (:string, :date, :uuid ...)
    #   [nil]                                 for unannotated columns
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — kind Symbol (or nil) followed by its details
    sig { params(node: Schema::Node).returns(T::Array[T.untyped]) }
    def self.logical_of(node); end

    # Returns a lambda converting a physical value into a Ruby value, or nil when no conversion is needed.
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — one-argument converter, or nil when decoded values are used as-is
    sig { params(node: Schema::Node).returns(T.nilable(Proc)) }
    def reader_for(node); end

    # Returns a lambda converting a physical value into a Ruby value, or nil when no conversion is needed.
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — one-argument converter, or nil when decoded values are used as-is
    sig { params(node: Schema::Node).returns(T.nilable(Proc)) }
    def self.reader_for(node); end

    # Converter from an INT64 timestamp to a UTC Time.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@return_ — lambda taking an Integer count of +unit+ since the epoch
    sig { params(unit: Symbol).returns(Proc) }
    def timestamp_reader(unit); end

    # Converter from an INT64 timestamp to a UTC Time.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@return_ — lambda taking an Integer count of +unit+ since the epoch
    sig { params(unit: Symbol).returns(Proc) }
    def self.timestamp_reader(unit); end

    # Converter from a decoded INT96 value to a UTC Time.
    # 
    # _@return_ — lambda taking a +[nanoseconds_of_day, julian_day]+ pair
    sig { returns(Proc) }
    def int96_reader; end

    # Converter from a decoded INT96 value to a UTC Time.
    # 
    # _@return_ — lambda taking a +[nanoseconds_of_day, julian_day]+ pair
    sig { returns(Proc) }
    def self.int96_reader; end

    # Converter from a stored unscaled decimal to a BigDecimal.
    # 
    # _@param_ `type` — physical type (Format::Type) of the column
    # 
    # _@param_ `scale` — digits after the decimal point
    # 
    # _@return_ — lambda taking an Integer (INT32/INT64) or big-endian two's complement
    # bytes (BYTE_ARRAY/FIXED_LEN_BYTE_ARRAY), or nil for any other physical type
    sig { params(type: Integer, scale: Integer).returns(T.nilable(Proc)) }
    def decimal_reader(type, scale); end

    # Converter from a stored unscaled decimal to a BigDecimal.
    # 
    # _@param_ `type` — physical type (Format::Type) of the column
    # 
    # _@param_ `scale` — digits after the decimal point
    # 
    # _@return_ — lambda taking an Integer (INT32/INT64) or big-endian two's complement
    # bytes (BYTE_ARRAY/FIXED_LEN_BYTE_ARRAY), or nil for any other physical type
    sig { params(type: Integer, scale: Integer).returns(T.nilable(Proc)) }
    def self.decimal_reader(type, scale); end

    # Big-endian two's complement bytes to Integer
    # 
    # _@param_ `bytes` — binary string; empty decodes as 0
    sig { params(bytes: String).returns(Integer) }
    def be_to_int(bytes); end

    # Big-endian two's complement bytes to Integer
    # 
    # _@param_ `bytes` — binary string; empty decodes as 0
    sig { params(bytes: String).returns(Integer) }
    def self.be_to_int(bytes); end

    # Integer to big-endian two's complement bytes of a fixed width
    # 
    # _@param_ `i` — value to encode
    # 
    # _@param_ `nbytes` — output width in bytes
    # 
    # _@return_ — binary string of +nbytes+ bytes
    sig { params(i: Integer, nbytes: Integer).returns(String) }
    def int_to_be(i, nbytes); end

    # Integer to big-endian two's complement bytes of a fixed width
    # 
    # _@param_ `i` — value to encode
    # 
    # _@param_ `nbytes` — output width in bytes
    # 
    # _@return_ — binary string of +nbytes+ bytes
    sig { params(i: Integer, nbytes: Integer).returns(String) }
    def self.int_to_be(i, nbytes); end

    # Decodes an IEEE 754 half-precision value, including subnormals, infinities and NaN.
    # 
    # _@param_ `h` — 16-bit pattern
    sig { params(h: Integer).returns(Float) }
    def half_to_float(h); end

    # Decodes an IEEE 754 half-precision value, including subnormals, infinities and NaN.
    # 
    # _@param_ `h` — 16-bit pattern
    sig { params(h: Integer).returns(Float) }
    def self.half_to_float(h); end

    # Rounds a Float to the nearest half-precision value (ties to even). Every step is exact
    # in double arithmetic, so there is no double rounding.
    # 
    # _@param_ `f` — value to round; overflows to infinity, NaN becomes the canonical quiet NaN
    # 
    # _@return_ — 16-bit pattern
    sig { params(f: Float).returns(Integer) }
    def float_to_half(f); end

    # Rounds a Float to the nearest half-precision value (ties to even). Every step is exact
    # in double arithmetic, so there is no double rounding.
    # 
    # _@param_ `f` — value to round; overflows to infinity, NaN becomes the canonical quiet NaN
    # 
    # _@return_ — 16-bit pattern
    sig { params(f: Float).returns(Integer) }
    def self.float_to_half(f); end

    # Returns a lambda converting a Ruby value into the physical value for +node+.
    # Besides the canonical Ruby type of each column (see the table at the top), columns accept
    # the values Rails and plain Ruby code commonly hand over:
    #   date:      Date, Time/DateTime (its calendar date), ISO-8601 String, Integer days since epoch
    #   timestamp: Time, DateTime, ActiveSupport::TimeWithZone, Date (midnight UTC), ISO-8601 String,
    #              Integer in the column's unit
    #   time:      Time (its time of day), "HH:MM[:SS[.fraction]]" String, Integer in the column's unit
    #   json:      String (used as-is) or any other object (serialized with JSON.generate)
    #   string:    String, Symbol or anything responding to to_s
    #   boolean:   true/false, 1/0, "true"/"false", "t"/"f", "1"/"0", "yes"/"no"
    #   integers:  Integer, or a Float/BigDecimal/Rational/String holding a whole number
    #   decimal:   BigDecimal, Integer, Rational, Float or numeric String
    #   uuid:      String with or without dashes, or 16 raw bytes
    # The returned lambda raises ArgumentError or RangeError for values it cannot convert.
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — one-argument converter; nil only for a column with no recognized
    # physical type
    sig { params(node: Schema::Node).returns(T.nilable(Proc)) }
    def writer_for(node); end

    # Returns a lambda converting a Ruby value into the physical value for +node+.
    # Besides the canonical Ruby type of each column (see the table at the top), columns accept
    # the values Rails and plain Ruby code commonly hand over:
    #   date:      Date, Time/DateTime (its calendar date), ISO-8601 String, Integer days since epoch
    #   timestamp: Time, DateTime, ActiveSupport::TimeWithZone, Date (midnight UTC), ISO-8601 String,
    #              Integer in the column's unit
    #   time:      Time (its time of day), "HH:MM[:SS[.fraction]]" String, Integer in the column's unit
    #   json:      String (used as-is) or any other object (serialized with JSON.generate)
    #   string:    String, Symbol or anything responding to to_s
    #   boolean:   true/false, 1/0, "true"/"false", "t"/"f", "1"/"0", "yes"/"no"
    #   integers:  Integer, or a Float/BigDecimal/Rational/String holding a whole number
    #   decimal:   BigDecimal, Integer, Rational, Float or numeric String
    #   uuid:      String with or without dashes, or 16 raw bytes
    # The returned lambda raises ArgumentError or RangeError for values it cannot convert.
    # 
    # _@param_ `node` — leaf node of the physical schema
    # 
    # _@return_ — one-argument converter; nil only for a column with no recognized
    # physical type
    sig { params(node: Schema::Node).returns(T.nilable(Proc)) }
    def self.writer_for(node); end

    # Coerces a value to true/false using BOOLEANS.
    # 
    # _@param_ `v` — true/false, 1/0, or a String/Symbol such as "yes" or :false
    sig { params(v: Object).returns(T::Boolean) }
    def to_boolean(v); end

    # Coerces a value to true/false using BOOLEANS.
    # 
    # _@param_ `v` — true/false, 1/0, or a String/Symbol such as "yes" or :false
    sig { params(v: Object).returns(T::Boolean) }
    def self.to_boolean(v); end

    # Days since the Unix epoch in the proleptic Gregorian calendar, as stored in DATE columns.
    # 
    # _@param_ `v` — a Date, an ISO-8601 date String, an Integer (returned as-is) or anything responding to +to_date+ (Time, DateTime)
    sig { params(v: T.any(Date, String, Integer, T.untyped)).returns(Integer) }
    def date_to_days(v); end

    # Days since the Unix epoch in the proleptic Gregorian calendar, as stored in DATE columns.
    # 
    # _@param_ `v` — a Date, an ISO-8601 date String, an Integer (returned as-is) or anything responding to +to_date+ (Time, DateTime)
    sig { params(v: T.any(Date, String, Integer, T.untyped)).returns(Integer) }
    def self.date_to_days(v); end

    # Converts the values a timestamp column accepts into a Time (or Time-like) object
    # 
    # _@param_ `v` — a Time, DateTime, Date (taken as midnight UTC), ISO-8601 (or +Time.parse+-able) String, or a Time-like object responding to +to_i+ and +nsec+
    # 
    # _@return_ — a Time, or +v+ itself when it is Time-like
    sig { params(v: T.any(Time, DateTime, Date, String, T.untyped)).returns(T.any(Time, Object)) }
    def to_time(v); end

    # Converts the values a timestamp column accepts into a Time (or Time-like) object
    # 
    # _@param_ `v` — a Time, DateTime, Date (taken as midnight UTC), ISO-8601 (or +Time.parse+-able) String, or a Time-like object responding to +to_i+ and +nsec+
    # 
    # _@return_ — a Time, or +v+ itself when it is Time-like
    sig { params(v: T.any(Time, DateTime, Date, String, T.untyped)).returns(T.any(Time, Object)) }
    def self.to_time(v); end

    # Converter from a timestamp-like value to an INT64 count of +unit+ since the epoch.
    # Integers pass through unchanged; sub-unit precision is truncated.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@param_ `utc` — whether the column is adjusted to UTC; when false the local wall clock time of the value (its UTC offset added) is stored
    # 
    # _@return_ — one-argument lambda, see {to_time} for accepted values
    sig { params(unit: Symbol, utc: T::Boolean).returns(Proc) }
    def timestamp_writer(unit, utc); end

    # Converter from a timestamp-like value to an INT64 count of +unit+ since the epoch.
    # Integers pass through unchanged; sub-unit precision is truncated.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@param_ `utc` — whether the column is adjusted to UTC; when false the local wall clock time of the value (its UTC offset added) is stored
    # 
    # _@return_ — one-argument lambda, see {to_time} for accepted values
    sig { params(unit: Symbol, utc: T::Boolean).returns(Proc) }
    def self.timestamp_writer(unit, utc); end

    # Converter from a time of day to a count of +unit+ since midnight.
    # The lambda accepts an Integer (returned as-is), an "HH:MM[:SS[.fraction]]" String or
    # anything responding to +hour+ and +nsec+ (Time, DateTime), and raises ArgumentError or
    # RangeError for anything else or a time past 23:59:59.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@return_ — one-argument lambda
    sig { params(unit: Symbol).returns(Proc) }
    def time_writer(unit); end

    # Converter from a time of day to a count of +unit+ since midnight.
    # The lambda accepts an Integer (returned as-is), an "HH:MM[:SS[.fraction]]" String or
    # anything responding to +hour+ and +nsec+ (Time, DateTime), and raises ArgumentError or
    # RangeError for anything else or a time past 23:59:59.
    # 
    # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
    # 
    # _@return_ — one-argument lambda
    sig { params(unit: Symbol).returns(Proc) }
    def self.time_writer(unit); end

    # String column restricted to a set of values. +values+ is an Array of labels, or a Hash of
    # label => stored value like Rails' `Model.statuses`, in which case either is accepted.
    # Symbols are accepted in place of String labels.
    # 
    # _@param_ `values` — allowed labels
    # 
    # _@return_ — lambda returning the String label, raising ArgumentError for any other value
    sig { params(values: T.any(T::Array[T.any(String, Symbol)], T::Hash[T.any(String, Symbol), Object])).returns(Proc) }
    def enum_writer(values); end

    # String column restricted to a set of values. +values+ is an Array of labels, or a Hash of
    # label => stored value like Rails' `Model.statuses`, in which case either is accepted.
    # Symbols are accepted in place of String labels.
    # 
    # _@param_ `values` — allowed labels
    # 
    # _@return_ — lambda returning the String label, raising ArgumentError for any other value
    sig { params(values: T.any(T::Array[T.any(String, Symbol)], T::Hash[T.any(String, Symbol), Object])).returns(Proc) }
    def self.enum_writer(values); end

    # Converts to Integer, rejecting fractional numbers and values outside min..max
    # 
    # _@param_ `min` — smallest accepted value
    # 
    # _@param_ `max` — largest accepted value
    # 
    # _@return_ — lambda raising ArgumentError for non-integers and RangeError when out of range
    sig { params(min: Integer, max: Integer).returns(Proc) }
    def int_checker(min, max); end

    # Converts to Integer, rejecting fractional numbers and values outside min..max
    # 
    # _@param_ `min` — smallest accepted value
    # 
    # _@param_ `max` — largest accepted value
    # 
    # _@return_ — lambda raising ArgumentError for non-integers and RangeError when out of range
    sig { params(min: Integer, max: Integer).returns(Proc) }
    def self.int_checker(min, max); end

    # Wraps a conversion to a String and checks the result has exactly +length+ bytes.
    # 
    # _@param_ `length` — required byte length
    # 
    # _@return_ — lambda raising ArgumentError when the converted String has another length
    sig { params(length: Integer, convert: T.proc.params(v: Object).returns(String)).returns(Proc) }
    def fixed_checker(length, &convert); end

    # Wraps a conversion to a String and checks the result has exactly +length+ bytes.
    # 
    # _@param_ `length` — required byte length
    # 
    # _@return_ — lambda raising ArgumentError when the converted String has another length
    sig { params(length: Integer, convert: T.proc.params(v: Object).returns(String)).returns(Proc) }
    def self.fixed_checker(length, &convert); end

    # Converter from a numeric value to the stored unscaled decimal. Values are rounded
    # (half away from zero) to +scale+ digits; the lambda raises RangeError when the result
    # exceeds the column's precision.
    # 
    # _@param_ `node` — DECIMAL leaf node, for its physical type, precision and type length
    # 
    # _@param_ `scale` — digits after the decimal point
    # 
    # _@return_ — lambda returning an Integer (INT32/INT64) or big-endian two's complement
    # bytes (FIXED_LEN_BYTE_ARRAY, BYTE_ARRAY with minimal length), or nil for any other
    # physical type
    sig { params(node: Schema::Node, scale: Integer).returns(T.nilable(Proc)) }
    def decimal_writer(node, scale); end

    # Converter from a numeric value to the stored unscaled decimal. Values are rounded
    # (half away from zero) to +scale+ digits; the lambda raises RangeError when the result
    # exceeds the column's precision.
    # 
    # _@param_ `node` — DECIMAL leaf node, for its physical type, precision and type length
    # 
    # _@param_ `scale` — digits after the decimal point
    # 
    # _@return_ — lambda returning an Integer (INT32/INT64) or big-endian two's complement
    # bytes (FIXED_LEN_BYTE_ARRAY, BYTE_ARRAY with minimal length), or nil for any other
    # physical type
    sig { params(node: Schema::Node, scale: Integer).returns(T.nilable(Proc)) }
    def self.decimal_writer(node, scale); end
  end

  # Parquet file metadata structures, mirroring parquet.thrift.
  # Enums are plain i32 on the wire; constants below give them names.
  module Format
    # Physical storage types (+Type+ enum in parquet.thrift).
    module Type
    end

    # Legacy type annotations (+ConvertedType+ enum), superseded by LogicalType but still
    # written alongside it for older readers.
    module ConvertedType
    end

    # Field repetition (+FieldRepetitionType+ enum).
    module Repetition
    end

    # Value and level encodings (+Encoding+ enum). Value 1 (GROUP_VAR_INT) was never used.
    module Encoding
    end

    # Page compression codecs (+CompressionCodec+ enum).
    module Codec
    end

    # Page types (+PageType+ enum).
    module PageType
    end

    # Byte and level-histogram statistics for a page or column chunk.
    class SizeStatistics < Herringbone::Format::S
    end

    # Min/max and count statistics for a page or column chunk. +max+/+min+ are the deprecated
    # signed-order fields; +max_value+/+min_value+ use the column's sort order.
    class Statistics < Herringbone::Format::S
    end

    # STRING logical type.
    class StringType < Herringbone::Format::S
    end

    # UUID logical type (16-byte FIXED_LEN_BYTE_ARRAY).
    class UUIDType < Herringbone::Format::S
    end

    # MAP logical type.
    class MapType < Herringbone::Format::S
    end

    # LIST logical type.
    class ListType < Herringbone::Format::S
    end

    # ENUM logical type.
    class EnumType < Herringbone::Format::S
    end

    # DATE logical type.
    class DateType < Herringbone::Format::S
    end

    # FLOAT16 logical type (2-byte FIXED_LEN_BYTE_ARRAY, little-endian half precision).
    class Float16Type < Herringbone::Format::S
    end

    # UNKNOWN logical type: the column is always null.
    class NullType < Herringbone::Format::S
    end

    # JSON logical type.
    class JsonType < Herringbone::Format::S
    end

    # BSON logical type.
    class BsonType < Herringbone::Format::S
    end

    # Millisecond member of the TimeUnit union.
    class MilliSeconds < Herringbone::Format::S
    end

    # Microsecond member of the TimeUnit union.
    class MicroSeconds < Herringbone::Format::S
    end

    # Nanosecond member of the TimeUnit union.
    class NanoSeconds < Herringbone::Format::S
    end

    # ColumnOrder member: values are ordered according to their (logical) type.
    class TypeDefinedOrder < Herringbone::Format::S
    end

    # Header of an index page; has no fields in the spec.
    class IndexPageHeader < Herringbone::Format::S
    end

    # VARIANT logical type.
    class VariantType < Herringbone::Format::S
    end

    # DECIMAL logical type: unscaled integer value divided by 10 to the power of +scale+.
    class DecimalType < Herringbone::Format::S
    end

    # Union of time units for TIME and TIMESTAMP; exactly one member is set.
    class TimeUnit < Herringbone::Format::S
      # _@return_ — a unit with the +millis+ member set
      sig { returns(TimeUnit) }
      def self.millis; end

      # _@return_ — a unit with the +micros+ member set
      sig { returns(TimeUnit) }
      def self.micros; end

      # _@return_ — a unit with the +nanos+ member set
      sig { returns(TimeUnit) }
      def self.nanos; end

      # _@return_ — +:millis+, +:micros+ or +:nanos+, or nil when no member is set
      sig { returns(T.nilable(Symbol)) }
      def to_sym; end
    end

    # TIMESTAMP logical type.
    class TimestampType < Herringbone::Format::S
    end

    # TIME logical type.
    class TimeType < Herringbone::Format::S
    end

    # INTEGER logical type (bit width 8, 16, 32 or 64; signed or unsigned).
    class IntType < Herringbone::Format::S
    end

    # Union of logical type annotations; exactly one member is set. Field id 9 is reserved
    # (for INTERVAL) in parquet.thrift.
    class LogicalType < Herringbone::Format::S
      # Returns [kind_symbol, payload] for whichever union member is set
      # 
      # _@return_ — member name and its struct, or nil when
      # no member is set
      sig { returns(T.nilable([Symbol, Thrift::Struct])) }
      def kind; end
    end

    # One node of the schema, flattened depth-first into +FileMetaData#schema+. Groups carry
    # +num_children+; leaves carry the physical +type+.
    class SchemaElement < Herringbone::Format::S
    end

    # Header of a v1 data page: levels and values share one compressed block.
    class DataPageHeader < Herringbone::Format::S
    end

    # Header of a dictionary page.
    class DictionaryPageHeader < Herringbone::Format::S
    end

    # Header of a v2 data page: levels are stored uncompressed before the (optionally
    # compressed) values, with their byte lengths given here.
    class DataPageHeaderV2 < Herringbone::Format::S
    end

    # Header preceding every page; +type+ (a PageType) says which sub-header is set.
    class PageHeader < Herringbone::Format::S
    end

    # Application-defined key/value metadata entry.
    class KeyValue < Herringbone::Format::S
    end

    # Sort order of one column within a row group.
    class SortingColumn < Herringbone::Format::S
    end

    # Number of pages of a given type and encoding in a column chunk.
    class PageEncodingStats < Herringbone::Format::S
    end

    # Metadata of a column chunk: where its pages are, how they are encoded and compressed.
    class ColumnMetaData < Herringbone::Format::S
    end

    # Algorithm settings shared by both algorithms: the AAD prefix (unless readers must supply
    # it) and the file's unique id, which together make the file's part of every module's AAD.
    class AesGcmV1 < Herringbone::Format::S
    end

    # AES_GCM_CTR_V1: like AesGcmV1, but pages are encrypted with AES-CTR, without a tag.
    class AesGcmCtrV1 < Herringbone::Format::S
    end

    # Union of encryption algorithms; exactly one member is set.
    class EncryptionAlgorithm < Herringbone::Format::S
      # _@return_ — whichever member is set
      sig { returns(T.nilable(T.any(AesGcmV1, AesGcmCtrV1))) }
      def settings; end
    end

    # ColumnCryptoMetaData member: the column is encrypted with the footer key.
    class EncryptionWithFooterKey < Herringbone::Format::S
    end

    # ColumnCryptoMetaData member: the column is encrypted with a key of its own.
    class EncryptionWithColumnKey < Herringbone::Format::S
    end

    # Union saying which key an encrypted column uses; exactly one member is set.
    class ColumnCryptoMetaData < Herringbone::Format::S
    end

    # Stored in the clear before an encrypted footer (files with the PARE magic).
    class FileCryptoMetaData < Herringbone::Format::S
    end

    # One column of a row group, plus the locations of its page index. In encrypted columns
    # +crypto_metadata+ names the key, and +encrypted_column_metadata+ holds the ColumnMetaData
    # when it is encrypted on its own.
    class ColumnChunk < Herringbone::Format::S
    end

    # A horizontal slice of the file, holding one ColumnChunk per leaf column.
    class RowGroup < Herringbone::Format::S
    end

    # Ordering of the per-page min/max values in a ColumnIndex (+BoundaryOrder+ enum).
    module BoundaryOrder
    end

    # Location of one data page within the file.
    class PageLocation < Herringbone::Format::S
    end

    # Offset index of a column chunk: the location of each of its data pages.
    class OffsetIndex < Herringbone::Format::S
    end

    # Column index of a column chunk: per-page min/max values and null information.
    class ColumnIndex < Herringbone::Format::S
    end

    # Union describing how min/max statistics of a column are ordered.
    class ColumnOrder < Herringbone::Format::S
    end

    # The file footer: schema, row groups and file-level metadata. The encryption fields are
    # only set in encrypted files with a plaintext footer.
    class FileMetaData < Herringbone::Format::S
    end

    # Split block bloom filter algorithm.
    class SplitBlockAlgorithm < Herringbone::Format::S
    end

    # XXH64 hash with seed 0.
    class XxHash < Herringbone::Format::S
    end

    # Bloom filter bitset stored uncompressed.
    class BloomFilterUncompressed < Herringbone::Format::S
    end

    # Union of bloom filter algorithms.
    class BloomFilterAlgorithm < Herringbone::Format::S
    end

    # Union of hash functions used to feed the bloom filter.
    class BloomFilterHash < Herringbone::Format::S
    end

    # Union of bloom filter compressions.
    class BloomFilterCompression < Herringbone::Format::S
    end

    # Header preceding the bitset of a column chunk's bloom filter.
    class BloomFilterHeader < Herringbone::Format::S
    end
  end

  # Reads Parquet files from a random-access IO. Herringbone never opens files by path: the
  # caller opens (and closes) the IO.
  # 
  #   File.open("data.parquet", "rb") do |file|
  #     reader = Herringbone::Reader.new(file)
  #     reader.each_row { |row| p row }                       # rows as Hashes with String keys
  #     reader.each_batch(1000, as: :columns) { |batch| ... }  # { "id" => [...], ... } per batch
  #     reader.read(columns: ["id"], where: { id: 1..10 })     # everything at once
  #   end
  # 
  # Rows are read in batches: pages are read and decoded one at a time per column, so memory use
  # depends on the batch size and the page size, not on the size of the row groups.
  # 
  # Options:
  #   keys:      :string (default) or :symbol, for row Hashes and Hashes built from structs.
  #              Map keys are always the stored values.
  #   time_zone: return timestamps in this zone instead of UTC. A UTC offset ("+02:00", or
  #              seconds as an Integer), a timezone object Time#getlocal accepts (e.g. a
  #              TZInfo::Timezone), or anything responding to #at such as an
  #              ActiveSupport::TimeZone (Time.zone), which yields ActiveSupport::TimeWithZone.
  #   decryption: keys for a file written with Parquet modular encryption:
  #              { footer_key: "...", columns: { "ssn" => "..." }, aad_prefix: "..." }, and/or
  #              keys: ->(key_metadata) { ... } (or a Hash) to look keys up by the key metadata
  #              stored in the file. Keys are 16, 24 or 32-byte Strings. Plaintext columns of a
  #              file with a plaintext footer can be read without keys.
  class Reader
    # +io+ must support #seek and #read (a File opened with "rb", StringIO, Tempfile...). It is
    # read only through a RestrictedReadableIO wrapping it.
    # 
    # _@param_ `io` — random-access source of the Parquet bytes; the caller closes it
    # 
    # _@param_ `keys` — +:string+ or +:symbol+, the key type of row and struct Hashes
    # 
    # _@param_ `time_zone` — zone timestamps are returned in (see the class docs); nil keeps them in UTC
    # 
    # _@param_ `decryption` — keys for an encrypted file (see the class docs); a callable is used as +keys:+
    sig do
      params(
        io: T.any(IO, StringIO, RestrictedReadableIO),
        keys: T.any(Symbol, String),
        time_zone: T.nilable(T.any(String, Integer, Object)),
        decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object], T.untyped))
      ).void
    end
    def initialize(io, keys: :string, time_zone: nil, decryption: nil); end

    # Total number of rows, as stated in the footer (some writers store 0)
    # 
    # _@return_ — the footer's num_rows
    sig { returns(Integer) }
    def num_rows; end

    # The row groups listed in the footer
    # 
    # _@return_ — row group metadata, in file order
    sig { returns(T::Array[Format::RowGroup]) }
    def row_groups; end

    # The footer's key/value metadata as a Hash (what the writer's metadata: option stores)
    # 
    # _@return_ — key => value; empty when the footer has none
    sig { returns(T::Hash[String, T.nilable(String)]) }
    def metadata; end

    # Yields batches of up to +size+ rows (all batches are full except the last one; batches span
    # row groups). Only one page per column and the current batch are held in memory.
    # 
    # as: :rows (default) yields an Array of row Hashes; as: :columns yields a Hash of top-level
    # field name => Array of that field's values in the batch, which skips building a Hash per row
    # and is noticeably faster when you process data column by column. as: :numo yields a Hash of
    # field name => Numo array (needs the numo-narray-alt or numo-narray gem; see NumoColumns
    # for the type mapping). With as: :numo, whether an integer column becomes DFloat (nulls) or
    # a list column 2-D is decided per batch, from the values in it.
    # 
    # where: only yields rows matching all conditions (see Reader::Filter). Row groups and pages
    # that cannot match are skipped using statistics, bloom filters and the page index, and the
    # remaining rows are checked one by one. Filtered columns need not be in +columns+.
    # from: skips the first rows of the file (jumping over pages with the page index), and
    # limit: stops after yielding that many rows.
    # 
    # _@param_ `size` — maximum number of rows per batch
    # 
    # _@param_ `columns` — top-level fields to return; nil returns all of them
    # 
    # _@param_ `as` — +:rows+, +:columns+ or +:numo+, the shape of each batch
    # 
    # _@param_ `where` — column => condition, see Filter
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@param_ `limit` — maximum number of rows to yield in total
    # 
    # _@return_ — self, or an Enumerator of batches when no block is given
    sig do
      params(
        size: Integer,
        columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        as: Symbol,
        where: T.nilable(T::Hash[T.any(String, Symbol), Object]),
        from: T.nilable(Integer),
        limit: T.nilable(Integer),
        blk: T.proc.params(batch: T.any(T::Array[T::Hash[T.untyped, T.untyped]], T::Hash[T.any(String, Symbol), T::Array[T.untyped]], T::Hash[T.any(String, Symbol), Numo::NArray])).void
      ).returns(T.any(Reader, T::Enumerator[T.untyped]))
    end
    def each_batch(size = DEFAULT_BATCH_SIZE, columns: nil, as: :rows, where: nil, from: nil, limit: nil, &blk); end

    # What a read with +where:+ / +from:+ would touch, without reading any data: an Array of
    # { row_group:, rows:, ranges: [[first_row, end_row), ...] } for the row groups that are
    # read. Row groups ruled out entirely are left out.
    # 
    # _@param_ `where` — column => condition, as in #each_batch
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@return_ — +{row_group: Integer, rows: Integer,
    # ranges: Array<Array(Integer, Integer)>}+ per row group that would be read
    sig { params(where: T.nilable(T::Hash[T.any(String, Symbol), Object]), from: T.nilable(Integer)).returns(T::Array[T::Hash[Symbol, Object]]) }
    def scan_plan(where: nil, from: nil); end

    # Yields each row as a Hash of top-level field name => value. Takes the options of each_batch
    # except as:.
    # 
    # _@param_ `columns` — top-level fields to return; nil returns all of them
    # 
    # _@param_ `where` — column => condition, see Filter
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@param_ `limit` — maximum number of rows to yield
    # 
    # _@return_ — self, or an Enumerator of rows when no block is given
    sig do
      params(
        columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        where: T.nilable(T::Hash[T.any(String, Symbol), Object]),
        from: T.nilable(Integer),
        limit: T.nilable(Integer),
        block: T.proc.params(row: T::Hash[T.any(String, Symbol), Object]).void
      ).returns(T.any(Reader, T::Enumerator[T.untyped]))
    end
    def each_row(columns: nil, where: nil, from: nil, limit: nil, &block); end

    # Reads the whole file (or the selected rows) at once: an Array of row Hashes, or with
    # as: :columns a Hash of top-level field name => Array of values, or with as: :numo a Hash of
    # top-level field name => Numo array. Takes the options of each_batch.
    # 
    # _@param_ `columns` — top-level fields to return; nil returns all of them
    # 
    # _@param_ `as` — +:rows+, +:columns+ or +:numo+, the shape of the result
    # 
    # _@param_ `where` — column => condition, see Filter
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@param_ `limit` — maximum number of rows to return
    # 
    # _@return_ — row Hashes (+:rows+), or field name => all values (+:columns+, +:numo+)
    sig do
      params(
        columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        as: Symbol,
        where: T.nilable(T::Hash[T.any(String, Symbol), Object]),
        from: T.nilable(Integer),
        limit: T.nilable(Integer)
      ).returns(T.any(T::Array[T::Hash[T.untyped, T.untyped]], T::Hash[T.any(String, Symbol), T::Array[T.untyped]], T::Hash[T.any(String, Symbol), Numo::NArray]))
    end
    def read(columns: nil, as: :rows, where: nil, from: nil, limit: nil); end

    # Internal (used by reads with where:/from:): [ColumnIndex or nil, OffsetIndex or nil] of a
    # leaf column in a row group. Cached per chunk; a missing or damaged index reads as nil.
    # 
    # _@param_ `row_group_index` — position of the row group in the footer
    # 
    # _@param_ `column` — leaf column, or its dotted / Array path
    # 
    # _@return_ — either element may be nil
    sig { params(row_group_index: Integer, column: T.any(Schema::Column, String, T::Array[String])).returns([Format::ColumnIndex, Format::OffsetIndex]) }
    def page_index(row_group_index, column); end

    # How the file is encrypted, without needing its keys; nil for a file that is not encrypted.
    # +columns+ lists the encrypted columns (as the first row group has them), with the key
    # metadata of their own key, if any, and whether their key is available.
    # 
    #   reader.encryption
    #   # => { algorithm: :aes_gcm, footer: :encrypted, footer_key_metadata: "kf", aad_prefix: nil,
    #   #      supply_aad_prefix: false, footer_verified: false,
    #   #      columns: { "ssn" => { key: :column, key_metadata: "kc1", readable: true } } }
    # 
    # _@return_ — +:algorithm+ (+:aes_gcm+ or +:aes_gcm_ctr+), +:footer+
    # (+:encrypted+ or +:plaintext+), +:footer_key_metadata+, +:aad_prefix+ (when stored),
    # +:supply_aad_prefix+, +:footer_verified+ (whether a plaintext footer's signature was
    # checked) and +:columns+
    sig { returns(T.nilable(T::Hash[Symbol, Object])) }
    def encryption; end

    # Internal: the decryption of one column chunk's modules
    # 
    # _@param_ `row_group_index` — position of the row group in the footer
    # 
    # _@param_ `column` — leaf column
    # 
    # _@return_ — nil when the chunk is not encrypted
    sig { params(row_group_index: Integer, column: Schema::Column).returns(T.nilable(Encryption::ModuleCrypto)) }
    def chunk_crypto(row_group_index, column); end

    # Internal: a ColumnChunkReader for a leaf column of a row group, decrypting when needed
    # 
    # _@param_ `row_group_index` — position of the row group in the footer
    # 
    # _@param_ `column` — leaf column
    # 
    # _@param_ `options` — passed to ColumnChunkReader.new
    sig { params(row_group_index: Integer, column: Schema::Column, options: T::Hash[Symbol, Object]).returns(ColumnChunkReader) }
    def chunk_reader(row_group_index, column, **options); end

    # Short summary for the console, without the schema
    # 
    # _@return_ — row count, row group count and the writer's created_by
    sig { returns(String) }
    def inspect; end

    # as: :numo. Flat numeric/boolean output columns go through NumoCursors (no Ruby object per
    # value); the other output columns, and every column a where: filter needs, are assembled as
    # Ruby values like as: :columns and converted when a batch is complete.
    # 
    # _@param_ `size` — maximum number of rows per batch
    # 
    # _@param_ `columns` — top-level fields to return
    # 
    # _@param_ `where` — column => condition, see Filter
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@param_ `limit` — maximum number of rows to yield in total
    sig do
      params(
        size: Integer,
        columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        where: T.nilable(T::Hash[T.any(String, Symbol), Object]),
        from: T.nilable(Integer),
        limit: T.nilable(Integer),
        blk: T.proc.params(batch: T::Hash[T.any(String, Symbol), Numo::NArray]).void
      ).void
    end
    def each_numo_batch(size, columns, where, from, limit, &blk); end

    # Checks the columns:, where: and from: options of a read that returns no rows (limit: 0),
    # so it raises for bad options like any other read
    # 
    # _@param_ `columns` — top-level fields to return
    # 
    # _@param_ `where` — column => condition, see Filter
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@return_ — self
    sig { params(columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)), where: T.nilable(T::Hash[T.any(String, Symbol), Object]), from: T.nilable(Integer)).returns(Reader) }
    def validate_read_options(columns, where, from); end

    # read(as: :numo) of no rows: an empty array of each column's type
    # 
    # _@param_ `columns` — top-level fields to return
    # 
    # _@return_ — field name => zero-length Numo array
    sig { params(columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol))).returns(T::Hash[T.any(String, Symbol), Numo::NArray]) }
    def numo_empty(columns); end

    # [[row_group_index, [[first_row, end_row), ...]], ...] to read, after ruling out row groups
    # (statistics, bloom filters) and pages (page index), and skipping the first +from+ rows
    # 
    # _@param_ `filter` — the where: conditions, if any
    # 
    # _@param_ `from` — number of rows at the start of the file to skip
    # 
    # _@return_ — row group index and its
    # half-open row ranges, for row groups that have rows left to read
    sig { params(filter: T.nilable(Filter), from: T.nilable(Integer)).returns(T::Array[[Integer, T::Array[[Integer, Integer]]]]) }
    def plan_rows(filter, from); end

    # Decodes one Thrift struct stored elsewhere in the file (ColumnIndex, OffsetIndex)
    # 
    # _@param_ `klass` — Format struct class to decode with (responds to .decode)
    # 
    # _@param_ `offset` — file offset of the struct
    # 
    # _@param_ `length` — byte length of the struct
    # 
    # _@param_ `crypto` — decryption of the chunk's modules
    # 
    # _@param_ `type` — the struct's module type, when encrypted
    # 
    # _@return_ — the decoded +klass+ instance, or nil when absent, truncated or corrupt
    sig do
      params(
        klass: Class,
        offset: T.nilable(Integer),
        length: T.nilable(Integer),
        crypto: T.nilable(Encryption::ModuleCrypto),
        type: T.nilable(Integer)
      ).returns(T.nilable(Object))
    end
    def read_struct(klass, offset, length, crypto = nil, type = nil); end

    # The top-level fields named by a +columns:+ option
    # 
    # _@param_ `columns` — field names; nil selects all
    # 
    # _@return_ — the fields, in the order requested
    sig { params(columns: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol))).returns(T::Array[Schema::Field]) }
    def select_fields(columns); end

    # Hash keys for the given fields (frozen, deduplicated Strings, or Symbols)
    # 
    # _@param_ `fields` — top-level fields being returned
    # 
    # _@param_ `symbolize` — whether to key by Symbol instead of String
    # 
    # _@return_ — one key per field
    sig { params(fields: T::Array[Schema::Field], symbolize: T::Boolean).returns(T.any(T::Array[String], T::Array[Symbol])) }
    def row_keys(fields, symbolize); end

    # Turns column-wise batch data into row Hashes
    # 
    # _@param_ `names` — Hash key per output field
    # 
    # _@param_ `data` — values per output field, each holding +k+ entries
    # 
    # _@param_ `k` — number of rows in the batch
    # 
    # _@return_ — +k+ row Hashes
    sig { params(names: T.any(T::Array[String], T::Array[Symbol]), data: T::Array[T::Array[T.untyped]], k: Integer).returns(T::Array[T::Hash[T.untyped, T.untyped]]) }
    def build_rows(names, data, k); end

    # The column's value converter, with the time zone applied to timestamps
    # 
    # _@param_ `column` — leaf column being read
    # 
    # _@return_ — physical value => Ruby value, or nil when values are used as decoded
    sig { params(column: Schema::Column).returns(T.nilable(Proc)) }
    def converter_for(column); end

    # Timestamps that denote an instant (UTC-adjusted TIMESTAMP, INT96). Local timestamps
    # (isAdjustedToUTC = false) are wall-clock values and are left as they are.
    # 
    # _@param_ `column` — leaf column to check
    # 
    # _@return_ — true when the time zone applies to this column's values
    sig { params(column: Schema::Column).returns(T::Boolean) }
    def instant_column?(column); end

    # A lambda turning a UTC Time into the zone, or nil for UTC
    # 
    # _@param_ `zone` — the +time_zone:+ option: a UTC offset (String or seconds), a zone name (ActiveSupport or TZInfo), an object responding to #at or #utc_to_local, or nil
    # 
    # _@return_ — Time => Time (or ActiveSupport::TimeWithZone), nil for UTC
    sig { params(zone: T.nilable(T.any(String, Integer, Object))).returns(T.nilable(Proc)) }
    def zone_converter(zone); end

    # Reads and decodes the footer: the FileMetaData Thrift struct, its 4-byte little-endian
    # length and the closing magic.
    # 
    # In an encrypted file the footer is decrypted (or its signature checked), and so is the
    # metadata of the columns whose key is available.
    # 
    # _@return_ — the decoded footer
    sig { returns(Format::FileMetaData) }
    def read_footer; end

    # Internal (used by reads with where:): the bloom filter of a column chunk. +column+ is a
    # dotted path ("a.b"), an Array path or a Schema::Column. Returns a BloomFilter, or nil when
    # the chunk has none (or one of an unknown kind).
    # 
    # _@param_ `row_group_index` — index of the row group
    # 
    # _@param_ `column` — the leaf column
    # 
    # _@return_ — the filter, or nil when there is none or it is unsupported
    sig { params(row_group_index: Integer, column: T.any(String, T::Array[T.any(String, Symbol)], Symbol, Schema::Column)).returns(T.nilable(BloomFilter)) }
    def bloom_filter(row_group_index, column); end

    # An encrypted bloom filter: the header and the bitset are two modules, one after the other
    # 
    # _@param_ `offset` — file offset of the header module
    # 
    # _@param_ `col` — the leaf column
    # 
    # _@param_ `crypto` — decryption of the chunk's modules
    # 
    # _@return_ — nil when the filter is of an unsupported kind
    sig { params(offset: Integer, col: Schema::Column, crypto: Encryption::ModuleCrypto).returns(T.nilable(BloomFilter)) }
    def encrypted_bloom_filter(offset, col, crypto); end

    # _@param_ `offset` — file offset of an encrypted module
    # 
    # _@return_ — the module, length prefix included
    sig { params(offset: Integer).returns(String) }
    def read_module_at(offset); end

    # Resolves the +column+ argument of #bloom_filter to a leaf column
    # 
    # _@param_ `column` — dotted path, path Array or column
    # 
    # _@return_ — the column
    sig { params(column: T.any(String, T::Array[T.any(String, Symbol)], Symbol, Schema::Column)).returns(Schema::Column) }
    def bloom_filter_column(column); end

    # _@return_ — the schema, built from the footer's flattened SchemaElements
    sig { returns(Schema) }
    attr_reader :schema

    # _@return_ — the file's FileMetaData (the decoded Thrift footer)
    sig { returns(Format::FileMetaData) }
    attr_reader :file_metadata

    # _@return_ — the IO the file is read from, as given to Reader.new, wrapped
    sig { returns(RestrictedReadableIO) }
    attr_reader :io

    # _@return_ — the keys given as +decryption:+, nil without them
    sig { returns(T.nilable(DecryptionConfiguration)) }
    attr_reader :decryption

    # Internal (used by Redaction and Combiner): the keys and settings of an encrypted file
    # 
    # _@return_ — nil for a file that is not encrypted
    sig { returns(T.nilable(Encryption::FileDecryptor)) }
    attr_reader :decryptor

    # Rebuilds nested values of one top-level field from the levels of its leaf columns
    # (the "record assembly" half of the Dremel algorithm).
    # 
    # @api private
    class Assembler
      # _@param_ `field` — top-level field to assemble
      # 
      # _@param_ `symbolize` — whether struct Hashes are keyed by Symbol instead of String
      sig { params(field: Schema::Field, symbolize: T::Boolean).void }
      def initialize(field, symbolize = false); end

      # Assembles +n+ values of the field from +chunks+ (leaf column index =>
      # [defs, reps, values] holding exactly those rows)
      # 
      # _@param_ `n` — number of rows in +chunks+
      # 
      # _@param_ `chunks` — leaf column index => [definition levels, repetition levels, values]; levels may be nil
      # 
      # _@return_ — +n+ assembled values (nil, scalars, Arrays, Hashes)
      sig { params(n: Integer, chunks: T::Hash[Integer, [T::Array[Integer], T::Array[Integer], T::Array[T.untyped]]]).returns(T::Array[T.untyped]) }
      def read_rows(n, chunks); end

      # Fast path for a top-level list of primitives (the most common nested shape)
      # 
      # _@param_ `field` — list field whose element is a leaf with repetition level 1
      # 
      # _@return_ — one list (or nil) per row
      sig { params(field: Schema::Field).returns(T::Array[T.nilable(T::Array[T.untyped])]) }
      def read_simple_list(field); end

      # Hash key for a struct member, memoized
      # 
      # _@param_ `field` — struct child
      # 
      # _@return_ — frozen name, or Symbol when symbolizing
      sig { params(field: Schema::Field).returns(T.any(String, Symbol)) }
      def key_for(field); end

      # Assembles one value of +field+ at the current entry cursors, recursing into children
      # 
      # _@param_ `field` — field to assemble
      # 
      # _@return_ — scalar, Hash (struct, map), Array (list) or nil
      sig { params(field: Schema::Field).returns(T.nilable(Object)) }
      def read(field); end

      # Moves every leaf of +field+ past one entry (a null or empty value takes a single entry)
      # 
      # _@param_ `field` — field whose leaves to advance
      sig { params(field: Schema::Field).void }
      def skip(field); end
    end

    # read(as: :numo) and each_batch(as: :numo): columns as Numo arrays. Numo is optional:
    # "numo/narray" (from numo-narray-alt or numo-narray) is required on first use.
    # 
    # Flat INT32 / INT64 / FLOAT / DOUBLE / BOOLEAN columns are decoded without a Ruby object
    # per value: PLAIN and BYTE_STREAM_SPLIT pages go through Numo::X.from_binary, dictionary
    # pages through dictionary[indices], and definition levels become a validity mask. Other
    # columns are read like as: :columns and converted per batch.
    # 
    # Type mapping (following Polars' Series#to_numo and Rover):
    #   INT32 / INT64 (also TIME)       Numo::Int32 / Int64
    #   INT(8/16, signed)               Int8 / Int16
    #   INT(8/16/32/64, unsigned)       UInt8 / UInt16 / UInt32 / UInt64
    #   FLOAT / FLOAT16 / DOUBLE        SFloat / SFloat / DFloat, NaN for nulls
    #   integers with nulls             DFloat with NaN (exact up to 2^53)
    #   BOOLEAN                         Bit; RObject of true/false/nil with nulls
    #   list<number>, all rows of the   2-D [rows, length] of the element type
    #     same length and no nulls
    #   anything else                   RObject of the values as: :rows returns
    # 
    # @api private
    module NumoColumns
      sig { void }
      def load!; end

      sig { void }
      def self.load!; end

      # A separate method so tests can stub it to simulate a missing gem.
      # 
      # _@return_ — whether "numo/narray" is loaded
      sig { returns(T::Boolean) }
      def loaded?; end

      # A separate method so tests can stub it to simulate a missing gem.
      # 
      # _@return_ — whether "numo/narray" is loaded
      sig { returns(T::Boolean) }
      def self.loaded?; end

      # Picks how +field+ is converted: a numeric or boolean leaf, a list of numbers with a single
      # repetition level, or anything else as RObject.
      # 
      # _@param_ `field` — top-level field of the read schema
      # 
      # _@return_ — how to build the field's Numo array
      sig { params(field: Schema::Field).returns(Spec) }
      def spec_for(field); end

      # Picks how +field+ is converted: a numeric or boolean leaf, a list of numbers with a single
      # repetition level, or anything else as RObject.
      # 
      # _@param_ `field` — top-level field of the read schema
      # 
      # _@return_ — how to build the field's Numo array
      sig { params(field: Schema::Field).returns(Spec) }
      def self.spec_for(field); end

      # [Numo class, class to decode pages into (nil: convert Ruby values)], or nil for columns
      # that become RObject
      # 
      # _@param_ `column` — leaf column
      # 
      # _@return_ — result class and page decode class, or nil
      sig { params(column: Schema::Column).returns(T.nilable(T.any([Class, Class], [Class, NilClass]))) }
      def leaf_classes(column); end

      # [Numo class, class to decode pages into (nil: convert Ruby values)], or nil for columns
      # that become RObject
      # 
      # _@param_ `column` — leaf column
      # 
      # _@return_ — result class and page decode class, or nil
      sig { params(column: Schema::Column).returns(T.nilable(T.any([Class, Class], [Class, NilClass]))) }
      def self.leaf_classes(column); end

      # The result for a field read through Numo cursors: +parts+ are [values, validity] pairs
      # (validity is a Numo::Bit, or nil when every value is present)
      # Booleans with nulls become an RObject of true/false/nil, other types with nulls a float
      # array with NaN in the null slots.
      # 
      # _@param_ `spec` — field spec from spec_for
      # 
      # _@param_ `parts` — one [values, validity] pair per batch
      # 
      # _@return_ — the whole column
      sig { params(spec: Spec, parts: T::Array[[Numo::NArray, Numo::Bit]]).returns(Numo::NArray) }
      def finish_fixed(spec, parts); end

      # The result for a field read through Numo cursors: +parts+ are [values, validity] pairs
      # (validity is a Numo::Bit, or nil when every value is present)
      # Booleans with nulls become an RObject of true/false/nil, other types with nulls a float
      # array with NaN in the null slots.
      # 
      # _@param_ `spec` — field spec from spec_for
      # 
      # _@param_ `parts` — one [values, validity] pair per batch
      # 
      # _@return_ — the whole column
      sig { params(spec: Spec, parts: T::Array[[Numo::NArray, Numo::Bit]]).returns(Numo::NArray) }
      def self.finish_fixed(spec, parts); end

      # The result for a field read as Ruby values (+parts+ are Arrays of values)
      # 
      # _@param_ `spec` — field spec from spec_for
      # 
      # _@param_ `parts` — the field's values, one Array per batch
      # 
      # _@return_ — the whole column
      sig { params(spec: Spec, parts: T::Array[T::Array[T.untyped]]).returns(Numo::NArray) }
      def finish_values(spec, parts); end

      # The result for a field read as Ruby values (+parts+ are Arrays of values)
      # 
      # _@param_ `spec` — field spec from spec_for
      # 
      # _@param_ `parts` — the field's values, one Array per batch
      # 
      # _@return_ — the whole column
      sig { params(spec: Spec, parts: T::Array[T::Array[T.untyped]]).returns(Numo::NArray) }
      def self.finish_values(spec, parts); end

      # A numeric / boolean leaf's Ruby values as a Numo array
      # 
      # _@param_ `klass` — Numo class for the column without nulls
      # 
      # _@param_ `values` — the column's values, nil for nulls
      # 
      # _@return_ — +klass+ without nulls; SFloat/DFloat with NaN (or RObject for booleans) with nulls
      sig { params(klass: Class, values: T::Array[T.nilable(T.any(Numeric, T::Boolean))]).returns(Numo::NArray) }
      def from_values(klass, values); end

      # A numeric / boolean leaf's Ruby values as a Numo array
      # 
      # _@param_ `klass` — Numo class for the column without nulls
      # 
      # _@param_ `values` — the column's values, nil for nulls
      # 
      # _@return_ — +klass+ without nulls; SFloat/DFloat with NaN (or RObject for booleans) with nulls
      sig { params(klass: Class, values: T::Array[T.nilable(T.any(Numeric, T::Boolean))]).returns(Numo::NArray) }
      def self.from_values(klass, values); end

      # Lists of numbers: 2-D [rows, length] when every row is a list of the same, non-zero
      # length without nulls; otherwise an RObject of the Arrays
      # 
      # _@param_ `klass` — Numo class of the list elements
      # 
      # _@param_ `values` — one list (or nil) per row
      # 
      # _@return_ — a 2-D +klass+ array or a 1-D Numo::RObject
      sig { params(klass: Class, values: T::Array[T.nilable(T::Array[T.nilable(Numeric)])]).returns(Numo::NArray) }
      def list_array(klass, values); end

      # Lists of numbers: 2-D [rows, length] when every row is a list of the same, non-zero
      # length without nulls; otherwise an RObject of the Arrays
      # 
      # _@param_ `klass` — Numo class of the list elements
      # 
      # _@param_ `values` — one list (or nil) per row
      # 
      # _@return_ — a 2-D +klass+ array or a 1-D Numo::RObject
      sig { params(klass: Class, values: T::Array[T.nilable(T::Array[T.nilable(Numeric)])]).returns(Numo::NArray) }
      def self.list_array(klass, values); end

      # A 1-D Numo::RObject holding +values+ as they are. Only list columns hold Arrays, which
      # #store and .cast would turn into more dimensions.
      # 
      # _@param_ `values` — one Ruby value per row
      # 
      # _@param_ `arrays` — whether +values+ may contain Arrays that must stay single elements
      # 
      # _@return_ — 1-D array of +values+
      sig { params(values: T::Array[T.untyped], arrays: T::Boolean).returns(Numo::RObject) }
      def robject(values, arrays: false); end

      # A 1-D Numo::RObject holding +values+ as they are. Only list columns hold Arrays, which
      # #store and .cast would turn into more dimensions.
      # 
      # _@param_ `values` — one Ruby value per row
      # 
      # _@param_ `arrays` — whether +values+ may contain Arrays that must stay single elements
      # 
      # _@return_ — 1-D array of +values+
      sig { params(values: T::Array[T.untyped], arrays: T::Boolean).returns(Numo::RObject) }
      def self.robject(values, arrays: false); end

      # Numo vector of 1 << j for each bit j of +width+, memoized per Ractor; dotting a bit matrix
      # with it turns rows of bits into integers. Int64 above 30 bits so the sums cannot overflow.
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — the powers of two
      sig { params(width: Integer).returns(T.any(Numo::Int32, Numo::Int64)) }
      def powers(width); end

      # Numo vector of 1 << j for each bit j of +width+, memoized per Ractor; dotting a bit matrix
      # with it turns rows of bits into integers. Int64 above 30 bits so the sums cannot overflow.
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — the powers of two
      sig { params(width: Integer).returns(T.any(Numo::Int32, Numo::Int64)) }
      def self.powers(width); end

      # +count+ bit-packed values of +width+ bits (LSB first) from +data+ at +pos+ as a Numo
      # array, without a Ruby object per value
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first packed value
      # 
      # _@param_ `count` — number of values, a multiple of 8
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — unsigned integer array of +count+ values (element type depends on +width+)
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          width: Integer
        ).returns(Numo::NArray)
      end
      def unpack_bits(data, pos, count, width); end

      # +count+ bit-packed values of +width+ bits (LSB first) from +data+ at +pos+ as a Numo
      # array, without a Ruby object per value
      # 
      # _@param_ `data` — binary page data
      # 
      # _@param_ `pos` — byte offset of the first packed value
      # 
      # _@param_ `count` — number of values, a multiple of 8
      # 
      # _@param_ `width` — bits per value
      # 
      # _@return_ — unsigned integer array of +count+ values (element type depends on +width+)
      sig do
        params(
          data: String,
          pos: Integer,
          count: Integer,
          width: Integer
        ).returns(Numo::NArray)
      end
      def self.unpack_bits(data, pos, count, width); end

      # How a top-level field becomes a Numo array.
      #   kind:      :fixed (a numeric or boolean leaf), :list (list of numbers) or :object
      #   klass:     the Numo class of the result without nulls
      #   bin_klass: for :fixed leaves whose pages can be decoded straight into Numo, the class
      #              of the decoded values (same width as the physical type), else nil
      #   arrays:    whether values may be Arrays (list fields)
      class Spec < Struct
        # _@return_ — whether pages can be decoded straight into Numo (via NumoCursor)
        sig { returns(T::Boolean) }
        def fast?; end

        # _@return_ — whether the result class is a float type, which holds nulls as NaN in place
        sig { returns(T::Boolean) }
        def float?; end

        # Returns the value of attribute kind
        sig { returns(Object) }
        attr_accessor :kind

        # Returns the value of attribute klass
        sig { returns(Object) }
        attr_accessor :klass

        # Returns the value of attribute bin_klass
        sig { returns(Object) }
        attr_accessor :bin_klass

        # Returns the value of attribute arrays
        sig { returns(Object) }
        attr_accessor :arrays
      end
    end

    # Hands out the next +k+ rows of a flat (non-repeated) numeric or boolean column as a
    # [Numo values, validity] pair: values has one slot per row (zero where the row is null),
    # validity is a Numo::Bit or nil when all rows are present.
    # 
    # @api private
    class NumoCursor
      # _@param_ `chunk_reader` — reader for the column's chunk in one row group
      # 
      # _@param_ `spec` — a :fixed spec with a bin_klass
      sig { params(chunk_reader: ColumnChunkReader, spec: NumoColumns::Spec).void }
      def initialize(chunk_reader, spec); end

      # Moves forward to row +target+ of the chunk, jumping over pages with the OffsetIndex
      # 
      # _@param_ `target` — row index within the chunk, not before #row
      sig { params(target: Integer).void }
      def seek(target); end

      # Reads the next +k+ rows, crossing page boundaries as needed.
      # 
      # _@param_ `k` — number of rows
      # 
      # _@return_ — values (zero in null slots)
      # and validity, nil when all +k+ rows are present
      sig { params(k: Integer).returns(T.any([Numo::NArray, Numo::Bit], [Numo::NArray, NilClass])) }
      def take(k); end

      # Decodes the current page's next +n+ non-null values into a +@klass+ array, by the cheapest
      # route the value decoder supports: raw bytes, dictionary indices, its own Numo decoding, or
      # Ruby values as a last resort.
      # 
      # _@param_ `n` — number of non-null values
      # 
      # _@return_ — +n+ values, never a view into a cached dictionary
      sig { params(n: Integer).returns(Numo::NArray) }
      def values(n); end

      # _@param_ `values` — decoded values, without nulls
      # 
      # _@return_ — +values+ as a +@klass+ array (booleans as 0/1 bits)
      sig { params(values: T::Array[T.any(Numeric, T::Boolean)]).returns(Numo::NArray) }
      def cast(values); end

      # Advances to the chunk's next data page.
      sig { void }
      def load_page!; end

      # _@return_ — index within the chunk of the next row #take returns
      sig { returns(Integer) }
      attr_reader :row
    end

    # Row selection for where: filters. A filter maps columns to conditions:
    # 
    #   where: { "user_id" => 42,                      # equality
    #            "status" => %w[paid shipped],         # any of these (IN)
    #            "created_at" => t1...t2,              # Ranges, also endless / beginless
    #            "address.city" => "Amsterdam",        # a member of a struct, by dotted path
    #            "deleted_at" => nil,                  # IS NULL
    #            "amount" => ->(v) { v && v > 100 } }  # any callable (row check only)
    # 
    # All conditions must hold. The filter is used three ways, from cheapest to most exact:
    # whole row groups are ruled out with column chunk statistics (min/max, null counts) and
    # bloom filters; within a row group, pages are ruled out with the page index (ColumnIndex +
    # OffsetIndex), leaving ranges of rows to read; and every row that is read is checked, so
    # results are exact.
    # 
    # @api private
    class Filter
      # _@param_ `schema` — schema of the file being read
      # 
      # _@param_ `where` — column => condition (see the class docs)
      sig { params(schema: Schema, where: T::Hash[T.any(String, Symbol), Object]).void }
      def initialize(schema, where); end

      # Top-level fields the conditions need to read
      # 
      # _@return_ — distinct fields, in condition order
      sig { returns(T::Array[Schema::Field]) }
      def fields; end

      # Whether any row of row group +rg_index+ may match, judging by chunk statistics and bloom
      # filters
      # 
      # _@param_ `reader` — reader of the file (for its footer and bloom filters)
      # 
      # _@param_ `rg_index` — position of the row group in the footer
      # 
      # _@return_ — false only when no row of the row group can match
      sig { params(reader: Reader, rg_index: Integer).returns(T::Boolean) }
      def row_group_may_match?(reader, rg_index); end

      # Sorted, non-overlapping [first_row, end_row) ranges of row group +rg_index+ that may hold
      # matching rows, judging by the page index. Columns without a page index do not narrow
      # the ranges.
      # 
      # _@param_ `reader` — reader of the file (for its page index)
      # 
      # _@param_ `rg_index` — position of the row group in the footer
      # 
      # _@return_ — half-open row ranges within the row group
      sig { params(reader: Reader, rg_index: Integer).returns(T::Array[[Integer, Integer]]) }
      def page_ranges(reader, rg_index); end

      # Indexes (0...k) of the rows of an assembled batch that match. +data+ holds one Array per
      # field in +fields+; +symbolize+ says how struct Hashes are keyed.
      # 
      # _@param_ `data` — assembled values, one Array of +k+ entries per field
      # 
      # _@param_ `fields` — the fields +data+ holds, in the same order
      # 
      # _@param_ `k` — number of rows in the batch
      # 
      # _@param_ `symbolize` — whether struct Hashes are keyed by Symbol
      # 
      # _@return_ — indexes of matching rows, ascending
      sig do
        params(
          data: T::Array[T::Array[T.untyped]],
          fields: T::Array[Schema::Field],
          k: Integer,
          symbolize: T::Boolean
        ).returns(T::Array[Integer])
      end
      def matching_rows(data, fields, k, symbolize); end

      # Whether a value satisfies a condition: nil matches nulls, an Array any of its elements,
      # a Range by #cover? (never nil, incomparable values do not match), a String by bytes
      # (ignoring the encoding), a callable by its result, anything else by ==.
      # 
      # _@param_ `test` — the condition
      # 
      # _@param_ `v` — the row's value
      # 
      # _@return_ — true when the value matches
      sig { params(test: Object, v: Object).returns(T::Boolean) }
      def self.matches?(test, v); end

      # Whether a set of values with the given bounds may contain a match. Unknown bounds or
      # values that cannot be compared never rule anything out.
      # 
      # _@param_ `test` — the condition
      # 
      # _@param_ `min` — lower bound of the values, nil when unknown
      # 
      # _@param_ `max` — upper bound of the values, nil when unknown
      # 
      # _@param_ `nulls` — number of nulls, nil when unknown
      # 
      # _@param_ `all_null` — whether every value is null
      # 
      # _@return_ — false only when no value can match
      sig do
        params(
          test: Object,
          min: T.nilable(Object),
          max: T.nilable(Object),
          nulls: T.nilable(Integer),
          all_null: T.nilable(T::Boolean)
        ).returns(T::Boolean)
      end
      def self.may_match?(test, min, max, nulls, all_null); end

      # Compares two values in Parquet order: Strings byte-wise, false before true
      # 
      # _@param_ `a` — left-hand value
      # 
      # _@param_ `b` — right-hand value
      # 
      # _@return_ — -1, 0 or 1, or nil when the values cannot be compared
      sig { params(a: Object, b: Object).returns(T.nilable(Integer)) }
      def self.compare(a, b); end

      # [min, max] of a chunk's statistics as Ruby values, or [nil, nil] when unusable
      # 
      # _@param_ `column` — the chunk's column, for decoding the bounds
      # 
      # _@param_ `stats` — the chunk's statistics
      # 
      # _@return_ — min and max, each nil when unknown
      sig { params(column: Schema::Column, stats: T.nilable(Format::Statistics)).returns([Object, Object]) }
      def self.stat_range(column, stats); end

      # The deprecated min/max fields were written with signed comparisons, which only agree
      # with the logical order for signed numbers and booleans
      # 
      # _@param_ `column` — column whose statistics are being read
      # 
      # _@return_ — true when the legacy min/max fields can be trusted
      sig { params(column: Schema::Column).returns(T::Boolean) }
      def self.legacy_order_ok?(column); end

      # Decodes a min/max bound (PLAIN encoding of one value) into a Ruby value
      # 
      # _@param_ `column` — the column the bound belongs to
      # 
      # _@param_ `bytes` — the encoded bound
      # 
      # _@return_ — the value, or nil when it is absent or cannot be used (INT96,
      # truncated FIXED_LEN_BYTE_ARRAY, too short, undecodable)
      sig { params(column: Schema::Column, bytes: T.nilable(String)).returns(T.nilable(Object)) }
      def self.decode_stat(column, bytes); end

      # Applies the column's converter, so bounds compare with the values rows hold
      # 
      # _@param_ `column` — the column the value belongs to
      # 
      # _@param_ `value` — physical value
      # 
      # _@return_ — the Ruby value
      sig { params(column: Schema::Column, value: Object).returns(Object) }
      def self.convert(column, value); end

      # Sorts ranges and merges overlapping or touching ones
      # 
      # _@param_ `ranges` — half-open row ranges
      # 
      # _@return_ — sorted, non-overlapping ranges
      sig { params(ranges: T::Array[[Integer, Integer]]).returns(T::Array[[Integer, Integer]]) }
      def self.merge(ranges); end

      # Intersection of two sorted, non-overlapping lists of half-open ranges
      # 
      # _@param_ `a` — first list of ranges
      # 
      # _@param_ `b` — second list of ranges
      # 
      # _@return_ — the rows in both, sorted
      sig { params(a: T::Array[[Integer, Integer]], b: T::Array[[Integer, Integer]]).returns(T::Array[[Integer, Integer]]) }
      def self.intersect(a, b); end

      # Symbols (also inside Arrays) become Strings, since columns never hold Symbols
      # 
      # _@param_ `test` — a condition as given in where:
      # 
      # _@return_ — the condition to store in Condition#test
      sig { params(test: Object).returns(Object) }
      def normalize(test); end

      # Bloom filters answer equality lookups (a value or a list of values)
      # 
      # _@param_ `reader` — reader of the file (for its bloom filters)
      # 
      # _@param_ `rg_index` — position of the row group in the footer
      # 
      # _@param_ `condition` — the condition to check
      # 
      # _@return_ — false only when the bloom filter rules out every value of the condition
      sig { params(reader: Reader, rg_index: Integer, condition: Condition).returns(T::Boolean) }
      def bloom_may_match?(reader, rg_index, condition); end

      # _@return_ — one per where: entry, in the order given
      sig { returns(T::Array[Condition]) }
      attr_reader :conditions

      # One where: entry, resolved against the schema
      # 
      # @!attribute [rw] name
      #   @return [String] the key as given (dotted path of a leaf column)
      # @!attribute [rw] column
      #   @return [Schema::Column] the leaf column the condition reads
      # @!attribute [rw] field
      #   @return [Schema::Field] the top-level field holding that column
      # @!attribute [rw] path
      #   @return [Array<String>] member names from the top-level field down to the column
      #     (empty for a top-level column)
      # @!attribute [rw] test
      #   @return [Object] the condition, with Symbols turned into Strings
      class Condition < Struct
        # _@return_ — the key as given (dotted path of a leaf column)
        sig { returns(String) }
        attr_accessor :name

        # _@return_ — the leaf column the condition reads
        sig { returns(Schema::Column) }
        attr_accessor :column

        # _@return_ — the top-level field holding that column
        sig { returns(Schema::Field) }
        attr_accessor :field

        # _@return_ — member names from the top-level field down to the column
        # (empty for a top-level column)
        sig { returns(T::Array[String]) }
        attr_accessor :path

        # _@return_ — the condition, with Symbols turned into Strings
        sig { returns(Object) }
        attr_accessor :test
      end
    end

    # Incremental decoders for the contents of one data page. The page bytes are decoded as they
    # are asked for, so a caller that takes a few hundred entries at a time never holds a whole
    # page's worth of levels or values as Ruby objects.
    # 
    # @api private
    module PageStream
      # The levels and values of one data page
      class Page
        # _@param_ `entries` — number of entries (num_values of the page header, nulls included)
        # 
        # _@param_ `defs` — definition levels; nil when max level is 0
        # 
        # _@param_ `reps` — repetition levels; nil when max level is 0
        # 
        # _@param_ `values` — value decoder responding to #read(n) (one of the decoders here)
        # 
        # _@param_ `converter` — converter for the decoded values, nil when none is needed
        sig do
          params(
            entries: Integer,
            defs: T.nilable(T.any(HybridDecoder, ArrayDecoder)),
            reps: T.nilable(T.any(HybridDecoder, ArrayDecoder)),
            values: Object,
            converter: T.nilable(Proc)
          ).void
        end
        def initialize(entries, defs, reps, values, converter); end

        # [definition_levels, repetition_levels] of the next +n+ entries (nil when a column has no
        # levels of that kind)
        # 
        # _@param_ `n` — entries wanted; capped at #remaining
        # 
        # _@return_ — definition and repetition levels
        sig { params(n: Integer).returns([T::Array[Integer], T::Array[Integer]]) }
        def read_levels(n); end

        # The next +n+ values, as physical values (apply #converter for Ruby values)
        # 
        # _@param_ `n` — number of non-null values
        # 
        # _@return_ — decoded values
        sig { params(n: Integer).returns(T::Array[T.untyped]) }
        def read_values(n); end

        # Moves past the next +n+ values without returning them
        # 
        # _@param_ `n` — number of non-null values
        sig { params(n: Integer).void }
        def skip_values(n); end

        # The value decoder (for read(as: :numo), which asks it for bytes or Numo arrays)
        # 
        # _@return_ — one of the decoders in PageStream
        sig { returns(Object) }
        def value_decoder; end

        # Which of the next +n+ entries are defined (definition level == +max_def+), as a
        # Numo::Bit, or nil when the column has no definition levels. For columns without
        # repetition levels; used by read(as: :numo).
        # 
        # _@param_ `n` — entries wanted; capped at #remaining
        # 
        # _@param_ `max_def` — the column's max definition level
        # 
        # _@return_ — 1 where the entry holds a value
        sig { params(n: Integer, max_def: Integer).returns(T.nilable(Numo::Bit)) }
        def read_validity_numo(n, max_def); end

        # _@return_ — entries (levels) of the page not read yet
        sig { returns(Integer) }
        attr_reader :remaining

        # _@return_ — physical value => Ruby value, still to be applied to #read_values
        sig { returns(T.nilable(Proc)) }
        attr_reader :converter
      end

      # A decoder over an Array that is already decoded (legacy encodings, booleans, deltas)
      class ArrayDecoder
        # _@param_ `values` — all of the page's decoded levels or values
        sig { params(values: T::Array[T.untyped]).void }
        def initialize(values); end

        # _@param_ `n` — number of entries to hand out
        # 
        # _@return_ — the next +n+ entries
        sig { params(n: Integer).returns(T::Array[T.untyped]) }
        def read(n); end
      end

      # The RLE / bit-packed hybrid, decoded run by run
      class HybridDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first run header
        # 
        # _@param_ `limit` — offset just past the encoded runs
        # 
        # _@param_ `width` — bit width of each value
        sig do
          params(
            data: String,
            pos: Integer,
            limit: Integer,
            width: Integer
          ).void
        end
        def initialize(data, pos, limit, width); end

        # Bit-packed runs are unpacked up to CHUNK values at a time
        # 
        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values
        sig { params(n: Integer).returns(T::Array[Integer]) }
        def read(n); end

        # For a bit width of 1: the next +n+ values as a Numo::Bit (read(as: :numo)). Runs are
        # collected as "0"/"1" characters, which costs less per run than Numo calls do (levels of
        # columns with scattered nulls come in many short runs).
        # 
        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values
        sig { params(n: Integer).returns(Numo::Bit) }
        def read_flags(n); end

        # The next +n+ values as a Numo array of +klass+ (read(as: :numo)): RLE runs are
        # filled and bit-packed runs unpacked by Numo, with no Ruby object per value. Leaves the
        # decoder in a state #read can continue from.
        # 
        # _@param_ `n` — number of values to decode
        # 
        # _@param_ `klass` — Numo integer class to fill, e.g. Numo::UInt8 or Numo::Int32
        # 
        # _@return_ — the next +n+ values as a +klass+ array
        sig { params(n: Integer, klass: Class).returns(Numo::NArray) }
        def read_numo(n, klass); end

        # Reads run headers until a non-empty run starts: an RLE run (count and one value) or
        # a bit-packed run (groups of 8 values)
        sig { void }
        def next_run; end
      end

      # PLAIN INT32 / INT64 / FLOAT / DOUBLE / INT96
      class FixedDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first value
        # 
        # _@param_ `format` — String#unpack directive of one value, e.g. "l<"
        # 
        # _@param_ `width` — bytes per value
        sig do
          params(
            data: String,
            pos: Integer,
            format: String,
            width: Integer
          ).void
        end
        def initialize(data, pos, format, width); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values
        sig { params(n: Integer).returns(T.any(T::Array[Integer], T::Array[Float])) }
        def read(n); end

        # _@param_ `n` — number of values to move past
        sig { params(n: Integer).void }
        def skip(n); end

        # The next +n+ values as their PLAIN (little-endian) bytes, for read(as: :numo)
        # 
        # _@param_ `n` — number of values
        # 
        # _@return_ — +n+ * width bytes
        sig { params(n: Integer).returns(String) }
        def read_bytes(n); end
      end

      # PLAIN INT96 (legacy Impala/Spark timestamps): 8 bytes of nanoseconds, 4 of Julian day
      class Int96Decoder < Herringbone::Reader::PageStream::FixedDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first value
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — [nanoseconds of the day, Julian day] per value
        sig { params(n: Integer).returns(T::Array[[Integer, Integer]]) }
        def read(n); end
      end

      # PLAIN FIXED_LEN_BYTE_ARRAY
      class FixedBytesDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first value
        # 
        # _@param_ `width` — the column's type_length
        sig { params(data: String, pos: Integer, width: Integer).void }
        def initialize(data, pos, width); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values as binary Strings
        sig { params(n: Integer).returns(T::Array[String]) }
        def read(n); end

        # _@param_ `n` — number of values to move past
        sig { params(n: Integer).void }
        def skip(n); end
      end

      # PLAIN BYTE_ARRAY: 4-byte length, then the bytes
      class ByteArrayDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first length prefix
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values as binary Strings
        sig { params(n: Integer).returns(T::Array[String]) }
        def read(n); end

        # Walks the length prefixes without creating Strings
        # 
        # _@param_ `n` — number of values to move past
        sig { params(n: Integer).void }
        def skip(n); end
      end

      # PLAIN BOOLEAN: one bit per value, LSB first
      class BooleanDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the first value; the rest of +data+ is unpacked at once
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values
        sig { params(n: Integer).returns(T::Array[T::Boolean]) }
        def read(n); end

        # The next +n+ values as a Numo::Bit (read(as: :numo))
        # 
        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — 1 for true
        sig { params(n: Integer).returns(Numo::Bit) }
        def read_numo(n); end
      end

      # RLE_DICTIONARY / PLAIN_DICTIONARY indices mapped to the (already converted) dictionary
      class DictionaryDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the bit width byte that precedes the RLE/bit-packed indices
        # 
        # _@param_ `dictionary` — values the indices point into, already converted
        # 
        # _@param_ `path` — dotted column path, for error messages
        sig do
          params(
            data: String,
            pos: Integer,
            dictionary: T::Array[T.untyped],
            path: String
          ).void
        end
        def initialize(data, pos, dictionary, path); end

        # Indices are decoded but not looked up
        # 
        # _@param_ `n` — number of values to move past
        sig { params(n: Integer).void }
        def skip(n); end

        # _@param_ `n` — number of values to decode; must be positive
        # 
        # _@return_ — the dictionary values at the next +n+ indices
        sig { params(n: Integer).returns(T::Array[T.untyped]) }
        def read(n); end

        # The next +n+ indices as a Numo::Int32, bounds-checked (read(as: :numo))
        # 
        # _@param_ `n` — number of indices to decode
        # 
        # _@return_ — indices into #dictionary
        sig { params(n: Integer).returns(Numo::Int32) }
        def read_indices_numo(n); end

        # _@return_ — the chunk's dictionary values (converted, shared by all its pages)
        sig { returns(T::Array[T.untyped]) }
        attr_reader :dictionary
      end

      # RLE-encoded BOOLEAN values
      class RleBooleanDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the 4-byte length prefix of the RLE data
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values
        sig { params(n: Integer).returns(T::Array[T::Boolean]) }
        def read(n); end

        # The next +n+ values as a Numo::Bit (read(as: :numo))
        # 
        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — 1 for true
        sig { params(n: Integer).returns(Numo::Bit) }
        def read_numo(n); end
      end

      # DELTA_LENGTH_BYTE_ARRAY: all lengths first (Integers), then the bytes sliced as needed
      class DeltaLengthDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the DELTA_BINARY_PACKED lengths
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values as binary Strings
        sig { params(n: Integer).returns(T::Array[String]) }
        def read(n); end
      end

      # DELTA_BYTE_ARRAY: prefix lengths and suffixes, each value built from the previous one
      class DeltaByteArrayDecoder
        # _@param_ `data` — binary page data
        # 
        # _@param_ `pos` — offset of the DELTA_BINARY_PACKED prefix lengths
        sig { params(data: String, pos: Integer).void }
        def initialize(data, pos); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values as binary Strings
        sig { params(n: Integer).returns(T::Array[String]) }
        def read(n); end
      end

      # BYTE_STREAM_SPLIT: byte k of every value lives in stream k; values are gathered per call
      class ByteStreamSplitDecoder
        # _@param_ `data` — binary page data; the streams run to its end
        # 
        # _@param_ `pos` — offset of the first stream
        # 
        # _@param_ `width` — bytes per value (and number of streams)
        # 
        # _@param_ `type` — Format::Type of the column
        # 
        # _@param_ `type_length` — value size in bytes for FIXED_LEN_BYTE_ARRAY, else unused
        sig do
          params(
            data: String,
            pos: Integer,
            width: Integer,
            type: Integer,
            type_length: T.nilable(Integer)
          ).void
        end
        def initialize(data, pos, width, type, type_length); end

        # _@param_ `n` — number of values to decode
        # 
        # _@return_ — the next +n+ values, decoded as PLAIN
        sig { params(n: Integer).returns(T.any(T::Array[Integer], T::Array[Float], T::Array[String])) }
        def read(n); end

        # The next +n+ values re-interleaved into PLAIN bytes by Numo (read(as: :numo))
        # 
        # _@param_ `n` — number of values
        # 
        # _@return_ — +n+ * width bytes in PLAIN layout
        sig { params(n: Integer).returns(String) }
        def read_bytes(n); end
      end
    end

    # Internal (used by Redaction and Herringbone.combine): takes plaintext column chunks out of a
    # file as they are stored, for Writer#write_row_group to copy into another file, and tells how
    # a chunk that has to be encoded again should be compressed.
    # 
    # @api private
    class ChunkCopier
      # _@param_ `reader` — the file, whose IO the chunks are read from
      sig { params(reader: Reader).void }
      def initialize(reader); end

      # _@param_ `i` — row group index
      # 
      # _@param_ `col` — the column, in the file's schema
      # 
      # _@return_ — the chunk's pages, page index and bloom filter
      sig { params(i: Integer, col: Schema::Column).returns(Writer::CopiedChunk) }
      def copy(i, col); end

      # How a chunk encoded again follows the source chunk: the same codec (LZO cannot be written
      # and becomes Snappy), and a bloom filter when the source chunk had one
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `col` — the column, in the file's schema
      # 
      # _@return_ — codec id and whether to write a bloom filter, nil when
      # the chunk's metadata is not readable
      sig { params(i: Integer, col: Schema::Column).returns(T.nilable([Integer, T::Boolean])) }
      def recode_settings(i, col); end

      # The encrypted columns of a file encrypted like this one, as the +columns:+ of its
      # EncryptionConfiguration: those encrypted with the footer key as +:footer+, the others
      # with their key and key metadata
      # 
      # _@param_ `sources` — the new file's column path => the column here that holds its values
      # 
      # _@return_ — the encrypted ones of +sources+
      sig { params(sources: T::Hash[String, Schema::Column]).returns(T::Hash[String, T.any(Symbol, T::Hash[T.untyped, T.untyped])]) }
      def encrypted_columns(sources); end

      # The row group's sorting columns, pointed at the new file's columns. A column missing from
      # +output_index+ ends the list, since the columns after it were only sorted within its runs.
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `output_index` — column index here => column index in the new file, for the columns whose values the new file holds as they are
      sig { params(i: Integer, output_index: T::Hash[Integer, Integer]).returns(T.nilable(T::Array[Format::SortingColumn])) }
      def sorting_columns(i, output_index); end

      # _@param_ `schema` — the new file's schema
      # 
      # _@return_ — the file's key/value metadata, without the keys that
      # describe the columns when +schema+ is another
      sig { params(schema: Schema).returns(T::Hash[String, T.nilable(String)]) }
      def metadata(schema); end

      # The chunk's pages. They are walked header by header rather than trusting
      # total_compressed_size, which some writers get wrong: copying too little breaks the
      # chunk, and copying too much could carry over bytes of a neighbouring chunk.
      # 
      # _@param_ `col` — the column
      # 
      # _@param_ `meta` — the chunk's metadata
      # 
      # _@param_ `offset_index` — the chunk's OffsetIndex, whose pages are included even when num_values is reached before them
      # 
      # _@return_ — file offset of the first page, and the pages' bytes
      sig { params(col: Schema::Column, meta: Format::ColumnMetaData, offset_index: T.nilable(Format::OffsetIndex)).returns([Integer, String]) }
      def chunk_bytes(col, meta, offset_index); end

      # Appends up to +count+ bytes that follow +buf+ in the file
      # 
      # _@param_ `buf` — bytes read from +start+ on; appended to
      # 
      # _@param_ `start` — file offset of +buf+
      # 
      # _@param_ `count` — bytes wanted
      # 
      # _@return_ — bytes appended, 0 at the end of the file
      sig { params(buf: String, start: Integer, count: Integer).returns(Integer) }
      def read_more(buf, start, count); end

      # _@param_ `offset` — file offset
      # 
      # _@param_ `length` — byte count
      # 
      # _@return_ — the bytes, nil when absent or cut off
      sig { params(offset: T.nilable(Integer), length: T.nilable(Integer)).returns(T.nilable(String)) }
      def read_at(offset, length); end

      # The chunk's bloom filter as stored. Filters written without a length (older writers) are
      # decoded and encoded again. A filter that cannot be read is left out, which only costs
      # pruning.
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `col` — the column
      # 
      # _@param_ `meta` — the chunk's metadata
      # 
      # _@return_ — header and bitset
      sig { params(i: Integer, col: Schema::Column, meta: Format::ColumnMetaData).returns(T.nilable(String)) }
      def bloom_bytes(i, col, meta); end
    end

    # Walks the pages of one leaf column chunk and hands out the entries (levels and values)
    # of the next +k+ rows. Pages are decoded incrementally (see PageStream), so only the
    # entries of the requested rows (plus a small lookahead of levels for repeated columns)
    # become Ruby objects. A row starts at an entry with repetition level 0 and may continue
    # over any number of following pages.
    # 
    # @api private
    class ColumnCursor
      # _@param_ `chunk_reader` — reader of the chunk, positioned at its start
      sig { params(chunk_reader: ColumnChunkReader).void }
      def initialize(chunk_reader); end

      # Moves forward to row +target+ of the chunk (0-based). With an OffsetIndex, pages before
      # the one holding +target+ are not read at all; otherwise rows are skipped page by page,
      # decoding levels but not building values.
      # 
      # _@param_ `target` — row of the chunk to stop at
      sig { params(target: Integer).void }
      def seek(target); end

      # Moves past the next +k+ rows without building their values
      # 
      # _@param_ `k` — number of rows to skip; zero or less does nothing
      sig { params(k: Integer).void }
      def skip(k); end

      # [definition_levels, repetition_levels, values] of the next +k+ rows. Levels are nil
      # when the column's max level is 0.
      # 
      # _@param_ `k` — number of rows to hand out
      # 
      # _@return_ — definition levels, repetition
      # levels and the (converted) values of the non-null entries
      sig { params(k: Integer).returns([T::Array[Integer], T::Array[Integer], T::Array[T.untyped]]) }
      def take(k); end

      # Non-repeated columns, where every entry is a row: reads page by page until +k+ entries
      # 
      # _@param_ `k` — number of rows
      # 
      # _@param_ `keep` — false to skip the values instead of decoding them
      # 
      # _@return_ — [defs, nil, values] per page touched;
      # empty when +keep+ is false
      sig { params(k: Integer, keep: T::Boolean).returns(T::Array[[T::Array[Integer], NilClass, T::Array[T.untyped]]]) }
      def take_flat(k, keep = true); end

      # Collects entries until +k+ rows have started and the next row start (or the end of the
      # column) is reached. Values are read from a page before moving on to the next one.
      # 
      # _@param_ `k` — number of rows
      # 
      # _@param_ `keep` — false to skip the values instead of decoding them
      # 
      # _@return_ — [defs, reps, values] per
      # page touched (defs nil without definition levels); empty when +keep+ is false
      sig { params(k: Integer, keep: T::Boolean).returns(T::Array[[T::Array[Integer], T::Array[Integer], T::Array[T.untyped]]]) }
      def take_repeated(k, keep = true); end

      # Reads (or skips) the values belonging to the collected entries of the current page
      # 
      # _@param_ `pieces` — output list a [defs, reps, values] piece is appended to
      # 
      # _@param_ `defs` — collected definition levels (nil without them)
      # 
      # _@param_ `reps` — collected repetition levels; nothing happens when empty
      # 
      # _@param_ `keep` — false to skip the values instead of appending a piece
      sig do
        params(
          pieces: T::Array[T::Array[T.untyped]],
          defs: T.nilable(T::Array[Integer]),
          reps: T::Array[Integer],
          keep: T::Boolean
        ).void
      end
      def flush(pieces, defs, reps, keep); end

      # The next +n+ values of the current page, converted when the page has a converter
      # 
      # _@param_ `n` — number of values (non-null entries)
      # 
      # _@return_ — Ruby values
      sig { params(n: Integer).returns(T::Array[T.untyped]) }
      def values(n); end

      # Like #load_page, but running out of pages is an error
      sig { void }
      def load_page!; end

      # Moves to the next data page; false at the end of the chunk
      # 
      # _@return_ — whether a page was loaded
      sig { returns(T::Boolean) }
      def load_page; end

      # _@return_ — rows handed out or skipped so far (the chunk row the cursor is at)
      sig { returns(Integer) }
      attr_reader :row
    end

    # Decodes the pages of one column chunk, one page at a time. Pages are read from the IO as
    # they are needed (a page header, then its body), so memory use is bounded by the page size
    # rather than the size of the chunk.
    # 
    #   reader = ColumnChunkReader.new(io, chunk, column)
    #   while (page = reader.next_page)
    #     defs, reps, values = page # levels are nil when the column's max level is 0
    #   end
    # 
    # The declared total_compressed_size of the chunk is not relied on (some old writers
    # under-report it): pages are read until the chunk's num_values have been seen.
    # 
    # @api private
    class ColumnChunkReader
      # _@param_ `io` — the file, read with #seek and #read
      # 
      # _@param_ `chunk` — the chunk's footer entry
      # 
      # _@param_ `column` — the leaf column the chunk stores
      # 
      # _@param_ `converter` — physical value => Ruby value, applied to values and dictionaries
      # 
      # _@param_ `lazy` — leave non-dictionary values physical in #next_page (see #page_converter)
      # 
      # _@param_ `crypto` — decryption of the chunk's pages, for an encrypted column
      sig do
        params(
          io: T.any(IO, StringIO, RestrictedReadableIO),
          chunk: Format::ColumnChunk,
          column: Schema::Column,
          converter: T.nilable(Proc),
          lazy: T::Boolean,
          crypto: T.nilable(Encryption::ModuleCrypto)
        ).void
      end
      def initialize(io, chunk, column, converter: column.converter, lazy: false, crypto: nil); end

      # All pages concatenated: [definition_levels, repetition_levels, values]
      # 
      # _@return_ — levels are nil when the column's
      # max level is 0
      sig { returns([T::Array[Integer], T::Array[Integer], T::Array[T.untyped]]) }
      def read; end

      # The next data page as [defs, reps, values], or nil after the last one
      # 
      # _@return_ — levels are nil when the
      # column's max level is 0; values hold the non-null entries
      sig { returns(T.nilable([T::Array[Integer], T::Array[Integer], T::Array[T.untyped]])) }
      def next_page; end

      # The next data page as a PageStream::Page that decodes its levels and values on demand,
      # or nil after the last one. Values come out physical; apply Page#converter to them.
      # Dictionary pages are read on the way.
      # 
      # _@return_ — the next data page
      sig { returns(T.nilable(PageStream::Page)) }
      def next_stream; end

      # Continues reading at data page +index+ of the OffsetIndex. The dictionary page (which
      # the OffsetIndex does not list) is read first if it has not been yet.
      # 
      # _@param_ `index` — position of the page in #locations
      sig { params(index: Integer).void }
      def jump_to_page(index); end

      # Whether all of the chunk's values have been returned
      # 
      # _@return_ — true once num_values entries have been seen
      sig { returns(T::Boolean) }
      def done?; end

      # Whether another data page is due: up to the last OffsetIndex location after a jump,
      # otherwise until num_values entries have been seen
      # 
      # _@return_ — true when #next_stream should read on
      sig { returns(T::Boolean) }
      def more_pages?; end

      # Reads the dictionary page at the start of the chunk, if there is one
      sig { void }
      def load_dictionary; end

      # Reads the page header at @pos and the page body after it
      # 
      # _@return_ — the header and the (still compressed) body
      sig { returns([Format::PageHeader, String]) }
      def read_page; end

      # Like #read_page, for an encrypted column: the header and the body are each an encrypted
      # module, the header's starting with its length
      # 
      # _@return_ — the header and the decrypted (still compressed) body
      sig { returns([Format::PageHeader, String]) }
      def read_encrypted_page; end

      # An encrypted module (length prefix included) at +pos+
      # 
      # _@param_ `pos` — file offset of the module
      # 
      # _@param_ `guess` — bytes to read when the buffer does not hold the length prefix
      # 
      # _@return_ — the module
      sig { params(pos: Integer, guess: Integer).returns(String) }
      def read_module(pos, guess); end

      # Returns [buffer, offset] where buffer[offset..] holds at least +need+ bytes from file
      # position +pos+ (fewer only at EOF), reading +len+ bytes when the buffer does not cover it.
      # 
      # _@param_ `pos` — file offset wanted
      # 
      # _@param_ `len` — bytes to read when the buffer has to be refilled
      # 
      # _@param_ `need` — bytes that must be available from +pos+ to reuse the buffer
      # 
      # _@return_ — binary buffer and the offset of +pos+ in it
      sig { params(pos: Integer, len: Integer, need: Integer).returns([String, Integer]) }
      def window(pos, len, need = len); end

      # Decompresses a page body with the chunk's codec
      # 
      # _@param_ `body` — compressed bytes
      # 
      # _@param_ `size` — uncompressed size from the page header
      # 
      # _@return_ — uncompressed bytes
      sig { params(body: String, size: Integer).returns(String) }
      def decompress(body, size); end

      # Decodes a dictionary page (always PLAIN) and keeps its converted values
      # 
      # _@param_ `header` — the dictionary page header
      # 
      # _@param_ `body` — the compressed page body
      # 
      # _@return_ — the dictionary values
      sig { params(header: Format::PageHeader, body: String).returns(T::Array[T.untyped]) }
      def read_dictionary(header, body); end

      # A DATA_PAGE: the whole body is compressed, levels come first with their own length prefix
      # 
      # _@param_ `header` — the data page header
      # 
      # _@param_ `body` — the compressed page body
      # 
      # _@return_ — the page, decoded on demand
      sig { params(header: Format::PageHeader, body: String).returns(PageStream::Page) }
      def data_page_v1(header, body); end

      # A DATA_PAGE_V2: levels are stored uncompressed before the (optionally compressed) values
      # 
      # _@param_ `header` — the data page header
      # 
      # _@param_ `body` — the page body
      # 
      # _@return_ — the page, decoded on demand
      sig { params(header: Format::PageHeader, body: String).returns(PageStream::Page) }
      def data_page_v2(header, body); end

      # [decoder, position after the levels]
      # 
      # _@param_ `data` — the uncompressed page
      # 
      # _@param_ `pos` — offset of the levels in +data+
      # 
      # _@param_ `encoding` — Format::Encoding of the levels (RLE or BIT_PACKED)
      # 
      # _@param_ `max` — max level of the column, which sets the bit width
      # 
      # _@param_ `n` — number of entries in the page
      # 
      # _@return_ — the decoder and the offset just past the levels
      sig do
        params(
          data: String,
          pos: Integer,
          encoding: Integer,
          max: Integer,
          n: Integer
        ).returns(T.any([PageStream::HybridDecoder, Integer], [PageStream::ArrayDecoder, Integer]))
      end
      def level_decoder(data, pos, encoding, max, n); end

      # [value decoder, converter still to apply to its values (nil for dictionary pages)]
      # 
      # _@param_ `data` — the uncompressed values section
      # 
      # _@param_ `pos` — offset of the values in +data+
      # 
      # _@param_ `encoding` — Format::Encoding of the values
      # 
      # _@return_ — a PageStream decoder (responds to #read) and the converter,
      # which may be nil
      sig { params(data: String, pos: Integer, encoding: Integer).returns([Object, Proc]) }
      def value_decoder(data, pos, encoding); end

      # _@return_ — the leaf column this chunk belongs to
      sig { returns(Schema::Column) }
      attr_reader :column

      # With +lazy+, values of data pages that are not dictionary-encoded are returned as
      # physical values, and #page_converter is what still has to be applied to them. This keeps
      # a decoded page small (Integers instead of Time or BigDecimal objects) when only a slice
      # of it is needed at a time.
      # 
      # _@return_ — converter of the last page returned by #next_page, nil when none
      sig { returns(T.nilable(Proc)) }
      attr_reader :page_converter

      # _@return_ — the chunk's data page locations from its
      # OffsetIndex (enables #jump_to_page)
      sig { returns(T.nilable(T::Array[Format::PageLocation])) }
      attr_accessor :locations

      # _@return_ — entries (levels, nulls included) of the data pages returned so far
      sig { returns(Integer) }
      attr_reader :seen

      # _@return_ — the chunk's num_values from its ColumnMetaData
      sig { returns(Integer) }
      attr_reader :total
    end
  end

  # A Parquet schema. Holds two views of the same tree:
  # 
  # * the physical tree of Schema::Node (what is stored in the footer as SchemaElements),
  #   whose leaves are the column chunks (Schema::Column), and
  # * the logical tree of Schema::Field, which interprets LIST/MAP annotations and is
  #   what rows are assembled from (and shredded into) when reading and writing.
  class Schema
    # Rebuilds the tree from the depth-first list of SchemaElements stored in the footer.
    # 
    # _@param_ `elements` — footer schema, root first
    sig { params(elements: T::Array[Format::SchemaElement]).returns(Schema) }
    def self.from_elements(elements); end

    # Builds a schema with the DSL, see Schema::Builder
    # 
    #   Herringbone::Schema.define do |s|
    #     s.int64 :id, null: false
    #     s.string :name
    #   end
    sig { params(block: T.proc.params(s: Builder).void).returns(Schema) }
    def self.define(&block); end

    # Infers a schema from the first 1000 rows (Hashes, or objects responding to #attributes or
    # #to_h). All fields are nullable. Integer -> int64, Integer mixed with Float -> double,
    # String/Symbol -> string (binary if not valid UTF-8), true/false -> boolean,
    # Time/DateTime -> timestamp(micros), Date -> date, BigDecimal -> decimal(38, max scale seen),
    # Hash -> struct, Array -> list. Columns that are nil in every sampled row become strings.
    # Fields declared in the block (Builder DSL) replace the inferred ones of the same name:
    #   Schema.infer(rows) { |s| s.json :payload }
    # 
    # _@param_ `rows` — rows to sample; only the first INFER_SAMPLE are read
    sig { params(rows: T::Enumerable[T.any(T::Hash[T.untyped, T.untyped], Object)], block: T.proc.params(s: Builder).void).returns(Schema) }
    def self.infer(rows, &block); end

    # _@param_ `root` — root group of the physical tree, with +children+ set
    sig { params(root: Node).void }
    def initialize(root); end

    # _@return_ — the tree flattened depth-first, root first, as stored
    # in the footer
    sig { returns(T::Array[Format::SchemaElement]) }
    def to_elements; end

    # _@param_ `name` — top-level field name
    # 
    # _@return_ — the top-level field, or nil when there is none by that name
    sig { params(name: T.any(String, Symbol)).returns(T.nilable(Field)) }
    def field(name); end

    # _@param_ `path` — dotted path or path components of a leaf column
    # 
    # _@return_ — the leaf column, or nil when there is none at that path
    sig { params(path: T.any(String, T::Array[String])).returns(T.nilable(Column)) }
    def column(path); end

    # Structural equality: the same fields in the same order, with the same names, repetition,
    # physical types and widths, annotations, field ids and nesting (see Node#signature). The name
    # of the root (+schema+, +spark_schema+...) does not count.
    # 
    # _@param_ `other` — object to compare with
    sig { params(other: Object).returns(T::Boolean) }
    def ==(other); end

    # _@return_ — hash consistent with #==
    sig { returns(Integer) }
    def hash; end

    # The fields of this schema, then those only +other+ has, matched by name at every level of
    # nesting (struct members, list elements, map keys and values). A field only one side has
    # becomes optional, as does one that is optional on either side. The types of fields both
    # have are widened without loss:
    # 
    # * integers to the wider one: int32 + int64 -> int64, uint8 + uint32 -> uint32, and unsigned
    #   with signed to a signed integer twice as wide: uint32 + int8 -> int64
    # * floats to the wider one, and integers with floats to a float holding every integer
    #   exactly: int16 + float -> float, int32 + float -> double
    # * timestamps and times to the finer unit: millis + micros -> micros
    # * string, enum and json to string; any of them with binary to binary
    # 
    #   (a.schema + b.schema).fields.map(&:name) # => ["id", "name", "email"]
    # 
    # _@param_ `other` — the schema to unite with
    # 
    # _@return_ — a new schema, sharing no nodes with either
    sig { params(other: Schema).returns(Schema) }
    def union(other); end

    # The fields both schemas have, in the order of this one, matched by name at every level of
    # nesting. Nullability and types are widened as by #union.
    # 
    #   (a.schema & b.schema).fields.map(&:name) # => ["id", "name"]
    # 
    # _@param_ `other` — the schema to intersect with
    # 
    # _@return_ — a new schema, sharing no nodes with either
    sig { params(other: Schema).returns(Schema) }
    def intersect(other); end

    # _@return_ — one line per node, indented by depth: repetition, physical type, name and
    # annotation
    sig { returns(String) }
    def inspect; end

    # _@return_ — the signatures of the top-level nodes (Node#signature), for #== and #hash
    sig { returns(T::Array[T.untyped]) }
    def signature; end

    # Appends a Column for every leaf under +node+, depth-first. A non-required node adds one
    # definition level and a repeated node one repetition level.
    # 
    # _@param_ `node` — group whose descendants are walked
    # 
    # _@param_ `max_def` — definition level of +node+ itself
    # 
    # _@param_ `max_rep` — repetition level of +node+ itself
    sig { params(node: Node, max_def: Integer, max_rep: Integer).void }
    def collect_columns(node, max_def, max_rep); end

    # Builds the logical Field for +node+, recognizing LIST and MAP annotations (including the
    # legacy 2-level forms) and bare repeated fields.
    # 
    # _@param_ `node` — physical node to interpret
    # 
    # _@param_ `parent_def` — definition level of the enclosing field
    # 
    # _@param_ `parent_rep` — repetition level of the enclosing field
    # 
    # _@param_ `as_element` — true when +node+ is itself the repeated node of a list, so its repetition is already accounted for and it is not optional
    sig do
      params(
        node: Node,
        parent_def: Integer,
        parent_rep: Integer,
        as_element: T::Boolean
      ).returns(Field)
    end
    def build_field(node, parent_def, parent_rep, as_element: false); end

    # Backward-compatibility rules from the Parquet LogicalTypes spec
    # 
    # _@param_ `list_node` — LIST-annotated group
    # 
    # _@param_ `repeated` — its only (repeated) child
    # 
    # _@return_ — true when +repeated+ is the element itself (2-level list), false when its
    # single child is the element (standard 3-level list)
    sig { params(list_node: Node, repeated: Node).returns(T::Boolean) }
    def list_element_is_repeated_node?(list_node, repeated); end

    # Builds a schema from an ActiveRecord model, so that the Hashes returned by
    # +record.attributes+ can be written directly:
    # 
    #   schema = Herringbone::Schema.from_active_record(Order, except: %w[notes])
    #   File.open("orders.parquet", "wb") { |f| Herringbone.write(f, Order, schema: schema) }
    # 
    # ActiveRecord is not required: this only uses what a model class exposes
    # (+columns+, +primary_key+ and, when present, +defined_enums+).
    # 
    # Primary key columns are never nullable. Rails enum attributes are string columns holding the
    # labels (the writer rejects values outside the enum; stored values such as 0/1 are written as
    # their labels).
    # 
    # _@param_ `model` — ActiveRecord model class, or anything exposing +columns+ the same way
    # 
    # _@param_ `only` — attribute names to include
    # 
    # _@param_ `except` — attribute names to leave out
    # 
    # _@param_ `parquet_enum` — true adds the Parquet ENUM annotation to enum columns, see Builder#enum
    # 
    # _@return_ — schema with one top-level field per selected column, in model column order
    sig do
      params(
        model: Class,
        only: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        except: T.nilable(T.any(T::Array[T.any(String, Symbol)], String, Symbol)),
        parquet_enum: T::Boolean
      ).returns(Schema)
    end
    def self.from_active_record(model, only: nil, except: nil, parquet_enum: false); end

    # The root Node, the leaf Columns in file order, and the top-level Fields of the logical tree
    sig { returns(T.untyped) }
    attr_reader :root

    # The root Node, the leaf Columns in file order, and the top-level Fields of the logical tree
    sig { returns(T.untyped) }
    attr_reader :columns

    # The root Node, the leaf Columns in file order, and the top-level Fields of the logical tree
    sig { returns(T.untyped) }
    attr_reader :fields

    # A node of the physical schema tree.
    class Node
      # _@param_ `name` — field name, stored as a String
      # 
      # _@param_ `repetition` — +:required+, +:optional+ or +:repeated+
      # 
      # _@param_ `type` — physical type (Format::Type), nil for groups
      # 
      # _@param_ `type_length` — byte width of FIXED_LEN_BYTE_ARRAY columns
      # 
      # _@param_ `converted_type` — legacy annotation (Format::ConvertedType)
      # 
      # _@param_ `logical_type` — logical type annotation
      # 
      # _@param_ `scale` — decimal scale
      # 
      # _@param_ `precision` — decimal precision
      # 
      # _@param_ `field_id` — optional field id, as used by Iceberg
      # 
      # _@param_ `children` — child nodes of a group (their +parent+ is set to this node); nil for a leaf
      # 
      # _@param_ `enum_values` — see #enum_values
      sig do
        params(
          name: T.any(String, Symbol),
          repetition: Symbol,
          type: T.nilable(Integer),
          type_length: T.nilable(Integer),
          converted_type: T.nilable(Integer),
          logical_type: T.nilable(Format::LogicalType),
          scale: T.nilable(Integer),
          precision: T.nilable(Integer),
          field_id: T.nilable(Integer),
          children: T.nilable(T::Array[Node]),
          enum_values: T.nilable(T.any(T::Array[String], T::Hash[String, Object]))
        ).void
      end
      def initialize(name:, repetition: :optional, type: nil, type_length: nil, converted_type: nil, logical_type: nil, scale: nil, precision: nil, field_id: nil, children: nil, enum_values: nil); end

      # _@return_ — true for a group (a node with children, possibly none)
      sig { returns(T::Boolean) }
      def group?; end

      # _@return_ — true for a primitive column node
      sig { returns(T::Boolean) }
      def leaf?; end

      # _@return_ — true when the repetition is +:repeated+
      sig { returns(T::Boolean) }
      def repeated?; end

      # _@return_ — true when the repetition is +:optional+
      sig { returns(T::Boolean) }
      def optional?; end

      # _@return_ — the LogicalType union member that is set (+:string+, +:list+,
      # +:decimal+...), or nil without a logical type
      sig { returns(T.nilable(Symbol)) }
      def logical_kind; end

      # _@return_ — whether the node carries a LIST logical or converted type
      sig { returns(T::Boolean) }
      def list_annotated?; end

      # _@return_ — whether the node carries a MAP logical type, or a MAP / MAP_KEY_VALUE
      # converted type
      sig { returns(T::Boolean) }
      def map_annotated?; end

      # _@return_ — names from the top-level field down to this node, without the
      # root's name (the +path_in_schema+ of a column)
      sig { returns(T::Array[String]) }
      def path; end

      # Builds a node without children from a footer SchemaElement; Schema.from_elements attaches them.
      # 
      # _@param_ `el` — element read from the footer
      # 
      # _@return_ — node with +children+ nil; a missing repetition is taken as required
      sig { params(el: Format::SchemaElement).returns(Node) }
      def self.from_element(el); end

      # _@param_ `root` — true for the schema root, which is written without a repetition type
      # 
      # _@return_ — element for the footer's flattened schema list
      sig { params(root: T::Boolean).returns(Format::SchemaElement) }
      def to_element(root: false); end

      # What Schema#== compares: name, repetition, physical type and width, annotation and field id,
      # and the same of the children. A logical type supersedes the converted type (and the
      # decimal scale and precision, which it holds), since writers differ in whether they also
      # store the legacy annotation. +enum_values+ is not stored in the file and does not count.
      # 
      # _@return_ — nested Arrays of plain values, comparable with == and usable as a Hash key
      sig { returns(T::Array[T.untyped]) }
      def signature; end

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :name

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :repetition

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :type

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :type_length

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :converted_type

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :logical_type

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :scale

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :precision

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :field_id

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :children

      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      sig { returns(T.untyped) }
      attr_accessor :parent

      # Allowed values of a string/enum column (writer-side validation only, not stored in the file)
      sig { returns(T.untyped) }
      attr_accessor :enum_values
    end

    # A leaf column (one column chunk per row group)
    class Column
      # _@param_ `index` — position among the schema's leaf columns
      # 
      # _@param_ `node` — leaf node of the physical tree
      # 
      # _@param_ `max_def` — maximum definition level (number of non-required nodes on the path)
      # 
      # _@param_ `max_rep` — maximum repetition level (number of repeated nodes on the path)
      sig do
        params(
          index: Integer,
          node: Node,
          max_def: Integer,
          max_rep: Integer
        ).void
      end
      def initialize(index, node, max_def, max_rep); end

      # _@return_ — physical type (Format::Type)
      sig { returns(Integer) }
      def type; end

      # _@return_ — byte width for FIXED_LEN_BYTE_ARRAY columns
      sig { returns(T.nilable(Integer)) }
      def type_length; end

      # _@return_ — path joined with dots, as used for column names in options
      sig { returns(String) }
      def dotted_path; end

      # Types.reader_for of the node. Not memoized: a Schema holding Procs could not be made
      # Ractor-shareable.
      # 
      # _@return_ — converts a physical value into its Ruby value, or nil when the physical
      # value is used as-is
      sig { returns(T.nilable(T.any(Proc, Method))) }
      def converter; end

      # Types.writer_for of the node. Not memoized, like #converter.
      # 
      # _@return_ — converts a Ruby value into the physical value to store, raising
      # ArgumentError / TypeError / RangeError for values that do not fit
      sig { returns(T.any(Proc, Method)) }
      def encoder; end

      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      sig { returns(T.untyped) }
      attr_reader :index

      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      sig { returns(T.untyped) }
      attr_reader :node

      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      sig { returns(T.untyped) }
      attr_reader :path

      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      sig { returns(T.untyped) }
      attr_reader :max_definition_level

      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      sig { returns(T.untyped) }
      attr_reader :max_repetition_level
    end

    # A node of the logical tree.
    #   kind:       :leaf, :struct, :list or :map
    #   optional:   whether this field itself may be null
    #   def_level:  definition level at which this field counts as present
    #   For :list and :map:
    #     rep_level:  repetition level of the repeated node
    #     item_def:   definition level at which the repeated node has at least one entry
    #     element:    element Field (lists); key/value Fields (maps, value may be nil)
    class Field
      # _@param_ `kind` — +:leaf+, +:struct+, +:list+ or +:map+
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `optional` — whether this field itself may be null
      # 
      # _@param_ `def_level` — definition level at which this field counts as present
      # 
      # _@param_ `node` — physical node the field was built from
      # 
      # _@param_ `rep_level` — repetition level of the repeated node (lists and maps)
      # 
      # _@param_ `item_def` — definition level at which a list or map has an entry
      # 
      # _@param_ `children` — fields of a struct
      # 
      # _@param_ `element` — element of a list
      # 
      # _@param_ `key` — key of a map
      # 
      # _@param_ `value` — value of a map
      # 
      # _@param_ `column` — column of a leaf
      sig do
        params(
          kind: Symbol,
          name: String,
          optional: T::Boolean,
          def_level: Integer,
          node: Node,
          rep_level: T.nilable(Integer),
          item_def: T.nilable(Integer),
          children: T.nilable(T::Array[Field]),
          element: T.nilable(Field),
          key: T.nilable(Field),
          value: T.nilable(Field),
          column: T.nilable(Column)
        ).void
      end
      def initialize(kind:, name:, optional:, def_level:, node:, rep_level: nil, item_def: nil, children: nil, element: nil, key: nil, value: nil, column: nil); end

      # _@return_ — first leaf column under this field
      sig { returns(Column) }
      def first_leaf; end

      # _@return_ — true for a primitive (+:leaf+) field
      sig { returns(T::Boolean) }
      def leaf?; end

      # Lookup of a struct's children; only valid for +:struct+ fields.
      # 
      # _@return_ — child fields by name
      sig { returns(T::Hash[String, Field]) }
      def children_by_name; end

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :kind

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :name

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :optional

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :def_level

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :rep_level

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :item_def

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :children

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :element

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :key

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :value

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :column

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :leaves

      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      sig { returns(T.untyped) }
      attr_reader :node
    end

    # Type inference behind Schema.infer
    # 
    # @api private
    module Inference
      # _@param_ `row` — sampled row
      # 
      # _@return_ — the row as a Hash keyed by field name (String or Symbol keys)
      sig { params(row: T.any(T::Hash[T.untyped, T.untyped], T.untyped)).returns(T::Hash[T.untyped, T.untyped]) }
      def row_hash(row); end

      # _@param_ `row` — sampled row
      # 
      # _@return_ — the row as a Hash keyed by field name (String or Symbol keys)
      sig { params(row: T.any(T::Hash[T.untyped, T.untyped], T.untyped)).returns(T::Hash[T.untyped, T.untyped]) }
      def self.row_hash(row); end

      # Hashes become groups, Arrays become 3-level LIST groups, other values a primitive column;
      # nil values are ignored and an all-nil column becomes a string.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `values` — the field's values across the sampled rows
      # 
      # _@return_ — optional node for the field
      sig { params(name: String, values: T::Array[Object]).returns(Node) }
      def node_for(name, values); end

      # Hashes become groups, Arrays become 3-level LIST groups, other values a primitive column;
      # nil values are ignored and an all-nil column becomes a string.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `values` — the field's values across the sampled rows
      # 
      # _@return_ — optional node for the field
      sig { params(name: String, values: T::Array[Object]).returns(Node) }
      def self.node_for(name, values); end

      # _@param_ `name` — field name, for the error message
      # 
      # _@param_ `values` — non-nil values of the field
      # 
      # _@return_ — DSL type, plus its options
      # for types that take some (decimal, timestamp)
      sig { params(name: String, values: T::Array[Object]).returns(T.any([Symbol], [Symbol, T::Hash[Symbol, Object]])) }
      def scalar_type(name, values); end

      # _@param_ `name` — field name, for the error message
      # 
      # _@param_ `values` — non-nil values of the field
      # 
      # _@return_ — DSL type, plus its options
      # for types that take some (decimal, timestamp)
      sig { params(name: String, values: T::Array[Object]).returns(T.any([Symbol], [Symbol, T::Hash[Symbol, Object]])) }
      def self.scalar_type(name, values); end
    end

    # DSL for defining schemas:
    # 
    #   Herringbone::Schema.define do |s|
    #     s.int64 :id, null: false
    #     s.string :name
    #     s.list :tags, :string
    #     s.map :scores, :string, :double
    #     s.struct :address do |address|
    #       address.string :city
    #     end
    #     s.decimal :price, precision: 12, scale: 2
    #     s.timestamp :created_at, unit: :micros
    #   end
    # 
    # Fields are nullable unless null: false is given. The blocks of #struct, #list and #map get
    # a Builder of their own.
    class Builder
      # Yields a new Builder to the block.
      # 
      # _@param_ `usage` — how the entry point is called with a block, for the error message
      # 
      # _@return_ — the builder, with no fields when there is no block
      sig { params(usage: String, block: T.proc.params(s: Builder).void).returns(Builder) }
      def self.build(usage, &block); end

      # A block without a parameter was most likely written for the +instance_eval+ DSL of
      # earlier versions, and would fail on its first declaration with a NoMethodError
      # 
      # _@param_ `block` — the block given to the entry point
      # 
      # _@param_ `usage` — how the entry point is called with a block, for the error message
      sig { params(block: T.nilable(Proc), usage: String).void }
      def self.check_block!(block, usage); end

      # Starts with no fields
      sig { void }
      def initialize; end

      # A TIME column; millis are stored as INT32, micros and nanos as INT64.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
      # 
      # _@param_ `utc` — the isAdjustedToUTC flag of the logical type
      # 
      # _@param_ `opts` — options of #column
      # 
      # _@return_ — the added node
      sig do
        params(
          name: T.any(String, Symbol),
          unit: Symbol,
          utc: T::Boolean,
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def time(name, unit: :micros, utc: true, **opts); end

      # A TIMESTAMP column, stored as INT64.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `unit` — +:millis+, +:micros+ or +:nanos+
      # 
      # _@param_ `utc` — the isAdjustedToUTC flag: true for instants, false for local date-times
      # 
      # _@param_ `opts` — options of #column
      # 
      # _@return_ — the added node
      sig do
        params(
          name: T.any(String, Symbol),
          unit: Symbol,
          utc: T::Boolean,
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def timestamp(name, unit: :micros, utc: true, **opts); end

      # A DECIMAL column. Up to 9 digits are stored as INT32, up to 18 as INT64, more as a
      # FIXED_LEN_BYTE_ARRAY of the minimal width, unless +physical:+ says otherwise.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `precision` — total number of digits
      # 
      # _@param_ `scale` — digits after the decimal point, between 0 and +precision+
      # 
      # _@param_ `opts` — options of #column
      # 
      # _@return_ — the added node
      sig do
        params(
          name: T.any(String, Symbol),
          precision: Integer,
          scale: Integer,
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def decimal(name, precision:, scale: 0, **opts); end

      # A FIXED_LEN_BYTE_ARRAY column without annotation.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `length` — byte width of every value
      # 
      # _@param_ `opts` — options of #column
      # 
      # _@return_ — the added node
      sig { params(name: T.any(String, Symbol), length: Integer, opts: T::Hash[Symbol, Object]).returns(Node) }
      def fixed(name, length:, **opts); end

      # A group of named fields.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `null` — whether the struct as a whole may be null
      # 
      # _@param_ `field_id` — field id to store in the schema
      # 
      # _@return_ — the added group node
      sig do
        params(
          name: T.any(String, Symbol),
          null: T::Boolean,
          field_id: T.nilable(Integer),
          block: T.proc.params(struct: Builder).void
        ).returns(Node)
      end
      def struct(name, null: true, field_id: nil, &block); end

      # s.list :tags, :string
      #   s.list :tags, :string, element_null: false
      #   s.list :points, :struct do |points| points.double :x; points.double :y end
      #   s.list :matrix do |matrix| matrix.list :element, :double end # block declares the element
      # 
      # Written as the standard 3-level LIST: an optional (or required) group holding a repeated
      # group "list" whose single child is "element".
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `type` — element type (any #column type, or +:struct+ with a block); nil when the block declares the element
      # 
      # _@param_ `null` — whether the list itself may be null
      # 
      # _@param_ `element_null` — whether elements may be null; ignored when the block declares the element, which then keeps its own +null:+
      # 
      # _@param_ `field_id` — field id to store in the schema
      # 
      # _@param_ `type_opts` — options of the element type (+precision:+, +unit:+...)
      # 
      # _@return_ — the added LIST group node
      sig do
        params(
          name: T.any(String, Symbol),
          type: T.nilable(T.any(Symbol, String)),
          null: T::Boolean,
          element_null: T::Boolean,
          field_id: T.nilable(Integer),
          type_opts: T::Hash[Symbol, Object],
          block: T.proc.params(list: Builder).void
        ).returns(Node)
      end
      def list(name, type = nil, null: true, element_null: true, field_id: nil, **type_opts, &block); end

      # s.map :scores, :string, :double
      #   s.map :things, :string, :struct do |things| things.int32 :a end
      # 
      # Written as the standard MAP: a group holding a repeated group "key_value" with a required
      # "key" and a "value". Keys are never null.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `key_type` — key type (a primitive #column type)
      # 
      # _@param_ `value_type` — value type (any #column type, or +:struct+ with a block); nil when the block declares the value
      # 
      # _@param_ `null` — whether the map itself may be null
      # 
      # _@param_ `value_null` — whether values may be null; ignored when the block declares the value
      # 
      # _@param_ `field_id` — field id to store in the schema
      # 
      # _@param_ `type_opts` — options of the value type (+precision:+, +unit:+...)
      # 
      # _@return_ — the added MAP group node
      sig do
        params(
          name: T.any(String, Symbol),
          key_type: T.any(Symbol, String),
          value_type: T.nilable(T.any(Symbol, String)),
          null: T::Boolean,
          value_null: T::Boolean,
          field_id: T.nilable(Integer),
          type_opts: T::Hash[Symbol, Object],
          block: T.proc.params(map: Builder).void
        ).returns(Node)
      end
      def map(name, key_type, value_type = nil, null: true, value_null: true, field_id: nil, **type_opts, &block); end

      # Generic column declaration: s.column :name, :int32, null: false
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `type` — DSL type: one of PRIMITIVES, or +:time+, +:timestamp+, +:decimal+, +:fixed+, +:enum+ with their options
      # 
      # _@param_ `null` — whether the field is nullable (optional rather than required)
      # 
      # _@param_ `field_id` — field id to store in the schema
      # 
      # _@param_ `opts` — type options
      # 
      # _@return_ — the added leaf node
      sig do
        params(
          name: T.any(String, Symbol),
          type: T.any(Symbol, String),
          null: T::Boolean,
          field_id: T.nilable(Integer),
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def column(name, type, null: true, field_id: nil, **opts); end

      # A string column. With parquet_enum: true it carries the ENUM annotation instead of STRING
      # (note that pyarrow and pandas then read it as binary). values: restricts what can be
      # written: an Array of labels, or a Hash like Rails' `Order.statuses` (label => stored value),
      # in which case both labels and stored values are accepted and the label is written.
      # 
      # _@param_ `name` — field name
      # 
      # _@param_ `values` — allowed labels, or label => stored value; nil allows any string
      # 
      # _@param_ `parquet_enum` — annotate as ENUM instead of STRING
      # 
      # _@param_ `opts` — options of #column
      # 
      # _@return_ — the added leaf node
      sig do
        params(
          name: T.any(String, Symbol),
          values: T.nilable(T.any(T::Array[T.any(String, Symbol)], T::Hash[T.any(String, Symbol), Object])),
          parquet_enum: T::Boolean,
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def enum(name, values: nil, parquet_enum: false, **opts); end

      # _@param_ `node` — node to append to #nodes
      # 
      # _@return_ — +node+
      sig { params(node: Node).returns(Node) }
      def add(node); end

      # _@param_ `nullable` — whether the field may be null
      # 
      # _@return_ — +:optional+ or +:required+
      sig { params(nullable: T::Boolean).returns(Symbol) }
      def rep(nullable); end

      # Builds the element of a list, or the key or value of a map.
      # 
      # _@param_ `name` — node name ("element", "key" or "value")
      # 
      # _@param_ `type` — DSL type, +:struct+, or nil to take the field the block declares
      # 
      # _@param_ `nullable` — whether the node may be null (not applied to a block-declared field)
      # 
      # _@param_ `type_opts` — type options passed to Types.physical_attributes
      # 
      # _@param_ `example` — the declaration called with a block, for the error message
      # 
      # _@return_ — the element node, not added to #nodes
      sig do
        params(
          name: String,
          type: T.nilable(T.any(Symbol, String)),
          nullable: T::Boolean,
          type_opts: T::Hash[Symbol, Object],
          example: T.nilable(String),
          block: T.proc.params(inner: Builder).void
        ).returns(Node)
      end
      def element_node(name, type, nullable, type_opts, example, &block); end

      # Yields a new Builder for a struct's fields; Parquet groups need at least one child.
      # 
      # _@param_ `name` — struct name, for the error message
      # 
      # _@param_ `example` — the declaration called with a block, for the error message
      # 
      # _@return_ — the declared fields
      sig { params(name: T.any(String, Symbol), example: String, block: T.proc.params(inner: Builder).void).returns(T::Array[Node]) }
      def struct_fields(name, example, &block); end

      # _@param_ `name` — field name, which names the block parameter when it can
      # 
      # _@param_ `head` — the declaration without its block, e.g. "struct :address"
      # 
      # _@param_ `declaration` — a declaration for the block's body, e.g. "string :city"
      # 
      # _@return_ — the declaration with a block taking a parameter, e.g.
      # "s.struct :address do |address| address.string :city end"
      sig { params(name: T.any(String, Symbol), head: String, declaration: String).returns(String) }
      def usage(name, head, declaration); end

      # _@param_ `name` — field name
      # 
      # _@param_ `type` — DSL type
      # 
      # _@param_ `repetition` — +:optional+ or +:required+
      # 
      # _@param_ `opts` — type options; +:values+ is taken out as the enum values and the rest go to Types.physical_attributes
      # 
      # _@return_ — leaf node, not added to #nodes
      sig do
        params(
          name: T.any(String, Symbol),
          type: T.any(Symbol, String),
          repetition: Symbol,
          opts: T::Hash[Symbol, Object]
        ).returns(Node)
      end
      def leaf_node(name, type, repetition, opts); end

      # _@return_ — fields declared so far, in declaration order
      sig { returns(T::Array[Node]) }
      attr_reader :nodes
    end

    # The union or intersection of two schemas, behind Schema#union and Schema#intersect. Fields
    # are matched by name at every level of nesting, and the type of a field both schemas have is
    # widened to one that holds the values of both without loss. Fields that do not fit are
    # collected rather than raised one by one, so a single IncompatibleSchema names them all.
    # 
    # Leaf types are compared as Arrays like +[:int, 32, true]+ or +[:timestamp, :micros, false]+,
    # so the same type spelled with a logical type in one file and a converted type in another
    # still matches.
    # 
    # @api private
    class Merge
      # _@param_ `mode` — +:union+ or +:intersect+
      sig { params(mode: Symbol).void }
      def initialize(mode); end

      # _@param_ `mine` — the receiver, whose field order comes first
      # 
      # _@param_ `theirs` — the other schema
      # 
      # _@return_ — a new schema sharing no nodes with either
      sig { params(mine: Schema, theirs: Schema).returns(Schema) }
      def call(mine, theirs); end

      # _@param_ `field` — any field
      # 
      # _@return_ — its type as error messages name it: the leaf type's label ("uint16",
      # "timestamp(millis, UTC)", "decimal(10, 2)"...), or "struct", "list" or "map"
      sig { params(field: Field).returns(String) }
      def describe(field); end

      # Matches the members of two groups (or the top-level fields) by name: those of +mine+ in
      # order, then, for a union, those only +theirs+ has.
      # 
      # _@param_ `mine` — fields of the receiver
      # 
      # _@param_ `theirs` — fields of the other schema
      # 
      # _@param_ `path` — path of the enclosing group, empty at the top level
      # 
      # _@return_ — merged nodes; incomplete when a conflict was recorded
      sig { params(mine: T::Array[Field], theirs: T::Array[Field], path: T::Array[String]).returns(T::Array[Node]) }
      def merge_members(mine, theirs, path); end

      # A field only one side of a union has: rows from the other side hold no value for it
      # 
      # _@param_ `field` — the field only one schema has
      # 
      # _@param_ `path` — path of the field
      # 
      # _@param_ `side` — +:left+ or +:right+, the schema that has it
      # 
      # _@return_ — an optional copy of the field's node; nil for a conflict
      sig { params(field: Field, path: T::Array[String], side: Symbol).returns(T.nilable(Node)) }
      def nullable(field, path, side); end

      # _@param_ `a` — the field in the receiver
      # 
      # _@param_ `b` — the field of the same name in the other schema
      # 
      # _@param_ `path` — path of the field
      # 
      # _@return_ — the merged node; nil when a conflict was recorded
      sig { params(a: Field, b: Field, path: T::Array[String]).returns(T.nilable(Node)) }
      def merge(a, b, path); end

      # _@param_ `an` — leaf in the receiver
      # 
      # _@param_ `bn` — leaf of the same name in the other schema
      # 
      # _@param_ `path` — path of the field
      # 
      # _@return_ — physical attributes for Node.new; nil when a conflict
      # was recorded
      sig { params(an: Node, bn: Node, path: T::Array[String]).returns(T.nilable(T::Hash[Symbol, Object])) }
      def merge_leaf(an, bn, path); end

      # _@param_ `field` — any field
      # 
      # _@return_ — the field id of its node, nil for the element of a bare repeated
      # field, whose node (and field id) is that of the list
      sig { params(field: Field).returns(T.nilable(Integer)) }
      def field_id_of(field); end

      # _@param_ `ta` — leaf type of the receiver's field (see #leaf_type)
      # 
      # _@param_ `tb` — a different leaf type of the other schema's field
      # 
      # _@return_ — the widened type, or why there is none
      sig { params(ta: T::Array[T.untyped], tb: T::Array[T.untyped]).returns(T.any([T::Array[T.untyped], NilClass], [NilClass, String])) }
      def widen(ta, tb); end

      # _@param_ `ta` — an integer type
      # 
      # _@param_ `tb` — another integer type
      # 
      # _@return_ — the narrowest integer holding both, or why
      # there is none
      sig { params(ta: T::Array[T.untyped], tb: T::Array[T.untyped]).returns(T.any([T::Array[T.untyped], NilClass], [NilClass, String])) }
      def widen_ints(ta, tb); end

      # _@param_ `int` — an integer type
      # 
      # _@param_ `float` — a float type
      # 
      # _@return_ — the narrowest float at least as wide as
      # +float+ that holds every value of +int+ exactly, or why there is none
      sig { params(int: T::Array[T.untyped], float: T::Array[T.untyped]).returns(T.any([T::Array[T.untyped], NilClass], [NilClass, String])) }
      def int_to_float(int, float); end

      # _@param_ `node` — a leaf
      # 
      # _@return_ — its type, independent of whether a logical or converted type spells it;
      # +[:other, ...]+ for annotations nothing widens (INTERVAL, unknown logical types)
      sig { params(node: Node).returns(T::Array[T.untyped]) }
      def leaf_type(node); end

      # _@param_ `node` — a leaf without a logical type
      # 
      # _@return_ — its type, see #leaf_type
      sig { params(node: Node).returns(T::Array[T.untyped]) }
      def converted_type(node); end

      # _@param_ `type` — a leaf type, see #leaf_type
      # 
      # _@return_ — physical attributes for Node.new, as the Builder DSL
      # declares that type
      sig { params(type: T::Array[T.untyped]).returns(T::Hash[Symbol, Object]) }
      def attributes(type); end

      # _@param_ `node` — a leaf
      # 
      # _@return_ — its physical attributes as they are
      sig { params(node: Node).returns(T::Hash[Symbol, Object]) }
      def attributes_of(node); end

      # _@param_ `type` — a leaf type, see #leaf_type
      # 
      # _@return_ — e.g. "uint16", "timestamp(millis, UTC)", "decimal(10, 2)"
      sig { params(type: T::Array[T.untyped]).returns(String) }
      def label(type); end

      # _@param_ `field` — any field
      # 
      # _@return_ — the leaf type's label, or "struct", "list" or "map"
      sig { params(field: Field).returns(String) }
      def kind_label(field); end

      # What two nodes must share to be merged as they are: Node#signature without the name,
      # repetition and field id of the node itself
      # 
      # _@param_ `node` — any node
      sig { params(node: Node).returns(T::Array[T.untyped]) }
      def shape(node); end

      # _@param_ `node` — node to copy, with its children
      # 
      # _@param_ `changes` — attributes to set on the copy (not on its children)
      # 
      # _@return_ — a copy sharing no nodes with the original
      sig { params(node: Node, changes: T::Hash[Symbol, Object]).returns(Node) }
      def copy(node, **changes); end

      # _@param_ `path` — path of the field
      # 
      # _@param_ `left` — the field in the receiver
      # 
      # _@param_ `right` — the field in the other schema
      # 
      # _@param_ `reason` — why they do not fit
      sig do
        params(
          path: T::Array[String],
          left: String,
          right: String,
          reason: String
        ).void
      end
      def conflict(path, left, right, reason); end
    end

    # Maps ActiveRecord column metadata to schema DSL types.
    # 
    #   integer   by sql_type (smallint -> int16, bigint -> int64, ...) or by limit
    #             (1 -> int8, 2 -> int16, 8 -> int64, otherwise int32); "unsigned" -> uintN.
    #             Integer primary keys are always int64.
    #   float     double; float (32-bit) only for sql_type "float4"
    #   decimal   decimal(precision, scale); decimal(38, 9) when the column has no precision
    #   boolean, date, binary, uuid, json map to the same-named types (jsonb -> json)
    #   datetime, timestamp, timestamptz -> timestamp(micros, UTC); time -> time(micros)
    #   hstore    map<string, string>
    #   anything else (string, text, citext, inet, cidr, macaddr, ...) -> string
    #   Postgres arrays (column.array, or a sql_type ending in "[]") -> list of the element type
    # 
    # @api private
    module ActiveRecordMapping
      # Declares +column+ on +builder+: hstore as map<string, string>, array columns as a list of
      # the element type, everything else as the scalar type picked by #scalar_type.
      # 
      # _@param_ `builder` — builder to add the field to
      # 
      # _@param_ `column` — column metadata (+name+, +type+, and when available +sql_type+, +array+, +limit+, +precision+, +scale+)
      # 
      # _@param_ `nullable` — whether the field may be null
      # 
      # _@param_ `primary` — whether the column is (part of) the primary key
      # 
      # _@return_ — the added schema node
      sig do
        params(
          builder: Builder,
          column: ActiveRecord::ConnectionAdapters::Column,
          nullable: T::Boolean,
          primary: T::Boolean
        ).returns(Node)
      end
      def add_column(builder, column, nullable, primary); end

      # Declares +column+ on +builder+: hstore as map<string, string>, array columns as a list of
      # the element type, everything else as the scalar type picked by #scalar_type.
      # 
      # _@param_ `builder` — builder to add the field to
      # 
      # _@param_ `column` — column metadata (+name+, +type+, and when available +sql_type+, +array+, +limit+, +precision+, +scale+)
      # 
      # _@param_ `nullable` — whether the field may be null
      # 
      # _@param_ `primary` — whether the column is (part of) the primary key
      # 
      # _@return_ — the added schema node
      sig do
        params(
          builder: Builder,
          column: ActiveRecord::ConnectionAdapters::Column,
          nullable: T::Boolean,
          primary: T::Boolean
        ).returns(Node)
      end
      def self.add_column(builder, column, nullable, primary); end

      # Picks the DSL type for a non-array, non-hstore column, following the table above.
      # 
      # _@param_ `column` — column metadata, read for +limit+, +precision+ and +scale+
      # 
      # _@param_ `type` — ActiveRecord's abstract type (+column.type+)
      # 
      # _@param_ `sql_type` — lowercased database type with any array suffix removed
      # 
      # _@param_ `primary` — whether the column is (part of) the primary key
      # 
      # _@return_ — DSL type and its options for Builder#column
      sig do
        params(
          column: ActiveRecord::ConnectionAdapters::Column,
          type: T.nilable(Symbol),
          sql_type: String,
          primary: T::Boolean
        ).returns([Symbol, T::Hash[Symbol, Object]])
      end
      def scalar_type(column, type, sql_type, primary); end

      # Picks the DSL type for a non-array, non-hstore column, following the table above.
      # 
      # _@param_ `column` — column metadata, read for +limit+, +precision+ and +scale+
      # 
      # _@param_ `type` — ActiveRecord's abstract type (+column.type+)
      # 
      # _@param_ `sql_type` — lowercased database type with any array suffix removed
      # 
      # _@param_ `primary` — whether the column is (part of) the primary key
      # 
      # _@return_ — DSL type and its options for Builder#column
      sig do
        params(
          column: ActiveRecord::ConnectionAdapters::Column,
          type: T.nilable(Symbol),
          sql_type: String,
          primary: T::Boolean
        ).returns([Symbol, T::Hash[Symbol, Object]])
      end
      def self.scalar_type(column, type, sql_type, primary); end

      # Named SQL types (smallint, bigint, ...) decide the width; a generic "integer"/"int"
      # uses the column limit in bytes, since e.g. SQLite reports `t.integer limit: 2` as "integer(2)".
      # 
      # _@param_ `column` — column metadata, read for +limit+
      # 
      # _@param_ `sql_type` — lowercased database type with any array suffix removed
      # 
      # _@param_ `primary` — true forces int64, since row ids can outgrow the declared width
      # 
      # _@return_ — one of +:int8+ .. +:int64+ or +:uint8+ .. +:uint64+
      sig { params(column: ActiveRecord::ConnectionAdapters::Column, sql_type: String, primary: T::Boolean).returns(Symbol) }
      def integer_type(column, sql_type, primary); end

      # Named SQL types (smallint, bigint, ...) decide the width; a generic "integer"/"int"
      # uses the column limit in bytes, since e.g. SQLite reports `t.integer limit: 2` as "integer(2)".
      # 
      # _@param_ `column` — column metadata, read for +limit+
      # 
      # _@param_ `sql_type` — lowercased database type with any array suffix removed
      # 
      # _@param_ `primary` — true forces int64, since row ids can outgrow the declared width
      # 
      # _@return_ — one of +:int8+ .. +:int64+ or +:uint8+ .. +:uint64+
      sig { params(column: ActiveRecord::ConnectionAdapters::Column, sql_type: String, primary: T::Boolean).returns(Symbol) }
      def self.integer_type(column, sql_type, primary); end
    end
  end

  # Minimal Thrift Compact Protocol implementation, just enough for Parquet metadata.
  # Structs are described declaratively (see Herringbone::Thrift::Struct) so that
  # both the reader and the writer are driven by the same field tables.
  # 
  # @api private
  module Thrift
    # Wire type written for a declared field type
    # 
    # _@param_ `type` — a scalar type from WIRE_TYPES, a +[:list, elem]+ Array, or a Struct subclass
    # 
    # _@return_ — one of the T_* wire type constants (T_TRUE for +:bool+)
    sig { params(type: T.any(Symbol, T::Array[T.untyped], Class)).returns(Integer) }
    def self.wire_type_for(type); end

    # Whether a value of wire type +wire+ can be read as declared +type+
    # 
    # Integer widths are interchangeable (any of i16/i32/i64 on the wire is read for any declared
    # integer type), and a set is accepted where a list is declared.
    # 
    # _@param_ `wire` — wire type from the field or list header
    # 
    # _@param_ `type` — declared field type (see WIRE_TYPES)
    # 
    # _@return_ — true when the value can be decoded as +type+, false when it must be skipped
    sig { params(wire: Integer, type: T.any(Symbol, T::Array[T.untyped], Class)).returns(T::Boolean) }
    def self.compatible?(wire, type); end

    # Raised on malformed or truncated Thrift data, and on values the writer cannot encode
    class Error < StandardError
    end

    # Decodes compact protocol data from a String, keeping a byte position into it
    class Reader
      # _@param_ `buf` — the encoded data (binary)
      # 
      # _@param_ `pos` — byte offset to start reading at
      sig { params(buf: String, pos: Integer).void }
      def initialize(buf, pos = 0); end

      # Reads one raw byte
      # 
      # _@return_ — the byte, 0..255
      sig { returns(Integer) }
      def read_byte; end

      # Reads an unsigned LEB128 varint
      # 
      # _@return_ — the decoded non-negative value, below 2**64
      sig { returns(Integer) }
      def read_varint; end

      # Reads a zigzag-encoded varint (how i16, i32, i64 and field id deltas are stored)
      # 
      # _@return_ — the decoded signed value
      sig { returns(Integer) }
      def read_zigzag; end

      # Reads a length-prefixed byte string
      # 
      # _@return_ — a slice of the buffer (with the buffer's encoding)
      sig { returns(String) }
      def read_binary; end

      # Reads an 8-byte little-endian double
      # 
      # _@return_ — the value
      sig { returns(Float) }
      def read_double; end

      # Reads a struct of the given class, returning an instance.
      # 
      # Fields the class does not declare, or whose wire type does not match the declared type,
      # are skipped, so newer writers' additions do not break reading.
      # 
      # _@param_ `klass` — a Thrift::Struct subclass
      # 
      # _@return_ — an instance of +klass+ with the fields that were present set
      sig { params(klass: Class).returns(Struct) }
      def read_struct(klass); end

      # Reads one value of wire type +wire+ as declared +type+
      # 
      # _@param_ `wire` — wire type from the field or list header
      # 
      # _@param_ `type` — declared type; +:string+ makes binary values UTF-8 and +:binary+ makes them BINARY, an Array or Struct subclass gives the element type or struct to read
      # 
      # _@return_ — true/false, an Integer (bytes are signed), a Float, a String, an Array
      # (or nil, see #read_list) or a Struct
      sig { params(wire: Integer, type: T.any(Symbol, T::Array[T.untyped], Class)).returns(Object) }
      def read_value(wire, type); end

      # Reads a list or set, whose header holds the size (or 15 and a varint size) and the
      # element wire type
      # 
      # _@param_ `type` — declared list type, +[:list, elem_type]+
      # 
      # _@return_ — the elements, or nil (with the list skipped) when the element wire
      # type does not match +elem_type+
      sig { params(type: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
      def read_list(type); end

      # Advances past a value of wire type +wire+ without decoding it
      # 
      # _@param_ `wire` — wire type of the value to skip
      sig { params(wire: Integer).void }
      def skip(wire); end

      # Reads the element count of a list, set or map
      # 
      # Every element takes at least one byte, so a count above the bytes left is corrupt. Checking
      # that up front keeps a forged count from preallocating a huge Array or skipping for ever.
      # 
      # _@return_ — the count, at most the number of bytes left in the buffer
      sig { returns(Integer) }
      def read_size; end

      # Runs the block one nesting level deeper
      # 
      # _@return_ — the block's value
      sig { params(blk: T.proc.returns(Object)).returns(Object) }
      def nested(&blk); end

      # _@return_ — byte offset of the next byte to read
      sig { returns(Integer) }
      attr_reader :pos
    end

    # Encodes compact protocol data by appending to a binary String
    class Writer
      # _@param_ `buf` — binary String to append to
      sig { params(buf: String).void }
      def initialize(buf = String.new(capacity: 1024, encoding: Encoding::BINARY)); end

      # Writes an unsigned LEB128 varint
      # 
      # _@param_ `n` — non-negative value
      sig { params(n: Integer).void }
      def write_varint(n); end

      # Writes a signed integer as a zigzag varint
      # 
      # _@param_ `n` — signed value
      sig { params(n: Integer).void }
      def write_zigzag(n); end

      # Writes a length-prefixed byte string
      # 
      # _@param_ `s` — value whose bytes are written (in any encoding)
      sig { params(s: String).void }
      def write_binary(s); end

      # Writes the non-nil fields of a struct in field id order, then T_STOP. Field ids are
      # written as a delta in the header when it is 1..15, else as a separate zigzag varint.
      # Booleans are carried by the header's wire type alone.
      # 
      # _@param_ `obj` — instance of a Thrift::Struct subclass
      sig { params(obj: Struct).void }
      def write_struct(obj); end

      # Writes one value of a declared type. Not for +:bool+, whose value goes in a field or
      # list header (see #write_struct and #write_list).
      # 
      # _@param_ `type` — declared type (see WIRE_TYPES)
      # 
      # _@param_ `value` — Integer, Float, String, Array or Struct matching +type+
      sig { params(type: T.any(Symbol, T::Array[T.untyped], Class), value: Object).void }
      def write_value(type, value); end

      # Writes a list: a header with the size (inline when below 15) and element wire type,
      # then the elements. Booleans in lists are written as full bytes.
      # 
      # _@param_ `elem_type` — declared element type
      # 
      # _@param_ `values` — the elements
      sig { params(elem_type: T.any(Symbol, T::Array[T.untyped], Class), values: T::Array[T.untyped]).void }
      def write_list(elem_type, values); end

      # _@param_ `type` — declared integer type, a key of INT_RANGES
      # 
      # _@param_ `value` — value to be written as +type+
      # 
      # _@return_ — +value+
      sig { params(type: Symbol, value: Object).returns(Integer) }
      def checked_int(type, value); end

      # Parquet strings are UTF-8. Binary Strings are taken to hold UTF-8 bytes, Strings in other
      # encodings are converted.
      # 
      # _@param_ `s` — value of a +:string+ field
      # 
      # _@return_ — +s+, or a UTF-8 copy of it
      sig { params(s: String).returns(String) }
      def utf8(s); end

      # _@return_ — the encoded data so far
      sig { returns(String) }
      attr_reader :buf
    end

    # A field declared on a Thrift::Struct subclass
    # 
    # @!attribute [rw] id
    #   @return [Integer] Thrift field id
    # @!attribute [rw] name
    #   @return [Symbol] accessor name
    # @!attribute [rw] type
    #   @return [Symbol, Array, Class] declared type (see WIRE_TYPES)
    # @!attribute [rw] ivar
    #   @return [Symbol] instance variable holding the value (+:@name+)
    class Field < Struct
      # _@return_ — Thrift field id
      sig { returns(Integer) }
      attr_accessor :id

      # _@return_ — accessor name
      sig { returns(Symbol) }
      attr_accessor :name

      # _@return_ — declared type (see WIRE_TYPES)
      sig { returns(T.any(Symbol, T::Array[T.untyped], Class)) }
      attr_accessor :type

      # _@return_ — instance variable holding the value (+:@name+)
      sig { returns(Symbol) }
      attr_accessor :ivar
    end

    # Base class for Thrift structs. Subclasses declare fields with
    #   field 1, :name, :i32
    class Struct
      # _@return_ — declared fields, sorted by id, including the superclass's
      sig { returns(T::Array[Field]) }
      def self.fields; end

      # _@return_ — declared fields by id, for decoding
      sig { returns(T::Hash[Integer, Field]) }
      def self.fields_by_id; end

      # Declares a field and defines its accessor
      # 
      # _@param_ `id` — Thrift field id from parquet.thrift
      # 
      # _@param_ `name` — accessor name
      # 
      # _@param_ `type` — declared type: a WIRE_TYPES key, +[:list, elem]+ or a Struct subclass
      sig { params(id: Integer, name: Symbol, type: T.any(Symbol, T::Array[T.untyped], Class)).void }
      def self.field(id, name, type); end

      # Decodes an instance from +buf+ starting at +pos+
      # 
      # _@param_ `buf` — encoded data
      # 
      # _@param_ `pos` — byte offset of the struct in +buf+
      # 
      # _@return_ — the instance and the offset just past it
      sig { params(buf: String, pos: Integer).returns([Struct, Integer]) }
      def self.decode(buf, pos = 0); end

      # _@param_ `attrs` — initial field values, by accessor name
      sig { params(attrs: T::Hash[Symbol, Object]).void }
      def initialize(**attrs); end

      # _@return_ — the compact protocol encoding (binary)
      sig { returns(String) }
      def encode; end

      # Set fields as a Hash, with nested structs (also inside lists) converted too
      # 
      # _@return_ — values by field name, nil fields left out
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # Structs are equal when they are of the same class and have the same field values
      # 
      # _@param_ `other` — object to compare with
      # 
      # _@return_ — true when +other+ is an equal struct
      sig { params(other: Object).returns(T::Boolean) }
      def ==(other); end

      # _@return_ — hash agreeing with #==, so equal structs work as Hash keys and in +uniq+
      sig { returns(Integer) }
      def hash; end

      # _@return_ — short class name and the set fields
      sig { returns(String) }
      def inspect; end
    end
  end

  # Writes Parquet files.
  # 
  #   schema = Herringbone::Schema.define do |s|
  #     s.int64 :id, null: false
  #     s.string :name
  #     s.list :tags, :string
  #   end
  #   File.open("out.parquet", "wb") do |file|
  #     Herringbone::Writer.open(file, schema) do |w|
  #       w << { "id" => 1, "name" => "one", "tags" => ["a", "b"] }
  #       w << [2, "two", []]           # Arrays are taken in schema order
  #       w << order                    # objects responding to #attributes (ActiveRecord) or #to_h
  #     end
  #   end
  # 
  # The output is any IO that responds to #write (a File, StringIO, Tempfile, socket, pipe...); it
  # is written sequentially and never seeked, rewound or closed by the writer; only #write is
  # required, its return value is ignored, and #binmode and #flush are called when available.
  # Herringbone does not open files by path.
  # 
  # Options:
  #   compression:     :snappy (default), :zstd, :gzip, :lz4 (LZ4_RAW), :lz4_hadoop, :brotli, :none
  #                    (:zstd and :brotli need the zstd-ruby / brotli gems)
  #   compression_level: nil (the codec's default), or a level for :zstd (up to 22), :gzip (0-9)
  #                    or :brotli (0-11)
  #   row_group_bytes: flush a row group once the buffered values take roughly this much memory
  #                    (default 16MB). This bounds memory use while writing.
  #   row_group_rows:  also flush after this many rows (default: no row limit)
  #   page_bytes:      approximate uncompressed data page size (default 1MB)
  #   page_rows:       at most this many rows per data page (default 20_000), which keeps the page
  #                    index selective
  #   data_page_version: 1 (default) or 2
  #   dictionary:      true/false, or an Array of column paths to dictionary-encode
  #   encodings:       { "path.to.column" => :delta_binary_packed, ... } for non-dictionary pages
  #   metadata:        Hash of String => String key/value metadata for the footer
  #   bloom_filters:   write split block bloom filters: true (every column that supports them),
  #                    an Array of column paths, or { "path" => true | { ndv:, fpp:, max_bytes: } }.
  #                    Without ndv: the distinct values of each row group are counted. fpp defaults
  #                    to 0.01 and max_bytes to 1MB. Filters are written after each row group.
  #   encryption:      Parquet modular encryption: { footer_key: "...", columns: { "ssn" => "..." } }.
  #                    Without columns: every column is encrypted with the footer key. See
  #                    #initialize for the settings.
  # 
  # Statistics and page indexes (ColumnIndex/OffsetIndex) are always written.
  class Writer
    # Opens a writer on +io+. With a block, the file is finished (footer written) when the block
    # returns and the block's value is returned; if the block raises, the writer is aborted and no
    # footer is written. Without a block, call #close to finish. The IO is never closed.
    # 
    # _@param_ `io` — destination
    # 
    # _@param_ `schema` — schema of the rows
    # 
    # _@param_ `options` — see the class description and #initialize
    # 
    # _@return_ — the writer without a block, the block's value with one
    sig do
      params(
        io: T.any(IO, T.untyped),
        schema: Schema,
        options: T::Hash[Symbol, Object],
        blk: T.proc.params(writer: Writer).returns(Object)
      ).returns(T.any(Writer, Object))
    end
    def self.open(io, schema, **options, &blk); end

    # Internal (used by Redaction and Combiner): .open for a file whose row groups are all written
    # with #write_row_group, one for each row group of another file, so they keep their boundaries
    # 
    # _@param_ `io` — destination
    # 
    # _@param_ `schema` — schema of the rows
    # 
    # _@param_ `refusal` — why +row_group_bytes:+ and +row_group_rows:+ cannot be given, e.g. "a redaction keeps the row groups of the input"
    # 
    # _@param_ `options` — see .open, without the row group options
    # 
    # _@return_ — the block's value
    sig do
      params(
        io: T.any(IO, T.untyped),
        schema: Schema,
        refusal: String,
        options: T::Hash[Symbol, Object],
        block: T.proc.params(writer: Writer).returns(Object)
      ).returns(Object)
    end
    def self.open_for_copies(io, schema, refusal, **options, &block); end

    # Validates the options and writes the leading magic bytes to +io+.
    # 
    # _@param_ `io` — destination; switched to binmode when it supports that
    # 
    # _@param_ `schema` — schema of the rows
    # 
    # _@param_ `compression` — codec name (see Herringbone.codecs) or Format::Codec id
    # 
    # _@param_ `compression_level` — level for :zstd, :gzip or :brotli (see Compression::LEVELS), nil for the codec's default
    # 
    # _@param_ `row_group_bytes` — approximate buffered size that triggers a row group
    # 
    # _@param_ `row_group_rows` — also flush a row group after this many rows
    # 
    # _@param_ `page_bytes` — approximate uncompressed data page size
    # 
    # _@param_ `page_rows` — maximum level entries per data page (pages of repeated columns extend to the next row start)
    # 
    # _@param_ `data_page_version` — 1 or 2
    # 
    # _@param_ `dictionary` — true for every column except BOOLEAN, FLOAT, DOUBLE and those listed in +encodings+; false for none; or the dotted paths of the columns to encode
    # 
    # _@param_ `encodings` — dotted column path => value encoding (a name from ENCODING_NAMES or an encoding id) for non-dictionary pages
    # 
    # _@param_ `metadata` — key/value metadata for the footer
    # 
    # _@param_ `bloom_filters` — see the class description
    # 
    # _@param_ `encryption` — encrypts the file (Parquet modular encryption); a Hash holds the keywords of EncryptionConfiguration.new. Keys are 16, 24 or 32-byte Strings; key metadata is stored as given, for readers to find the keys by.
    sig do
      params(
        io: T.any(IO, T.untyped),
        schema: Schema,
        compression: T.any(Symbol, Integer),
        compression_level: T.nilable(Integer),
        row_group_bytes: Integer,
        row_group_rows: T.nilable(Integer),
        page_bytes: Integer,
        page_rows: Integer,
        data_page_version: Integer,
        dictionary: T.any(T::Boolean, T::Array[String]),
        encodings: T::Hash[T.any(String, Symbol), T.any(Symbol, Integer)],
        metadata: T::Hash[T.untyped, T.untyped],
        bloom_filters: T.nilable(T.any(T::Boolean, T::Array[String], T::Hash[String, T.any(T::Boolean, T::Hash[T.untyped, T.untyped])])),
        encryption: T.nilable(T.any(EncryptionConfiguration, T::Hash[Symbol, Object], T::Boolean))
      ).void
    end
    def initialize(io, schema, compression: :snappy, compression_level: nil, row_group_bytes: 16 * 1024 * 1024, row_group_rows: nil, page_bytes: 1024 * 1024, page_rows: 20_000, data_page_version: 1, dictionary: true, encodings: {}, metadata: {}, bloom_filters: nil, encryption: nil); end

    # Appends a row: a Hash keyed by top-level field names (Strings or Symbols), an Array of values
    # in schema order, or an object responding to #attributes (ActiveRecord) or #to_h (Struct, Data).
    # A row that fails to encode leaves nothing behind in the buffers. Flushes a row group when the
    # buffered rows reach the size limits.
    # 
    # _@param_ `row` — row to append
    sig { params(row: T.any(T::Hash[T.untyped, T.untyped], T::Array[T.untyped], T.untyped)).returns(T.self_type) }
    def <<(row); end

    # Number of rows written so far, including buffered ones
    sig { returns(Integer) }
    def rows_written; end

    # Writes any buffered rows as a row group
    sig { void }
    def flush_row_group; end

    # Internal (used by Redaction and Combiner): writes a row group of +num_rows+ rows from the
    # buffered values, except for the columns in +copies+, whose chunks are copied byte for byte
    # from another file with their offsets rebased. Starts a new row group afterwards.
    # 
    # _@param_ `num_rows` — rows in the row group
    # 
    # _@param_ `copies` — column index => chunk to copy instead of encoding (only plaintext chunks, into columns this writer does not encrypt)
    # 
    # _@param_ `codecs` — column index => codec id for an encoded chunk, instead of the +compression:+ option
    # 
    # _@param_ `bloom_filters` — column index => true to give an encoded chunk a bloom filter (default settings) when the +bloom_filters:+ option does not ask for one
    # 
    # _@param_ `sorting_columns` — stored on the RowGroup as given
    sig do
      params(
        num_rows: Integer,
        copies: T::Hash[Integer, CopiedChunk],
        codecs: T::Hash[Integer, Integer],
        bloom_filters: T::Hash[Integer, T::Boolean],
        sorting_columns: T.nilable(T::Array[Format::SortingColumn])
      ).void
    end
    def write_row_group(num_rows, copies: {}, codecs: {}, bloom_filters: {}, sorting_columns: nil); end

    # Internal (used by Redaction and Combiner): whether the column is encrypted in this file
    # 
    # _@param_ `index` — leaf column index
    sig { params(index: Integer).returns(T::Boolean) }
    def encrypted_column?(index); end

    # Internal (used by Redaction and Combiner): shreds one value per row of a top-level field into
    # the buffers, for #write_row_group. Other fields are left as they are, so the caller decides
    # which columns are encoded and which are copied.
    # 
    # _@param_ `name` — top-level field name
    # 
    # _@param_ `values` — the field's value for each row
    sig { params(name: String, values: T::Array[T.untyped]).void }
    def buffer_field(name, values); end

    # Flushes buffered rows, then writes the page indexes and the footer and flushes the IO.
    # Does nothing when already closed or aborted. The IO itself is not closed.
    sig { void }
    def close; end

    # Stops writing without finishing the file (no footer is written). Whatever was already written
    # to the IO stays there; discarding it is up to the caller.
    sig { void }
    def abort; end

    # Short summary for the console, without the buffered values
    # 
    # _@return_ — state (open, closed or aborted), rows written including buffered ones,
    # row groups flushed and the codec
    sig { returns(String) }
    def inspect; end

    # Pathname responds to #write too (writing a whole file by path), so it is rejected explicitly.
    # A text-mode IO (a pipe, or a File opened with "w") transcodes what is written when
    # Encoding.default_internal is set, as Rails does, and binary pages cannot be transcoded,
    # so the IO is switched to binary mode.
    # 
    # _@param_ `io` — candidate destination
    # 
    # _@return_ — +io+, in binary mode when it supports #binmode
    sig { params(io: Object).returns(T.any(IO, T.untyped)) }
    def check_io!(io); end

    # Starts a new row group: fresh buffers per column, and the per-field write plan
    # (field, name, Symbol name, buffer and encoder for flat fields, or nils for shredded ones).
    sig { void }
    def reset_buffers; end

    # _@param_ `col` — column to buffer
    # 
    # _@return_ — empty value store for the column
    sig { params(col: Schema::Column).returns(T.any(ByteValues, T::Array[T.untyped])) }
    def new_values_store(col); end

    # Flushes when the buffered values reach row_group_bytes (or row_group_rows rows). The bytes per
    # row are estimated from the buffered values after the first rows, then refreshed per row group.
    sig { void }
    def check_row_group_size; end

    # _@param_ `bytes_per_row` — estimated buffered bytes per row
    # 
    # _@return_ — rows to buffer before the next size check: what fits in row_group_bytes,
    # at least ESTIMATE_AFTER_ROWS, at most row_group_rows
    sig { params(bytes_per_row: Integer).returns(Integer) }
    def row_limit_for(bytes_per_row); end

    # _@return_ — memory held by the buffers divided by the buffered rows
    sig { returns(Integer) }
    def estimate_bytes_per_row; end

    # Writes to the IO and tracks the file offset, since the IO is never asked for its position
    # 
    # _@param_ `bytes` — binary data
    sig { params(bytes: String).void }
    def write_raw(bytes); end

    # _@param_ `path` — column path, for the error message
    # 
    # _@param_ `enc` — encoding name from ENCODING_NAMES, or an encoding id
    # 
    # _@return_ — encoding id
    sig { params(path: T.any(String, Symbol), enc: T.any(Symbol, String, Integer)).returns(Integer) }
    def encoding_id(path, enc); end

    # _@param_ `col` — column the encoding is requested for
    # 
    # _@param_ `enc` — encoding id, a key of VALID_ENCODINGS
    sig { params(col: Schema::Column, enc: Integer).void }
    def check_encoding!(col, enc); end

    # Reads a struct member, by String or Symbol key
    # 
    # _@param_ `hash` — struct value
    # 
    # _@param_ `name` — member name
    # 
    # _@return_ — member value, nil when +hash+ is nil or has no such key
    sig { params(hash: T.nilable(T.any(T::Hash[T.untyped, T.untyped], T.untyped)), name: String).returns(T.nilable(Object)) }
    def lookup(hash, name); end

    # _@param_ `row` — row given to #<<
    # 
    # _@return_ — the row keyed by top-level field names
    sig { params(row: T.any(T::Hash[T.untyped, T.untyped], T::Array[T.untyped], T.untyped)).returns(T::Hash[T.untyped, T.untyped]) }
    def row_hash(row); end

    # _@param_ `value` — value to convert
    # 
    # _@param_ `what` — description of the value, for the error message
    sig { params(value: T.any(T::Hash[T.untyped, T.untyped], T.untyped), what: String).returns(T::Hash[T.untyped, T.untyped]) }
    def as_hash(value, what); end

    # Removes the entries a failed row left behind, so the buffers stay aligned
    # 
    # _@param_ `marks` — sizes of defs, reps and values of each nested buffer before the row, nil when there are none
    sig { params(marks: T.nilable(T::Array[[Integer, Integer, Integer]])).void }
    def rollback_row(marks); end

    # Record shredding: turns a nested value into (definition level, repetition level, value) entries
    # 
    # _@param_ `field` — field the value belongs to
    # 
    # _@param_ `value` — Ruby value of the field
    # 
    # _@param_ `parent_def` — definition level recorded when +value+ is nil
    # 
    # _@param_ `rep` — repetition level of the first entry this value produces
    sig do
      params(
        field: Schema::Field,
        value: T.nilable(Object),
        parent_def: Integer,
        rep: Integer
      ).void
    end
    def shred(field, value, parent_def, rep); end

    # Writes one column chunk of the current row group: an optional dictionary page, then data pages.
    # Bloom filters and page indexes are queued, to be written after the row group and before the
    # footer.
    # 
    # _@param_ `col` — column being written
    # 
    # _@param_ `buffer` — the column's buffered levels and values
    # 
    # _@param_ `codec` — codec id to compress the pages with
    # 
    # _@param_ `bloom` — bloom filter settings (see #bloom_filter_settings), nil for no bloom filter
    # 
    # _@return_ — chunk with its ColumnMetaData, for the row group
    sig do
      params(
        col: Schema::Column,
        buffer: ColumnBuffer,
        codec: Integer,
        bloom: T.nilable(T::Hash[Symbol, T.nilable(Numeric)])
      ).returns(Format::ColumnChunk)
    end
    def write_column_chunk(col, buffer, codec: @codec, bloom: ); end

    # _@param_ `pages` — pages of a column chunk
    sig { params(pages: T::Array[PageInfo]).returns(Format::OffsetIndex) }
    def offset_index_for(pages); end

    # Writes a chunk copied from another file. The pages, the ColumnIndex and the bloom filter
    # hold no file offsets and go out as they are; the ColumnMetaData and the OffsetIndex do, so
    # those are rebased onto where the chunk lands in this file. The path is this file's, which
    # differs when the source file names list elements another way ("list.item", "array").
    # 
    # _@param_ `col` — the column the chunk is copied into
    # 
    # _@param_ `copy` — the chunk to copy
    # 
    # _@return_ — chunk with its ColumnMetaData, for the row group
    sig { params(col: Schema::Column, copy: CopiedChunk).returns(Format::ColumnChunk) }
    def copy_column_chunk(col, copy); end

    # nil when the column has no defined sort order, or a page's values have no min/max (all NaN)
    # 
    # _@param_ `col` — column the pages belong to
    # 
    # _@param_ `pages` — pages of the column chunk
    # 
    # _@param_ `order` — sort key from #sort_key
    sig { params(col: Schema::Column, pages: T::Array[PageInfo], order: T.nilable(T.any(Proc, Method))).returns(T.nilable(Format::ColumnIndex)) }
    def column_index_for(col, pages, order); end

    # _@param_ `ranges` — [min, max] of each non-null page, in page order
    # 
    # _@param_ `order` — sort key from #sort_key
    # 
    # _@return_ — Format::BoundaryOrder: ASCENDING when both mins and maxes never decrease
    # (or there are fewer than two pages), DESCENDING when they never increase, else UNORDERED
    sig { params(ranges: T::Array[[Object, Object]], order: T.any(Proc, Method)).returns(Integer) }
    def boundary_order(ranges, order); end

    # Page indexes go after the last row group: all column indexes, then all offset indexes.
    # A copied chunk brings its ColumnIndex already encoded, and may come without either index.
    # Those of encrypted columns are encrypted.
    sig { void }
    def write_page_indexes; end

    # { dotted_path => { ndv:, fpp:, max_bytes: } } from the bloom_filters: option
    # 
    # _@param_ `requested` — true for every column of a supported type, column paths, or column path => true / false / settings Hash. A path may also be given as an Array of names. Settings are +ndv+, +fpp+ and +max_bytes+.
    # 
    # _@return_ — settings by dotted path; empty when disabled
    sig { params(requested: T.nilable(T.any(T::Boolean, T::Array[String], T::Hash[String, T.nilable(T.any(T::Boolean, T::Hash[T.untyped, T.untyped]))]))).returns(T::Hash[String, T::Hash[Symbol, T.nilable(Numeric)]]) }
    def bloom_filter_config(requested); end

    # _@param_ `settings` — +ndv+, +fpp+ and +max_bytes+, all optional
    # 
    # _@param_ `path` — column path, for error messages
    # 
    # _@return_ — +ndv+ (nil to count distinct values), +fpp+ and
    # +max_bytes+ with defaults filled in
    sig { params(settings: T::Hash[Symbol, Object], path: T.nilable(String)).returns(T::Hash[Symbol, T.nilable(Numeric)]) }
    def bloom_filter_settings(settings, path = nil); end

    # A filter holding the chunk's values: +dict_values+ (already distinct) for dictionary-encoded
    # chunks, +values+ otherwise. Each distinct value is hashed once, and the filter is sized from
    # the configured ndv or from the number of distinct values.
    # 
    # _@param_ `col` — column the filter is for
    # 
    # _@param_ `settings` — from #bloom_filter_settings
    # 
    # _@param_ `dict_values` — dictionary of the chunk, when dictionary-encoded
    # 
    # _@param_ `values` — the chunk's non-null physical values, used without a dictionary
    sig do
      params(
        col: Schema::Column,
        settings: T::Hash[Symbol, T.nilable(Numeric)],
        dict_values: T.nilable(T::Array[T.untyped]),
        values: T.nilable(T::Array[T.untyped])
      ).returns(BloomFilter)
    end
    def build_bloom_filter(col, settings, dict_values, values); end

    # Bloom filters go right after the row group's column chunks, in column order. A copied
    # chunk brings its filter already encoded. In an encrypted column the header and the bitset
    # are encrypted separately.
    sig { void }
    def write_bloom_filters; end

    # _@param_ `col` — column to check
    # 
    # _@return_ — whether the +dictionary:+ option asks for this column to be dictionary-encoded
    # (never for BOOLEAN)
    sig { params(col: Schema::Column).returns(T::Boolean) }
    def use_dictionary?(col); end

    # Returns [dictionary_values, indices] or nil when a dictionary is not worthwhile: more than about
    # half the values are distinct, or the dictionary exceeds MAX_DICTIONARY_BYTES
    # 
    # _@param_ `values` — non-null physical values of the chunk
    # 
    # _@param_ `type` — physical type
    # 
    # _@param_ `type_length` — FIXED_LEN_BYTE_ARRAY width
    sig { params(values: T::Array[T.untyped], type: Integer, type_length: T.nilable(Integer)).returns(T.nilable([T::Array[T.untyped], T::Array[Integer]])) }
    def build_dictionary(values, type, type_length); end

    # Splits a column buffer into pages of roughly @page_bytes bytes. Repeated columns
    # are only cut where a new row starts.
    # 
    # _@param_ `buf` — column buffer with levels as Arrays
    # 
    # _@param_ `value_bytes` — estimated encoded size of all the chunk's values
    # 
    # _@return_ — [from, to) ranges of level entries, one per page
    sig { params(buf: ColumnBuffer, value_bytes: Integer).returns(T::Array[[Integer, Integer]]) }
    def page_ranges(buf, value_bytes); end

    # _@param_ `col` — column to check
    # 
    # _@return_ — PLAIN-encoded bytes per value, nil for BYTE_ARRAY (variable width)
    sig { params(col: Schema::Column).returns(T.nilable(Integer)) }
    def value_width(col); end

    # Encodes a page's values. RLE_DICTIONARY values are the dictionary indices, prefixed with the
    # bit width byte; RLE is only used for BOOLEAN and carries the 4-byte length prefix.
    # 
    # _@param_ `values` — physical values, or dictionary indices
    # 
    # _@param_ `encoding` — encoding id
    # 
    # _@param_ `type` — physical type
    # 
    # _@param_ `type_length` — FIXED_LEN_BYTE_ARRAY width
    # 
    # _@param_ `dict_size` — number of dictionary entries, for RLE_DICTIONARY
    # 
    # _@return_ — encoded binary page values
    sig do
      params(
        values: T::Array[T.untyped],
        encoding: Integer,
        type: Integer,
        type_length: T.nilable(Integer),
        dict_size: T.nilable(Integer)
      ).returns(String)
    end
    def encode_values(values, encoding, type, type_length, dict_size); end

    # Writes a page, returning the uncompressed size including the header
    # 
    # Compresses with the configured level when +codec+ is the writer's own; chunks a redaction
    # keeps in their source codec use that codec's default
    # 
    # _@param_ `codec` — codec id
    # 
    # _@param_ `data` — bytes to compress, or the parts of them
    # 
    # _@return_ — compressed bytes
    sig { params(codec: Integer, data: T.any(String, T::Array[String])).returns(String) }
    def compress(codec, data); end

    # In an encrypted column the body and the header are encrypted; the CRC covers the body as
    # stored, encrypted.
    # 
    # _@param_ `header` — header; sizes and CRC32 are filled in here
    # 
    # _@param_ `body` — uncompressed page body, or its parts
    # 
    # _@param_ `compressed` — bytes to write as the page body, or their parts, when already prepared (v2 data pages, whose levels stay uncompressed); +body+ is compressed otherwise
    # 
    # _@param_ `codec` — codec id to compress +body+ with
    # 
    # _@param_ `crypto` — encryption of the column's modules
    # 
    # _@param_ `ordinal` — data page ordinal within the chunk; nil for a dictionary page
    sig do
      params(
        header: Format::PageHeader,
        body: T.any(String, T::Array[String]),
        compressed: T.nilable(T.any(String, T::Array[String])),
        codec: Integer,
        crypto: T.nilable(Encryption::ModuleCrypto),
        ordinal: T.nilable(Integer)
      ).returns(Integer)
    end
    def write_page(header, body, compressed = nil, codec: @codec, crypto: nil, ordinal: nil); end

    # A DATA_PAGE: length-prefixed repetition and definition levels, then the values, all compressed
    # 
    # _@param_ `n` — number of level entries (values including nulls)
    # 
    # _@param_ `rep_bytes` — RLE-encoded repetition levels, empty when the column has none
    # 
    # _@param_ `def_bytes` — RLE-encoded definition levels, empty when the column has none
    # 
    # _@param_ `encoded` — encoded values
    # 
    # _@param_ `encoding` — encoding id of the values
    # 
    # _@param_ `codec` — codec id to compress the page with
    # 
    # _@param_ `page_crypto` — encryption of the column's modules and the page's ordinal, for an encrypted column
    # 
    # _@return_ — uncompressed size including the header
    sig do
      params(
        n: Integer,
        rep_bytes: String,
        def_bytes: String,
        encoded: String,
        encoding: Integer,
        codec: Integer,
        page_crypto: T.nilable([Encryption::ModuleCrypto, Integer])
      ).returns(Integer)
    end
    def write_data_page_v1(n, rep_bytes, def_bytes, encoded, encoding, codec, page_crypto); end

    # A DATA_PAGE_V2: levels without length prefixes and uncompressed, then the compressed values
    # 
    # _@param_ `n` — number of level entries (values including nulls)
    # 
    # _@param_ `nulls` — null entries
    # 
    # _@param_ `rows` — rows in the page
    # 
    # _@param_ `rep_bytes` — RLE-encoded repetition levels, empty when the column has none
    # 
    # _@param_ `def_bytes` — RLE-encoded definition levels, empty when the column has none
    # 
    # _@param_ `encoded` — encoded values
    # 
    # _@param_ `encoding` — encoding id of the values
    # 
    # _@param_ `codec` — codec id to compress the values with
    # 
    # _@param_ `page_crypto` — encryption of the column's modules and the page's ordinal, for an encrypted column
    # 
    # _@return_ — uncompressed size including the header
    sig do
      params(
        n: Integer,
        nulls: Integer,
        rows: Integer,
        rep_bytes: String,
        def_bytes: String,
        encoded: String,
        encoding: Integer,
        codec: Integer,
        page_crypto: T.nilable([Encryption::ModuleCrypto, Integer])
      ).returns(Integer)
    end
    def write_data_page_v2(n, nulls, rows, rep_bytes, def_bytes, encoded, encoding, codec, page_crypto); end

    # Chunk statistics: null count, plus min/max (flagged exact unless truncated) when the column
    # has a sort order and non-NaN values
    # 
    # _@param_ `col` — column the chunk belongs to
    # 
    # _@param_ `defs` — definition levels of the chunk
    # 
    # _@param_ `values` — distinct or all non-null physical values of the chunk
    # 
    # _@param_ `order` — sort key from #sort_key
    sig do
      params(
        col: Schema::Column,
        defs: T::Array[Integer],
        values: T::Array[T.untyped],
        order: T.nilable(T.any(Proc, Method))
      ).returns(Format::Statistics)
    end
    def statistics_for(col, defs, values, order); end

    # A key giving the Parquet sort order of the column's physical values (IDENTITY when Ruby's own
    # comparison already matches), or nil when the order is undefined (INT96)
    # 
    # _@param_ `col` — column to order
    sig { params(col: Schema::Column).returns(T.nilable(T.any(Proc, Method))) }
    def sort_key(col); end

    # [min, max] of +values+ in column order, ignoring NaNs; nil if there is nothing to compare.
    # A zero float bound is normalized to -0.0 (min) / 0.0 (max), as the spec asks.
    # 
    # _@param_ `col` — column the values belong to
    # 
    # _@param_ `values` — physical values
    # 
    # _@param_ `order` — sort key from #sort_key
    sig { params(col: Schema::Column, values: T::Array[T.untyped], order: T.any(Proc, Method)).returns(T.nilable([Object, Object])) }
    def value_range(col, values, order); end

    # _@param_ `col` — column the value belongs to
    # 
    # _@param_ `value` — physical value
    # 
    # _@return_ — the value PLAIN-encoded, as statistics store it (byte arrays without length)
    sig { params(col: Schema::Column, value: Object).returns(String) }
    def stat_bytes(col, value); end

    # Long byte-array bounds are truncated: a prefix is still a lower bound for the minimum, and
    # a prefix with its last byte incremented is an upper bound for the maximum
    # 
    # _@param_ `bytes` — encoded minimum
    # 
    # _@return_ — at most STAT_TRUNCATE_BYTES bytes
    sig { params(bytes: String).returns(String) }
    def truncate_min(bytes); end

    # _@param_ `bytes` — encoded maximum
    # 
    # _@return_ — at most STAT_TRUNCATE_BYTES bytes, with the last byte that is not 0xFF
    # incremented (trailing 0xFF bytes dropped); +bytes+ unchanged when it fits, or when the
    # whole prefix is 0xFF
    sig { params(bytes: String).returns(String) }
    def truncate_max(bytes); end

    # _@return_ — schema the rows are written with
    sig { returns(Schema) }
    attr_reader :schema

    # A column chunk taken as it is from another file, for #write_row_group
    # 
    # @!attribute chunk
    #   @return [Format::ColumnChunk] the chunk's footer entry in the source file
    # @!attribute start
    #   @return [Integer] source file offset of the chunk's first page
    # @!attribute bytes
    #   @return [String] the chunk's pages, headers included
    # @!attribute column_index
    #   @return [String, nil] the chunk's encoded ColumnIndex
    # @!attribute offset_index
    #   @return [Format::OffsetIndex, nil] the chunk's OffsetIndex, with source file offsets
    # @!attribute bloom_filter
    #   @return [String, nil] the chunk's encoded bloom filter, header included
    # @api private
    class CopiedChunk < Struct
      # _@return_ — the chunk's footer entry in the source file
      sig { returns(Format::ColumnChunk) }
      attr_accessor :chunk

      # _@return_ — source file offset of the chunk's first page
      sig { returns(Integer) }
      attr_accessor :start

      # _@return_ — the chunk's pages, headers included
      sig { returns(String) }
      attr_accessor :bytes

      # _@return_ — the chunk's encoded ColumnIndex
      sig { returns(T.nilable(String)) }
      attr_accessor :column_index

      # _@return_ — the chunk's OffsetIndex, with source file offsets
      sig { returns(T.nilable(Format::OffsetIndex)) }
      attr_accessor :offset_index

      # _@return_ — the chunk's encoded bloom filter, header included
      sig { returns(T.nilable(String)) }
      attr_accessor :bloom_filter
    end

    # Levels are kept as binary Strings (one byte per entry). Values are an Array for numeric and
    # boolean columns, and a compact ByteValues for BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY columns.
    # 
    # @!attribute defs
    #   @return [String, Array<Integer>] definition levels (unpacked to an Array while a chunk is written)
    # @!attribute reps
    #   @return [String, Array<Integer>, nil] repetition levels, like +defs+; nil for non-repeated columns
    # @!attribute values
    #   @return [Array, ByteValues] non-null physical values
    # @api private
    class ColumnBuffer < Struct
      # _@return_ — definition levels (unpacked to an Array while a chunk is written)
      sig { returns(T.any(String, T::Array[Integer])) }
      attr_accessor :defs

      # _@return_ — repetition levels, like +defs+; nil for non-repeated columns
      sig { returns(T.nilable(T.any(String, T::Array[Integer]))) }
      attr_accessor :reps

      # _@return_ — non-null physical values
      sig { returns(T.any(T::Array[T.untyped], ByteValues)) }
      attr_accessor :values
    end

    # What the page indexes need to know about a written data page
    # 
    # @!attribute offset
    #   @return [Integer] file offset of the page header
    # @!attribute size
    #   @return [Integer] page size in the file, header included
    # @!attribute first_row
    #   @return [Integer] index of the page's first row within the row group
    # @!attribute nulls
    #   @return [Integer] null entries in the page
    # @!attribute non_null
    #   @return [Integer] non-null values in the page
    # @!attribute range
    #   @return [Array(Object, Object), nil] [min, max] physical values, nil when there are none
    # @api private
    class PageInfo < Struct
      # _@return_ — file offset of the page header
      sig { returns(Integer) }
      attr_accessor :offset

      # _@return_ — page size in the file, header included
      sig { returns(Integer) }
      attr_accessor :size

      # _@return_ — index of the page's first row within the row group
      sig { returns(Integer) }
      attr_accessor :first_row

      # _@return_ — null entries in the page
      sig { returns(Integer) }
      attr_accessor :nulls

      # _@return_ — non-null values in the page
      sig { returns(Integer) }
      attr_accessor :non_null

      # _@return_ — [min, max] physical values, nil when there are none
      sig { returns(T.nilable([Object, Object])) }
      attr_accessor :range
    end
  end

  # XXH64 (seed 0), the hash Parquet bloom filters use.
  # 
  # When the optional "xxhash" gem (a C extension) is loaded (+require "xxhash"+) it is used,
  # which is 20-40x faster; otherwise hashing is pure Ruby. The gem is only a speedup, so nothing
  # fails without it. +XXHash.backend = :ruby+ forces pure Ruby (for tests and benchmarks).
  # 
  # The pure-Ruby version keeps every 64-bit value as two 32-bit halves, and multiplies by the
  # XXH64 primes split into 16-bit pieces, so that no intermediate result leaves the Fixnum range.
  # Masked 64-bit Integer arithmetic is shorter, but allocates a Bignum for almost every operation
  # (about 25 per hash), and with a large live heap (a writer holding a row group) those
  # allocations trigger so many garbage collections that hashing becomes up to 10x slower. The
  # arithmetic is written once with the small code generators below, whose output is inlined into
  # the hashing methods: no method calls or allocations in the hot paths.
  # 
  # @api private
  module XXHash
    # XXH64 of a String's bytes, as an unsigned 64-bit Integer
    # 
    # _@param_ `bytes` — data to hash (its encoding is ignored)
    # 
    # _@return_ — the hash, 0...2^64
    sig { params(bytes: String).returns(Integer) }
    def self.xxh64(bytes); end

    # XXH64 of 8 bytes given as a little-endian 64-bit Integer (an INT64 or DOUBLE's PLAIN
    # encoding), signed or unsigned: only its low 64 bits are used
    # 
    # _@param_ `lane` — value whose low 64 bits are hashed
    # 
    # _@return_ — the hash, 0...2^64
    sig { params(lane: Integer).returns(Integer) }
    def self.xxh64_u64(lane); end

    # XXH64 of 4 bytes given as a little-endian 32-bit Integer (INT32, FLOAT), signed or unsigned
    # 
    # _@param_ `word` — value whose low 32 bits are hashed
    # 
    # _@return_ — the hash, 0...2^64
    sig { params(word: Integer).returns(Integer) }
    def self.xxh64_u32(word); end

    # Hashes of many 64-bit Integers (low 64 bits of each)
    # 
    # _@param_ `lanes` — values to hash, signed or unsigned
    # 
    # _@return_ — the hashes, in the same order
    sig { params(lanes: T::Array[Integer]).returns(T::Array[Integer]) }
    def self.xxh64_u64_all(lanes); end

    # Hashes of many 32-bit Integers (low 32 bits of each)
    # 
    # _@param_ `words` — values to hash, signed or unsigned
    # 
    # _@return_ — the hashes, in the same order
    sig { params(words: T::Array[Integer]).returns(T::Array[Integer]) }
    def self.xxh64_u32_all(words); end

    # Hashes of many Strings
    # 
    # _@param_ `strings` — values whose bytes are hashed
    # 
    # _@return_ — the hashes, in the same order
    sig { params(strings: T::Array[String]).returns(T::Array[Integer]) }
    def self.xxh64_all(strings); end

    # :native when the xxhash gem is used, :ruby otherwise
    # 
    # _@return_ — +:native+ or +:ruby+
    sig { returns(Symbol) }
    def self.backend; end

    # :ruby forces pure Ruby, :native the xxhash gem (UnsupportedError if it is not loaded), nil
    # goes back to the default: native when loaded
    # 
    # _@param_ `name` — +:ruby+, +:native+ or nil
    sig { params(name: T.nilable(Symbol)).void }
    def self.backend=(name); end

    # Whether the native xxhash gem is loaded (whatever the selected backend)
    # 
    # _@return_ — true when the gem is loaded
    sig { returns(T::Boolean) }
    def self.native_available?; end

    # Not memoized, so that it works the same in every Ractor and once the gem is required later
    # 
    # _@return_ — the gem's module to call +xxh64(data, seed)+ on, or false when it
    # is not loaded
    sig { returns(T.any(Module, T::Boolean)) }
    def self.native_library; end

    # Code generators for the pure-Ruby hash: each returns Ruby source operating on a 64-bit
    # value held in two local variables (+hi+ and +lo+, 32 bits each), using t0/t1 as scratch
    module Generator
      # Shifts are written as multiplications and divisions by powers of two, which YARV has
      # specialized instructions for (<< and >> on Integers are method calls).
      # 
      # (hi:lo) = (hi:lo) * c mod 2^64. Products are at most 48 bits wide: the low halves are
      # multiplied by 16-bit pieces of c, and only the low 32 bits of the cross terms are kept.
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant multiplier
      # 
      # _@param_ `hi_zero` — whether +hi+ is known to be 0, which drops its cross terms
      # 
      # _@return_ — Ruby source (uses t0 and t1 as scratch)
      sig do
        params(
          hi: String,
          lo: String,
          c: Integer,
          hi_zero: T::Boolean
        ).returns(String)
      end
      def mul(hi, lo, c, hi_zero: false); end

      # Shifts are written as multiplications and divisions by powers of two, which YARV has
      # specialized instructions for (<< and >> on Integers are method calls).
      # 
      # (hi:lo) = (hi:lo) * c mod 2^64. Products are at most 48 bits wide: the low halves are
      # multiplied by 16-bit pieces of c, and only the low 32 bits of the cross terms are kept.
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant multiplier
      # 
      # _@param_ `hi_zero` — whether +hi+ is known to be 0, which drops its cross terms
      # 
      # _@return_ — Ruby source (uses t0 and t1 as scratch)
      sig do
        params(
          hi: String,
          lo: String,
          c: Integer,
          hi_zero: T::Boolean
        ).returns(String)
      end
      def self.mul(hi, lo, c, hi_zero: false); end

      # Rotate (hi:lo) left by r bits (0 < r < 32)
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `r` — rotation in bits, 1..31
      # 
      # _@return_ — Ruby source (uses t0 as scratch)
      sig { params(hi: String, lo: String, r: Integer).returns(String) }
      def rotl(hi, lo, r); end

      # Rotate (hi:lo) left by r bits (0 < r < 32)
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `r` — rotation in bits, 1..31
      # 
      # _@return_ — Ruby source (uses t0 as scratch)
      sig { params(hi: String, lo: String, r: Integer).returns(String) }
      def self.rotl(hi, lo, r); end

      # (hi:lo) += (a_hi:a_lo), where the addend is two expressions (constants or variables)
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `a_hi` — expression for the addend's high 32 bits
      # 
      # _@param_ `a_lo` — expression for the addend's low 32 bits
      # 
      # _@return_ — Ruby source
      sig do
        params(
          hi: String,
          lo: String,
          a_hi: T.any(String, Integer),
          a_lo: T.any(String, Integer)
        ).returns(String)
      end
      def add(hi, lo, a_hi, a_lo); end

      # (hi:lo) += (a_hi:a_lo), where the addend is two expressions (constants or variables)
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `a_hi` — expression for the addend's high 32 bits
      # 
      # _@param_ `a_lo` — expression for the addend's low 32 bits
      # 
      # _@return_ — Ruby source
      sig do
        params(
          hi: String,
          lo: String,
          a_hi: T.any(String, Integer),
          a_lo: T.any(String, Integer)
        ).returns(String)
      end
      def self.add(hi, lo, a_hi, a_lo); end

      # (hi:lo) += c, mod 2^64
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant addend
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String, c: Integer).returns(String) }
      def add_const(hi, lo, c); end

      # (hi:lo) += c, mod 2^64
      # 
      # _@param_ `hi` — variable holding the high 32 bits
      # 
      # _@param_ `lo` — variable holding the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant addend
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String, c: Integer).returns(String) }
      def self.add_const(hi, lo, c); end

      # Assigns the 64-bit constant c to (hi:lo)
      # 
      # _@param_ `hi` — variable for the high 32 bits
      # 
      # _@param_ `lo` — variable for the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String, c: Integer).returns(String) }
      def set(hi, lo, c); end

      # Assigns the 64-bit constant c to (hi:lo)
      # 
      # _@param_ `hi` — variable for the high 32 bits
      # 
      # _@param_ `lo` — variable for the low 32 bits
      # 
      # _@param_ `c` — unsigned 64-bit constant
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String, c: Integer).returns(String) }
      def self.set(hi, lo, c); end

      # XXH64 round with a zero accumulator: (hi:lo) = rotl(lane * P2, 31) * P1
      # 
      # _@param_ `hi` — variable holding the lane's high 32 bits, replaced by the result's
      # 
      # _@param_ `lo` — variable holding the lane's low 32 bits, replaced by the result's
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def round0(hi, lo); end

      # XXH64 round with a zero accumulator: (hi:lo) = rotl(lane * P2, 31) * P1
      # 
      # _@param_ `hi` — variable holding the lane's high 32 bits, replaced by the result's
      # 
      # _@param_ `lo` — variable holding the lane's low 32 bits, replaced by the result's
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def self.round0(hi, lo); end

      # Stripe round: acc = rotl(acc + lane * P2, 31) * P1, with the lane in (xh:xl)
      # 
      # _@param_ `hi` — variable holding the accumulator's high 32 bits
      # 
      # _@param_ `lo` — variable holding the accumulator's low 32 bits
      # 
      # _@param_ `xh` — variable holding the lane's high 32 bits (clobbered)
      # 
      # _@param_ `xl` — variable holding the lane's low 32 bits (clobbered)
      # 
      # _@return_ — Ruby source
      sig do
        params(
          hi: String,
          lo: String,
          xh: String,
          xl: String
        ).returns(String)
      end
      def round(hi, lo, xh, xl); end

      # Stripe round: acc = rotl(acc + lane * P2, 31) * P1, with the lane in (xh:xl)
      # 
      # _@param_ `hi` — variable holding the accumulator's high 32 bits
      # 
      # _@param_ `lo` — variable holding the accumulator's low 32 bits
      # 
      # _@param_ `xh` — variable holding the lane's high 32 bits (clobbered)
      # 
      # _@param_ `xl` — variable holding the lane's low 32 bits (clobbered)
      # 
      # _@return_ — Ruby source
      sig do
        params(
          hi: String,
          lo: String,
          xh: String,
          xl: String
        ).returns(String)
      end
      def self.round(hi, lo, xh, xl); end

      # h ^= rotl(v * P2, 31) * P1; h = h * P1 + P4, with v in (vh:vl) (left unchanged)
      # 
      # _@param_ `hi` — variable holding h's high 32 bits
      # 
      # _@param_ `lo` — variable holding h's low 32 bits
      # 
      # _@param_ `vh` — variable holding the accumulator v's high 32 bits
      # 
      # _@param_ `vl` — variable holding the accumulator v's low 32 bits
      # 
      # _@return_ — Ruby source (uses xh and xl as scratch)
      sig do
        params(
          hi: String,
          lo: String,
          vh: String,
          vl: String
        ).returns(String)
      end
      def merge_round(hi, lo, vh, vl); end

      # h ^= rotl(v * P2, 31) * P1; h = h * P1 + P4, with v in (vh:vl) (left unchanged)
      # 
      # _@param_ `hi` — variable holding h's high 32 bits
      # 
      # _@param_ `lo` — variable holding h's low 32 bits
      # 
      # _@param_ `vh` — variable holding the accumulator v's high 32 bits
      # 
      # _@param_ `vl` — variable holding the accumulator v's low 32 bits
      # 
      # _@return_ — Ruby source (uses xh and xl as scratch)
      sig do
        params(
          hi: String,
          lo: String,
          vh: String,
          vl: String
        ).returns(String)
      end
      def self.merge_round(hi, lo, vh, vl); end

      # Consumes an 8-byte lane in (xh:xl)
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def lane8(hi, lo); end

      # Consumes an 8-byte lane in (xh:xl)
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def self.lane8(hi, lo); end

      # Consumes a 4-byte word in xl
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source (sets xh)
      sig { params(hi: String, lo: String).returns(String) }
      def lane4(hi, lo); end

      # Consumes a 4-byte word in xl
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source (sets xh)
      sig { params(hi: String, lo: String).returns(String) }
      def self.lane4(hi, lo); end

      # Consumes one byte in xl (as it is below 2^16, byte * P5 needs no splitting)
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def lane1(hi, lo); end

      # Consumes one byte in xl (as it is below 2^16, byte * P5 needs no splitting)
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source
      sig { params(hi: String, lo: String).returns(String) }
      def self.lane1(hi, lo); end

      # Final mix; evaluates to the hash as one Integer
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source whose last expression is the 64-bit hash
      sig { params(hi: String, lo: String).returns(String) }
      def avalanche(hi, lo); end

      # Final mix; evaluates to the hash as one Integer
      # 
      # _@param_ `hi` — variable holding the hash's high 32 bits
      # 
      # _@param_ `lo` — variable holding the hash's low 32 bits
      # 
      # _@return_ — Ruby source whose last expression is the 64-bit hash
      sig { params(hi: String, lo: String).returns(String) }
      def self.avalanche(hi, lo); end

      # Source of the pure-Ruby hashing methods, evaluated into XXHash: +ruby_xxh64(bytes)+,
      # +ruby_xxh64_lane(xh, xl)+ (8 bytes as two 32-bit halves) and +ruby_xxh64_u32(xl)+ (4 bytes)
      # 
      # _@return_ — Ruby source defining the three singleton methods
      sig { returns(String) }
      def source; end

      # Source of the pure-Ruby hashing methods, evaluated into XXHash: +ruby_xxh64(bytes)+,
      # +ruby_xxh64_lane(xh, xl)+ (8 bytes as two 32-bit halves) and +ruby_xxh64_u32(xl)+ (4 bytes)
      # 
      # _@return_ — Ruby source defining the three singleton methods
      sig { returns(String) }
      def self.source; end
    end
  end

  # Concatenates Parquet files into one, behind Herringbone.combine. Building it reads the footer of
  # every input and checks every input against the output schema, so all mismatches surface at
  # once, before anything is written.
  # 
  # Every row group of every input becomes a row group of the output, in order. Column chunks are
  # copied byte for byte wherever the output stores a column's values as the input does, and only
  # their offsets (in the column metadata, the page index and the bloom filter references) are
  # rebased. That holds per leaf column, so a narrower input still has most of its chunks copied.
  # Columns that cannot be copied are encoded again from their values: those the output widens in
  # physical type, time unit or nullability, and those encrypted in the input or to be encrypted in
  # the output. Fields an input lacks are written as nulls.
  # 
  # @api private
  class Combiner
    # _@param_ `ios_or_readers` — the input files: IOs read with #seek and #read, or Readers (which bring their own +decryption:+); enumerated once, and none is closed
    # 
    # _@param_ `schema` — the output schema: nil when every input has the same one, +:union+ for the union of the inputs' schemas, +:intersect+ for their intersection, or a Schema each input must fit
    # 
    # _@param_ `decryption` — keys of encrypted inputs given as IOs, see Reader.new
    sig { params(ios_or_readers: T::Enumerable[T.any(IO, StringIO, Reader)], schema: T.nilable(T.any(Schema, Symbol)), decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object], T::Array[T.untyped], T.untyped))).void }
    def initialize(ios_or_readers, schema: nil, decryption: nil); end

    # _@param_ `output_io` — destination, written sequentially; not closed
    # 
    # _@param_ `options` — Writer options for chunks encoded again, and +metadata:+ / +encryption:+ for the output
    sig { params(output_io: T.any(IO, T.untyped), options: T::Hash[Symbol, Object]).returns(Report) }
    def apply(output_io, **options); end

    # Readers with the combiner's own options. A Reader given as input lends its IO and its
    # decryption, but not its +keys:+ or +time_zone:+, which would change the values encoded again.
    # 
    # _@param_ `ios_or_readers` — the inputs
    # 
    # _@param_ `decryption` — keys for the inputs given as IOs
    sig { params(ios_or_readers: T::Enumerable[T.any(IO, StringIO, Reader)], decryption: T.nilable(Object)).returns(T::Array[Reader]) }
    def open_readers(ios_or_readers, decryption); end

    # _@param_ `schema` — the +schema:+ option
    # 
    # _@param_ `readers` — the inputs
    sig { params(schema: T.nilable(T.any(Schema, Symbol)), readers: T::Array[Reader]).returns(Schema) }
    def output_schema(schema, readers); end

    # Each field of +mine+ with the field of the same name in +theirs+ (nil when there is none),
    # then the same for their members down through structs, lists and maps
    # 
    # _@param_ `mine` — the schema walked
    # 
    # _@param_ `theirs` — the schema its fields are looked up in
    # 
    # _@return_ — field, twin and dotted path
    sig { params(mine: Schema, theirs: Schema).returns(T::Array[[Schema::Field, Schema::Field, String]]) }
    def pairs(mine, theirs); end

    # Where the fields of +theirs+ differ from those of +mine+, recorded as conflicts
    # 
    # _@param_ `mine` — the schema compared with
    # 
    # _@param_ `theirs` — the input's schema
    # 
    # _@param_ `k` — the input's position
    # 
    # _@param_ `other` — what to call +mine+, e.g. "input 0"
    # 
    # _@param_ `skip` — paths not to compare
    sig do
      params(
        mine: Schema,
        theirs: Schema,
        k: Integer,
        other: String,
        skip: T::Array[String]
      ).void
    end
    def differences(mine, theirs, k, other, skip: []); end

    # Fits an input to the output schema, recording the conflicts when it does not fit. The input
    # must be the same as the output or narrower: uniting it with the output (Schema#+) must leave
    # the output as it is. Each output leaf is found in the input through the logical tree, by
    # name, so the element of a pyarrow list ("list.item") or of a legacy 2-level list is still the
    # same column.
    # 
    # _@param_ `reader` — the input
    # 
    # _@param_ `k` — its position
    # 
    # _@param_ `drop` — whether fields the output lacks are dropped (+schema: :intersect+) rather than refused
    sig { params(reader: Reader, k: Integer, drop: T::Boolean).returns(Input) }
    def fit(reader, k, drop); end

    # Whether a chunk of +theirs+ holds the values of +mine+ byte for byte. For a column of an
    # input that fits the output, the widenings that keep the bytes are those of the annotation
    # alone: int8 into int32, uint16 into int32, string into binary... Equal levels mean that no
    # field on the way became nullable, since nullability only ever widens here.
    # 
    # _@param_ `mine` — a column of the output schema
    # 
    # _@param_ `theirs` — the input's column for it
    sig { params(mine: Schema::Column, theirs: Schema::Column).returns(T::Boolean) }
    def same_bytes?(mine, theirs); end

    # _@param_ `node` — a leaf
    # 
    # _@return_ — the unit of a time or timestamp column, nil for other columns
    sig { params(node: Schema::Node).returns(T.nilable(Symbol)) }
    def time_unit(node); end

    # _@param_ `field` — any field
    # 
    # _@return_ — its type as messages name it, see Schema::Merge#describe
    sig { params(field: Schema::Field).returns(String) }
    def describe(field); end

    # _@param_ `path` — path of the field, empty for the input as a whole
    # 
    # _@param_ `left` — the field as the schema compared with has it
    # 
    # _@param_ `right` — the field as the input has it
    # 
    # _@param_ `reason` — why they do not fit
    # 
    # _@param_ `k` — the input's position
    sig do
      params(
        path: T.any(String, T::Array[String]),
        left: T.nilable(String),
        right: T.nilable(String),
        reason: T.nilable(String),
        k: Integer
      ).void
    end
    def conflict(path, left, right, reason, k); end

    # _@param_ `singular` — the verb for one input, e.g. "does"
    # 
    # _@param_ `plural` — the verb for several, e.g. "do"
    # 
    # _@return_ — the inputs with conflicts and the verb: "2 of 5 inputs do", "1 of 5 inputs
    # does", or "The input does" when there is only one
    sig { params(singular: String, plural: String).returns(String) }
    def inputs_count(singular, plural); end

    # Raises the conflicts, grouped by input, as one IncompatibleSchema:
    # 
    #   2 of 3 inputs do not fit the schema (schema:):
    # 
    #     input 1 (2026-02.parquet)
    #       price        double in the schema, string here (no common type)
    #       address.zip  required in the schema, nullable here
    # 
    # _@param_ `header` — the first line
    # 
    # _@param_ `other` — what to call the schema the inputs are compared with, e.g. "the schema"
    # 
    # _@param_ `advice` — a closing paragraph
    sig { params(header: String, other: String, advice: T.nilable(String)).void }
    def raise_conflicts(header, other, advice: nil); end

    # The +encryption:+ option that encrypts the output like the encrypted inputs: the same
    # algorithm, footer mode, footer key and key metadata, AAD prefix, and the same key for each
    # column. Plaintext inputs get that encryption too.
    # 
    # _@return_ — nil when no input is encrypted
    sig { returns(T.nilable(EncryptionConfiguration)) }
    def inherited_encryption; end

    # Writes row group +i+ of +input+, copying the column chunks it can. A field with a column that
    # cannot be copied is read as a whole, since Reader and Writer handle top-level fields; the
    # columns of it that can be copied still are.
    # 
    # _@param_ `input` — the input file
    # 
    # _@param_ `i` — row group index in the input
    # 
    # _@param_ `from` — index of the row group's first row in the input
    # 
    # _@param_ `writer` — the output
    # 
    # _@return_ — +:copied+ or +:rewritten+
    sig do
      params(
        input: Input,
        i: Integer,
        from: Integer,
        writer: Writer
      ).returns(Symbol)
    end
    def write_row_group(input, i, from, writer); end

    # _@return_ — the schema of the output
    sig { returns(Schema) }
    attr_reader :schema

    # What #apply did
    # 
    # @!attribute rows
    #   @return [Integer] rows written
    # @!attribute row_groups
    #   @return [Hash{Symbol => Integer}] +{copied:, rewritten:}+ row group counts: a row group is
    #     rewritten when at least one of its column chunks had to be encoded again
    # @!attribute inputs
    #   @return [Array<InputReport>] how each input was fitted to the output schema, in input order
    # @api public
    class Report < Struct
      # _@return_ — rows written
      sig { returns(Integer) }
      attr_accessor :rows

      # _@return_ — +{copied:, rewritten:}+ row group counts: a row group is
      # rewritten when at least one of its column chunks had to be encoded again
      sig { returns(T::Hash[Symbol, Integer]) }
      attr_accessor :row_groups

      # _@return_ — how each input was fitted to the output schema, in input order
      sig { returns(T::Array[InputReport]) }
      attr_accessor :inputs
    end

    # How one input was fitted to the output schema. Paths are dotted field paths ("address.zip").
    # 
    # @!attribute name
    #   @return [String] "input 2", with the IO's path when it has one: "input 2 (2026-03.parquet)"
    # @!attribute filled
    #   @return [Array<String>] fields the input lacks, written as nulls
    # @!attribute widened
    #   @return [Array<String>] fields the output holds in a wider type, or nullable
    # @!attribute dropped
    #   @return [Array<String>] fields of the input the output does not have (+schema: :intersect+)
    # @api public
    class InputReport < Struct
      # _@return_ — "input 2", with the IO's path when it has one: "input 2 (2026-03.parquet)"
      sig { returns(String) }
      attr_accessor :name

      # _@return_ — fields the input lacks, written as nulls
      sig { returns(T::Array[String]) }
      attr_accessor :filled

      # _@return_ — fields the output holds in a wider type, or nullable
      sig { returns(T::Array[String]) }
      attr_accessor :widened

      # _@return_ — fields of the input the output does not have (+schema: :intersect+)
      sig { returns(T::Array[String]) }
      attr_accessor :dropped
    end

    # One input file: its Reader (with the combiner's own options), its ChunkCopier, output column
    # index => the input's column holding its values (output columns the input lacks are not in
    # it), and its InputReport
    class Input < Struct
      # Returns the value of attribute reader
      sig { returns(Object) }
      attr_accessor :reader

      # Returns the value of attribute copier
      sig { returns(Object) }
      attr_accessor :copier

      # Returns the value of attribute sources
      sig { returns(Object) }
      attr_accessor :sources

      # Returns the value of attribute report
      sig { returns(Object) }
      attr_accessor :report
    end
  end

  # Examines a Parquet file using only its footer, page headers and page indexes. Values are
  # never decompressed or decoded, so this works for files whose codecs are not installed and
  # stays fast for big files (it seeks from page header to page header).
  # 
  #   File.open("data.parquet", "rb") do |io|
  #     inspector = Herringbone::Inspector.new(io)
  #     inspector.summary                        # => { file_size:, num_rows:, codecs:, ... }
  #     inspector.row_groups[0].column("name").pages
  #     inspector.to_h                           # everything, JSON-serializable
  #     puts inspector.report                    # readable text (bin/herringbone inspect)
  #     html = inspector.to_html                 # self-contained HTML page (see Visualizer)
  #   end
  # 
  # Page headers and indexes are read lazily; #load_all reads them all up front, after which the
  # inspector no longer needs the IO. The IO is never closed. After #verify_checksums, page CRC
  # results are included in every output.
  class Inspector
    # +io+ is a random-access IO (responds to #seek and #read, e.g. File.open(path, "rb")). It is
    # left open.
    # 
    # An encrypted file needs +decryption:+ (see Reader.new) when its footer is encrypted. With a
    # plaintext footer it opens without keys, and the chunks whose key is missing are shown
    # without their pages, page indexes and statistics.
    # 
    # _@param_ `io` — random-access IO positioned anywhere; only the footer is read here
    # 
    # _@param_ `decryption` — keys of an encrypted file, see Reader.new
    sig { params(io: IO, decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object]))).void }
    def initialize(io, decryption: nil); end

    # _@return_ — row count declared in the footer
    sig { returns(Integer) }
    def num_rows; end

    # _@return_ — the writer's created_by string, e.g. +"parquet-cpp-arrow version 15.0.0"+
    sig { returns(T.nilable(String)) }
    def created_by; end

    # _@return_ — format version from the footer (1 or 2; says little about the features used)
    sig { returns(Integer) }
    def version; end

    # _@return_ — the schema's leaf columns
    sig { returns(T::Array[Schema::Column]) }
    def columns; end

    # _@return_ — file offset where the Thrift-encoded FileMetaData starts
    sig { returns(Integer) }
    def footer_offset; end

    # _@return_ — the row groups, in footer order (built on first use)
    sig { returns(T::Array[RowGroupInfo]) }
    def row_groups; end

    # _@return_ — the column chunks of all row groups, row group by row group
    sig { returns(T::Array[ColumnChunkInfo]) }
    def column_chunks; end

    # Walks every page header and page index now (e.g. before closing the file)
    # 
    # _@return_ — self
    sig { returns(Inspector) }
    def load_all; end

    # _@return_ — whether any column chunk has a ColumnIndex or an OffsetIndex
    sig { returns(T::Boolean) }
    def page_index?; end

    # _@return_ — whether any column chunk has a bloom filter
    sig { returns(T::Boolean) }
    def bloom_filters?; end

    # How the file is encrypted (see Reader#encryption), nil for a file that is not
    # 
    # _@return_ — +:algorithm+, +:footer+, +:footer_key_metadata+,
    # +:aad_prefix+, +:supply_aad_prefix+, +:footer_verified+ and +:columns+ (path => { key:,
    # key_metadata:, readable: } for the encrypted columns of the first row group)
    sig { returns(T.nilable(T::Hash[Symbol, Object])) }
    def encryption; end

    # The file-level key/value metadata, each entry described: ARROW:schema is decoded, JSON
    # values are parsed (pandas metadata summarized), binary values are shown as hex
    # 
    # _@return_ — each with :key, :bytesize, :format ("arrow_schema",
    # "json", "text" or "binary"), :value (truncated) and, depending on the format, :summary,
    # :json, :arrow_schema, :arrow_fields, :arrow_error
    sig { returns(T::Array[T::Hash[Symbol, Object]]) }
    def key_value_metadata; end

    # _@return_ — "TYPE_DEFINED_ORDER" or "UNKNOWN" per leaf column; nil when the
    # footer has no column_orders
    sig { returns(T.nilable(T::Array[String])) }
    def column_orders; end

    # File-wide facts: sizes, row and column counts, codecs, whether page indexes and bloom
    # filters are present, and (after #verify_checksums) the CRC tallies under :checksums.
    # Walks no page headers.
    sig { returns(T::Hash[Symbol, Object]) }
    def summary; end

    # Reads every page body and checks it against the CRC32 in its page header (the CRC covers
    # the page data as stored: compressed, and for v2 pages the levels plus the compressed
    # values). Nothing is decompressed. Sets PageInfo#checksum on every page and returns
    # #checksum_summary. Needs the IO, so call it before closing the file.
    # 
    # _@return_ — see #checksum_summary
    sig { returns(T::Hash[Symbol, Object]) }
    def verify_checksums; end

    # _@return_ — whether #verify_checksums has run
    sig { returns(T::Boolean) }
    def checksums_verified?; end

    # After #verify_checksums: { ok:, mismatch:, absent:, mismatches: [{ row_group:, column:, page:, type:, offset:, crc:, actual: }] }
    # The counts are pages per status; in each mismatch +crc+ is the CRC from the page header and
    # +actual+ the CRC32 of the stored bytes (kept from the verification, so the IO is not needed).
    # 
    # _@return_ — nil before #verify_checksums
    sig { returns(T.nilable(T::Hash[Symbol, Object])) }
    def checksum_summary; end

    # Every disagreement between page header statistics and the ColumnIndex, across the file,
    # each with :row_group and :column added (see ColumnChunkInfo#index_mismatches)
    sig { returns(T::Array[T::Hash[Symbol, Object]]) }
    def index_mismatches; end

    # The decoded ARROW:schema key/value (see ArrowSchema.decode); nil when the file has none or
    # it could not be decoded, and #arrow_schema_error then says why
    # 
    # _@return_ — see ArrowSchema.decode
    sig { returns(T.nilable(T::Hash[Symbol, Object])) }
    def arrow_schema; end

    # _@return_ — why the ARROW:schema value could not be decoded; nil when it decoded
    # fine or the file has none
    sig { returns(T.nilable(String)) }
    def arrow_schema_error; end

    # Schema tree: Hashes with name, repetition, types, levels (leaves) and children (groups)
    # Nodes that match a field of the ARROW:schema also get its type as :arrow_type.
    # 
    # _@return_ — the root's children
    sig { returns(T::Array[T::Hash[Symbol, Object]]) }
    def schema_tree; end

    # Per leaf column: sums over all row groups, plus overall min/max where comparable
    # Walks every page header (for the page counts).
    # 
    # _@return_ — one per leaf column, in schema order
    sig { returns(T::Array[T::Hash[Symbol, Object]]) }
    def column_totals; end

    # Byte ranges of the whole file, in offset order: magic, pages (or whole chunks when their pages
    # could not be walked), bloom filters, page indexes, footer. Gaps right after a chunk at its
    # file_offset are inline :column_metadata copies; other gaps are reported as :unknown. Each entry: { kind:, start:, length:, row_group:, column:, page: }
    # +row_group+, +column+ and +page+ are indexes, present only where they apply. Segments can
    # overlap when the file is damaged; gaps are only computed past the furthest end seen so far.
    sig { returns(T::Array[T::Hash[Symbol, Object]]) }
    def layout; end

    # Everything: summary, key/value metadata, schema tree, row groups with their chunks and
    # pages, column totals, and any checksum and page index mismatches. Walks every page header.
    # 
    # _@return_ — JSON-safe; keys without a value are left out
    sig { returns(T::Hash[Symbol, Object]) }
    def to_h; end

    # _@param_ `args` — passed on to Hash#to_json (e.g. a JSON::State)
    # 
    # _@return_ — #to_h as JSON
    sig { params(args: T::Array[T.untyped]).returns(String) }
    def to_json(*args); end

    # A self-contained HTML page showing the file's layout, see Visualizer
    # 
    # _@return_ — HTML document
    sig { returns(String) }
    def to_html; end

    # Readable text summary. With pages: true, lists every page header too.
    # 
    # _@param_ `pages` — whether to add a line per page header under each column chunk
    # 
    # _@return_ — multi-line text, as printed by +bin/herringbone inspect+
    sig { params(pages: T::Boolean).returns(String) }
    def report(pages: false); end

    # _@return_ — short description: name, rows, row group count and file size
    sig { returns(String) }
    def inspect; end

    # Decryption of an encrypted chunk's modules
    # 
    # _@param_ `chunk` — an encrypted chunk
    # 
    # _@return_ — nil when the chunk's key was not given
    sig { params(chunk: ColumnChunkInfo).returns(T.nilable(Encryption::ModuleCrypto)) }
    def chunk_crypto(chunk); end

    # Walks page headers from the chunk's first page. Returns [pages, error_message_or_nil].
    # Mirrors the reader's tolerance: a chunk may extend past its declared total_compressed_size.
    # 
    # _@param_ `chunk` — chunk whose pages to walk
    # 
    # _@return_ — the pages found, and why
    # the walk stopped early (nil when every value was accounted for)
    sig { params(chunk: ColumnChunkInfo).returns(T.any([T::Array[PageInfo], String], [T::Array[PageInfo], NilClass])) }
    def walk_pages(chunk); end

    # Reads and decodes a chunk's ColumnIndex, decoding the per-page min/max with the column type
    # 
    # _@param_ `chunk` — chunk whose ColumnIndex to read
    # 
    # _@return_ — nil when the chunk has none or it fails to decode
    sig { params(chunk: ColumnChunkInfo).returns(T.nilable(ColumnIndexInfo)) }
    def read_column_index(chunk); end

    # Reads and decodes a chunk's OffsetIndex
    # 
    # _@param_ `chunk` — chunk whose OffsetIndex to read
    # 
    # _@return_ — nil when the chunk has none or it fails to decode
    sig { params(chunk: ColumnChunkInfo).returns(T.nilable(OffsetIndexInfo)) }
    def read_offset_index(chunk); end

    # Size in bytes of the bloom filter at +offset+ (its Thrift header plus the bitset). An
    # encrypted filter is two modules, whose lengths are stored in the clear.
    # 
    # _@param_ `offset` — file offset of the BloomFilterHeader
    # 
    # _@param_ `encrypted` — whether the filter is encrypted
    # 
    # _@return_ — nil when the header can't be decoded or has no num_bytes
    sig { params(offset: Integer, encrypted: T::Boolean).returns(T.nilable(Integer)) }
    def bloom_filter_size(offset, encrypted = false); end

    # :ok, :mismatch or :absent for one page (reads its body). Sets PageInfo#actual_crc.
    # 
    # _@param_ `page` — page to check
    sig { params(page: PageInfo).returns(Symbol) }
    def page_checksum(page); end

    # CRC32 of a page's body as stored
    # 
    # _@param_ `page` — page whose compressed body to read
    # 
    # _@return_ — unsigned 32-bit CRC
    sig { params(page: PageInfo).returns(Integer) }
    def page_crc(page); end

    # See ColumnChunkInfo#index_mismatches
    # 
    # _@param_ `chunk` — chunk whose page headers to compare with its ColumnIndex
    # 
    # _@return_ — one entry per disagreement; a single :page_count
    # entry when the ColumnIndex and the data pages differ in number
    sig { params(chunk: ColumnChunkInfo).returns(T::Array[T::Hash[Symbol, Object]]) }
    def compare_page_index(chunk); end

    # Decodes a Format::Statistics into Ruby values via the column's type converter
    # Prefers min_value/max_value; falls back to the deprecated min/max, with a caveat when their
    # ordering can't be trusted for the column's type.
    # 
    # _@param_ `st` — statistics from column metadata or a page header
    # 
    # _@param_ `column` — column the statistics describe
    # 
    # _@return_ — nil when +st+ is nil
    sig { params(st: T.nilable(Format::Statistics), column: Schema::Column).returns(T.nilable(Stats)) }
    def decode_statistics(st, column); end

    # Decodes one PLAIN-encoded statistics value (no length prefix for byte arrays)
    # INT96 decodes to [nanoseconds, julian_day] before conversion. Values of the wrong width,
    # or that fail to convert, come back as hex (see Inspector.hex).
    # 
    # _@param_ `bytes` — encoded value
    # 
    # _@param_ `column` — column whose physical type and converter apply
    # 
    # _@return_ — the converted value, a hex String when it could not be decoded, nil
    # for nil (or empty BOOLEAN) input
    sig { params(bytes: T.nilable(String), column: Schema::Column).returns(T.nilable(Object)) }
    def decode_value(bytes, column); end

    # _@param_ `e` — Parquet Encoding value
    # 
    # _@return_ — its name, e.g. "RLE_DICTIONARY" (the number as a String when unknown)
    sig { params(e: Integer).returns(String) }
    def self.encoding_name(e); end

    # _@param_ `column` — leaf column
    # 
    # _@return_ — physical type with its logical annotation, e.g. "BYTE_ARRAY STRING" or
    # "FIXED_LEN_BYTE_ARRAY(16) UUID"
    sig { params(column: Schema::Column).returns(String) }
    def self.type_name(column); end

    # The node's LogicalType, else its ConvertedType, as text
    # 
    # _@param_ `node` — schema node (leaf or group)
    # 
    # _@return_ — e.g. "INTEGER(8, unsigned)", "TIMESTAMP(MICROS, UTC)" or "DECIMAL(10, 2)";
    # nil when the node has no annotation
    sig { params(node: Schema::Node).returns(T.nilable(String)) }
    def self.logical_type_name(node); end

    # :signed, :unsigned or :unknown, per the Parquet sort order rules for the column's type
    # 
    # _@param_ `column` — leaf column
    sig { params(column: Schema::Column).returns(Symbol) }
    def self.sort_order(column); end

    # Converts Ruby values (Time, BigDecimal, binary Strings, non-finite Floats...) to JSON-safe ones
    # Recurses into Hashes, Arrays and Structs; Hash keys other than Symbols become Strings.
    # 
    # _@param_ `v` — value to convert
    sig { params(v: Object).returns(T.nilable(T.any(T::Hash[T.untyped, T.untyped], T::Array[T.untyped], String, Integer, Float, T::Boolean))) }
    def self.jsonable(v); end

    # A String as readable text when it is valid UTF-8 without control characters, else as hex
    # Strings already tagged as valid UTF-8 are returned as they are, control characters and all.
    # 
    # _@param_ `s` — string in any encoding
    sig { params(s: String).returns(String) }
    def self.text(s); end

    # _@param_ `bytes` — bytes to show
    # 
    # _@return_ — "0x" and lowercase hex digits; only the first 64 bytes, followed by the
    # total size, for longer input
    sig { params(bytes: String).returns(String) }
    def self.hex(bytes); end

    # A short display form of a decoded value
    # Strings are quoted (binary ones go through Inspector.text first), nil shows as "null".
    # 
    # _@param_ `v` — decoded value
    # 
    # _@param_ `max` — longest result, in characters; longer ones are cut and end in an ellipsis
    sig { params(v: Object, max: Integer).returns(String) }
    def self.display(v, max: 40); end

    # _@param_ `n` — byte count
    # 
    # _@return_ — e.g. "512 B", "1.50 KB" or "12.3 MB" (binary units); "?" for nil
    sig { params(n: T.nilable(Integer)).returns(String) }
    def self.human_bytes(n); end

    # _@param_ `uncompressed` — uncompressed byte count
    # 
    # _@param_ `compressed` — compressed byte count
    # 
    # _@return_ — " (3.21x)" for #report, empty when the ratio is unknown
    sig { params(uncompressed: T.nilable(Integer), compressed: T.nilable(Integer)).returns(String) }
    def ratio_text(uncompressed, compressed); end

    # _@param_ `page` — page whose CRC status to show
    # 
    # _@return_ — the status for a #report page line: " crc ok", " CRC MISMATCH", " crc"
    # (has a CRC, not verified) or empty
    sig { params(page: PageInfo).returns(String) }
    def crc_text(page); end

    # _@param_ `m` — an entry of #index_mismatches
    # 
    # _@return_ — one #report line describing it
    sig { params(m: T::Hash[Symbol, Object]).returns(String) }
    def index_mismatch_text(m); end

    # Adds :arrow_type to schema nodes with a same-named Arrow field (top level, and struct members)
    # 
    # _@param_ `nodes` — #schema_tree nodes, updated in place
    # 
    # _@param_ `fields` — Arrow fields at the same level
    # 
    # _@param_ `depth` — nesting depth; recursion stops at 32
    sig { params(nodes: T::Array[T::Hash[Symbol, Object]], fields: T::Array[T::Hash[Symbol, Object]], depth: Integer).void }
    def annotate_arrow_types(nodes, fields, depth = 0); end

    # Whether the index bound +idx+ excludes values the page's bound +page+ says are present
    # (index min above the page min, or index max below the page max). Truncated binary bounds
    # (one a prefix of the other) and values that can't be compared are never reported.
    # 
    # _@param_ `idx` — decoded ColumnIndex bound
    # 
    # _@param_ `page` — decoded page header bound
    # 
    # _@param_ `order` — :signed, :unsigned or :unknown (see Inspector.sort_order)
    # 
    # _@param_ `which` — :min or :max
    sig do
      params(
        idx: T.nilable(Object),
        page: T.nilable(Object),
        order: Symbol,
        which: Symbol
      ).returns(T::Boolean)
    end
    def narrower?(idx, page, order, which); end

    # Overall min or max of per-chunk bounds, when they can be compared
    # 
    # _@param_ `values` — decoded per-chunk minimums or maximums
    # 
    # _@param_ `which` — :min or :max
    # 
    # _@return_ — nil when there are no values or they are of mixed or incomparable types
    sig { params(values: T::Array[T.nilable(Object)], which: Symbol).returns(T.nilable(Object)) }
    def safe_extreme(values, which); end

    # Reads the file size, the footer length and magic, and decodes the FileMetaData into @metadata
    # (decrypting it, or checking its signature, in an encrypted file)
    sig { void }
    def read_footer; end

    # Reads +len+ bytes at +pos+ through a small read-ahead window, so walking many small pages
    # does not cost a syscall per header
    # 
    # _@param_ `pos` — file offset
    # 
    # _@param_ `len` — bytes wanted
    # 
    # _@return_ — binary String; shorter than +len+ at the end of the file
    sig { params(pos: Integer, len: Integer).returns(String) }
    def read_at(pos, len); end

    # A module of an encrypted chunk, decrypted
    # 
    # _@param_ `chunk` — the chunk the module belongs to
    # 
    # _@param_ `offset` — file offset of the module
    # 
    # _@param_ `length` — its length, length prefix included
    # 
    # _@param_ `type` — module type
    # 
    # _@return_ — the plaintext (the bytes as stored for a plaintext chunk), nil when the
    # chunk's key was not given
    sig do
      params(
        chunk: ColumnChunkInfo,
        offset: Integer,
        length: Integer,
        type: Integer
      ).returns(T.nilable(String))
    end
    def read_module(chunk, offset, length, type); end

    # Decrypts and decodes the encrypted page header at +pos+. Its AAD depends on whether it is the
    # dictionary page's (the first page, when the chunk has a dictionary) and on the number of
    # data pages before it.
    # 
    # _@param_ `chunk` — the chunk, whose key is available
    # 
    # _@param_ `pos` — file offset of the header module
    # 
    # _@param_ `limit` — offset the header must not extend past (the footer's start)
    # 
    # _@param_ `pages` — the chunk's pages before this one
    # 
    # _@return_ — the header and the module's size in bytes
    sig do
      params(
        chunk: ColumnChunkInfo,
        pos: Integer,
        limit: Integer,
        pages: T::Array[PageInfo]
      ).returns([Format::PageHeader, Integer])
    end
    def read_encrypted_page_header(chunk, pos, limit, pages); end

    # Decodes the page header at +pos+, reading more bytes when it is larger than the first guess
    # (page statistics of long strings can make headers big)
    # 
    # _@param_ `pos` — file offset of the header
    # 
    # _@param_ `limit` — offset the header must not extend past (the footer's start)
    # 
    # _@return_ — the header and its encoded size in bytes
    sig { params(pos: Integer, limit: Integer).returns([Format::PageHeader, Integer]) }
    def read_page_header(pos, limit); end

    # Builds a PageInfo from a decoded page header
    # 
    # _@param_ `index` — position of the page in its chunk
    # 
    # _@param_ `h` — decoded header
    # 
    # _@param_ `pos` — file offset of the header
    # 
    # _@param_ `header_size` — encoded size of the header in bytes
    # 
    # _@param_ `column` — column the page belongs to (for statistics and row counts)
    sig do
      params(
        index: Integer,
        h: Format::PageHeader,
        pos: Integer,
        header_size: Integer,
        column: Schema::Column
      ).returns(PageInfo)
    end
    def page_info(index, h, pos, header_size, column); end

    # One #key_value_metadata entry
    # 
    # _@param_ `key` — metadata key
    # 
    # _@param_ `value` — metadata value
    # 
    # _@return_ — see #key_value_metadata
    sig { params(key: String, value: T.nilable(String)).returns(T::Hash[Symbol, Object]) }
    def describe_key_value(key, value); end

    # _@param_ `json` — the parsed "pandas" metadata value
    # 
    # _@return_ — e.g. "pandas 2.2.0 metadata, 3 columns"
    sig { params(json: Object).returns(String) }
    def pandas_summary(json); end

    # Field names from an Arrow IPC schema message, found by scanning for its flatbuffer strings.
    # Best effort: only used to label the blob, nil when nothing sensible is found.
    # Only top-level Parquet column names that occur in the decoded bytes are reported.
    # 
    # _@param_ `b64` — the base64 ARROW:schema value
    sig { params(b64: String).returns(T.nilable(T::Array[String])) }
    def arrow_field_names(b64); end

    # Returns the value of attribute metadata.
    sig { returns(T.untyped) }
    attr_reader :metadata

    # Returns the value of attribute schema.
    sig { returns(T.untyped) }
    attr_reader :schema

    # Returns the value of attribute file_size.
    sig { returns(T.untyped) }
    attr_reader :file_size

    # Returns the value of attribute footer_size.
    sig { returns(T.untyped) }
    attr_reader :footer_size

    # A label for the file (the basename of the IO's path, when it has one)
    sig { returns(T.untyped) }
    attr_reader :name

    # Just enough of parquet.thrift's BloomFilterHeader to learn the filter's size
    # 
    # @api private
    class BloomFilterHeader < Herringbone::Thrift::Struct
    end

    # Decoded min/max statistics (from a column chunk, a page header or a page index entry).
    # +min+/+max+ are converted with the column's type converter (hex Strings when they could
    # not be decoded); +min_exact+/+max_exact+ mirror is_min_value_exact/is_max_value_exact;
    # +source+ says which Thrift fields they came from and +caveat+ why they may be unreliable.
    class Stats < Struct
      # _@return_ — the set members, JSON-safe (see Inspector.jsonable)
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # Returns the value of attribute min
      sig { returns(Object) }
      attr_accessor :min

      # Returns the value of attribute max
      sig { returns(Object) }
      attr_accessor :max

      # Returns the value of attribute null_count
      sig { returns(Object) }
      attr_accessor :null_count

      # Returns the value of attribute distinct_count
      sig { returns(Object) }
      attr_accessor :distinct_count

      # Returns the value of attribute min_exact
      sig { returns(Object) }
      attr_accessor :min_exact

      # Returns the value of attribute max_exact
      sig { returns(Object) }
      attr_accessor :max_exact

      # Returns the value of attribute source
      sig { returns(Object) }
      attr_accessor :source

      # Returns the value of attribute caveat
      sig { returns(Object) }
      attr_accessor :caveat
    end

    # One page header of a column chunk. +checksum+ is nil until the CRCs are verified
    # (Inspector#verify_checksums), then :ok, :mismatch or :absent (the page has no CRC);
    # +actual_crc+ is then the CRC32 of the page's stored bytes (nil when it has no CRC).
    # +index+ is the page's position in the chunk, +offset+ where its header starts; +type+ is
    # a PageType name such as :DATA_PAGE (the raw Integer when unknown). +first_row_index+ and,
    # for v1 pages of repeated columns, +num_rows+ are only known from the OffsetIndex.
    class PageInfo < Struct
      # _@return_ — bytes taken by the page in the file: header plus compressed body
      sig { returns(Integer) }
      def total_size; end

      # _@return_ — file offset just past the page's body
      sig { returns(Integer) }
      def end_offset; end

      # _@return_ — file offset where the page's body (after the header) starts
      sig { returns(Integer) }
      def body_offset; end

      # _@return_ — whether this is a dictionary page
      sig { returns(T::Boolean) }
      def dictionary?; end

      # _@return_ — whether this is a v1 or v2 data page
      sig { returns(T::Boolean) }
      def data?; end

      # The CRC from the header as an unsigned 32-bit value (Thrift stores it as a signed i32)
      # 
      # _@return_ — nil when the header has no CRC
      sig { returns(T.nilable(Integer)) }
      def expected_crc; end

      # _@return_ — the set members, JSON-safe; +:crc+ becomes a Boolean
      # saying whether the header has a CRC, +:actual_crc+ is left out
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # Returns the value of attribute index
      sig { returns(Object) }
      attr_accessor :index

      # Returns the value of attribute type
      sig { returns(Object) }
      attr_accessor :type

      # Returns the value of attribute offset
      sig { returns(Object) }
      attr_accessor :offset

      # Returns the value of attribute header_size
      sig { returns(Object) }
      attr_accessor :header_size

      # Returns the value of attribute compressed_size
      sig { returns(Object) }
      attr_accessor :compressed_size

      # Returns the value of attribute uncompressed_size
      sig { returns(Object) }
      attr_accessor :uncompressed_size

      # Returns the value of attribute num_values
      sig { returns(Object) }
      attr_accessor :num_values

      # Returns the value of attribute num_nulls
      sig { returns(Object) }
      attr_accessor :num_nulls

      # Returns the value of attribute num_rows
      sig { returns(Object) }
      attr_accessor :num_rows

      # Returns the value of attribute first_row_index
      sig { returns(Object) }
      attr_accessor :first_row_index

      # Returns the value of attribute encoding
      sig { returns(Object) }
      attr_accessor :encoding

      # Returns the value of attribute definition_level_encoding
      sig { returns(Object) }
      attr_accessor :definition_level_encoding

      # Returns the value of attribute repetition_level_encoding
      sig { returns(Object) }
      attr_accessor :repetition_level_encoding

      # Returns the value of attribute definition_levels_byte_length
      sig { returns(Object) }
      attr_accessor :definition_levels_byte_length

      # Returns the value of attribute repetition_levels_byte_length
      sig { returns(Object) }
      attr_accessor :repetition_levels_byte_length

      # Returns the value of attribute is_compressed
      sig { returns(Object) }
      attr_accessor :is_compressed

      # Returns the value of attribute is_sorted
      sig { returns(Object) }
      attr_accessor :is_sorted

      # Returns the value of attribute statistics
      sig { returns(Object) }
      attr_accessor :statistics

      # Returns the value of attribute crc
      sig { returns(Object) }
      attr_accessor :crc

      # Returns the value of attribute checksum
      sig { returns(Object) }
      attr_accessor :checksum

      # Returns the value of attribute actual_crc
      sig { returns(Object) }
      attr_accessor :actual_crc
    end

    # ColumnIndex of one column chunk, with min/max decoded per page (nil for all-null pages)
    class ColumnIndexInfo < Struct
      # _@return_ — the set members, JSON-safe (see Inspector.jsonable)
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # Returns the value of attribute offset
      sig { returns(Object) }
      attr_accessor :offset

      # Returns the value of attribute length
      sig { returns(Object) }
      attr_accessor :length

      # Returns the value of attribute null_pages
      sig { returns(Object) }
      attr_accessor :null_pages

      # Returns the value of attribute min_values
      sig { returns(Object) }
      attr_accessor :min_values

      # Returns the value of attribute max_values
      sig { returns(Object) }
      attr_accessor :max_values

      # Returns the value of attribute boundary_order
      sig { returns(Object) }
      attr_accessor :boundary_order

      # Returns the value of attribute null_counts
      sig { returns(Object) }
      attr_accessor :null_counts

      # Returns the value of attribute repetition_level_histograms
      sig { returns(Object) }
      attr_accessor :repetition_level_histograms

      # Returns the value of attribute definition_level_histograms
      sig { returns(Object) }
      attr_accessor :definition_level_histograms
    end

    # One OffsetIndex entry: where a data page starts, its size (header included) and the index
    # of its first row within the row group
    class PageLocation < Struct
      # Returns the value of attribute offset
      sig { returns(Object) }
      attr_accessor :offset

      # Returns the value of attribute compressed_page_size
      sig { returns(Object) }
      attr_accessor :compressed_page_size

      # Returns the value of attribute first_row_index
      sig { returns(Object) }
      attr_accessor :first_row_index
    end

    # OffsetIndex of one column chunk: its own +offset+/+length+ in the file, the PageLocations
    # of its data pages and the optional per-page unencoded BYTE_ARRAY sizes
    class OffsetIndexInfo < Struct
      # _@return_ — the set members, with +:page_locations+ as Hashes
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # Returns the value of attribute offset
      sig { returns(Object) }
      attr_accessor :offset

      # Returns the value of attribute length
      sig { returns(Object) }
      attr_accessor :length

      # Returns the value of attribute page_locations
      sig { returns(Object) }
      attr_accessor :page_locations

      # Returns the value of attribute unencoded_byte_array_data_bytes
      sig { returns(Object) }
      attr_accessor :unencoded_byte_array_data_bytes
    end

    # One column chunk of a row group
    class ColumnChunkInfo
      # _@param_ `inspector` — owner, used to read page headers and indexes lazily
      # 
      # _@param_ `row_group` — row group the chunk belongs to
      # 
      # _@param_ `column` — leaf column the chunk stores
      # 
      # _@param_ `chunk` — chunk as decoded from the footer
      sig do
        params(
          inspector: Inspector,
          row_group: RowGroupInfo,
          column: Schema::Column,
          chunk: Format::ColumnChunk
        ).void
      end
      def initialize(inspector, row_group, column, chunk); end

      # _@return_ — whether the chunk is encrypted
      sig { returns(T::Boolean) }
      def encrypted?; end

      # Decryption of the chunk's modules (memoized)
      # 
      # _@return_ — nil when the chunk is not encrypted or its key was
      # not given
      sig { returns(T.nilable(Encryption::ModuleCrypto)) }
      def crypto; end

      # How the chunk is encrypted, without its key
      # 
      # _@return_ — { key: :footer or :column, key_metadata:, readable: },
      # nil for a plaintext chunk
      sig { returns(T.nilable(T::Hash[Symbol, Object])) }
      def encryption; end

      # _@return_ — dotted path of the column, e.g. +"address.city"+
      sig { returns(String) }
      def path; end

      # _@return_ — position of the column among the schema's leaf columns
      sig { returns(Integer) }
      def column_index_number; end

      # _@return_ — codec name such as :SNAPPY (the raw Integer when unknown)
      sig { returns(T.any(Symbol, Integer)) }
      def codec; end

      # _@return_ — encoding names listed in the column metadata
      sig { returns(T::Array[String]) }
      def encodings; end

      # _@return_ — values in the chunk, nulls and repeated entries included
      sig { returns(Integer) }
      def num_values; end

      # _@return_ — total_compressed_size from the column metadata (page headers included)
      sig { returns(Integer) }
      def compressed_size; end

      # _@return_ — total_uncompressed_size from the column metadata (page headers included)
      sig { returns(Integer) }
      def uncompressed_size; end

      # _@return_ — offset of the first data page, as declared in the column metadata
      sig { returns(Integer) }
      def data_page_offset; end

      # _@return_ — path of the file holding the chunk when it is not stored in this one
      sig { returns(T.nilable(String)) }
      def external_file; end

      # _@return_ — uncompressed size divided by compressed size; nil when nothing is compressed
      sig { returns(T.nilable(Float)) }
      def compression_ratio; end

      # Some writers store 0 when there is no dictionary page, and some store a data_page_offset
      # of 0 for empty chunks (which would point at the magic bytes)
      # 
      # _@return_ — the declared dictionary page offset, nil when absent or implausible
      sig { returns(T.nilable(Integer)) }
      def dictionary_page_offset; end

      # Where the chunk's first page starts
      # 
      # _@return_ — file offset; nil when the chunk's metadata is encrypted and its key
      # was not given
      sig { returns(T.nilable(Integer)) }
      def start_offset; end

      # The end according to the metadata; some writers under-report it (see #end_offset)
      # 
      # _@return_ — file offset just past the chunk; nil when it is not known
      sig { returns(T.nilable(Integer)) }
      def declared_end_offset; end

      # The end of the last page actually found (the declared end if the pages could not be walked)
      # 
      # _@return_ — file offset just past the chunk, never before #declared_end_offset
      sig { returns(T.nilable(Integer)) }
      def end_offset; end

      # Page counts per page type and encoding, from the column metadata's encoding_stats
      # 
      # _@return_ — each { page_type:, encoding:, count: }; empty when
      # the writer stored none
      sig { returns(T::Array[T::Hash[Symbol, Object]]) }
      def encoding_stats; end

      # Chunk-level statistics from the column metadata, decoded (memoized)
      # 
      # _@return_ — nil when the chunk has no statistics
      sig { returns(T.nilable(Stats)) }
      def statistics; end

      # _@return_ — the SizeStatistics (unencoded byte array sizes and
      # level histograms) as a Hash, nil when absent
      sig { returns(T.nilable(T::Hash[Symbol, Object])) }
      def size_statistics; end

      # _@return_ — the chunk's own key/value metadata (rarely used by writers)
      sig { returns(T::Hash[String, String]) }
      def key_value_metadata; end

      # _@return_ — file offset of the chunk's bloom filter, nil when it has none
      sig { returns(T.nilable(Integer)) }
      def bloom_filter_offset; end

      # Bytes taken by the bloom filter (header + bitset); read from its header when the footer has no length
      # 
      # _@return_ — nil when there is no bloom filter or its header can't be decoded
      sig { returns(T.nilable(Integer)) }
      def bloom_filter_length; end

      # _@return_ — [offset, length] of the chunk's ColumnIndex, nil when
      # it has none
      sig { returns(T.nilable([Integer, Integer])) }
      def column_index_range; end

      # _@return_ — [offset, length] of the chunk's OffsetIndex, nil when
      # it has none
      sig { returns(T.nilable([Integer, Integer])) }
      def offset_index_range; end

      # All page headers, in file order. Errors while walking (corrupt or truncated headers) end
      # the walk; #error then says what went wrong and #pages holds the pages found before it.
      sig { returns(T::Array[PageInfo]) }
      def pages; end

      # _@return_ — the v1 and v2 data pages, in file order
      sig { returns(T::Array[PageInfo]) }
      def data_pages; end

      # _@return_ — the dictionary page, nil when the chunk has none
      sig { returns(T.nilable(PageInfo)) }
      def dictionary_page; end

      # Number of entries in the dictionary (from its page header)
      # 
      # _@return_ — nil when the chunk has no dictionary page
      sig { returns(T.nilable(Integer)) }
      def dictionary_size; end

      # The chunk's ColumnIndex, read and decoded on first use
      # 
      # _@return_ — nil when there is none or it is corrupt
      sig { returns(T.nilable(ColumnIndexInfo)) }
      def column_index; end

      # The chunk's OffsetIndex, read and decoded on first use
      # 
      # _@return_ — nil when there is none or it is corrupt
      sig { returns(T.nilable(OffsetIndexInfo)) }
      def offset_index; end

      # Null count from the chunk statistics, else the sum over the data page headers
      # 
      # _@return_ — nil when neither the statistics nor every data page has it, or the
      # chunk is encrypted and its key was not given
      sig { returns(T.nilable(Integer)) }
      def null_count; end

      # Reads every page body (compressed bytes, as stored) and checks it against the CRC in its
      # page header. Sets PageInfo#checksum on each page and returns the pages' statuses.
      # 
      # _@return_ — :ok, :mismatch or :absent per page, in #pages order
      sig { returns(T::Array[Symbol]) }
      def verify_checksums; end

      # Page statistics (from page headers) that disagree with the ColumnIndex entry for the
      # same page. Each: { page:, data_page:, field:, page_value:, index_value: } where +page+
      # is the page's position in #pages, +data_page+ its position among the data pages (and
      # in the ColumnIndex), +field+ one of :min, :max, :null_count, :null_page, :page_count.
      # A ColumnIndex bound that is wider than the page's (e.g. a truncated string prefix) is
      # allowed; one that is narrower, or a differing null count, is reported. Empty when the
      # chunk has no ColumnIndex or its pages carry no statistics.
      sig { returns(T::Array[T::Hash[Symbol, Object]]) }
      def index_mismatches; end

      # Everything known about the chunk, including its pages and page indexes (reads them if
      # they were not read yet)
      # 
      # _@return_ — JSON-safe; keys without a value are left out
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # _@return_ — short description: path, row group, codec and sizes
      sig { returns(String) }
      def inspect; end

      # Page row counts come from the offset index when there is one (v1 pages don't carry them)
      # Sets +first_row_index+ on the data pages the index points at, and +num_rows+ where the
      # page header did not provide it.
      # 
      # _@param_ `list` — pages of this chunk, updated in place
      sig { params(list: T::Array[PageInfo]).void }
      def apply_offset_index(list); end

      # Returns the value of attribute inspector.
      sig { returns(T.untyped) }
      attr_reader :inspector

      # Returns the value of attribute row_group.
      sig { returns(T.untyped) }
      attr_reader :row_group

      # Returns the value of attribute column.
      sig { returns(T.untyped) }
      attr_reader :column

      # Returns the value of attribute chunk.
      sig { returns(T.untyped) }
      attr_reader :chunk

      # Returns the value of attribute meta.
      sig { returns(T.untyped) }
      attr_reader :meta

      # Returns the value of attribute error.
      sig { returns(T.untyped) }
      attr_reader :error
    end

    # One row group
    class RowGroupInfo
      # _@param_ `inspector` — owner, passed on to the column chunks
      # 
      # _@param_ `index` — position of the row group in the file
      # 
      # _@param_ `row_group` — row group as decoded from the footer
      # 
      # _@param_ `first_row` — file-wide index of the row group's first row
      sig do
        params(
          inspector: Inspector,
          index: Integer,
          row_group: Format::RowGroup,
          first_row: Integer
        ).void
      end
      def initialize(inspector, index, row_group, first_row); end

      # _@return_ — rows in the row group
      sig { returns(Integer) }
      def num_rows; end

      # _@return_ — total_byte_size from the footer (uncompressed size of all column data)
      sig { returns(Integer) }
      def total_byte_size; end

      # _@return_ — total_compressed_size from the footer, else the sum over the chunks
      sig { returns(Integer) }
      def compressed_size; end

      # _@return_ — sum of the chunks' total_uncompressed_size
      sig { returns(Integer) }
      def uncompressed_size; end

      # _@return_ — lowest start offset of the row group's chunks; nil without chunks
      sig { returns(T.nilable(Integer)) }
      def start_offset; end

      # _@return_ — highest end offset of the row group's chunks; nil without chunks
      sig { returns(T.nilable(Integer)) }
      def end_offset; end

      # _@param_ `path` — dotted path (+"a.b"+) or path segments (+["a", "b"]+)
      # 
      # _@return_ — the chunk of that column, nil when there is none
      sig { params(path: T.any(String, T::Array[String])).returns(T.nilable(ColumnChunkInfo)) }
      def column(path); end

      # The row group's declared sort order
      # 
      # _@return_ — each { column:, descending:, nulls_first: }, where
      # +column+ is the column's path (its index when out of range)
      sig { returns(T::Array[T::Hash[Symbol, Object]]) }
      def sorting_columns; end

      # Everything known about the row group, with each column chunk's #to_h
      # 
      # _@return_ — JSON-safe; keys without a value are left out
      sig { returns(T::Hash[Symbol, Object]) }
      def to_h; end

      # _@return_ — short description: index, row count and number of columns
      sig { returns(String) }
      def inspect; end

      # Returns the value of attribute index.
      sig { returns(T.untyped) }
      attr_reader :index

      # Returns the value of attribute row_group.
      sig { returns(T.untyped) }
      attr_reader :row_group

      # Returns the value of attribute columns.
      sig { returns(T.untyped) }
      attr_reader :columns

      # _@return_ — file-wide index of the row group's first row
      sig { returns(Integer) }
      attr_reader :first_row
    end

    # Decodes the ARROW:schema key/value that Arrow writers (pyarrow, arrow-rs, DuckDB...) store:
    # base64 of an Arrow IPC message whose header is a flatbuffer Schema (Arrow's Message.fbs and
    # Schema.fbs). Pure Ruby and read-only; type names follow pyarrow's (str(field.type)).
    # 
    #   Inspector::ArrowSchema.decode(value)
    #   # => { endianness: "little", metadata: {...}, fields: [{ name: "a", type: "int32", nullable: true, ... }] }
    # 
    # Fields carry :name, :type, :nullable and, when present, :children, :dictionary
    # ({ index_type:, ordered:, id: }), :extension (ARROW:extension:name) and :metadata.
    module ArrowSchema
      # Decodes the base64 ARROW:schema value; raises ArrowSchema::Error when it can't
      # 
      # _@param_ `b64` — the key/value metadata value (base64 of an IPC Schema message)
      # 
      # _@return_ — { endianness:, fields:, metadata: }; +metadata+ is a
      # Hash{String => String}, left out when the schema has none
      sig { params(b64: String).returns(T::Hash[Symbol, Object]) }
      def decode(b64); end

      # Decodes the base64 ARROW:schema value; raises ArrowSchema::Error when it can't
      # 
      # _@param_ `b64` — the key/value metadata value (base64 of an IPC Schema message)
      # 
      # _@return_ — { endianness:, fields:, metadata: }; +metadata+ is a
      # Hash{String => String}, left out when the schema has none
      sig { params(b64: String).returns(T::Hash[Symbol, Object]) }
      def self.decode(b64); end

      # The flatbuffer inside an encapsulated IPC message: [0xFFFFFFFF] int32 length, flatbuffer
      # (the continuation marker is missing in files from before Arrow 0.15)
      # 
      # _@param_ `bytes` — the decoded (binary) ARROW:schema value
      # 
      # _@return_ — the message's flatbuffer bytes
      sig { params(bytes: String).returns(String) }
      def message_bytes(bytes); end

      # The flatbuffer inside an encapsulated IPC message: [0xFFFFFFFF] int32 length, flatbuffer
      # (the continuation marker is missing in files from before Arrow 0.15)
      # 
      # _@param_ `bytes` — the decoded (binary) ARROW:schema value
      # 
      # _@return_ — the message's flatbuffer bytes
      sig { params(bytes: String).returns(String) }
      def self.message_bytes(bytes); end

      # Describes one Arrow Field table and, recursively, its children
      # 
      # _@param_ `t` — the Field table
      # 
      # _@param_ `depth` — nesting depth of the field, 0 at the top level
      # 
      # _@param_ `count` — one-element counter of the fields seen so far, shared across the recursion
      # 
      # _@return_ — see the module description for the keys
      sig { params(t: Table, depth: Integer, count: T::Array[Integer]).returns(T::Hash[Symbol, Object]) }
      def field(t, depth, count); end

      # Describes one Arrow Field table and, recursively, its children
      # 
      # _@param_ `t` — the Field table
      # 
      # _@param_ `depth` — nesting depth of the field, 0 at the top level
      # 
      # _@param_ `count` — one-element counter of the fields seen so far, shared across the recursion
      # 
      # _@return_ — see the module description for the keys
      sig { params(t: Table, depth: Integer, count: T::Array[Integer]).returns(T::Hash[Symbol, Object]) }
      def self.field(t, depth, count); end

      # _@param_ `tables` — KeyValue tables (custom_metadata of a Schema or Field)
      # 
      # _@return_ — nil when there are none
      sig { params(tables: T::Array[Table]).returns(T.nilable(T::Hash[String, String])) }
      def key_values(tables); end

      # _@param_ `tables` — KeyValue tables (custom_metadata of a Schema or Field)
      # 
      # _@return_ — nil when there are none
      sig { params(tables: T::Array[Table]).returns(T.nilable(T::Hash[String, String])) }
      def self.key_values(tables); end

      # A child as pyarrow prints it inside a nested type: "name: type" plus " not null"
      # 
      # _@param_ `c` — a field as returned by #field
      sig { params(c: T::Hash[Symbol, Object]).returns(String) }
      def child_text(c); end

      # A child as pyarrow prints it inside a nested type: "name: type" plus " not null"
      # 
      # _@param_ `c` — a field as returned by #field
      sig { params(c: T::Hash[Symbol, Object]).returns(String) }
      def self.child_text(c); end

      # _@param_ `t` — an Arrow Int table (bitWidth, is_signed)
      # 
      # _@return_ — e.g. "int32" or "uint8"
      sig { params(t: Table).returns(String) }
      def int_name(t); end

      # _@param_ `t` — an Arrow Int table (bitWidth, is_signed)
      # 
      # _@return_ — e.g. "int32" or "uint8"
      sig { params(t: Table).returns(String) }
      def self.int_name(t); end

      # _@param_ `u` — Arrow TimeUnit value
      # 
      # _@return_ — "s", "ms", "us" or "ns" ("unitN" for unknown values)
      sig { params(u: Integer).returns(String) }
      def unit(u); end

      # _@param_ `u` — Arrow TimeUnit value
      # 
      # _@return_ — "s", "ms", "us" or "ns" ("unitN" for unknown values)
      sig { params(u: Integer).returns(String) }
      def self.unit(u); end

      # Type names follow Arrow's DataType::ToString (what pyarrow prints)
      # 
      # _@param_ `kind` — the Field's Type union tag (Schema.fbs)
      # 
      # _@param_ `t` — the union's type table, nil when absent
      # 
      # _@param_ `children` — the already described child fields
      # 
      # _@return_ — e.g. "timestamp[us, tz=UTC]" or "list<item: string>"
      sig { params(kind: Integer, t: T.nilable(Table), children: T::Array[T::Hash[Symbol, Object]]).returns(String) }
      def type_name(kind, t, children); end

      # Type names follow Arrow's DataType::ToString (what pyarrow prints)
      # 
      # _@param_ `kind` — the Field's Type union tag (Schema.fbs)
      # 
      # _@param_ `t` — the union's type table, nil when absent
      # 
      # _@param_ `children` — the already described child fields
      # 
      # _@return_ — e.g. "timestamp[us, tz=UTC]" or "list<item: string>"
      sig { params(kind: Integer, t: T.nilable(Table), children: T::Array[T::Hash[Symbol, Object]]).returns(String) }
      def self.type_name(kind, t, children); end

      # map<key, value> with non-standard field names in parentheses, as Arrow prints it
      # 
      # _@param_ `t` — the Map table (keysSorted), nil when absent
      # 
      # _@param_ `children` — the map's single entries struct field
      sig { params(t: T.nilable(Table), children: T::Array[T::Hash[Symbol, Object]]).returns(String) }
      def map_name(t, children); end

      # map<key, value> with non-standard field names in parentheses, as Arrow prints it
      # 
      # _@param_ `t` — the Map table (keysSorted), nil when absent
      # 
      # _@param_ `children` — the map's single entries struct field
      sig { params(t: T.nilable(Table), children: T::Array[T::Hash[Symbol, Object]]).returns(String) }
      def self.map_name(t, children); end

      # "name: type" lines for a field and its children, indented, for text output
      # Children nested deeper than 8 levels are left out.
      # 
      # _@param_ `fields` — fields as returned by #decode under +:fields+
      # 
      # _@param_ `depth` — indentation level of +fields+
      # 
      # _@param_ `out` — accumulator the lines are appended to
      # 
      # _@return_ — +out+
      sig { params(fields: T::Array[T::Hash[Symbol, Object]], depth: Integer, out: T::Array[String]).returns(T::Array[String]) }
      def lines(fields, depth = 0, out = []); end

      # "name: type" lines for a field and its children, indented, for text output
      # Children nested deeper than 8 levels are left out.
      # 
      # _@param_ `fields` — fields as returned by #decode under +:fields+
      # 
      # _@param_ `depth` — indentation level of +fields+
      # 
      # _@param_ `out` — accumulator the lines are appended to
      # 
      # _@return_ — +out+
      sig { params(fields: T::Array[T::Hash[Symbol, Object]], depth: Integer, out: T::Array[String]).returns(T::Array[String]) }
      def self.lines(fields, depth = 0, out = []); end

      # Raised for malformed or unsupported ARROW:schema values
      class Error < StandardError
      end

      # A minimal flatbuffer reader: tables (through their vtables), scalars, strings, vectors of
      # scalars and tables, and unions. Every read is bounds-checked; malformed input raises Error.
      # 
      # @api private
      class FlatBuffer
        # _@param_ `bytes` — the flatbuffer (copied as binary)
        sig { params(bytes: String).void }
        def initialize(bytes); end

        # _@return_ — the root table, whose offset is stored in the first 4 bytes
        sig { returns(Table) }
        def root; end

        # _@param_ `pos` — absolute position of a table
        sig { params(pos: Integer).returns(Table) }
        def table_at(pos); end

        # _@param_ `pos` — absolute start of the read
        # 
        # _@param_ `len` — bytes to read
        sig { params(pos: Integer, len: Integer).void }
        def check(pos, len); end

        # _@param_ `pos` — absolute start of the read
        # 
        # _@param_ `len` — bytes to read
        # 
        # _@param_ `fmt` — String#unpack1 directive for the bytes
        # 
        # _@return_ — the unpacked scalar
        sig { params(pos: Integer, len: Integer, fmt: String).returns(Integer) }
        def read(pos, len, fmt); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — unsigned 8-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def u8(pos); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — unsigned little-endian 16-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def u16(pos); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — signed little-endian 16-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def i16(pos); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — unsigned little-endian 32-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def u32(pos); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — signed little-endian 32-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def i32(pos); end

        # _@param_ `pos` — absolute position
        # 
        # _@return_ — signed little-endian 64-bit value at +pos+
        sig { params(pos: Integer).returns(Integer) }
        def i64(pos); end

        # Offsets are relative to where they are stored
        # 
        # _@param_ `pos` — absolute position of a uoffset
        # 
        # _@return_ — absolute position it points to
        sig { params(pos: Integer).returns(Integer) }
        def deref(pos); end

        # _@param_ `pos` — absolute position of the string's length prefix
        # 
        # _@return_ — the string's bytes as UTF-8 (not validated)
        sig { params(pos: Integer).returns(String) }
        def string(pos); end

        # [start, length] of the vector at +pos+ with +size+-byte elements
        # 
        # _@param_ `pos` — absolute position of the vector's length prefix
        # 
        # _@param_ `size` — bytes per element
        # 
        # _@return_ — start of the first element and the element count
        sig { params(pos: Integer, size: Integer).returns([Integer, Integer]) }
        def vector(pos, size); end
      end

      # One flatbuffer table; fields are addressed by their slot (declaration order in the .fbs)
      # 
      # @api private
      class Table
        # _@param_ `fb` — buffer the table lives in
        # 
        # _@param_ `pos` — absolute position of the table (where its vtable offset is stored)
        sig { params(fb: FlatBuffer, pos: Integer).void }
        def initialize(fb, pos); end

        # Absolute position of a field's value, nil when absent
        # 
        # _@param_ `slot` — field slot, counting from 0
        sig { params(slot: Integer).returns(T.nilable(Integer)) }
        def field(slot); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@param_ `default` — returned when the field is absent (the .fbs default)
        # 
        # _@return_ — the unsigned 8-bit field (also used for union type tags)
        sig { params(slot: Integer, default: Integer).returns(Integer) }
        def u8(slot, default = 0); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@param_ `default` — returned when the field is absent (the .fbs default)
        sig { params(slot: Integer, default: T::Boolean).returns(T::Boolean) }
        def bool(slot, default = false); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@param_ `default` — returned when the field is absent (the .fbs default)
        # 
        # _@return_ — the signed 16-bit field (also used for enums such as TimeUnit)
        sig { params(slot: Integer, default: Integer).returns(Integer) }
        def i16(slot, default = 0); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@param_ `default` — returned when the field is absent (the .fbs default)
        # 
        # _@return_ — the signed 32-bit field
        sig { params(slot: Integer, default: Integer).returns(Integer) }
        def i32(slot, default = 0); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@param_ `default` — returned when the field is absent (the .fbs default)
        # 
        # _@return_ — the signed 64-bit field
        sig { params(slot: Integer, default: Integer).returns(Integer) }
        def i64(slot, default = 0); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@return_ — the string field, nil when absent
        sig { params(slot: Integer).returns(T.nilable(String)) }
        def string(slot); end

        # _@param_ `slot` — field slot, counting from 0 (also the value of a union)
        # 
        # _@return_ — the sub-table, nil when absent
        sig { params(slot: Integer).returns(T.nilable(Table)) }
        def table(slot); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@return_ — the vector of tables, empty when absent
        sig { params(slot: Integer).returns(T::Array[Table]) }
        def tables(slot); end

        # _@param_ `slot` — field slot, counting from 0
        # 
        # _@return_ — the vector of signed 32-bit values, empty when absent
        sig { params(slot: Integer).returns(T::Array[Integer]) }
        def i32s(slot); end
      end
    end
  end

  # Rewrites a Parquet file with rows removed or column values replaced, for GDPR erasure ("forget
  # me") and pseudonymization. A Redaction is built once and applied to any number of files, one
  # file in and one file out:
  # 
  #   forget = Herringbone::Redaction.new do |r|
  #     r.where(user_id: 42).delete
  #     r.where(email: "anna@example.com").replace(email: nil, name: nil)
  #     r.replace(:phone) { |phone| phone&.gsub(/\d(?=\d{3})/, "#") }
  #     r.drop :ssn
  #   end
  #   File.open("in.parquet", "rb") do |io|
  #     File.open("out.parquet", "wb") { |output_io| forget.apply(io, output_io) }
  #   end
  # 
  # Statements apply in declared order, per row: a deleted row is gone for later statements, and
  # later statements (their conditions and their blocks) see what earlier ones replaced.
  # 
  # Row groups no statement touches are copied byte for byte. A row group where only leaf columns
  # are replaced gets just those column chunks re-encoded. A row group with deleted rows, or with a
  # nested field replaced as a whole, is rewritten. Either way no deleted or replaced value is
  # left in data pages, dictionary pages, statistics, the page index or bloom filters.
  class Redaction
    # Builds a redaction. The block receives the redaction and declares the statements on it,
    # see the class description.
    sig { params(block: T.proc.params(r: Redaction).void).void }
    def initialize(&block); end

    # Selects the rows the next verb applies to. Takes what Reader#read(where:) takes: values,
    # Arrays (IN), Ranges, nil (IS NULL), callables and dotted struct member paths, all of which
    # must hold.
    # 
    #   where(user_id: 42).delete
    #   where("address.city" => "Amsterdam", created_at: ..cutoff).replace(name: nil)
    # 
    # _@param_ `conditions` — column => condition
    # 
    # _@param_ `more` — more conditions, as keyword arguments
    # 
    # _@return_ — call #delete or #replace on it
    sig { params(conditions: T.nilable(T::Hash[T.any(String, Symbol), Object]), more: T::Hash[T.any(String, Symbol), Object]).returns(Scope) }
    def where(conditions = nil, **more); end

    # Replaces values in every row (or, after #where, in the matching rows). Either constants:
    # 
    #   replace(email: nil, name: "[deleted]")
    # 
    # or column names and a block computing each value from the current one, and from the whole
    # row (a Hash with String keys, as Reader returns it) when the block takes two parameters:
    # 
    #   replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", key, email) }
    #   replace(:name) { |name, row| row["consent"] ? name : nil }
    # 
    # A column is a top-level field or a struct member by dotted path. Values inside a list or map
    # are replaced by replacing the whole field with a block that receives the Array or Hash.
    # A struct member of a row whose struct is null is left alone.
    # 
    # _@param_ `columns` — columns whose values the block computes
    # 
    # _@param_ `constants` — column => value to set
    # 
    # _@return_ — self
    sig { params(columns: T::Array[T.any(String, Symbol)], constants: T::Hash[T.any(String, Symbol), Object], block: T.proc.params(value: Object, row: T::Hash[String, Object]).returns(Object)).returns(Redaction) }
    def replace(*columns, **constants, &block); end

    # Removes columns from the schema: top-level fields, or struct members by dotted path
    # 
    # _@param_ `columns` — columns to remove
    # 
    # _@return_ — self
    sig { params(columns: T::Array[T.any(String, Symbol)]).returns(Redaction) }
    def drop(*columns); end

    # Internal (used by Scope): appends a statement
    # 
    # _@param_ `statement` — the statement to add
    # 
    # _@return_ — self
    sig { params(statement: Statement).returns(Redaction) }
    def add_statement(statement); end

    # Whether #apply would change +io_or_reader+: true when a column is dropped, when a replace without
    # #where meets a non-empty file, or when some row matches a #where. Reads as little as it can:
    # row groups are ruled out with statistics, bloom filters and the page index first, and only
    # the columns the conditions name are read for the rest.
    # 
    # _@param_ `io_or_reader` — the Parquet file, read with #seek and #read, or a Reader of it, whose IO and decryption are used
    # 
    # _@param_ `decryption` — keys of an encrypted file, see Reader.new; not with a Reader, which has its own
    sig { params(io_or_reader: T.any(IO, StringIO, Reader), decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object]))).returns(T::Boolean) }
    def affects?(io_or_reader, decryption: nil); end

    # Writes the redacted copy of +io_or_reader+ to +output_io+. The redaction is checked against the
    # file's schema first, so a missing column, a nil for a required column or a #where without a
    # verb raise before anything is written. The output is left unfinished (no footer) when an
    # error happens later, for instance a block returning a value its column cannot store.
    # 
    # A Reader is read with its own IO and decryption, but always with the default +keys:+ and
    # +time_zone:+, whatever it was built with.
    # 
    # An encrypted input (opened with +decryption:+) is written encrypted the same way: same
    # algorithm, footer mode, AAD prefix, keys and key metadata. +encryption:+ (see Writer) writes
    # it with other settings, and +encryption: false+ writes a plaintext file. Column chunks that
    # are encrypted in either file are re-encoded rather than copied.
    # 
    # _@param_ `io_or_reader` — the Parquet file, read with #seek and #read, or a Reader of it; not closed
    # 
    # _@param_ `output_io` — destination, written sequentially; not closed
    # 
    # _@param_ `decryption` — keys of an encrypted input, see Reader.new; not with a Reader, which has its own
    # 
    # _@param_ `writer_options` — Writer options for the re-encoded column chunks (+compression:+, +bloom_filters:+, +page_rows:+, +dictionary:+...), and +metadata:+ to replace the footer key/value metadata instead of copying it
    # 
    # _@return_ — what was done
    sig do
      params(
        io_or_reader: T.any(IO, StringIO, Reader),
        output_io: T.any(IO, T.untyped),
        decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object])),
        writer_options: T::Hash[Symbol, Object]
      ).returns(Report)
    end
    def apply(io_or_reader, output_io, decryption: nil, **writer_options); end

    # Short summary for the console: one clause per statement, naming the columns but not the
    # condition values, since a where may hold a long list of ids
    sig { returns(String) }
    def inspect; end

    # Builds a replace statement from the arguments of #replace
    # 
    # _@param_ `where` — conditions, nil for every row
    # 
    # _@param_ `columns` — columns for the block
    # 
    # _@param_ `constants` — column => value
    # 
    # _@param_ `block` — computes the values
    sig do
      params(
        where: T.nilable(T::Hash[T.any(String, Symbol), Object]),
        columns: T::Array[T.any(String, Symbol)],
        constants: T::Hash[T.any(String, Symbol), Object],
        block: T.nilable(Proc)
      ).returns(Statement)
    end
    def self.replace_statement(where, columns, constants, block); end

    sig { void }
    def check_scopes!; end

    # _@return_ — the statements, in declared order
    sig { returns(T::Array[Statement]) }
    attr_reader :statements

    # _@return_ — fields and struct members to remove from the schema
    sig { returns(T::Array[String]) }
    attr_reader :drops

    # One statement of a Redaction
    # 
    # @!attribute kind
    #   @return [Symbol] +:delete+ or +:replace+
    # @!attribute where
    #   @return [Hash{String, Symbol => Object}, nil] conditions as given to #where, nil for every row
    # @!attribute targets
    #   @return [Array<String>] columns to replace (top-level names or dotted struct member paths)
    # @!attribute constants
    #   @return [Hash{String => Object}] column => value, for a replace without a block
    # @!attribute block
    #   @return [Proc, nil] computes the replacement values
    class Statement < Struct
      # _@return_ — +:delete+ or +:replace+
      sig { returns(Symbol) }
      attr_accessor :kind

      # _@return_ — conditions as given to #where, nil for every row
      sig { returns(T.nilable(T::Hash[T.any(String, Symbol), Object])) }
      attr_accessor :where

      # _@return_ — columns to replace (top-level names or dotted struct member paths)
      sig { returns(T::Array[String]) }
      attr_accessor :targets

      # _@return_ — column => value, for a replace without a block
      sig { returns(T::Hash[String, Object]) }
      attr_accessor :constants

      # _@return_ — computes the replacement values
      sig { returns(T.nilable(Proc)) }
      attr_accessor :block
    end

    # What #apply did, for the audit trail an erasure needs
    # 
    # @!attribute rows_read
    #   @return [Integer] rows decoded (rows of row groups that were copied unread are not counted)
    # @!attribute rows_deleted
    #   @return [Integer] rows removed
    # @!attribute rows_changed
    #   @return [Integer] rows kept where at least one replace produced a different value
    # @!attribute row_groups
    #   @return [Hash{Symbol => Integer}] +{copied:, rewritten:}+ row group counts
    class Report < Struct
      # _@return_ — rows decoded (rows of row groups that were copied unread are not counted)
      sig { returns(Integer) }
      attr_accessor :rows_read

      # _@return_ — rows removed
      sig { returns(Integer) }
      attr_accessor :rows_deleted

      # _@return_ — rows kept where at least one replace produced a different value
      sig { returns(Integer) }
      attr_accessor :rows_changed

      # _@return_ — +{copied:, rewritten:}+ row group counts
      sig { returns(T::Hash[Symbol, Integer]) }
      attr_accessor :row_groups
    end

    # Rows selected with Redaction#where, waiting for a verb: #delete or #replace
    class Scope
      # _@param_ `redaction` — the redaction the statement is added to
      # 
      # _@param_ `conditions` — column => condition, as Reader#read(where:)
      sig { params(redaction: Redaction, conditions: T::Hash[T.any(String, Symbol), Object]).void }
      def initialize(redaction, conditions); end

      # _@return_ — whether a verb was called on this scope
      sig { returns(T::Boolean) }
      def used?; end

      # Removes the matching rows
      # 
      # _@return_ — the redaction, for chaining
      sig { returns(Redaction) }
      def delete; end

      # Replaces values in the matching rows, see Redaction#replace
      # 
      # _@param_ `columns` — columns whose values the block computes
      # 
      # _@param_ `constants` — column => value to set
      # 
      # _@return_ — the redaction, for chaining
      sig { params(columns: T::Array[T.any(String, Symbol)], constants: T::Hash[T.any(String, Symbol), Object], block: T.proc.params(value: Object, row: T::Hash[String, Object]).returns(Object)).returns(Redaction) }
      def replace(*columns, **constants, &block); end

      # Short summary for the console: the columns the conditions name, not their values
      sig { returns(String) }
      def inspect; end

      # _@return_ — the conditions given to Redaction#where
      sig { returns(T::Hash[T.any(String, Symbol), Object]) }
      attr_reader :conditions
    end

    # Applies a Redaction to one file. Building it checks the redaction against the file's schema,
    # so mistakes surface before anything is written.
    # 
    # Each row group lands in one of three tiers. When no statement can match (by statistics,
    # bloom filters and the page index, or by reading the condition columns), its column chunks
    # are copied byte for byte. When rows match but none is deleted and only leaf columns change,
    # the changed chunks are re-encoded and the others copied. Otherwise the whole row group is
    # rewritten, keeping its boundary: one row group in, one (or none) out.
    # 
    # @api private
    class Rewriter
      # _@param_ `redaction` — the statements and drops to apply
      # 
      # _@param_ `io_or_reader` — the Parquet file, read with #seek and #read, or a Reader of it (whose IO and decryption are used)
      # 
      # _@param_ `decryption` — keys of an encrypted file, see Reader.new; not with a Reader
      sig { params(redaction: Redaction, io_or_reader: T.any(IO, StringIO, Reader), decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object]))).void }
      def initialize(redaction, io_or_reader, decryption: nil); end

      # _@return_ — see Redaction#affects?
      sig { returns(T::Boolean) }
      def affects?; end

      # _@param_ `output_io` — destination
      # 
      # _@param_ `options` — Writer options for re-encoded chunks, and +metadata:+
      sig { params(output_io: T.any(IO, T.untyped), options: T::Hash[Symbol, Object]).returns(Report) }
      def apply(output_io, **options); end

      # The caller's Reader may have been built with +keys:+ or +time_zone:+, which change what
      # #read returns, so values are always read through a Reader with the default options
      # 
      # _@param_ `io_or_reader` — the Parquet file, or a Reader of it
      # 
      # _@param_ `decryption` — keys, for an IO only
      sig { params(io_or_reader: T.any(IO, StringIO, Reader), decryption: T.nilable(T.any(DecryptionConfiguration, T::Hash[Symbol, Object]))).returns(Reader) }
      def fixed_options_reader(io_or_reader, decryption); end

      # _@param_ `i` — row group index
      # 
      # _@param_ `writer` — the output
      sig { params(i: Integer, writer: Writer).void }
      def redact_row_group(i, writer); end

      # Statements that may touch row group +i+: those without conditions, and those whose
      # conditions the statistics, bloom filters and page index do not rule out
      # 
      # _@param_ `i` — row group index
      # 
      # _@return_ — statement indexes
      sig { params(i: Integer).returns(T::Array[Integer]) }
      def candidates(i); end

      # Reads the condition columns of row group +i+ and checks them against the original values.
      # When no row matches any statement, no statement changes anything (later statements see
      # what earlier ones changed, and none did), so the row group can be copied.
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `candidates` — indexes of statements, all with conditions
      # 
      # _@return_ — whether some row matches some statement
      sig { params(i: Integer, candidates: T::Array[Integer]).returns(T::Boolean) }
      def any_match?(i, candidates); end

      # Applies the statements to every row of row group +i+, in place in @data
      # 
      # _@param_ `i` — row group index
      # 
      # _@return_ — deleted flag per row, and the targets whose
      # values changed
      sig { params(i: Integer).returns([T::Array[T::Boolean], T::Array[Target]]) }
      def run_statements(i); end

      # _@param_ `filter` — conditions of a statement
      # 
      # _@param_ `r` — row index within the row group
      # 
      # _@return_ — whether the row, as earlier statements left it, matches all conditions
      sig { params(filter: Reader::Filter, r: Integer).returns(T::Boolean) }
      def row_matches?(filter, r); end

      # _@param_ `t` — replaced column
      # 
      # _@param_ `r` — row index within the row group
      # 
      # _@return_ — the column's current value, or ABSENT when a struct holding it is null
      sig { params(t: Target, r: Integer).returns(Object) }
      def current(t, r); end

      # Stores a value, copying the struct Hashes on the way so nothing else shares them
      # 
      # _@param_ `t` — replaced column
      # 
      # _@param_ `r` — row index within the row group
      # 
      # _@param_ `value` — the new value
      sig { params(t: Target, r: Integer, value: Object).void }
      def assign(t, r, value); end

      # _@param_ `r` — row index within the row group
      # 
      # _@return_ — the whole row as it stands, keyed by top-level field name
      sig { params(r: Integer).returns(T::Hash[String, Object]) }
      def row_hash(r); end

      # Tier 1: every kept column chunk is copied as it is, except those encrypted in the input or
      # the output, which are encoded again
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `writer` — the output
      sig { params(i: Integer, writer: Writer).void }
      def copy_row_group(i, writer); end

      # Tier 2: the chunks of the changed leaf columns (and of encrypted ones) are encoded again,
      # the rest are copied
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `writer` — the output
      # 
      # _@param_ `changed` — leaf targets whose values changed
      sig { params(i: Integer, writer: Writer, changed: T::Array[Target]).void }
      def rewrite_columns(i, writer, changed); end

      # Kept columns whose chunk in row group +i+ cannot be copied, because it is encrypted in the
      # input (its AAD names the file and the chunk's place in it) or is to be encrypted
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `writer` — the output
      # 
      # _@return_ — input column indexes
      sig { params(i: Integer, writer: Writer).returns(T::Array[Integer]) }
      def encrypted_columns(i, writer); end

      # The Writer +encryption:+ option that encrypts the output like the input: the same
      # algorithm, footer mode, AAD prefix and keys, for the columns that are kept
      # 
      # _@return_ — nil for a plaintext input
      sig { returns(T.nilable(EncryptionConfiguration)) }
      def input_encryption; end

      # Tier 3: the remaining rows are encoded again, every column of them
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `writer` — the output
      # 
      # _@param_ `deleted` — deleted flag per row
      # 
      # _@param_ `changed` — targets whose values changed
      sig do
        params(
          i: Integer,
          writer: Writer,
          deleted: T::Array[T::Boolean],
          changed: T::Array[Target]
        ).void
      end
      def rewrite_row_group(i, writer, deleted, changed); end

      # Codec and bloom filter of a re-encoded chunk follow the source chunk (see
      # Reader::ChunkCopier#recode_settings), unless +compression:+ was given
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `col` — the input column
      # 
      # _@param_ `j` — the output column index
      # 
      # _@param_ `codecs` — collects output column index => codec id
      # 
      # _@param_ `blooms` — collects output column index => true
      sig do
        params(
          i: Integer,
          col: Schema::Column,
          j: Integer,
          codecs: T::Hash[Integer, Integer],
          blooms: T::Hash[Integer, T::Boolean]
        ).void
      end
      def chunk_settings(i, col, j, codecs, blooms); end

      # The row group's sorting columns that still hold: dropped or changed columns end the list
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `rewritten` — indexes of input columns whose values changed
      sig { params(i: Integer, rewritten: T::Array[Integer]).returns(T.nilable(T::Array[Format::SortingColumn])) }
      def sorting_columns(i, rewritten); end

      # Reads top-level fields of row group +i+ into @data, unless they are there already
      # 
      # _@param_ `i` — row group index
      # 
      # _@param_ `names` — top-level field names
      sig { params(i: Integer, names: T::Array[String]).void }
      def load(i, names); end

      # _@param_ `i` — row group index
      # 
      # _@return_ — rows in the row group
      sig { params(i: Integer).returns(Integer) }
      def rows(i); end

      # _@param_ `block` — a replace block
      # 
      # _@return_ — whether the block takes the row as a second parameter
      sig { params(block: Proc).returns(T::Boolean) }
      def wants_row?(block); end

      # Resolves a column named in a statement: a top-level field, or a struct member by dotted path
      # 
      # _@param_ `name` — the column as named
      # 
      # _@param_ `verb` — "replace" or "drop", for error messages
      # 
      # _@return_ — the field and its path of names
      sig { params(name: String, verb: String).returns([Schema::Field, T::Array[String]]) }
      def resolve(name, verb); end

      # _@param_ `name` — the column as named in the statement
      # 
      # _@param_ `statement` — the replace statement
      sig { params(name: String, statement: Statement).returns(Target) }
      def target(name, statement); end

      sig { void }
      def check_drops!; end

      # The input schema without the dropped fields
      sig { returns(Schema) }
      def output_schema; end

      # A replaced column, resolved against the file's schema
      # 
      # @!attribute name
      #   @return [String] the column as named in the statement
      # @!attribute path
      #   @return [Array<String>] top-level field name, then struct member names
      # @!attribute field
      #   @return [Schema::Field] the replaced field
      # @!attribute column
      #   @return [Schema::Column, nil] the leaf column, nil when the field is nested
      class Target < Struct
        # _@return_ — the column as named in the statement
        sig { returns(String) }
        attr_accessor :name

        # _@return_ — top-level field name, then struct member names
        sig { returns(T::Array[String]) }
        attr_accessor :path

        # _@return_ — the replaced field
        sig { returns(Schema::Field) }
        attr_accessor :field

        # _@return_ — the leaf column, nil when the field is nested
        sig { returns(T.nilable(Schema::Column)) }
        attr_accessor :column
      end
    end
  end

  # Parquet modular encryption (Encryption.md in parquet-format): AES-GCM and AES-CTR on top of
  # OpenSSL, and the AADs that tie every encrypted module to its file and its place in the file.
  # Writer takes +encryption:+ and Reader +decryption:+; see FileEncryptor and FileDecryptor.
  # 
  # An encrypted module is stored as a 4-byte little-endian length, then a 12-byte nonce, the
  # ciphertext and (GCM only) a 16-byte tag.
  # 
  # @api private
  module Encryption
    # _@param_ `key` — candidate key
    # 
    # _@param_ `what` — what the key is for, for the error message
    # 
    # _@return_ — the key as a binary String
    sig { params(key: Object, what: String).returns(String) }
    def check_key!(key, what); end

    # _@param_ `key` — candidate key
    # 
    # _@param_ `what` — what the key is for, for the error message
    # 
    # _@return_ — the key as a binary String
    sig { params(key: Object, what: String).returns(String) }
    def self.check_key!(key, what); end

    # Leaf columns named by a column path (a leaf) or by a field (all of its leaves)
    # 
    # _@param_ `schema` — schema holding the columns
    # 
    # _@param_ `name` — dotted path, or an Array of names
    # 
    # _@return_ — the columns, empty when nothing matches
    sig { params(schema: Schema, name: T.any(String, Symbol, T::Array[String])).returns(T::Array[Schema::Column]) }
    def columns_named(schema, name); end

    # Leaf columns named by a column path (a leaf) or by a field (all of its leaves)
    # 
    # _@param_ `schema` — schema holding the columns
    # 
    # _@param_ `name` — dotted path, or an Array of names
    # 
    # _@return_ — the columns, empty when nothing matches
    sig { params(schema: Schema, name: T.any(String, Symbol, T::Array[String])).returns(T::Array[Schema::Column]) }
    def self.columns_named(schema, name); end

    # Reads the footer region (everything between the data and the 4-byte footer length) of a
    # plaintext or encrypted file. Column metadata that can be decrypted replaces the stripped or
    # missing +meta_data+ of its ColumnChunk.
    # 
    # _@param_ `region` — the footer region, binary
    # 
    # _@param_ `magic` — the file's closing magic, "PAR1" or "PARE"
    # 
    # _@param_ `decryption` — the keys
    # 
    # _@return_ — the footer, and its decryptor (nil for
    # a file that is not encrypted)
    sig { params(region: String, magic: String, decryption: T.nilable(DecryptionConfiguration)).returns([Format::FileMetaData, FileDecryptor]) }
    def read_footer(region, magic, decryption); end

    # Reads the footer region (everything between the data and the 4-byte footer length) of a
    # plaintext or encrypted file. Column metadata that can be decrypted replaces the stripped or
    # missing +meta_data+ of its ColumnChunk.
    # 
    # _@param_ `region` — the footer region, binary
    # 
    # _@param_ `magic` — the file's closing magic, "PAR1" or "PARE"
    # 
    # _@param_ `decryption` — the keys
    # 
    # _@return_ — the footer, and its decryptor (nil for
    # a file that is not encrypted)
    sig { params(region: String, magic: String, decryption: T.nilable(DecryptionConfiguration)).returns([Format::FileMetaData, FileDecryptor]) }
    def self.read_footer(region, magic, decryption); end

    # A module stored in a Thrift binary field, with its length prefix (as parquet-mr and Arrow
    # write it) or without
    # 
    # _@param_ `bytes` — the field's value
    # 
    # _@return_ — the module with its length prefix
    sig { params(bytes: String).returns(String) }
    def length_prefixed(bytes); end

    # A module stored in a Thrift binary field, with its length prefix (as parquet-mr and Arrow
    # write it) or without
    # 
    # _@param_ `bytes` — the field's value
    # 
    # _@return_ — the module with its length prefix
    sig { params(bytes: String).returns(String) }
    def self.length_prefixed(bytes); end

    # AES with one key: GCM and CTR ciphers, reused from module to module, and the count of
    # encryptions done with the key
    class Cipher
      # _@param_ `key` — 16, 24 or 32 bytes
      sig { params(key: String).void }
      def initialize(key); end

      # _@param_ `plain` — bytes to encrypt
      # 
      # _@param_ `aad` — additional authenticated data
      # 
      # _@return_ — the module: length, nonce, ciphertext and tag
      sig { params(plain: String, aad: String).returns(String) }
      def gcm_encrypt(plain, aad); end

      # _@param_ `buf` — nonce, ciphertext and tag
      # 
      # _@param_ `aad` — additional authenticated data
      # 
      # _@return_ — the plaintext
      sig { params(buf: String, aad: String).returns(String) }
      def gcm_decrypt(buf, aad); end

      # The tag GCM gives +plain+ with +nonce+, for footer signatures
      # 
      # _@param_ `plain` — the signed bytes
      # 
      # _@param_ `aad` — additional authenticated data
      # 
      # _@param_ `nonce` — the nonce to use, random when nil
      # 
      # _@return_ — nonce and tag
      sig { params(plain: String, aad: String, nonce: T.nilable(String)).returns(String) }
      def gcm_sign(plain, aad, nonce = nil); end

      # _@param_ `plain` — bytes to encrypt
      # 
      # _@return_ — the module: length, nonce and ciphertext
      sig { params(plain: String).returns(String) }
      def ctr_encrypt(plain); end

      # _@param_ `buf` — nonce and ciphertext
      # 
      # _@return_ — the plaintext
      sig { params(buf: String).returns(String) }
      def ctr_decrypt(buf); end

      # _@return_ — key size, without the key
      sig { returns(String) }
      def inspect; end

      # _@param_ `nonce` — 12 bytes
      # 
      # _@param_ `data` — bytes to encrypt or decrypt (the same operation in CTR mode)
      sig { params(nonce: String, data: String).returns(String) }
      def ctr(nonce, data); end

      sig { void }
      def count!; end
    end

    # Encrypts and decrypts the modules of one column chunk (or the footer, without ordinals),
    # building each module's AAD
    class ModuleCrypto
      # _@param_ `cipher` — the column's (or footer's) key
      # 
      # _@param_ `file_aad` — AAD prefix and file unique id
      # 
      # _@param_ `ctr` — whether page bodies use AES-CTR (AES_GCM_CTR_V1)
      # 
      # _@param_ `row_group` — row group ordinal; nil for the footer
      # 
      # _@param_ `column` — column ordinal; nil for the footer
      # 
      # _@param_ `what` — the column and row group, for error messages
      sig do
        params(
          cipher: Cipher,
          file_aad: String,
          ctr: T::Boolean,
          row_group: T.nilable(Integer),
          column: T.nilable(Integer),
          what: String
        ).void
      end
      def initialize(cipher, file_aad, ctr, row_group = nil, column = nil, what = "the footer"); end

      # _@param_ `type` — module type
      # 
      # _@param_ `plain` — the module's plaintext
      # 
      # _@param_ `page` — data page ordinal within the chunk, for data pages and their headers
      # 
      # _@return_ — the encrypted module, length prefix included
      sig { params(type: Integer, plain: String, page: T.nilable(Integer)).returns(String) }
      def encrypt(type, plain, page = nil); end

      # _@param_ `type` — module type
      # 
      # _@param_ `mod` — the encrypted module, length prefix included
      # 
      # _@param_ `page` — data page ordinal within the chunk, for data pages and their headers
      # 
      # _@return_ — the plaintext
      sig { params(type: Integer, mod: String, page: T.nilable(Integer)).returns(String) }
      def decrypt(type, mod, page = nil); end

      # _@param_ `plain` — the footer as serialized
      # 
      # _@return_ — nonce and tag of the footer signature
      sig { params(plain: String).returns(String) }
      def sign(plain); end

      # _@param_ `plain` — the footer as serialized
      # 
      # _@param_ `signature` — nonce and tag stored after it
      # 
      # _@return_ — whether the signature matches
      sig { params(plain: String, signature: String).returns(T::Boolean) }
      def signed?(plain, signature); end

      # _@param_ `type` — module type
      # 
      # _@param_ `page` — page ordinal
      # 
      # _@return_ — file AAD, module type, row group and column ordinals, page ordinal
      sig { params(type: Integer, page: T.nilable(Integer)).returns(String) }
      def aad(type, page); end
    end

    # An EncryptionConfiguration applied to a schema: what the writer needs to encrypt each
    # module and the footer
    class FileEncryptor
      # _@param_ `config` — the settings
      # 
      # _@param_ `schema` — the schema being written
      sig { params(config: EncryptionConfiguration, schema: Schema).void }
      def initialize(config, schema); end

      # _@return_ — the magic bytes the file starts and ends with
      sig { returns(String) }
      def magic; end

      # _@param_ `index` — leaf column index
      # 
      # _@return_ — whether the column is encrypted
      sig { params(index: Integer).returns(T::Boolean) }
      def encrypted?(index); end

      # _@param_ `row_group` — row group ordinal
      # 
      # _@param_ `index` — leaf column index
      # 
      # _@return_ — encryption of the chunk's modules, nil for a plaintext column
      sig { params(row_group: Integer, index: Integer).returns(T.nilable(ModuleCrypto)) }
      def chunk(row_group, index); end

      # Sets the crypto metadata of the encrypted column chunks, and encrypts their ColumnMetaData
      # when it is not protected by the footer: for columns with their own key, and in plaintext
      # footer mode, where the footer keeps a copy without statistics
      # 
      # _@param_ `row_groups` — the file's row groups, changed in place
      sig { params(row_groups: T::Array[Format::RowGroup]).void }
      def finish(row_groups); end

      # The bytes between the last data and the footer length: the encrypted footer after its
      # FileCryptoMetaData, or the plaintext footer and its signature
      # 
      # _@param_ `meta` — the footer; gets the algorithm in plaintext mode
      sig { params(meta: Format::FileMetaData).returns(String) }
      def footer(meta); end

      # _@return_ — algorithm and footer mode, without keys
      sig { returns(String) }
      def inspect; end

      # _@param_ `key` — checked key
      # 
      # _@return_ — one per distinct key, so encryptions are counted per key
      sig { params(key: String).returns(Cipher) }
      def cipher_for(key); end

      # _@param_ `requested` — the configuration's columns
      # 
      # _@return_ — per leaf column
      sig { params(requested: T.nilable(T::Hash[String, T.any(EncryptionConfiguration::ColumnKey, Symbol)])).returns(T::Array[T.nilable(ColumnKey)]) }
      def column_keys(requested); end

      # _@param_ `meta` — the column's metadata
      # 
      # _@return_ — a copy without statistics, for plaintext footers
      sig { params(meta: Format::ColumnMetaData).returns(Format::ColumnMetaData) }
      def stripped(meta); end

      # _@return_ — whether the footer is stored in the clear (and signed)
      sig { returns(T::Boolean) }
      attr_reader :plaintext_footer

      # How one column is encrypted
      # 
      # @!attribute cipher
      #   @return [Cipher] its key
      # @!attribute key_metadata
      #   @return [String, nil] stored with the column (column keys only)
      # @!attribute footer
      #   @return [Boolean] whether the key is the footer key
      class ColumnKey < Struct
        # _@return_ — its key
        sig { returns(Cipher) }
        attr_accessor :cipher

        # _@return_ — stored with the column (column keys only)
        sig { returns(T.nilable(String)) }
        attr_accessor :key_metadata

        # _@return_ — whether the key is the footer key
        sig { returns(T::Boolean) }
        attr_accessor :footer
      end
    end

    # A DecryptionConfiguration applied to one file: finds the keys (given, or looked up by their
    # key metadata), checks the AAD prefix, decrypts the footer and the column metadata, and
    # hands out a ModuleCrypto per column chunk
    class FileDecryptor
      # _@param_ `config` — the keys; nil for none
      # 
      # _@param_ `algorithm` — from the footer or the FileCryptoMetaData
      # 
      # _@param_ `footer_key_metadata` — key metadata of the footer key
      # 
      # _@param_ `plaintext_footer` — whether the footer is stored in the clear
      sig do
        params(
          config: T.nilable(DecryptionConfiguration),
          algorithm: T.nilable(Format::EncryptionAlgorithm),
          footer_key_metadata: T.nilable(String),
          plaintext_footer: T::Boolean
        ).void
      end
      def initialize(config, algorithm, footer_key_metadata: nil, plaintext_footer: false); end

      # _@return_ — +:aes_gcm+ or +:aes_gcm_ctr+
      sig { returns(Symbol) }
      def algorithm_name; end

      # _@return_ — the AAD prefix stored in the file
      sig { returns(T.nilable(String)) }
      def aad_prefix; end

      # _@return_ — whether the footer signature was checked (plaintext footers, with the key)
      sig { returns(T::Boolean) }
      def footer_verified?; end

      # _@return_ — the footer key, given or looked up; nil when not available
      sig { returns(T.nilable(String)) }
      def footer_key; end

      # _@param_ `mod` — the encrypted footer module
      # 
      # _@return_ — the serialized FileMetaData
      sig { params(mod: String).returns(String) }
      def decrypt_footer(mod); end

      # Checks the signature of a plaintext footer, when the footer key is available (without it
      # the file is read like a legacy reader would)
      # 
      # _@param_ `plain` — the serialized FileMetaData
      # 
      # _@param_ `signature` — nonce and tag stored after it
      sig { params(plain: String, signature: String).void }
      def verify_footer(plain, signature); end

      # Replaces the +meta_data+ of chunks whose ColumnMetaData is encrypted on its own, when
      # their key is available
      # 
      # _@param_ `meta` — the decoded footer, changed in place
      sig { params(meta: Format::FileMetaData).void }
      def decrypt_column_metadata(meta); end

      # _@param_ `row_group` — row group index in the footer
      # 
      # _@param_ `ordinal` — the row group's ordinal from the footer
      # 
      # _@param_ `column` — the leaf column
      # 
      # _@param_ `chunk` — its chunk in the row group
      # 
      # _@return_ — decryption of the chunk's modules, nil for a plaintext chunk
      sig do
        params(
          row_group: Integer,
          ordinal: T.nilable(Integer),
          column: Schema::Column,
          chunk: Format::ColumnChunk
        ).returns(T.nilable(ModuleCrypto))
      end
      def chunk(row_group, ordinal, column, chunk); end

      # How the file is encrypted, see Reader#encryption
      # 
      # _@param_ `schema` — the file's schema, to name the columns
      # 
      # _@param_ `chunks` — the column chunks of a row group
      sig { params(schema: Schema, chunks: T::Array[Format::ColumnChunk]).returns(T::Hash[Symbol, Object]) }
      def describe(schema, chunks); end

      # _@param_ `chunk` — the chunk's footer entry, with its crypto metadata
      # 
      # _@param_ `path` — its column's dotted path
      # 
      # _@return_ — the chunk's key, nil when it is not encrypted or the key is not available
      sig { params(chunk: Format::ColumnChunk, path: String).returns(T.nilable(String)) }
      def chunk_key(chunk, path); end

      # The configuration of a file encrypted like this one (see Redaction)
      # 
      # _@param_ `columns` — encrypted columns of the new file, as the +columns:+ setting; nil to encrypt them all with the footer key
      sig { params(columns: T.nilable(T::Hash[String, T.any(T::Hash[T.untyped, T.untyped], Symbol)])).returns(EncryptionConfiguration) }
      def writer_settings(columns); end

      # _@return_ — algorithm and footer mode, without keys
      sig { returns(String) }
      def inspect; end

      # _@param_ `chunk` — an encrypted chunk
      # 
      # _@param_ `path` — its column's dotted path
      # 
      # _@return_ — nil when the key is not available
      sig { params(chunk: Format::ColumnChunk, path: String).returns(T.nilable(Cipher)) }
      def chunk_cipher(chunk, path); end

      # _@param_ `path` — dotted column path
      # 
      # _@param_ `key_metadata` — the column's key metadata
      # 
      # _@return_ — the given key for the column (or a field holding it), else the
      # looked-up one
      sig { params(path: String, key_metadata: T.nilable(String)).returns(T.nilable(String)) }
      def column_key(path, key_metadata); end

      # _@param_ `key_metadata` — stored key metadata
      # 
      # _@param_ `owner` — what the key is for: +:footer+ or a dotted column path
      # 
      # _@return_ — the key from the +keys:+ resolver, nil when there is none. Keys
      # without key metadata are looked up per owner.
      sig { params(key_metadata: T.nilable(String), owner: T.any(Symbol, String)).returns(T.nilable(String)) }
      def resolve(key_metadata, owner); end

      # _@param_ `callable` — the +keys:+ resolver
      # 
      # _@return_ — whether it only takes the key metadata (procs drop extra arguments)
      sig { params(callable: T.untyped).returns(T::Boolean) }
      def one_argument?(callable); end

      # _@param_ `key` — 16, 24 or 32 bytes
      # 
      # _@return_ — one per distinct key
      sig { params(key: String).returns(Cipher) }
      def cipher_for(key); end

      # Dotted paths of the leaf columns, by column ordinal
      # 
      # _@param_ `meta` — the footer
      sig { params(meta: Format::FileMetaData).returns(T::Array[String]) }
      def column_paths(meta); end

      # _@param_ `path` — dotted column path
      # 
      # _@param_ `chunk` — the encrypted chunk whose key is missing
      # 
      # _@return_ — what is missing, and how to give it
      sig { params(path: String, chunk: Format::ColumnChunk).returns(String) }
      def missing_key(path, chunk); end

      # _@return_ — the file's algorithm
      sig { returns(Format::EncryptionAlgorithm) }
      attr_reader :algorithm

      # _@return_ — key metadata of the footer key
      sig { returns(T.nilable(String)) }
      attr_reader :footer_key_metadata

      # _@return_ — whether the footer is stored in the clear (and signed)
      sig { returns(T::Boolean) }
      attr_reader :plaintext_footer
    end
  end

  # Renders a Parquet file's layout as one self-contained HTML page: a to-scale byte map of the
  # file (row groups, column chunks, dictionary and data pages, page indexes, bloom filters,
  # footer), the schema, per-column and per-page tables, page indexes and key/value metadata.
  # CSS, JS and data are inline; the only external resource is highlight.js from cdnjs, used to
  # colour JSON (the page works without it).
  # 
  # The design and idea come from Parquet X-ray by cfahlgren1
  # (https://huggingface.co/spaces/cfahlgren1/parquet-xray), credited at the top of every page.
  # 
  # Used through Inspector#to_html:
  # 
  #   File.open("data.parquet", "rb") { |io| Herringbone::Inspector.new(io).to_html }
  # 
  # @api private
  class Visualizer
    # +inspector+ is an Inspector. +title+ defaults to the file's name.
    # 
    # _@param_ `inspector` — inspector over the file to render
    # 
    # _@param_ `title` — page title; defaults to the file's name
    # 
    # _@param_ `max_pages` — page budget for per-page detail (see MAX_PAGES)
    sig { params(inspector: Inspector, title: T.nilable(String), max_pages: Integer).void }
    def initialize(inspector, title: nil, max_pages: MAX_PAGES); end

    # Builds the page. Walks every page header of the file (and reads the page indexes).
    # 
    # _@return_ — a complete, self-contained HTML document
    sig { returns(String) }
    def to_html; end

    # The data embedded in the page
    # 
    # _@return_ — file, schema, columns, row groups (with chunks and pages),
    # key/value metadata and footer JSON, ready for JSON.generate
    sig { returns(T::Hash[Symbol, Object]) }
    def payload; end

    # Inspector#summary plus the display name and whether per-page detail was truncated.
    # 
    # _@return_ — file-level facts for the page header
    sig { returns(T::Hash[Symbol, Object]) }
    def file_info; end

    # One leaf column with its totals over all row groups.
    # 
    # _@param_ `col` — leaf column
    # 
    # _@param_ `t` — the column's entry from Inspector#column_totals
    # 
    # _@return_ — column row, keyed with the short names the JS uses
    sig { params(col: Schema::Column, t: T::Hash[Symbol, Object]).returns(T::Hash[Symbol, Object]) }
    def column_info(col, t); end

    # One column chunk: its metadata, statistics and index ranges and, when +with_pages+, its page
    # rows, ColumnIndex and OffsetIndex.
    # 
    # _@param_ `c` — chunk to describe
    # 
    # _@param_ `with_pages` — whether to include per-page detail (false once over the page budget)
    # 
    # _@return_ — JSON-safe chunk entry, nil members omitted
    sig { params(c: Inspector::ColumnChunkInfo, with_pages: T::Boolean).returns(T::Hash[Symbol, Object]) }
    def chunk_info(c, with_pages); end

    # _@param_ `st` — chunk statistics
    # 
    # _@return_ — statistics with min/max in display form, nil members omitted
    sig { params(st: Inspector::Stats).returns(T::Hash[Symbol, Object]) }
    def stats_info(st); end

    # [type, offset, header_size, compressed, uncompressed, values, nulls, rows, first_row, encoding,
    #  min, max, crc, extra]; crc is 0 (none), 1 (present, not verified), 2 (verified ok) or 3 (mismatch)
    # 
    # _@param_ `p` — page header to describe
    # 
    # _@return_ — the page row, compact so pages of large files stay small
    sig { params(p: Inspector::PageInfo).returns(T::Array[T.untyped]) }
    def page_row(p); end

    # A page statistics vs ColumnIndex disagreement as a compact row.
    # 
    # _@param_ `m` — entry from Inspector::ColumnChunkInfo#index_mismatches
    # 
    # _@return_ — [page, field, value in page header, value in column index]; min/max in display form
    sig { params(m: T::Hash[Symbol, Object]).returns(T::Array[T.untyped]) }
    def mismatch_row(m); end

    # Display form of a decoded statistics value: strings quoted, the rest as text
    # 
    # _@param_ `v` — decoded value (String, numeric, Time, Date, Array, ...)
    # 
    # _@return_ — at most 160 characters, nil for nil
    sig { params(v: T.nilable(Object)).returns(T.nilable(String)) }
    def disp(v); end

    # The footer FileMetaData pretty-printed, or nil when it exceeds MAX_FOOTER_JSON bytes.
    # 
    # _@return_ — JSON text
    sig { returns(T.nilable(String)) }
    def footer_json; end

    # Footer structs as plain data; binary statistics as hex, long strings shortened
    # 
    # _@param_ `v` — a value from FileMetaData#to_h (Hash, Array, String or scalar)
    # 
    # _@return_ — +v+ with every String passed through Inspector.text and cut at 300 characters
    sig { params(v: Object).returns(Object) }
    def raw(v); end

    # _@param_ `s` — text to put into HTML (converted with to_s)
    # 
    # _@return_ — +s+ with &, <, > and double quotes escaped
    sig { params(s: Object).returns(String) }
    def escape_html(s); end
  end

  # Compact buffer for the values of a BYTE_ARRAY or FIXED_LEN_BYTE_ARRAY column while a row
  # group is being collected. Instead of holding on to one Ruby String per value, it either
  # 
  # * dictionary-encodes values as they arrive (keeping each distinct value once, plus an Integer
  #   index per value), which suits low-cardinality columns such as enums and statuses, or
  # * appends the raw bytes to one binary String (plus a length per value for BYTE_ARRAY).
  # 
  # It starts out in dictionary mode (when allowed) and switches to raw bytes once the dictionary
  # grows too large or too many values turn out to be distinct. Strings are only rebuilt when the
  # row group is flushed, one column at a time.
  # 
  # @api private
  class ByteValues
    # _@param_ `width` — byte length of each value for FIXED_LEN_BYTE_ARRAY, nil for BYTE_ARRAY
    # 
    # _@param_ `dictionary` — start in dictionary mode; false appends raw bytes from the start
    sig { params(width: T.nilable(Integer), dictionary: T::Boolean).void }
    def initialize(width: nil, dictionary: true); end

    # _@return_ — number of values held
    sig { returns(Integer) }
    def size; end

    # _@return_ — true when no values are held
    sig { returns(T::Boolean) }
    def empty?; end

    # _@return_ — true while still dictionary-encoding (not yet switched to raw bytes)
    sig { returns(T::Boolean) }
    def dictionary?; end

    # Short summary for the console, without the values
    # 
    # _@return_ — value count, the dictionary size (or "raw" after switching to raw bytes),
    # the width for FIXED_LEN_BYTE_ARRAY and the estimated memory
    sig { returns(String) }
    def inspect; end

    # Appends a value, switching to raw bytes when the dictionary limits are exceeded.
    # 
    # _@param_ `value` — bytes of the value; for FIXED_LEN_BYTE_ARRAY it must be +width+ bytes long (not checked here)
    # 
    # _@return_ — self
    sig { params(value: String).returns(ByteValues) }
    def <<(value); end

    # Removes the last value
    sig { void }
    def pop; end

    # Supports the `slice!(n..)` form used to roll back a failed row
    # 
    # _@param_ `range` — endless range; values from +range.begin+ on are dropped
    sig { params(range: T::Range[T.untyped]).void }
    def slice!(range); end

    # Approximate memory held, used to size row groups
    # 
    # _@return_ — estimated bytes
    sig { returns(Integer) }
    def memory_bytes; end

    # Returns [:dictionary, values, indices] when the column is worth dictionary-encoding,
    # otherwise [:plain, values]
    # 
    # Dictionary encoding is kept unless there are more than 16 values and more than about half
    # of them are distinct.
    # 
    # _@return_ — distinct values and an index per value, or all values in order
    sig { returns(T.any([Symbol, T::Array[String], T::Array[Integer]], [Symbol, T::Array[String]])) }
    def materialize; end

    # Appends +value+ in raw-bytes mode, recording its length for BYTE_ARRAY.
    # 
    # _@param_ `value` — bytes of the value, in any encoding
    # 
    # _@return_ — self
    sig { params(value: String).returns(ByteValues) }
    def append_bytes(value); end

    # Leaves dictionary mode, re-appending every value held so far as raw bytes.
    sig { void }
    def switch_to_bytes; end

    # Drops all values after the first +n+.
    # 
    # _@param_ `n` — number of values to keep
    sig { params(n: Integer).void }
    def truncate(n); end

    # Splits the raw bytes back into one binary String per value.
    sig { returns(T::Array[String]) }
    def strings; end
  end

  # Raised when a file uses (or a writer asks for) a codec whose library is not loaded
  class MissingCodecError < Herringbone::UnsupportedError
    # _@param_ `codec` — codec name, as shown in the message
    # 
    # _@param_ `gem_name` — gem to add to the Gemfile
    # 
    # _@param_ `path` — what to require to load the gem
    sig { params(codec: String, gem_name: String, path: String).void }
    def initialize(codec, gem_name, path); end

    # _@return_ — codec name (+"ZSTD"+) and name of the gem providing it (+"zstd-ruby"+)
    sig { returns(String) }
    attr_reader :codec

    # _@return_ — codec name (+"ZSTD"+) and name of the gem providing it (+"zstd-ruby"+)
    sig { returns(String) }
    attr_reader :gem_name
  end

  # Dispatches page (de)compression by Parquet codec id. Snappy and LZ4 are pure Ruby and GZIP
  # uses zlib, so those always work. LZO is pure Ruby too, but can only be read. ZSTD and Brotli
  # come from optional gems (zstd-ruby, brotli), which the application requires; if they are
  # not loaded, MissingCodecError says what to add.
  # (Snappy also uses the optional snappy gem when it is loaded, see Codecs::Snappy.)
  # 
  # @api private
  module Compression
    # The library module for a codec backed by an optional gem
    # 
    # _@param_ `codec` — a codec id that is a key of LIBRARIES
    # 
    # _@return_ — the gem's module (+Zstd+ or +Brotli+)
    sig { params(codec: Integer).returns(Module) }
    def library(codec); end

    # The library module for a codec backed by an optional gem
    # 
    # _@param_ `codec` — a codec id that is a key of LIBRARIES
    # 
    # _@return_ — the gem's module (+Zstd+ or +Brotli+)
    sig { params(codec: Integer).returns(Module) }
    def self.library(codec); end

    # A separate method so tests can stub it to simulate a missing gem
    # 
    # _@param_ `const` — top-level constant the gem defines
    # 
    # _@return_ — the gem's module, nil when it is not loaded
    sig { params(const: Symbol).returns(T.nilable(Module)) }
    def loaded_library(const); end

    # A separate method so tests can stub it to simulate a missing gem
    # 
    # _@param_ `const` — top-level constant the gem defines
    # 
    # _@return_ — the gem's module, nil when it is not loaded
    sig { params(const: Symbol).returns(T.nilable(Module)) }
    def self.loaded_library(const); end

    # Raises MissingCodecError (or UnsupportedError) unless +codec+ can be used
    # 
    # _@param_ `codec` — codec id or name (see NAMES)
    # 
    # _@return_ — the gem's module for a gem-backed codec, nil for a built-in one
    sig { params(codec: T.any(Integer, Symbol, String)).returns(T.nilable(Module)) }
    def ensure_available!(codec); end

    # Raises MissingCodecError (or UnsupportedError) unless +codec+ can be used
    # 
    # _@param_ `codec` — codec id or name (see NAMES)
    # 
    # _@return_ — the gem's module for a gem-backed codec, nil for a built-in one
    sig { params(codec: T.any(Integer, Symbol, String)).returns(T.nilable(Module)) }
    def self.ensure_available!(codec); end

    # Checks that +codec+ takes a compression level and that +level+ is in its range
    # 
    # _@param_ `codec` — Format::Codec id
    # 
    # _@param_ `level` — compression level, nil for the codec's default
    # 
    # _@return_ — the level
    sig { params(codec: Integer, level: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def check_level!(codec, level); end

    # Checks that +codec+ takes a compression level and that +level+ is in its range
    # 
    # _@param_ `codec` — Format::Codec id
    # 
    # _@param_ `level` — compression level, nil for the codec's default
    # 
    # _@return_ — the level
    sig { params(codec: Integer, level: T.nilable(Integer)).returns(T.nilable(Integer)) }
    def self.check_level!(codec, level); end

    # Codec id for a codec name; Integers are taken to be ids already and returned unchecked
    # 
    # _@param_ `name` — codec id, or a name from NAMES (case-insensitive)
    # 
    # _@return_ — the Format::Codec id
    sig { params(name: T.any(Integer, Symbol, String)).returns(Integer) }
    def codec_id(name); end

    # Codec id for a codec name; Integers are taken to be ids already and returned unchecked
    # 
    # _@param_ `name` — codec id, or a name from NAMES (case-insensitive)
    # 
    # _@return_ — the Format::Codec id
    sig { params(name: T.any(Integer, Symbol, String)).returns(Integer) }
    def self.codec_id(name); end

    # Decompresses a page body, checking the result against the size the page header declares
    # 
    # _@param_ `codec` — Format::Codec id from the column chunk metadata
    # 
    # _@param_ `data` — compressed bytes
    # 
    # _@param_ `uncompressed_size` — expected decompressed size in bytes
    # 
    # _@return_ — decompressed bytes (binary)
    sig { params(codec: Integer, data: String, uncompressed_size: Integer).returns(String) }
    def decompress(codec, data, uncompressed_size); end

    # Decompresses a page body, checking the result against the size the page header declares
    # 
    # _@param_ `codec` — Format::Codec id from the column chunk metadata
    # 
    # _@param_ `data` — compressed bytes
    # 
    # _@param_ `uncompressed_size` — expected decompressed size in bytes
    # 
    # _@return_ — decompressed bytes (binary)
    sig { params(codec: Integer, data: String, uncompressed_size: Integer).returns(String) }
    def self.decompress(codec, data, uncompressed_size); end

    # Compresses a page body. Given several Strings, compresses their concatenation; GZIP, ZSTD
    # and Snappy take them one by one, the other codecs join them first.
    # 
    # _@param_ `codec` — Format::Codec id
    # 
    # _@param_ `data` — bytes to compress, or the parts of them
    # 
    # _@param_ `level` — compression level checked with check_level!, nil for the default
    # 
    # _@return_ — compressed bytes (binary)
    sig { params(codec: Integer, data: T.any(String, T::Array[String]), level: T.nilable(Integer)).returns(String) }
    def compress(codec, data, level = nil); end

    # Compresses a page body. Given several Strings, compresses their concatenation; GZIP, ZSTD
    # and Snappy take them one by one, the other codecs join them first.
    # 
    # _@param_ `codec` — Format::Codec id
    # 
    # _@param_ `data` — bytes to compress, or the parts of them
    # 
    # _@param_ `level` — compression level checked with check_level!, nil for the default
    # 
    # _@return_ — compressed bytes (binary)
    sig { params(codec: Integer, data: T.any(String, T::Array[String]), level: T.nilable(Integer)).returns(String) }
    def self.compress(codec, data, level = nil); end

    # A gzip member with no file name and a zero mtime, like Zlib.gzip makes
    # 
    # _@param_ `parts` — bytes to compress, in order
    # 
    # _@param_ `level` — zlib level, nil for the default
    # 
    # _@return_ — gzip data
    sig { params(parts: T::Array[String], level: T.nilable(Integer)).returns(String) }
    def gzip(parts, level); end

    # A gzip member with no file name and a zero mtime, like Zlib.gzip makes
    # 
    # _@param_ `parts` — bytes to compress, in order
    # 
    # _@param_ `level` — zlib level, nil for the default
    # 
    # _@return_ — gzip data
    sig { params(parts: T::Array[String], level: T.nilable(Integer)).returns(String) }
    def self.gzip(parts, level); end

    # _@param_ `parts` — bytes to compress, in order
    # 
    # _@param_ `level` — zstd level, nil for the default
    # 
    # _@return_ — a single zstd frame
    sig { params(parts: T::Array[String], level: T.nilable(Integer)).returns(String) }
    def zstd(parts, level); end

    # _@param_ `parts` — bytes to compress, in order
    # 
    # _@param_ `level` — zstd level, nil for the default
    # 
    # _@return_ — a single zstd frame
    sig { params(parts: T::Array[String], level: T.nilable(Integer)).returns(String) }
    def self.zstd(parts, level); end

    # Codec output relabelled as binary without copying it, unless it is frozen
    # 
    # _@param_ `str` — bytes
    # 
    # _@return_ — +str+ or a binary copy of it
    sig { params(str: String).returns(String) }
    def binary(str); end

    # Codec output relabelled as binary without copying it, unless it is frozen
    # 
    # _@param_ `str` — bytes
    # 
    # _@return_ — +str+ or a binary copy of it
    sig { params(str: String).returns(String) }
    def self.binary(str); end

    # Handles files whose gzip data consists of several concatenated members
    # 
    # _@param_ `data` — gzip data, one or more members
    # 
    # _@return_ — the members' decompressed bytes concatenated (binary)
    sig { params(data: String).returns(String) }
    def gunzip(data); end

    # Handles files whose gzip data consists of several concatenated members
    # 
    # _@param_ `data` — gzip data, one or more members
    # 
    # _@return_ — the members' decompressed bytes concatenated (binary)
    sig { params(data: String).returns(String) }
    def self.gunzip(data); end
  end

  # A Parquet Split Block Bloom Filter (parquet-format BloomFilter.md).
  # 
  # The bitset is made of 32-byte blocks of eight 32-bit words. A value is hashed with XXH64 over
  # the PLAIN encoding of its physical value (without the length prefix for BYTE_ARRAY); the upper
  # 32 bits of the hash pick a block, and the lower 32 bits set one bit in each of its words.
  # 
  # A filter answers "definitely not in the column chunk" or "maybe": +might_contain?+ never
  # returns false for a value that was inserted. Values are given as Ruby values and converted
  # like the writer converts them (the column's encoder), so a Date, Time, BigDecimal or UUID
  # String hashes the same bytes as the stored value. Nulls are never in a bloom filter.
  # The writer builds them (bloom_filters: option) and reads with where: consult them.
  # 
  # @api private
  class BloomFilter
    # Bitset size in bytes for +ndv+ distinct values at false positive probability +fpp+, per the
    # spec's formula (m = -8 * ndv / ln(1 - fpp ** (1/8)) bits), rounded up to a power of two
    # and clamped to MIN_BYTES..max_bytes
    # 
    # _@param_ `ndv` — expected number of distinct values (values below 1 count as 1)
    # 
    # _@param_ `fpp` — false positive probability, strictly between 0 and 1
    # 
    # _@param_ `max_bytes` — upper bound, clamped to MIN_BYTES..MAX_BYTES and rounded down to a power of two
    # 
    # _@return_ — bitset size in bytes, a power of two
    sig { params(ndv: Integer, fpp: Float, max_bytes: Integer).returns(Integer) }
    def self.optimal_num_bytes(ndv, fpp = DEFAULT_FPP, max_bytes: DEFAULT_MAX_BYTES); end

    # XXH64 of the PLAIN encoding of a physical value of +type+ (as the column encoders produce it)
    # 
    # _@param_ `value` — the physical value; for INT96 the +[nanos_of_day, julian_day]+ pair the encoder produces
    # 
    # _@param_ `type` — Format::Type physical type
    # 
    # _@return_ — the unsigned 64-bit hash
    sig { params(value: T.any(Integer, Float, String, T::Array[Integer]), type: Integer).returns(Integer) }
    def self.hash_physical(value, type); end

    # Hashes of many physical values of +type+, converting them in bulk. With +distinct+, each
    # distinct physical value is hashed once (floats are compared by their bytes, so -0.0 and 0.0,
    # or NaNs with different payloads, stay apart as they hash differently).
    # 
    # _@param_ `values` — physical values, as for .hash_physical
    # 
    # _@param_ `type` — Format::Type physical type
    # 
    # _@param_ `distinct` — hash each distinct value once (the result is then shorter)
    # 
    # _@return_ — the unsigned 64-bit hashes
    sig { params(values: T::Array[T.untyped], type: Integer, distinct: T::Boolean).returns(T::Array[Integer]) }
    def self.hash_physical_all(values, type, distinct: false); end

    # Reads a filter (header and bitset) from +buf+ at +pos+. Returns nil for algorithms, hashes
    # or compressions this implementation does not know.
    # 
    # _@param_ `buf` — bytes holding the BloomFilterHeader followed by the bitset
    # 
    # _@param_ `pos` — byte offset of the header in +buf+
    # 
    # _@param_ `column` — column the filter belongs to, for converting values
    # 
    # _@return_ — the filter, or nil when it is of an unsupported kind
    sig { params(buf: String, pos: Integer, column: T.nilable(Schema::Column)).returns(T.nilable(BloomFilter)) }
    def self.decode(buf, pos = 0, column: nil); end

    # Whether a header describes a filter this implementation can read: split block algorithm,
    # XXH64, uncompressed, and a size that is a multiple of 32 bytes up to MAX_BYTES
    # 
    # _@param_ `header` — decoded header
    # 
    # _@return_ — true when supported
    sig { params(header: Format::BloomFilterHeader).returns(T::Boolean) }
    def self.supported_header?(header); end

    # A filter of +num_bytes+ (a multiple of 32, normally a power of two), or one using an existing
    # +bitset+ String. With a +column+ (a Schema::Column), values are Ruby values converted with
    # the column's encoder; without one, values must be Strings and their bytes are hashed.
    # 
    # _@param_ `num_bytes` — bitset size for an empty filter (MIN_BYTES when nil); ignored with +bitset+
    # 
    # _@param_ `bitset` — existing bitset (little-endian 32-bit words)
    # 
    # _@param_ `column` — column the filter is for
    sig { params(num_bytes: T.nilable(Integer), bitset: T.nilable(String), column: T.nilable(Schema::Column)).void }
    def initialize(num_bytes = nil, bitset: nil, column: nil); end

    # _@return_ — bitset size in bytes
    sig { returns(Integer) }
    def num_bytes; end

    # Adds a value to the filter
    # 
    # _@param_ `value` — Ruby value, converted with the column's encoder (a String without a column)
    # 
    # _@return_ — self
    sig { params(value: Object).returns(BloomFilter) }
    def insert(value); end

    # Whether the value may be in the filter. Never false for an inserted value; true for a
    # value that was not inserted with about the false positive probability the filter was sized for.
    # 
    # _@param_ `value` — Ruby value, converted with the column's encoder (a String without a column)
    # 
    # _@return_ — false when the value is definitely absent
    sig { params(value: Object).returns(T::Boolean) }
    def might_contain?(value); end

    # XXH64 hash the filter uses for a Ruby +value+
    # 
    # _@param_ `value` — Ruby value, converted with the column's encoder (a String without a column)
    # 
    # _@return_ — the unsigned 64-bit hash
    sig { params(value: Object).returns(Integer) }
    def hash_of(value); end

    # Sets the bits for a hash: the upper 32 bits pick the block, the lower 32 bits (multiplied
    # by each salt) one bit in each of its eight words
    # 
    # _@param_ `h` — unsigned 64-bit XXH64 hash
    # 
    # _@return_ — self
    sig { params(h: Integer).returns(BloomFilter) }
    def insert_hash(h); end

    # Inserts many hashes at once: faster than insert_hash, as the hashes (mostly Bignums) are
    # split into 32-bit halves in bulk and the rest is Fixnum arithmetic
    # 
    # _@param_ `hashes` — unsigned 64-bit XXH64 hashes
    # 
    # _@return_ — self
    sig { params(hashes: T::Array[Integer]).returns(BloomFilter) }
    def insert_hashes(hashes); end

    # Whether all the bits for a hash are set (see #insert_hash)
    # 
    # _@param_ `h` — unsigned 64-bit XXH64 hash
    # 
    # _@return_ — false when the hashed value is definitely absent
    sig { params(h: Integer).returns(T::Boolean) }
    def might_contain_hash?(h); end

    # The raw bitset (little-endian 32-bit words)
    # 
    # _@return_ — binary String of #num_bytes bytes
    sig { returns(String) }
    def bitset; end

    # Header and bitset, as stored in a Parquet file
    # 
    # _@return_ — Thrift-encoded BloomFilterHeader followed by the bitset (binary)
    sig { returns(String) }
    def encode; end

    # _@return_ — size and, when set, the column's dotted path
    sig { returns(String) }
    def inspect; end

    # Header for this filter: split block algorithm, XXH64 hash, uncompressed
    # 
    # _@return_ — the header
    sig { returns(Format::BloomFilterHeader) }
    def header; end

    # _@return_ — column whose encoder converts values, nil for raw Strings
    sig { returns(T.nilable(Schema::Column)) }
    attr_reader :column
  end

  # Writes Parquet the way the CSV gem writes CSV: name the columns, then append rows as Arrays.
  # The column types are inferred from the first Schema::INFER_SAMPLE rows (see Schema.infer), so
  # no schema has to be declared.
  # 
  #   File.open("people.parquet", "wb") do |file|
  #     Herringbone::SimpleWriter.open(file) do |sw|
  #       sw.headers!(:id, :name, :age)
  #       sw << [123, "John", 12]
  #       sw << { id: 124, name: "Jane" } # Hashes work too; missing columns are nulls
  #     end
  #   end
  # 
  # Every column is nullable. A column that is nil in every sampled row becomes a string, and a file
  # with headers but no rows has only string columns. Only the sample is held in memory; later rows
  # are written as they come. A row that does not fit the inferred types raises SchemaMismatch,
  # explaining what was inferred and how to declare the column, and the writer stops there (the
  # file is left without a footer). Unlike CSV, the headers are mandatory: a Parquet file always
  # has named columns.
  # 
  # Columns declared in a block (Schema::Builder DSL) replace inferred ones, e.g. for a column that
  # holds both numbers and text:
  # 
  #   Herringbone::SimpleWriter.new(io) { |s| s.string :code }
  # 
  # #encrypt! encrypts the file with one key (see Key):
  # 
  #   Herringbone::SimpleWriter.open(file) do |sw|
  #     sw.encrypt!(key: ENV["PARQUET_KEY"]) # the key's hex, or a Herringbone::Key
  #     sw.headers!(:id, :name)
  #     sw << [1, "John"]
  #   end
  class SimpleWriter
    # Opens a writer, yields it and closes it, finishing the file. If the block raises, the file is
    # left unfinished (no footer), as with Writer.open. To declare columns, use #initialize and #close.
    # 
    # _@param_ `io` — destination; written sequentially, never closed
    # 
    # _@param_ `options` — Writer options (compression:, row_group_bytes:...)
    # 
    # _@return_ — the writer without a block, the block's value with one
    sig { params(io: T.any(IO, T.untyped), options: T::Hash[Symbol, Object], blk: T.proc.params(writer: SimpleWriter).returns(Object)).returns(T.any(SimpleWriter, Object)) }
    def self.open(io, **options, &blk); end

    # _@param_ `io` — destination; nothing is written to it until the column types are known
    # 
    # _@param_ `options` — Writer options (compression:, row_group_bytes:...)
    sig { params(io: T.any(IO, T.untyped), options: T::Hash[Symbol, Object], overrides: T.proc.params(s: Schema::Builder).void).void }
    def initialize(io, **options, &overrides); end

    # Names the columns, in the order row Arrays list their values. Must be called once, before
    # the first row.
    # 
    # _@param_ `names` — column names
    sig { params(names: T::Array[T.any(String, Symbol)]).returns(T.self_type) }
    def headers!(*names); end

    # Encrypts the file with one key, the way most Parquet readers can decrypt with that key (see
    # EncryptionConfiguration.simple). Must be called before the first row. For a new key, pass
    # +key: Herringbone::Key.generate+ and keep it (+key.hex+): the file can't be read without it.
    # 
    # _@param_ `key` — a key, or its hex (32 or 64 digits; raw bytes go through Key.new)
    # 
    # _@return_ — the key the file is encrypted with
    sig { params(key: T.any(Key, String)).returns(Key) }
    def encrypt!(key:); end

    # Appends a row: an Array with one value per header, in header order, or a Hash keyed by
    # header (String or Symbol keys; missing columns are nulls).
    # 
    # _@param_ `row`
    sig { params(row: T.any(T::Array[T.untyped], T::Hash[T.untyped, T.untyped])).returns(T.self_type) }
    def <<(row); end

    # _@return_ — rows written so far, including those held back to infer the column types
    sig { returns(Integer) }
    def rows_written; end

    # Writes any rows still held back and finishes the file. The IO is not closed.
    sig { void }
    def close; end

    # Stops without finishing the file. What was already written stays in the IO.
    sig { void }
    def abort; end

    # Short summary for the console, without the rows
    # 
    # _@return_ — the number of columns and the underlying writer's summary
    sig { returns(String) }
    def inspect; end

    # _@param_ `row` — row given to #<<
    # 
    # _@return_ — its values in header order
    sig { params(row: T.any(T::Array[T.untyped], T::Hash[T.untyped, T.untyped])).returns(T::Array[T.untyped]) }
    def values_of(row); end

    # _@param_ `sample` — held-back rows, values in header order
    # 
    # _@return_ — inferred from the sample; string columns when it is empty
    sig { params(sample: T::Array[T::Array[T.untyped]]).returns(Schema) }
    def schema_for(sample); end

    # _@return_ — the column names, nil until #headers! is called
    sig { returns(T.nilable(T::Array[String])) }
    attr_reader :headers
  end

  # Writes rows whose schema is inferred from the rows themselves, reading them only once: the
  # first Schema::INFER_SAMPLE rows are held back, the schema is built from them, and then they and
  # every later row go straight to a Writer. Memory is bounded by the sample, however many rows
  # follow it. Nothing is written to the IO before the schema is known, so a source that can only
  # be iterated once (a cursor, a queue, a lazy Enumerator over an IO) loses no rows.
  # 
  # A row that does not fit the inferred schema raises SchemaMismatch and stops the writer: the
  # file is left unfinished (no footer) rather than written with rows missing.
  # 
  # Used by Herringbone.write and SimpleWriter.
  # 
  # @api private
  class InferringWriter
    # _@param_ `io` — destination, passed to Writer.new
    # 
    # _@param_ `fix` — how a caller declares a column, for SchemaMismatch messages; +%s+ is replaced by a declaration such as +string :age+
    # 
    # _@param_ `options` — Writer options
    sig do
      params(
        io: T.any(IO, T.untyped),
        fix: String,
        options: T::Hash[Symbol, Object],
        schema_for: T.proc.params(sample: T::Array[T.untyped]).returns(Schema)
      ).void
    end
    def initialize(io, fix:, **options, &schema_for); end

    # _@param_ `row` — row to write, in any form the Writer accepts
    sig { params(row: Object).returns(T.self_type) }
    def <<(row); end

    # Sets the encryption before the first row
    # 
    # _@param_ `config` — how to encrypt the file
    sig { params(config: EncryptionConfiguration).void }
    def encryption=(config); end

    # _@return_ — rows accepted so far, including the ones held back
    sig { returns(Integer) }
    def rows_written; end

    # Writes the held-back rows if the sample never filled up, then finishes the file
    sig { void }
    def close; end

    # Stops without finishing the file; when the schema was never built nothing was written at all
    sig { void }
    def abort; end

    # Short summary for the console, without the held-back rows
    # 
    # _@return_ — the number of rows held back, or the Writer's summary once it is open
    sig { returns(String) }
    def inspect; end

    # Builds the schema from the held-back rows, opens the Writer and writes them
    sig { void }
    def start; end

    # _@param_ `row` — row for the Writer
    sig { params(row: Object).void }
    def write(row); end

    sig { void }
    def check_usable!; end

    # A multi-line explanation of an EncodeError against the inferred schema
    # 
    # _@param_ `error` — error raised by the Writer
    sig { params(error: EncodeError).returns(String) }
    def explain(error); end

    # _@param_ `column` — leaf column
    # 
    # _@return_ — its type as the Builder DSL names it, e.g. "int64" or "timestamp (micros)"
    sig { params(column: Schema::Column).returns(String) }
    def describe(column); end

    # A Builder DSL declaration whose type can hold +value+, to suggest in the explanation
    # 
    # _@param_ `name` — top-level field name
    # 
    # _@param_ `value` — the value that did not fit
    # 
    # _@return_ — e.g. "string :age"
    sig { params(name: String, value: Object).returns(String) }
    def declaration_for(name, value); end
  end

  # IO::Buffer lets the decompressors copy bytes around without allocating a String per copy.
  # It still carries an "experimental" warning, which is silenced once here: the gem only uses
  # new/for/copy/get_string/free, and falls back to String operations where it is missing.
  # 
  # @api private
  module IOBufferSupport
  end

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
    # Wraps +io+, unless it is already wrapped
    # 
    # _@param_ `io` — anything responding to #read and #seek
    # 
    # _@return_ — +io+ itself when it is one, a new wrapper of it otherwise
    sig { params(io: T.any(IO, StringIO, RestrictedReadableIO, T.untyped)).returns(RestrictedReadableIO) }
    def self.wrap(io); end

    # _@param_ `io` — anything responding to #read and #seek
    sig { params(io: T.any(IO, StringIO, T.untyped)).void }
    def initialize(io); end

    # Reads up to +n_bytes+ from the current position
    # 
    # _@param_ `n_bytes` — bytes wanted
    # 
    # _@return_ — at most +n_bytes+, fewer when the end of the IO comes first; nil at the end
    sig { params(n_bytes: Integer).returns(T.nilable(String)) }
    def read(n_bytes); end

    # Moves to +offset+ bytes from the start of the IO
    # 
    # _@param_ `offset` — absolute position
    # 
    # _@return_ — 0, as IO#seek returns
    sig { params(offset: Integer).returns(Integer) }
    def seek(offset); end

    # _@return_ — the current position, in bytes from the start of the IO
    sig { returns(Integer) }
    def pos; end

    # Size of the IO in bytes, asked of the IO when it can tell (File, StringIO, Tempfile...) and
    # found by seeking to its end otherwise
    # 
    # _@return_ — the size in bytes
    sig { returns(Integer) }
    def size; end

    # _@return_ — the path of the IO (File#path, Tempfile#path), or UNTITLED when it has none
    sig { returns(String) }
    def path; end

    # _@return_ — e.g. "#<Herringbone::RestrictedReadableIO data.parquet>"
    sig { returns(String) }
    def inspect; end
  end

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
    # Encryption that the most Parquet readers can decrypt given nothing but the key: every
    # column and the footer encrypted with one key, AES_GCM_V1, no AAD prefix. The key's id is
    # stored in the file, so a reader holding several keys picks the right one. Passing a Key or
    # the hex of a key as +encryption:+ does the same.
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
    # _@param_ `key` — the key, or its hex (the id is then the key's fingerprint)
    sig { params(key: T.any(Key, String)).returns(EncryptionConfiguration) }
    def self.simple(key); end

    # Turns the +encryption:+ option into a configuration
    # 
    # _@param_ `value` — a configuration, the keywords of #initialize, or a key or its hex (see .simple)
    sig { params(value: T.any(EncryptionConfiguration, T::Hash[T.any(Symbol, String), Object], Key, String)).returns(EncryptionConfiguration) }
    def self.from(value); end

    # _@param_ `footer_key` — the key, or 16, 24 or 32 bytes (AES-128, 192 or 256); required
    # 
    # _@param_ `footer_key_metadata` — stored in the file for the footer key; defaults to the id of a Key
    # 
    # _@param_ `columns` — column path (+"address.city"+) or field name (all of its columns) => a Key (stored with its id), the bytes of a key, +{key:, key_metadata:}+, or +:footer+ for the footer key. Columns left out are not encrypted; nil encrypts them all with the footer key.
    # 
    # _@param_ `plaintext_footer` — store the footer in the clear (signed with the footer key), so readers without keys can read the plaintext columns; it then keeps no statistics of the encrypted columns
    # 
    # _@param_ `algorithm` — +:aes_gcm+ or +:aes_gcm_ctr+, which encrypts pages with AES-CTR: faster, but page contents are not authenticated
    # 
    # _@param_ `aad_prefix` — identity of the file (a table and partition name, say), which binds the encrypted modules to it
    # 
    # _@param_ `store_aad_prefix` — false leaves the AAD prefix out of the file, so readers must supply it
    sig do
      params(
        footer_key: T.nilable(T.any(Key, String)),
        footer_key_metadata: T.nilable(String),
        columns: T.nilable(T::Hash[T.any(String, Symbol, T::Array[String]), T.any(String, T::Hash[T.untyped, T.untyped], Symbol)]),
        plaintext_footer: T::Boolean,
        algorithm: Symbol,
        aad_prefix: T.nilable(String),
        store_aad_prefix: T::Boolean
      ).void
    end
    def initialize(footer_key: nil, footer_key_metadata: nil, columns: nil, plaintext_footer: false, algorithm: :aes_gcm, aad_prefix: nil, store_aad_prefix: true); end

    # _@return_ — whether the footer is stored in the clear (and signed)
    sig { returns(T::Boolean) }
    def plaintext_footer?; end

    # _@return_ — whether the file stores the AAD prefix (false: readers must supply it)
    sig { returns(T::Boolean) }
    def store_aad_prefix?; end

    # _@return_ — whether every column is encrypted with the footer key
    sig { returns(T::Boolean) }
    def uniform?; end

    # _@return_ — the settings as keywords of #initialize, keys included
    sig { returns(T::Hash[Symbol, Object]) }
    def to_h; end

    # _@param_ `other` — object to compare with
    # 
    # _@return_ — whether +other+ is a configuration with the same settings and keys
    sig { params(other: Object).returns(T::Boolean) }
    def ==(other); end

    # _@return_ — the settings, without keys
    sig { returns(String) }
    def inspect; end

    # _@param_ `columns` — the +columns:+ argument
    # 
    # _@return_ — frozen, keyed by dotted path or field name
    sig { params(columns: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, T.any(ColumnKey, Symbol)]) }
    def column_settings(columns); end

    # _@param_ `name` — the column
    # 
    # _@param_ `setting` — +key:+ and +key_metadata:+
    sig { params(name: String, setting: T::Hash[Symbol, Object]).returns(ColumnKey) }
    def column_key(name, setting); end

    # _@return_ — key of the footer, and of the columns encrypted with it (binary)
    sig { returns(String) }
    attr_reader :footer_key

    # _@return_ — stored for the footer key, for readers to find it by
    sig { returns(T.nilable(String)) }
    attr_reader :footer_key_metadata

    # _@return_ — column path or field name => its own key, or
    # +:footer+ for the footer key; nil when every column is encrypted with the footer key
    sig { returns(T.nilable(T::Hash[String, T.any(ColumnKey, Symbol)])) }
    attr_reader :columns

    # _@return_ — +:aes_gcm+ (AES_GCM_V1) or +:aes_gcm_ctr+ (AES_GCM_CTR_V1, pages with AES-CTR)
    sig { returns(Symbol) }
    attr_reader :algorithm

    # _@return_ — identity of the file, part of the AAD of every encrypted module
    sig { returns(T.nilable(String)) }
    attr_reader :aad_prefix

    # A column encrypted with a key of its own
    # 
    # @!attribute [r] key
    #   @return [String] 16, 24 or 32 bytes, binary
    # @!attribute [r] key_metadata
    #   @return [String, nil] stored with the column, for readers to find the key by
    class ColumnKey < Struct
      # _@return_ — the key metadata, without the key
      sig { returns(String) }
      def inspect; end

      # _@return_ — 16, 24 or 32 bytes, binary
      sig { returns(String) }
      attr_reader :key

      # _@return_ — stored with the column, for readers to find the key by
      sig { returns(T.nilable(String)) }
      attr_reader :key_metadata
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
    # Turns the +decryption:+ option into a configuration
    # 
    # A keyring (a Key, the hex of a key, or an Array of those) looks keys up by the id stored
    # in the file; a single key is also used when the file names no id or another one, as for
    # files from tools that store none.
    # 
    # _@param_ `value` — a configuration, the keywords of #initialize, a keyring, a callable to use as +keys:+, or nil
    # 
    # _@return_ — nil for nil
    sig { params(value: T.nilable(T.any(DecryptionConfiguration, T::Hash[T.any(Symbol, String), Object], Key, String, T::Array[T.any(Key, String)], T.untyped))).returns(T.nilable(DecryptionConfiguration)) }
    def self.from(value); end

    # _@param_ `footer_key` — 16, 24 or 32 bytes
    # 
    # _@param_ `columns` — column path or field name => key
    # 
    # _@param_ `keys` — key metadata (a Key's id) => key, for the keys not given above. A callable gets the key metadata stored for the key (nil when the file stores none) and, when it takes a second parameter, what the key is for: +:footer+ or the dotted path of the column. It returns the key (a Key or bytes), or nil when it is not available. Each key is looked up once per Reader.
    # 
    # _@param_ `aad_prefix` — the file's AAD prefix
    sig do
      params(
        footer_key: T.nilable(T.any(Key, String)),
        columns: T::Hash[T.any(String, Symbol, T::Array[String]), T.any(Key, String)],
        keys: T.nilable(T.any(T.untyped, T::Hash[String, T.any(Key, String)])),
        aad_prefix: T.nilable(String)
      ).void
    end
    def initialize(footer_key: nil, columns: {}, keys: nil, aad_prefix: nil); end

    # _@return_ — what is configured, without keys
    sig { returns(String) }
    def inspect; end

    # _@return_ — key of the footer (and of the columns encrypted with it), binary
    sig { returns(T.nilable(String)) }
    attr_reader :footer_key

    # _@return_ — column path or field name => key
    sig { returns(T::Hash[String, String]) }
    attr_reader :columns

    # _@return_ — looks keys up by their key metadata
    sig { returns(T.nilable(T.any(T.untyped, T::Hash[String, String]))) }
    attr_reader :keys

    # _@return_ — the file's AAD prefix: needed when the file does not store it, and
    # checked against the stored one otherwise
    sig { returns(T.nilable(String)) }
    attr_reader :aad_prefix
  end
end
