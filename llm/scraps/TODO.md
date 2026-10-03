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

Done (see llm/outputs/encryption.md). Left:

- `herringbone inspect` flags for keys (`--footer-key=HEX`, `--column-key=path:HEX`,
  `--aad-prefix=`); the Inspector API already takes `decryption:`
- Copying encrypted chunks in a redaction without re-encoding them: decrypt and re-encrypt each
  module with the new AAD instead of decoding the values
- Reading the key tools format (PKMT1 key material, wrapped data keys) behind a KMS client
  interface, if someone asks for it
