# Herringbone

A pure-Ruby reader and writer for [Apache Parquet](https://parquet.apache.org/) files.

- No Thrift gem and no native extensions of its own: the Thrift compact protocol, all encodings
  and the Snappy and LZ4 codecs are implemented in Ruby (ZSTD and Brotli use optional gems)
- Full nesting support (structs, lists, maps, any depth) via Dremel record shredding/assembly
- Reads files from parquet-mr, Arrow, Spark, Impala, DuckDB, Rust writers etc.
- Ruby 3.0+

## Installation

```ruby
gem "herringbone"
```

The only dependency is `bigdecimal`. Compression support:

| codec | provided by |
|---|---|
| none, Snappy, LZ4 (raw and Hadoop-framed) | Herringbone itself (pure Ruby) |
| GZIP | `zlib` (part of Ruby) |
| ZSTD | the `zstd-ruby` gem, if installed |
| Brotli | the `brotli` gem, if installed |
| LZO | not supported |

To read or write ZSTD or Brotli, add the gem next to Herringbone:

```ruby
gem "herringbone"
gem "zstd-ruby" # ZSTD: faster writes and smaller files than the default Snappy
gem "brotli"
```

Herringbone requires these on first use. Without them, asking a writer for `compression: :zstd`
raises `Herringbone::MissingCodecError` straight away (before any file is created), and reading
a ZSTD-compressed file raises it when the first such page is reached, naming the missing gem and
the column. The file's metadata and schema can still be read. To check upfront:

```ruby
File.open("data.parquet", "rb") do |file|
  reader = Herringbone::Reader.new(file)
  reader.codecs          # => [:zstd]
  reader.missing_codecs  # => [:zstd] when zstd-ruby is not installed
  reader.ensure_codecs_available! # raises MissingCodecError now instead of mid-read
end
Herringbone::Compression.available?(:zstd) # => true / false
```

## Reading

Readers take a random-access IO (a `File` opened with `"rb"`, `StringIO`, `Tempfile`...);
Herringbone does not open files by path. The IO belongs to the caller and is not closed by the reader.

```ruby
require "herringbone"

File.open("data.parquet", "rb") do |file|
  reader = Herringbone::Reader.new(file)
  reader.schema             # => #<Herringbone::Schema ...>
  reader.num_rows

  reader.each_row do |row|  # Hash with String keys, nested values as Hash/Array
    p row
  end

  reader.each_batch(1000) { |rows| ... }                 # Arrays of up to 1000 row Hashes
  reader.each_row(columns: ["id", "name"]) { |row| ... } # projection
  reader.column("name")     # => all values of one top-level field
  reader.read_row_group(0)  # => { "id" => [...], "name" => [...] }
end

File.open("data.parquet", "rb") { |f| Herringbone::Reader.new(f, keys: :symbol, time_zone: "+02:00").rows }
Herringbone::Reader.from_string(bytes).rows # Parquet bytes in a String
```

`each_row`, `each_batch` and `rows` stream: pages are read from the file and decoded one at a
time per column, and rows are assembled in batches (1024 by default, `each_batch(size)` or
`each_row(batch_size:)`), so memory depends on the batch and page sizes rather than on the
row group size. Reading 1M rows stored in a single row group (as parquet-rs writes them) peaks at
about 60–160 MB RSS growth instead of 660 MB. `column` and `read_row_group` return whole
columns, so they hold them in memory.

Options, for `Reader.new` and `Reader.open`, and per call for `each_row`, `each_batch` and `rows`:

| option | default | |
|---|---|---|
| `keys` | `:string` | `:symbol` for Symbol keys in rows and in Hashes built from structs (map keys stay as stored) |
| `time_zone` | none (UTC) | return timestamps in this zone, see below |

`time_zone:` accepts a UTC offset (`"+02:00"`, `"-0500"`, or seconds as an Integer), `"UTC"`, a
timezone object that `Time#getlocal` accepts (e.g. `TZInfo::Timezone.get("Europe/Amsterdam")`),
or anything responding to `#at`, such as `Time.zone` or `ActiveSupport::TimeZone["Amsterdam"]`
in Rails (timestamps then come back as `ActiveSupport::TimeWithZone`). Zone names such as
`"Europe/Amsterdam"` work when ActiveSupport or TZInfo is loaded. All of these work on Ruby 3.0.
It applies to UTC-adjusted timestamps and INT96; timestamps stored with `isAdjustedToUTC=false`
are wall-clock values and stay as they are.

## Writing

```ruby
schema = Herringbone::Schema.define do
  int64 :id, null: false
  string :name
  enum :status, values: %w[pending paid shipped]
  list :tags, :string
  map :scores, :string, :double
  struct :address do
    string :city
    string :zip
  end
  decimal :price, precision: 12, scale: 2
  json :payload
  timestamp :created_at
end

File.open("out.parquet", "wb") do |file|
  Herringbone::Writer.open(file, schema) do |w|
    w << { "id" => 1, "name" => "Anna", "status" => "paid", "tags" => ["a", "b"],
           "scores" => { "x" => 1.5 }, "address" => { "city" => "Amsterdam" },
           "price" => BigDecimal("9.99"), "payload" => { "any" => ["json"] }, "created_at" => Time.now }
    w << { id: 2, status: :pending }  # Symbol keys and values work; missing keys are nulls
    w << [3, "Bo", nil, nil, nil, nil, nil, nil, nil, nil] # Arrays in schema order
    w << order                         # anything with #attributes (ActiveRecord) or #to_h (Struct, Data)
  end
end

# Or with an inferred schema, optionally overriding some columns
Herringbone.write(io, rows, schema: Herringbone::Schema.infer(rows, types: { payload: :json }))
```

Schemas can also be given as a Hash, anywhere a schema is accepted:

```ruby
Herringbone::Schema.define(
  id: { type: :int64, null: false },
  name: :string,
  tags: [:string],                                   # list of strings
  address: { city: :string, zip: :string },          # struct
  price: { type: :decimal, precision: 12, scale: 2 },
  scores: { type: :map, key: :string, value: :double }
)
Herringbone::Writer.open(io, { id: :int64, name: :string }) { |w| w << [1, "x"] }
```

Column types in the DSL: `boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double
float16 string binary json bson enum uuid date int96 time timestamp decimal fixed`, plus
`struct`, `list` and `map`. Fields are nullable unless `null: false` is given.
List elements are nullable unless `element_null: false`; map values unless `value_null: false`.
Nested lists: `list :matrix do list :element, :double end`.

`enum` is a string column. `values:` restricts what may be written, and also takes a Rails-style
Hash (`values: Order.statuses`), in which case both labels and stored integers are accepted and
the label is written. `parquet_enum: true` adds the Parquet ENUM annotation (pyarrow and pandas
read such columns as binary, which is why it is off by default).

Columns accept the values Ruby and Rails code usually has at hand:

| column | accepts |
|---|---|
| `date` | `Date`, `Time`/`DateTime` (their date), `"2024-05-01"` |
| `timestamp` | `Time`, `DateTime`, `ActiveSupport::TimeWithZone`, `Date` (midnight UTC), ISO-8601 strings, Integers in the column's unit |
| `time` | `Time` (its time of day, as Rails returns for `time` columns), `"13:45:30.25"`, Integers |
| `json` | Strings as-is, anything else through `JSON.generate` |
| `string`, `enum` | Strings, Symbols, anything with `to_s` |
| `boolean` | `true`/`false`, `1`/`0`, `"t"`/`"f"`, `"true"`/`"false"`, `"yes"`/`"no"` |
| integers | Integers, whole-number Floats/BigDecimals/Rationals, numeric Strings; out-of-range values raise |
| `decimal` | `BigDecimal`, Integer, Rational, Float, numeric Strings |
| `uuid` | Strings with or without dashes, or 16 raw bytes |

Values that don't fit raise `Herringbone::EncodeError` naming the row number and column path; the
failed row is discarded and the writer can carry on.

The writer writes to any IO that responds to `#write` (a `File`, `StringIO`, `Tempfile`, socket or
pipe); it writes sequentially and never seeks, rewinds or closes it. If the `Writer.open` block
raises (or `#abort` is called), no footer is written and whatever was written so far is left in
the IO for you to discard. To replace a file only once it is complete, write to a temporary file
and rename it yourself:

```ruby
tmp = "orders.parquet.tmp"
File.open(tmp, "wb") { |f| Herringbone.export(Order, f) }
File.rename(tmp, "orders.parquet")
```

Writer options:

| option | default | |
|---|---|---|
| `compression` | `:snappy` | `:none`, `:snappy`, `:gzip`, `:lz4` (LZ4_RAW), `:lz4_hadoop`, `:zstd` (needs `zstd-ruby`), `:brotli` (needs `brotli`) |
| `row_group_bytes` | 16MB | flush a row group once the buffered values take about this much memory; bounds memory use. Low-cardinality string columns are dictionary-encoded as rows arrive and other strings are packed into byte buffers, so a 15-column table exported in 16MB groups peaks around 290 MB RSS (420 MB with 64MB groups) |
| `row_group_size` | none | also flush after this many rows |
| `page_size` | 1MB | approximate data page size |
| `page_row_limit` | `20_000` | at most this many rows per data page |
| `page_index` | `true` | write page indexes (see below) |
| `data_page_version` | `1` | `1` or `2` |
| `dictionary` | `true` | `false`, or an Array of column paths to dictionary-encode |
| `encodings` | `{}` | e.g. `{ "id" => :delta_binary_packed, "x" => :byte_stream_split }` |
| `statistics` | `true` | write min/max/null_count |
| `metadata` | `{}` | footer key/value metadata |

### Page indexes and statistics

Every column chunk gets min/max/null-count statistics, and the writer adds the Parquet page index:
an OffsetIndex (where each data page starts and which row it begins with) for every column, and a
ColumnIndex (per-page min/max, null counts, all-null pages, and whether pages are sorted) for every
column with a defined sort order (all types except INT96). Query engines such as DuckDB, Spark,
Trino, Arrow and DataFusion use these to skip whole pages: with the default 20,000 rows per page,
a lookup like `WHERE id BETWEEN ...` on a sorted column reads a handful of pages instead of the
whole row group. Sort your rows by the columns you filter on to get the most out of it.

Unsigned integers, decimals and float16 use their proper sort orders; NaNs are left out of float
bounds; byte-array bounds longer than 64 bytes are truncated (flagged as inexact in statistics).

## Exporting ActiveRecord models

`Herringbone::Schema.from_active_record` builds a schema from a model's columns, so that
`record.attributes` can be written as-is. Rails is not a dependency: it only calls
`columns`, `primary_key` and `defined_enums` on the model.

```ruby
schema = Herringbone::Schema.from_active_record(Order)
File.open("orders.parquet", "wb") do |file|
  Herringbone::Writer.open(file, schema) do |w|
    Order.find_each { |order| w << order.attributes }
  end
end
```

Or in one go, which loads records with `find_each` and returns the number of rows written:

```ruby
File.open("orders.parquet", "wb") do |file|
  Herringbone.export(Order.where(created_at: 1.year.ago..), file, compression: :zstd)
end
Herringbone.export(Order, io, only: %w[id status total], batch_size: 5000)
```

Options: `only:` and `except:` take attribute names; `enums: :enum` writes enum attributes with
the Parquet ENUM annotation instead of as plain strings (the default, `enums: :string`). Enum
attributes are written as their labels, and the writer rejects values outside the enum.

| Column | Parquet |
|---|---|
| `integer` | `int16`/`int32`/`int64` by SQL type (`smallint`, `integer`, `bigint`...) or limit; `uintN` for `unsigned`; primary keys are always `int64` |
| `float` | `double` (`float` for Postgres `float4`) |
| `decimal` | `decimal(precision, scale)`; `decimal(38, 9)` when the column has no precision |
| `boolean`, `date`, `binary`, `uuid` | same |
| `json`, `jsonb` | `json` |
| `datetime`, `timestamp`, `timestamptz` | `timestamp` (microseconds, UTC) |
| `time` | `time` (microseconds) |
| `hstore` | `map` of `string` to `string` |
| enum attributes | `string` (or `enum`) |
| `string`, `text`, `citext`, anything else | `string` |
| Postgres array columns | `list` of the element type |

Columns declared `NOT NULL` (and primary keys) are required, all others nullable.
Column order follows `Model.columns`.

## Type mapping

| Parquet | Ruby |
|---|---|
| BOOLEAN | `true`/`false` |
| INT32/INT64 (incl. signed/unsigned INTEGER) | `Integer` |
| FLOAT, DOUBLE, FLOAT16 | `Float` |
| STRING, ENUM, JSON | `String` (UTF-8) |
| BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY, BSON | `String` (binary) |
| DATE | `Date` (proleptic Gregorian) |
| TIMESTAMP, INT96 | `Time` (UTC) |
| TIME | `Integer` in the column's unit since midnight |
| DECIMAL | `BigDecimal` |
| UUID | `String` like `"0f1e2d3c-..."` |
| struct / list / map | `Hash` / `Array` / `Hash` |

## Supported format features

- Encodings (read and write): PLAIN, PLAIN_DICTIONARY/RLE_DICTIONARY, RLE, DELTA_BINARY_PACKED,
  DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, BYTE_STREAM_SPLIT; legacy BIT_PACKED levels (read)
- Data page v1 and v2, dictionary pages, page CRCs (written)
- Legacy list and map layouts per the Parquet backward-compatibility rules
- Not supported: encryption, column chunks in external files, bloom filters and page indexes
  (ignored when reading, not written)

## Inspecting files

> The inspector and its HTML view are modelled on
> **[Parquet X-ray](https://huggingface.co/spaces/cfahlgren1/parquet-xray) by cfahlgren1** —
> the design and the idea are theirs. Go check it out.

`Herringbone::Inspector` examines a file using only its footer, page headers, page indexes and
bloom filter headers. No values are decompressed or decoded, so it is fast on big files and works
for ZSTD/Brotli files even without the codec gems.

```ruby
File.open("data.parquet", "rb") do |file|
  i = Herringbone::Inspector.new(file)   # also takes a Reader
  i.summary        # size, footer size, rows, row groups, created_by, codecs, page index / bloom presence
  i.schema_tree    # physical + logical types, repetition, max definition/repetition levels, Arrow type
  i.key_value_metadata # ARROW:schema decoded, JSON values (pandas, Spark) parsed
  i.arrow_schema   # ARROW:schema as Arrow fields and types (pyarrow's names), nested children,
                   # dictionary encoding, extension names, field metadata; nil + i.arrow_schema_error if undecodable
  rg = i.row_groups[0]
  rg.sorting_columns
  chunk = rg.column("name")
  chunk.codec, chunk.encodings, chunk.encoding_stats, chunk.compression_ratio
  chunk.statistics # min/max decoded to Ruby values (Date, Time, BigDecimal...), with caveats for legacy stats
  chunk.pages      # every page header: type, offset, sizes, values, nulls, rows, encoding, page statistics, CRC
  chunk.column_index # per-page min/max/null counts; chunk.offset_index: page locations and first rows
  chunk.index_mismatches # page header statistics that disagree with the column index
  i.pages(0, "name") # same as above
  i.column_totals  # per column, summed over row groups
  i.layout         # byte ranges of everything in the file, in order
  i.to_h           # all of it, JSON-serializable
  puts i.report    # readable text summary
end
```

Page CRCs are only verified when asked, because that reads every page body (still without
decompressing: the CRC32 covers the page bytes as stored):

```ruby
File.open("data.parquet", "rb") do |file|
  i = Herringbone::Inspector.new(file) # or reader.inspector for an open Herringbone::Reader
  i.verify_checksums # => { ok: 10, mismatch: 1, absent: 0, mismatches: [{ row_group:, column:, page:, ... }] }
  i.pages(0, "name").map(&:checksum)   # => [:ok, :mismatch, ...] (:absent when a page has no CRC)
  i.to_h(checksums: true)              # or report(checksums: true), Visualizer.new(file, checksums: true)
end
```

`Herringbone::Visualizer` renders the same information as one self-contained HTML page: a byte map
of the file drawn to scale (row groups, column chunks, dictionary and data pages, page indexes,
bloom filters, footer) that zooms into a row group and a column chunk, the schema, a column table
with codecs, encodings, sizes, compression ratios and statistics, per-page tables, page indexes and
key/value metadata. Everything is inline; highlight.js is loaded from cdnjs to colour JSON, and the
page works without it. The design and idea come from
[Parquet X-ray](https://huggingface.co/spaces/cfahlgren1/parquet-xray) by cfahlgren1.

```ruby
File.open("data.parquet", "rb") do |file|
  html = Herringbone.visualize(file)                          # the page as a String
  File.open("layout.html", "w") { |out| Herringbone.visualize(file, out) } # or into an IO
end
```

```
bin/herringbone inspect FILE [OUT.html]   # HTML page to OUT.html, or to stdout
bin/herringbone inspect FILE --text       # text summary (add --pages to list every page header)
bin/herringbone inspect FILE --json       # everything as JSON
bin/herringbone inspect FILE --text --verify-checksums  # also check page CRCs (any output form)
```

## Command line

```
bin/herringbone schema FILE
bin/herringbone meta FILE
bin/herringbone cat FILE [N]
bin/herringbone inspect FILE [OUT.html | --text [--pages] | --json] [--verify-checksums]
```

## Development

```
bundle install
bundle exec rake test
HERRINGBONE_PYTHON=/path/to/python-with-pyarrow bundle exec rake test   # also run pyarrow interop tests
```

`test/fixtures/parquet-testing` holds files from [apache/parquet-testing](https://github.com/apache/parquet-testing)
(Apache-2.0); expectations for them were generated with pyarrow, see `test/fixtures/generate_expectations.py`.
