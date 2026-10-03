#!/usr/bin/env python3
"""
Reads and writes encrypted Parquet files with pyarrow, for test/encryption_interop_test.rb.

pyarrow only exposes the key tools layer of Parquet modular encryption: the key metadata in the
file is JSON (PKMT1) holding data keys wrapped by a KMS. The test KMS here wraps a key by
base64-encoding it, so the Ruby side can build and read the same key metadata with known keys.

Usage:
  pyarrow_encryption.py --check
  pyarrow_encryption.py write PATH OPTIONS_JSON   writes the test table, prints its rows as JSON
  pyarrow_encryption.py read PATH                 prints the rows of PATH as JSON

OPTIONS_JSON: {"columns": {"kc1": ["ssn"]}, "plaintext_footer": false, "algorithm": "AES_GCM_V1"}
"""

import base64
import datetime as dt
import json
import sys

import pyarrow as pa
import pyarrow.parquet as pq
import pyarrow.parquet.encryption as pe


class Base64Kms(pe.KmsClient):
    """Wraps a data key by base64-encoding it; only for tests."""

    def __init__(self, config):
        pe.KmsClient.__init__(self)

    def wrap_key(self, key_bytes, master_key_identifier):
        return base64.b64encode(key_bytes).decode()

    def unwrap_key(self, wrapped_key, master_key_identifier):
        return base64.b64decode(wrapped_key)


def factory():
    return pe.CryptoFactory(lambda config: Base64Kms(config))


def kms_config():
    return pe.KmsConnectionConfig()


def table():
    n = 2500
    return pa.table({
        "id": pa.array(range(n), pa.int64()),
        "ssn": pa.array([None if i % 11 == 0 else "ssn-%04d" % (i % 300) for i in range(n)], pa.string()),
        "score": pa.array([i * 0.5 for i in range(n)], pa.float64()),
        "tags": pa.array([["t%d" % (i % 3)] * (i % 3) for i in range(n)], pa.list_(pa.string())),
        "at": pa.array([dt.datetime(2026, 1, 1) + dt.timedelta(seconds=i) for i in range(n)], pa.timestamp("us", tz="UTC")),
    })


def rows(t):
    out = []
    for row in t.to_pylist():
        row = {k: (v.isoformat() if isinstance(v, dt.datetime) else v) for k, v in row.items()}
        out.append(row)
    return out


def main():
    if sys.argv[1] == "--check":
        return
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "write":
        opts = json.loads(sys.argv[3])
        config = pe.EncryptionConfiguration(
            footer_key="kf",
            column_keys=opts.get("columns", {}),
            uniform_encryption=opts.get("uniform", False),
            plaintext_footer=opts.get("plaintext_footer", False),
            encryption_algorithm=opts.get("algorithm", "AES_GCM_V1"),
            double_wrapping=False,
            data_key_length_bits=opts.get("key_bits", 128),
        )
        props = factory().file_encryption_properties(kms_config(), config)
        t = table()
        pq.write_table(t, path, encryption_properties=props, row_group_size=1000, data_page_size=4096,
                       write_page_index=True, write_page_checksum=True)
        print(json.dumps(rows(t)))
    else:
        props = factory().file_decryption_properties(kms_config(), pe.DecryptionConfiguration())
        t = pq.read_table(path, decryption_properties=props, page_checksum_verification=True)
        print(json.dumps(rows(t)))


if __name__ == "__main__":
    main()
