# Parquet test fixtures

## Source and license

The `*.parquet` files in this directory are copied unmodified from the
[apache/parquet-testing](https://github.com/apache/parquet-testing) repository,
`data/` directory (`geospatial.parquet` and `geospatial-with-nan.parquet` come
from `data/geospatial/`), at commit
`56653c437c8092f704a092d0d1d4e600124cd49f`.

They are licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0), copyright The Apache Software
Foundation. See the upstream repository's `LICENSE.txt`/`NOTICE.txt`.
Descriptions of many of the files are in the upstream `data/README.md` and
the per-file `*.md` notes there.

The encrypted files (`*.parquet.encrypted`, and `aes256/` with 256-bit keys
from parquet-mr) come from `data/` and `data/aes256/` at the same commit.
Their keys are listed in the upstream
`data/README.md` and in `test/encryption_test.rb`;
`encrypt_columns_and_footer_aad` and `..._disable_aad_storage` use the AAD
prefix `"tester"`.

Not included: `large_string_map.brotli.parquet` (4KB on disk but decompresses to two ~1GB
strings), the bloom filter `.bin` blobs and the `*_expect.csv` files (the
JSON expectations cover the same ground). Files whose names mention
`corrupt`/`malformed` are included on purpose, for error-path tests.

`../generated/` holds our own fixtures written by pyarrow
(`../generate_fixtures.py`), with expectations in the same format.

## Expectation files

`expected/<file>.parquet.json` is produced by `../generate_expectations.py`
with pyarrow 25 (`pq.read_metadata` + `pq.read_table` with default options).
Re-run with:

    python test/fixtures/generate_expectations.py            # both dirs
    python test/fixtures/generate_fixtures.py                # regenerates generated/ + its expectations

Keys:

