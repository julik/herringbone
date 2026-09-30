# Herringbone × Andrew Kane's gems: where integration pays off

Research date: 2026-09-30. Gem versions and release dates come from the rubygems.org API
(`/api/v1/owners/ankane/gems.json`, 153 gems). Behaviour was checked against each gem's README and,
for the important ones, its source (shallow clones of polars-ruby, rover, nanoarrow-ruby,
iceberg-ruby, delta-ruby, ducklake-ruby, seaduck, blazer). All numbers were measured on Ruby 3.4.8,
arm64-darwin (Apple Silicon), with polars-df 0.27.1, rover-df 1.1.0, numo-narray-alt 0.11.2,
nanoarrow 0.1.4 and zstd-ruby. The benchmark scripts are in the session scratchpad (`bench1.rb`,
`bench2.rb`, `proto_numo.rb`, `fiddle_arrow.rb`).

## Summary

- Andrew Kane's data and ML gems share two formats: **Numo arrays** (numo-narray-alt since
  2026) and, newer, the **Arrow C stream capsule protocol** (`#arrow_c_stream`). Rover, xgb,
  lightgbm, eps, disco, faiss, ngt, torch-rb, onnxruntime, isotree and prophet take Numo or Rover.
  polars-df, nanoarrow, deltalake-rb and iceberg take `arrow_c_stream`. Herringbone speaks neither
  today. Its column batches are Arrays of Ruby objects.
- **The best single feature is `as: :numo`.** Flat fixed-width columns would be decoded straight
  from page bytes into Numo arrays with `Numo::Int64.from_binary` and friends, with no Ruby object
  per value. It is measured and it works:
  - `from_binary` on 1M int64 takes 1.2 ms, against 19 ms for `unpack("q<*")` and 33 ms for
    `Numo::Int64.cast(array)`.
  - A prototype read of 2 columns × 1M rows into Numo took 12–27 ms, against 48–67 ms for today's
    `read(as: :columns)`.
  - Wrapping the result in a Rover::DataFrame is free (0.0 ms). Building the same frame from Ruby
    Arrays costs 164–294 ms.
  - Overall, Parquet → Rover gets about 13× faster (26 ms against 355 ms).
- **Rover is the natural partner.** It is pure Numo, and today it reads and writes Parquet only
  through `red-parquet`, the Apache Arrow GLib/C++ stack. Herringbone plus `as: :numo` would give
  Rover a Parquet path with no native Arrow.
- **Polars needs Herringbone least.** It reads Parquet natively, about 50–100× faster than
  Herringbone: 5 ms for a 1M-row, 4-column file, against 356 ms. Herringbone helps only where Polars
  falls short:
  - It streams from arbitrary Ruby IOs. Polars slurps a Ruby IO fully into memory.
  - It exports ActiveRecord with bounded memory through `find_each`, with enum labels and Ruby
    coercions. `Polars.read_database` runs `select_all` over the whole result.
  - It runs on engines without native gems, such as JRuby and TruffleRuby.
  - It has the Inspector.

  The clean bridge is `arrow_c_stream`. **I showed that a pure-Ruby, Fiddle-built Arrow C stream is
  accepted by `Polars::Series.new`: 1M int64 in 1.2 ms.** It has a real threading hazard (below),
  though, so the production route should go through nanoarrow.
- **Vectors and embeddings (neighbor, pgvector, informers, faiss, ngt).**
  `Schema.from_active_record` maps pgvector `vector(n)` columns to `string` today. Mapping them to
  `list<float>`, and reading fixed-length float lists as 2-D Numo `[n, dim]`, is a small change
  with high value for the AI/embeddings crowd.
- **Not ankane, but the biggest speed lever overall: native Snappy.** Snappy is Parquet's default
  codec, and Herringbone's is pure Ruby:
  - Reading a Snappy-compressed 2-column × 1M file takes about 780 ms of pure-Ruby
    decompression. The Numo prototype took 784 ms on that file against 12 ms uncompressed.
  - Writing 1M rows × 2 doubles takes 5.0 s with Snappy against 1.3 s uncompressed.

  An optional `snappy` gem (0.5.1, released 2026-03-18), lazily required like `zstd-ruby`, would
  help every integration below. Polars itself writes ZSTD by default, so reading Polars files needs
  `zstd-ruby`. The first read of a Polars file raised `MissingCodecError` until I installed it.

## Ranked top 5 (value ÷ effort)

