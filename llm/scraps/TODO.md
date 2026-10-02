# TODO

Priorities: writing over reading, native Ruby types, ergonomics over a few % of speed.

## Reading into Numo

- `timestamps: :integer` / `dates: :integer` options
- Dictionary-encoded strings as Int32 codes plus categories
- A fast path for list leaves (2-D without assembling Ruby Arrays)

## Inspector

- Compare the OffsetIndex page sizes/first rows with the page headers, the same way page header
  statistics are compared with the ColumnIndex (tests do, the inspector doesn't report it)
- Reuse `Format::BloomFilterHeader` instead of the Inspector's own partial `BloomFilterHeader`

## Pushdown

- `where:` on list/map elements
- OR conditions in `where:`

## Modular encryption

Read and write files encrypted per the Parquet modular encryption spec
(https://github.com/apache/parquet-format/blob/master/Encryption.md, also at
https://parquet.apache.org/docs/file-format/data-pages/encryption/). Today the reader and
inspector raise `UnsupportedError` on the `PARE` magic, and a plaintext-footer file with encrypted
columns would fail on its first encrypted page.

- Algorithms: `AES_GCM_V1` (every module AES-GCM: 4-byte length, 12-byte nonce, ciphertext,
  16-byte tag) and `AES_GCM_CTR_V1` (metadata GCM, pages CTR without a tag). 128/192/256-bit keys.
  OpenSSL (stdlib) has both; no new gem. Fresh random nonce per module, at most 2^32 per key.
- Modules, each encrypted on its own: data and dictionary pages, their page headers, ColumnIndex,
  OffsetIndex, bloom filter header and bitset, ColumnMetaData (when the column has its own key),
  the footer.
- AAD = optional caller prefix (file identity, stored or supplied by the reader) + `aad_file_unique`
  + 1-byte module type (footer 0, ColumnMetaData 1, data page 2, dictionary page 3, data page
  header 4, dictionary page header 5, ColumnIndex 6, OffsetIndex 7, bloom header 8, bloom bitset 9)
  + 2-byte LE row group ordinal + column ordinal (+ page ordinal for pages). The writer already
  sets `RowGroup.ordinal`.
- Footer modes: encrypted footer (`PARE` magic both ends; `FileCryptoMetaData` in the clear before
  the encrypted `FileMetaData`, hides schema and row counts) and plaintext footer (`PAR1`, footer
  readable, statistics of encrypted columns stripped, footer signed with a 28-byte nonce+tag before
  the length).
- Thrift: `FileCryptoMetaData`, `EncryptionAlgorithm` union (`AesGcmV1`/`AesGcmCtrV1` with
  `aad_prefix`, `aad_file_unique`, `supply_aad_prefix`), `ColumnCryptoMetaData` union
  (`ENCRYPTION_WITH_FOOTER_KEY` / `ENCRYPTION_WITH_COLUMN_KEY` with `path_in_schema`,
  `key_metadata`), `ColumnChunk.crypto_metadata` + `encrypted_column_metadata` (field 9 is already
  declared), `FileMetaData.encryption_algorithm` + `footer_signing_key_metadata`.
- Keys: the file stores only opaque `key_metadata` per footer/column. API sketch: `Reader.new(io,
  keys: { footer: "...", "ssn" => "..." })` or `keys: ->(key_metadata) { ... }` (a KMS lookup);
  `Writer.new(io, schema, encrypt: { footer: key, columns: { "ssn" => key }, plaintext_footer:
  false, aad_prefix: "..." })`. Envelope encryption / the PME key tools format (master key ids,
  wrapped data keys) can be a layer on top, not in the core.
- Reader must verify GCM tags against the right AAD, check the footer signature in plaintext mode,
  and read `encrypted_column_metadata` with the column key. Page index pushdown and bloom filters
  need the column key too. Inspector: report what is encrypted without needing keys.
- Redaction: copied row groups can be copied as ciphertext only when the AAD does not change
  (same row group ordinal and column ordinal), otherwise re-encrypt; dropped columns shift
  column ordinals, so everything after them is re-encrypted. Per-column keys are per file, not
  per subject, so crypto-shredding one user stays out of scope (see llm/plans/redaction.md).
- Fixtures: apache/parquet-testing has `encrypt_columns_and_footer.parquet.encrypted` and friends
  (keys in its README) for interop; also round-trip against pyarrow's `encryption_properties`.
