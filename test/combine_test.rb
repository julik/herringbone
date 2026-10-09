# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "json"
require "open3"
require "tmpdir"

# Herringbone.combine
class CombineTest < Minitest::Test
  include WriterHelpers

  F = Herringbone::Format

  SCHEMA = Herringbone::Schema.define do |s|
    s.int64 :id, null: false
    s.string :email
    s.struct :address do |a|
      a.string :city
      a.int32 :zip
    end
    s.list :tags, :string
    s.timestamp :at
  end

  KEY = "K" * 16

  def rows(range)
    range.map do |i|
      {"id" => i, "email" => (i % 7).zero? ? nil : "user#{i}@example.com",
       "address" => (i % 5).zero? ? nil : {"city" => "City #{i % 3}", "zip" => 1000 + i},
       "tags" => ["t#{i % 3}"] * (i % 3), "at" => Time.at(1_700_000_000 + i, in: "UTC")}
    end
  end

  def file(range, schema: SCHEMA, **options)
    write_to_string(schema, rows(range), row_group_rows: 100, page_rows: 30, bloom_filters: %w[email], **options)
  end

  def combine(files, **options)
    out = StringIO.new("".b)
    report = Herringbone.combine(files.map { |bytes| StringIO.new(bytes) }, out, **options)
    [out.string, report]
  end

  def pages(bytes, row_group, path)
    chunk = Herringbone::Inspector.new(StringIO.new(bytes)).row_groups[row_group].column(path)
    chunk.pages.map { |p| bytes.byteslice(p.offset, p.total_size) }
  end

  # Every OffsetIndex entry points at a page header of the stated size, and page CRCs hold
  def assert_well_formed(bytes, msg = nil)
    reader_for(bytes).row_groups.each do |rg|
      rg.columns.each do |c|
        next unless c.offset_index_offset
        F::OffsetIndex.decode(bytes, c.offset_index_offset).first.page_locations.each do |loc|
          header, body = F::PageHeader.decode(bytes, loc.offset)
          assert_equal loc.compressed_page_size, body - loc.offset + header.compressed_page_size, msg
        end
      end
    end
    assert_equal 0, Herringbone::Inspector.new(StringIO.new(bytes)).verify_checksums[:mismatch], msg
  end

  # --- Herringbone.combine ---

  def test_combine_copies_every_row_group
    a = file(0...250)
    b = file(250...400)
    out, report = combine([a, b])
    assert_equal 400, report.rows
    assert_equal({copied: 5, rewritten: 0}, report.row_groups)
    assert_well_formed out
    assert_roundtrip SCHEMA, rows(0...400), out
    assert_equal pages(a, 1, "address.zip"), pages(out, 1, "address.zip")
    assert_equal pages(b, 1, "tags.list.element"), pages(out, 4, "tags.list.element")
    reader = reader_for(out)
    assert_equal [100, 100, 50, 100, 50], reader.row_groups.map(&:num_rows)
    assert_equal rows([300, 314]).map { |r| r["email"] }, reader.read(where: {email: %w[user300@example.com user314@example.com]}).map { |r| r["email"] }
    assert reader.row_groups.all? { |rg| rg.columns[1].meta_data.bloom_filter_offset }, "bloom filters come along"
    assert reader.bloom_filter(4, "email").might_contain?("user351@example.com")
    assert_equal rows(380...390), reader.read(from: 380, limit: 10), "page indexes are rebased"
  end

  def test_combine_one_file_and_empty_files
    a = file(0...120)
    out, = combine([a])
    assert_equal reader_for(a).read, reader_for(out).read
    empty = write_to_string(SCHEMA, [])
    out, report = combine([empty, a, empty])
    assert_equal 120, report.rows
    assert_equal 2, reader_for(out).row_groups.size
  end

  def test_combine_keeps_metadata_and_sorting_columns
    a = file(0...100, metadata: {"source" => "a"})
    b = file(100...200, metadata: {"source" => "b"})
    out, = combine([a, b])
    assert_equal({"source" => "a"}, reader_for(out).metadata)
    out, = combine([a, b], metadata: {"source" => "both"})
    assert_equal({"source" => "both"}, reader_for(out).metadata)

    footer_len = b.byteslice(-8, 4).unpack1("V")
    meta = F::FileMetaData.decode(b.byteslice(-8 - footer_len, footer_len)).first
    meta.row_groups.each { |rg| rg.sorting_columns = [F::SortingColumn.new(column_idx: 0, descending: false, nulls_first: false)] }
    footer = meta.encode
    sorted = b.byteslice(0, b.bytesize - 8 - footer_len) + footer + [footer.bytesize].pack("V") + "PAR1"
    out, = combine([a, sorted])
    assert_equal [nil, [0]], reader_for(out).row_groups.map { |rg| rg.sorting_columns&.map(&:column_idx) }
  end

  def test_combine_refuses_different_schemas
    other = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.string :email
      s.struct(:address) { |a|
        a.string :city
        a.string :zip
      }
      s.list :tags, :string
      s.timestamp :at
    end
    b = write_to_string(other, [{"id" => 1, "address" => {"zip" => "1234"}}])
    error = assert_raises(ArgumentError) { combine([file(0...10), file(10...20), b]) }
    assert_match "The schema of input 2 differs from that of input 0 in address.", error.message
    assert_match "schema:", error.message
  end

  def test_combine_with_a_union_schema_fills_gaps_with_nulls
    narrow = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.string :phone, null: false
    end
    phones = [{"id" => 1000, "phone" => "555-1"}, {"id" => 1001, "phone" => "555-2"}]
    a = file(0...150, metadata: {"ARROW:schema" => "stale", "source" => "a"})
    b = write_to_string(narrow, phones)
    schema = reader_for(a).schema + reader_for(b).schema
    out, report = combine([a, b], schema: schema)
    assert_equal({copied: 0, rewritten: 3}, report.row_groups, "the widened id column is encoded again")
    assert_well_formed out
    assert_equal schema, reader_for(out).schema
    expected = rows(0...150).map { |r| r.merge("phone" => nil) } +
      phones.map { |r| {"email" => nil, "address" => nil, "tags" => nil, "at" => nil}.merge(r) }
    assert_roundtrip schema, expected, out
    assert_equal({"source" => "a"}, reader_for(out).metadata, "metadata describing the columns goes")
    assert_equal pages(a, 0, "email"), pages(out, 0, "email"), "unchanged columns are still copied"
  end

  def test_combine_with_a_schema_that_does_not_fit
    a = file(0...10)
    narrow = Herringbone::Schema.define { |s| s.int64 :id, null: false }
    error = assert_raises(ArgumentError) { combine([a], schema: narrow) }
    assert_equal "Input 0 has the field email, which is not in the schema", error.message
    wide = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.string :email
      s.struct(:address) { |x|
        x.string :city
        x.int32 :zip
      }
      s.list :tags, :string
      s.timestamp :at
      s.int32 :x, null: false
    end
    error = assert_raises(ArgumentError) { combine([a], schema: wide) }
    assert_equal "Input 0 lacks x, which the schema requires", error.message
    narrowed = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.string :email, null: false
      s.struct(:address) { |x|
        x.string :city
        x.int32 :zip
      }
      s.list :tags, :string
      s.timestamp :at
    end
    error = assert_raises(ArgumentError) { combine([a], schema: narrowed) }
    assert_equal "Input 0 does not fit the schema: email is nullable in the input and required in the schema", error.message
  end

  def test_combine_refuses_schemas_that_only_differ_in_order
    swapped = Herringbone::Schema.define do |s|
      s.string :email
      s.int64 :id, null: false
    end
    plain = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.string :email
    end
    a = write_to_string(plain, [{"id" => 1}])
    b = write_to_string(swapped, [{"id" => 2}])
    error = assert_raises(ArgumentError) { combine([a, b]) }
    assert_match "differs from that of input 0 in the order of the fields", error.message
    out, report = combine([a, b], schema: plain)
    assert_equal({copied: 2, rewritten: 0}, report.row_groups, "fields are matched by name, wherever they are")
    assert_equal [1, 2], reader_for(out).read.map { |r| r["id"] }
  end

  def test_combine_with_a_union_schema_widens_types
    narrow = Herringbone::Schema.define do |s|
      s.int32 :id, null: false
      s.int8 :score
      s.timestamp :at, unit: :millis
      s.struct(:address) { |a| a.string :city }
      s.list :tags, :string
    end
    wide = Herringbone::Schema.define do |s|
      s.int64 :id, null: false
      s.uint16 :score
      s.timestamp :at, unit: :micros
      s.struct(:address) { |a|
        a.string :city
        a.string :zip
      }
      s.list :tags, :binary
    end
    at = Time.utc(2026, 10, 9, 12, 0, 0, 123_000)
    a = write_to_string(narrow, [{"id" => 1, "score" => -3, "at" => at, "address" => {"city" => "Lyon"}, "tags" => ["x"]}])
    b = write_to_string(wide, [{"id" => 2**40, "score" => 65_535, "at" => at + Rational(1, 1_000_000), "address" => {"zip" => "69001"}, "tags" => ["\xFF".b]}])
    schema = reader_for(a).schema + reader_for(b).schema
    assert_equal Herringbone::Schema.define { |s|
      s.int64 :id, null: false
      s.int32 :score
      s.timestamp :at, unit: :micros
      s.struct(:address) { |x|
        x.string :city
        x.string :zip
      }
      s.list :tags, :binary
    }, schema
    out, report = combine([a, b], schema: schema)
    assert_equal({copied: 1, rewritten: 1}, report.row_groups, "b has the union's types already")
    assert_well_formed out
    # Widening the annotation alone keeps the bytes, so those chunks of a are still copied
    %w[score address.city tags.list.element].each do |path|
      assert_equal pages(a, 0, path), pages(out, 0, path), path
    end
    %w[id at].each { |path| refute_equal pages(a, 0, path), pages(out, 0, path), path }
    read = reader_for(out).read
    assert_equal [1, 2**40], read.map { |r| r["id"] }
    assert_equal [-3, 65_535], read.map { |r| r["score"] }
    assert_equal [at, at + Rational(1, 1_000_000)], read.map { |r| r["at"] }
    assert_equal [{"city" => "Lyon", "zip" => nil}, {"city" => nil, "zip" => "69001"}], read.map { |r| r["address"] }
    assert_equal [["x"], ["\xFF".b]], read.map { |r| r["tags"] }
  end

  def test_list_elements_named_another_way_are_still_copied
    # pyarrow names the element of a list "item"
    pyarrow = Herringbone::Schema.new(Herringbone::Schema::Node.new(name: "schema", repetition: :required, children: [
      Herringbone::Schema::Node.new(name: "tags", converted_type: F::ConvertedType::LIST,
        logical_type: F::LogicalType.new(list: F::ListType.new), children: [
          Herringbone::Schema::Node.new(name: "list", repetition: :repeated, children: [
            Herringbone::Schema::Node.new(name: "item", **Herringbone::Types.physical_attributes(:string))
          ])
        ])
    ]))
    ours = Herringbone::Schema.define { |s| s.list :tags, :string }
    a = write_to_string(ours, [{"tags" => %w[a b]}])
    b = write_to_string(pyarrow, [{"tags" => ["c", nil]}, {"tags" => nil}])
    schema = reader_for(a).schema + reader_for(b).schema
    assert_equal ours, schema
    out, report = combine([a, b], schema: schema)
    assert_equal({copied: 2, rewritten: 0}, report.row_groups)
    assert_equal pages(b, 0, "tags.list.item"), pages(out, 1, "tags.list.element")
    assert_equal [%w[tags list element]] * 2, reader_for(out).row_groups.map { |rg| rg.columns[0].meta_data.path_in_schema }
    assert_equal [%w[a b], ["c", nil], nil], reader_for(out).read.map { |r| r["tags"] }
  end

  def test_columns_that_become_nullable_are_encoded_again
    required = Herringbone::Schema.define do |s|
      s.struct(:address, null: false) { |a| a.string :city }
      s.string :name
    end
    optional = Herringbone::Schema.define do |s|
      s.struct(:address) { |a| a.string :city }
      s.string :name
    end
    a = write_to_string(required, [{"address" => {"city" => "Lyon"}, "name" => "x"}])
    out, report = combine([a], schema: optional)
    assert_equal({copied: 0, rewritten: 1}, report.row_groups)
    refute_equal pages(a, 0, "address.city"), pages(out, 0, "address.city"), "a definition level more"
    assert_equal pages(a, 0, "name"), pages(out, 0, "name")
    assert_equal [{"address" => {"city" => "Lyon"}, "name" => "x"}], reader_for(out).read
  end

  def test_combine_with_a_schema_narrower_than_an_input
    a = write_to_string(Herringbone::Schema.define { |s| s.int64 :id }, [{"id" => 2**40}])
    error = assert_raises(ArgumentError) { combine([a], schema: Herringbone::Schema.define { |s| s.int32 :id }) }
    assert_equal "Input 0 does not fit the schema: id is wider in the input than in the schema " \
      "(a wider type, or nullable or more members); pass the union of the schemas", error.message
  end

  def test_combine_with_a_schema_an_input_has_no_common_type_with
    a = write_to_string(Herringbone::Schema.define { |s|
      s.int64 :id
      s.string :zip
    }, [{"id" => 1}])
    schema = Herringbone::Schema.define do |s|
      s.double :id
      s.int32 :zip
    end
    error = assert_raises(ArgumentError) { combine([a], schema: schema) }
    assert_equal <<~MESSAGE.chomp, error.message
      Input 0 does not fit the schema (the schema's type first, then the input's):
        id: double vs int64 (int64 does not fit a double exactly)
        zip: int32 vs string (no common type)
    MESSAGE
  end

  def test_combine_argument_errors
    assert_raises(ArgumentError) { combine([]) }
    assert_raises(ArgumentError) { Herringbone.combine(StringIO.new(file(0...10)), StringIO.new) }
    error = assert_raises(ArgumentError) { combine([file(0...10)], row_group_rows: 5) }
    assert_match "row_group_rows", error.message
  end

  def test_combine_re_encodes_with_codecs_of_the_source
    a = file(0...100, compression: :gzip)
    b = write_to_string(Herringbone::Schema.define { |s| s.int64 :id }, [{"id" => 5}], compression: :gzip)
    schema = reader_for(a).schema + reader_for(b).schema
    out, = combine([a, b], schema: schema)
    codecs = reader_for(out).row_groups.map { |rg| rg.columns.map { |c| c.meta_data.codec } }
    assert_equal [F::Codec::GZIP] * 6, codecs[0], "the widened id of input 0 keeps its codec"
    assert_equal [F::Codec::GZIP] + [F::Codec::SNAPPY] * 5, codecs[1], "columns of nulls take the writer's codec"
    out, = combine([a, b], schema: schema, compression: :none)
    assert_equal F::Codec::UNCOMPRESSED, reader_for(out).row_groups[0].columns[0].meta_data.codec
    assert_equal F::Codec::GZIP, reader_for(out).row_groups[0].columns[1].meta_data.codec, "copied as it is"
  end

  def test_corrupt_page_header_raises
    a = file(0...100)
    meta = reader_for(a).row_groups[0].columns[0].meta_data
    a = a.dup
    a[meta.data_page_offset, 8] = "\xFF".b * 8
    error = assert_raises(Herringbone::FormatError) { combine([a]) } # used to retry forever at the end of the file
    assert_match "Corrupt page header in id", error.message
  end

  # --- Encryption ---

  def test_encrypted_inputs_need_encryption_for_the_output
    encrypted = file(0...100, encryption: {footer_key: KEY})
    error = assert_raises(ArgumentError) { combine([file(100...200), encrypted], decryption: {footer_key: KEY}) }
    assert_match "Input 1 is encrypted: pass encryption:", error.message
    assert_raises(Herringbone::DecryptionError) { combine([encrypted]) }
  end

  def test_encrypted_inputs_into_a_plaintext_file
    encrypted = file(0...150, encryption: {footer_key: KEY})
    out, report = combine([file(150...200), encrypted], decryption: {footer_key: KEY}, encryption: false)
    assert_equal({copied: 1, rewritten: 2}, report.row_groups)
    assert_well_formed out
    assert_roundtrip SCHEMA, rows(150...200) + rows(0...150), out
  end

  def test_combine_into_an_encrypted_file
    key = Herringbone::Key.generate
    out, report = combine([file(0...100), file(100...150, encryption: {footer_key: KEY})], decryption: {footer_key: KEY},
      encryption: key)
    assert_equal({copied: 0, rewritten: 2}, report.row_groups)
    assert_raises(Herringbone::DecryptionError) { reader_for(out) }
    reader = Herringbone::Reader.new(StringIO.new(out), decryption: key)
    assert_equal canonical_lines(SCHEMA, rows(0...150)), canonical_lines(SCHEMA, reader.read)
  end

  def test_only_encrypted_columns_are_re_encoded
    a = file(0...100)
    out, = combine([a], encryption: {footer_key: KEY, columns: {"email" => "E" * 16}, plaintext_footer: true})
    assert_equal pages(a, 0, "address.zip"), pages(out, 0, "address.zip")
    refute_equal pages(a, 0, "email"), pages(out, 0, "email")
    reader = Herringbone::Reader.new(StringIO.new(out), decryption: {footer_key: KEY, columns: {"email" => "E" * 16}})
    assert_equal canonical_lines(SCHEMA, rows(0...100)), canonical_lines(SCHEMA, reader.read)
  end

  # --- Files from other writers ---

  # Files written by pyarrow, parquet-mr and others combine with themselves
  def test_fixtures_combine_with_themselves
    paths = Dir[File.join(FIXTURES_DIR, "generated", "*.parquet")] +
      %w[alltypes_plain.parquet alltypes_dictionary.parquet nested_structs.rust.parquet dict-page-offset-zero.parquet
        data_index_bloom_encoding_stats.parquet datapage_v2.snappy.parquet nulls.snappy.parquet].map { |f| File.join(FIXTURES_DIR, "parquet-testing", f) }
    paths.each do |path|
      bytes = File.binread(path)
      reader = reader_for(bytes)
      begin
        original = reader.read
      rescue Herringbone::UnsupportedError
        next # a codec gem this run goes without
      end
      name = File.basename(path)
      out, report = combine([bytes, bytes])
      assert_equal 2 * original.size, report.rows, name
      assert_well_formed out, name
      expected = (original + original).map { |r| Canonical.dump(Canonical.row(reader.schema, r)) }
      assert_equal expected, reader_for(out).read.map { |r| Canonical.dump(Canonical.row(reader.schema, r)) }, name
    end
  end

  def test_pyarrow_reads_combined_files
    python = ENV["HERRINGBONE_PYTHON"]
    skip "HERRINGBONE_PYTHON is not set" if python.nil? || python.empty?
    dump = File.expand_path("support/pyarrow_dump.py", __dir__)
    _, status = Open3.capture2e(python, dump, "--check")
    skip "#{python} cannot import pyarrow" unless status.success?
    narrow = Herringbone::Schema.define { |s| s.int64 :id, null: false }
    a = file(0...250)
    b = write_to_string(narrow, [{"id" => 1000}])
    Dir.mktmpdir do |dir|
      same = File.join(dir, "same.parquet")
      union = File.join(dir, "union.parquet")
      File.binwrite(same, combine([a, file(250...300)]).first)
      File.binwrite(union, combine([a, b], schema: SCHEMA + narrow).first)
      out, err, st = Open3.capture3(python, dump, same, union)
      assert st.success?, err
      results = JSON.parse(out)
      {same => rows(0...300), union => rows(0...250) + [{"id" => 1000}]}.each do |path, expected|
        r = results.fetch(path)
        assert_nil r["error"], path
        assert_nil r["checksum"], path
        assert_equal [], r["stats_errors"], path
        assert_equal expected.size, r["num_rows"]
        assert_equal expected.map { |row| row["id"] }, r["rows"].map { |row| row["id"] }
        assert_equal expected.map { |row| row["email"] }, r["rows"].map { |row| row["email"] }
        assert_equal expected.map { |row| row["tags"] }, r["rows"].map { |row| row["tags"] }
      end
    end
  end
end
