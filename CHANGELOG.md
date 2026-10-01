# Changelog

## Unreleased

- `Herringbone::SimpleWriter`: CSV-style writing with `headers!` and Array rows, types inferred.
- `Herringbone.write` without `schema:` reads the rows once, holding back only the first 1000 for
  inference, so cursors and one-shot Enumerators no longer lose rows.
- `Herringbone.write(io, rows) { json :payload }` declares fields that replace inferred ones.
- `Herringbone::SchemaMismatch` (an `EncodeError`) explains a row that doesn't fit an inferred
  schema and stops the write; `EncodeError` has `row`, `column` and `value`.
- `herringbone inspect --format=html` opens the page in the browser when run in a terminal.
- Reading and writing work from any Ractor, and schemas can be passed to Ractors with
  `Ractor.make_shareable(schema)`.
- **Breaking:** `herringbone inspect` takes `--format=text|json|html` instead of `--json`/`--html`.
- **Breaking:** the optional gems (`zstd-ruby`, `brotli`, `snappy`, `xxhash`, `numo-narray-alt`)
  are used only when loaded: require them (`Bundler.require` does) instead of relying on
  Herringbone to require them on first use.

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
