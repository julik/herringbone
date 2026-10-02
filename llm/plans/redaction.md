# Redaction

Rewrite a Parquet file with rows removed or column values replaced, for GDPR "forget me" and
pseudonymization. One file in, one file out, through IOs. Untouched parts of the file are copied
byte-for-byte.

## API

The principal entry point is `Herringbone::Redaction#apply(input_io, output_io)`: a Redaction is
built once and applies itself to any number of files. `Herringbone.redact(input, output, redaction
= nil, **writer_options, &block)` is a shortcut that builds the Redaction from the block (or takes
one) and calls `apply`.

```ruby
# Forget me: remove the rows
Herringbone.redact(input, output) do
  where(user_id: 42).delete
end

# Forget me, but keep the row for accounting: blank the personal columns
Herringbone.redact(input, output) do
  where(user_id: 42).replace(email: nil, name: nil, address: nil)
end

# Pseudonymize a column across the whole file, mask another, drop a third
Herringbone.redact(input, output) do
  replace(:email) { |email| OpenSSL::HMAC.hexdigest("SHA256", KEY, email.downcase) }
  replace(:phone) { |phone| phone && "***#{phone[-3..]}" }
  drop :ssn, :ip_address
end

# Built once, applied to many files (a forget-me job over a bucket)
forget = Herringbone::Redaction.new do
  where(user_id: 42).delete
  where(email: "anna@example.com").delete     # separate statements OR together
  where(created_at: ..2.years.ago).delete      # retention works the same way
end

if forget.affects?(input)      # stats and bloom filters first, then an exact scan of the where columns only
  report = forget.apply(input, output)
  report.rows_deleted          # => 3
  report.row_groups            # => { copied: 61, rewritten: 1 }
end
```

Rules:

- `where` takes exactly what `Reader#read(where:)` takes: equality, Arrays (IN), Ranges, `nil`
  (IS NULL), callables, dotted struct paths. It reuses `Reader::Filter`, so it gets the same row
  group and page skipping and the same restriction (no columns inside lists or maps).
- `where(...).delete` removes the matching rows.
- `replace` has two shapes. A Hash sets constants: `replace(email: nil, name: "[deleted]")`.
  Column names plus a block compute each value: `replace(:email, :phone) { |value, row| ... }`.
  The block receives the value, and the whole row (a Hash with String keys, as the Reader
  returns) as a second argument when it declares two parameters. Only assemble the full row when
  the block asks for it.
- `replace` without `where` applies to every row. `where` without a verb raises ArgumentError.
- A column is a top-level field or a struct member by dotted path. To change what is inside a
  list or map, replace the whole field with a block that receives the Array or Hash.
- `drop :a, :b` removes columns from the schema.
- Statements apply in declared order, per row. A deleted row is gone for later statements; later
  replaces see earlier results.
- Mistakes fail before any byte is written: replacing with nil on a `null: false` column, naming
  a missing column, or a `where` without a verb raise ArgumentError when the Redaction is built
  or when it is first checked against the file's schema in `apply`/`affects?`.
- IO only, like the rest of the gem. Input is any seekable IO (what `Reader` takes), output
  anything with `#write` (what `Writer` takes), never closed. In-place means write a temp file
  and rename; S3 means read the object and write through `upload_stream`.
- `apply` returns a `Redaction::Report`: `rows_read`, `rows_deleted`, `rows_changed`,
  `row_groups` (`{ copied:, rewritten: }`). This is the audit trail a GDPR erasure needs.
- `affects?(input_io)` returns whether `apply` would change anything, reading as little as
  possible: rule out row groups by statistics and bloom filters, then scan only the `where`
  columns of the rest. A Redaction with a bare `replace` or `drop` affects every non-empty file.
- Writer options (`compression:`, `bloom_filters:`, `page_rows:`...) are accepted by `apply`
  and `Herringbone.redact` and apply to rewritten chunks. By default a rewritten chunk keeps the
  codec of the source chunk; LZO cannot be written and falls back to snappy. Bloom filters are
  rebuilt for a rewritten chunk when the source chunk had one. Key/value metadata is copied;
  `metadata:` replaces it. `created_by` becomes herringbone's.

## How it runs

Each row group of the input lands in one of three tiers:

1. **Nothing matches: copy bytes.** Data pages, dictionary pages, bloom filters and the
   ColumnIndex are copied verbatim (none of them hold absolute offsets). The OffsetIndex,
   ColumnChunk, ColumnMetaData and RowGroup hold absolute file positions, so they are re-emitted
   with rebased offsets. A row group is proven clean either by statistics and bloom filters
   (`Filter#row_group_may_match?`, no data read) or by scanning just the `where` columns and
   finding no matching row. Callables in `where` therefore work, only slower.
2. **Rows match, nothing deleted, only leaf columns replaced: rewrite the touched chunks.** The
   chunks of replaced leaf columns are decoded (levels and values), mapped, and re-encoded through
   the Writer's column chunk path, which yields fresh statistics, dictionary, page index and bloom
   filter. Replacing a leaf with nil changes its definition levels; a required leaf cannot be
   nulled (caught up front). Every other chunk is copied as in tier 1.
