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

## 2. Reading ergonomics — done

Streaming reads: pages are read lazily (seek + read per page) and decoded one at a time per
column; rows are assembled in batches (`each_batch(size)`, `each_row` on top of it), with values
converted to Ruby objects per batch. 1M rows in one row group: 662 → ~160 MB peak RSS growth,
107k → 158k rows/s (`benchmark/streaming_read.rb`). `keys: :symbol` and `time_zone:` options.

Possible follow-ups:
- Decode within a page incrementally (RLE runs, PLAIN values) to bound memory by the batch
  alone; today a decoded page (up to ~200k entries for dictionary-encoded 1MB pages) is held
- Use the OffsetIndex to skip pages/rows (`each_row(from:)`)

## 3. Inspecting files without reading the data — done

`Herringbone::Inspector` (footer, page headers, page indexes and bloom filter headers only; never
decompresses): summary, schema tree, key/value metadata, row groups, column chunks with decoded
statistics and caveats, every page header, ColumnIndex/OffsetIndex, per-column totals, a byte
`layout` of the whole file, `to_h` (JSON) and a text `report`. `Herringbone::Visualizer` renders it
as a self-contained HTML page (design and idea from
[Parquet X-ray](https://huggingface.co/spaces/cfahlgren1/parquet-xray) by cfahlgren1):
`bin/herringbone inspect FILE [OUT]`, `--text`, `--json`.

Possible follow-ups:
- `reader.inspector` convenience (`Inspector.new(reader)` works already)
- Verify page CRCs (needs reading page bodies, so opt-in)
- Decode the ARROW:schema flatbuffer to show Arrow types next to Parquet ones
- Compare page statistics with the page index and flag disagreements

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
