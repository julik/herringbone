# Encryption keys: KMS, key tools, and the smallest thing that works

Follow-up to `encryption.md`. Question: should Herringbone ship a "default KMS" for
`EncryptionConfiguration.simple`, so that the key-lookup ceremony other tools have is covered,
without growing a Java-style key management layer?

## What other tools do with keys (findings)

The spec stores an opaque `key_metadata` per key (footer, column) and leaves key management to
the implementation. Two styles exist in the wild:

1. **Explicit keys, or lookup by id.** The reader is given the key bytes, or a callback that maps
   the stored `key_metadata` to key bytes. Arrow C++ (`DecryptionKeyRetriever`,
   `StringKeyIdRetriever`: key_metadata is a UTF-8 key id), arrow-go, arrow-rs
   (`KeyRetriever`), DataFusion (`footer_key_as_hex`), ParquetSharp, Trino 478+ (keys from
   environment variables, optionally `id:key` where id is the raw key_metadata), DuckDB
   (`add_parquet_key`, ignores key_metadata) and pyarrow 25+ (`create_decryption_properties`,
   one key, ignores key_metadata).

2. **Key tools (parquet-java's `PropertiesDrivenCryptoFactory`, pyarrow's `CryptoFactory`).**
   Envelope encryption: every file (and column) gets a random data key (DEK); the DEK is
   "wrapped" (encrypted) by a master key that lives in a KMS; key_metadata is JSON ("PKMT1"):

   ```json
   {"keyMaterialType":"PKMT1","internalStorage":true,"isFooterKey":true,
    "kmsInstanceID":"DEFAULT","kmsInstanceURL":"DEFAULT","masterKeyID":"kf",
    "wrappedDEK":"<base64>","doubleWrapping":false}
   ```

   (with `doubleWrapping: true`, the default, there is a key-encryption key in between). The
   reader instantiates a `KmsClient` class named in Hadoop configuration, which unwraps
   `wrappedDEK` given `masterKeyID`. This is the only thing Spark/Hive read out of the box.
   Wrapping can be remote (the KMS does it) or local (`LocalWrapKmsClient`: the master key is
   fetched and the DEK is AES-GCM encrypted with it, AAD = the master key id, stored as
   `base64(nonce12 || ciphertext || tag16)` — `KeyToolkit.encryptKeyLocally`).

   The only built-in KmsClient is `InMemoryKMS`, from parquet-hadoop's *tests* jar ("a mock
   class, built for testing only"), which takes master keys as `id:base64key` in
   `parquet.encryption.key.list` and wraps locally.

Verified here (see `encryption.md` for the rest): pyarrow 25.0.1 reads Herringbone files with
just the key, and its KMS-based API reads Herringbone files carrying PKMT1 key metadata written
with a fake base64 "KMS". DuckDB 1.5.6 can't read multi-page or bloom-filtered encrypted chunks
from anyone, and writes files without AADs.

## What envelope encryption buys, and what it costs

Buys:

- A fresh key per file, so the 2^32 AES-GCM invocations per key never come close, and a
  leaked data key exposes one file.
- Master key rotation without re-encrypting data (re-wrapping DEKs means rewriting footers,
  which nobody does in practice; Iceberg keeps wrapped keys in its manifests for this reason).
- Spark/Hive reading without custom code, *if* they run a KmsClient for the same KMS.

Costs:

- Every single-key reader (pyarrow's simple API, DuckDB, Trino's env keys, DataFusion's hex
  key) can't read the file: they need the DEK, which only the KMS can unwrap.
- For Spark to read it "out of the box" the wrapping has to match their KmsClient: remote
  wrapping by their KMS (Vault transit, AWS KMS...), or local wrapping with the InMemoryKMS
  format, which is a test mock. Either way Herringbone would need a wrap/unwrap plug-in point,
  JSON key material, KEKs for double wrapping, and a cache: the Java key tools, ported.
- Wrapping the master key under itself to make one key work everywhere (suggested by the
  survey) is a key-dependent-message construction; not doing that.

The 90% user has a key (or a few, rotated) in an env var, a secrets manager or Rails
credentials, and wants files they and their colleagues can open in pyarrow, DuckDB or Spark with
that key. A per-file DEK protects them from nothing they worry about.

## What was built: a Key, a keyring, and a block

The smallest thing that still handles lookup and rotation, without a KMS layer:

- `Herringbone::Key` is key bytes plus an id. The id defaults to a fingerprint: the first 8 bytes
  of HMAC-SHA256(key, "herringbone key id") as hex. That is a PRF output under a secret key, so
  it gives nothing away, and it is stable: the same key always gets the same id, so nobody has
  to invent or store ids. `Key.new(bytes, id: "2026-10")` names it instead; `Key.generate`,
  `Key.from_hex` and `#hex` cover making and storing keys.
- Writing: `encryption: key` (a Key, or its hex) is `EncryptionConfiguration.simple(key)`:
  uniform AES_GCM_V1, encrypted footer, no AAD prefix, 128/256 bits; the id goes in the footer's
  key_metadata as plain UTF-8. That is what Arrow's `StringKeyIdRetriever` and Trino's `id:key`
  lists expect, and what `herringbone inspect` shows.
- Reading: `decryption: key` or `decryption: [key, older_key, ...]`, a keyring: keys are looked up
  by the id the file stores, and a lone key is also used as the footer key whatever the file says
  (files from pyarrow and others store no id or their own). Rotation is writing with a new key
  and reading with all of them.
- Where a String stands for a key (`encryption:`, `decryption:`, `SimpleWriter#encrypt!(key:)`)
  it must be 32/48/64 hex digits. Raw bytes are refused with a message pointing at `Key#hex` and
  `Key.new(bytes)`: a binary String is easy to mangle (encodings, chomping, copy and paste) and
  a 32-character text key would be ambiguous with 16 bytes of hex, so there is one String form.
- The "KMS": `decryption: ->(key_id) { ... }` returning a Key or bytes, for keys that live in
  credentials, Vault and the like. A two-parameter block also learns what the key is for.
- CLI: `--key=HEX` (a keyring entry, matched by fingerprint), `--key=ID=HEX`, or the prompt,
  which names the id it wants.
- Anywhere the full configuration takes a key (footer, columns), a Key works too and brings its
  id as the key metadata.

What is *not* in it: KMS client classes, JSON key material, wrapping, caching policies, key
versions. If someone needs Spark-without-custom-code, the extension point would be a
`wrap:`/`unwrap:` pair of blocks writing PKMT1 JSON, built when asked for (the interop test
already shows the JSON shape round-trips through pyarrow's CryptoFactory).
