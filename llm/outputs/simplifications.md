# API simplification: open proposals

The simplification pass (commit `a244401`, "Simplify the public API") applied everything that
removed a *duplicate way* of doing something. The items below were left for a decision: either
they remove a capability, or they were judged borderline. Nothing here is applied yet.

## Proposals not applied

1. **Stop writing the deprecated Hadoop-framed LZ4 codec (`:lz4_hadoop`).**
   Keep reading it (older parquet-mr and Arrow files use it), but only offer `:lz4` (LZ4_RAW)
   for writing. The Parquet spec deprecates the Hadoop framing and newer readers may reject it.

2. **`Writer#flush_row_group`: document it or make it private.**
   It is public but undocumented. It lets callers end a row group at a chosen point (e.g. one
   row group per day or per tenant, which makes row-group pruning very effective). Either
   document it as the way to control row-group boundaries, or hide it and rely on
   `row_group_rows:` / `row_group_bytes:` alone.

3. **Move the Inspector's internal helpers into a private module.**
   About 20 helpers are public only because the Inspector's info objects call them
   (`walk_pages`, `read_column_index`, `decode_statistics`, `page_crc`, `hex`, `human_bytes`, …).
   They are not documented, but they show up in the class's public methods. Moving them into a
   private module would shrink `Inspector`'s surface to what the README describes
   (`summary`, `row_groups`, `report`, `to_h`, `to_html`, `verify_checksums`). This was left out
   only to avoid churning a 1,400-line file.

4. **`row_groups` means two different things.**
   `Reader#row_groups` returns raw Thrift `RowGroup` structs, while `Inspector#row_groups` returns
   info objects with sizes, codecs and statistics. Options: rename the Reader one (or make it
   internal alongside `file_metadata`, `page_index` and `bloom_filter`, which stay public only
   because `where:` uses them), or have the Reader return the same info objects.

5. **`HERRINGBONE_NO_IO_BUFFER` environment variable.**
   It forces the String-based Snappy decompressor instead of the `IO::Buffer` one. It looks like
   an internal CI switch (the "Without IO::Buffer" job) rather than something users need; it could
   become a test-only setting.

6. **Niche writer options and types that could go later.**
   - `data_page_version:` (v1 pages are the default and the most compatible)
   - `encodings:` (per-column value encodings)
   - `dictionary:` as an Array of column paths (keep `true`/`false`)
   - the `int96` type (a legacy Impala/Spark timestamp encoding; reading it is still needed)
   - the `bson` type
   - `field_id:` on schema fields

## Borderline changes that were applied (review these)

- **Writer option names unified:** `row_group_size` → `row_group_rows`, `page_size` →
  `page_bytes`, `page_row_limit` → `page_rows` (alongside `row_group_bytes`). Before, "size" meant
  rows for row groups but bytes for pages.
- **`statistics: false` and `page_index: false` removed:** statistics and page indexes are always
  written, so files without them can no longer be produced.
- **Hash schemas removed** (`Schema.define(id: :int64, tags: [:string])`); only the block DSL
  remains. Dynamic schemas can use `column :name, type` inside a block.
- **Per-call `keys:` / `time_zone:` removed:** they are set once on `Reader.new`.
- **CLI default output is now text** instead of HTML (`herringbone inspect FILE --html` for the
  page).
