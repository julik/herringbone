# Parakiet

A pure-Ruby reader and writer for [Apache Parquet](https://parquet.apache.org/) files.

- No native extensions, no Thrift gem: the Thrift compact protocol, all encodings and the
  Snappy and LZ4 codecs are implemented in Ruby
- Full nesting support (structs, lists, maps, any depth) via Dremel record shredding/assembly
- Reads files from parquet-mr, Arrow, Spark, Impala, DuckDB, Rust writers etc.
- Ruby 3.0+

## Installation

```ruby
gem "parakiet"
```

Snappy and LZ4 are implemented in Ruby, GZIP uses `zlib`, and ZSTD and Brotli come from the
`zstd-ruby` and `brotli` gems (runtime dependencies, along with `bigdecimal`).

## Reading

```ruby
require "parakiet"

Parakiet::Reader.open("data.parquet") do |reader|
  reader.schema             # => #<Parakiet::Schema ...>
  reader.num_rows

  reader.each_row do |row|  # Hash with String keys, nested values as Hash/Array
    p row
  end

  reader.each_row(columns: ["id", "name"]) { |row| ... } # projection
  reader.column("name")     # => all values of one top-level field
  reader.read_row_group(0)  # => { "id" => [...], "name" => [...] }
end

Parakiet.read("data.parquet") # => Array of row Hashes
```

## Writing

```ruby
schema = Parakiet::Schema.define do
  int64 :id, null: false
  string :name
  list :tags, :string
  map :scores, :string, :double
  struct :address do
    string :city
    string :zip
  end
  decimal :price, precision: 12, scale: 2
  timestamp :created_at, unit: :micros
end

Parakiet::Writer.open("out.parquet", schema, compression: :snappy) do |w|
  w << { "id" => 1, "name" => "Anna", "tags" => ["a", "b"], "scores" => { "x" => 1.5 },
         "address" => { "city" => "Amsterdam" }, "price" => BigDecimal("9.99"),
         "created_at" => Time.now }
  w << { id: 2 } # Symbol keys work too; missing keys are nulls
end

# Or with an inferred schema
Parakiet.write("out.parquet", [{ "id" => 1, "name" => "x" }])
```

Column types in the DSL: `boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double
float16 string binary json bson enum uuid date int96 time timestamp decimal fixed`, plus
`struct`, `list` and `map`. Fields are nullable unless `null: false` is given.
List elements are nullable unless `element_null: false`; map values unless `value_null: false`.
Nested lists: `list :matrix do list :element, :double end`.

Writer options:

| option | default | |
|---|---|---|
| `compression` | `:snappy` | `:none`, `:snappy`, `:gzip`, `:lz4` (LZ4_RAW), `:lz4_hadoop`, `:zstd`, `:brotli` |
| `row_group_size` | `100_000` | rows per row group |
| `page_size` | 1MB | approximate data page size |
| `data_page_version` | `1` | `1` or `2` |
| `dictionary` | `true` | `false`, or an Array of column paths to dictionary-encode |
| `encodings` | `{}` | e.g. `{ "id" => :delta_binary_packed, "x" => :byte_stream_split }` |
| `statistics` | `true` | write min/max/null_count |
| `metadata` | `{}` | footer key/value metadata |

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
bin/parakiet schema FILE
bin/parakiet meta FILE
bin/parakiet cat FILE [N]
```

## Development

```
bundle install
bundle exec rake test
PARAKIET_PYTHON=/path/to/python-with-pyarrow bundle exec rake test   # also run pyarrow interop tests
```

`test/fixtures/parquet-testing` holds files from [apache/parquet-testing](https://github.com/apache/parquet-testing)
(Apache-2.0); expectations for them were generated with pyarrow, see `test/fixtures/generate_expectations.py`.