| # | Integration | Enables | Form | Effort | Value |
|---|---|---|---|---|---|
| 1 | **`read`/`each_batch(as: :numo)`**: fast column decode into Numo, nulls following the Polars/Rover convention | Rover, xgb, lightgbm, eps, isotree, torch-rb, onnxruntime, faiss, ngt, disco, prophet | (a) soft integration: lazy `require "numo/narray"` | M (≈1–2 weeks with tests) | **High** |
| 2 | **Rover round-trip**: `Rover::DataFrame.new(reader.read(as: :numo))`; `Herringbone.write(io, rover_df)`; offer Rover an optional Herringbone fallback when red-parquet is missing | Rover, prophet-rb, eps, disco | (c) README recipe, plus a small duck-typed writer input and an upstream PR proposal | S once #1 is done | **High** |
| 3 | **Vector columns**: `from_active_record` maps `vector`/`halfvec`/`sparsevec`; fixed-length float lists read as 2-D Numo `[n, dim]` | neighbor, pgvector, informers, transformers-rb, faiss, ngt, torch-rb | (a) inside herringbone | S (AR mapping) + S/M (2-D read) | Medium-high |
| 4 | **Columnar writer input**: `Herringbone.write(io, {"id" => numo_or_array, ...})` with a PLAIN fast path via `Numo#to_binary` | Rover/Polars output, ML predictions, embeddings | (a) inside herringbone | M | Medium |
| 5 | **Arrow C stream export**: `batch.arrow_c_stream` / `reader.arrow_c_stream`, built through nanoarrow | polars-df, deltalake-rb, iceberg, nanoarrow | (a) soft dependency on `nanoarrow`, or (b) a `herringbone-arrow` adapter gem | M | Medium: most Polars users won't need it |

Honourable mention: a **Blazer "Download Parquet"** action, typed where CSV loses types, with
Parquet uploads to match. Effort is S and it would suit data teams. It needs Andrew to accept a
soft dependency, so it is an upstream proposal, not something herringbone can ship. See the Blazer
section.

### Shared enabling features

1. **A fast flat-column decoder** in Reader. It covers leaf columns with `max_repetition_level == 0`
   whose values are PLAIN INT32/INT64/FLOAT/DOUBLE/BOOLEAN, or are dictionary-encoded. It works like
   this:
   - **Values:** each page is kept as a packed little-endian `String` slice, and a column's slices
     are joined once. `Numo::X.from_binary` does the rest.
   - **Definition levels (`max_def == 1`, the usual nullable case):** the RLE/bit-packed hybrid is
     decoded without per-value objects. RLE runs become `fill`. Bit-packed runs of width 1 already
     use Numo::Bit's layout (LSB-first), so `Numo::Bit.from_binary(bytes, [n])` reads them
     directly (verified). Per page, this gives a validity bitmap.
   - **Dictionary pages:** the dictionary is decoded once into a Numo array. The indices (hybrid,
     bit width ≤ 32) are decoded into `Numo::Int32`, then `dict[indices]` resolves them. That took
     1.5 ms for 1M values.
   - **Nulls:** values are scattered into a full-length array with
     `full[validity.where] = dense`, which took 15 ms per 1M.

   The format-agnostic core is a `(values String, validity bitmap String or nil, length, physical
   and logical type)` tuple. Numo, nanoarrow and Fiddle-Arrow output are thin layers on top.
2. **`#to_binary`/`#to_string` on the write side.** A fixed-width, non-null Numo column is already
   a PLAIN page body. Statistics come from `Numo#min`/`#max`, and page-index entries from slices.
   Note that `Numo#to_binary` returns a **US-ASCII**-encoded String. Call `.b` before concatenating
   it with binary buffers; comparing it unconverted against a binary String returned `false` in the
   test.
