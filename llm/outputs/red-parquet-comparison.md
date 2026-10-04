# Herringbone vs red-parquet (Apache Arrow)

Compared 2026-10-04: Herringbone `0.6.1` + unreleased `main`, against `red-parquet` `25.0.1`.
Nothing was benchmarked.

## Where it lives

red-parquet is the official Ruby binding from the Apache Arrow project. RubyGems lists no source
URL (only `https://arrow.apache.org/`), and the old `red-data-tools/red-parquet` repo is archived.
The code is in the Arrow monorepo:

- [`apache/arrow/ruby/red-parquet`](https://github.com/apache/arrow/tree/main/ruby/red-parquet):
  the gem, about 200 lines of Ruby.
- [`apache/arrow/c_glib/parquet-glib`](https://github.com/apache/arrow/tree/main/c_glib/parquet-glib):
  the C (GLib) wrapper around Parquet C++ that defines the actual API.
- [`apache/arrow/ruby/red-arrow`](https://github.com/apache/arrow/tree/main/ruby/red-arrow): where
  `Arrow::Table`, type conversion and `Table.load`/`#save` live.

There are no hand-written bindings: GObject Introspection generates `Parquet::*` classes from
Parquet GLib when the gem loads. That's why the rubydoc.info pages are near empty: the methods
don't exist in the Ruby source. The real API reference is the
[Parquet GLib docs](https://arrow.apache.org/docs/c_glib/parquet-glib/) (`gparquet_arrow_file_reader_read_table`
becomes `Parquet::ArrowFileReader#read_table`).

The gem is versioned with Arrow (25.0.1, released about every quarter) and has 1.45M downloads.
It does `require "parquet"` and defines `module Parquet`, the same as the `parquet` gem
(parquet-ruby), so the two can't be loaded in one process.

## The basic difference

red-parquet reads a Parquet file into an Arrow table (columnar, in C++ memory) and writes an
Arrow table out. Getting Ruby objects means converting from Arrow (`each_record`,
`raw_records`). It's a building block for Arrow-based data work (red-arrow, red-arrow-dataset,
Rover, Red Datasets), not a row-oriented Ruby API. Herringbone works with Ruby rows and values
directly and adds what Ruby/Rails code needs around the format.

## Packaging and platform

| | Herringbone | red-parquet |
|---|---|---|
| Implementation | Pure Ruby | Parquet C++ via Parquet GLib and GObject Introspection |
| Install | `gem install`, any platform | System packages first: Arrow GLib and Parquet GLib (`libparquet-glib-dev` from Apache's apt/yum repo, Homebrew `apache-arrow-glib`, MSYS2). The gem tries to install them through `native-package-installer`. |
| Gem dependencies | `bigdecimal` | `red-arrow` (C++ extension), `gobject-introspection`, `glib2`, `gio2`, `pkg-config`, `extpp`, `bigdecimal`, `csv` |
| Version coupling | None | The gem version has to match the installed Arrow GLib; upgrading the system package means upgrading the gem |
| JRuby | Not tested | red-arrow has a partial JRuby backend; red-parquet needs GObject Introspection, so no |
| Docker/CI | Nothing extra | Apache package repository plus the Arrow C++ and GLib shared libraries |
| Threads | Ractors; holds the GVL | Parquet C++ reads with threads (`use_threads`) |

## Reading

| | Herringbone | red-parquet |
|---|---|---|
| Entry points | `Reader.new(io)`, `each_row`, `each_batch`, `read` | `Arrow::Table.load("x.parquet")`; `Parquet::ArrowFileReader` (`read_table`, `read_row_group(i, column_indices)`, `each_row_group`, `read_column_data(i)`) |
| Sources | Any seekable Ruby IO | Path, `Arrow::Buffer`, http(s) URI, Arrow input streams; S3/GCS/HDFS through red-arrow-dataset |
| Result | Ruby Hashes/Arrays, column Hashes, Numo arrays | `Arrow::Table` (C++ memory); Ruby values through `each_record`, `raw_records`, `Arrow::Array#to_a` |
| Streaming | Page by page, memory set by batch and page size | A whole table at once, or one row group at a time |
| Column projection | `columns:` by name | Column indices on `read_row_group`; by name through red-arrow-dataset |
| Row filters | `where:` (values, IN lists, Ranges, `nil`, callables, struct members) | Not on the Parquet reader. `Arrow::Table#slice` filters after loading; red-arrow-dataset's scanner takes an `Arrow::Expression` filter that Arrow C++ uses to skip row groups by statistics |
| Page index skipping | Yes | Not exposed |
| Bloom filters | Used for filtering | Not exposed |
| Offset/limit | `from:`, `limit:` through the offset index | No (slice after loading) |
| After loading | Plain Ruby | Arrow compute: `group`, `join`, `sort_by`, `slice`; conversion to CSV, Arrow IPC, Feather |
| Metadata | `reader.schema`, `metadata`, `Inspector` | `ArrowFileReader#metadata`: `FileMetadata`, `RowGroupMetadata`, `ColumnChunkMetadata`, typed `Statistics` (min/max, nulls, distinct values) |
| Reader tuning | `time_zone:`, `keys: :symbol` | `ReaderProperties`: buffered stream, buffer size, pre-buffering |
| Encrypted files | Yes | No (Parquet C++ supports it; the GLib layer doesn't expose it) |

## Writing

| | Herringbone | red-parquet |
|---|---|---|
| Entry points | `Writer.open(io, schema) { \|w\| w << row }`, `Herringbone.write(io, rows)`, `SimpleWriter` | `table.save("x.parquet", compression: :zstd)`; `Parquet::ArrowFileWriter.open(schema, path) { \|w\| w.write(...) }` |
| Input | Ruby rows: Hashes, Arrays, ActiveRecord records, Structs | `Arrow::Table`, `Arrow::RecordBatch`, or Ruby Arrays of rows / Hashes of columns built into a record batch |
| Schema | `Schema.define { \|s\| ... }` DSL or inferred from the first 1000 rows | `Arrow::Schema.new(name: :type, ...)`, or inferred when building an `Arrow::Table` from Ruby values |
| ActiveRecord | Yes | No |
| Push-style writing | `w << row` | `writer.write(batch)` per record batch; explicit row groups with `new_row_group` |
| Output | Any Ruby IO with `#write`, never seeks (S3 `upload_stream`) | Path, `Arrow::Buffer`, Arrow output streams; S3 and other filesystems through red-arrow-dataset |
| Compression | `:none`, `:snappy`, `:gzip`, `:lz4`, `:lz4_hadoop`, `:zstd`, `:brotli` (zstd/brotli via optional gems) | Whatever Arrow C++ was built with (the Apache packages have snappy, gzip, lz4, zstd, brotli) |
| Compression level | `compression_level:` | Not exposed |
| Writer settings | `row_group_bytes`, `row_group_rows`, `page_bytes`, `page_rows`, `data_page_version`, `dictionary`, `encodings`, `metadata`, `bloom_filters` | `WriterProperties`: compression (per column), dictionary on/off (per column), data page size, dictionary page size limit, max row group length, batch size; `chunk_size:` on save |
| Encodings per column | Yes | No |
| Bloom filters, page index | Written | Not exposed (Arrow C++ defaults: no bloom filters, no page index) |
| Footer key/value metadata | `metadata:` | Not exposed directly |
| Value coercion | Lenient: strings, Symbols, ISO-8601, Rails booleans, `TimeWithZone` | Arrow array builders: values must fit the Arrow type |

## Types

Arrow's type system is a superset of what Parquet stores, so red-parquet reads and writes every
logical type Parquet C++ supports: all integer widths, float16, decimal128/256, date32/64,
time32/64, timestamps in any unit with zones, large strings, dictionary-encoded columns,
fixed-size binary, lists, large lists, structs and maps, at any
depth. Herringbone covers the same Parquet logical types (plus INT96 writing, BSON and ENUM,
and legacy list/map layouts on read) and maps them straight to Ruby classes (`BigDecimal`,
`Date`, `Time` in a chosen zone, UUID Strings, Hashes, Arrays). With red-parquet the Ruby side
depends on red-arrow's converters; `raw_records` gives decimals as `BigDecimal`, timestamps as
`Time` and dates as `Date`.

## Tooling

| | Herringbone | red-parquet |
|---|---|---|
| Inspector / CLI | `Inspector` (text, JSON, HTML byte map), `herringbone inspect`, `herringbone cat` | Metadata and statistics objects; no CLI |
| Page CRC checks | `verify_checksums` | No |
| Redaction | `Herringbone.redact` | No |
| Encryption | Read and write, interoperable with parquet-mr, Arrow, pyarrow | No |
| Other formats | Parquet only | Arrow IPC, Feather, CSV, JSON, ORC through red-arrow |

## Where each one is the better pick

red-parquet:

- Analytical work in Ruby on top of Arrow: group, join, sort and filter in C++, hand tables to
  Rover or other Arrow-based gems, convert between Parquet, Arrow IPC, Feather and CSV.
- Reading whole large files fast with threads, when Arrow C++ is already installed.
- Datasets spread over many files on S3/GCS/HDFS with partitioning and predicate pushdown
  (with red-arrow-dataset).
- Being the reference implementation: what Parquet C++ writes is what pyarrow writes.

Herringbone:

- Installing anywhere with `gem install`, without system packages or version-matched C++
  libraries, in Docker images, on CI, on Heroku-style platforms.
- Row-oriented Ruby: Rails exports, ActiveRecord, inferred schemas, lenient coercion.
- Lookups in a file: `where:`, `from:`/`limit:`, page index and bloom filter skipping, without
  loading the file into memory.
- Writing to any Ruby IO (S3 multipart uploads, sockets, pipes).
- Encryption, redaction, file inspection, the CLI, and file tuning (encodings, page sizes, bloom
  filters, compression levels).

Unrelated but worth knowing: the same monorepo has `red-arrow-format`, a new pure-Ruby reader and
writer for the Arrow IPC format (not Parquet).
