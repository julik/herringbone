#!/usr/bin/env python3
"""
Generate reference expectations (JSON) for Parquet fixture files using pyarrow.

Usage:
    python test/fixtures/generate_expectations.py [DIR ...]

With no arguments, processes test/fixtures/parquet-testing and
test/fixtures/generated. For every *.parquet file in DIR, writes
DIR/expected/<basename>.json.

The value conversion rules (mirrored by the Ruby test suite) are documented
in test/fixtures/parquet-testing/README.md and in `to_json_values` below.
Tested with pyarrow 25.
"""

import base64
import hashlib
import json
import math
import os
import sys
from decimal import Decimal

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

PREVIEW_ROWS = 50
HERE = os.path.dirname(os.path.abspath(__file__))

_UNIT_DIVISOR = {"s": 1, "ms": 1_000, "us": 1_000_000, "ns": 1_000_000_000}
_UNIT_DIGITS = {"s": 0, "ms": 3, "us": 6, "ns": 9}


# ---------------------------------------------------------------------------
# Value conversion
# ---------------------------------------------------------------------------

def civil_from_days(z):
    """Days since 1970-01-01 -> (year, month, day), proleptic Gregorian,
    valid for any integer (Howard Hinnant's algorithm)."""
    z += 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return (y + 1 if m <= 2 else y), m, d


def fmt_year(y):
    return "%04d" % y if y >= 0 else "-%04d" % -y


def fmt_date(days):
    y, m, d = civil_from_days(days)
    return "%s-%02d-%02d" % (fmt_year(y), m, d)


def fmt_time_of_day(total_units, unit):
    div = _UNIT_DIVISOR[unit]
    digits = _UNIT_DIGITS[unit]
    secs, frac = divmod(total_units, div)
    h, rem = divmod(secs, 3600)
    mi, s = divmod(rem, 60)
    out = "%02d:%02d:%02d" % (h, mi, s)
    if digits:
        out += "." + str(frac).rjust(digits, "0")
    return out


def fmt_timestamp(value, unit, utc):
    div = _UNIT_DIVISOR[unit]
    secs, frac = divmod(value, div)  # floor division: frac is always >= 0
    days, sod = divmod(secs, 86400)
    out = fmt_date(days) + "T" + fmt_time_of_day(sod * div + frac, unit)
    return out + ("Z" if utc else "")


def fmt_float(f):
    if f is None:
        return None
    if math.isnan(f):
        return "NaN"
    if math.isinf(f):
        return "Infinity" if f > 0 else "-Infinity"
    return float(f)


def to_json_values(arr):
    """Convert a pyarrow Array/ChunkedArray to a list of JSON-compatible values."""
    if isinstance(arr, pa.ChunkedArray):
        out = []
        for chunk in arr.chunks:
            out.extend(to_json_values(chunk))
        return out

    t = arr.type
    if isinstance(t, pa.BaseExtensionType):
        return to_json_values(arr.storage)
    if pa.types.is_dictionary(t):
        return to_json_values(arr.dictionary_decode())
    if pa.types.is_null(t):
        return [None] * len(arr)
    if pa.types.is_boolean(t) or pa.types.is_integer(t):
        return arr.to_pylist()
    if pa.types.is_floating(t):
        return [fmt_float(v) for v in arr.to_pylist()]
    if pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t):
        return arr.to_pylist()
    if (pa.types.is_binary(t) or pa.types.is_large_binary(t)
            or pa.types.is_fixed_size_binary(t) or pa.types.is_binary_view(t)):
        return [None if v is None else {"base64": base64.b64encode(v).decode("ascii")}
                for v in arr.to_pylist()]
    if pa.types.is_decimal(t):
        return [None if v is None else format(v, "f") for v in arr.to_pylist()]
    if pa.types.is_date32(t):
        return [None if v is None else fmt_date(v) for v in arr.cast(pa.int32()).to_pylist()]
    if pa.types.is_date64(t):
        return [None if v is None else fmt_date(v // 86_400_000)
                for v in arr.cast(pa.int64()).to_pylist()]
    if pa.types.is_timestamp(t):
        utc = t.tz is not None
        return [None if v is None else fmt_timestamp(v, t.unit, utc)
                for v in arr.cast(pa.int64()).to_pylist()]
    if pa.types.is_time32(t) or pa.types.is_time64(t):
        int_type = pa.int32() if pa.types.is_time32(t) else pa.int64()
        return [None if v is None else fmt_time_of_day(v, t.unit)
                for v in arr.cast(int_type).to_pylist()]
    if pa.types.is_duration(t):
        return arr.cast(pa.int64()).to_pylist()
    if pa.types.is_map(t):
        keys = to_json_values(arr.values.field(0))
        items = to_json_values(arr.values.field(1))
        offsets = arr.offsets.to_pylist()
        return [None if not arr[i].is_valid else
                [[keys[j], items[j]] for j in range(offsets[i], offsets[i + 1])]
                for i in range(len(arr))]
    if pa.types.is_list(t) or pa.types.is_large_list(t):
        child = to_json_values(arr.values)
        offsets = arr.offsets.to_pylist()
        return [None if not arr[i].is_valid else child[offsets[i]:offsets[i + 1]]
                for i in range(len(arr))]
    if pa.types.is_fixed_size_list(t):
        child = to_json_values(arr.values)
        n = t.list_size
        return [None if not arr[i].is_valid else
                child[(arr.offset + i) * n:(arr.offset + i + 1) * n]
                for i in range(len(arr))]
    if pa.types.is_struct(t):
        names = [t.field(i).name for i in range(t.num_fields)]
        cols = [to_json_values(c) for c in arr.flatten()]
        return [None if not arr[i].is_valid else {n: c[i] for n, c in zip(names, cols)}
                for i in range(len(arr))]
    raise TypeError("Unsupported arrow type for JSON conversion: %s" % t)


def table_rows(table):
    cols = [to_json_values(table.column(i)) for i in range(table.num_columns)]
    names = table.column_names
    return [{n: c[r] for n, c in zip(names, cols)} for r in range(table.num_rows)]


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False)