3. **Null convention**, matching what the ecosystem already does (verified with `Polars::Series#to_numo`
   and `Rover::Vector`):
   - Float columns use NaN for null.
   - Integer columns with nulls become `Numo::DFloat` with NaN. This is lossy above 2^53.
   - Boolean columns with nulls become `Numo::RObject` (true/false/nil). Without nulls they are
     `Numo::Bit`.
   - Strings, decimals, dates and timestamps become `Numo::RObject`. Offer
     `timestamps: :integer` (Int64 in the column's unit) and `dates: :integer` (Int32 days) for ML
     callers who want raw numbers.

   XGBoost's `DMatrix` defaults to `missing: Float::NAN`, so NaN-for-null is exactly what it
   expects.

## The "speedy per-column reading into Numo" idea, evaluated

### Type mapping

| Parquet physical/logical | Numo type | Zero-per-value path? |
|---|---|---|
| BOOLEAN (PLAIN, LSB-first bit-packed) | `Numo::Bit` | Yes. `Numo::Bit.from_binary(bytes, [n])` matches bit for bit (verified). RLE booleans (data page v2) need hybrid decode first. |
| INT32 | `Numo::Int32` | Yes |
| INT32 + INT(8/16, signed) | `Numo::Int8` / `Int16` | `from_binary` as Int32, then `cast_to` (fast, in C) |
| INT32 + INT(8/16/32, unsigned) | `UInt8` / `UInt16` / `UInt32` | UInt32 reinterprets directly; the narrower types via `cast_to` |
| INT64 | `Numo::Int64` | Yes |
| INT64 + UINT_64 | `Numo::UInt64` | Yes (reinterpret) |
| FLOAT / DOUBLE | `SFloat` / `DFloat` | Yes |
| FLOAT16 (FLBA 2) | `SFloat` | No: Numo has no half type, so it needs a per-value conversion |
| DATE | `Int32` days, or `RObject` of `Date` | Int32 yes; Date no |
| TIMESTAMP(unit) | `Int64` in the unit, or `RObject` of `Time` | Int64 yes; Time no |
| INT96 | `Int64` nanoseconds | No (12-byte values; the arithmetic could be vectorised with Numo) |
| DECIMAL on INT32/INT64 | `Int32`/`Int64` unscaled (plus the scale), or `DFloat` (lossy) | Yes, for the unscaled form |
| DECIMAL on FLBA/BYTE_ARRAY, STRING, BYTE_ARRAY, UUID, JSON | `RObject` | No gain over Arrays (dictionary-encoded strings can come out as `Int32` codes plus a dictionary for categoricals) |
| `list<float/double>` where every row has the same length (embeddings) | 2-D `SFloat`/`DFloat` `[n, dim]` | Yes: read the leaf PLAIN, check that the repetition levels describe fixed-length lists, then `reshape(n, dim)` |
| Other nested types | `RObject` | No |

Endianness: Parquet is little-endian and so are x86 and ARM hosts. `Numo::NArray` has
`swap_byte`/`to_swapped`/`hton`, so a big-endian host (such as s390x) can fix up after
`from_binary`. Ankane's own `npy` gem does exactly this `from_binary`/`to_binary` dance, only for
`<`-endian dtypes.

Numo flavour: ankane's gems moved to **numo-narray-alt** in 2026: rover-df ≥ 1.0, prophet-rb,
disco, faiss and npy depend on it. Plain `numo-narray` was last released on 2022-08-20
(0.9.2.1). Both provide `require "numo/narray"` and the `Numo::` constants, so a lazy require works
with either. Never add either one as a hard dependency; numo-narray-alt warns when both are
installed.

### Measured (1M elements unless stated)

| Operation | Time |
|---|---|
| `String#unpack("q<*")` → Array (what Herringbone does now) | 19.3 ms |
| `unpack("E*")` → Array | 8.7 ms |
| `Numo::Int64.from_binary` | **1.2 ms** |
| `Numo::DFloat.from_binary` | 1.0 ms |
| `Numo::Int32.from_binary` | 0.4 ms |
| `Numo::Bit.from_binary` (bit-packed booleans) | 0.1 ms |
| `Numo::Int64.cast(ruby_array)` | 32.9 ms |
| `Numo::Int64#to_binary` | 0.7 ms |
| `Numo::Int64#to_a` | 4.7 ms |
| Dictionary resolve `dict[int32_indices]` (DFloat) | 1.5 ms |
| Scatter 900k non-null values into a NaN-filled 1M DFloat | 15.3 ms |

Prototype: `proto_numo.rb` pulls PLAIN page slices out of `ColumnChunkReader#next_stream` and
calls `from_binary`. Each file has 2 columns (int64 id, double amount) × 1M rows. The last two
columns build a data frame from the Numo prototype's output.

| File | Today's `read(as: :columns)` | Numo prototype | + `Rover::DataFrame.new` | + `Polars::DataFrame.new` |
|---|---|---|---|---|
| Polars-written, ZSTD | 61 ms | **26 ms** | 0.0 ms | 19 ms |
| Polars-written, uncompressed | 48 ms | **12 ms** | 0.0 ms | – |
| Herringbone-written, ZSTD | 67 ms | **27 ms** | 0.0 ms | – |
| Herringbone-written, uncompressed | 51 ms | **14 ms** | 0.0 ms | – |
| Polars-written, **Snappy** | 822 ms | 784 ms | – | – |
| Herringbone-written, **Snappy** (default) | 828 ms | 789 ms | – | – |

In the prototype, definition levels were still decoded into a Ruby Array. The table's files had no
nulls, so those were cheap single RLE runs. Pure-Ruby Snappy dominates whenever it is involved.

For comparison, from the same data:

| Path | Time |
|---|---|
| `Polars.read_parquet(path)` | 5.5 ms |
| `Polars.read_parquet(StringIO)` (slurps the IO) | 4.2 ms |
| Herringbone `read(as: :columns)`, all 4 columns | 356 ms |
| `Rover::DataFrame.new` from 4 Ruby Arrays | 294 ms |
| `Rover::DataFrame.new` from 2 Ruby Arrays | 164 ms |
| `Rover::DataFrame.new` from 2 Numo arrays | 0.1 ms |
| Rover via Polars (`Rover::DataFrame.new(polars_df.to_h)`) | 535 ms |
| `Polars::DataFrame.new` from a Hash of 4 Ruby Arrays | 76 ms |
| `Polars::Series.new(numo)` (Polars calls `values.to_a` internally, so it is not zero-copy) | 9–11 ms |
| Polars `df.to_h` (4 columns) | 79 ms |
| Polars `df["id"].to_a` | 3 ms |
| Polars `df["id"].to_numo` | 34 ms |
| Polars `df.rows` | 301 ms |
| Herringbone `read(where: {id: 500_000..500_099})` | 66 ms |
| Polars `scan_parquet.filter(...)` | 7 ms |
| `Herringbone.write`, 1M rows × 4 columns from Hashes (Snappy) | 7.1 s |
| `Herringbone.write`, 1M rows × 2 numeric columns, `:none`, no dictionary | 1.35 s |
| `Herringbone.write`, same with Snappy and dictionary | 5.0 s |
| Polars `write_parquet` | 13 ms |

## Per-gem assessment

Downloads are rubygems totals. "Form" uses the task's labels: (a) soft integration inside
herringbone, (b) a separate adapter gem, (c) a README recipe.

### Strong fits

#### rover-df: `Rover::DataFrame` (1.1.0, 2026-08-15; 4.0M downloads)

- **What it is:** Simple data frames on numo-narray-alt. Each column is a `Rover::Vector` wrapping
  a Numo array. Integer and boolean columns cannot hold nulls: `Rover.read_parquet` raises "Nulls
  not supported". Floats use NaN.
- **Parquet today:** `Rover.read_parquet`, `parse_parquet` and `DataFrame#to_parquet` need
  **red-parquet** (Apache Arrow GLib and C++; 25.0.1). `to_parquet` builds row arrays in Ruby
  (the source has a `# TODO improve performance`).
- **Why it matters:** Rover is the data frame of prophet-rb (a hard dependency) and an accepted
  input to eps, disco, xgb, lightgbm, isotree and vega. Installing red-parquet is heavy (libarrow
  and GObject Introspection), so Herringbone would be a pure-Ruby Parquet path for all of them.
- **Integration:**

  ```ruby
  df = File.open("sales.parquet", "rb") { |f| Rover::DataFrame.new(Herringbone::Reader.new(f).read(as: :numo)) }
  df = Rover::DataFrame.new(reader.read(as: :numo, columns: %w[ds y], where: { store_id: 7 }))

  File.open("out.parquet", "wb") { |f| Herringbone.write(f, df) }  # writer sees #vectors / #to_numo per column
  ```

- **Form:** (c) a recipe for reading once `as: :numo` exists. Writing needs a tiny duck type in
  `Herringbone.write`: an object responding to `vectors` whose values respond to `to_numo`, or
  simply a Hash of Numo columns (top-5 #4). An upstream PR to Rover could make
  `Rover.read_parquet(io_or_path)` try Herringbone when red-parquet isn't installed. Andrew keeps
  such dependencies soft (for example `require "parquet"` is lazy), so that fits his style.
- **Effort:** S after #1. **Value:** high. It is 13× faster than going through Ruby Arrays and
  removes the native Arrow requirement.

#### polars-df: Polars (0.27.1, 2026-08-12; 0.9M downloads)

- **What it is:** Rust Polars through magnus. Precompiled for x86_64/aarch64 Linux (glibc and
  musl), x86_64/arm64 macOS and mingw. It reads and writes Parquet natively (`read_parquet`,
  `scan_parquet` with predicate pushdown, `sink_parquet`) and is about 50–100× faster than
  Herringbone at it.
- **Input formats:**
  - Hash of Ruby Arrays: 40 ms for 1M int64, 4 ms for 1M float64, 36 ms for 1M strings.
  - Numo: goes through `to_a`, so there is no zero-copy gain.
  - **Any object with `#arrow_c_stream`** whose return value responds to `#to_i` with an
    `ArrowArrayStream*`. `DataFrame.new`, `Series.new` and `Schema.new` accept it, and `to_arrow`
    returns a `Nanoarrow::Array`.
- **Where Herringbone still adds value:**
  1. Arbitrary Ruby IOs. Polars calls `io.read` and buffers the whole thing, so it cannot range-read
     a 20 GB object on S3 through an IO shim. Herringbone seeks and reads only the footer, the page
     indexes and the pages it needs.
  2. ActiveRecord export. `Polars.read_database(relation)` runs `select_all(relation.to_sql)` into
     memory with raw DB values. Herringbone streams through `find_each` with enum labels,
     `json`/`decimal` coercions and a schema from the model.
  3. Platforms without Rust binaries: JRuby, TruffleRuby, odd architectures.
  4. The Inspector and CRC verification.
  5. A writer with Ruby-value coercions (TimeWithZone, `BigDecimal`, Rails enums).
- **Integration:** `batch.arrow_c_stream` / `reader.arrow_c_stream`, so that
  `Polars::DataFrame.new(reader)` or `Polars::DataFrame.new(batch)` works (top-5 #5). A recipe
  works today: `Polars::DataFrame.new(reader.read(as: :columns))`, which took 77 ms for 2 columns ×
  1M. For writing, `Herringbone.write(io, polars_df)` isn't worth it, because Polars writes Parquet
  itself.
- **Form:** (c) a recipe now, (a)/(b) through Arrow later. **Value:** low-to-medium. Say so plainly
  in the README: if you have Polars, read Parquet with Polars.

#### nanoarrow: Nanoarrow (0.1.4, 2026-09-21; new since 2026-07-18)

- **What it is:** Zero-dependency Arrow for Ruby, wrapping the C nanoarrow library. It follows the
  Python nanoarrow API. `Nanoarrow::Array.new(ruby_array, Nanoarrow.int64)` builds in C: 9.3 ms
  for 1M ints and 15 ms for 1M strings. It exposes `arrow_c_stream`, `arrow_c_array` and
  `arrow_c_schema` capsules.
- **Limitation:** there is no `from_buffers` / `c_array_from_buffers` constructor (Python nanoarrow
  has one), so it cannot wrap packed Strings without going through Ruby values.
- **Why it matters:** it is the glue Andrew uses between polars, iceberg and deltalake. Herringbone
  could export batches as Nanoarrow arrays, with `require "nanoarrow"` lazy. Polars then imports a
  Nanoarrow int64 array in **0.4 ms**, and a string array in 4.7 ms.
- **Upstream suggestion:** a PR to nanoarrow-ruby adding a buffers-based constructor
  (`Nanoarrow::Array.from_buffers(type, length, validity: str, data: str, offsets: str)`). That
  would make Herringbone → Arrow zero-per-value for fixed-width and offset-based columns. Parquet's
  DELTA_LENGTH_BYTE_ARRAY is already "lengths + concatenated bytes", so it is nearly Arrow's
  offsets + data.
- **Form:** (a) a soft dependency. **Effort:** M. **Value:** medium. It is the path to #5 below.

#### Arrow consumers: deltalake-rb (0.3.2, 2026-06-08), iceberg (0.12.0, 2026-07-22), ducklake (0.1.5, 2026-05-23), seaduck (0.1.1, 2026-03-10)

- **deltalake-rb:** `DeltaLake.write(uri, data)` accepts only objects implementing
  `arrow_c_stream`; the error message says so.
- **iceberg:** `table.append` takes a Polars DataFrame, a Nanoarrow array, or an Array of Hashes.
  `catalog.create_table(schema: x)` accepts any `arrow_c_schema`.
- **ducklake and seaduck:** these run DuckDB, which reads Parquet itself.
  `ducklake.add_data_files("events", "data.parquet")` registers an **existing Parquet file** in
  the lake without rewriting it.
- **Integration:**
  - Recipe for ducklake: write the file with Herringbone from ActiveRecord (typed, streaming,
    bounded memory), upload it, then `add_data_files`. This works today, provided the schema
    matches the table.
  - For Delta and Iceberg: once #5 exists, `DeltaLake.write("s3://…", reader)` or
    `table.append(batch)` streams Parquet/ActiveRecord data into a lakehouse without Polars.
    Iceberg's Array-of-Hashes path already works with `reader.each_batch` today.
- **Form:** (c) recipes, plus #5. **Value:** medium for the lakehouse crowd, but those users often
  have Polars anyway.

#### neighbor (1.2.0, 2026-06-05; 22.6M downloads) and pgvector (0.3.3, 2026-03-19; 3.4M)

- **What they are:** Vector search for Rails. `has_neighbors`, with vectors as Arrays of Floats,
  stored in Postgres `vector(n)`/`halfvec`/`sparsevec`/`bit` columns, in SQLite, or in MySQL.
- **Gap found:** `Schema.from_active_record` falls through to `string` for `vector` columns, which
  exports `"[0.1, 0.2, …]"` text. Parquet's convention for embeddings is `list<float>`: Hugging
  Face datasets, LanceDB exports, pyarrow `fixed_size_list` round-trip as a LIST.
- **Integration:**
  - Map `sql_type =~ /\A(vector|halfvec)/` to `list :x, :float, element_null: false`. A `float16`
    element is an option for `halfvec`, but Herringbone's float16 path is per-value.
  - Map `sparsevec` to `map<int32, float>`, or to `struct { indices list<int32>, values list<float> }`.
  - Map `bit(n)` to `binary`.
  - On read, `reader.read(as: :numo)` returns a 2-D `Numo::SFloat [n, dim]` for fixed-length float
    lists. That feeds straight into faiss (`index.add(numo)`), ngt, `Torch.from_numo`, or
    `Pgvector` bulk loading through `COPY` (pgvector-ruby has an example).

  ```ruby
  File.open("embeddings.parquet", "wb") { |f| Herringbone.write(f, Document.select(:id, :embedding)) }
  vectors = File.open("embeddings.parquet", "rb") { |f| Herringbone::Reader.new(f).read(as: :numo, columns: ["embedding"])["embedding"] }
  index = Faiss::IndexFlatL2.new(vectors.shape[1]); index.add(vectors)
  ```

- **Form:** (a) inside herringbone, mapping by `sql_type` so neighbor isn't needed. **Effort:** S
  for the AR mapping, S/M for the 2-D read. **Value:** medium-high. Exporting and importing
  embeddings is a very common Rails + AI chore.

#### informers (1.3.0, 2026-04-15; 2.6M) and transformers-rb (0.2.0, 2026-04-04)

- **What they are:** ONNX transformer inference that produces embeddings as Arrays of Floats.
- **Why it matters:** Hugging Face datasets are distributed as Parquet, so there is text in and
  embeddings out.
- **Integration:**
  - Batch-embed with `reader.each_batch(256, columns: ["text"]) { |rows| model.(rows.map { _1["text"] }) }`.
  - Write the results with the `list :embedding, :float` schema from the vectors item.
- **Form:** (c) a recipe; it depends on the vector support. **Value:** medium.

#### xgb (0.12.1, 2026-08-05), lightgbm (0.5.0, 2026-07-18), eps (0.7.0, 2026-04-15), isotree (0.5.0, 2026-04-08)

- **Input formats:** Array of Arrays, Numo 2-D, or a Rover DataFrame (eps and isotree also take
  Arrays of Hashes). xgb's DMatrix casts to `SFloat` and copies `to_string` into FFI memory, so no
  Ruby Floats are involved. `missing: Float::NAN` is its default.
- **Integration:**

  ```ruby
  cols = reader.read(as: :numo, columns: features + ["label"])
  x = Numo::NArray.column_stack(features.map { cols[_1] })
  XGBoost.train(params, XGBoost::DMatrix.new(x, label: cols["label"]))
  ```

  Alternatively, pass a Rover frame.
- **Form:** (c) a recipe, powered by #1. **Value:** medium-high. Training sets are exactly the
  "big Parquet of features" case, and there are no per-value objects end to end.

#### torch-rb (0.26.0, 2026-09-06), torchvision/torchaudio/torchtext/torchdata (0.1.0, 2026-04-08), onnxruntime (0.11.7, 2026-09-10)

- **torch-rb:** `Torch.from_numo(numo)` and `tensor.numo`. Using `as: :numo` with
  `Torch.from_numo` is a recipe.
- **torchdata-ruby:** very small (FileLister and `parse_csv` datapipes). A "parse_parquet" datapipe
  would be a natural upstream PR, but the gem is young and little used.
- **onnxruntime:** takes Numo or Arrays as input, so it is a recipe.
- **Form:** (c). **Value:** low-to-medium; niche.

#### faiss (0.6.4, 2026-09-17) and ngt (0.6.0, 2026-02-27)

- **Input formats:** Array of Arrays or 2-D Numo. faiss depends on numo-narray-alt.
- **Integration:** use the 2-D vector read from the vectors item: Parquet embeddings → Numo →
  index. This is a recipe. **Value:** medium, together with the vectors item.

#### blazer (3.5.2, 2026-09-25; 9.8M downloads)

- **What it is:** SQL exploration, dashboards and checks, with 20+ data source adapters. There is
  no DuckDB adapter. Adapters implement `run_statement` → `[columns, rows, error]`.
- **Why Parquet matters:**
  - Query results download as **CSV only** (`format.csv` in QueriesController), which loses types.
  - "Uploads" import **CSV only** into Postgres through `COPY`.
- **Integration ideas:**
  1. Offer `format.parquet` next to `format.csv`, as an upstream PR with a soft dependency (the
     block runs only if `defined?(Herringbone)`), or as a recipe that overrides the controller:
     `Herringbone.write(io, rows.map { columns.zip(_1).to_h })`. `Schema.infer` gives typed
     columns. Timestamps stay timestamps and decimals stay decimals, which spreadsheets and DuckDB
     users appreciate.
  2. Parquet uploads: read with Herringbone, create the table from the schema (known types instead
     of CSV guessing), then `COPY`.
  3. A "parquet" adapter isn't sensible, because Herringbone has no SQL engine.
- **Form:** upstream proposal, or (c) a recipe. **Effort:** S. **Value:** medium. Big install
  base; it's Andrew's call.

#### prophet-rb (0.7.0, 2026-04-08), disco (1.0.0, 2026-04-17), anomaly_detection (0.4.0, 2026-04-07), trend

- **prophet-rb** takes a Rover `ds`/`y` frame or a Hash of date => value. **disco** takes an Array
  of Hashes (`user_id`, `item_id`, `rating`) or Rover.
- Herringbone rows already fit as Arrays of Hashes: `reader.read(columns: %w[user_id item_id rating])`.
  With Symbol keys (`keys: :symbol`) they match disco's documented examples.
- **Form:** (c) a recipe; Rover-backed after #2. **Value:** low-medium.

#### ahoy_matey (5.5.0, 2026-04-08; 14.1M), plus notable, searchjoy, field_test, mailkick, authtrail

- **What they are:** first-party event and analytics tables that grow without bound. Ahoy's
  README has a "Data Retention" section that `find_in_batches` + `delete_all`s old visits.
- **Integration:** a recipe to archive to Parquet before deleting:
  `Herringbone.write(io, Ahoy::Event.where(time: ...2.years.ago), compression: :zstd)`. Upload it,
  then delete. Sort by `time` so the page index makes later lookups cheap. This already works; it
  is only documentation.
- **Form:** (c). **Value:** medium for docs and discoverability, zero code.

#### pgslice (0.7.2, 2026-01-06), distribute_reads (1.1.0, 2026-04-02), pgsync (0.8.1, 2025-09-12)

- **pgslice:** detached old partitions are ideal archive candidates for Parquet. That is a recipe.
- **distribute_reads:** `distribute_reads { Herringbone.write(io, Order.all) }` runs big exports
  against replicas. That is a one-line recipe.
- **pgsync:** a Postgres → Postgres CLI. No fit.

#### lockbox (2.2.0, 2026-04-04; 48.6M), blind_index (2.8.1, 2026-06-29), kms_encrypted, hypershield

- **Behaviour today:** `from_active_record` builds the schema from `Model.columns`, so it exports
  `*_ciphertext` and never plaintext. That is the safe default, and the README could say so
  explicitly. Exporting decrypted fields needs an explicit schema plus the value.
- Herringbone does not support Parquet modular encryption (README).
- **Whole-file Lockbox encryption:** `Lockbox.new(key:).encrypt(parquet_bytes)` works, but it is
  not streaming and makes the file unreadable by other tools.
- **Form:** (c) a README sentence about ciphertext columns. **Value:** low, but worth one sentence
  for trust.

#### hexspace (0.3.0, 2025-04-03), drill-sergeant (0.4.0, 2026-04-08), ignite-client (0.3.0, 2025-04-03)

- **What they are:** SQL clients for Spark/Hive, Drill and Ignite that return Arrays of Hashes.
  `Herringbone.write(io, client.execute(sql))` works today, with the schema inferred.
- **Improvement:** a small `schema:` builder from these clients' result column types. Low value.
- **Form:** (c).

### Weak or no fit (and why)

- **groupdate, hightop, active_median, rollups:** SQL-side aggregation helpers on
  ActiveRecord. Their results are small Hashes, and Parquet adds nothing. At most, rollups'
  pre-aggregated table can be exported like any model.
- **chartkick (5.2.1), vega (0.6.0), mapkick-rb:** they take Hashes, Arrays or Rover (vega also
  takes Polars through `rows(named: true)`). Herringbone rows already work. There is nothing to
  build.
- **searchkick (6.1.2):** it indexes from models, not files. Bulk reindexing from Parquet is
  possible but no one asks for it.
- **pghero, pgdexter, strong_migrations, gindex, slowpoke, pretender and the other Rails
  operations gems:** no tabular data interchange.
- **npy (1.0.0), safetensors (0.3.0):** tensor file formats, not tabular. They are useful only as
  proof that Andrew's pattern is `from_binary`/`to_binary` on Numo, which is what #1 proposes.
- **datasketches (0.5.2):** Herringbone could use HLL for bloom-filter NDV estimation, but it
  already counts distinct values per row group. No need.
- **tomoto, fasttext, mitie, blingfire, tokenizers:** they consume text, so the recipe is just
  `each_batch` over a text column. Nothing to build.
- **trove (0.4.0):** it deploys ML model files to S3. Not tabular.
- **or-tools, highs, glpk, scs, osqp, cbc, clp, opt-rb:** optimisation solvers. No fit.
- **tensorflow (0.2.0, 2021-07-07):** unmaintained. Skip it.
- **Not ankane's, despite the task list:**
  - annoy-rb is by yoshoku.
  - The Trino client is by treasure-data.
  - There is no "dbx" gem under his account; the closest are distribute_reads and pgsync.
  - He has no standalone DuckDB gem. DuckDB appears only inside ducklake and seaduck, via
    libduckdb.
  - S3 helpers: none, apart from trove and neighbor-s3, which is for S3 Vectors, not data files.

## Arrow C stream from pure Ruby: the Fiddle experiment

The capsule protocol that Andrew's Rust gems use is simple. `obj.arrow_c_stream` returns something
whose `to_i` is an `ArrowArrayStream*`; Polars' `import_stream_rbcapsule` just calls `to_i`. I
built one with only Fiddle, which is stdlib:

- `ArrowSchema` (format `"l"`), `ArrowArray` (2 buffers: no validity, plus the data copied from a
  packed String) and `ArrowArrayStream` are laid out with `pack("Q…")`.
- `get_schema`, `get_next`, `get_last_error` and `release` are `Fiddle::Closure::BlockCaller`s.

The result: `Polars::Series.new(RbArrow.int64_stream("id", packed, 1_000_000))` built a correct
`Int64` Series (sum verified) in **1.2 ms**, including the 8 MB copy. The array's `release` was
invoked on the main Ruby thread when the Series was garbage-collected.

**Why not ship it:**

- **Threading.** Fiddle closures entered from a non-Ruby thread go through
  `rb_thread_call_with_gvl`, which is not valid for foreign threads. Polars drains a stream
  synchronously on the calling thread, but other consumers may not: deltalake/iceberg writers run on
  Rust async runtimes. And whichever Rust thread drops the last reference to an imported buffer
  calls `release`. Polars may do that from its thread pool after a rechunk or a lazy query.
- **Ownership.** Buffers must outlive the consumer, which needs a working `release` to free them.

Nanoarrow owns its buffers and has C release callbacks, so it is the safe carrier. The Fiddle trick
is fine as an experiment or for a "materialize then hand to Polars synchronously" helper, and it
shows that a buffers-based nanoarrow constructor would give Herringbone → Arrow at close to memcpy
speed.

## Suggested API shapes (herringbone style: IO-only, keyword options, one obvious way)

```ruby
# 1. Numo columns (lazy require "numo/narray"; works with numo-narray or numo-narray-alt)
reader.read(as: :numo)                                # { "id" => Numo::Int64, "price" => Numo::DFloat, "name" => Numo::RObject }
reader.each_batch(100_000, as: :numo, columns: %w[x y], where: { day: date }) { |cols| ... }
# nulls: floats NaN; ints with nulls -> DFloat NaN; bools with nulls -> RObject; strings/dates/times -> RObject
# fixed-length list<float> -> 2-D SFloat [n, dim]

# 2. Columnar writing (Arrays or Numo; fixed-width non-null Numo takes the to_binary fast path)
Herringbone.write(io, { "id" => ids, "embedding" => matrix })             # schema inferred from Numo classes / values
Herringbone.write(io, rover_df)                                           # duck-typed: #vectors -> #to_numo

# 3. Arrow (lazy require "nanoarrow")
Polars::DataFrame.new(reader)                    # Reader#arrow_c_stream: one record batch per each_batch(…) chunk
DeltaLake.write("s3://bucket/t", reader)         # streams (once nanoarrow owns the buffers)

# 4. ActiveRecord vector columns (no neighbor dependency; by sql_type)
Herringbone::Schema.from_active_record(Document) # embedding vector(768) -> list<float> (element_null: false)
```

## Sources (versions and release dates from rubygems.org, checked 2026-09-30)

- Owner list: https://rubygems.org/profiles/ankane (API: https://rubygems.org/api/v1/owners/ankane/gems.json)
- polars-df 0.27.1 (2026-08-12): https://github.com/ankane/ruby-polars. See `lib/polars/series.rb`
  (Numo → `to_a`; `arrow_c_stream`), `ext/polars/src/series/import.rs` (capsule `to_i`),
  `ext/polars/src/file.rs` (Ruby IO → `read` into a buffer), `test/arrow_test.rb`, and
  `lib/polars/io/database.rb`.
- rover-df 1.1.0 (2026-08-15): https://github.com/ankane/rover. See `lib/rover.rb`
  (`parquet_to_df` via red-parquet; nulls in int/bool unsupported) and `lib/rover/data_frame.rb`
  (`to_parquet`, `to_h`).
- nanoarrow 0.1.4 (2026-09-21; first release 2026-07-18): https://github.com/ankane/nanoarrow-ruby
- deltalake-rb 0.3.2 (2026-06-08): https://github.com/ankane/delta-ruby (`lib/deltalake/utils.rb`
  requires `arrow_c_stream`)
- iceberg 0.12.0 (2026-07-22): https://github.com/ankane/iceberg-ruby
- ducklake 0.1.5 (2026-05-23): https://github.com/ankane/ducklake-ruby (`add_data_files`).
  seaduck 0.1.1 (2026-03-10): https://github.com/ankane/seaduck
- numo-narray-alt 0.11.2 (2026-08-12): https://github.com/yoshoku/numo-narray-alt. numo-narray
  0.9.2.1 (2022-08-20).
- npy 1.0.0 (2026-04-04): https://github.com/ankane/npy (`from_binary`/`to_binary`).
  safetensors 0.3.0 (2026-06-09).
- xgb 0.12.1 (2026-08-05): https://github.com/ankane/xgboost-ruby (`lib/xgboost/dmatrix.rb`:
  Numo/Rover, `cast_to(SFloat).to_string`, `missing: NaN`). lightgbm 0.5.0 (2026-07-18). eps 0.7.0
  (2026-04-15). isotree 0.5.0 (2026-04-08).
- prophet-rb 0.7.0 (2026-04-08; depends on rover-df and numo-narray-alt). disco 1.0.0
  (2026-04-17). anomaly_detection 0.4.0 (2026-04-07).
- torch-rb 0.26.0 (2026-09-06; `Torch.from_numo`). torchdata 0.1.0 (2026-04-08). onnxruntime
  0.11.7 (2026-09-10).
- informers 1.3.0 (2026-04-15). transformers-rb 0.2.0 (2026-04-04). tokenizers 0.7.0 (2026-04-27).
- neighbor 1.2.0 (2026-06-05). pgvector 0.3.3 (2026-03-19):
  https://github.com/pgvector/pgvector-ruby. faiss 0.6.4 (2026-09-17). ngt 0.6.0 (2026-02-27).
  neighbor-s3 0.1.0 (2025-10-03).
- blazer 3.5.2 (2026-09-25): https://github.com/ankane/blazer (`app/controllers/blazer/queries_controller.rb`
  CSV export, `uploads_controller.rb` CSV-only uploads, `lib/blazer/adapters/base_adapter.rb`)
