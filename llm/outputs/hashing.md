# Bloom filter hashing: why it was slow and what changed

Commit `f249c4a` ("Faster bloom filter hashing: distinct values once, big-integer-free XXH64,
optional xxhash gem"), on top of the bloom filter support from `e543808`.

## The problem

Parquet bloom filters hash every value with XXH64 (seed 0). Herringbone's first version did this
in pure Ruby. It was correct but made writing slow once a filter was enabled:

| Writing 1M rows (int64 + ~22-byte string) | Time |
|---|---|
| No bloom filters | ~5–6 s |
| Filter on the int column | ~9–17 s |
| Filter on the string column | ~21–22 s |

## Why it was slow

- **Big integers everywhere.** XXH64 works on unsigned 64-bit numbers. Ruby Integers become
  heap-allocated Bignums above 2^62, so the straightforward implementation (`(a * PRIME) & M64`)
  created about 25 Bignum objects per hash.
- **GC under a large heap.** In a standalone benchmark that still gave ~0.76M hashes/s for
  8-byte integers. Inside the writer, with its large live heap, Ruby 3.4 kept its small-object
  pool tiny and ran over 1,000 full garbage collections in one run, so hashing dropped to
  ~0.12M/s (and ~0.05M/s for strings), about 6x slower than the benchmark suggested.
- **Hashing every value.** The writer hashed each value, including repeats, and de-duplicated
  the hashes afterwards.

## What changed

1. **Hash each distinct value once.** Dictionary-encoded chunks already hold their distinct
   values (the dictionary). Other chunks are de-duplicated before hashing
   (`BloomFilter.hash_physical_all(values, type, distinct: true)`). Floats are compared by their
   bytes, so `-0.0`/`0.0` and NaNs with different bit patterns stay separate. This does not help
   when every value is unique (the benchmark above), but it does for typical data.
2. **Pure-Ruby XXH64 without big integers** (`lib/herringbone/xxhash.rb`):
   - 64-bit values are kept as two 32-bit halves, and the prime constants are split into 16-bit
     pieces, so no intermediate number ever becomes a Bignum.
   - Each operation (multiply, rotate, add, avalanche) is written once as a small code template;
     the templates are expanded into the hash methods at load time (`module_eval`), so the hot
     paths contain no method calls.
   - Shifts are written as `*` and `/` by powers of two: Ruby's VM has fast paths for those but
     not for Integer `<<`/`>>`, worth about 30%.
   - Special paths for 4- and 8-byte values and single bytes, plus bulk versions
     (`xxh64_all`, `xxh64_u64_all`, `xxh64_u32_all`).
   - Signed values are accepted directly, removing the `value & M64` that created a Bignum for
     every negative number.
   - `BloomFilter#insert_hash` / `#might_contain_hash?` avoid Bignums too, and the new
     `BloomFilter#insert_hashes` inserts in bulk (0.59 s instead of 0.87 s per 1M inserts).
3. **Optional native backend: the `xxhash` gem.**
   - Chosen over `digest-xxhash`: `xxhash` 0.7.0 (Aug 2025, 16M downloads) is about 2.3x faster.
     Results are identical on Ruby 3.0 (CI), 3.2, 3.4 and 4.0.
   - It is used automatically when it can be required. If it is missing, hashing silently stays
     in pure Ruby: it is only a speedup, unlike the ZSTD/Brotli codec gems, which raise
     `MissingCodecError` when a file needs them.
   - `HERRINGBONE_PURE_RUBY_XXHASH=1` or `Herringbone::XXHash.backend = :ruby` forces pure Ruby;
     `backend = :native` raises `UnsupportedError` if the gem is missing; `nil` / `:auto` restores
     the default. `Herringbone::XXHash.backend` and `.native_available?` report the state.
   - Not a runtime dependency: it sits in the Gemfile's `:speedups` group.

## Results

Ruby 3.4.1 on an M-series Mac (numbers vary by about ±10% with machine load).

| Hashing speed | Before | After |
|---|---|---|
| Pure Ruby, 8-byte integers, clean process | 0.76M/s | 1.30–1.42M/s |
| Pure Ruby, 20-byte strings, clean process | 0.34M/s | 0.54–0.59M/s |
| Pure Ruby inside a writer (large heap) | 0.12M/s ints, 0.05M/s strings | same as a clean process |
| Native (`xxhash`), 8-byte integers | — | 6.9–7.4M/s |
| Native (`xxhash`), 20-byte strings | — | 11.9–12.5M/s |

| Writing 1M rows (int64 + 22-byte string) | Before | After, pure Ruby | After, native |
|---|---|---|---|
| No filters | 6.24 s | 5.63 s | 5.63 s |
| Filter on the int column | 16.81 s | 6.83 s | 6.19 s |
| Filter on the string column | 21.44 s | 8.38 s | 6.06 s |

The time a filter *adds* is the number that matters: on the int column it went from 10.6 s to
1.2 s (pure Ruby) or ~0.5 s (native), and on the string column from 15.2 s to 2.75 s or ~0.5 s.
Reproduce with `ruby -Ilib benchmark/bloom_filters.rb` (`ROWS` and `HASHES` can be set in the
environment).

## Testing

- `test/bloom_filter_test.rb` (23 tests): the pure-Ruby test vectors are checked directly
  whichever backend is active; both backends give identical results on 300+ random strings,
  64-bit values (including edge and negative values) and 32-bit words, through single and bulk
  functions; backend selection and the environment variable; `insert_hashes` sets the same bits
  as `insert_hash`; distinct hashing for integers, strings and floats (`-0.0`, `0.0`, NaN), both at
  the helper level and through a written file.
- The full suite passes with the gem (588 runs), with pure Ruby forced (588 runs) and without
  the optional gems (564 runs).
- CI: the job without optional gems now uses `BUNDLE_WITHOUT=codecs:speedups` ("Without
  zstd/brotli/xxhash gems") and checks that `xxhash` is really absent; Ruby 3.0–4.0 jobs run with
  the gem installed.

## Files

- `lib/herringbone/xxhash.rb`: rewritten
- `lib/herringbone/bloom_filter.rb`: `hash_physical_all(distinct:)`, `insert_hashes`, Bignum-free
  `insert_hash` / `might_contain_hash?`
- `lib/herringbone/writer.rb`: `build_bloom_filter` hashes distinct values only
- `Gemfile`: `:speedups` group with `xxhash`
- `.github/workflows/ci.yml`: the no-optional-gems job also excludes `xxhash`
- `test/bloom_filter_test.rb`, `benchmark/bloom_filters.rb`, README ("Bloom filters"), TODO.md