3. **Rows deleted, or a nested top-level field replaced as a whole: rewrite the row group.** All
   rows of the row group are read, filtered and mapped, and written through the normal Writer
   path, since the row count changes and every column's statistics must be recomputed. Keep the
   row group boundary (one input row group becomes one output row group, or none if every row
   was deleted) so the rest of the file's layout is predictable.

Dropped columns are skipped during the copy and left out of the schema (Uber's "copy and skip").

Guarantee to document: no deleted or replaced value survives anywhere in the output. Not in
data pages, dictionary pages, chunk min/max statistics, page index min/max or bloom filters.
Caveats to document: the old file (S3 versions, backups) is the caller's to destroy; only the
columns named are touched; other files are not.

## Implementation notes

- New file `lib/herringbone/redaction.rb` (plus a `redaction/` directory if it grows): the
  builder DSL (`where`, `delete`, `replace`, `drop`), `Scope` returned by `where`, `Report`,
  the rewriter. `Herringbone.redact` in `lib/herringbone.rb`.
- Reuse `Reader::Filter` for the conditions, `Reader#page_index`, `ColumnChunkReader` for
  decoding single chunks, and the Writer for rewriting. The Writer needs a seam to (a) write a
  row group assembled from a mix of raw-copied chunks and freshly encoded chunks, and (b) write a
  whole row group's rows as one row group (`row_group_rows`/`row_group_bytes` must not split it,
  or it may; splitting is acceptable if simpler, but say so in the docs). Prefer adding small
  internal methods to Writer over duplicating its page/index/footer code.
- Raw copy: read the chunk's byte range (`file_offset`/`dictionary_page_offset`..
  `data_page_offset + total_compressed_size`), write it, and clone the ColumnMetaData/ColumnChunk
  with shifted offsets. Re-encode the OffsetIndex with shifted `PageLocation#offset`. Copy the
  ColumnIndex and bloom filter bytes with their offsets rebased. Mind files where
  `dictionary_page_offset` is before `data_page_offset` and files whose `file_offset` is wrong
  (some writers set it to the data page offset): compute the chunk start as the minimum of the
  dictionary and data page offsets.
- Schema of the output: the input schema minus dropped fields. Column order unchanged.
- Validate the Redaction against the schema once per `apply`/`affects?` (columns exist, replaced
  columns are not inside lists/maps unless the whole field is replaced, nil not set on required
  columns).
- `rows_changed` counts rows where at least one replace produced a value different from the
  original (compare with `!=` after the block); `rows_read` counts rows actually decoded.
- Tests (`test/`): round-trip through pyarrow-written fixtures and herringbone-written files;
  delete all / some / none of a row group; replace a leaf, a struct member, a whole list; drop;
  copied row groups are byte-identical pages (compare page bodies via the Inspector); statistics,
  page index and bloom filters of rewritten chunks no longer contain the removed value (check
  min/max and `bloom_may_match?`); `affects?` reads only the where columns (count chunk reads);
  errors raised before writing (output IO stays empty); multiple statements in order; writer
  options; LZO fallback; metadata copy; Ractor-safety not required.
- README: a "Redaction" section after "Writing" with the examples above, the rules, the
  guarantee and the caveats, and two or three recipes (HMAC pseudonymization, masking, Faker).
- CHANGELOG under `## Unreleased`.
- Later, not now: `dry_run:`, a `herringbone redact` CLI command, built-in pseudonymizers.

## Research summary

- Delta Lake and Iceberg mark deletes in metadata (deletion vectors, positional deletes) for
  speed, and both document that GDPR needs data files physically rewritten
  (`REORG ... APPLY (PURGE)`, copy-on-write compaction). Rewriting is the right primitive; this
  feature is that primitive for one file.
- parquet-java's rewriter and its proposed `mask` command: null, hash, redact; unchanged columns
  moved as a whole. `replace` with a Hash or block plus `drop` cover the same ground.
- Uber's selective column reduction copies retained column chunks as raw bytes and fixes offsets;
  27x faster than a Spark rewrite at 1GB. Factual's parquet-rewriter passes clean row groups
  through raw and only re-serializes dirty ones.
- Crypto-shredding (encrypt per subject, delete the key) needs Parquet modular encryption, which
  Herringbone does not support, and regulators treat ciphertext as personal data. Out of scope.
- Google DLP's transform catalogue (redact, replace, mask, HMAC, deterministic encryption, FPE,
  date shift, bucketing) is all expressible as one-line blocks; recipes go in the README.

Sources: https://www.dremio.com/blog/apache-iceberg-and-the-right-to-be-forgotten/ ,
https://datalakehousehub.com/blog/gdpr-hard-deletes-on-iceberg/ ,
https://docs.delta.io/delta-deletion-vectors/ ,
https://docs.databricks.com/aws/en/tables/features/deletion-vectors ,
https://github.com/apache/parquet-java/issues/2455 ,
https://www.uber.com/en-IN/blog/selective-column-reduction-for-datalake-storage-cost-efficiency ,
https://github.com/Factual/parquet-rewriter ,
https://docs.cloud.google.com/sensitive-data-protection/docs/pseudonymization ,
https://en.wikipedia.org/wiki/Crypto-shredding ,
https://parquet.apache.org/docs/file-format/data-pages/encryption/
