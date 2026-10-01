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
