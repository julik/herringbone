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
gem "zstd-ruby" # optional: ZSTD (faster writes and smaller files than the default Snappy)
gem "brotli"    # optional: Brotli
gem "xxhash"    # optional: faster bloom filters
gem "numo-narray-alt" # optional: read(as: :numo)
```

The only dependency is `bigdecimal`. Snappy, LZ4 and GZIP always work. `Herringbone.codecs` lists
the codecs this process can use, e.g. `[:none, :snappy, :gzip, :lz4, :lz4_hadoop, :zstd]`. Using
a missing one raises `Herringbone::MissingCodecError` naming the gem to add: a writer raises it
before writing anything, a reader when it reaches the first such page (the schema and metadata
are still readable). LZO is not supported.

## Reading

Herringbone never opens files by path: readers take a random-access IO (a `File` opened with
`"rb"`, `StringIO`, `Tempfile`...), which stays open and belongs to the caller.

```ruby
require "herringbone"

File.open("data.parquet", "rb") do |file|
  reader = Herringbone::Reader.new(file)
  reader.schema
  reader.num_rows

  reader.each_row { |row| p row }             # Hashes with String keys, nested values as Hash/Array
  reader.each_batch(1000) { |rows| ... }      # Arrays of up to 1000 rows
  reader.each_batch(10_000, as: :columns) { |batch| batch["amount"].sum } # { "id" => [...], ... }
  reader.read                                 # all rows at once; read(as: :columns) for column Arrays
end
```

Reads stream: pages are read and decoded one at a time per column and rows are assembled in
batches, so memory depends on the batch and page sizes rather than on the row group size (1M
rows in a single row group peak at about 60–160 MB RSS growth instead of 660 MB). Column-order
batches (`as: :columns`) skip building a Hash per row and are 25–30% faster.

`Reader.new` takes `keys: :symbol` for Symbol keys (in rows and in structs; map keys stay as
stored) and `time_zone:` to return timestamps in a zone instead of UTC: a UTC offset (`"+02:00"`,
or seconds), `"UTC"`, a `TZInfo::Timezone`, or anything responding to `#at` such as `Time.zone`
in Rails (which yields `ActiveSupport::TimeWithZone`). Zone names like `"Europe/Amsterdam"` work
when ActiveSupport or TZInfo is loaded. Timestamps stored with `isAdjustedToUTC=false` are
wall-clock values and stay as they are.

### Selecting rows

`each_row`, `each_batch` and `read` take `columns:`, `where:`, `from:` and `limit:`:

```ruby
reader.read(columns: %w[id name])                                          # projection
reader.read(where: { user_id: 42 })
reader.read(where: { status: %w[paid shipped], created_at: 1.week.ago.. })  # IN, Ranges
reader.read(where: { "address.city" => "Amsterdam", deleted_at: nil })     # struct members, IS NULL
reader.read(where: { amount: ->(v) { v && v > 100 } })                      # any callable
reader.read(from: 1_000_000, limit: 100)                                    # rows 1,000,000..1,000,099
```

All conditions must hold; filtered columns need not be among `columns:`, and any column not inside
a list or map can be filtered on. Row groups are skipped using min/max statistics, null counts and
bloom filters, pages using the page index (written by Herringbone, parquet-mr, Arrow and others),
and `from:` jumps to its row through the offset index; every row read is then checked, so results
are exact. On a 1M-row file with 20k-row pages, looking up one `id` takes 0.1 s instead of 6.3 s.
Filters help most on columns the data is sorted or clustered by. `reader.scan_plan(where: ...)`
shows which row groups and row ranges a read would touch, without reading them.

### Numo arrays

`as: :numo` returns (or yields, with `each_batch`) a Hash of column name => Numo array, and takes
the same `columns:`, `where:`, `from:` and `limit:`. Add `gem "numo-narray-alt"` (or
`numo-narray`) to your Gemfile: Herringbone requires it on first use and raises
`Herringbone::UnsupportedError` naming the gem when it is missing.

```ruby
cols = reader.read(as: :numo, columns: %w[id amount])  # { "id" => Numo::Int64, "amount" => Numo::DFloat }
df = Rover::DataFrame.new(reader.read(as: :numo))       # no conversion needed
```

