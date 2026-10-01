# Proposal: optional native Snappy via the `snappy` gem

Status: proposal, not implemented. Measured 2026-10-01 on an M-series Mac, Ruby 3.4.1, using a
throwaway GEM_HOME (nothing was added to the project).

## Summary

Snappy is Parquet's default codec, and the one most files in the wild use. Herringbone's Snappy
is pure Ruby. It is correct and interoperable, but it is the single biggest cost in reading and
writing typical files. The `snappy` gem (miyucy/snappy) is a maintained C++ binding to Google's
libsnappy. Used as an optional speedup, loaded on first use with a silent fallback to pure Ruby
(the same pattern as the `xxhash` gem for bloom filters), it would:

- make Snappy compression **27× faster** and decompression **12× faster**;
- cut reading a typical 1M-row Snappy file from 4.9 s to 2.8 s (2.7× faster for 2 columns);
- make writing with Snappy about as fast as writing uncompressed (5.5 s → 2.7 s for 300k rows).

Recommendation: do it. It is a small change (about half a day including tests and CI), with the
same shape as the existing optional gems.

## Why

| Codec work on 16 MB of real page data | Pure Ruby (Herringbone) | Native (`snappy` 0.5.1) | Speedup |
|---|---|---|---|
| Compress | 11.3 MB/s | 307.7 MB/s | 27× |
| Decompress | 43.5 MB/s | 536.2 MB/s | 12× |
| Compression ratio | 0.750 | 0.750 | same |

End to end, on the 1M-row, 15-column benchmark file (`benchmark/dataset.rb`, Snappy-compressed)
and a 300k-row write of the same schema:

| | Pure Ruby | Native | |
|---|---|---|---|
| Read 1M rows × 15 columns (`as: :columns`) | 4.88 s | 2.77 s | 1.8× |
| Read 2 columns | 1.03 s | 0.38 s | 2.7× |
| Write 300k rows, Snappy | 5.48 s | 2.72 s | 2.0× |
| Write 300k rows, uncompressed (reference) | 2.37 s | 2.49 s | — |

Compression takes 3.1 of the 5.5 seconds of a pure-Ruby Snappy write; with the native gem that
drops to about 0.2 s. On the read side the remaining time is decoding and building Ruby objects,
so the gain is largest when few columns or fixed-width columns are read (and it compounds with the
upcoming `as: :numo` reads, where decompression would otherwise dominate).

## Candidate gems

| Gem | Latest release | Downloads | Notes |
|---|---|---|---|
| **`snappy`** (miyucy/snappy) | 0.5.1, 2026-03-18 (0.5.0 in January) | 15.6M | MIT. Binds libsnappy; vendors its source. Also ships a `java` platform gem for JRuby. **Recommended.** |
| `snappy-ruby` (jgreninger) | 1.0.2, 2025-11-03 | ~1k | BSD-3. Very new, barely used. |
| `snappy_ext` | 0.1.2, 2011-03-24 | 23k | Abandoned. |

`snappy` API (0.5.1): `Snappy.deflate(str)` / `Snappy.inflate(str)` work on **raw Snappy blocks**,
which is exactly what Parquet pages use (not the Snappy framing format). Aliases: `compress`,
`uncompress`, `dump`, `load`; `Snappy.valid?(str)` checks a block. Output is BINARY
(ASCII-8BIT).

Compatibility was checked both ways: blocks compressed by the gem decompress in Herringbone's pure
Ruby codec and vice versa, byte for byte. The gem's compressed output is not guaranteed to be
byte-identical to ours, but any valid block is valid Parquet.

## Installation caveat (important)

The gem's `extconf.rb` first looks for a system libsnappy (`pkg-config libsnappy` or
`-lsnappy`). If there is none, it builds the vendored copy, which **needs `cmake`**. On this Mac
(no libsnappy, no cmake) `gem install snappy` failed with "extconf failed"; with `cmake` on the
PATH it built in about 7 seconds. So users need one of:

- `brew install snappy` / `apt-get install libsnappy-dev`, or
- `cmake` (preinstalled on GitHub's Ubuntu and macOS runners; `brew install cmake` locally).

This is exactly why it must stay optional: the pure-Ruby codec keeps Herringbone installable
anywhere, and the native gem is an opt-in speedup.

## Design

Follow the `xxhash` pattern from the bloom filter work:

- **Loading:** on the first Snappy compress or decompress, try `require "snappy"`. If it loads,
  use `::Snappy.deflate` / `::Snappy.inflate`; if not, silently stay with the pure-Ruby codec. It
  is only a speedup, so a missing gem must never raise (unlike ZSTD/Brotli, where a missing gem
  raises `MissingCodecError` because there is no fallback).
- **Switch for tests and benchmarks:** `Herringbone::Codecs::Snappy.backend = :ruby | :native |
  nil` (nil = automatic), matching `Herringbone::XXHash.backend=`. Not promoted in the README.
- **Size check stays:** `Compression.decompress` already verifies the decompressed size against
  the page header; keep that, and map the gem's errors (`Snappy::Error`) to `FormatError` with the
  column name, as for the other codecs.
- **Encoding:** pass BINARY strings in; the gem returns BINARY.
- **The `IO::Buffer` path** in the pure-Ruby decompressor stays for the fallback.
- **Gemfile:** add `gem "snappy"` to the existing `:speedups` group (with `xxhash`), not the
  gemspec. The CI job "Without zstd/brotli/xxhash gems" (`BUNDLE_WITHOUT=codecs:speedups`)
  then also covers the pure-Ruby path; the other jobs cover native (GitHub runners have cmake).
- **README:** one sentence next to the `xxhash` note in Installation: "install the `snappy` gem
  (needs libsnappy or cmake to build) for much faster Snappy".
- **`Herringbone.codecs`** is unchanged: Snappy is always available either way.

## Tests

- Both backends decode each other's blocks: random data, highly compressible data, empty input,
  sizes around the 64 KB block boundary, the existing Snappy test vectors.
- Corrupt input raises `FormatError` with either backend; a size mismatch is still caught.
- The full suite passes with the native backend forced, with the pure-Ruby backend forced, and
  without the gem installed.
- Interop: pyarrow reads files written with the native backend (the interop CI job).

## Open questions

- Should Herringbone write with the native backend but still *verify* decompressed sizes the same
  way? (Yes; it is cheap.)
- JRuby: the gem's `java` platform build uses snappy-java. Worth a smoke test if JRuby support is
  ever claimed.
- Thread safety / GVL: the gem's C functions run with the GVL held. For multi-threaded readers,
  a GVL-releasing variant would be an upstream improvement, not needed now.
