# Herringbone

A pure-Ruby reader and writer for [Apache Parquet](https://parquet.apache.org/) files.

- No Thrift gem and no native extensions of its own: the Thrift compact protocol, all encodings
  and the Snappy and LZ4 codecs are implemented in Ruby (ZSTD and Brotli use optional gems).
  LZO, from Hadoop-era files, can be read but not written
- Full nesting support (structs, lists, maps, any depth) via Dremel record shredding/assembly
- Reads files from parquet-mr, Arrow, Spark, Impala, DuckDB, Rust writers etc.
- Optimized reads with batches and pages
- Parquet modular encryption (per column and of the footer), interoperable with parquet-mr and Arrow
- Ruby 3.0+

This README covers the common cases. The [MANUAL](MANUAL.md) has everything else: reader and
writer options, schemas and column types, bloom filters, Numo arrays, encryption, the redaction
rules, type mapping and the inspector.

## Installation

```ruby
gem "herringbone"
```

Optionally add `snappy` (faster), `zstd-ruby` and `brotli` (more codecs), `xxhash` (faster bloom
filters) or `numo-narray-alt` (`read(as: :numo)`). Herringbone uses whichever of them are loaded,
see [Optional gems](MANUAL.md#optional-gems).

## Exporting from Rails

Stream a relation straight into S3, no temp file needed:

```ruby
s3 = Aws::S3::TransferManager.new
s3.upload_stream(bucket: "exports", key: "payments.parquet") do |io|
  # Schema will be auto-inferred, find_each will be used automatically
  Herringbone.write(io, Payment.where(status: "settled", created_at: 1.month.ago..))
end
```

Or to a local file:

```ruby
File.open("orders.parquet", "wb") do |file|
  Herringbone.write(file, Order.where(created_at: 1.year.ago..), compression: :zstd)
end
```

Any Enumerable of Hashes, Structs or Arrays works too; the schema is inferred from the first 1000
rows. See [ActiveRecord](MANUAL.md#activerecord) and [Writing to S3](MANUAL.md#writing-to-s3).

## Reading

```ruby
File.open("data.parquet", "rb") do |file|
  reader = Herringbone::Reader.new(file)
  reader.num_rows

  reader.each_row { |row| p row }        # Hashes with String keys, nested values as Hash/Array
  reader.each_batch(1000) { |rows| ... } # Arrays of up to 1000 rows
  reader.read                            # all rows at once

  reader.read(columns: %w[id name], where: { user_id: 42 })
  reader.read(where: { status: %w[paid shipped], created_at: 1.week.ago.. })
end
```

Reads stream page by page, and `where:` skips row groups and pages it can rule out using
statistics, page indexes and bloom filters. See [Reading](MANUAL.md#reading).

## Writing CSV-style

`SimpleWriter` writes like the CSV gem: name the columns, then append rows. The types are inferred.

```ruby
File.open("people.parquet", "wb") do |file|
  Herringbone::SimpleWriter.open(file) do |sw|
    sw.headers!(:id, :name, :age)
    sw << [123, "John", 12]
    sw << { id: 124, name: "Jane" } # Hashes work too
  end
end
```

To control the types, declare a schema and use `Herringbone::Writer`, see
[Writing](MANUAL.md#writing).

## Encrypting

Parquet files tend to wander off: to S3 buckets, laptops, other teams. Encrypting them takes one
key and one line, no KMS, no Hadoop configuration. Make a key once and keep it with your other
secrets:

```ruby
Herringbone::Key.generate.hex # => "9f86d081884c7d65..." - put it in your credentials or ENV
```

Then write with it:

```ruby
File.open("people.parquet", "wb") do |file|
  Herringbone::SimpleWriter.open(file) do |sw|
    sw.encrypt!(key: ENV["PARQUET_KEY"])
    sw.headers!(:id, :name, :email)
    sw << [1, "John", "john@example.com"]
  end
end
```

and read with it:

```ruby
Herringbone::Reader.new(file, decryption: ENV["PARQUET_KEY"]).read
```

The schema, the values and the statistics are all encrypted (AES-256-GCM); without the key the
file is just noise. `encryption: key` does the same for `Herringbone.write` and
`Herringbone::Writer`. Your colleagues can open the file with the same key in pyarrow 25+
(`pq.read_table(path, decryption_properties=pyarrow.parquet.encryption.create_decryption_properties(bytes.fromhex(key)))`),
Arrow, DataFusion, Trino or Spark, and `herringbone inspect people.parquet` asks for the key.
When the time comes to rotate, read with all your keys, `decryption: [new_key, old_key]`, and
each file finds its own. See [Encryption](MANUAL.md#encryption) for per-column keys, plaintext
footers and which tools read what.

## Redacting

`Herringbone.redact` rewrites a file with rows removed or values replaced, for GDPR "forget me"
requests and pseudonymization. The parts of the file nothing touches are copied byte for byte.

```ruby
# Forget me: remove the rows
Herringbone.redact(input, output) do |r|
  r.where(user_id: 42).delete
end

# Forget me, but keep the row for accounting: blank the personal columns
Herringbone.redact(input, output) do |r|
  r.where(user_id: 42).replace(email: nil, name: nil, address: nil)
end

# Pseudonymize a column across the whole file, mask another, drop a third
Herringbone.redact(input, output) do |r|
  r.replace(:email) { |email| OpenSSL::HMAC.hexdigest("SHA256", KEY, email.downcase) }
  r.replace(:phone) { |phone| phone && "***#{phone[-3..]}" }
  r.drop :ssn, :ip_address
end
```

See [Redaction](MANUAL.md#redaction) for reusable redactions, reports and recipes.

## Looking inside a file

```
bin/herringbone cat FILE [N]                 # rows as JSON lines
bin/herringbone inspect FILE                 # schema, row groups, column chunks
bin/herringbone inspect FILE --format=html   # a byte map of the file, opened in your browser
```

See [Inspecting files](MANUAL.md#inspecting-files) and [Command line](MANUAL.md#command-line).

## Development

See [Development](MANUAL.md#development) and [CONTRIBUTING](CONTRIBUTING.md).
