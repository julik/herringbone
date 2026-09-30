#!/usr/bin/env python3
"""
Generate small, targeted Parquet fixtures with pyarrow into test/fixtures/generated/
and then write their expectations to test/fixtures/generated/expected/ using
generate_expectations.py (same JSON format as for parquet-testing).

Usage:
    python test/fixtures/generate_fixtures.py

Requires pyarrow (tested with 25.0.1) and numpy (for float16 values).
Output is deterministic in content; the "created_by" string depends on the
pyarrow version used.
"""

import datetime as dt
import os
import sys
import uuid
from decimal import Decimal

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "generated")
sys.path.insert(0, HERE)
import generate_expectations  # noqa: E402


def write(name, table, **kwargs):
    kwargs.setdefault("compression", "snappy")
    path = os.path.join(OUT, name + ".parquet")
    pq.write_table(table, path, **kwargs)
    size = os.path.getsize(path)
    assert size < 200_000, "%s is too large (%d bytes)" % (name, size)
    print("wrote %-45s %7d bytes" % (name + ".parquet", size))


# ---------------------------------------------------------------------------
# Base data
# ---------------------------------------------------------------------------

def base_table(n=200):
    return pa.table({
        "id": pa.array(range(n), pa.int64()),
        "name": pa.array([None if i % 7 == 0 else "name-%d" % (i % 13) for i in range(n)], pa.string()),
        "value": pa.array([None if i % 11 == 0 else i * 1.25 - 50 for i in range(n)], pa.float64()),
        "flag": pa.array([None if i % 5 == 0 else i % 3 == 0 for i in range(n)], pa.bool_()),
        "small": pa.array([(i * 37) % 100 - 50 for i in range(n)], pa.int32()),
    })


def codecs():
    t = base_table()
    for codec in ["none", "snappy", "gzip", "zstd", "brotli", "lz4"]:
        write("codec_%s" % codec, t, compression=codec)


def page_versions():
    t = base_table()
    write("page_v1", t, data_page_version="1.0")
    write("page_v2", t, data_page_version="2.0")
    write("page_v2_uncompressed", t, data_page_version="2.0", compression="none")
    # Many small pages, with page index, CRC checksums and statistics
    write("multi_page_with_index", base_table(1000), data_page_size=512,
          write_page_index=True, write_page_checksum=True, compression="none",
          use_dictionary=False)


def dictionary():
    t = base_table()
    write("dictionary_on", t, use_dictionary=True)
    write("dictionary_off", t, use_dictionary=False)
    # Dictionary that overflows the dictionary page limit -> falls back to PLAIN
    n = 2000
    t2 = pa.table({"s": pa.array(["unique-string-value-%06d" % i for i in range(n)])})
    write("dictionary_fallback", t2, use_dictionary=True, dictionary_pagesize_limit=4096,
          compression="none")
    # Arrow dictionary type (stored with ARROW:schema)
    t3 = pa.table({"d": pa.array(["a", "b", None, "a", "c", "b"]).dictionary_encode()})
    write("dictionary_arrow_type", t3)


