# Zstandard fixtures

- `golden/` holds `tests/golden-decompression/*.zst` and, prefixed with `error-`,
  `tests/golden-decompression-errors/*.zst` from [zstd](https://github.com/facebook/zstd) at
  49cf51799ea051457f57243527aa2058f999f005 (BSD license): edge cases the reference decoder must
  accept, and corrupt frames it must reject.
- Everything else comes from `generate.rb`, which compresses with the reference zstd CLI.
