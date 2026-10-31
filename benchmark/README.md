# Corpus benchmarks

From the repository root, with the gem's dependencies installed:

```sh
ruby benchmark/suite.rb
ruby benchmark/suite.rb --long
```

The default uses 20,000 rows and three repetitions, aiming for about 30 seconds on
a development machine. `--long` uses 1,000,000 rows and five repetitions with no
time cap. The baseline uses the shipped pure-Ruby Snappy codec.

## CLI usage

```sh
ruby benchmark/suite.rb [options]
ruby benchmark/suite.rb --help
```

| Option | Purpose |
|---|---|
| `-h`, `--help` | Print usage and exit without running benchmarks. |
| `--long` | Use 1,000,000 rows and five repetitions, with no time cap. |
| `--corpus DIR` | Generate or reuse compatible input files in this directory. |
| `--output DIR` | Save results in a new or empty directory; defaults to a retained temporary directory. |
| `--implementation-file FILE` | Load a trusted Ruby file registering comparison setups. |

Options can be combined:

```sh
ruby benchmark/suite.rb --long --corpus /tmp/herringbone-inputs --output /tmp/herringbone-long-run
```

## Scenarios

Nine scenarios cover:

- Typed writes.
- Coercible writes.
- Reads.
- Selected-row replacement.
- Whole-column replacement.
- Deletion.
- Combining identical schemas.
- Combining schemas by union.
- Combining schemas by intersection.

Inputs include:

- Numeric columns.
- Text columns.
- Binary columns.
- Temporal columns.
- Nulls.
- Legacy schemas.

## Reuse the inputs

```sh
ruby benchmark/suite.rb --corpus /tmp/herringbone-inputs --output /tmp/herringbone-run-1
ruby benchmark/suite.rb --corpus /tmp/herringbone-inputs --output /tmp/herringbone-run-2
```

The first run generates the corpus; the second checks and reuses it. Output
directories must be new or empty, and parent directories must exist. Incompatible
or damaged corpora are refused; use a new directory to regenerate them. Without
these options, the script prints a retained temporary directory. Remove it when finished.

## Compare an implementation

Save this as `/tmp/native-snappy.rb`, with the optional `snappy` gem installed:

```ruby
BenchmarkSuite.register_implementation("native-snappy") do
  require "snappy"
  Herringbone::Codecs::Snappy.backend = :native
  {"gem_version" => Gem.loaded_specs.fetch("snappy").version.to_s}
end
```

Then run:

```sh
ruby benchmark/suite.rb --implementation-file /tmp/native-snappy.rb
```

`native-snappy` names the comparison. Before each candidate trial, the runner calls
the block, then times the scenario. The returned Hash records the installed codec
version under `backend.custom.gem_version` in the trial log.

The runner first loads the file just to discover its registered names. Keep requires
and implementation changes **inside the block** so they apply only to that named
implementation. Top-level code also runs during discovery and for every candidate
in the file. Each trial gets a fresh process; the `ruby` baseline never loads this file.

Return a JSON-compatible Hash to record extra details, or `nil` when none are needed.

## Read the results

Check that `summary.json` has `"passed": true`. The terminal shows medians and ranges,
for example from a 20,000-row local run:

```text
write_typed        ruby               0.647s [  0.616,   0.652]    30930 rows/s (3 samples)
  Writer-active: 0.600s [0.568, 0.603]
```

Here the median write took 0.647 seconds; the three samples ranged from 0.616 to
0.652 seconds. Writer-active time excludes record preparation, while still
including conversion, encoding, compression, IO and GC during writer work.

`results.jsonl` has one job per line. A write trial looks like:

```text
{
  ...
  "scenario": "write_typed",
  "implementation": "ruby",
  "passed": true,
  "records": [
    ...
    {"event": "measured", "seconds": 0.647..., "writer_active_seconds": 0.600..., ...},
    ...
  ],
  ...
}
```

- Operation wall/CPU time, allocations and rows/s exclude startup and validation.
  Peak RSS covers the entire worker, including startup and validation.
- Every output is checked for schema, values, order and row count. All repetitions
  are retained; a failure or detected source change makes the command exit nonzero.
- Successful trial files are removed; corpus files, logs and failed trial files
  remain. Filesystem caches are not flushed and files are not fsynced.
