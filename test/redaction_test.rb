# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"
require "minitest/mock"

# Herringbone::Redaction and Herringbone.redact
class RedactionTest < Minitest::Test
  include WriterHelpers

  F = Herringbone::Format

  SCHEMA = Herringbone::Schema.define do |s|
    s.int64 :user_id, null: false
    s.string :email
    s.string :name
    s.struct :address do |address|
      address.string :city
      address.string :zip
    end
    s.list :tags, :string
    s.int32 :score
  end

  # 300 rows in 3 row groups of 100; user_id 7 only lives in row group 0
  def rows
    Array.new(300) do |i|
      {"user_id" => (i < 100) ? i % 10 : 100 + i, "email" => "user#{i}@example.com", "name" => "Name #{i}",
       "address" => {"city" => "City #{i % 3}", "zip" => "Z#{i}"}, "tags" => ["t#{i % 4}"], "score" => i}
    end
  end

  def source(**options)
    write_to_string(SCHEMA, rows, row_group_rows: 100, bloom_filters: %w[email user_id], **options)
  end

  def redact(bytes, redaction = nil, **options, &block)
    out = StringIO.new("".b)
    report = Herringbone.redact(StringIO.new(bytes), out, redaction, **options, &block)
    [out.string, report]
  end

  # Every page of a column chunk (header and body) as stored
  def pages(bytes, row_group, path)
    chunk = Herringbone::Inspector.new(StringIO.new(bytes)).row_groups[row_group].column(path)
    chunk.pages.map { |p| bytes.byteslice(p.offset, p.total_size) }
  end

  def chunk(bytes, row_group, path)
    reader_for(bytes).row_groups[row_group].columns.find { |c| c.meta_data.path_in_schema.join(".") == path }
  end

  def column_index(bytes, row_group, path)
    c = chunk(bytes, row_group, path)
    F::ColumnIndex.decode(bytes, c.column_index_offset).first
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

  # An IO that remembers which byte ranges were read
  class RecordingIO < StringIO
    attr_reader :reads

    def initialize(*)
      super
      @reads = []
    end

    def read(length = nil, *rest)
      start = pos
      super.tap { |data| @reads << (start...(start + data.bytesize)) if data }
    end
  end

  def test_delete_removes_rows_and_rewrites_only_their_row_group
    bytes = source
    out, report = redact(bytes) { |r| r.where(user_id: 7).delete }
    expected = rows.reject { |r| r["user_id"] == 7 }
    assert_roundtrip SCHEMA, expected, out
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal 10, report.rows_deleted
    assert_equal 0, report.rows_changed
    assert_equal 100, report.rows_read # the two other row groups are ruled out by statistics
    reader = reader_for(out)
    assert_equal [90, 100, 100], reader.row_groups.map(&:num_rows)
    SCHEMA.columns.each do |col|
      [1, 2].each do |g|
        assert_equal pages(bytes, g, col.dotted_path), pages(out, g, col.dotted_path), "#{col.dotted_path} in row group #{g}"
      end
    end
  end

  def test_delete_every_row_of_a_row_group_drops_it
    out, report = redact(source) { |r| r.where(user_id: 0..9).delete }
    assert_equal [100, 100], reader_for(out).row_groups.map(&:num_rows)
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal 100, report.rows_deleted
    assert_roundtrip SCHEMA, rows.drop(100), out
  end

  def test_delete_nothing_copies_everything
    bytes = source
    out, report = redact(bytes) { |r| r.where(email: "nobody@example.com").delete }
    assert_equal({copied: 3, rewritten: 0}, report.row_groups)
    assert_equal 0, report.rows_deleted
    3.times do |g|
      SCHEMA.columns.each { |col| assert_equal pages(bytes, g, col.dotted_path), pages(out, g, col.dotted_path) }
    end
    assert_roundtrip SCHEMA, rows, out
    assert_well_formed out
    # Copied offsets point at the copied pages: the page index still lets reads skip
    assert_equal [{"score" => 250}], reader_for(out).read(columns: ["score"], where: {score: 250})
  end

  def test_callable_conditions_scan_the_condition_columns
    out, report = redact(source) { |r| r.where(name: ->(n) { n == "Name 150" }).delete }
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal 300, report.rows_read # a callable rules nothing out without reading
    assert_roundtrip SCHEMA, rows.reject { |r| r["name"] == "Name 150" }, out
  end

  def test_replace_leaf_rewrites_only_that_chunk
    bytes = source
    out, report = redact(bytes) { |r| r.where(user_id: 7).replace(email: nil, name: "[deleted]") }
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal 10, report.rows_changed
    expected = rows.map { |r| (r["user_id"] == 7) ? r.merge("email" => nil, "name" => "[deleted]") : r }
    assert_roundtrip SCHEMA, expected, out
    (SCHEMA.columns.map(&:dotted_path) - %w[email name]).each do |path|
      assert_equal pages(bytes, 0, path), pages(out, 0, path), path
    end
    refute_equal pages(bytes, 0, "email"), pages(out, 0, "email")
  end

  def test_removed_values_leave_no_trace
    secret = "user9@example.com" # also the chunk's maximum
    bytes = source(compression: :none)
    assert bytes.include?(secret)
    reader = reader_for(bytes)
    assert reader.bloom_filter(0, "email").might_contain?(secret)
    out, = redact(bytes) { |r| r.where(email: secret).replace(email: "redacted") }
    refute out.include?(secret), "the removed value is still in the file"
    reader = reader_for(out)
    stats = chunk(out, 0, "email").meta_data.statistics
    assert_operator stats.max_value, :<, secret
    refute_includes column_index(out, 0, "email").max_values, secret
    refute reader.bloom_filter(0, "email").might_contain?(secret)
    assert reader.bloom_filter(0, "email").might_contain?("redacted")
    assert_empty reader.read(where: {email: secret})

    out, = redact(bytes) { |r| r.where(email: secret).delete }
    refute out.include?(secret)
    refute reader_for(out).bloom_filter(0, "email").might_contain?(secret)
  end

  def test_deleted_row_values_leave_no_trace_in_any_column
    bytes = source(compression: :none)
    out, = redact(bytes) { |r| r.where(user_id: 7).delete }
    gone = rows.select { |r| r["user_id"] == 7 }.flat_map { |r| [r["email"], r["name"], r["address"]["zip"]] }
    gone.each { |value| refute out.include?([value.bytesize].pack("V") + value), value } # as PLAIN stores them
    refute reader_for(out).bloom_filter(0, "user_id").might_contain?(7)
  end

  def test_replace_struct_member
    bytes = source
    out, report = redact(bytes) { |r| r.replace("address.city") { |city| city.upcase } }
    assert_equal({copied: 0, rewritten: 3}, report.row_groups)
    expected = rows.map { |r| r.merge("address" => r["address"].merge("city" => r["address"]["city"].upcase)) }
    assert_roundtrip SCHEMA, expected, out
    3.times { |g| assert_equal pages(bytes, g, "address.zip"), pages(out, g, "address.zip") }
  end

  def test_struct_member_of_a_null_struct_is_left_alone
    data = [{"user_id" => 1, "address" => nil}, {"user_id" => 2, "address" => {"city" => "A"}}]
    out, report = redact(write_to_string(SCHEMA, data)) { |r| r.replace("address.city" => "X") }
    assert_equal [nil, {"city" => "X", "zip" => nil}], reader_for(out).read.map { |r| r["address"] }
    assert_equal 1, report.rows_changed
  end

  def test_replace_whole_list_and_struct
    out, = redact(source) do |r|
      r.replace(:tags) { |tags| tags.map(&:upcase) }
      r.where(user_id: 3).replace(address: nil)
    end
    expected = rows.map do |r|
      r = r.merge("tags" => r["tags"].map(&:upcase))
      (r["user_id"] == 3) ? r.merge("address" => nil) : r
    end
    assert_roundtrip SCHEMA, expected, out
  end

  def test_block_receives_the_row_when_it_asks
    out, = redact(source) { |r| r.replace(:name) { |name, row| "#{row["user_id"]}:#{row["address"]["zip"]}" } }
    assert_equal "7:Z7", reader_for(out).read[7]["name"]
    seen = []
    redact(source) { |r| r.replace(:name) { |*args| seen << args.size } }
    assert_equal [2], seen.uniq
  end

  def test_drop
    bytes = source(metadata: {"ARROW:schema" => "stale", "owner" => "me"})
    out, report = redact(bytes) { |r| r.drop :tags, "address.zip" }
    reader = reader_for(out)
    assert_equal %w[user_id email name address.city score], reader.schema.columns.map(&:dotted_path)
    assert_equal({copied: 3, rewritten: 0}, report.row_groups)
    assert_equal({"owner" => "me"}, reader.metadata)
    expected = rows.map { |r| r.except("tags").merge("address" => {"city" => r["address"]["city"]}) }
    assert_equal expected, reader.read
    3.times { |g| assert_equal pages(bytes, g, "score"), pages(out, g, "score") }
  end

  def test_drop_with_rewrite
    out, = redact(source) do |r|
      r.where(user_id: 7).delete
      r.drop :email
    end
    assert_equal rows.reject { |r| r["user_id"] == 7 }.map { |r| r.except("email") }, reader_for(out).read
  end

  def test_statements_apply_in_order
    out, report = redact(source) do |r|
      r.where(user_id: 7).replace(email: nil)
      r.where(email: nil).delete # sees the email blanked above
      r.where(user_id: 8).delete
      r.where(user_id: 8).replace(name: "never") # the row is gone already
      r.replace(:name) { |name| name.sub("Name", "N") } # sees nothing deleted
    end
    expected = rows.reject { |r| [7, 8].include?(r["user_id"]) }.map { |r| r.merge("name" => r["name"].sub("Name", "N")) }
    assert_roundtrip SCHEMA, expected, out
    assert_equal 20, report.rows_deleted
    assert_equal 280, report.rows_changed
  end

  def test_where_conditions_are_or_ed_across_statements
    forget = Herringbone::Redaction.new do |r|
      r.where(user_id: 7).delete
      r.where(email: "user250@example.com").delete
      r.where(score: ..2).delete
    end
    out, report = redact(source, forget)
    assert_equal 14, report.rows_deleted
    assert_equal({copied: 1, rewritten: 2}, report.row_groups)
    assert_equal rows.size - 14, reader_for(out).num_rows
  end

  def test_affects
    bytes = source
    assert Herringbone::Redaction.new { |r| r.where(user_id: 7).delete }.affects?(StringIO.new(bytes))
    refute Herringbone::Redaction.new { |r| r.where(user_id: 12_345).delete }.affects?(StringIO.new(bytes))
    refute Herringbone::Redaction.new { |r| r.where(name: ->(n) { n == "x" }).delete }.affects?(StringIO.new(bytes))
    assert Herringbone::Redaction.new { |r| r.replace(name: nil) }.affects?(StringIO.new(bytes))
    assert Herringbone::Redaction.new { |r| r.drop :tags }.affects?(StringIO.new(bytes))
    refute Herringbone::Redaction.new { |r| r.replace(name: nil) }.affects?(StringIO.new(write_to_string(SCHEMA, [])))
  end

  # Column paths of the chunks decoded while the block runs
  def decoded_chunks
    seen = []
    original = Herringbone::Reader::ColumnChunkReader.method(:new)
    Herringbone::Reader::ColumnChunkReader.stub(:new, ->(*args, **kw) {
      seen << args[2].dotted_path
      original.call(*args, **kw)
    }) { yield }
    seen
  end

  def test_affects_reads_only_the_condition_columns
    bytes = source
    result = nil
    decoded = decoded_chunks do
      result = Herringbone::Redaction.new { |r| r.where(name: ->(n) { n == "Name 250" }).delete }.affects?(StringIO.new(bytes))
    end
    assert result
    assert_equal ["name"] * 3, decoded
    decoded = decoded_chunks { Herringbone::Redaction.new { |r| r.where(user_id: 250).delete }.affects?(StringIO.new(bytes)) }
    assert_equal ["user_id"], decoded # row groups 0 and 2 are ruled out by statistics
  end

  def test_affects_stops_at_statistics
    io = RecordingIO.new(source)
    refute Herringbone::Redaction.new { |r| r.where(user_id: 12_345).delete }.affects?(io)
    first_chunk_end = reader_for(io.string).row_groups.last.columns.last.meta_data.then { |m| m.data_page_offset + m.total_compressed_size }
    assert io.reads.all? { |r| r.begin >= first_chunk_end }, "no column chunk is read"
  end

  def test_mistakes_raise_before_anything_is_written
    bytes = source
    {
      ->(r) { r.where(nope: 1).delete } => /no such column "nope"/,
      ->(r) { r.replace(nope: 1) } => /no such column "nope"/,
      ->(r) { r.replace(user_id: nil) } => /user_id is required/,
      ->(r) { r.replace(score: "not a number") } => /cannot write "not a number" to score/,
      ->(r) { r.replace("tags.list.element" => "x") } => /inside the list tags; replace tags instead with a block that receives its Array/,
      ->(r) { r.drop :nope } => /drop: no such column/,
      ->(r) { r.drop :user_id, :email, :name, :address, :tags, :score } => /cannot drop every column/,
      ->(r) { r.drop "address.city", "address.zip" } => /cannot drop every member of address/,
      ->(r) {
        r.drop :address
        r.replace("address.city" => nil)
      } => /address.city is dropped/
    }.each do |block, message|
      out = StringIO.new("".b)
      redaction = Herringbone::Redaction.new(&block)
      error = assert_raises(ArgumentError) { redaction.apply(StringIO.new(bytes), out) }
      assert_match message, error.message
      assert_equal 0, out.size, "nothing written for #{message.inspect}"
      assert_raises(ArgumentError) { redaction.affects?(StringIO.new(bytes)) }
    end
    out = StringIO.new("".b)
    assert_raises(ArgumentError) { Herringbone.redact(StringIO.new(bytes), out, row_group_rows: 10) { |r| r.replace(name: nil) } }
    assert_raises(ArgumentError) { Herringbone.redact(StringIO.new(bytes), out, compression: :nope) { |r| r.replace(name: nil) } }
    assert_equal 0, out.size
  end

  def test_block_without_a_parameter_is_refused
    error = assert_raises(ArgumentError) { Herringbone::Redaction.new { nil } }
    assert_match(/Redaction.new \{ \|r\| r.where/, error.message)
    out = StringIO.new("".b)
    error = assert_raises(ArgumentError) { Herringbone.redact(StringIO.new(source), out) { nil } }
    assert_match(/Herringbone.redact\(input, output\) \{ \|r\| r.where/, error.message)
    assert_equal 0, out.size
  end

  def test_block_sees_the_methods_around_it
    out, = redact(source) { |r| r.where(user_id: forgotten_user).delete }
    assert_equal 290, reader_for(out).num_rows
  end

  def forgotten_user = 7

  def test_dsl_mistakes
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.where(user_id: 1) } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.where({}) } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.replace(:email) } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.replace(:email, name: nil) { |v| v } } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.replace(email: nil) { |v| v } } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.replace } }
    assert_raises(ArgumentError) { Herringbone::Redaction.new { |r| r.drop } }
    redaction = Herringbone::Redaction.new
    redaction.where(user_id: 1)
    out = StringIO.new("".b)
    assert_raises(ArgumentError) { redaction.apply(StringIO.new(source), out) }
    assert_equal 0, out.size
    assert_raises(ArgumentError) { Herringbone.redact(StringIO.new(source), out) }
    assert_raises(ArgumentError) { Herringbone.redact(StringIO.new(source), out, redaction) { |r| r.replace(name: nil) } }
  end

  def test_block_argument_and_chaining
    helper = "[gone]"
    redaction = Herringbone::Redaction.new { |r| r.where(user_id: 7).replace(name: helper).where(user_id: 8).delete }
    out, report = redact(source, redaction)
    assert_equal 10, report.rows_deleted
    assert_equal 10, report.rows_changed
    assert_equal ["[gone]"], reader_for(out).read(where: {user_id: 7}).map { |r| r["name"] }.uniq
  end

  def test_bad_block_value_raises_with_the_row
    redaction = Herringbone::Redaction.new { |r| r.replace(:score) { "oops" } }
    out = StringIO.new("".b)
    error = assert_raises(Herringbone::EncodeError) { redaction.apply(StringIO.new(source), out) }
    assert_equal "score", error.column
    assert_equal 0, error.row
  end

  def test_writer_options_apply_to_rewritten_chunks
    bytes = source
    out, = redact(bytes, compression: :gzip, page_rows: 10, metadata: {"redacted" => "yes"}) { |r| r.where(user_id: 7).replace(email: nil) }
    reader = reader_for(out)
    assert_equal F::Codec::GZIP, chunk(out, 0, "email").meta_data.codec
    assert_equal F::Codec::SNAPPY, chunk(out, 0, "name").meta_data.codec
    assert_equal 10, F::OffsetIndex.decode(out, chunk(out, 0, "email").offset_index_offset).first.page_locations.size
    assert_equal({"redacted" => "yes"}, reader.metadata)
    assert_match(/herringbone-ruby/, reader.file_metadata.created_by)
  end

  def test_rewritten_chunks_keep_codec_and_bloom_filters
    bytes = source(compression: :gzip)
    out, = redact(bytes) { |r| r.where(user_id: 7).replace(email: "x", score: 0) }
    assert_equal [F::Codec::GZIP], reader_for(out).row_groups.flat_map { |rg| rg.columns.map { |c| c.meta_data.codec } }.uniq
    reader = reader_for(out)
    assert reader.bloom_filter(0, "email") # rebuilt for the rewritten chunk
    assert reader.bloom_filter(1, "email") # copied
    assert_nil reader.bloom_filter(0, "score")
  end

  def test_metadata_is_copied
    bytes = source(metadata: {"a" => "1", "b" => nil})
    out, = redact(bytes) { |r| r.where(user_id: 7).delete }
    assert_equal({"a" => "1", "b" => nil}, reader_for(out).metadata)
  end

  def test_lzo_chunks_fall_back_to_snappy
    bytes = File.binread(File.join(FIXTURES_DIR, "lzo", "lzo.parquet"))
    original = reader_for(bytes).read
    out, report = redact(bytes) { |r| r.replace(name: "anon") }
    assert_equal({copied: 0, rewritten: 1}, report.row_groups)
    codecs = reader_for(out).row_groups[0].columns.to_h { |c| [c.meta_data.path_in_schema.join("."), c.meta_data.codec] }
    assert_equal({"id" => F::Codec::LZO, "name" => F::Codec::SNAPPY, "score" => F::Codec::LZO}, codecs)
    assert_equal original.map { |r| r.merge("name" => r["name"] && "anon") }, reader_for(out).read
  end

  def test_redaction_is_reusable
    forget = Herringbone::Redaction.new { |r| r.where(user_id: 7).delete }
    a = StringIO.new("".b)
    b = StringIO.new("".b)
    forget.apply(StringIO.new(source), a)
    forget.apply(StringIO.new(source(compression: :none)), b)
    assert_equal reader_for(a.string).read, reader_for(b.string).read
  end

  def test_sorting_columns_survive_where_they_still_hold
    bytes = source
    meta = F::FileMetaData.decode(bytes.byteslice(-8 - bytes.byteslice(-8, 4).unpack1("V"), bytes.byteslice(-8, 4).unpack1("V"))).first
    meta.row_groups.each { |rg| rg.sorting_columns = [F::SortingColumn.new(column_idx: 6, descending: false, nulls_first: false), F::SortingColumn.new(column_idx: 0, descending: false, nulls_first: false)] }
    footer = meta.encode
    body = bytes.byteslice(0, bytes.bytesize - 8 - bytes.byteslice(-8, 4).unpack1("V"))
    bytes = body + footer + [footer.bytesize].pack("V") + "PAR1"
    out, = redact(bytes) do |r|
      r.where(user_id: 7).replace(user_id: 0)
      r.drop :tags
    end
    sorting = reader_for(out).row_groups.map { |rg| rg.sorting_columns&.map(&:column_idx) }
    assert_equal [[5], [5, 0], [5, 0]], sorting
  end

  # Files written by pyarrow, parquet-mr and others survive both kinds of rewrite
  def test_fixtures_round_trip
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
      field = reader.schema.fields.find { |f| f.leaf? && f.optional && reader.schema.column(f.name) }
      out, report = redact(bytes) { |r| r.replace(field.name => nil) } if field
      if field
        assert_well_formed out, name
        assert_equal Canonical.dump(original.map { |r| Canonical.row(reader.schema, r.merge(field.name => nil)) }),
          Canonical.dump(reader_for(out).read.map { |r| Canonical.row(reader.schema, r) }), name
        assert_equal 0, report.row_groups[:copied], name unless original.all? { |r| r[field.name].nil? }
      end
      flat = reader.schema.fields.find { |f| f.leaf? && f.column.type != F::Type::INT96 && original.any? { |r| !r[f.name].nil? } }
      next unless flat
      value = original.find { |r| !r[flat.name].nil? }[flat.name]
      out, = redact(bytes) { |r| r.where(flat.name => value).delete }
      assert_well_formed out, name
      expected = original.reject { |r| Herringbone::Reader::Filter.matches?(value, r[flat.name]) }
      assert_equal Canonical.dump(expected.map { |r| Canonical.row(reader.schema, r) }),
        Canonical.dump(reader_for(out).read.map { |r| Canonical.row(reader.schema, r) }), name
    end
  end
end