- `num_rows`, `num_row_groups`, `created_by`: from the footer.
- `schema`: one entry per leaf column, in footer order:
  `path` (array of names, from pyarrow's dotted path split on `.`),
  `physical_type` (`INT32`, `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY`, ...),
  `logical_type` (pyarrow's string form, for example `String`, `Decimal(precision=5, scale=2)`,
  `Timestamp(isAdjustedToUTC=true, timeUnit=milliseconds, is_from_converted_type=false, force_set_converted_type=false)`,
  or `null` when absent), `converted_type` (`UTF8`, `DECIMAL`, ... or `null`),
  `max_definition_level`, `max_repetition_level`. There's also `type_length` for
  FIXED_LEN_BYTE_ARRAY and `precision`/`scale` for decimals.
- `row_group_num_rows`: array, one per row group.
- `codecs`: `codecs[row_group][column]`, codec name (`UNCOMPRESSED`, `SNAPPY`, `GZIP`, `ZSTD`, `BROTLI`, `LZ4`, `LZ4_RAW`, ...).
- `encodings`: `encodings[row_group][column]`, the column chunk's `encodings` list from metadata, **sorted** alphabetically
  (includes level encodings such as `RLE`/`BIT_PACKED`).
- `columns`: top-level column names, as pyarrow reads them.
- `rows`: first up to 50 rows, converted as described below.
- `row_hash`: SHA-256 of all rows (see below).
- `checksum_verification_error` (only for files with `checksum` in the name): `null` if
  reading with `page_checksum_verification=True` succeeds, otherwise the error message.
- `error`: present when pyarrow could not read the data. In that case the metadata keys
  above are still present when the footer itself could be read, but `rows`/`row_hash` are absent.

## Value conversion rules

Each row is a JSON object keyed by top-level column name. Values are converted
by type (logical type, as pyarrow reads it):

| Type | JSON |
|---|---|
| null | `null` (at any nesting level) |
| boolean | `true` / `false` |
| any integer (int8..int64, uint8..uint64) | JSON integer (full precision, e.g. `18446744073709551615`) |
| float16 / float32 / float64 | JSON number: the value widened exactly to a double, formatted as Python `repr()` (shortest round-trip). NaN -> `"NaN"`, +inf -> `"Infinity"`, -inf -> `"-Infinity"` (strings). `-0.0` stays `-0.0`. |
| string (UTF8/STRING, JSON, ENUM annotated and large_string) | JSON string |
| binary / fixed_len_byte_array without string annotation (includes UUID, INTERVAL, geometry, BSON, and un-annotated BYTE_ARRAY) | `{"base64": "<standard base64 with = padding>"}` (Ruby: `Base64.strict_encode64`) |
| decimal (any physical type) | string in plain notation with exactly `scale` fractional digits, no exponent, `-` for negatives: `"-1.23"`, `"0.0000000000"`, `"42"` (scale 0) |
| date | `"YYYY-MM-DD"` (proleptic Gregorian) |
| time (ms/us/ns) | `"HH:MM:SS.fff"` with 3/6/9 fractional digits for millis/micros/nanos |
| timestamp (ms/us/ns) | `"YYYY-MM-DDTHH:MM:SS.fff"` with 3/6/9 fractional digits by unit, followed by `Z` iff the timestamp is UTC-adjusted (`isAdjustedToUTC=true`). Values are always rendered in UTC, never shifted to a zone. |
| INT96 timestamp | read as nanosecond timestamp without UTC flag: `"YYYY-MM-DDTHH:MM:SS.fffffffff"` (9 digits, no `Z`) |
| list (any encoding: 3-level, 2-level legacy, repeated fields) | JSON array; null list -> `null`, empty list -> `[]` |
| map | JSON array of `[key, value]` pairs in stored order; null map -> `null` |
| struct / group | JSON object keyed by field name; null struct -> `null` |

Date/time formatting details: years are zero-padded to 4 digits (`0001-01-01`);
negative years get a leading `-`. Fractions are computed with floor division,
so pre-epoch values render as positive fractions (`-1` ns -> `1969-12-31T23:59:59.999999999`).
Seconds-unit timestamps (not produced by Parquet) would get no fraction.

Note on floats: Python `repr()` takes the shortest round-trip digits and
uses fixed notation when the decimal point position `decpt` (value =
`0.DIGITS x 10^decpt`) is in `-4 < decpt <= 16`, and otherwise scientific
notation `D[.DDD]e±XX` (exponent signed, at least 2 digits). Examples: `1e-05`,
`0.0001`, `1000000000000000.0`, `1e+16`, `5e-324`, `-0.0`, `1.100000023841858`.
Ruby's `Float#to_s` gives the same digits but switches to scientific notation
earlier and writes `1.0e-05`, and Ruby's `JSON.generate` has its own float
format (`0.00001`, `1e+15`), so neither matches byte for byte. This helper
matches Python `repr()` for all finite doubles (checked against 350k random
values):

```ruby
# Format a finite Float exactly like Python's repr(float)
def python_float_repr(f)
  return "-0.0" if f.zero? && (1.0 / f).negative?
  return "0.0" if f.zero?
  s = f.abs.to_s                      # shortest round-trip digits, Ruby formatting
  mantissa, exp = s.split("e")
  int_part, frac_part = mantissa.split(".")
  digits = (int_part + frac_part.to_s).sub(/\A0+/, "")
  decpt = exp ? exp.to_i + 1 : (int_part == "0" ? -(frac_part[/\A0*/].length) : int_part.length)
  digits = digits.sub(/0+\z/, "")
  digits = "0" if digits.empty?
  sign = f.negative? ? "-" : ""
  if decpt > -4 && decpt <= 16
    if decpt <= 0
      sign + "0." + ("0" * -decpt) + digits
    elsif digits.length <= decpt
      sign + digits + ("0" * (decpt - digits.length)) + ".0"
    else
      sign + digits[0, decpt] + "." + digits[decpt..]
    end
  else
    e = decpt - 1
    m = digits.length > 1 ? digits[0] + "." + digits[1..] : digits
    sign + m + "e" + (e.negative? ? "-" : "+") + e.abs.to_s.rjust(2, "0")
  end
end
```

## row_hash

    lines = [canonical_json(row) for row in all_rows]     # every row in the file, in order
    row_hash = sha256("\n".join(lines).encode("utf-8")).hexdigest()

- No trailing newline. A file with zero rows hashes the empty string
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
- `canonical_json` is Python `json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)`:
  - no whitespace at all;
  - object keys sorted (by code point, the same as UTF-8 byte order), at every nesting level;
  - non-ASCII characters are written raw as UTF-8, not `\u`-escaped;
  - escapes: `\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`; other control characters below U+0020 become `\u00XX` (lowercase hex);
    `/` and U+007F are not escaped. This is the same as Ruby's `JSON.generate` defaults.
  - floats as described above (Python `repr`).

In Ruby, `JSON.generate` produces the same escaping, but its float formatting differs.
So either serialize with a small custom emitter (sorted keys, `JSON.generate(str)` for
strings, `python_float_repr` for floats, `to_s` for integers), or `JSON.generate`
the row and patch the float output. Then:

    Digest::SHA256.hexdigest(lines.join("\n"))

## Files pyarrow 25 cannot read (expectation has `error`)

- `alp_extended.zstd.parquet`: ALP encoding is not supported ("Unknown encoding type").
- `flba12_timestamp.parquet`: TIMESTAMP logical type on FIXED_LEN_BYTE_ARRAY(12) is rejected.
- `incorrect_map_schema.parquet`: map keys not marked `required` are rejected.
- `int32_with_uuid_logical_type.parquet`: UUID logical type on INT32 is rejected.

A lenient reader might decode some of these anyway; they're mainly useful for error handling.