Flat numeric and boolean columns are decoded from the page bytes without a Ruby object per value:
two numeric columns of 1M uncompressed rows read in about 25 ms, against 50 ms with `as: :columns`.

| Parquet | Numo |
|---|---|
| INT32, INT64 (also TIME) | `Int32`, `Int64` |
| INT(8/16) signed; INT(8/16/32/64) unsigned | `Int8`, `Int16`; `UInt8` … `UInt64` |
| FLOAT, FLOAT16, DOUBLE | `SFloat`, `SFloat`, `DFloat` (nulls are NaN) |
| integers with nulls | `DFloat` with NaN (exact up to 2**53) |
| BOOLEAN | `Bit`; with nulls `RObject` of true/false/nil |
| list of numbers, every row the same length and no nulls | 2-D `[rows, length]` (e.g. embeddings) |
| strings, binary, decimals, dates, timestamps, UUIDs, structs, maps, other lists | `RObject` of the values `read` returns |

Whether a column has nulls (or a list column is rectangular) is decided from the rows read, so
with `each_batch` it can differ between batches.

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
```

`Herringbone.write(io, rows)` writes an Enumerable of rows in one go, inferring the schema from the
first 1000 rows unless `schema:` is given; fields declared in a block replace inferred ones:
`Herringbone.write(io, rows, schema: Herringbone::Schema.infer(rows) { json :payload })`.

The writer writes to any IO that responds to `#write` (a `File`, `StringIO`, `Tempfile`, socket or
pipe), sequentially, and never seeks, rewinds or closes it (it does switch it to binary mode). If
the `Writer.open` block raises (or `#abort` is called), no footer is written and what was written
so far is left for you to discard. To replace a file only once it is complete, write to a temporary
file and rename it.

Column types: `boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double float16
string binary json bson enum uuid date int96 time timestamp decimal fixed`, plus `struct`, `list`
and `map`; `column :name, :int32` declares one by name. Fields are nullable unless `null: false`
is given; list elements unless `element_null: false`, map values unless `value_null: false`.
Nested lists: `list :matrix do list :element, :double end`. `time` and `timestamp` take `unit:`
(`:millis`, `:micros`, `:nanos`) and `utc:`.

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

Writer options:

| option | default | |
|---|---|---|
| `compression` | `:snappy` | `:none`, `:snappy`, `:gzip`, `:lz4` (LZ4_RAW), `:lz4_hadoop`, `:zstd`, `:brotli` |
| `row_group_bytes` | 16MB | flush a row group once the buffered values take about this much memory, which bounds memory use (a 15-column table peaks around 290 MB RSS) |
| `row_group_rows` | none | also flush after this many rows |
| `page_bytes` | 1MB | approximate data page size |
| `page_rows` | `20_000` | at most this many rows per data page |
| `data_page_version` | `1` | `1` or `2` |
| `dictionary` | `true` | `false`, or an Array of column paths to dictionary-encode |
| `encodings` | `{}` | e.g. `{ "id" => :delta_binary_packed, "x" => :byte_stream_split }` |
| `metadata` | `{}` | footer key/value metadata, read back with `reader.metadata` |
| `bloom_filters` | none | `true`, an Array of column paths, or `{ "path" => { ndv:, fpp:, max_bytes: } }` |

### Statistics, page indexes and bloom filters

Every column chunk gets min/max/null-count statistics and the Parquet page index (per-page min/max
and row offsets), which Herringbone, DuckDB, Spark, Trino, Arrow and DataFusion use to skip pages.
With 20,000 rows per page, `WHERE id BETWEEN ...` on a sorted column reads a handful of pages
instead of the whole row group, so sort rows by the columns you filter on.

Min/max cannot rule out a value inside a row group's range, the usual case for unsorted IDs,
emails or UUIDs; a bloom filter can. They are off by default. `bloom_filters: ["user_id", "email"]`
(or `true` for every non-boolean column) writes Parquet's split block bloom filters, sized from
each row group's distinct values at a false positive probability of 1% (`fpp:`, up to `max_bytes:`,
default 1MB) unless `ndv:` gives the number of distinct values. Nested leaves are named by their
dotted path (`"tags.list.element"`). Hashing is pure Ruby unless the `xxhash` gem is installed:
a million rows take about 1.2 s longer to write with a filter on an INT64 column and 2.8 s longer
with one on a ~22-byte string column, and about 0.5 s longer with `xxhash`.