def row_hash(rows):
    payload = "\n".join(canonical_json(r) for r in rows)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

def _none_if(value, *nulls):
    return None if value in nulls else value


def schema_info(md):
    out = []
    for i in range(md.num_columns):
        col = md.schema.column(i)
        lt = str(col.logical_type)
        entry = {
            "path": col.path.split("."),
            "physical_type": col.physical_type,
            "logical_type": _none_if(lt, "None"),
            "converted_type": _none_if(col.converted_type, "NONE"),
            "max_definition_level": col.max_definition_level,
            "max_repetition_level": col.max_repetition_level,
        }
        if col.physical_type == "FIXED_LEN_BYTE_ARRAY":
            entry["type_length"] = col.length
        if col.converted_type == "DECIMAL" or lt.startswith("Decimal"):
            entry["precision"] = col.precision
            entry["scale"] = col.scale
        out.append(entry)
    return out


def generate(path):
    md = pq.read_metadata(path)
    result = {
        "num_rows": md.num_rows,
        "num_row_groups": md.num_row_groups,
        "created_by": md.created_by,
        "schema": schema_info(md),
        "row_group_num_rows": [md.row_group(g).num_rows for g in range(md.num_row_groups)],
        # codecs[row_group][column]; encodings[row_group][column] -> sorted list
        "codecs": [[md.row_group(g).column(c).compression for c in range(md.num_columns)]
                   for g in range(md.num_row_groups)],
        "encodings": [[sorted(md.row_group(g).column(c).encodings) for c in range(md.num_columns)]
                      for g in range(md.num_row_groups)],
    }
    try:
        table = pq.read_table(path)
    except Exception as e:  # noqa: BLE001 - metadata is still useful for the reader
        result["error"] = "%s: %s" % (type(e).__name__, e)
        return result
    rows = table_rows(table)
    result["columns"] = table.column_names
    result["rows"] = rows[:PREVIEW_ROWS]
    result["row_hash"] = row_hash(rows)
    return result


def process_dir(d):
    out_dir = os.path.join(d, "expected")
    os.makedirs(out_dir, exist_ok=True)
    failures = []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".parquet"):
            continue
        path = os.path.join(d, name)
        try:
            result = generate(path)
        except Exception as e:  # noqa: BLE001 - even the footer could not be read
            result = {"error": "%s: %s" % (type(e).__name__, e)}
        if "error" in result:
            failures.append((name, result["error"]))
        if "checksum" in name and "error" not in result:
            try:
                pq.read_table(path, page_checksum_verification=True)
                result["checksum_verification_error"] = None
            except Exception as e:  # noqa: BLE001
                result["checksum_verification_error"] = "%s: %s" % (type(e).__name__, e)
        with open(os.path.join(out_dir, name + ".json"), "w", encoding="utf-8") as f:
            f.write(json.dumps(result, ensure_ascii=False, indent=1, allow_nan=False))
            f.write("\n")
    return failures


def main(argv):
    dirs = argv or [os.path.join(HERE, "parquet-testing"), os.path.join(HERE, "generated")]
    for d in dirs:
        if not os.path.isdir(d):
            continue
        failures = process_dir(d)
        print("%s: done, %d failure(s)" % (d, len(failures)))
        for name, err in failures:
            print("  FAILED %s: %s" % (name, err))


if __name__ == "__main__":
    main(sys.argv[1:])
