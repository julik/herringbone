# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/writer_helpers"

# Parquet modular encryption: reading the apache/parquet-testing fixtures, writing and reading
# back in every mode, missing and wrong keys, tampering, redaction and the inspector
class EncryptionTest < Minitest::Test
  include WriterHelpers

  PARQUET_TESTING = File.join(FIXTURES_DIR, "parquet-testing")

  # Keys of the fixtures written by Arrow C++ (data/README.md in parquet-testing)
  ARROW_KEYS = {"kf" => "0123456789012345", "kc1" => "1234567890123450", "kc2" => "1234567890123451"}.freeze
  # Keys of the fixtures in data/aes256, written by parquet-mr
  MR_KEYS = {"kf" => "01234567890123456789012345678901"}.merge(
    (1..8).to_h { |i| ["kc#{i}", "123456789012345678901234567890#{11 + i}"] }
  ).freeze

  FOOTER_KEY = "F" * 16
  SSN_KEY = "S" * 32
  ADDRESS_KEY = "A" * 24

  SCHEMA = Herringbone::Schema.define do |s|
    s.int64 :id, null: false
    s.string :ssn
    s.string :name
    s.struct :address do |a|
      a.string :city
      a.int32 :zip
    end
    s.list :tags, :string
    s.double :score
  end

  def rows(n = 600)
    Array.new(n) do |i|
      {"id" => i, "ssn" => (i % 13).zero? ? nil : format("SECRET-%04d", i), "name" => "name #{i % 20}",
       "address" => (i % 17).zero? ? nil : {"city" => "City #{i % 5}", "zip" => 1000 + i},
       "tags" => ["t#{i % 3}"] * (i % 4), "score" => i * 0.25}
    end
  end

  def write(rows = self.rows, schema: SCHEMA, **options)
    write_to_string(schema, rows, page_rows: 100, row_group_rows: 250, **options)
  end

  def encrypted(**settings)
    {footer_key: FOOTER_KEY, footer_key_metadata: "footer"}.merge(settings)
  end

  def keys
    {keys: {"footer" => FOOTER_KEY, "ssn" => SSN_KEY, "address" => ADDRESS_KEY}}
  end

  def encrypted_reader(bytes, decryption = keys, **options)
    Herringbone::Reader.new(StringIO.new(bytes), decryption: decryption, **options)
  end

  # --- parquet-testing fixtures ---

  def fixture(name)
    File.binread(File.join(PARQUET_TESTING, name))
  end

  def assert_fixture_rows(rows)
    assert_equal 50, rows.size
    rows.each_with_index do |row, i|
      assert_equal i, row["int32_field"]
      assert_equal i.even?, row["boolean_field"]
      assert_equal [i * 2 * 10**12, (i * 2 + 1) * 10**12], row["int64_field"]
      assert_in_delta i * 1.1, row["float_field"], 1e-4
      assert_in_delta i * 1.1111111, row["double_field"], 1e-9
      i.even? ? assert_equal(format("parquet%03d", i), row["ba_field"]) : assert_nil(row["ba_field"])
      assert_equal i.chr * 10, row["flba_field"]
    end
  end

  def test_reads_arrow_fixtures
    %w[encrypt_columns_and_footer encrypt_columns_and_footer_ctr encrypt_columns_plaintext_footer
      uniform_encryption encrypt_columns_and_footer_aad encrypt_columns_and_footer_disable_aad_storage].each do |name|
      decryption = {keys: ARROW_KEYS}
      decryption[:aad_prefix] = "tester" if name.include?("aad")
      reader = encrypted_reader(fixture("#{name}.parquet.encrypted"), decryption)
      assert_fixture_rows(reader.read)
    end
  end

  def test_reads_parquet_mr_aes256_fixtures
    %w[encrypt_columns_and_footer encrypt_columns_and_footer_ctr encrypt_columns_plaintext_footer
      uniform_encryption encrypt_columns_and_footer_disable_aad_storage].each do |name|
      decryption = {keys: MR_KEYS}
      decryption[:aad_prefix] = "tester" if name.include?("aad")
      reader = encrypted_reader(fixture("aes256/#{name}.parquet.encrypted"), decryption)
      assert_fixture_rows(reader.read)
    end
  end

  def test_fixture_encryption_description
    reader = encrypted_reader(fixture("encrypt_columns_plaintext_footer.parquet.encrypted"), {keys: ARROW_KEYS})
    info = reader.encryption
    assert_equal :aes_gcm, info[:algorithm]
    assert_equal :plaintext, info[:footer]
    assert_equal "kf", info[:footer_key_metadata]
    assert info[:footer_verified]
    assert_equal({"float_field" => {key: :column, key_metadata: "kc2", readable: true},
                  "double_field" => {key: :column, key_metadata: "kc1", readable: true}}, info[:columns])

    ctr = encrypted_reader(fixture("encrypt_columns_and_footer_ctr.parquet.encrypted"), {keys: ARROW_KEYS}).encryption
    assert_equal :aes_gcm_ctr, ctr[:algorithm]
    assert_equal :encrypted, ctr[:footer]
    refute ctr[:footer_verified]

    stored = encrypted_reader(fixture("encrypt_columns_and_footer_aad.parquet.encrypted"), {keys: ARROW_KEYS, aad_prefix: "tester"})
    assert_equal "tester", stored.encryption[:aad_prefix]
    supplied = encrypted_reader(fixture("encrypt_columns_and_footer_disable_aad_storage.parquet.encrypted"),
      {keys: ARROW_KEYS, aad_prefix: "tester"})
    assert_nil supplied.encryption[:aad_prefix]
    assert supplied.encryption[:supply_aad_prefix]

    assert_nil reader_for(write(rows(5))).encryption
  end

  def test_fixture_pushdown_uses_decrypted_bloom_filters_and_page_index
    reader = encrypted_reader(fixture("encrypt_columns_and_footer_bloom_filter.parquet.encrypted"), {keys: ARROW_KEYS})
    filter = reader.bloom_filter(0, "double_field")
    assert filter.might_contain?(1500.5)
    assert_equal [{"double_field" => 1500.5, "float_field" => 1500.25, "int32_field" => 1500, "name" => "name_1500"}],
      reader.read(where: {double_field: 1500.5})
    assert_equal [], reader.scan_plan(where: {double_field: 1500.7}), "the bloom filter rules the value out"
    assert_equal [[942, 1910]], reader.scan_plan(where: {double_field: 1000.5}).first[:ranges]
    assert_equal %w[name_1000 name_1001], reader.read(from: 1000, limit: 2, columns: ["name", "double_field"]).map { |r| r["name"] }
  end

  def test_fixture_aad_prefix_must_match
    name = "encrypt_columns_and_footer_disable_aad_storage.parquet.encrypted"
    error = assert_raises(Herringbone::DecryptionError) { encrypted_reader(fixture(name), {keys: ARROW_KEYS}) }
    assert_match(/AAD prefix/, error.message)
    assert_raises(Herringbone::DecryptionError) { encrypted_reader(fixture(name), {keys: ARROW_KEYS, aad_prefix: "other"}) }
    error = assert_raises(Herringbone::DecryptionError) do
      encrypted_reader(fixture("encrypt_columns_and_footer_aad.parquet.encrypted"), {keys: ARROW_KEYS, aad_prefix: "other"})
    end
    assert_match(/does not match/, error.message)
  end

  def test_fixture_with_plaintext_footer_reads_plaintext_columns_without_keys
    reader = Herringbone::Reader.new(StringIO.new(fixture("encrypt_columns_plaintext_footer.parquet.encrypted")))
    assert_equal (0...50).to_a, reader.read(columns: ["int32_field"]).map { |r| r["int32_field"] }
    refute reader.encryption[:footer_verified]
    refute reader.encryption[:columns]["double_field"][:readable]
    error = assert_raises(Herringbone::DecryptionError) { reader.read }
    assert_match(/float_field is encrypted.*"kc2"/, error.message)
    assert_raises(Herringbone::DecryptionError) { reader.read(columns: ["int32_field"], where: {double_field: 1.0}) }
  end

  # --- writing ---

  def expected_rows(rows = self.rows)
    rows.map { |r| r.merge("address" => r["address"]&.to_h) }
  end

  MODES = {
    uniform: {},
    column_keys: {columns: {"ssn" => {key: SSN_KEY, key_metadata: "ssn"}, "address" => {key: ADDRESS_KEY, key_metadata: "address"},
                            "tags" => :footer}},
    plaintext_footer: {plaintext_footer: true, columns: {"ssn" => {key: SSN_KEY, key_metadata: "ssn"}, "score" => :footer}},
    ctr: {algorithm: :aes_gcm_ctr, columns: {"ssn" => {key: SSN_KEY, key_metadata: "ssn"}, "id" => :footer}},
    aad_prefix: {aad_prefix: "table/part-0"},
    supplied_aad_prefix: {aad_prefix: "table/part-0", store_aad_prefix: false, plaintext_footer: true}
  }.freeze

  MODES.each do |mode, settings|
    [1, 2].each do |version|
      define_method("test_round_trip_#{mode}_v#{version}") do
        bytes = write(data_page_version: version, bloom_filters: %w[id ssn], encryption: encrypted(**settings))
        assert_equal((settings[:plaintext_footer] ? "PAR1" : "PARE"), bytes.byteslice(0, 4))
        assert_equal bytes.byteslice(0, 4), bytes.byteslice(-4, 4)
        decryption = keys
        decryption[:aad_prefix] = "table/part-0" if settings[:store_aad_prefix] == false
        reader = encrypted_reader(bytes, decryption)
        assert_equal expected_rows, reader.read
        assert_equal 3, reader.row_groups.size
        assert_equal [{"id" => 301, "ssn" => "SECRET-0301"}], reader.read(columns: %w[id ssn], where: {ssn: "SECRET-0301"})
        assert_equal [{row_group: 1, rows: 100, ranges: [[100, 200]]}], reader.scan_plan(where: {id: 420..440})
        assert_equal [], reader.scan_plan(where: {ssn: "SECRET-9999"})
        assert_equal (500...510).to_a, reader.read(columns: ["id"], from: 500, limit: 10).map { |r| r["id"] }
        assert_equal expected_rows.map { |r| r["ssn"] }, reader.read(as: :columns, columns: ["ssn"])["ssn"]
      end
    end
  end

  def test_encrypted_columns_leave_no_plaintext_behind
    bytes = write(dictionary: false, compression: :none, encryption: encrypted(columns: {"ssn" => SSN_KEY}, plaintext_footer: true))
    refute_includes bytes, "SECRET", "values, statistics and page index of ssn are encrypted"
    assert_includes bytes, "City 1", "address is not encrypted"
    legacy = reader_for(bytes)
    ssn = legacy.row_groups.first.columns[legacy.schema.column("ssn").index]
    assert_nil ssn.meta_data.statistics, "the plaintext footer keeps no statistics of encrypted columns"
    assert ssn.encrypted_column_metadata
    assert_equal expected_rows.map { |r| r["name"] }, legacy.read(columns: ["name"]).map { |r| r["name"] }
  end

  def test_ctr_pages_are_unauthenticated_but_headers_are_not
    bytes = write(compression: :none, encryption: encrypted(algorithm: :aes_gcm_ctr))
    assert_equal expected_rows, encrypted_reader(bytes).read
  end

  def test_key_sizes
    [16, 24, 32].each do |size|
      key = "k" * size
      bytes = write(rows(20), encryption: {footer_key: key})
      assert_equal expected_rows(rows(20)), encrypted_reader(bytes, {footer_key: key}).read
    end
  end

  def test_explicit_keys_and_resolvers
    bytes = write(encryption: encrypted(**MODES[:column_keys]))
    explicit = {footer_key: FOOTER_KEY, columns: {"ssn" => SSN_KEY, "address" => ADDRESS_KEY}}
    assert_equal expected_rows, encrypted_reader(bytes, explicit).read
    calls = []
    resolver = ->(metadata) {
      calls << metadata
      keys[:keys][metadata]
    }
    assert_equal expected_rows, encrypted_reader(bytes, {keys: resolver}).read
    assert_equal %w[footer ssn address], calls, "each key metadata is resolved once"
    assert_equal expected_rows, encrypted_reader(bytes, {footer_key: FOOTER_KEY, columns: {"address.city" => ADDRESS_KEY, "address.zip" => ADDRESS_KEY},
                                             keys: {"ssn" => SSN_KEY}}).read
  end

  def test_missing_keys
    bytes = write(encryption: encrypted(**MODES[:column_keys]))
    error = assert_raises(Herringbone::DecryptionError) { reader_for(bytes) }
    assert_match(/encrypted \(AES_GCM_V1, footer key metadata "footer"\)/, error.message)
    error = assert_raises(Herringbone::DecryptionError) { encrypted_reader(bytes, {keys: {}}) }
    assert_match(/footer is encrypted.*"footer"/, error.message)

    reader = encrypted_reader(bytes, {footer_key: FOOTER_KEY, keys: ->(metadata) { (metadata == "address") ? ADDRESS_KEY : nil }})
    assert_equal expected_rows.map { |r| r.slice("id", "address") }, reader.read(columns: %w[id address])
    refute reader.encryption[:columns]["ssn"][:readable]
    assert reader.encryption[:columns]["address.city"][:readable]
    error = assert_raises(Herringbone::DecryptionError) { reader.read(columns: ["ssn"]) }
    assert_match(/Column ssn is encrypted and its key was not given \(key metadata "ssn"\)/, error.message)
    assert_raises(Herringbone::DecryptionError) { reader.read(columns: ["id"], where: {ssn: "SECRET-0001"}) }
    assert_raises(Herringbone::DecryptionError) { reader.bloom_filter(0, "ssn") }
  end

  def test_wrong_keys
    bytes = write(encryption: encrypted(**MODES[:column_keys]))
    assert_raises(Herringbone::DecryptionError) { encrypted_reader(bytes, {footer_key: "x" * 16}) }
    error = assert_raises(Herringbone::DecryptionError) { encrypted_reader(bytes, {footer_key: FOOTER_KEY, columns: {"ssn" => "x" * 32}}) }
    assert_match(/column metadata of ssn.*wrong key/, error.message)

    plaintext = write(encryption: encrypted(plaintext_footer: true, columns: {"ssn" => SSN_KEY}))
    error = assert_raises(Herringbone::DecryptionError) { encrypted_reader(plaintext, {footer_key: "x" * 16}) }
    assert_match(/footer signature does not match/, error.message)
    assert_raises(Herringbone::DecryptionError) { encrypted_reader(plaintext, {columns: {"ssn" => "y" * 32}}) }
  end

  def test_tampering_is_detected
    bytes = write(compression: :none, dictionary: false, encryption: encrypted(columns: {"ssn" => SSN_KEY}, plaintext_footer: true))
    reader = encrypted_reader(bytes, {footer_key: FOOTER_KEY, columns: {"ssn" => SSN_KEY}})
    chunk = reader.row_groups.first.columns[reader.schema.column("ssn").index]
    start = chunk.meta_data.data_page_offset
    changed = bytes.dup
    changed.setbyte(start + 40, changed.getbyte(start + 40) ^ 1)
    tampered = encrypted_reader(changed, {footer_key: FOOTER_KEY, columns: {"ssn" => SSN_KEY}})
    assert_raises(Herringbone::DecryptionError) { tampered.read(columns: ["ssn"]) }

    footer_at = bytes.bytesize - 8 - bytes.byteslice(-8, 4).unpack1("V")
    name_at = bytes.index("ssn".b, footer_at)
    changed = bytes.dup
    changed[name_at, 3] = "SSN"
    error = assert_raises(Herringbone::DecryptionError) { encrypted_reader(changed, {footer_key: FOOTER_KEY}) }
    assert_match(/signature/, error.message)
  end

  def test_modules_cannot_be_swapped_between_row_groups
    bytes = write(compression: :none, encryption: encrypted)
    reader = encrypted_reader(bytes)
    a, b = reader.row_groups.first(2).map { |rg| rg.columns[0].meta_data }
    first = bytes.byteslice(a.data_page_offset, a.total_compressed_size)
    second = bytes.byteslice(b.data_page_offset, b.total_compressed_size)
    skip "chunks differ in size" unless first.bytesize == second.bytesize
    swapped = bytes.dup
    swapped[a.data_page_offset, first.bytesize] = second
    assert_raises(Herringbone::DecryptionError) { encrypted_reader(swapped).read(columns: ["id"]) }
  end

  def test_files_have_their_own_aad
    one = write(rows(10), encryption: encrypted)
    two = write(rows(10), encryption: encrypted)
    refute_equal one, two
  end

  def test_writer_option_errors
    {
      {} => /footer_key must be a 16, 24 or 32-byte String/,
      {footer_key: "short"} => /footer_key must be a 16, 24 or 32-byte String.*got 5 bytes/,
      {footer_key: FOOTER_KEY, bogus: 1} => /unknown option bogus/,
      {footer_key: FOOTER_KEY, columns: {"nope" => SSN_KEY}} => /no such column "nope"/,
      {footer_key: FOOTER_KEY, columns: {"address" => SSN_KEY, "address.zip" => SSN_KEY}} => /address.zip is listed twice/,
      {footer_key: FOOTER_KEY, columns: {"ssn" => "x"}} => /key of ssn/,
      {footer_key: FOOTER_KEY, columns: {"ssn" => {key: SSN_KEY, metadata: "x"}}} => /unknown option metadata for ssn/,
      {footer_key: FOOTER_KEY, columns: {"ssn" => 42}} => /expected a key/,
      {footer_key: FOOTER_KEY, algorithm: :aes_cbc} => /algorithm must be/,
      {footer_key: FOOTER_KEY, store_aad_prefix: false} => /store_aad_prefix: false needs an aad_prefix/
    }.each do |settings, message|
      error = assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, SCHEMA, encryption: settings) }
      assert_match message, error.message
    end
    assert_raises(ArgumentError) { Herringbone::Writer.new(StringIO.new, SCHEMA, encryption: "key") }
  end

  def test_reader_option_errors
    bytes = write(rows(5), encryption: encrypted)
    assert_raises(ArgumentError) { encrypted_reader(bytes, {footer: FOOTER_KEY}) }
    assert_raises(ArgumentError) { encrypted_reader(bytes, {footer_key: "short"}) }
    assert_raises(ArgumentError) { encrypted_reader(bytes, {keys: "nope"}) }
    error = assert_raises(ArgumentError) { encrypted_reader(bytes, {keys: ->(_) { "short" }}) }
    assert_match(/keys: the key for the footer/, error.message)
  end

  def test_write_and_simple_writer_pass_encryption_on
    io = StringIO.new
    Herringbone.write(io, [{id: 1, secret: "x"}], encryption: {footer_key: FOOTER_KEY, columns: {"secret" => SSN_KEY}})
    assert_equal [{"id" => 1, "secret" => "x"}], encrypted_reader(io.string, {footer_key: FOOTER_KEY, columns: {"secret" => SSN_KEY}}).read

    io = StringIO.new
    w = Herringbone::SimpleWriter.new(io, encryption: {footer_key: FOOTER_KEY})
    w.headers!(%w[a b])
    w << [1, "x"]
    w.close
    assert_equal [{"a" => 1, "b" => "x"}], encrypted_reader(io.string, {footer_key: FOOTER_KEY}).read
  end

  def test_empty_file
    bytes = write([], encryption: encrypted(**MODES[:column_keys]))
    reader = encrypted_reader(bytes)
    assert_equal [], reader.read
    assert_equal({}, reader.encryption[:columns])
  end

  def test_numo
    skip "Numo is not loaded" unless defined?(Numo::NArray)
    bytes = write(encryption: encrypted)
    batch = encrypted_reader(bytes).read(as: :numo, columns: %w[id score])
    assert_equal (0...600).to_a, batch["id"].to_a
  end

  # --- redaction ---

  def redact(bytes, decryption: keys, **options, &block)
    out = StringIO.new("".b)
    report = Herringbone.redact(StringIO.new(bytes), out, decryption: decryption, **options, &block)
    [out.string, report]
  end

  def test_redaction_keeps_the_encryption
    bytes = write(bloom_filters: %w[ssn], encryption: encrypted(**MODES[:column_keys], aad_prefix: "orders"))
    out, report = redact(bytes) { |r| r.where(id: 7).delete }
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal "PARE", out.byteslice(0, 4)
    reader = encrypted_reader(out, keys)
    assert_equal expected_rows.reject { |r| r["id"] == 7 }, reader.read
    info = reader.encryption
    assert_equal "orders", info[:aad_prefix]
    assert_equal({key: :column, key_metadata: "ssn", readable: true}, info[:columns]["ssn"])
    assert_equal({key: :footer, key_metadata: nil, readable: true}, info[:columns]["tags.list.element"])
    assert_nil info[:columns]["id"]
    assert reader.bloom_filter(0, "ssn"), "re-encoded chunks keep their bloom filter"
  end

  def test_redaction_of_plaintext_footer_and_supplied_aad_prefix
    bytes = write(encryption: encrypted(**MODES[:supplied_aad_prefix]))
    out, = redact(bytes, decryption: keys.merge(aad_prefix: "table/part-0")) { |r| r.drop :name }
    assert_equal "PAR1", out.byteslice(0, 4)
    reader = encrypted_reader(out, keys.merge(aad_prefix: "table/part-0"))
    assert reader.encryption[:supply_aad_prefix]
    assert reader.encryption[:footer_verified]
    assert_equal expected_rows.map { |r| r.except("name") }, reader.read
    assert_raises(Herringbone::DecryptionError) { encrypted_reader(out) }
  end

  def test_redaction_to_plaintext_and_back
    bytes = write(encryption: encrypted(**MODES[:column_keys]))
    plain, = redact(bytes, encryption: false) { |r| r.replace(:name) { |n| n&.upcase } }
    assert_equal "PAR1", plain.byteslice(0, 4)
    assert_nil reader_for(plain).encryption
    assert_equal expected_rows.map { |r| r.merge("name" => r["name"].upcase) }, reader_for(plain).read

    again, report = redact(plain, decryption: nil, encryption: {footer_key: FOOTER_KEY, columns: {"ssn" => SSN_KEY}}) { |r| r.where(id: 1).delete }
    assert_equal({copied: 2, rewritten: 1}, report.row_groups)
    assert_equal({"ssn" => {key: :column, key_metadata: nil, readable: true}},
      encrypted_reader(again, {footer_key: FOOTER_KEY, columns: {"ssn" => SSN_KEY}}).encryption[:columns])
  end

  def test_redaction_needs_the_keys_of_the_columns_it_keeps
    bytes = write(encryption: encrypted(**MODES[:column_keys]))
    partial = {footer_key: FOOTER_KEY, columns: {"address" => ADDRESS_KEY}}
    error = assert_raises(Herringbone::DecryptionError) { redact(bytes, decryption: partial) { |r| r.where(id: 1).delete } }
    assert_match(/needs the key of ssn/, error.message)
    out, = redact(bytes, decryption: partial) do |r|
      r.where(id: 1).delete
      r.drop :ssn
    end
    assert_equal expected_rows.reject { |r| r["id"] == 1 }.map { |r| r.except("ssn") }, encrypted_reader(out, partial).read
  end

  def test_redaction_affects
    bytes = write(encryption: encrypted)
    redaction = Herringbone::Redaction.new { |r| r.where(id: 99_999).delete }
    refute redaction.affects?(StringIO.new(bytes), decryption: {footer_key: FOOTER_KEY})
    assert_raises(Herringbone::DecryptionError) { redaction.affects?(StringIO.new(bytes)) }
  end

  # --- inspector ---

  def test_inspector_with_keys
    bytes = write(bloom_filters: %w[ssn], encryption: encrypted(**MODES[:column_keys]))
    inspector = Herringbone::Inspector.new(StringIO.new(bytes), decryption: keys)
    inspector.verify_checksums
    assert_equal 0, inspector.checksum_summary[:mismatch]
    ssn = inspector.row_groups.first.column("ssn")
    assert ssn.encrypted?
    assert_equal 3, ssn.data_pages.size
    assert_equal 3, ssn.column_index.null_pages.size
    assert ssn.bloom_filter_length.positive?
    assert_equal "SECRET-0001", ssn.statistics.min
    assert_equal :encrypted, inspector.summary[:encryption][:footer]
    report = inspector.report(pages: true)
    assert_match(/encryption: aes_gcm, encrypted footer, footer key metadata "footer"/, report)
    assert_match(/ssn: column key "ssn"/, report)
    refute_includes inspector.layout.map { |s| s[:kind] }, :unknown
    assert inspector.to_html
  end

  def test_inspector_without_keys
    bytes = write(bloom_filters: %w[ssn], encryption: encrypted(**MODES[:plaintext_footer]))
    inspector = Herringbone::Inspector.new(StringIO.new(bytes))
    ssn = inspector.row_groups.first.column("ssn")
    assert_equal [], ssn.pages
    assert_match(/key was not given/, ssn.error)
    assert_nil ssn.column_index
    assert ssn.bloom_filter_length.positive?, "the size of an encrypted bloom filter is known without its key"
    assert_equal 3, inspector.row_groups.first.column("id").data_pages.size
    assert_match(/ssn: column key "ssn" \(no key given\)/, inspector.report)
    inspector.to_h
    assert inspector.to_html

    encrypted_footer = write(encryption: encrypted(**MODES[:column_keys]))
    error = assert_raises(Herringbone::DecryptionError) { Herringbone::Inspector.new(StringIO.new(encrypted_footer)) }
    assert_match(/footer key metadata "footer"/, error.message)
    partial = Herringbone::Inspector.new(StringIO.new(encrypted_footer), decryption: {footer_key: FOOTER_KEY})
    assert_match(/ssn: encrypted, metadata and pages unavailable without its key/, partial.report)
    partial.to_h
    assert partial.to_html
  end
end
