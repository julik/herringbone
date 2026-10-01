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

`Herringbone.write(io, relation)` combines `from_active_record` and `find_each`.

## 2. Reading ergonomics — done

Streaming reads: pages are read lazily (seek + read per page) and decoded one at a time per
column; rows are assembled in batches (`each_batch(size)`, `each_row` on top of it), with values
converted to Ruby objects per batch. 1M rows in one row group: 662 → ~160 MB peak RSS growth,
107k → 158k rows/s (`benchmark/streaming_read.rb`). `keys: :symbol` and `time_zone:` options.

Pages are decoded incrementally (levels run by run, values by per-encoding decoders), so only
the batch being assembled becomes Ruby objects: 1M rows in 1M-row pages 599 → 210 MB.
Column-order batches (`each_batch(as: :columns)`, `read(as: :columns)`) are 25–30% faster than rows.
`where:` / `from:` / `limit:` select rows using statistics, bloom filters and the page index
(see section 4); `scan_plan` shows what would be read.

`read(as: :numo)` / `each_batch(as: :numo)`: Numo arrays per column (optional numo-narray-alt,
required lazily). Flat INT32/INT64/FLOAT/DOUBLE/BOOLEAN columns skip Ruby objects: PLAIN and
BYTE_STREAM_SPLIT bytes go through `from_binary`, dictionary pages through `dict[indices]`, levels
and indices are unpacked by Numo (`HybridDecoder#read_numo`/`#read_flags`). 1M rows × id + amount:
26 ms vs 52 ms for `as: :columns` (`benchmark/numo_read.rb`). Nulls follow Polars/Rover (ints →
DFloat NaN, bools → RObject), fixed-length numeric lists become 2-D. Possible follow-ups:
`timestamps: :integer` / `dates: :integer` options, dictionary-encoded strings as Int32 codes plus
categories, a fast path for list leaves (2-D without assembling Ruby Arrays).

## 3. Inspecting files without reading the data — done

`Herringbone::Inspector` (footer, page headers, page indexes and bloom filter headers only; never
decompresses): summary, schema tree, key/value metadata, row groups, column chunks with decoded
statistics and caveats, every page header, ColumnIndex/OffsetIndex, per-column totals, a byte
`layout` of the whole file, `to_h` (JSON) and a text `report`. `Herringbone::Visualizer` renders it
as a self-contained HTML page (design and idea from
[Parquet X-ray](https://huggingface.co/spaces/cfahlgren1/parquet-xray) by cfahlgren1):
`bin/herringbone inspect FILE`, `--json`, `--html`.

Follow-ups — done:
- `Inspector#to_html` (the Visualizer is internal)
- Opt-in page CRC verification: `Inspector#verify_checksums`, after which `summary`, `to_h`,
  `report` and `to_html` include the results; CLI `--verify-checksums`
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
`page_rows:` (20k rows per page), sort orders for unsigned/decimal/float16, 64-byte
truncation of byte-array bounds. Verified against DataFusion's page pruning in CI.
Reading uses them: `where:` rules out pages with the ColumnIndex and columns jump to the needed
pages with the OffsetIndex (also for `from:`), reading exactly the page bytes.
Possible follow-ups: `where:` on list/map elements; OR conditions.

### Bloom filters — done (reading and writing)

`Herringbone::BloomFilter` (split block, 8 spec salts) with XXH64 (`Herringbone::XXHash`): the
optional `xxhash` gem when it can be required (Gemfile group `:speedups`; ~7M/s for 8-byte values,
~12M/s for 20-byte strings), else pure Ruby on 32-bit halves with constants split into 16-bit
pieces so nothing leaves the Fixnum range, generated from small code templates (~1.3M/s, ~0.6M/s).
Masked Bignum arithmetic looked fast in microbenchmarks but allocates ~25 Bignums per hash, and
with a writer's large live heap the resulting GCs made it up to 10x slower. Shifts are written as
`*`/`/` (YARV has no specialized instruction for Integer `<<`/`>>`). `XXHash.backend = :ruby`
forces pure Ruby (tests and benchmarks). The writer hashes each distinct value once (floats by
their bytes) and inserts in bulk (`insert_hashes`); `benchmark/bloom_filters.rb` measures it.
Writer option `bloom_filters:` (`true`, paths, or `{ path => { ndv:, fpp:, max_bytes: } }`;
sized from counted distinct values when ndv is not given), written after each row group's chunks
with `bloom_filter_offset`/`bloom_filter_length`. Reads with `where:` consult them
(`Reader#bloom_filter(rg, path)`; values go through the column encoder). Verified against
the parquet-testing fixtures (parquet-mr without length, parquet-rs with length), a pyarrow-written
fixture covering every physical type, pyarrow reading our files, and DataFusion pruning row groups.
Possible follow-up: let the Inspector reuse `Format::BloomFilterHeader`.

## Speed

- Optional native Snappy (`snappy` gem, optional Bundler group): 27x faster compression, 12x
  faster decompression; see llm/outputs/native-snappy.md
