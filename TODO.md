# TODO

Priorities: writing over reading, native Ruby types, ergonomics over a few % of speed.

## 1. Writer ergonomics and Ruby types (next)

- **`Schema.from_active_record(Model)`**, duck-typed on `columns_hash` / `defined_enums` so Rails is
  not a dependency. Maps SQL types, `null: false`, decimal precision/scale, `jsonb`, `uuid`,
  Postgres arrays → lists, and Rails enums → string columns (optionally validated against the
  enum's values)
- **Column types accept what Rails hands you:**
  - `json` given a Hash/Array → `JSON.generate` (today it writes Ruby `inspect` output — bug)
  - `time` given a `Time` (Rails time-of-day columns) → time since midnight in the column's unit
  - `date` given an ISO-8601 String; `timestamp` given an ISO-8601 String
  - `enum`: write it as a STRING with dictionary encoding by default, since pyarrow and pandas read
    the ENUM annotation as binary; keep `values:` for validation
  - Audit every type for Symbol, BigDecimal, Rational, Date/DateTime/Time/TimeWithZone inputs
- **Hash schemas:** `Schema.define(id: :int64, name: :string, tags: [:string])` for flat and
  simple nested cases without the block DSL
- **Better `Schema.infer`:** widen int → double across the sample; nil-only columns take a type from
  `types: { col: :string }`; detect JSON-ish Hashes when asked
- **Array rows** in schema order (`w << [1, "x"]`), as well as Hashes / Structs / Data objects
- **Error messages** that name the row number and the full column path
- **`Writer.open` takes an IO too**; path writes go to a temp file and are renamed on close,
  so a crash never leaves a truncated file
- **zstd as the default codec** now that zstd-ruby is a dependency (~2x faster writes than the
  pure-Ruby snappy and smaller files in the benchmark)
- **Byte-based row group flushing** (`row_group_bytes:`, default e.g. 128 MB) with `row_group_size:`
  as an optional row cap, so memory is predictable for wide rows

## 2. Reading ergonomics

- **Streaming reads:** the reader materializes a whole row group before yielding rows. Files with
  huge row groups (parquet-rs writes up to 1M rows per group) cost ~750 MB RSS per 1M rows of the
  benchmark schema. Read page by page / in row batches across the columns of a row group instead
- `keys: :symbol` option for rows; batch iteration (`each_batch(size)`)
- Optional `time_zone:` for returned timestamps (e.g. `Time.zone` in Rails)

## 3. Pushdown structures (later)

### Bloom filters (read + write)

- Thrift structs: `BloomFilterHeader` (numBytes, algorithm/hash/compression unions with one member each)
- Pure-Ruby XXH64 (seed 0) — needs masked 64-bit arithmetic; benchmark bignum-masking vs 32-bit limbs.
  Verify against the published XXH64 test vectors.
- Split Block Bloom Filter: 32-byte blocks of 8 x u32, the 8 spec salt constants,
  block = ((hash >> 32) * num_blocks) >> 32, one bit per word from the low 32 bits
- Hash input is the PLAIN encoding of the *physical* value (no length prefix for BYTE_ARRAY);
  reuse the column encoders so `might_contain?(Date.today)` hashes the right bytes
- Reader: `reader.bloom_filter(row_group, "col").might_contain?(value)` and a helper that yields
  only row groups that may contain a value
- Writer: `bloom_filters: { "col" => { ndv:, fpp: } }` (or size from counted distinct values);
  size per spec formula, power of two in 32B..128MB; write after the row group's chunks, set
  `bloom_filter_offset` / `bloom_filter_length`
- Fixtures: parquet-testing `data_index_bloom_encoding_stats.parquet`,
  `data_index_bloom_encoding_with_length.parquet`; interop-check with pyarrow

### Page indexes (ColumnIndex / OffsetIndex)

- Per-page min/max/null counts and page locations, for page-level predicate pushdown
- Same order of work as bloom filters; best done together. Writing them helps downstream engines
  (DuckDB, Spark, Trino) skip data in files we produce
