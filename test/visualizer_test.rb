# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "open3"
require "rbconfig"

class VisualizerTest < Minitest::Test
  Visualizer = Herringbone::Visualizer
  FIXTURES = Dir[File.join(FIXTURES_DIR, "{parquet-testing,generated}", "*.parquet")].sort
  BIN = File.expand_path("../bin/herringbone", __dir__)
  ALLOWED_URLS = [Visualizer::HIGHLIGHT_JS, Visualizer::CREDIT_URL].freeze

  def render(path, checksums: false)
    File.open(path, "rb") do |io|
      inspector = Herringbone::Inspector.new(io)
      inspector.verify_checksums if checksums
      inspector.to_html
    end
  end

  def embedded_data(html)
    json = html[%r{<script type="application/json" id="hb-data">(.*?)</script>}m, 1]
    refute_nil json, "no embedded data"
    JSON.parse(json)
  end

  def inline_script(html)
    html.scan(%r{<script>(.*?)</script>}m).flatten.first
  end

  def check_html(html, name)
    assert html.start_with?("<!doctype html>"), name
    assert html.rstrip.end_with?("</html>"), name
    %w[html head body style].each do |tag|
      assert_equal 1, html.scan(/<#{tag}[\s>]/).size, "#{name}: <#{tag}>"
      assert_equal 1, html.scan("</#{tag}>").size, "#{name}: </#{tag}>"
    end
    assert_equal html.scan(/<script[\s>]/).size, html.scan("</script>").size, name
    assert_equal 3, html.scan(/<script[\s>]/).size, name
    # No "</" can end the data script early: the JSON has every "<" escaped
    data_json = html[%r{id="hb-data">(.*?)</script>}m, 1]
    refute_includes data_json, "<", name
    urls = html.scan(%r{https?://[^\s"'<>)]+}).uniq
    assert_empty urls - ALLOWED_URLS, "#{name}: unexpected external URLs"
    assert_equal 1, html.scan(%(<script src="#{Visualizer::HIGHLIGHT_JS}")).size, name
    refute_match(/<link[^>]+stylesheet/, html, name)
  end

  def test_renders_every_fixture
    FIXTURES.each do |path|
      name = File.basename(path)
      html = render(path)
      check_html(html, name)
      data = embedded_data(html)
      assert_equal File.size(path), data["file"]["file_size"], name
      assert_equal name, data["file"]["name"]
      File.open(path, "rb") do |io|
        r = Herringbone::Reader.new(io)
        assert_equal r.num_rows, data["file"]["num_rows"], name
        assert_equal r.schema.columns.size, data["columns"].size, name
        assert_equal r.row_groups.size, data["row_groups"].size, name
      end
      data["row_groups"].each do |rg|
        rg["chunks"].each do |ch|
          next unless ch["pages"]
          assert_equal ch["np"], ch["pages"].size, name
          assert_equal ch["values"], ch["pages"].reject { |p| p[0] == 2 }.sum { |p| p[5] }, name
        end
      end
    end
  end

  def test_credit_is_prominent_at_the_top
    html = render(File.join(FIXTURES_DIR, "generated", "codec_snappy.parquet"))
    link = %(<a href="#{Visualizer::CREDIT_URL}")
    assert_includes html, link
    body = html[html.index("<body>")..]
    credit_at = body.index(link)
    assert_operator credit_at, :<, body.index("<section"), "credit comes before any content"
    assert_operator credit_at, :<, body.index("</header>"), "credit sits in the page header"
    assert_match(/Design and idea from <a href="#{Regexp.escape(Visualizer::CREDIT_URL)}"[^>]*>Parquet X-ray<\/a> by cfahlgren1/o, html)
  end

  def test_page_indexes_and_stats_are_embedded
    data = embedded_data(render(File.join(FIXTURES_DIR, "parquet-testing", "alltypes_tiny_pages.parquet")))
    assert data["file"]["page_index"]
    id = data["row_groups"][0]["chunks"][0]
    assert_equal "0", id["stats"]["min"]
    assert_equal "7299", id["stats"]["max"]
    assert_equal id["ndp"], id["offset_index"].size
    assert_equal id["ndp"], id["column_index"]["rows"].size
    strings = data["row_groups"][0]["chunks"].find { |c| data["columns"][c["c"]]["path"] == "string_col" }
    assert_equal '"0"', strings["stats"]["min"]
    refute_nil data["footer_json"]
    assert JSON.parse(data["footer_json"]).key?("schema")
  end

  def test_key_value_metadata_is_embedded_with_json_parsed
    data = embedded_data(render(File.join(FIXTURES_DIR, "parquet-testing", "int96_from_spark.parquet")))
    json_kv = data["kv"].find { |kv| kv["format"] == "json" }
    assert_kind_of Hash, json_kv["json"]
    arrow = embedded_data(render(File.join(FIXTURES_DIR, "generated", "logical_misc.parquet")))["kv"]
      .find { |kv| kv["key"] == "ARROW:schema" }
    assert_operator arrow["value"].size, :<, 200
  end

  def test_big_files_cap_page_detail
    path = File.join(FIXTURES_DIR, "parquet-testing", "overflow_i16_page_cnt.parquet")
    inspector = File.open(path, "rb") { |io| Herringbone::Inspector.new(io).load_all }
    full = embedded_data(Visualizer.new(inspector).to_html)
    refute full["file"]["pages_truncated"]
    assert_equal 40_000, full["row_groups"][0]["chunks"][0]["pages"].size
    capped_html = Visualizer.new(inspector, max_pages: 1000).to_html
    capped = embedded_data(capped_html)
    assert capped["file"]["pages_truncated"]
    assert_nil capped["row_groups"][0]["chunks"][0]["pages"]
    assert_equal 40_000, capped["row_groups"][0]["chunks"][0]["np"]
    assert_operator capped_html.bytesize, :<, 100_000
  end

  def test_html_escapes_hostile_names
    io = StringIO.new("".b)
    schema = Herringbone::Schema.define { string :"</script><script>alert(1)</script>" }
    Herringbone::Writer.open(io, schema) { |w| w << ["</script><!--"] }
    html = Visualizer.new(Herringbone::Inspector.new(StringIO.new(io.string)), title: "<b>%%DATA%%</b>").to_html
    check_html(html, "hostile")
    assert_includes html, "<title>&lt;b&gt;%%DATA%%&lt;/b&gt; · Parquet layout</title>"
    assert_equal "</script><script>alert(1)</script>", embedded_data(html)["columns"][0]["path"]
  end

  def test_works_without_codec_gems
    Herringbone::Compression.stub(:loaded_library, nil) do
      %w[codec_zstd codec_brotli enc_delta_mixed_v2_zstd].each do |f|
        html = render(File.join(FIXTURES_DIR, "generated", "#{f}.parquet"))
        check_html(html, f)
      end
    end
  end

  def test_to_html_is_titled_with_the_file_name
    path = File.join(FIXTURES_DIR, "generated", "nested_map_string_int.parquet")
    html = render(path)
    check_html(html, "to_html")
    assert_includes html, "<title>nested_map_string_int.parquet · Parquet layout</title>"
    from_string = Herringbone::Inspector.new(StringIO.new(File.binread(path)))
    assert_equal html, Visualizer.new(from_string, title: "nested_map_string_int.parquet").to_html
    assert_raises(ArgumentError) { Visualizer.new(path) }
  end

  def test_inline_javascript_is_valid
    node = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "node") }.find { |f| File.executable?(f) }
    skip "node is not installed" unless node
    js = inline_script(render(File.join(FIXTURES_DIR, "generated", "codec_snappy.parquet")))
    Dir.mktmpdir do |dir|
      file = File.join(dir, "page.js")
      File.write(file, js)
      out, status = Open3.capture2e(node, "--check", file)
      assert status.success?, out
    end
  end

  def test_cli
    path = File.join(FIXTURES_DIR, "parquet-testing", "data_index_bloom_encoding_stats.parquet")
    ruby = RbConfig.ruby
    text, status = Open3.capture2(ruby, BIN, "inspect", path)
    assert status.success?
    assert_match(/rows: 14, row groups: 1/, text)
    assert_match(/bloom filters: yes/, text)
    assert_match(/^schema:/, text)
    refute_match(/0: DATA_PAGE @4/, text)
    pages, = Open3.capture2(ruby, BIN, "inspect", path, "--pages")
    assert_match(/0: DATA_PAGE @4/, pages)
    explicit, status = Open3.capture2(ruby, BIN, "inspect", path, "--format=text", "--pages")
    assert status.success?
    assert_equal pages, explicit
    json, status = Open3.capture2(ruby, BIN, "inspect", path, "--format=json")
    assert status.success?
    assert_equal 14, JSON.parse(json)["summary"]["num_rows"]
    html, status = Open3.capture2(ruby, BIN, "inspect", path, "--format=html")
    assert status.success?
    check_html(html, "cli stdout")
    lines, status = Open3.capture2(ruby, BIN, "cat", path, "2")
    assert status.success?
    assert_equal 2, lines.lines.size
    assert_equal %w[String], JSON.parse(lines.lines.first).keys
    [
      %w[inspect --json], %w[inspect --html], %w[inspect --format=json --format=html], %w[inspect --format=xml],
      %w[inspect --format=json --pages], %w[inspect --text], %w[inspect], %w[schema], %w[meta], %w[cat --json], %w[cat x]
    ].each do |args|
      _, _, status = Open3.capture3(ruby, BIN, args[0], *((args[0] == "inspect" && args.size == 1) ? [] : [path]), *args.drop(1))
      refute status.success?, args.join(" ")
    end
    _, err, status = Open3.capture3(ruby, BIN, "inspect", "/nonexistent.parquet")
    refute status.success?
    assert_match(/\Aherringbone: /, err)
  end

  def test_checksums_are_verified_on_request
    path = File.join(FIXTURES_DIR, "parquet-testing", "datapage_v1-corrupt-checksum.parquet")
    plain = embedded_data(render(path))
    assert_nil plain["file"]["checksums"]
    assert_equal [1], plain["row_groups"].flat_map { |g| g["chunks"].flat_map { |c| c["pages"].map { |p| p[12] } } }.uniq
    html = render(path, checksums: true)
    check_html(html, "checksums")
    data = embedded_data(html)
    assert_equal({"ok" => 2, "mismatch" => 2, "absent" => 0}, data["file"]["checksums"])
    chunks = data["row_groups"][0]["chunks"]
    assert_equal [[3, 2], [2, 3]], chunks.map { |c| c["pages"].map { |p| p[12] } }
    assert_equal [1, 1], chunks.map { |c| c["crc_bad"] }
    ok = embedded_data(render(File.join(FIXTURES_DIR, "parquet-testing", "rle-dict-snappy-checksum.parquet"), checksums: true))
    assert_equal({"ok" => 2, "mismatch" => 0, "absent" => 2}, ok["file"]["checksums"])
    assert_equal [[2, 0], [2, 0]], ok["row_groups"][0]["chunks"].map { |c| c["pages"].map { |p| p[12] } }
  end

  def test_arrow_types_are_embedded
    data = embedded_data(render(File.join(FIXTURES_DIR, "generated", "logical_temporal.parquet")))
    assert_equal "timestamp[us, tz=America/New_York]", data["schema"].find { |n| n["name"] == "ts_us_tz_ny" }["arrow_type"]
    kv = data["kv"].find { |x| x["key"] == "ARROW:schema" }
    assert_equal 11, kv["arrow_schema"]["fields"].size
    assert_nil data["arrow_error"]
    io = StringIO.new("".b)
    Herringbone::Writer.open(io, Herringbone::Schema.define { int64 :id }, metadata: {"ARROW:schema" => "/////w=="}) { |w| w << [1] }
    broken = embedded_data(Herringbone::Inspector.new(StringIO.new(io.string)).to_html)
    assert_match(/could not decode ARROW:schema/, broken["arrow_error"])
    assert_match(/could not decode/, broken["kv"][0]["arrow_error"])
  end

  def test_index_mismatches_are_embedded
    path = File.join(FIXTURES_DIR, "parquet-testing", "repeated_primitive_no_list.parquet")
    i = File.open(path, "rb") { |io| Herringbone::Inspector.new(io).load_all }
    assert_equal 0, embedded_data(Visualizer.new(i).to_html)["file"]["index_mismatches"]
    c = i.row_groups[0].column("Int32_list")
    ci = c.column_index.dup
    ci.min_values = [3]
    c.instance_variable_set(:@column_index, ci)
    c.remove_instance_variable(:@index_mismatches)
    data = embedded_data(Visualizer.new(i).to_html)
    assert_equal 1, data["file"]["index_mismatches"]
    assert_equal [[1, "min", "0", "3"]], data["row_groups"][0]["chunks"][0]["idx_mm"]
  end

  def test_inline_javascript_is_valid_with_every_feature
    node = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "node") }.find { |f| File.executable?(f) }
    skip "node is not installed" unless node
    js = inline_script(render(File.join(FIXTURES_DIR, "parquet-testing", "datapage_v1-corrupt-checksum.parquet"), checksums: true))
    Dir.mktmpdir do |dir|
      file = File.join(dir, "page.js")
      File.write(file, js)
      out, status = Open3.capture2e(node, "--check", file)
      assert status.success?, out
    end
  end

  def test_cli_inspect_verify_checksums
    path = File.join(FIXTURES_DIR, "parquet-testing", "datapage_v1-corrupt-checksum.parquet")
    ruby = RbConfig.ruby
    text, status = Open3.capture2(ruby, BIN, "inspect", path, "--verify-checksums")
    assert status.success?
    assert_match(/page CRCs: 2 ok, 2 mismatched/, text)
    json, status = Open3.capture2(ruby, BIN, "inspect", path, "--format=json", "--verify-checksums")
    assert status.success?
    assert_equal 2, JSON.parse(json)["summary"]["checksums"]["mismatch"]
    plain, = Open3.capture2(ruby, BIN, "inspect", path, "--format=json")
    assert_nil JSON.parse(plain)["summary"]["checksums"]
    html, status = Open3.capture2(ruby, BIN, "inspect", path, "--format=html", "--verify-checksums")
    assert status.success?
    assert_equal 2, embedded_data(html)["file"]["checksums"]["mismatch"]
  end

  def test_unknown_page_types_keep_their_raw_type
    path = File.join(FIXTURES_DIR, "generated", "codec_snappy.parquet")
    File.open(path, "rb") do |io|
      inspector = Herringbone::Inspector.new(io)
      page = inspector.column_chunks.first.pages.first.dup
      page.type = 9
      row = Visualizer.new(inspector).send(:page_row, page)
      assert_equal 9, row[0]
      page.type = :INDEX_PAGE
      assert_equal 1, Visualizer.new(inspector).send(:page_row, page)[0]
    end
  end
end
