# Benchmark results

Machine: Apple Silicon (arm64-darwin24), ruby 3.4.1 without YJIT, 2026-09-30.
Dataset: `dataset.rb`, 15 Rails-style columns (ids, 3 low-cardinality enum/string columns, decimal,
nullable double/strings, int32, boolean, 2 timestamps, nullable date).

## herringbone vs parquet-ruby 0.9.0 (1M rows) — `compare_parquet_ruby.rb`

"Peak RSS growth" is sampled every 20ms in a forked child, relative to the child's baseline.
parquet-ruby writes one row group per file here (parquet-rs default); herringbone uses 100k-row groups.

```
herringbone 0.1.0, parquet-ruby 0.9.0, ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [arm64-darwin24]

== Write (snappy)
herringbone Writer (hash rows)                             23.01s      43k rows/s      291 MB peak RSS growth  44.2 MB
herringbone Writer (hash rows, uncompressed)               10.93s      92k rows/s      296 MB peak RSS growth  94.4 MB
herringbone Writer (hash rows, zstd via zstd-ruby)         11.23s      89k rows/s      317 MB peak RSS growth  25.7 MB
parquet-ruby write_rows (array rows)                     4.42s     226k rows/s      373 MB peak RSS growth  45.2 MB

== Read all rows
herringbone each_row, herringbone file                         9.71s     103k rows/s      249 MB peak RSS growth  1000000 rows
parquet-ruby each_row, herringbone file                     5.25s     191k rows/s      255 MB peak RSS growth  1000000 rows
herringbone each_row, parquet-ruby file                    14.36s      70k rows/s      759 MB peak RSS growth  1000000 rows
parquet-ruby each_row, parquet-ruby file                 5.34s     187k rows/s      268 MB peak RSS growth  1000000 rows

== Read one column (amount)
herringbone column, herringbone file                           2.50s     400k rows/s      246 MB peak RSS growth  sum=49970731364.8
parquet-ruby each_column, herringbone file                  1.60s     627k rows/s      197 MB peak RSS growth  sum=49970731364.8
herringbone column, parquet-ruby file                       2.42s     413k rows/s      288 MB peak RSS growth  sum=49970731364.8
parquet-ruby each_column, parquet-ruby file              1.52s     656k rows/s      200 MB peak RSS growth  sum=49970731364.8

```

## 20M-row streaming export — `rails_export.rb`

Records are produced `find_each`-style (batches of 1000 attribute Hashes) and streamed into one
file with 100k-row groups, snappy. Live Ruby heap stays flat (~72k slots after each flush); RSS
plateaus in the 450–490 MB range (malloc retaining freed page buffers), independent of row count.

```
Exporting 20000000 rows to /private/tmp/claude-501/-Users-julik-Code-libs-herringbone/2d9676f4-e126-46c5-ab82-0da5b4975abe/scratchpad/export20m.parquet (row groups of 100000, snappy)
        rows   elapsed     rows/s    RSS MB   file MB     GC runs
     1000000     18.7s      53361       300      44.2         302
     2000000     37.6s      53201       302      88.4         515
     3000000     56.1s      53469       384     132.5         681
     4000000     74.5s      53657       424     176.7         852
     5000000     93.4s      53537       451     220.9        1007
     6000000    112.1s      53543       445     265.1        1150
     7000000    131.3s      53325       285     309.3        1308
     8000000    149.8s      53407       365     353.5        1470
     9000000    168.5s      53426       423     397.6        1633
    10000000    187.0s      53464       444     441.8        1795
    11000000    205.7s      53473       459     486.0        1958
    12000000    224.2s      53512       457     530.2        2106
    13000000    242.8s      53538       464     574.4        2254
    14000000    261.4s      53547       472     618.6        2397
    15000000    280.2s      53523       468     662.7        2537
    16000000    299.0s      53515       473     706.9        2678
    17000000    317.8s      53497       474     751.1        2816
    18000000    336.9s      53423       297     795.3        2954
    19000000    355.4s      53462       486     839.5        3090
    20000000    373.9s      53485       485     883.7        3227
Done in 374.0s (53480 rows/s), file 883.9 MB, peak sampled RSS 486 MB
Verified 200 row groups, 20000000 rows; sampled rows match the source
```

## 20M-row export with the current defaults (zstd, row_group_bytes: 16MB)

```
Exporting 20000000 rows to /private/tmp/claude-501/-Users-julik-Code-libs-herringbone/2d9676f4-e126-46c5-ab82-0da5b4975abe/scratchpad/export20m.parquet (default options)
        rows   elapsed     rows/s    RSS MB     GC runs
     1000000      9.8s     102247       283         318
     2000000     19.8s     101018       323         493
     3000000     29.7s     101152       350         654
     4000000     39.0s     102560       382         796
     5000000     48.8s     102459       396         941
     6000000     58.7s     102140       397        1077
     7000000     68.1s     102749       292        1193
     8000000     77.9s     102694       345        1308
     9000000     87.7s     102595       363        1422
    10000000     97.6s     102495       393        1536
    11000000    106.9s     102931       409        1655
    12000000    116.7s     102832       409        1769
    13000000    126.4s     102829       416        1877
    14000000    135.8s     103095       424        1986
    15000000    145.5s     103077       418        2098
    16000000    155.2s     103082       427        2210
    17000000    164.5s     103352       303        2320
    18000000    173.9s     103483       405        2428
    19000000    183.8s     103356       442        2540
    20000000    193.5s     103338       389        2651
Done in 193.6s (103307 rows/s), file 512.3 MB, peak sampled RSS 442 MB
Row groups hold 3728..115704 rows
Verified 175 row groups, 20000000 rows; sampled rows match the source
```
