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
Herringbone::Reader.open("data.parquet") do |reader|
  reader.codecs          # => [:zstd]
  reader.missing_codecs  # => [:zstd] when zstd-ruby is not installed
  reader.ensure_codecs_available! # raises MissingCodecError now instead of mid-read
end
Herringbone::Compression.available?(:zstd) # => true / false
```

## Reading

```ruby
require "herringbone"

Herringbone::Reader.open("data.parquet") do |reader|
  reader.schema             # => #<Herringbone::Schema ...>
  reader.num_rows

  reader.each_row do |row|  # Hash with String keys, nested values as Hash/Array
    p row
  end

  reader.each_row(columns: ["id", "name"]) { |row| ... } # projection
  reader.column("name")     # => all values of one top-level field
  reader.read_row_group(0)  # => { "id" => [...], "name" => [...] }
end

Herringbone.read("data.parquet") # => Array of row Hashes
```

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

Herringbone::Writer.open("out.parquet", schema) do |w|
  w << { "id" => 1, "name" => "Anna", "status" => "paid", "tags" => ["a", "b"],
         "scores" => { "x" => 1.5 }, "address" => { "city" => "Amsterdam" },
         "price" => BigDecimal("9.99"), "payload" => { "any" => ["json"] }, "created_at" => Time.now }
  w << { id: 2, status: :pending }  # Symbol keys and values work; missing keys are nulls
  w << [3, "Bo", nil, nil, nil, nil, nil, nil, nil, nil] # Arrays in schema order
  w << order                         # anything with #attributes (ActiveRecord) or #to_h (Struct, Data)
end

# Or with an inferred schema, optionally overriding some columns
Herringbone.write("out.parquet", rows, schema: Herringbone::Schema.infer(rows, types: { payload: :json }))
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
Herringbone::Writer.open("out.parquet", { id: :int64, name: :string }) { |w| w << [1, "x"] }
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

When given a path, the writer writes to a temporary file next to it and renames it into place on
close. If the block raises (or `#abort` is called), the temporary file is removed and any
existing file at the path is left untouched. An IO (`File`, `StringIO`, a socket...) can be
given instead of a path.

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
Herringbone::Writer.open("orders.parquet", schema) do |w|
  Order.find_each { |order| w << order.attributes }
end
```

Or in one go, which loads records with `find_each` and returns the number of rows written:

```ruby
Herringbone.export(Order.where(created_at: 1.year.ago..), "orders.parquet", compression: :zstd)
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

## Command line

```
bin/herringbone schema FILE
bin/herringbone meta FILE
bin/herringbone cat FILE [N]
```

## Development

```
bundle install
bundle exec rake test
HERRINGBONE_PYTHON=/path/to/python-with-pyarrow bundle exec rake test   # also run pyarrow interop tests
```

`test/fixtures/parquet-testing` holds files from [apache/parquet-testing](https://github.com/apache/parquet-testing)
(Apache-2.0); expectations for them were generated with pyarrow, see `test/fixtures/generate_expectations.py`.