### Writing to S3

Parquet keeps its metadata in a footer, so a file can be streamed into an S3 multipart upload
without a local copy, using `upload_stream` from `aws-sdk-s3`:

```ruby
s3 = Aws::S3::TransferManager.new # aws-sdk-s3 1.197+; before that, Aws::S3::Object#upload_stream
s3.upload_stream(bucket: "exports", key: "events.parquet", part_size: 16 * 1024 * 1024) do |io|
  Herringbone::Writer.open(io, schema) do |w|
    events.each { |event| w << event }
  end
end
s3.upload_stream(bucket: "exports", key: "orders.parquet") { |io| Herringbone.write(io, Order.all) }
```

If the block raises, the SDK aborts the multipart upload and raises `Aws::S3::MultipartUploadError`,
so no partial object is left. S3 allows at most 10,000 parts, which with the default 5MB parts caps
the file at about 48GB; raise `part_size:` for bigger files.

## ActiveRecord

`Herringbone.write` also takes a model or relation, which it reads with `find_each`, using a schema
built from the model's columns. It returns the number of rows written:

```ruby
File.open("orders.parquet", "wb") do |file|
  Herringbone.write(file, Order.where(created_at: 1.year.ago..), compression: :zstd)
end
schema = Herringbone::Schema.from_active_record(Order, only: %w[id status total])
Herringbone.write(io, Order, schema: schema)
```

`from_active_record` takes `only:`, `except:` and `parquet_enum: true`. Rails is not a dependency:
it only calls `columns`, `primary_key` and `defined_enums` on the model. Enum attributes are
written as their labels, and the writer rejects values outside the enum.

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

Columns declared `NOT NULL` (and primary keys) are required, all others nullable. Column order
follows `Model.columns`.

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

## Inspecting files

> The inspector and its HTML view are modelled on
> **[Parquet X-ray](https://huggingface.co/spaces/cfahlgren1/parquet-xray) by cfahlgren1** —
> the design and the idea are theirs. Go check it out.

`Herringbone::Inspector` examines a file using only its footer, page headers, page indexes and
bloom filter headers. Nothing is decompressed, so it is fast on big files and works for ZSTD and
Brotli files without the codec gems.

```ruby
File.open("data.parquet", "rb") do |file|
  inspector = Herringbone::Inspector.new(file)
  inspector.summary      # size, rows, row groups, codecs, page index / bloom filter presence...
  inspector.row_groups[0].column("name").pages # page headers; also statistics, column_index...
  puts inspector.report  # the schema, every column chunk, key/value metadata (Arrow schema decoded)
  inspector.to_h         # all of it, JSON-serializable
  inspector.to_html      # one self-contained HTML page with a to-scale byte map of the file
end
```

`inspector.verify_checksums` reads every page body (still without decompressing) to check the page
CRCs; the results then appear in `summary`, `report`, `to_h` and `to_html`.

## Command line

```
bin/herringbone cat FILE [N]                    # rows as JSON lines
bin/herringbone inspect FILE [--pages]          # text report (--pages lists every page header)
bin/herringbone inspect FILE --json             # everything as JSON
bin/herringbone inspect FILE --html > out.html  # the HTML page
```

Add `--verify-checksums` to any `inspect` form to check page CRCs.

## Supported format features

- Encodings (read and write): PLAIN, PLAIN_DICTIONARY/RLE_DICTIONARY, RLE, DELTA_BINARY_PACKED,
  DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, BYTE_STREAM_SPLIT; legacy BIT_PACKED levels (read)
- Data page v1 and v2, dictionary pages, page CRCs (written)
- Page indexes and split block bloom filters (read and written)
- Legacy list and map layouts per the Parquet backward-compatibility rules
- Not supported: encryption, column chunks in external files

## Development

```
bundle install
bundle exec rake test
HERRINGBONE_PYTHON=/path/to/python-with-pyarrow bundle exec rake test   # also run pyarrow interop tests
```

`test/fixtures/parquet-testing` holds files from [apache/parquet-testing](https://github.com/apache/parquet-testing)
(Apache-2.0); expectations for them were generated with pyarrow, see `test/fixtures/generate_expectations.py`.
