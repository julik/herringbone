# Parquet modular encryption: API design

Reading and writing files encrypted per the Parquet modular encryption spec
(https://github.com/apache/parquet-format/blob/master/Encryption.md), with OpenSSL from the
standard library and no new gem.

## Goals and non-goals

- Read files written by parquet-mr, Arrow C++ / pyarrow and parquet-rs: both algorithms
  (`AES_GCM_V1`, `AES_GCM_CTR_V1`), both footer modes, footer and per-column keys, AAD prefixes
  stored or supplied, 128/192/256-bit keys.
- Write the same. Defaults follow parquet-mr and Arrow: `AES_GCM_V1`, encrypted footer.
- Everything the reader does with plaintext files keeps working on encrypted ones: projections,
  `where:` pushdown (statistics, page index, bloom filters), `from:`, `as: :numo`.
- Redaction of encrypted files, keeping the output encrypted.
- Keys are raw bytes handed in by the caller. Herringbone stores and returns the opaque
  `key_metadata`; turning it into a key (a KMS call, unwrapping a data key) is the caller's job.
  The parquet-mr "key tools" format (master key ids, wrapped data keys as JSON) is not
  implemented, but can be built on top with the `keys:` resolver below (the pyarrow interop test
  does exactly that).
- Not covered: crypto-shredding of single users (keys are per column and per file, see
  `llm/plans/redaction.md`), external key material files.

## Writing

`Writer.new` / `Writer.open` / `Herringbone.write` / `SimpleWriter` take `encryption:`:

```ruby
Herringbone::Writer.open(io, schema, encryption: {
  footer_key: FOOTER_KEY,                     # 16, 24 or 32 bytes, required
  footer_key_metadata: "kf",                  # optional, stored in the file as is
  columns: {                                  # optional; leave out to encrypt every column
    "ssn" => SSN_KEY,                         #   with its own key
    "address" => {key: ADDR_KEY, key_metadata: "kc2"},  # a struct: all its leaf columns
    "email" => :footer                        #   with the footer key
  },
  plaintext_footer: false,                    # true: legacy readers can read the other columns
  algorithm: :aes_gcm,                        # or :aes_gcm_ctr (pages without authentication)
  aad_prefix: "orders/2026-10-03/part-0",     # optional file identity, checked by readers
  store_aad_prefix: true                      # false: readers must supply aad_prefix
}) { |w| rows.each { |r| w << r } }
```

- `columns:` keys are dotted column paths or field names; a field name covers all of its leaf
  columns (so `"tags"` covers `tags.list.element`). Columns not listed stay plaintext. Without
  `columns:` every column is encrypted with the footer key ("uniform encryption").
- A column value is a key String, `{key:, key_metadata:}`, or `:footer`.
- Keys are binary Strings; `["00112233..."].pack("H*")` for hex. Wrong sizes, unknown columns and
  unknown options raise `ArgumentError` before anything is written.
- Encrypted columns get their pages, page headers, ColumnIndex, OffsetIndex and bloom filter
  (header and bitset) encrypted. ColumnMetaData is encrypted separately when the column has its
  own key or the footer is plaintext; in plaintext-footer mode the footer keeps a copy without
  statistics, as the spec asks.
- Each module gets a fresh random 12-byte nonce. Each file gets an 8-byte random
  `aad_file_unique`. Encryptions are counted per key and the writer raises after 2^32, per the
  NIST limit the spec quotes.
- Page CRCs are computed over the stored (encrypted) page bytes, like parquet-mr and Arrow.

## Reading

`Reader.new` takes `decryption:`:

```ruby
Herringbone::Reader.new(io, decryption: {
  footer_key: FOOTER_KEY,                     # explicit keys...
  columns: {"ssn" => SSN_KEY},
  keys: ->(key_metadata) { kms.unwrap(key_metadata) },  # ...or a resolver (any #call or a Hash)
  aad_prefix: "orders/2026-10-03/part-0"      # needed when the file does not store it
})
```

- Explicit `footer_key:` / `columns:` win; otherwise `keys:` is called with the key metadata
  stored for the footer or column. It returns the key, or nil when the caller has no access.
  Each distinct key metadata is resolved once per Reader.
- The name `keys:` is free inside the `decryption:` Hash; the top-level `keys:` option
  (`:string` / `:symbol`) stays what it is.
- Encrypted footer (`PARE`) without a footer key raises `Herringbone::DecryptionError`, saying
  which key metadata the footer needs.
- Plaintext footer: the file opens without keys (as for a legacy reader); the footer signature is
  verified whenever the footer key is available. Plaintext columns read as usual.
- Reading (or filtering on) an encrypted column whose key is not available raises
  `DecryptionError` naming the column, so `columns:` selects what the caller can read.
- A wrong key, a tampered module, a footer that fails its signature check or an `aad_prefix` that
  differs from the stored one raise `DecryptionError`. (With `AES_GCM_CTR_V1`, page bodies carry
  no tag, so tampered page data is only detected if it fails to decode.)
- `Reader#encryption` describes the file without needing keys, nil for plaintext files:

  ```ruby
  reader.encryption
  # => {algorithm: :aes_gcm, footer: :encrypted, footer_key_metadata: "kf",
  #     aad_prefix: "...", supply_aad_prefix: false,
  #     columns: {"ssn" => {key: :column, key_metadata: "kc1", readable: true},
  #               "email" => {key: :footer, key_metadata: nil, readable: true}}}
  ```

`DecryptionError < Herringbone::Error` is new. It replaces the `UnsupportedError` that `PARE`
files raised so far.

## Redaction

```ruby
Herringbone.redact(input, output, decryption: {keys: kms}) do |r|
  r.where(user_id: 42).delete
end
```

- `decryption:` opens the input (also for `Redaction#apply` and `#affects?`).
- An encrypted input is written encrypted by default, with the same algorithm, footer mode,
  keys, key metadata, AAD prefix setting and encrypted columns (dropped columns aside), and a
  new `aad_file_unique`. `encryption: {...}` writes with other settings, and `encryption: false`
  writes a plaintext file on purpose. Writing an encrypted input without being able to decrypt
  all of its kept columns raises `DecryptionError`.
- Byte-for-byte copying stays for chunks that are plaintext in both files. A chunk that is
  encrypted in the input or the output is re-encoded, since its AAD (file id, row group and
  column ordinals) changes; copying ciphertext would only work if the output reused the input's
  file id and every row group and column kept its ordinal.

## Inspector and CLI

- `Inspector.new(io, decryption: nil)`. Plaintext-footer files open without keys; encrypted
  chunks whose key is missing are shown as encrypted, with their size but without pages,
  indexes or bloom filters. With keys, everything is shown, decrypted.
- `Inspector#to_h` / `#report` get an `encryption` section (the same Hash as `Reader#encryption`).
- `PARE` files without a footer key raise `DecryptionError` from `Inspector.new`, naming the
  algorithm and footer key metadata; `herringbone inspect` prints that message.
- CLI key flags (`--footer-key=HEX`, `--column-key=path:HEX`) are left for later.

## Implementation outline

- `lib/herringbone/encryption.rb`: `Encryption` module with
  - AES-GCM / AES-CTR module encryption and decryption on top of `OpenSSL::Cipher`, ciphers
    reused per key;
  - module type constants and AAD building (prefix + file unique + type + LE16 row group,
    column and page ordinals);
  - `FileEncryptor` (validates the `encryption:` option, per-column settings, invocation
    counters) and `FileDecryptor` (footer decryption, signature check, column metadata
    decryption, key resolution and caching), each handing out a per-chunk object that knows its
    key, algorithm and AAD.
- `Format`: `AesGcmV1`, `AesGcmCtrV1`, `EncryptionAlgorithm`, `EncryptionWithFooterKey`,
  `EncryptionWithColumnKey`, `ColumnCryptoMetaData`, `FileCryptoMetaData`;
  `ColumnChunk.crypto_metadata` (8), `FileMetaData.encryption_algorithm` (8) and
  `footer_signing_key_metadata` (9).
- Reader: the footer is decrypted, and decryptable `encrypted_column_metadata` replaces
  `meta_data` on load, so pushdown, numo and redaction see plain metadata.
  `ColumnChunkReader` decrypts page headers (dictionary header when at the dictionary offset,
  data page headers with the data page ordinal, also after an OffsetIndex jump) and bodies;
  page indexes and bloom filters are decrypted where they are read.
- Writer: page headers and bodies, page indexes and bloom filters are encrypted as they are
  written; column metadata at `#close` (bloom filter offsets are filled in after the chunk);
  the footer is encrypted or signed.
- Fixtures: the `*.parquet.encrypted` files from apache/parquet-testing (`data/` and
  `data/aes256/`, Arrow C++ and parquet-mr) with the keys from its README; round trips through
  pyarrow with a test-only KMS client in both directions.

## Status

Implemented as designed, with two refinements found while building it:

- `Reader#bloom_filter` raises `DecryptionError` for an encrypted column without its key, rather
  than answering nil: with an encrypted footer it cannot even tell whether there is a filter.
- A redaction counts a row group whose encrypted chunks were re-encoded, but whose values no
  statement changed, as `copied` in the report.

Verified against:

- the 12 encrypted files of apache/parquet-testing: Arrow C++ (`data/`, 128-bit keys) and
  parquet-mr (`data/aes256/`), covering GCM and GCM-CTR, encrypted and plaintext footers (signature
  checked), uniform and per-column keys, AAD prefix stored and supplied, bloom filters and page
  indexes used for `where:`;
- pyarrow 25 both ways (`test/encryption_interop_test.rb`), pyarrow reading with page checksum
  verification on;
- the CRCs of parquet-mr's encrypted pages, which match when computed over the encrypted bytes,
  as Herringbone writes them.

Writing and reading 300k rows (int64, string, double) takes the same time with and without
encryption (1.4 s / 0.3 s on an M-series Mac): pages are encrypted whole, with AES-NI.

## Follow-up: configuration objects, CLI keys, a simple default

- `EncryptionConfiguration` / `DecryptionConfiguration` hold and check the `encryption:` /
  `decryption:` settings; Hashes are converted with `.from`, so validation happens in one place,
  before a schema is known (column names are checked by the Writer). Both are frozen and keep
  keys out of `#inspect`.
- A `keys:` callable with two parameters also gets what the key is for (`:footer` or a column
  path), and is called for keys without key metadata. The CLI uses that to prompt.
- `herringbone inspect` / `cat`: `--footer-key`, `--column-key=PATH=KEY`, `--key=METADATA=KEY`,
  `--aad-prefix`, keys in hex, `base64:` or `raw:`; missing keys are asked for on stdin (no echo
  on a terminal), `--no-prompt` turns that off.

### `EncryptionConfiguration.simple(key, key_metadata: nil)`

Uniform encryption with the footer key, AES_GCM_V1, encrypted footer, no AAD prefix, 128 or
256-bit keys. Chosen from a survey of readers (late 2026):

- pyarrow 25 added `create_decryption_properties(footer_key)`, uniform only. Verified here: it
  reads `simple` files, and Herringbone reads what `create_encryption_properties(key)` writes.
- arrow-rs/DataFusion: no CTR, no 192-bit keys. Not verified (the PyPI DataFusion wheel lacks
  the encryption feature).
- DuckDB 1.5: encrypted footer, uniform, GCM, no AAD prefix only. Verified with 1.5.6: it reads
  spec files only when every column chunk has a single data page and no bloom filter (fails the
  same way on pyarrow-written files), and writes files without AADs or column crypto metadata.
- Spark/parquet-java: key tools JSON out of the box, or a custom DecryptionPropertiesFactory for
  plain keys; Trino 478+ reads with keys from environment variables.

A key tools (PKMT1) mode that wraps the key under itself, so Spark could read with InMemoryKMS,
was considered and left out: it is a key-dependent-message construction and InMemoryKMS ships in
a tests jar that says not to use it in production.
