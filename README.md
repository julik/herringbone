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

`each_batch(size, as: :columns)` yields `{ "id" => [...], "name" => [...] }` per batch instead
of row Hashes, which is 25–30% faster when you process data column by column.
`reader.read_columns` and `Herringbone.read(io, as: :columns)` return a whole file that way.

### Selecting rows: `where:`, `from:`, `limit:`

`each_row`, `each_batch`, `rows`, `read_columns` and `Herringbone.read` take filters:

```ruby
reader.rows(where: { user_id: 42 })
reader.rows(where: { status: %w[paid shipped], created_at: 1.week.ago.. })  # IN, Ranges
reader.rows(where: { "address.city" => "Amsterdam", deleted_at: nil })     # struct members, IS NULL
reader.rows(where: { amount: ->(v) { v && v > 100 } })                      # any callable
reader.rows(from: 1_000_000, limit: 100)                                     # rows 1,000,000..1,000,099
reader.each_batch(10_000, as: :columns, columns: %w[id amount], where: { day: Date.today }) { |b| ... }
```

All conditions must hold; filtered columns need not be among `columns:`. Conditions work on any
column that is not inside a list or map. The file is used to avoid reading data wherever it can:

- row groups whose min/max statistics or null counts rule a condition out are skipped, as are
  row groups whose bloom filter says an equality value is absent;
- within the remaining row groups, the page index (written by Herringbone, parquet-mr, Arrow and
  others) rules out pages, and the offset index lets each column jump straight to the pages it
  needs; `from:` uses it to jump to a row without reading the pages before it;
- every row that is read is then checked, so results are exact.

On a 1M-row file with 20k-row pages, a lookup of one `id` takes 0.1 s instead of 6.3 s for a
full scan. Filters help most on columns the data is sorted or clustered by; sort rows by the
columns you filter on when writing. `reader.scan_plan(where: ..., from: ...)` shows which row
groups and row ranges a read would touch, without reading anything.

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
| `bloom_filters` | none | `true`, an Array of column paths, or `{ "path" => true \| { ndv:, fpp:, max_bytes: } }` (see below) |

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

### Bloom filters

Min/max statistics cannot rule out a value that falls inside a row group's range, which is the
usual case for IDs, emails or UUIDs that are not sorted. A bloom filter can: it answers "definitely
not here" or "maybe" for an equality lookup, so readers skip every row group that cannot hold the
value. Herringbone writes and reads Parquet's split block bloom filters (XXH64, as parquet-mr,
Arrow, DuckDB, Spark and DataFusion use) in pure Ruby. They are off by default:

```ruby
Herringbone::Writer.open(file, schema, bloom_filters: ["user_id", "email"]) { |w| ... }
Herringbone::Writer.open(file, schema, bloom_filters: true) { |w| ... }  # every non-boolean column
Herringbone::Writer.open(file, schema, bloom_filters: {
  "email" => true,                          # sized from the distinct values of each row group
  "user_id" => { ndv: 1_000_000, fpp: 0.05 } # fixed size per row group
}) { |w| ... }
```

Without `ndv`, the writer counts the distinct values of each row group (the dictionary size for
dictionary-encoded chunks) and sizes the filter with the spec's formula for the false positive
probability `fpp` (default `0.01`), rounded up to a power of two between 32 bytes and `max_bytes`
(default 1MB). Filters are written after each row group's column chunks. Nested leaves are named
by their dotted path (`"tags.list.element"`); nulls are not recorded; BOOLEAN columns have none.

Reading takes Ruby values, converted like the writer converts them, so Dates, Times, BigDecimals
and UUID Strings match what was stored:

```ruby
File.open("events.parquet", "rb") do |f|
  reader = Herringbone::Reader.new(f)
  reader.bloom_filter(0, "email")&.might_contain?("a@example.com")  # nil if the chunk has none
  reader.row_groups_that_may_contain("user_id", 42)  # => [3] (groups without a filter included)
  reader.row_groups_that_may_contain("day", Date.new(2024, 5, 1)).each do |i|
    reader.read_row_group(i)
  end
end
```

`Herringbone::BloomFilter` and `Herringbone::XXHash.xxh64` can also be used on their own. Hashing
is pure Ruby, so bloom filters make writing noticeably slower: on an M-series Mac a filter adds
about 3.5 s per million rows on an INT64 column and about 17 s per million ~22-byte strings
(dictionary-encoded columns only hash their distinct values).

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
- Split block bloom filters (read and written, see above)
- Not supported: encryption, column chunks in external files, page indexes when reading

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
