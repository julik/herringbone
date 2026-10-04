# Herringbone manual

The full reference for Herringbone. For a quick start, see the [README](README.md).

- [Installation](#installation)
  - [Optional gems](#optional-gems)
  - [Ractors](#ractors)
- [Reading](#reading)
  - [Reader options](#reader-options)
  - [Selecting rows](#selecting-rows)
  - [Numo arrays](#numo-arrays)
- [Writing](#writing)
  - [Defining a schema](#defining-a-schema)
  - [Writing with an inferred schema](#writing-with-an-inferred-schema)
  - [Output IOs and failed writes](#output-ios-and-failed-writes)
  - [Column types](#column-types)
  - [Accepted values](#accepted-values)
  - [Writer options](#writer-options)
  - [SimpleWriter: coming from CSV](#simplewriter-coming-from-csv)
  - [Statistics, page indexes and bloom filters](#statistics-page-indexes-and-bloom-filters)
  - [Writing to S3](#writing-to-s3)
- [Encryption](#encryption)
  - [Writing encrypted files](#writing-encrypted-files)
  - [Which settings other tools read](#which-settings-other-tools-read)
  - [Reading encrypted files](#reading-encrypted-files)
  - [Key management](#key-management)
- [ActiveRecord](#activerecord)
- [Redaction](#redaction)
  - [Statements](#statements)
  - [Reusable redactions and reports](#reusable-redactions-and-reports)
  - [Input and output](#input-and-output)
  - [How row groups are rewritten](#how-row-groups-are-rewritten)
  - [What gets erased, and what doesn't](#what-gets-erased-and-what-doesnt)
  - [Encrypted files](#encrypted-files)
  - [Recipes](#recipes)
- [Combining files](#combining-files)
  - [Comparing and uniting schemas](#comparing-and-uniting-schemas)
  - [Combining encrypted files](#combining-encrypted-files)
- [Type mapping](#type-mapping)
- [Inspecting files](#inspecting-files)
- [Command line](#command-line)
- [Supported format features](#supported-format-features)
- [Development](#development)

## Installation

```ruby
gem "herringbone"
```

### Optional gems

Add these libraries to speed up and enable certain functionality:

```ruby
gem "snappy"          # native Snappy, 2-3x faster reads and writes of typical files
gem "zstd-ruby"       # ZSTD
gem "brotli"          # Brotli
gem "xxhash"          # faster bloom filters
gem "numo-narray-alt" # read(as: :numo)
```

Herringbone never requires them itself: it uses whichever are loaded. Bundler.require (as in Rails)
loads them, otherwise require them yourself:

```ruby
require "herringbone"
require "zstd-ruby"
require "numo/narray"
```

### Ractors

On Ruby 3.1 and later, Herringbone works from any Ractor. Pass a schema to a Ractor with
`Ractor.make_shareable(schema)`. Rows made shareable the same way reach a writing Ractor by
reference, without being copied:

```ruby
writer = Ractor.new("out.parquet", Ractor.make_shareable(schema)) do |path, schema|
  File.open(path, "wb") do |f|
    Herringbone::Writer.open(f, schema) do |w|
      while (row = Ractor.receive) != :done
        w << row
      end
    end
  end
end
rows.each { |row| writer.send(Ractor.make_shareable(row)) }
writer.send(:done)
```

Herringbone loads its parts on first use (`require "herringbone"` itself takes under a
millisecond). Before Ruby 3.4, Ractors other than the main one cannot load code, so call
`Herringbone.eager_load!` before starting them. It also moves all the loading to boot, for
example before a server forks.

## Reading

Herringbone can read from any IO-ish object with random access (the IO should be seekable).

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

### Reader options

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
`numo-narray`) to your Gemfile and `require "numo/narray"`: without it, `as: :numo` raises
`Herringbone::UnsupportedError` naming the gem.

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

### Defining a schema

```ruby
schema = Herringbone::Schema.define do |s|
  s.int64 :id, null: false
  s.string :name
  s.enum :status, values: %w[pending paid shipped]
  s.list :tags, :string
  s.map :scores, :string, :double
  s.struct :address do |address|
    address.string :city
    address.string :zip
  end
  s.decimal :price, precision: 12, scale: 2
  s.json :payload
  s.timestamp :created_at
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

The block receives the schema builder, and the blocks of `struct`, `list` and `map` receive a
builder of their own, so the block can still call your methods and read your instance variables.
A block that takes no parameter raises `ArgumentError`.

### Writing with an inferred schema

`Herringbone.write(io, rows)` writes an Enumerable of rows in one go, inferring the schema from the
first 1000 rows unless `schema:` is given; fields declared in a block replace inferred ones:
`Herringbone.write(io, rows) { |s| s.json :payload }`. The rows are iterated once, holding back only
those first 1000, so lazy Enumerators and cursors that can't be rewound work. A later row that
doesn't fit the inferred types raises `Herringbone::SchemaMismatch`, which explains what was
inferred and how to declare the column, and leaves the file unfinished.

### Output IOs and failed writes

The writer writes to any IO that responds to `#write` (a `File`, `StringIO`, `Tempfile`, socket or
pipe), sequentially, and never seeks, rewinds or closes it (it does switch it to binary mode). If
the `Writer.open` block raises (or `#abort` is called), no footer is written and what was written
so far is left for you to discard. To replace a file only once it is complete, write to a temporary
file and rename it.

### Column types

`boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double float16 string binary
json bson enum uuid date int96 time timestamp decimal fixed`, plus `struct`, `list` and `map`;
`s.column :name, :int32` declares one by name. Fields are nullable unless `null: false` is given;
list elements unless `element_null: false`, map values unless `value_null: false`. Nested lists:
`s.list :matrix do |matrix| matrix.list :element, :double end`. `time` and `timestamp` take `unit:`
(`:millis`, `:micros`, `:nanos`) and `utc:`.

`enum` is a string column. `values:` restricts what may be written, and also takes a Rails-style
Hash (`values: Order.statuses`), in which case both labels and stored integers are accepted and
the label is written. `parquet_enum: true` adds the Parquet ENUM annotation (pyarrow and pandas
read such columns as binary, which is why it is off by default).

### Accepted values

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

### Writer options

| option | default | |
|---|---|---|
| `compression` | `:snappy` | `:none`, `:snappy`, `:gzip`, `:lz4` (LZ4_RAW), `:lz4_hadoop`, `:zstd`, `:brotli` |
| `compression_level` | codec default | level for `:zstd` (up to 22, default 3), `:gzip` (0-9) or `:brotli` (0-11) |
| `row_group_bytes` | 16MB | flush a row group once the buffered values take about this much memory, which bounds memory use (a 15-column table peaks around 290 MB RSS) |
| `row_group_rows` | none | also flush after this many rows |
| `page_bytes` | 1MB | approximate data page size |
| `page_rows` | `20_000` | at most this many rows per data page |
| `data_page_version` | `1` | `1` or `2` |
| `dictionary` | `true` | `false`, or an Array of column paths to dictionary-encode |
| `encodings` | `{}` | e.g. `{ "id" => :delta_binary_packed, "x" => :byte_stream_split }` |
| `metadata` | `{}` | footer key/value metadata, read back with `reader.metadata` |
| `bloom_filters` | none | `true`, an Array of column paths, or `{ "path" => { ndv:, fpp:, max_bytes: } }` |

### SimpleWriter: coming from CSV

`SimpleWriter` writes like the CSV gem: name the columns, then append Arrays. The types are
inferred from the first 1000 rows, as with `Herringbone.write`.

```ruby
File.open("people.parquet", "wb") do |file|
  Herringbone::SimpleWriter.open(file) do |sw|
    sw.headers!(:id, :name, :age)
    sw << [123, "John", 12]
    sw << { id: 124, name: "Jane" } # Hashes work too
  end
end
```

Unlike CSV, headers are required. A column that holds more than one type can be declared up front:
`Herringbone::SimpleWriter.new(io) { |s| s.string :code }` (then call `close` when done).

`encrypt!` encrypts the file with one key (see [Encryption](#encryption)): give it the key's hex
or a `Herringbone::Key` (`key: Herringbone::Key.generate` for a new one; keep it).

```ruby
Herringbone::SimpleWriter.open(file) do |sw|
  sw.encrypt!(key: ENV["PARQUET_KEY"])
  sw.headers!(:id, :name)
  sw << [1, "John"]
end
```

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
dotted path (`"tags.list.element"`). Hashing is pure Ruby unless the `xxhash` gem is loaded:
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

## Encryption

Herringbone reads and writes files encrypted with
[Parquet modular encryption](https://parquet.apache.org/docs/file-format/data-pages/encryption/),
the scheme parquet-mr (Spark), Arrow (pyarrow) and parquet-rs implement. Each column can be
encrypted with its own key or left in the clear, and the footer (schema, row counts, statistics)
is either encrypted too or left readable and signed. AES-GCM comes from OpenSSL, which Ruby ships
with; no other gem is needed.

### Writing encrypted files

Most of the time, one key will do:

```ruby
key = Herringbone::Key.generate                     # AES-256; keep it safe, without it the data is gone
key = Herringbone::Key.from_hex(ENV["PARQUET_KEY"]) # 32 or 64 hex digits; key.hex gives them back

Herringbone.write(io, rows, encryption: key)
Herringbone::Reader.new(io, decryption: key)
```

That encrypts every column and the footer with the key (AES-GCM, no AAD prefix), the setup the
most other readers support, see below; they take the key itself (`key.bytes`). A key's hex (32 or
64 digits) works in place of a `Key` too: `encryption: ENV["PARQUET_KEY"]`. Any other String is
refused, raw key bytes included, since those are easy to mangle and to mistake for text: wrap
them in `Herringbone::Key.new(bytes)`.

Each key has an id, stored in the clear in the files it encrypts: a fingerprint of the key (an
HMAC, which gives nothing away about the key), or one you choose with
`Herringbone::Key.new(bytes, id: "2026-10")`. A reader given several keys, a keyring, picks the
one the file names, so rotating keys is writing with a new one and reading with all of them:

```ruby
Herringbone::Reader.new(io, decryption: [current_key, previous_key])
Herringbone::Reader.new(io, decryption: ->(key_id) { Rails.application.credentials.parquet_keys[key_id] })
```

The block is your key management: it gets the id from the file and returns the key (a `Key` or
bytes), or nil. There is no envelope encryption (per-file data keys wrapped by a KMS), see
[Key management](#key-management). `Herringbone::EncryptionConfiguration.simple(key)` is what
`encryption: key` turns into.

For anything finer:

```ruby
Herringbone::Writer.open(file, schema, encryption: {
  footer_key: FOOTER_KEY,                               # 16, 24 or 32 bytes (AES-128/192/256)
  footer_key_metadata: "orders-footer-v3",             # stored in the file, to find the key by
  columns: {
    "ssn" => {key: SSN_KEY, key_metadata: "pii-v7"},    # its own key
    "address" => ADDRESS_KEY,                           # a struct: all of its columns
    "email" => :footer                                  # the footer key
  }
}) { |w| rows.each { |row| w << row } }

Herringbone.write(io, rows, encryption: {footer_key: FOOTER_KEY}) # every column, with the footer key
```

The Hash is turned into a `Herringbone::EncryptionConfiguration`, which checks every setting
(keys, algorithm, column settings) when it is built; build one yourself to check settings up front
or to reuse them. It is frozen and its `#inspect` leaves the keys out. `decryption:` likewise takes
a Hash or a `Herringbone::DecryptionConfiguration`.

Columns not listed in `columns:` are written in the clear; without `columns:` every column is
encrypted with the footer key. Keys are binary Strings (`["00112233..."].pack("H*")` for hex).
Encrypted columns have their pages, page headers, statistics, page index and bloom filter
encrypted; statistics and the page index still drive `where:` for readers that have the key.

The other settings:

- `plaintext_footer: true` leaves the footer readable (and signs it), so readers without keys,
  including those that don't know about encryption, can read the plaintext columns. The footer
  then keeps no statistics of the encrypted columns.
- `algorithm: :aes_gcm_ctr` encrypts pages with AES-CTR instead of AES-GCM: a little faster, but
  page contents are no longer authenticated (headers and metadata still are).
- `aad_prefix: "orders/2026-10-03/part-0"` binds the file to an identity, so it can't be passed
  off as another file encrypted with the same keys. It is stored in the file, unless
  `store_aad_prefix: false`, in which case readers have to supply it.

### Which settings other tools read

What each Parquet implementation can decrypt, as of late 2026. Herringbone's own interop tests
cover pyarrow; the rest comes from their documentation and source code.

| Reader | Keys | Limits |
|---|---|---|
| pyarrow 25+ | one key: `pq.read_table(path, decryption_properties=pyarrow.parquet.encryption.create_decryption_properties(key))` | single-key API: uniform encryption only; anything else needs `CryptoFactory` and a KMS client reading key tools JSON (see Key management) |
| Arrow C++, arrow-go, ParquetSharp | footer key, column keys, key retriever | none |
| arrow-rs, DataFusion | footer key (`format.crypto.file_decryption.footer_key_as_hex`), column keys, key retriever | no AES-CTR, no 192-bit keys; the `datafusion` Python wheel is built without encryption |
| parquet-java, Spark 3.2+, Hive | key tools JSON through a KMS client class; plain keys need a small `DecryptionPropertiesFactory` returning the footer key | none |
| Trino 478+ (Hive connector) | footer and column keys from environment variables | read only |
| DuckDB 1.5 | one key (`PRAGMA add_parquet_key`) | encrypted footer, uniform, AES-GCM, no AAD prefix; 1.5.6 fails on column chunks with more than one page or with a bloom filter, also for files pyarrow writes |
| Polars, ClickHouse, Parquet.Net | none | can't read encrypted files |

`EncryptionConfiguration.simple` stays inside all those limits except DuckDB's page bug. Files
written by DuckDB don't follow the spec (no AAD, no column crypto metadata), and Herringbone can't
read them.

### Reading encrypted files

```ruby
reader = Herringbone::Reader.new(file, decryption: {
  footer_key: FOOTER_KEY,
  columns: {"ssn" => SSN_KEY, "address" => ADDRESS_KEY}
})
reader.read(where: {ssn: "123-45-6789"})
```

Instead of (or besides) giving keys, `keys:` looks them up by the key metadata stored in the file:
a Hash, or anything responding to `#call`, returning nil for keys the caller has no access to.
Each key metadata is looked up once per Reader. A callable that takes two parameters also gets
what the key is for (`:footer` or the column's dotted path), and is called for keys the file
stores no metadata for, with nil.

```ruby
Herringbone::Reader.new(file, decryption: {keys: ->(key_metadata) { kms.data_key(key_metadata) }})
```

A file with a plaintext footer opens without keys; its plaintext columns read as usual, and the
footer signature is checked whenever the footer key is available. Reading or filtering on an
encrypted column whose key is missing raises `Herringbone::DecryptionError`, naming the column and
its key metadata, so `columns:` can leave it out. A wrong key, an AAD prefix that doesn't match,
or changed bytes also raise `DecryptionError`. `reader.encryption` describes how a file is
encrypted (algorithm, footer mode, key metadata, which columns are readable), nil when it isn't.

Files from parquet-mr 1.12+ and Arrow (both algorithms, both footer modes, AAD prefixes stored or
supplied) are read, and pyarrow reads the files Herringbone writes.

### Key management

The file only stores the key metadata you give it; turning that back into a key is up to you.
Common schemes: the metadata names a key in a KMS or secret store; or it holds a data key
encrypted ("wrapped") with a master key, which the KMS unwraps. Herringbone doesn't implement
parquet-mr's and pyarrow's key tools format (JSON key material with wrapped data keys), but a
`keys:` resolver can read it: `JSON.parse(key_metadata)` gives the master key id and the wrapped
data key for your KMS to unwrap. Keys are per file and per column, not per row, so encryption
does not replace deleting a person's rows (see [Redaction](#redaction)). AES-GCM allows about 4
billion encryptions per key, two per page; the writer raises before going over.

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

## Redaction

`Herringbone.redact` rewrites a file with rows removed or values replaced, for GDPR "forget me"
requests and pseudonymization. One file goes in and one comes out, and the parts of the file
nothing touches are copied byte for byte.

```ruby
# Forget me: remove the rows
Herringbone.redact(io, output_io) do |r|
  r.where(user_id: 42).delete
end

# Forget me, but keep the row for accounting: blank the personal columns
Herringbone.redact(io, output_io) do |r|
  r.where(user_id: 42).replace(email: nil, name: nil, address: nil)
end

# Forget me, but keep the row linkable: pseudonymize just that user's email
Herringbone.redact(io, output_io) do |r|
  r.where(user_id: 42).replace(:email) { |email| OpenSSL::HMAC.hexdigest("SHA256", KEY, email) }
end

# Pseudonymize a column across the whole file, mask another, drop a third
Herringbone.redact(io, output_io) do |r|
  r.replace(:email) { |email| OpenSSL::HMAC.hexdigest("SHA256", KEY, email.downcase) }
  r.replace(:phone) { |phone| phone && "***#{phone[-3..]}" }
  r.drop :ssn, :ip_address
end
```

### Statements

The block receives the redaction being built, like `Writer.open` passes the writer, so it can use
the methods and instance variables around it; a block without the `|r|` raises `ArgumentError`.
`where` takes what `read(where:)` takes (values, Arrays, Ranges, `nil`, callables and dotted
struct paths, but no columns inside lists or maps), and skips row groups and pages the same way.
`where(...).delete` removes the matching rows. `replace` sets constants,
`replace(email: nil, name: "[deleted]")`, or computes each value with a block,
`replace(:email, :phone) { |value| ... }`. A block that takes two parameters also gets the whole
row, as a Hash with String keys like `read` returns. Without `where`, `replace` applies to every
row. A column is a top-level field or a struct member by dotted path (`"address.city"`; a member
of a null struct is left alone). To change what is inside a list or map, replace the whole field
with a block that receives the Array or Hash. `drop :a, :b` removes columns from the schema.

Statements apply in declared order, row by row: a deleted row is gone for later statements, and
later statements see what earlier ones replaced, in their conditions as well as in their blocks.
Mistakes raise `ArgumentError` before anything is written: a `where` without a verb, a column that
doesn't exist, `nil` (or a value of the wrong type) for a `null: false` column. A block that
returns something its column can't store raises `Herringbone::EncodeError` when it gets there and
leaves the output unfinished.

### Reusable redactions and reports

A `Herringbone::Redaction` is built once and applies itself to any number of files, which suits a
forget-me job going over a bucket:

```ruby
forget = Herringbone::Redaction.new do |r|
  r.where(user_id: 42).delete
  r.where(email: "anna@example.com").delete     # separate statements OR together
  r.where(created_at: ..2.years.ago).delete      # retention works the same way
end

if forget.affects?(io)         # statistics and bloom filters first, then the where columns only
  report = forget.apply(io, output_io)
  report.rows_deleted          # => 3
  report.row_groups            # => { copied: 61, rewritten: 1 }
end
```

The `Redaction::Report` that `apply` returns has `rows_read`, `rows_deleted`, `rows_changed` and
`row_groups` (`{ copied:, rewritten: }`), which is the audit trail an erasure needs.

### Input and output

`apply` and `Herringbone.redact` take IOs like `Reader` and `Writer` do: the input must be
seekable, the output only needs `#write`, and neither is closed. Herringbone doesn't open files by
path, so open them yourself. The input can also be a `Herringbone::Reader` you already have, and
then its IO and its decryption are used. Whatever `keys:` or `time_zone:` it was built with, the
redaction reads values the same way (and blocks get rows with String keys):

```ruby
reader = Herringbone::Reader.new(io, keys: :symbol, decryption: {keys: kms_lookup})
Herringbone.redact(reader, output_io) { |r| r.where(user_id: 42).delete }
```
 To redact in place, write to a
temporary file and rename it over the original; on S3, read the object and write the new one
through `upload_stream`.

### How row groups are rewritten

Each row group is handled in the cheapest way that is still exact. If no statement can match it,
judging by statistics, bloom filters and the page index, or by reading only the `where` columns,
its column chunks are copied as they are and only their offsets are rebased. If rows match but
none is deleted and only leaf columns change, just those column chunks are encoded again. If rows
are deleted, or a nested field is replaced whole, the row group is rewritten, as one row group
(or none, when every row goes). Rewritten chunks keep the codec of the original chunk (LZO, which
Herringbone can't write, becomes Snappy) and get a new bloom filter if they had one. Writer
options (`compression:`, `bloom_filters:`, `page_rows:`...) apply to the rewritten chunks;
`row_group_bytes:` and `row_group_rows:` are refused, since row groups keep their boundaries. The
footer's key/value metadata is copied (without `ARROW:schema` and `pandas` when columns are
dropped, since those describe the columns) unless `metadata:` is given.

### What gets erased, and what doesn't

No deleted or replaced value survives in the output: not in data pages, dictionary pages, column
chunk min/max statistics, the page index or bloom filters. What Herringbone can't reach is up to
you: the original file, its S3 versions and backups still hold the data until you delete them,
only the columns you name are touched (an email that also sits in a free-text `notes` column stays
there), and other files with the same person in them need their own pass.

### Encrypted files

Pass the input's keys in `decryption:`. The output is then encrypted the same way: same algorithm,
footer mode, AAD prefix, keys and key metadata, for the columns that are kept. `encryption:` (as
for `Writer`) writes it with other settings, and `encryption: false` writes a plaintext file.
`Redaction#affects?` takes `decryption:` too. A `Herringbone::Reader` brings its own keys, so
`decryption:` is not given with one.

```ruby
Herringbone.redact(io, output_io, decryption: {keys: kms_lookup}) do |r|
  r.where(user_id: 42).delete
end
```

Encrypted column chunks can't be copied byte for byte, since their encryption is tied to the file
and to their position in it, so they are encoded again even in row groups no statement touches.
Every key of the columns being kept must be available.

### Recipes

Keyed hashing keeps a column joinable without keeping the value; keep the key out of the data, and
rotate or destroy it to cut the link:

```ruby
require "openssl"
KEY = ENV.fetch("PSEUDONYM_KEY")
Herringbone.redact(io, output_io) do |r|
  r.replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", KEY, email.downcase) }
end
```

Masking keeps enough to be recognizable to the person but not to anyone else:

```ruby
Herringbone.redact(io, output_io) do |r|
  r.replace(:card_number) { |number| number && number[-4..].rjust(number.size, "*") }
  r.replace(:email) { |email| email&.sub(/\A(.).*@/, '\1***@') }
  r.replace(:birth_date) { |date| date && Date.new(date.year, 1, 1) }
end
```

Fake values (with the `faker` gem) make a copy for staging that looks real. Seed Faker from the
original value to get the same fake for the same person in every file:

```ruby
require "faker"
require "zlib"
Herringbone.redact(io, output_io) do |r|
  r.replace(:name) do |name|
    next nil unless name
    Faker::Config.random = Random.new(Zlib.crc32(name))
    Faker::Name.name
  end
  r.replace(:address) do |address|
    address && { "city" => Faker::Address.city, "zip" => Faker::Address.zip_code }
  end
end
```

## Combining files

`Herringbone.combine` concatenates Parquet files into one: every row group of every input, in
order. The inputs are seekable IOs and the output any IO with `#write`, like for `Reader` and
`Writer`, and none of them is closed.

```ruby
paths = %w[2026-01.parquet 2026-02.parquet 2026-03.parquet]
inputs = paths.map { |path| File.open(path, "rb") }
File.open("2026-q1.parquet", "wb") { |out| Herringbone.combine(inputs, out) }
inputs.each(&:close)
```

When the inputs have the same schema, nothing is decoded: the column chunks are copied byte for
byte, with their statistics, page indexes and bloom filters, and only the offsets pointing at them
are rebased. Row groups keep their boundaries, so a hundred small files make a file of a hundred
small row groups; to merge row groups, read the files and write the rows with `Writer` instead.
`combine` returns a `Combiner::Report` with `rows` and `row_groups` (`{ copied:, rewritten: }`).

The footer's key/value metadata is the first input's (without `ARROW:schema` and `pandas` when the
output schema is another than the first input's), unless `metadata:` is given. Writer options
(`compression:`, `page_rows:`...) apply to the column chunks that have to be encoded again;
`row_group_bytes:` and `row_group_rows:` are refused. Those chunks keep the codec of the original
chunk, and get a bloom filter if they had one.

### Comparing and uniting schemas

Two schemas are `==` when they have the same fields in the same order, with the same names,
nullability, physical types, annotations, field ids and nesting. `eql?` and `hash` agree, so
schemas work as Hash keys. What does not count: the name of the root (`schema`, `spark_schema`,
`duckdb_schema`...), `enum values:` (which are not stored in the file), the footer's key/value
metadata (which is not part of the schema), and the legacy converted type of a column that has a
logical type, since writers differ in whether they store both. A pyarrow file and a Herringbone
file holding the same columns usually compare equal. `difference` says where two schemas part:

```ruby
a.schema.difference(b.schema).to_s # => "address.zip: optional INT32 zip vs optional BYTE_ARRAY zip (STRING)"
```

Without `schema:`, every input must have the schema of the first, or `combine` raises
`ArgumentError` before writing anything, naming the column:

```
The schema of input 2 differs from that of input 0: address.zip: optional INT32 zip in input 0,
optional BYTE_ARRAY zip (STRING) in input 2. Combine files with the same schema, or pass schema: ...
```

For files whose columns differ, `+` unites two schemas: the fields of the first, then the fields
only the second has. Fields only one side has become nullable, and so does a field that is
required on one side and nullable on the other. Fields are matched by name at the top level only,
and anything else that differs (types, struct members, list elements) raises `ArgumentError`.
Pass the union as `schema:`:

```ruby
schemas = inputs.map { |io| Herringbone::Reader.new(io).schema }
Herringbone.combine(inputs, out, schema: schemas.reduce(:+))
```

Each input's fields are then fitted to `schema:`, in whatever order the input has them. Fields an
input has as they are in `schema:` are still copied; fields it lacks are written as nulls, and
fields it has required where `schema:` has them nullable are encoded again. An input with a field
`schema:` lacks, or lacking a field `schema:` requires, raises `ArgumentError`.

### Combining encrypted files

Pass the keys of encrypted inputs in `decryption:`, as for `Reader` (`[key, older_key]` lets each
file find its own). An encrypted column chunk can't be copied, since its encryption is tied to the
file and to its position in it, so it is decrypted and encoded again. When an input is encrypted,
`encryption:` (as for `Writer`) is required, so a file is never decrypted by accident:
`encryption: false` writes a plaintext file on purpose. Plaintext inputs can go into an encrypted
output too; their columns that get encrypted are encoded again and the rest are copied.

```ruby
Herringbone.combine(inputs, out, decryption: [key, older_key], encryption: key)
```

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
> the design and the idea are theirs. Go check it out. It is amazing!

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

An encrypted file takes `decryption:` as for `Reader`. With a plaintext footer it opens without
keys, showing the encrypted chunks without their pages and page indexes; `summary` and `report`
say how the file is encrypted. Encrypted pages are checked against their CRCs as stored, without
decrypting them.

`inspector.verify_checksums` reads every page body (still without decompressing) to check the page
CRCs; the results then appear in `summary`, `report`, `to_h` and `to_html`.

## Command line

```
bin/herringbone cat FILE [N]                           # rows as JSON lines
bin/herringbone inspect FILE [--pages]                 # text report (--pages lists every page header)
bin/herringbone inspect FILE --format=json             # everything as JSON
bin/herringbone inspect FILE --format=html             # the HTML page, opened in your browser
bin/herringbone inspect FILE --format=html > out.html  # the HTML page, saved
```

Add `--verify-checksums` to any `inspect` form to check page CRCs.

Encrypted files take keys on the command line: as they are (picked by their fingerprint id, like
a keyring), or for the footer, a column path or the key id the file stores (which `inspect`
shows):

```
bin/herringbone cat FILE --key=$PARQUET_KEY
bin/herringbone inspect FILE --footer-key=00112233445566778899aabbccddeeff
bin/herringbone cat FILE 10 --key=kc1=base64:MTIzNDU2Nzg5MDEyMzQ1MA== --column-key=ssn=raw:1234567890123450
bin/herringbone inspect FILE --aad-prefix=orders/part-0 --no-prompt
```

Keys are hex, `base64:...` or `raw:...` (a 16, 24 or 32-character key that isn't valid hex is
taken as typed too). A key the file needs but wasn't given is asked for on stdin, without echo in
a terminal; an empty answer leaves that column unreadable. `--no-prompt` asks for nothing.

`--format` is `text` (the default), `json` or `html`; `--pages` only goes with `text`.
In a terminal, `--format=html` writes the page to a temp file, prints its path and opens it with
`open` on macOS, `start` on Windows or `xdg-open` elsewhere. When stdout is redirected or piped it
prints the page instead.

## Supported format features

- Encodings (read and write): PLAIN, PLAIN_DICTIONARY/RLE_DICTIONARY, RLE, DELTA_BINARY_PACKED,
  DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, BYTE_STREAM_SPLIT; legacy BIT_PACKED levels (read)
- Data page v1 and v2, dictionary pages, page CRCs (written)
- Page indexes and split block bloom filters (read and written)
- Legacy list and map layouts per the Parquet backward-compatibility rules
- LZO-compressed files (read only)
- Modular encryption (read and write): AES_GCM_V1 and AES_GCM_CTR_V1, encrypted and plaintext
  footers, footer and column keys, AAD prefixes
- Not supported: column chunks in external files

## Development

```
bundle install
bundle exec rake test
HERRINGBONE_PYTHON=/path/to/python-with-pyarrow bundle exec rake test   # also run pyarrow interop tests
```

`test/fixtures/parquet-testing` holds files from [apache/parquet-testing](https://github.com/apache/parquet-testing)
(Apache-2.0); expectations for them were generated with pyarrow, see `test/fixtures/generate_expectations.py`.
