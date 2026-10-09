# Changelog

## Unreleased

- `Herringbone::Schema#union` (`+`) and `#intersect` (`&`) match fields by name at every level of
  nesting and widen their types without loss (int32 + int64 -> int64, uint32 + int8 -> int64,
  int32 + float -> double, millis + micros -> micros, string + binary -> binary).
- `Herringbone::IncompatibleSchema` lists every field two schemas cannot agree on, at once.
- `Herringbone::Schema#==` compares structure: field names, order, nullability, types, field ids
  and nesting.
- Writing allocates less: compressed pages are no longer copied before they reach the IO, and GZIP,
  ZSTD and pure-Ruby Snappy compress a page's levels and values without joining them first.

## 0.6.1

- `Herringbone::Reader` raises `Herringbone::FormatError` for forged metadata or page headers that
  made it loop endlessly, overflow the stack or raise `ArgumentError`, `RangeError` or
  `NoMemoryError`.

## 0.6.0

- `require "herringbone"` loads the rest of the gem on first use: under 1 ms instead of about
  40 ms, and reading or writing plain files no longer loads OpenSSL, the inspector or the
  redaction code. `Herringbone.eager_load!` loads everything, which Ractors need before Ruby 3.4.
- `compression_level:` sets the level for `:zstd`, `:gzip` and `:brotli` in `Herringbone::Writer`,
  `Herringbone.write`, `SimpleWriter` and `Herringbone.redact`.
- `Herringbone::Writer` (and `Herringbone.write`, `SimpleWriter`) take `encryption:` to write files
  with Parquet modular encryption: footer and per-column keys, encrypted or signed plaintext
  footer, AES-GCM or AES-GCM-CTR, AAD prefixes.
- `Herringbone::Key` (`Key.generate`, `Key.from_hex`) holds a key and its id: `encryption: key`
  encrypts a whole file with it the way most readers (pyarrow 25+, Arrow, arrow-rs, Spark, Trino)
  can decrypt, and `decryption: [key, older_key]` picks the key by the id stored in the file.
- `decryption:` takes a callable that returns the key for a key id.
- `Herringbone::SimpleWriter#encrypt!(key:)` encrypts the file with one key, given as its hex or as
  a `Key`; Strings that are not the hex of a key are refused.
- `Herringbone::EncryptionConfiguration` and `Herringbone::DecryptionConfiguration` check the
  `encryption:` and `decryption:` settings when they are built; Hashes are turned into them.
- `herringbone inspect` and `herringbone cat` take `--footer-key`, `--column-key`, `--key` and
  `--aad-prefix` for encrypted files, and ask for missing keys on stdin.
- `Herringbone::Reader` and `Herringbone::Inspector` take `decryption:` with keys, or a `keys:`
  lookup by the key metadata stored in the file, and read encrypted files from parquet-mr, Arrow
  and Herringbone; `Reader#encryption` describes how a file is encrypted.
- `Herringbone.redact` takes `decryption:` and writes an encrypted input encrypted the same way,
  unless `encryption:` says otherwise.
- **Breaking:** encrypted files raise `Herringbone::DecryptionError` (when their keys are missing
  or wrong) instead of `Herringbone::UnsupportedError`.

## 0.5.0

- `Herringbone.redact` and `Herringbone::Redaction` rewrite a file with rows deleted, values
  replaced or columns dropped, for GDPR erasure and pseudonymization, copying the row groups they
  don't touch byte for byte.
- `Herringbone::Redaction#affects?` says whether a redaction would change a file, reading only
  statistics, bloom filters and the `where` columns.
- `Herringbone::Writer#inspect` (and `SimpleWriter`, `ByteValues`) prints a one-line summary with
  the writer's state and row count instead of dumping the buffered rows.
- **Breaking:** schema DSL blocks receive the builder as a parameter instead of running with
  `instance_eval`: `Herringbone::Schema.define { |s| s.int64 :id }`, likewise for `Schema.infer`,
  `Herringbone.write`, `SimpleWriter.new` and nested `struct`/`list`/`map` blocks. A block without
  a parameter raises `ArgumentError`.

## 0.4.0

- herringbone is now Ractor-enabled! Reading and writing work from any Ractor on Ruby 3.1+, and schemas can be passed to Ractors with
- **Breaking:** the optional gems (`zstd-ruby`, `brotli`, `snappy`, `xxhash`, `numo-narray-alt`)
  are used only when loaded: require them (`Bundler.require` does) instead of relying on
  Herringbone to require them on first use.
- Files with LZO-compressed pages (written by parquet-mr with hadoop-lzo) can be read. Writing
  LZO is not supported.
- `Herringbone::SimpleWriter`: CSV-style writing with `headers!` and Array rows, types inferred.
- `Herringbone.write` without `schema:` reads the rows once, holding back only the first 1000 for
  inference, so cursors and one-shot Enumerators no longer lose rows.
- `Herringbone.write(io, rows) { json :payload }` declares fields that replace inferred ones.
- `Herringbone::SchemaMismatch` (an `EncodeError`) explains a row that doesn't fit an inferred
  schema and stops the write; `EncodeError` has `row`, `column` and `value`.
- `herringbone inspect --format=html` opens the page in the browser when run in a terminal.
  `Ractor.make_shareable(schema)`.
- **Breaking:** `herringbone inspect` takes `--format=text|json|html` instead of `--json`/`--html`.

## 0.3.0

- `read(as: :numo)` and `each_batch(as: :numo)` return Numo arrays (optional `numo-narray-alt`).
- The `snappy` gem is used for Snappy when installed: 27x faster compression, 12x faster decompression.
- Writes are forward-only, so files can be streamed into S3 multipart uploads.
- YARD documentation for the whole library.

## 0.2.0

- Streaming reads: pages are decoded incrementally and rows assembled in batches.
- `each_batch(as: :columns)` and `read(as: :columns)` for column-order reads.
- `where:`, `from:` and `limit:` skip row groups and pages using statistics, bloom filters and the
  page index.
- Page indexes (ColumnIndex and OffsetIndex) are written for every column chunk.
- Bloom filters are written and read, using the `xxhash` gem when it is installed.
- `Herringbone::Inspector`, an HTML visualizer and `herringbone inspect`: page headers, page
  indexes, CRC verification and the decoded ARROW:schema, without decompressing any data.
- `Herringbone.write` takes ActiveRecord models and relations.
- `zstd-ruby` and `brotli` are optional; a missing codec raises `MissingCodecError`.
- **Breaking:** the public API was simplified: `Reader.new(io)` and `Writer.open(io, schema)`
  only take IOs, Hash schemas and `Herringbone.export`/`open`/`read` are gone, and `DecodeError`
  is now `FormatError`.

## 0.1.0

- Pure-Ruby Parquet reader and writer, with no Thrift gem or native extensions.
- Full nesting support (structs, lists, maps) via Dremel shredding and assembly.
- All standard encodings, v1 and v2 data pages, Snappy, LZ4 and GZIP in Ruby, ZSTD and Brotli via gems.
- Schemas from a block DSL, inferred from rows, or built from ActiveRecord models.
- Writer coercions for Rails values, byte-based row groups and compact buffers.
