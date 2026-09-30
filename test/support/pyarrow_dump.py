#!/usr/bin/env python3
"""
Reads Parquet files with pyarrow and prints one JSON object with, per file:

  rows        canonical rows (same conversion rules as test/fixtures/generate_expectations.py)
  metadata    num_rows, row groups, per-column codec/encodings/statistics
  checksum    None if page CRC verification succeeded, else the error
  stats_errors  mismatches between the statistics in the footer and the column data
  error       set when pyarrow could not read the file

Usage: pyarrow_dump.py FILE [FILE ...]   (use --check to only verify pyarrow is importable)
"""

import decimal
import json
import struct
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fixtures"))

import pyarrow as pa  # noqa: E402
import pyarrow.compute as pc  # noqa: E402
import pyarrow.parquet as pq  # noqa: E402

from generate_expectations import table_rows  # noqa: E402


def unwrap(arr):
    if isinstance(arr, pa.ChunkedArray):
        arr = pa.concat_arrays(arr.chunks) if arr.num_chunks else pa.array([], type=arr.type)
    if isinstance(arr.type, pa.BaseExtensionType):
        arr = arr.storage
    return arr


def leaf_array(table, path):
    """Returns the flattened leaf values for a Parquet column path."""
    arr = unwrap(table.column(path[0]))
    rest = path[1:]
    while rest:
        arr = unwrap(arr)
        t = arr.type
        if pa.types.is_map(t):
            # key_value, key|value
            which = rest[1]
            arr = arr.keys if which == "key" else arr.items
            rest = rest[2:]
        elif pa.types.is_list(t) or pa.types.is_large_list(t):
            # list, element
            arr = arr.flatten()
            rest = rest[2:]
        elif pa.types.is_struct(t):
            names = [t.field(i).name for i in range(t.num_fields)]
            arr = arr.flatten()[names.index(rest[0])]
            rest = rest[1:]
        else:
            raise TypeError("cannot descend into %s at %s" % (t, rest))
    return unwrap(arr)


def py(v):
    if isinstance(v, bytes):
        return v.hex()
    if isinstance(v, float) and v != v:
        return "NaN"
    return repr(v) if not isinstance(v, (int, str, bool, type(None))) else v


def physical(v, t):
    """Converts a min/max value computed from column data to its Parquet physical form."""
    if isinstance(v, str):
        return v.encode("utf-8")
    if pa.types.is_decimal(t):
        # The default decimal context (28 digits) would round 38-digit values
        with decimal.localcontext() as ctx:
            ctx.prec = 100
            return int(v.scaleb(t.scale))
    return v


def raw_stat(v, t, half):
    """Normalizes a raw statistics value to what physical() produces from column data."""
    if isinstance(v, bytes):
        if half:
            return struct.unpack("<e", v)[0]
        if pa.types.is_decimal(t):
            return int.from_bytes(v, "big", signed=True)
    if isinstance(v, int) and v < 0 and pa.types.is_unsigned_integer(t):
        # Unsigned columns store their values in signed physical types
        return v + (1 << t.bit_width)
    return v


def stats_check(pf, md):
    errors = []
    for g in range(md.num_row_groups):
        table = pf.read_row_group(g)
        for c in range(md.num_columns):
            col = md.row_group(g).column(c)
            st = col.statistics
            if st is None or not st.has_min_max:
                continue
            path = col.path_in_schema.split(".")
            leaf = leaf_array(table, path)
            half = pa.types.is_float16(leaf.type)
            if half:
                # pyarrow has no float16 kernels; float32 holds every float16 exactly
                leaf = leaf.cast(pa.float32())
            if pa.types.is_floating(leaf.type):
                leaf = pc.filter(leaf, pc.invert(pc.is_nan(leaf)))
            valid = leaf.drop_null()
            if len(valid) == 0:
                errors.append("rg %d %s: has min/max but no values" % (g, col.path_in_schema))
                continue
            t = valid.type
            if pa.types.is_timestamp(t) or pa.types.is_time64(t) or pa.types.is_duration(t):
                valid = valid.cast(pa.int64())
            elif pa.types.is_date32(t) or pa.types.is_time32(t):
                valid = valid.cast(pa.int32())
            mm = pc.min_max(valid)
            dmin, dmax = physical(mm["min"].as_py(), t), physical(mm["max"].as_py(), t)
            smin, smax = raw_stat(st.min_raw, t, half), raw_stat(st.max_raw, t, half)
            if pa.types.is_floating(t) and dmin == 0:
                ok_min = smin == 0
            else:
                ok_min = smin == dmin
            ok_max = (smax == 0) if (pa.types.is_floating(t) and dmax == 0) else smax == dmax
            # Byte-array bounds over 64 bytes are truncated: min to a prefix, max to an upper bound
            if isinstance(dmin, bytes) and len(dmin) > 64 and not ok_min:
                ok_min = len(smin) == 64 and dmin.startswith(smin)
            if isinstance(dmax, bytes) and len(dmax) > 64 and not ok_max:
                ok_max = len(smax) <= 64 and smax > dmax[:len(smax)]
            if not (ok_min and ok_max):
                errors.append("rg %d %s: stats min/max %s/%s, data %s/%s"
                              % (g, col.path_in_schema, py(smin), py(smax), py(dmin), py(dmax)))
    return errors


def dump(path):
    out = {}
    try:
        pf = pq.ParquetFile(path)
        md = pf.metadata
    except Exception as e:  # noqa: BLE001
        return {"error": "%s: %s" % (type(e).__name__, e)}
    out["num_rows"] = md.num_rows
    out["num_row_groups"] = md.num_row_groups
    out["created_by"] = md.created_by
    out["key_value_metadata"] = {k.decode("utf-8", "replace"): v.decode("utf-8", "replace")
                                 for k, v in (md.metadata or {}).items()}
    cols = []
    for g in range(md.num_row_groups):
        rg = md.row_group(g)
        cols.append([{
            "path": rg.column(c).path_in_schema,
            "codec": rg.column(c).compression,
            "encodings": sorted(rg.column(c).encodings),
            "num_values": rg.column(c).num_values,
            "null_count": (rg.column(c).statistics.null_count
                           if rg.column(c).statistics is not None and rg.column(c).statistics.has_null_count
                           else None),
            "has_min_max": bool(rg.column(c).statistics is not None and rg.column(c).statistics.has_min_max),
        } for c in range(md.num_columns)])
    out["columns"] = cols
    try:
        table = pq.read_table(path)
        out["rows"] = table_rows(table)
    except Exception as e:  # noqa: BLE001
        out["error"] = "%s: %s" % (type(e).__name__, e)
        return out
    try:
        pq.read_table(path, page_checksum_verification=True)
        out["checksum"] = None
    except Exception as e:  # noqa: BLE001
        out["checksum"] = "%s: %s" % (type(e).__name__, e)
    try:
        out["stats_errors"] = stats_check(pf, md)
    except Exception as e:  # noqa: BLE001
        out["stats_errors"] = ["stats check crashed: %s: %s" % (type(e).__name__, e)]
    return out


def main(argv):
    if argv == ["--check"]:
        print(pa.__version__)
        return
    result = {p: dump(p) for p in argv}
    sys.stdout.write(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main(sys.argv[1:])
