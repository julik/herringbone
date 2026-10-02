# LZO fixtures

- `velox_lzo.parquet` is `velox/dwio/parquet/tests/examples/lzo.parquet` from
  [Velox](https://github.com/facebookincubator/velox) (Apache License 2.0), a real parquet-mr file
  with hadoop-lzo pages. Velox's `ParquetReaderTest` checks the values our test checks.
- Everything else comes from `generate.rb`, which compresses with the reference liblzo2.
