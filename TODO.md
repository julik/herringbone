# TODO

Priorities: writing over reading, native Ruby types, ergonomics over a few % of speed.

## 1. Writer ergonomics and Ruby types — done

`Schema.from_active_record`, Hash schemas, Array/`#attributes`/`#to_h` rows, coercions for Rails
values (json, time of day, ISO dates/timestamps, TimeWithZone, booleans, numerics), `enum` as a
validated string column, row numbers in errors, atomic path writes and IO targets, snappy by
default with zstd/brotli as optional gems (clear MissingCodecError when absent), byte-based row groups (`row_group_bytes:`, 16MB default).

Buffering: levels are byte Strings, string/fixed columns are dictionary-encoded on the fly or
packed into byte buffers (ByteValues). 3M-row export: 370 → 285 MB RSS at 16MB row groups,
660 → 416 MB at 64MB.

`Herringbone.export(relation, target, **options)` combines `from_active_record` and `find_each`.

## 2. Reading ergonomics

- **Streaming reads:** the reader materializes a whole row group before yielding rows. Files with
  huge row groups (parquet-rs writes up to 1M rows per group) cost ~750 MB RSS per 1M rows of the
  benchmark schema. Read page by page / in row batches across the columns of a row group instead
- `keys: :symbol` option for rows; batch iteration (`each_batch(size)`)
- Optional `time_zone:` for returned timestamps (e.g. `Time.zone` in Rails)

## 3. Inspecting files without reading the data

- A visualizer that renders a file's layout as a self-contained HTML page with SVG: schema tree,
  row groups, column chunks and pages drawn to scale (compressed vs uncompressed size), codecs,
  encodings, dictionary pages, statistics, key/value metadata. `bin/herringbone html FILE > out.html`
- Methods to examine a file from its footer and page headers only, without decoding values:
  `reader.inspect_layout` / `reader.pages(row_group, column)` returning page headers (type,
  sizes, encoding, value counts, statistics, offsets), per-column totals and compression ratios,
  dictionary sizes, encoding stats, and a `reader.summary` for the CLI

## 4. Pushdown structures

### Page indexes — done (writing)

ColumnIndex + OffsetIndex for every column chunk (column index where a sort order is defined),
`page_row_limit:` (20k rows per page), sort orders for unsigned/decimal/float16, 64-byte
truncation of byte-array bounds. Verified against DataFusion's page pruning in CI.
Possible follow-up: use page indexes when reading (skip pages for row ranges / predicates).

### Bloom filters (not now)

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