- chartkick 5.2.1 (2025-10-13). vega 0.6.0 (2026-05-11). mapkick-rb 0.3.0 (2026-04-15).
  groupdate 6.8.0 (2026-04-04). hightop 1.0.0. active_median 1.0.0. rollups 0.6.0 (2026-04-15).
- ahoy_matey 5.5.0 (2026-04-08). searchkick 6.1.2 (2026-06-05). pghero 4.0.1 (2026-08-15).
  pgdexter 0.6.3 (2025-10-15). pgslice 0.7.2 (2026-01-06). distribute_reads 1.1.0 (2026-04-02).
  pgsync 0.8.1 (2025-09-12).
- lockbox 2.2.0 (2026-04-04). blind_index 2.8.1 (2026-06-29). tomoto 0.6.2 (2026-02-22).
  datasketches 0.5.2 (2026-04-07). trove 0.4.0 (2026-04-09). tensorflow 0.2.0 (2021-07-07,
  stale). hexspace 0.3.0 (2025-04-03). drill-sergeant 0.4.0 (2026-04-08).
- Fiddle closure threading: https://github.com/ruby/fiddle/blob/master/ext/fiddle/closure.c
  (`rb_thread_call_with_gvl` when not holding the GVL)
- snappy gem 0.5.1 (2026-03-18): https://rubygems.org/gems/snappy