def encodings():
    n = 300
    ints32 = [None if i % 17 == 0 else (i * 7919) % 2000 - 1000 for i in range(n)]
    ints32[1] = 2**31 - 1
    ints32[2] = -(2**31)
    ints64 = [None if i % 19 == 0 else (i * 104729) * (1 if i % 2 else -1) for i in range(n)]
    ints64[1] = 2**63 - 1
    ints64[2] = -(2**63)
    strings = [None if i % 13 == 0 else "prefix/common/%04d/%s" % (i // 3, "x" * (i % 5)) for i in range(n)]
    strings[3] = ""
    strings[4] = "unicode éè ☃ \U0001F600"
    binaries = [None if s is None else s.encode("utf-8") for s in strings]
    floats = [None if i % 23 == 0 else (i - 150) / 7.0 for i in range(n)]
    floats[1] = float("nan")
    floats[2] = float("inf")
    floats[3] = float("-inf")
    floats[4] = -0.0
    flba = [None if i % 29 == 0 else bytes([(i * k) % 256 for k in range(1, 5)]) for i in range(n)]
    bools = [None if i % 9 == 0 else (i % 4 in (0, 1)) for i in range(n)]

    common = dict(use_dictionary=False, compression="none")

    write("enc_plain", pa.table({
        "i32": pa.array(ints32, pa.int32()), "i64": pa.array(ints64, pa.int64()),
        "f32": pa.array(floats, pa.float32()), "f64": pa.array(floats, pa.float64()),
        "s": pa.array(strings, pa.string()), "b": pa.array(binaries, pa.binary()),
        "flba": pa.array(flba, pa.binary(4)), "bool": pa.array(bools, pa.bool_()),
    }), column_encoding="PLAIN", **common)

    for version in ["1.0", "2.0"]:
        write("enc_rle_boolean_v%s" % version[0], pa.table({"bool": pa.array(bools, pa.bool_())}),
              column_encoding={"bool": "RLE"}, data_page_version=version, **common)

    write("enc_delta_binary_packed", pa.table({
        "i32": pa.array(ints32, pa.int32()), "i64": pa.array(ints64, pa.int64()),
        "i32_required": pa.array([i * 3 - 100 for i in range(n)], pa.int32()),
        "i64_monotonic": pa.array([1_600_000_000_000 + i * 1000 for i in range(n)], pa.int64()),
    }, schema=pa.schema([
        pa.field("i32", pa.int32()), pa.field("i64", pa.int64()),
        pa.field("i32_required", pa.int32(), nullable=False),
        pa.field("i64_monotonic", pa.int64(), nullable=False),
    ])), column_encoding="DELTA_BINARY_PACKED", **common)

    write("enc_delta_length_byte_array", pa.table({
        "s": pa.array(strings, pa.string()), "b": pa.array(binaries, pa.binary()),
    }), column_encoding="DELTA_LENGTH_BYTE_ARRAY", **common)

    write("enc_delta_byte_array", pa.table({
        "s": pa.array(strings, pa.string()), "b": pa.array(binaries, pa.binary()),
        "flba": pa.array(flba, pa.binary(4)),
    }), column_encoding="DELTA_BYTE_ARRAY", **common)

    write("enc_byte_stream_split", pa.table({
        "f32": pa.array(floats, pa.float32()), "f64": pa.array(floats, pa.float64()),
        "i32": pa.array(ints32, pa.int32()), "i64": pa.array(ints64, pa.int64()),
        "flba": pa.array(flba, pa.binary(4)),
        "f16": pa.array(np.array([np.nan if v is None else v for v in floats], dtype=np.float16),
                        pa.float16()),
    }), column_encoding="BYTE_STREAM_SPLIT", **common)

    # The same encodings with data page v2 and compression
    write("enc_delta_mixed_v2_zstd", pa.table({
        "i64": pa.array(ints64, pa.int64()),
        "s_dlba": pa.array(strings, pa.string()),
        "s_dba": pa.array(strings, pa.string()),
        "f64": pa.array(floats, pa.float64()),
    }), column_encoding={"i64": "DELTA_BINARY_PACKED", "s_dlba": "DELTA_LENGTH_BYTE_ARRAY",
                         "s_dba": "DELTA_BYTE_ARRAY", "f64": "BYTE_STREAM_SPLIT"},
        use_dictionary=False, compression="zstd", data_page_version="2.0")


def logical_types():
    utc = dt.timezone.utc
    ts_values = [
        dt.datetime(1970, 1, 1, 0, 0, 0),
        dt.datetime(2024, 2, 29, 23, 59, 59, 999999),
        dt.datetime(1969, 12, 31, 23, 59, 59, 500000),
        dt.datetime(1900, 1, 1, 12, 0, 0),
        None,
        dt.datetime(2262, 4, 11, 0, 0, 0),
    ]
    ts_ns = pa.array([0, 1_709_251_199_123_456_789, -1, -2_208_945_600_000_000_000, None,
                      9_223_286_400_000_000_000], pa.int64())
    temporal = pa.table({
        "date": pa.array([dt.date(1970, 1, 1), dt.date(2024, 2, 29), dt.date(1969, 12, 31),
                          dt.date(1, 1, 1), None, dt.date(9999, 12, 31)], pa.date32()),
        "time_ms": pa.array([0, 1, 86_399_999, 43_200_000, None, 3_723_004], pa.time32("ms")),
        "time_us": pa.array([0, 1, 86_399_999_999, 43_200_000_000, None, 3_723_004_005],
                            pa.time64("us")),
        "time_ns": pa.array([0, 1, 86_399_999_999_999, 43_200_000_000_000, None, 3_723_004_005_006],
                            pa.time64("ns")),
        "ts_ms": pa.array(ts_values, pa.timestamp("ms")),
        "ts_us": pa.array(ts_values, pa.timestamp("us")),
        "ts_ns": ts_ns.cast(pa.timestamp("ns")),
        "ts_ms_utc": pa.array([v and v.replace(tzinfo=utc) for v in ts_values], pa.timestamp("ms", tz="UTC")),
        "ts_us_utc": pa.array([v and v.replace(tzinfo=utc) for v in ts_values], pa.timestamp("us", tz="UTC")),
        "ts_ns_utc": ts_ns.cast(pa.timestamp("ns", tz="UTC")),
        "ts_us_tz_ny": pa.array([v and v.replace(tzinfo=utc) for v in ts_values],
                                pa.timestamp("us", tz="America/New_York")),
    })
    write("logical_temporal", temporal)
    # Same data without the ARROW:schema key-value metadata (pure Parquet logical types)
    write("logical_temporal_no_arrow_schema", temporal, store_schema=False)
    # Legacy INT96 timestamps
    write("timestamp_int96", pa.table({"ts": pa.array(ts_values, pa.timestamp("us"))}),
          use_deprecated_int96_timestamps=True)

    def decs(vals, prec, scale, typ=pa.decimal128):
        return pa.array([None if v is None else Decimal(v) for v in vals], typ(prec, scale))

    decimals = pa.table({
        "d_5_2": decs(["0.00", "1.23", "-1.23", "999.99", None, "-999.99"], 5, 2),
        "d_9_0": decs(["0", "1", "-1", "999999999", None, "-999999999"], 9, 0),
        "d_18_6": decs(["0.000000", "123456789012.345678", "-0.000001", "999999999999.999999", None,
                        "-1.5"], 18, 6),
        "d_38_10": decs(["0E-10", "1234567890123456789012345678.1234567890", "-0.0000000001",
                         "9999999999999999999999999999.9999999999", None, "-42.5"], 38, 10),
        "d_76_20": decs(["0", "12345678901234567890123456789012345678901234567890.12345678901234567890",
                         "-1", "1E-20", None, "-3.14159"], 76, 20, pa.decimal256),
    })
    write("logical_decimal", decimals)
    write("logical_decimal_as_integer", decimals.select(["d_5_2", "d_9_0", "d_18_6"]),
          store_decimal_as_integer=True)

    ints = pa.table({
        "i8": pa.array([0, -128, 127, None, 1], pa.int8()),
        "i16": pa.array([0, -32768, 32767, None, 1], pa.int16()),
        "i32": pa.array([0, -(2**31), 2**31 - 1, None, 1], pa.int32()),
        "i64": pa.array([0, -(2**63), 2**63 - 1, None, 1], pa.int64()),
        "u8": pa.array([0, 0, 255, None, 1], pa.uint8()),
        "u16": pa.array([0, 0, 65535, None, 1], pa.uint16()),
        "u32": pa.array([0, 0, 2**32 - 1, None, 2**31], pa.uint32()),
        "u64": pa.array([0, 0, 2**64 - 1, None, 2**63], pa.uint64()),
    })
    write("logical_integers", ints)
    write("logical_integers_no_arrow_schema", ints, store_schema=False)

    uuids = [uuid.UUID("00000000-0000-0000-0000-000000000000"),
             uuid.UUID("123e4567-e89b-12d3-a456-426614174000"),
             None,
             uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff")]
    f16 = np.array([0.0, -0.0, 1.5, np.nan, 65504.0, -np.inf, 6.1e-05, 0.333], dtype=np.float16)
    misc = pa.table({
        "uuid": pa.array([u.bytes if u else None for u in uuids] * 2, pa.uuid()),
        "fsb3": pa.array([b"abc", b"\x00\x01\x02", None, b"\xff\xfe\xfd"] * 2, pa.binary(3)),
        "f16": pa.array(f16, pa.float16()),
        "json": pa.array(['{"a":1}', "[1,2,3]", None, '"str"', "null", "{}", "true", "1.5"],
                         pa.json_(pa.string())),
        "large_string": pa.array(["", "large", None, "ünicöde", "x" * 100, "a", "b", "c"],
                                 pa.large_string()),
        "binary": pa.array([b"", b"\x00", None, b"\xde\xad\xbe\xef", b"abc", b"\n", b"\x7f", b"z"],
                           pa.binary()),
        "large_binary": pa.array([b"", b"\x00", None, b"\xde\xad\xbe\xef", b"abc", b"\n", b"\x7f", b"z"],
                                 pa.large_binary()),
        "f32": pa.array([0.1, -0.0, float("nan"), float("inf"), float("-inf"), 1e-40, 3.4e38, None],
                        pa.float32()),
        "f64": pa.array([0.1, -0.0, float("nan"), float("inf"), float("-inf"), 5e-324, 1e16, None],
                        pa.float64()),
    })
    write("logical_misc", misc)
    write("logical_misc_no_arrow_schema", misc, store_schema=False)


def nested():
    write("nested_list_int_nulls", pa.table({
        # null list, empty list, list with null element, mixed
        "l": pa.array([None, [], [None], [1, None, 2], [3], None, [None, None], [4, 5, 6]],
                      pa.list_(pa.int32())),
        "l_required_elems": pa.array([None, [], [1], [2, 3], [], None, [4], [5, 6, 7]],
                                     pa.list_(pa.field("element", pa.int32(), nullable=False))),
    }))

    write("nested_list_list_string", pa.table({
        "ll": pa.array([
            None, [], [None], [[]], [[None]], [["a", None, "b"], None, [], ["c"]],
            [["x"]], [["long string value", ""], ["☃"]],
        ], pa.list_(pa.list_(pa.string()))),
    }))

    inner = pa.struct([pa.field("c", pa.string())])
    st = pa.struct([pa.field("a", pa.int32()), pa.field("b", pa.list_(inner))])
    write("nested_struct_list_struct", pa.table({
        "s": pa.array([
            None,
            {"a": None, "b": None},
            {"a": 1, "b": []},
            {"a": 2, "b": [None]},
            {"a": 3, "b": [{"c": None}]},
            {"a": 4, "b": [{"c": "x"}, None, {"c": "y"}]},
        ], st),
        "id": pa.array(range(6), pa.int32()),
    }))

    write("nested_map_string_int", pa.table({
        "m": pa.array([
            None, [], [("a", 1)], [("a", None), ("b", 2)], [("x", 10), ("y", None), ("z", 30)], None,
        ], pa.map_(pa.string(), pa.int32())),
    }))

    write("nested_empty_vs_null_lists", pa.table({
        "l": pa.array([[], None, [], None, [1], []], pa.list_(pa.int64())),
        "ls": pa.array([None, [], [""], [None], [], None], pa.list_(pa.string())),
    }))

    # Legacy (non-compliant) list naming: repeated group "list" with field "item"
    write("nested_list_noncompliant", pa.table({
        "l": pa.array([None, [], [1, None], [2]], pa.list_(pa.int32())),
    }), use_compliant_nested_type=False)

    # Deeply nested mix, with data page v2
    deep_t = pa.struct([
        pa.field("m", pa.map_(pa.string(), pa.list_(pa.int16()))),
        pa.field("s", pa.struct([pa.field("x", pa.float64()), pa.field("y", pa.list_(pa.bool_()))])),
    ])
    write("nested_deep_v2", pa.table({
        "d": pa.array([
            None,
            {"m": None, "s": None},
            {"m": [("k", None), ("j", []), ("i", [1, None, 3])], "s": {"x": None, "y": None}},
            {"m": [], "s": {"x": 1.5, "y": [True, None, False]}},
        ], deep_t),
    }), data_page_version="2.0")


def structure():
    n = 55
    t = pa.table({
        "id": pa.array(range(n), pa.int32()),
        "s": pa.array(["row-%d" % i if i % 4 else None for i in range(n)]),
        "l": pa.array([[i] * (i % 3) if i % 5 else None for i in range(n)], pa.list_(pa.int32())),
    })
    write("multiple_row_groups", t, row_group_size=10)

    schema = pa.schema([
        pa.field("i", pa.int64()), pa.field("s", pa.string()),
        pa.field("l", pa.list_(pa.int32())),
        pa.field("st", pa.struct([pa.field("a", pa.int32())])),
        pa.field("m", pa.map_(pa.string(), pa.int32())),
    ])
    write("zero_rows", schema.empty_table())

    n = 20
    write("all_null_columns", pa.table({
        "id": pa.array(range(n), pa.int32()),
        "null_int": pa.array([None] * n, pa.int32()),
        "null_string": pa.array([None] * n, pa.string()),
        "null_double": pa.array([None] * n, pa.float64()),
        "null_list": pa.array([None] * n, pa.list_(pa.int32())),
        "null_struct": pa.array([None] * n, pa.struct([pa.field("a", pa.int32())])),
        "null_type": pa.nulls(n),
    }))
    write("all_null_columns_no_dict_v2", pa.table({
        "null_int": pa.array([None] * n, pa.int64()),
        "null_string": pa.array([None] * n, pa.string()),
    }), use_dictionary=False, data_page_version="2.0")

    # Required (non-nullable) columns -> max_definition_level 0
    write("required_columns", pa.table({
        "a": pa.array(range(10), pa.int32()),
        "b": pa.array(["v%d" % i for i in range(10)]),
    }, schema=pa.schema([pa.field("a", pa.int32(), nullable=False),
                         pa.field("b", pa.string(), nullable=False)])))

    # Parquet format version 1.0 (converted types only / no newer logical types)
    write("format_version_1_0", base_table(20).append_column(
        "ts", pa.array([dt.datetime(2020, 1, 1) + dt.timedelta(seconds=i) for i in range(20)],
                       pa.timestamp("ms"))), version="1.0")


def bloom_filters():
    """Bloom filters written by Arrow C++ for most physical types, in two row groups."""
    n = 200
    t = pa.table({
        "i32": pa.array([None if i % 17 == 0 else i * 3 - 100 for i in range(n)], pa.int32()),
        "i64": pa.array([i * 1_000_003 - 5_000_000_000 for i in range(n)], pa.int64()),
        "f32": pa.array([i * 0.5 - 7 for i in range(n)], pa.float32()),
        "f64": pa.array([i * 1.25 - 50 for i in range(n)], pa.float64()),
        "str": pa.array(["str-%d" % i for i in range(n)], pa.string()),
        "bin": pa.array([bytes([i % 256, 0, 255]) + b"bin" for i in range(n)], pa.binary()),
        "fixed": pa.array([uuid.UUID(int=i * 7919 + 1).bytes for i in range(n)], pa.binary(16)),
        "date": pa.array([dt.date(2020, 1, 1) + dt.timedelta(days=i) for i in range(n)], pa.date32()),
        "ts": pa.array([dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=i * 61)
                        for i in range(n)], pa.timestamp("us", tz="UTC")),
        "dec_small": pa.array([Decimal(i * 101) / 100 for i in range(n)], pa.decimal128(9, 2)),
        "dec_big": pa.array([Decimal(i * 1234567) / 1000 for i in range(n)], pa.decimal128(30, 3)),
        "dict_str": pa.array(["cat-%d" % (i % 10) for i in range(n)], pa.string()),
    })
    options = {name: {"ndv": 100, "fpp": 0.01} for name in t.column_names}
    write("bloom_filters_arrow", t, row_group_size=100, bloom_filter_options=options,
          use_dictionary=["dict_str"], store_decimal_as_integer=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        if name.endswith(".parquet"):
            os.remove(os.path.join(OUT, name))
    codecs()
    page_versions()
    dictionary()
    encodings()
    logical_types()
    nested()
    structure()
    bloom_filters()
    generate_expectations.main([OUT])


if __name__ == "__main__":
    main()
