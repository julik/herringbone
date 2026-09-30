# TODO

## Bloom filters (read + write)

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

## Page indexes (ColumnIndex / OffsetIndex)

- Per-page min/max/null counts and page locations, for page-level predicate pushdown
- Same order of work as bloom filters; best done together if pushdown is the goal
