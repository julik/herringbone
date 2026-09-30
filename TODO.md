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

Follow-ups — done:
- `reader.inspector`
- Opt-in page CRC verification: `Inspector#verify_checksums`, `to_h(checksums: true)`,
  `report(checksums: true)`, `Visualizer.new(io, checksums: true)`, CLI `--verify-checksums`
  (per page ok/mismatch/absent, a summary badge and a per-page column in the HTML)
- ARROW:schema decoded in pure Ruby (`Inspector::ArrowSchema`, a small flatbuffer reader):
  Arrow field names and types (pyarrow's spelling), nested children, timestamp time zones,
  dictionary encoding, extension names and field/schema metadata, shown next to the Parquet
  schema; falls back to the abbreviated display with an error note when it can't be decoded
- Page header statistics compared with the ColumnIndex (`chunk.index_mismatches`,
  `inspector.index_mismatches`): narrower index bounds, differing null counts, null pages with
  values and page count mismatches are flagged in the report and the HTML

Possible follow-ups:
- Compare the OffsetIndex page sizes/first rows with the page headers the same way (tests do,
  the inspector doesn't report it)

## 4. Pushdown structures

### Page indexes — done (writing)

ColumnIndex + OffsetIndex for every column chunk (column index where a sort order is defined),
`page_row_limit:` (20k rows per page), sort orders for unsigned/decimal/float16, 64-byte
truncation of byte-array bounds. Verified against DataFusion's page pruning in CI.
Possible follow-up: use page indexes when reading (skip pages for row ranges / predicates).

### Bloom filters — done (reading and writing)

`Herringbone::BloomFilter` (split block, 8 spec salts) with a pure-Ruby XXH64 (`Herringbone::XXHash`,
masked Bignum arithmetic: faster on MRI than 32-bit limbs; ~690k/s for 8-byte values, ~320k/s for
20-byte strings). Writer option `bloom_filters:` (`true`, paths, or `{ path => { ndv:, fpp:, max_bytes: } }`;
sized from counted distinct values when ndv is not given), written after each row group's chunks
with `bloom_filter_offset`/`bloom_filter_length`. Reader: `bloom_filter(rg, path)`,
`row_groups_that_may_contain(path, value)` (values go through the column encoder). Verified against
the parquet-testing fixtures (parquet-mr without length, parquet-rs with length), a pyarrow-written
fixture covering every physical type, pyarrow reading our files, and DataFusion pruning row groups.
Possible follow-ups: let the Inspector reuse `Format::BloomFilterHeader`; a row-level
`where:`-style API that combines statistics and bloom filters to pick row groups.
