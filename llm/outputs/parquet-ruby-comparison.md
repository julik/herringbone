# Herringbone vs parquet-ruby (the `parquet` gem)

Compared 2026-10-04: Herringbone `0.6.1` + unreleased `main`, against `parquet` `0.9.0`
([njaremko/parquet-ruby](https://github.com/njaremko/parquet-ruby) at `b467371`). parquet-ruby
facts come from its README, `CHANGELOG.md` and the Rust/Ruby sources; nothing here was
benchmarked, so there are no speed comparisons. See
[parquet-ruby-history.md](parquet-ruby-history.md) for the maintenance record.

## The basic difference

parquet-ruby wraps the arrow-rs `parquet` crate (58.3) through magnus. It has a small API of six
module functions (`each_row`, `each_column`, `write_rows`, `write_columns`, `metadata`,
`repack`) and leaves decoding and encoding to Rust. Herringbone implements the format in Ruby
(Thrift, encodings, Snappy, LZ4) and puts its effort into what Ruby/Rails code needs around the
format: filtered reads, inferred schemas, ActiveRecord, encryption, redaction, inspection.

## Packaging and platform

| | Herringbone | parquet-ruby |
|---|---|---|
| Implementation | Pure Ruby | Rust (arrow-rs `parquet` 58.3) via magnus/rb_sys |
| Ruby versions | 3.0+ | 3.1+ from source; binaries for 3.2–4.0 |
| Install | Any platform, no compiler | Binaries for x86_64/aarch64 Linux (gnu, musl) and x86_64/arm64 macOS; elsewhere a Rust toolchain |
| New Ruby releases | Work without a release | Need a release with new binaries (Ruby 4.0 waited 6 months) |
| Runtime deps | `bigdecimal` | `rb_sys`, `bigdecimal` |
| Optional gems | `snappy`, `zstd-ruby`, `brotli`, `xxhash`, `numo-narray-alt` | None, all codecs built in |
| Ractors | Yes, reading and writing from any Ractor | Not documented |
| GVL | Held (pure Ruby) | Released during `repack` |
| Load time | Under 1 ms, rest autoloaded | Loads the native extension |

## Reading

| | Herringbone | parquet-ruby |
|---|---|---|
| Sources | Any seekable IO | Path or IO |
| Row iteration | `each_row`, Hashes (String or Symbol keys) | `each_row`, Hashes or Arrays (`result_type:`) |
| Batches | `each_batch(n)` of rows, or `as: :columns` | `each_column(batch_size:)`, Hashes or Arrays of columns |
| Everything at once | `read`, `read(as: :columns)` | No, iterate |
| Numo arrays | `as: :numo`, decoded straight from page bytes | No |
| Column projection | `columns:` | `columns:` |
| Row filters | `where:` with values, IN lists, Ranges, `nil`, callables, struct members | No |
| Row group skipping | Statistics, null counts, bloom filters | No (`row_groups:` is open PR #47) |
| Page skipping | Page index (column and offset index) | No |
| Offset/limit | `from:`, `limit:` via the offset index | No |
| Read planning | `scan_plan(where:)` shows what would be read | No |
| Time zones | `time_zone:` (offset, TZInfo, `Time.zone` in Rails) | UTC; unadjusted timestamps read as UTC |
| String allocation control | No | `string_storage: :copy/:intern/:shared` (zero-copy frozen strings) |
| Encrypted files | Yes, see below | No |
| Metadata | `reader.schema`, `num_rows`, `metadata`, `Inspector` | `Parquet.metadata` Hash (schema, row groups, column stats, offsets) |

## Writing

| | Herringbone | parquet-ruby |
|---|---|---|
| APIs | `Writer.open(io, schema) { \|w\| w << row }`, `Herringbone.write(io, rows)`, `SimpleWriter` | `write_rows(enum, schema:, write_to:)`, `write_columns(enum, ...)` |
| Push-style writer | Yes, `w << row` as rows arrive | No, it pulls from an Enumerable (wrap a push source in an Enumerator) |
| Row shapes | Hashes (String/Symbol keys), Arrays, objects with `#attributes` or `#to_h` | Arrays in schema order; column batches |
| Schema definition | `Schema.define { \|s\| s.int64 :id }` DSL | Array of `{name => type}` Hashes, a `fields` Hash, or `Schema.define` DSL |
| Schema inference | Types inferred from the first 1000 rows, declared fields override | Without a schema, every column is a string named `f0`, `f1`, … |
| ActiveRecord | Relations written with `find_each`, schema from column types, enums | No |
| Output | Any IO with `#write`, sequential, never seeks (streams into S3 `upload_stream`) | Path or IO; IO output is staged in a temp file on disk, then copied |
| Atomic file replace | No, write to a temp file and rename | Yes for path output (staged, then renamed, keeps uid/gid/mode) |
| Failed writes | No footer; the bad row raises `EncodeError` and the writer can carry on | No partial file at the path |
| Memory bounding | `row_group_bytes`, `row_group_rows` | `flush_threshold`, `batch_size`, `sample_size` (bounded since `0.9.0`) |
| Value coercion | Strings, Symbols, ISO-8601, numeric Strings, Rails booleans, `TimeWithZone`… | Mostly typed values; time strings parsed with a `format:` |
| Compression | `:none`, `:snappy`, `:gzip`, `:lz4` (raw), `:lz4_hadoop`, `:zstd`, `:brotli` | none, snappy, gzip, lz4, zstd, brotli |
| Compression level | `compression_level:` | Not exposed |
| Encodings | Per column: dictionary, delta, byte stream split | arrow-rs defaults, not exposed |
| Data page v2 | `data_page_version: 2` | Not exposed |
| Page size / rows | `page_bytes`, `page_rows` | Not exposed |
| Statistics and page index | Always | arrow-rs defaults |
| Bloom filters | `bloom_filters:` per column, `ndv:`, `fpp:`, `max_bytes:` | No (open PR #28 since 2025-09) |
| Footer key/value metadata | `metadata:` | Not exposed |
| String deduplication | Dictionary encoding | `string_cache:` for repeated strings |

## Types

| | Herringbone | parquet-ruby |
|---|---|---|
| Integers | int8–64, uint8–64 | int8–64, uint8–64 |
| Floats | float, double, float16 | float, double; float16 read |
| Strings, binary | string, binary, fixed | string, binary, fixed-size binary |
| Decimal | `BigDecimal`, any precision | `BigDecimal`, decimal128 and decimal256 (256 read truncated in `0.5.10`) |
| Date | `date` | `date32` read; writing it fails (open issue #33) |
| Timestamps | millis, micros, nanos, UTC or local; INT96 read and write | seconds, millis, micros, nanos, with or without zone |
| Time of day | millis, micros, nanos | millis, micros |
| UUID | Read and write | Read and write (`format: "uuid"` on a fixed-size binary), read as a `SecureRandom.uuid`-style String |
| JSON, BSON | `json` (any Ruby value via `JSON.generate`), `bson` | No |
| Enum | `enum` with allowed values, Rails enum Hashes | No |
| Nesting | struct, list, map, any depth; legacy list/map layouts read | struct, list, map, any depth |

## Tooling and file operations

| | Herringbone | parquet-ruby |
|---|---|---|
| Inspector | `Inspector`: summary, per-page headers, statistics, page indexes, bloom filters; text/JSON/HTML report with a to-scale byte map | `Parquet.metadata` |
| Page CRCs | Written; `verify_checksums` checks them | arrow-rs defaults |
| CLI | `herringbone cat`, `herringbone inspect` | No |
| Concatenate / re-split files | No | `Parquet.repack`, copying row groups byte for byte where it can |
| Redaction (GDPR) | `Herringbone.redact`: delete rows, replace values, drop columns, copying untouched row groups byte for byte | No |
| Encryption | Modular encryption read and write: AES-GCM and AES-GCM-CTR, footer and column keys, plaintext footers, AAD prefixes, key rotation by key id; interoperable with parquet-mr, Arrow, pyarrow | No (the crate's `encryption` feature isn't enabled) |
| LZO | Read | No |

## Where each one is the better pick

parquet-ruby:

- Bulk decode/encode of large files where native speed matters and filters aren't needed.
- Concatenating or re-splitting many files (`repack`), with the GVL released.
- Low-allocation string reads (`string_storage: :shared`).
- Atomic replacement of an output path.

Herringbone:

- Reading part of a file: `where:`, `from:`/`limit:`, page and row-group skipping, bloom filters.
- Rails exports: ActiveRecord relations, inferred schemas, lenient value coercion, Symbol keys.
- Streaming straight into S3 or any non-seekable IO without temp disk.
- Encrypted files, redaction, file inspection, the CLI.
- Platforms and Rubies without binaries (no Rust toolchain needed), Ractors, Numo.
- Tuning the file: encodings, page sizes, data page v2, compression levels, footer metadata.
