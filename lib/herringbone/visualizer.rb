# frozen_string_literal: true

require "json"

module Herringbone
  # Renders a Parquet file's layout as one self-contained HTML page: a to-scale byte map of the
  # file (row groups, column chunks, dictionary and data pages, page indexes, bloom filters,
  # footer), the schema, per-column and per-page tables, page indexes and key/value metadata.
  # CSS, JS and data are inline; the only external resource is highlight.js from cdnjs, used to
  # colour JSON (the page works without it).
  #
  # The design and idea come from Parquet X-ray by cfahlgren1
  # (https://huggingface.co/spaces/cfahlgren1/parquet-xray), credited at the top of every page.
  #
  # Used through Inspector#to_html:
  #
  #   File.open("data.parquet", "rb") { |io| Herringbone::Inspector.new(io).to_html }
  class Visualizer
    HIGHLIGHT_JS = "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"
    # The design and idea of this page come from Parquet X-ray; credited at the top of every page
    CREDIT_URL = "https://huggingface.co/spaces/cfahlgren1/parquet-xray"

    # Beyond this many pages in the file, per-page detail is kept only for the first chunks
    # (the rest are drawn as whole column chunks) to keep the page small
    MAX_PAGES = 60_000
    # Footer JSON is embedded only when the footer is smaller than this
    MAX_FOOTER_JSON = 512 * 1024

    PAGE_TYPES = {DATA_PAGE: 0, INDEX_PAGE: 1, DICTIONARY_PAGE: 2, DATA_PAGE_V2: 3}.freeze

    # +inspector+ is an Inspector. +title+ defaults to the file's name.
    def initialize(inspector, title: nil, max_pages: MAX_PAGES)
      raise ArgumentError, "Expected a Herringbone::Inspector, got #{inspector.class}" unless inspector.is_a?(Inspector)
      @inspector = inspector
      @title = title
      @max_pages = max_pages
    end

    def to_html
      json = JSON.generate(payload).gsub("<", "\\u003c").gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
      name = @title || @inspector.name || "Parquet file"
      values = {"TITLE" => escape_html("#{name} · Parquet layout"), "HIGHLIGHT_JS" => HIGHLIGHT_JS,
                "CREDIT_URL" => CREDIT_URL, "DATA" => json}
      # One pass, so placeholder-like text in the data is never substituted
      TEMPLATE.gsub(/%%(TITLE|HIGHLIGHT_JS|CREDIT_URL|DATA)%%/) { values.fetch(Regexp.last_match(1)) }
    end

    private

    # The data embedded in the page
    def payload
      i = @inspector
      budget = @max_pages
      totals = i.column_totals.to_h { |t| [t[:column], t] }
      {
        generator: "herringbone #{VERSION}",
        file: file_info,
        schema: i.schema_tree,
        columns: i.columns.map { |c| column_info(c, totals[c.index]) },
        row_groups: i.row_groups.map do |rg|
          {
            i: rg.index, rows: rg.num_rows, first_row: rg.first_row, start: rg.start_offset, end: rg.end_offset,
            cs: rg.compressed_size, us: rg.uncompressed_size, total_byte_size: rg.total_byte_size,
            file_offset: rg.row_group.file_offset, ordinal: rg.row_group.ordinal, sorting: rg.sorting_columns,
            chunks: rg.columns.map do |c|
              keep = c.pages.size <= budget
              budget -= c.pages.size if keep
              chunk_info(c, keep)
            end
          }
        end,
        kv: i.key_value_metadata,
        arrow_error: i.arrow_schema_error,
        footer_json: footer_json
      }
    end

    def file_info
      s = @inspector.summary
      name = @title || @inspector.name || "(IO)"
      s.merge(name: name, pages_truncated: @inspector.column_chunks.sum { |c| c.pages.size } > @max_pages,
        index_mismatches: @inspector.column_chunks.sum { |c| c.index_mismatches.size })
    end

    def column_info(col, t)
      node = col.node
      {
        i: col.index, path: col.dotted_path, name: node.name, type: Inspector.type_name(col),
        physical: Format::Type::NAMES[node.type].to_s, logical: Inspector.logical_type_name(node),
        repetition: node.repetition, max_def: col.max_definition_level, max_rep: col.max_repetition_level,
        sort_order: Inspector.sort_order(col),
        codecs: t[:codecs], encodings: t[:encodings], cs: t[:compressed_size], us: t[:uncompressed_size],
        values: t[:num_values], nulls: t[:null_count], pages: t[:num_pages], data_pages: t[:num_data_pages],
        dict_pages: t[:dictionary_pages], dict_bytes: t[:dictionary_bytes],
        min: disp(t[:min]), max: disp(t[:max])
      }
    end

    def chunk_info(c, with_pages)
      st = c.statistics
      h = {
        c: c.column.index, codec: c.codec.to_s, enc: c.encodings, estats: c.encoding_stats,
        values: c.num_values, nulls: c.null_count, cs: c.compressed_size, us: c.uncompressed_size,
        start: c.start_offset, end: c.end_offset, declared_end: c.declared_end_offset,
        data_off: c.data_page_offset, dict_off: c.dictionary_page_offset, file_offset: c.chunk.file_offset,
        stats: st && stats_info(st),
        bloom: c.bloom_filter_offset && [c.bloom_filter_offset, c.bloom_filter_length],
        ci: c.column_index_range, oi: c.offset_index_range,
        dict: c.dictionary_page && {n: c.dictionary_page.num_values, cs: c.dictionary_page.compressed_size,
                                    us: c.dictionary_page.uncompressed_size, sorted: c.dictionary_page.is_sorted},
        np: c.pages.size, ndp: c.data_pages.size,
        size_stats: c.size_statistics,
        kv: c.key_value_metadata.empty? ? nil : c.key_value_metadata,
        err: c.error,
        # [page, field, value in page header, value in column index]; page is nil for :page_count
        idx_mm: c.index_mismatches.empty? ? nil : c.index_mismatches.map { |m| mismatch_row(m) },
        crc_bad: c.pages.count { |p| p.checksum == :mismatch }.then { |n| n.zero? ? nil : n }
      }
      if with_pages
        h[:pages] = c.pages.map { |p| page_row(p) }
        if (ci = c.column_index)
          h[:column_index] = {
            boundary: ci.boundary_order,
            rows: ci.null_pages.each_index.map do |k|
              [ci.null_pages[k] ? 1 : 0, disp(ci.min_values[k]), disp(ci.max_values[k]), ci.null_counts&.[](k)]
            end
          }
        end
        if (oi = c.offset_index)
          h[:offset_index] = oi.page_locations.map { |l| [l.offset, l.compressed_page_size, l.first_row_index] }
        end
      end
      Inspector.jsonable(h.compact)
    end

    def stats_info(st)
      {
        min: disp(st.min), max: disp(st.max), nulls: st.null_count, distinct: st.distinct_count,
        min_exact: st.min_exact, max_exact: st.max_exact, source: st.source, caveat: st.caveat
      }.compact
    end

    # [type, offset, header_size, compressed, uncompressed, values, nulls, rows, first_row, encoding,
    #  min, max, crc, extra]; crc is 0 (none), 1 (present, not verified), 2 (verified ok) or 3 (mismatch)
    def page_row(p)
      st = p.statistics
      extra = if p.type == :DATA_PAGE_V2
        "levels #{p.repetition_levels_byte_length}+#{p.definition_levels_byte_length} B" \
          "#{", not compressed" unless p.is_compressed}"
      elsif p.type == :DATA_PAGE
        [p.definition_level_encoding && "def #{p.definition_level_encoding}",
          p.repetition_level_encoding && "rep #{p.repetition_level_encoding}"].compact.join(", ")
      elsif p.dictionary?
        p.is_sorted ? "sorted" : nil
      end
      [PAGE_TYPES.fetch(p.type, 1), p.offset, p.header_size, p.compressed_size, p.uncompressed_size, p.num_values,
        p.num_nulls, p.num_rows, p.first_row_index, p.encoding, st && disp(st.min), st && disp(st.max),
        CRC_STATES.fetch(p.checksum) { p.crc.nil? ? 0 : 1 }, extra]
    end

    CRC_STATES = {absent: 0, ok: 2, mismatch: 3}.freeze

    def mismatch_row(m)
      values = [m[:page_value], m[:index_value]]
      values = values.map { |v| disp(v) } if m[:field] == :min || m[:field] == :max
      [m[:page], m[:field].to_s, *values]
    end

    # Display form of a decoded statistics value: strings quoted, the rest as text
    def disp(v)
      s = case v
      when nil then return nil
      when String
        t = Inspector.text(v)
        (v.encoding == Encoding::BINARY && t.start_with?("0x")) ? t : JSON.generate(t)
      when Float then v.nan? ? "NaN" : v.to_s
      when BigDecimal then v.to_s("F")
      when Time then Inspector.jsonable(v)
      when Date then v.iso8601
      when Array then JSON.generate(Inspector.jsonable(v))
      else v.to_s
      end
      (s.size > 160) ? "#{s[0, 159]}…" : s
    end

    def footer_json
      return nil if @inspector.footer_size > MAX_FOOTER_JSON
      JSON.pretty_generate(Inspector.jsonable(raw(@inspector.metadata.to_h)))
    end

    # Footer structs as plain data; binary statistics as hex, long strings shortened
    def raw(v)
      case v
      when Hash then v.to_h { |k, x| [k, raw(x)] }
      when Array then v.map { |x| raw(x) }
      when String
        t = Inspector.text(v)
        (t.size > 300) ? "#{t[0, 300]}… (#{v.bytesize} bytes)" : t
      else v
      end
    end

    def escape_html(s)
      s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    TEMPLATE = <<~'HTML'
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>%%TITLE%%</title>
      <style>
      :root {
        --ink: #111827; --secondary: #374151; --subtle: #6b7280; --faint: #9ca3af;
        --line: #e5e7eb; --line-soft: #f1f2f4; --bg: #ffffff; --surface: #ffffff; --surface-alt: #f9fafb;
        --accent: #4f46e5; --accent-soft: #eef2ff; --accent-line: #c7d2fe;
        --ok: #047857; --ok-soft: #ecfdf5; --ok-line: #a7f3d0; --warn: #b45309; --warn-soft: #fffbeb; --err: #b91c1c; --err-soft: #fef2f2;
        --strip-bg: #f3f4f6; --seam: rgba(255,255,255,.85); --outline: #111827;
        --k-dict: #e2e5ea; --k-data: #c3c8d0; --k-ci: #d8b4fe; --k-oi: #93c5fd; --k-bloom: #6ee7b7;
        --k-cmeta: #fcd9a8; --k-footer: #4b5563; --k-flen: #1f2937; --k-magic: #111827; --k-unknown: #fca5a5;
        --kw: #e11d48; --ty: #7c3aed; --ann: #0d9488; --num: #b45309; --str: #047857;
        --shadow: 0 10px 30px -10px rgb(17 24 39 / 25%), 0 2px 6px rgb(17 24 39 / 6%);
        --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --ink: #e5e7eb; --secondary: #cbd2dc; --subtle: #9aa3b2; --faint: #6b7483;
          --line: #2a2f38; --line-soft: #20252c; --bg: #0e1116; --surface: #13171d; --surface-alt: #181d24;
          --accent: #8b93ff; --accent-soft: #1d2140; --accent-line: #3b418a;
          --ok: #34d399; --ok-soft: #0d2a22; --ok-line: #1f5d4a; --warn: #fbbf24; --warn-soft: #2a2110; --err: #f87171; --err-soft: #2c1414;
          --strip-bg: #1b2028; --seam: rgba(14,17,22,.8); --outline: #f9fafb;
          --k-dict: #394150; --k-data: #566072; --k-ci: #7e5aa8; --k-oi: #3f6fa8; --k-bloom: #2f8f6c;
          --k-cmeta: #7a5a2e; --k-footer: #9ca3af; --k-flen: #d1d5db; --k-magic: #f3f4f6; --k-unknown: #b45353;
          --kw: #fb7185; --ty: #c4b5fd; --ann: #5eead4; --num: #fbbf24; --str: #6ee7b7;
          --shadow: 0 10px 30px -10px rgb(0 0 0 / 70%), 0 2px 6px rgb(0 0 0 / 40%);
        }
      }
      * { box-sizing: border-box; }
      html { scrollbar-gutter: stable; }
      body { margin: 0; background: var(--bg); color: var(--ink); font: 13px/1.45 Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
      button, input, select { font: inherit; color: inherit; }
      .wrap { max-width: 1320px; margin: 0 auto; padding: 24px 24px 64px; }
      header.top { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 18px; }
      header.top h1 { margin: 0; font-size: 20px; letter-spacing: -.01em; display: flex; align-items: center; gap: 10px; }
      .logo { width: 18px; height: 18px; border-radius: 3px; background: repeating-linear-gradient(135deg, var(--accent) 0 3px, transparent 3px 6px), var(--accent-soft); outline: 1px solid var(--accent-line); }
      header.top .sub { color: var(--subtle); }
      .credit { flex-basis: 100%; margin: 4px 0 0; padding: 6px 10px; border-radius: 8px; background: var(--accent-soft); border: 1px solid var(--accent-line); color: var(--secondary); font-size: 12.5px; }
      .credit a { color: var(--accent); font-weight: 600; }
      h2 { margin: 0 0 8px; font-size: 14px; display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
      h2 small { font-size: 12px; font-weight: 400; color: var(--faint); }
      section { margin-bottom: 22px; }
      .card { border: 1px solid var(--line); border-radius: 12px; background: var(--surface); }
      .pad { padding: 14px 16px; }
      .mono { font-family: var(--mono); }
      .faint { color: var(--faint); } .subtle { color: var(--subtle); }
      .num { font-variant-numeric: tabular-nums; }
      .summary header { display: flex; gap: 10px; align-items: center; padding: 10px 16px; background: var(--surface-alt); border-bottom: 1px solid var(--line); border-radius: 12px 12px 0 0; flex-wrap: wrap; }
      .summary header h2 { margin: 0; font-family: var(--mono); font-size: 14px; }
      .stats { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)) minmax(0, 1.8fr); gap: 12px; padding: 12px 16px; margin: 0; }
      .stats dt { font-size: 11.5px; color: var(--subtle); }
      .stats dd { margin: 2px 0 0; font-size: 15px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .stats dd.mono { font-size: 12.5px; font-weight: 500; margin-top: 4px; }
      .badges { display: flex; flex-wrap: wrap; gap: 8px; padding: 0 16px 14px; }
      .badge { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--line); border-radius: 999px; padding: 3px 11px; font-size: 12.5px; color: var(--subtle); }
      .badge.ok { background: var(--ok-soft); border-color: var(--ok-line); color: var(--ok); }
      .badge.warn { background: var(--warn-soft); border-color: var(--warn); color: var(--warn); }
      .badge.err { background: var(--err-soft); border-color: var(--err); color: var(--err); }
      .badge code { font-family: var(--mono); font-size: 12px; }
      .map-grid { display: grid; grid-template-columns: minmax(0, 1fr) 240px; gap: 16px; }
      .strip-label { display: flex; justify-content: space-between; gap: 8px; font-size: 11px; color: var(--faint); margin-bottom: 4px; }
      .strip-label b { color: var(--secondary); font-weight: 500; }
      .strip { height: 40px; position: relative; }
      .strip canvas { display: block; width: 100%; height: 100%; border-radius: 3px; cursor: crosshair; }
      .strip.pick canvas { cursor: pointer; }
      .zoom { margin-top: 14px; }
      .zoom .strip { height: 30px; }
      .legend { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-top: 10px; font-size: 11.5px; color: var(--subtle); align-items: center; }
      .legend .sw { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
      .legend .item { cursor: pointer; white-space: nowrap; }
      .legend .item.dim { opacity: .4; }
      .legend .kinds { margin-left: auto; display: inline-flex; flex-wrap: wrap; gap: 4px 13px; color: var(--faint); }
      .hint { margin: 6px 0 0; font-size: 11.5px; color: var(--faint); }
      .two { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 20px; align-items: start; }
      .schema { background: var(--surface-alt); border-radius: 8px; outline: 1px solid var(--line); padding: 6px 0; font-family: var(--mono); font-size: 12.5px; }
      .sline { display: grid; grid-template-columns: 30px minmax(0, 1fr) 140px; align-items: center; min-height: 24px; width: 100%; border: 0; background: transparent; text-align: left; padding: 0; }
      button.sline { cursor: pointer; }
      button.sline:hover, .sline.sel { background: var(--accent-soft); }
      .sline.sel { box-shadow: inset 3px 0 0 var(--accent); }
      .sline .ln { text-align: right; padding-right: 10px; color: var(--faint); opacity: .6; }
      .sline .code { white-space: pre; overflow: hidden; text-overflow: ellipsis; padding-right: 12px; }
      .sline .kw { color: var(--kw); } .sline .ty { color: var(--ty); } .sline .ann { color: var(--ann); } .sline .nm { font-weight: 600; }
      .sline .lv { color: var(--faint); font-size: 11px; }
      .sline .size { display: flex; align-items: center; gap: 8px; padding-right: 12px; font-size: 11px; color: var(--faint); }
      .bar { position: relative; flex: 1; height: 4px; border-radius: 1px; background: var(--line-soft); }
      .bar > span { position: absolute; top: 0; bottom: 0; left: 0; min-width: 1px; border-radius: 1px; }
      .sline .size .v { width: 64px; text-align: right; white-space: nowrap; }
      .rgs { overflow: hidden; }
      .rg-row { display: grid; grid-template-columns: 14px 44px minmax(0, 1.1fr) minmax(0, 1fr) 76px; gap: 10px; align-items: center; height: 30px; width: 100%; padding: 0 12px; border: 0; border-bottom: 1px solid var(--line-soft); background: transparent; text-align: left; cursor: pointer; }
      .rg-row:hover { background: var(--surface-alt); }
      .rg-row.open { background: var(--accent-soft); }
      .rg-row .caret { font-size: 10px; color: var(--faint); }
      .rg-row .gbar { height: 8px; border-radius: 1px; display: block; }
      .rg-body { padding: 8px 12px 12px 36px; border-bottom: 1px solid var(--line-soft); background: var(--surface-alt); }
      .kvline { display: flex; flex-wrap: wrap; gap: 4px 18px; margin-bottom: 6px; }
      .kvline .k { color: var(--faint); margin-right: 4px; }
      .chunk-row { display: grid; grid-template-columns: 130px minmax(0, 1fr) 70px; grid-template-areas: "name pages size" "name minmax info"; gap: 2px 12px; padding: 6px 4px; border-bottom: 1px solid var(--line-soft); cursor: pointer; border-radius: 4px; }
      .chunk-row:last-child { border-bottom: 0; }
      .chunk-row:hover { background: var(--surface); }
      .chunk-row.sel { background: var(--accent-soft); }
      .chunk-row .name { grid-area: name; font-family: var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; align-self: start; }
      .chunk-row .pages { grid-area: pages; display: flex; gap: 1px; height: 10px; align-items: stretch; }
      .chunk-row .pages > span { min-width: 2px; border-radius: 1px; }
      .chunk-row .size { grid-area: size; text-align: right; font-family: var(--mono); }
      .chunk-row .minmax { grid-area: minmax; font-family: var(--mono); font-size: 11px; color: var(--subtle); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .chunk-row .info { grid-area: info; text-align: right; font-size: 11px; color: var(--faint); white-space: nowrap; }
      .more { margin: 6px 0 0; border: 0; background: transparent; color: var(--accent); cursor: pointer; padding: 4px; font-size: 12px; }
      .tablewrap { overflow-x: auto; }
      table { border-collapse: collapse; width: 100%; font-size: 12px; }
      th { text-align: left; font-weight: 500; font-size: 11px; color: var(--faint); padding: 6px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; position: sticky; top: 0; background: var(--surface); }
      td { padding: 5px 8px; border-bottom: 1px solid var(--line-soft); vertical-align: top; }
      td.r, th.r { text-align: right; }
      td.mono { font-size: 11.5px; }
      td.clip { max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      tbody tr.click { cursor: pointer; }
      tbody tr.click:hover { background: var(--surface-alt); }
      tbody tr.sel { background: var(--accent-soft); }
      tbody tr.hl { outline: 2px solid var(--accent); outline-offset: -2px; }
      .ratio { display: flex; align-items: center; gap: 6px; min-width: 110px; }
      .ratio .bar { height: 6px; }
      .pill { display: inline-block; padding: 0 6px; border-radius: 4px; background: var(--line-soft); font-family: var(--mono); font-size: 11px; margin: 1px 2px 1px 0; white-space: nowrap; }
      .pill.warn { background: var(--warn-soft); color: var(--warn); }
      .pill.err { color: var(--err); background: var(--err-soft); }
      .pill.ok { color: var(--ok); background: var(--ok-soft); }
      .sline .arrow { color: var(--faint); }
      .sw-inline { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 6px; vertical-align: 0; }
      .detail .dl { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 8px 18px; margin: 0 0 12px; }
      .detail .dl dt { font-size: 11px; color: var(--faint); }
      .detail .dl dd { margin: 1px 0 0; font-family: var(--mono); font-size: 12px; overflow-wrap: anywhere; }
      .note { font-size: 12px; padding: 6px 10px; border-radius: 6px; background: var(--warn-soft); color: var(--warn); margin: 6px 0; }
      .note.err { color: var(--err); }
      .tabs { display: flex; gap: 4px; margin: 10px 0 8px; border-bottom: 1px solid var(--line); }
      .tabs button { border: 0; background: transparent; padding: 6px 10px; cursor: pointer; color: var(--subtle); border-bottom: 2px solid transparent; margin-bottom: -1px; }
      .tabs button.on { color: var(--ink); border-bottom-color: var(--accent); }
      .pager { display: flex; gap: 8px; align-items: center; margin-top: 8px; font-size: 12px; color: var(--subtle); }
      .pager button { border: 1px solid var(--line); background: var(--surface); border-radius: 6px; padding: 2px 10px; cursor: pointer; }
      .pager button:disabled { opacity: .4; cursor: default; }
      .kv { border-top: 1px solid var(--line-soft); padding: 10px 0; }
      .kv:first-child { border-top: 0; padding-top: 0; }
      .kv .head { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; margin-bottom: 6px; }
      .kv .key { font-family: var(--mono); font-weight: 600; }
      pre { margin: 0; max-height: 420px; overflow: auto; background: var(--surface-alt); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font: 12px/1.5 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; }
      pre code { font: inherit; background: none; padding: 0; }
      details > summary { cursor: pointer; color: var(--subtle); margin-bottom: 8px; }
      .hljs-attr { color: var(--ty); } .hljs-string { color: var(--str); } .hljs-number, .hljs-literal { color: var(--num); } .hljs-keyword { color: var(--kw); } .hljs-punctuation { color: var(--faint); }
      #pop { position: fixed; z-index: 10; pointer-events: none; min-width: 240px; max-width: 420px; background: var(--surface); border: 1px solid var(--line); border-radius: 10px; box-shadow: var(--shadow); padding: 10px 12px; font-size: 12px; display: none; }
      #pop .t { font-weight: 600; font-size: 13px; display: flex; align-items: center; gap: 6px; margin-bottom: 2px; }
      #pop .p { font-family: var(--mono); color: var(--subtle); font-size: 11.5px; }
      #pop .w { color: var(--secondary); margin: 6px 0; }
      #pop dl { display: grid; grid-template-columns: auto 1fr; gap: 1px 12px; margin: 6px 0 0; }
      #pop dt { color: var(--faint); } #pop dd { margin: 0; font-family: var(--mono); overflow-wrap: anywhere; }
      footer.foot { color: var(--faint); font-size: 11.5px; margin-top: 30px; }
      @media (max-width: 900px) {
        .two, .map-grid { grid-template-columns: minmax(0, 1fr); }
        .stats { grid-template-columns: repeat(3, minmax(0, 1fr)); }
        .stats .wide { grid-column: 1 / -1; }
      }
      @media (max-width: 600px) {
        .wrap { padding: 16px 12px 48px; }
        .sline { grid-template-columns: 24px minmax(0, 1fr) 70px; }
        .sline .size .bar { display: none; }
        .rg-row { grid-template-columns: 14px 36px minmax(0, 1fr) 70px; }
        .rg-row .gcell { display: none; }
        .chunk-row { grid-template-columns: minmax(0, 1fr) 64px; grid-template-areas: "name size" "pages pages" "minmax info"; }
      }
      </style>
      </head>
      <body>
      <div class="wrap">
        <header class="top">
          <h1><span class="logo" aria-hidden="true"></span>Parquet layout</h1>
          <span class="sub">Footer, page headers and page indexes only &middot; no values were decoded</span>
          <p class="credit" id="credit">Design and idea from <a href="%%CREDIT_URL%%" rel="noopener">Parquet X-ray</a> by cfahlgren1 &mdash; this page reimplements its file map, schema and row group views for Herringbone.</p>
        </header>
        <section class="card summary" id="summary"></section>
        <section class="card pad" id="map"></section>
        <div class="two">
          <section id="schema"></section>
          <section id="rowgroups"></section>
        </div>
        <section id="detail"></section>
        <section id="columns"></section>
        <section id="kv"></section>
        <section id="footer"></section>
        <footer class="foot" id="gen"></footer>
      </div>
      <div id="pop" role="tooltip"></div>
      <noscript><p style="padding:24px">This page needs JavaScript to draw the file layout.</p></noscript>
      <script type="application/json" id="hb-data">%%DATA%%</script>
      <script>
      (function () {
        "use strict";
        var D = JSON.parse(document.getElementById("hb-data").textContent);
        var F = D.file;
        var S = { rg: null, col: null, page: null, tab: "pages", pageOffset: 0, allRgs: false, allCols: false, allSchema: false, allChunkRgs: false };

        // ---------- helpers ----------
        function h(tag, props) {
          var el = document.createElement(tag);
          if (props) for (var k in props) {
            var v = props[k];
            if (v == null || v === false) continue;
            if (k === "class") el.className = v;
            else if (k === "text") el.textContent = v;
            else if (k === "style") el.setAttribute("style", v);
            else if (k.slice(0, 2) === "on") el.addEventListener(k.slice(2), v);
            else el.setAttribute(k, v === true ? "" : v);
          }
          for (var i = 2; i < arguments.length; i++) add(el, arguments[i]);
          return el;
        }
        function add(el, c) {
          if (c == null || c === false) return;
          if (Array.isArray(c)) { c.forEach(function (x) { add(el, x); }); return; }
          el.appendChild(typeof c === "object" ? c : document.createTextNode(String(c)));
        }
        function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
        function num(n) { return n == null ? "–" : Number(n).toLocaleString("en-US"); }
        function bytes(n) {
          if (n == null) return "–";
          var u = ["B", "KB", "MB", "GB", "TB"], i = 0, f = Number(n);
          while (f >= 1024 && i < u.length - 1) { f /= 1024; i++; }
          return i === 0 ? f + " B" : f.toFixed(f < 10 ? 2 : 1) + " " + u[i];
        }
        function pct(a, b) { if (!b) return "–"; var p = a / b * 100; return (p < 0.1 && p > 0 ? "<0.1" : p.toFixed(p < 10 ? 1 : 0)) + "%"; }
        function ratio(us, cs) { return cs ? (us / cs).toFixed(2) + "×" : "–"; }
        function plural(n, w) { return num(n) + " " + w + (n === 1 ? "" : "s"); }
        var dark = window.matchMedia && matchMedia("(prefers-color-scheme: dark)");
        function isDark() { return !!(dark && dark.matches); }
        function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

        // ---------- colours ----------
        var HUES = [215, 28, 150, 330, 262, 45, 180, 0, 95, 300, 195, 60];
        function colColor(c, dict, ignoreSel) {
          var hue = HUES[c % HUES.length], d = isDark();
          if (ignoreSel || S.col == null) return d ? "hsl(" + hue + " 32% " + (dict ? 30 : 46) + "%)" : "hsl(" + hue + " 45% " + (dict ? 87 : 74) + "%)";
          if (c === S.col) return d ? "hsl(" + hue + " 60% " + (dict ? 40 : 60) + "%)" : "hsl(" + hue + " 60% " + (dict ? 80 : 60) + "%)";
          return dict ? (d ? "#22272f" : "#eef0f3") : (d ? "#2c323c" : "#dfe2e6");
        }
        var KINDS = {
          dict: { label: "Dictionary page", v: "--k-dict", what: "Each distinct value stored once; the data pages after it store small integer ids that point here." },
          data: { label: "Data page", v: "--k-data", what: "The unit a reader fetches and decompresses: a page header followed by levels and values." },
          chunk: { label: "Column chunk", v: "--k-data", what: "Pages of this chunk were not listed individually." },
          ci: { label: "Column index", v: "--k-ci", what: "Min, max and null count for every page of one column chunk, so readers can skip pages that can't match a filter." },
          oi: { label: "Offset index", v: "--k-oi", what: "Byte offset and first row of every page of one column chunk, so readers can jump straight to a row." },
          bloom: { label: "Bloom filter", v: "--k-bloom", what: "Answers \"is this value definitely absent?\" so = and IN lookups can skip a whole row group." },
          footer: { label: "Footer", v: "--k-footer", what: "Thrift-encoded FileMetaData: the schema, every row group and column chunk, their statistics and the offsets of everything else." },
          flen: { label: "Footer length", v: "--k-flen", what: "4-byte little-endian length of the footer. Readers fetch the last 8 bytes first to find it." },
          magic: { label: "PAR1 magic", v: "--k-magic", what: "4 bytes that open and close every Parquet file." },
          cmeta: { label: "Column metadata copy", v: "--k-cmeta", what: "A copy of the chunk's ColumnMetaData written right after its pages (ColumnChunk.file_offset points here). Readers use the footer's copy." },
          unknown: { label: "Unaccounted bytes", v: "--k-unknown", what: "Bytes not covered by any page, index or footer (padding, or data the metadata doesn't describe)." }
        };
        function kindColor(k) { return cssVar(KINDS[k].v); }
        function segColor(s) {
          if (s.k === "data" || s.k === "chunk") return colColor(s.c, false);
          if (s.k === "dict") return colColor(s.c, true);
          if ((s.k === "ci" || s.k === "oi" || s.k === "bloom" || s.k === "cmeta") && S.col != null && s.c !== S.col) return isDark() ? "#2c323c" : "#dfe2e6";
          return kindColor(s.k);
        }

        // ---------- byte segments ----------
        var PT = ["DATA_PAGE", "INDEX_PAGE", "DICTIONARY_PAGE", "DATA_PAGE_V2"];
        var CRC = ["", "present, not verified", "ok", "MISMATCH"];
        var segs = [{ k: "magic", s: 0, e: 4 }];
        D.row_groups.forEach(function (rg) {
          rg.chunks.forEach(function (ch) {
            if (ch.pages && ch.pages.length) {
              ch.pages.forEach(function (p, i) {
                segs.push({ k: p[0] === 2 ? "dict" : "data", s: p[1], e: p[1] + p[2] + p[3], rg: rg.i, c: ch.c, p: i });
              });
            } else if (ch.cs > 0) {
              segs.push({ k: "chunk", s: ch.start, e: ch.end, rg: rg.i, c: ch.c });
            }
            if (ch.bloom && ch.bloom[1]) segs.push({ k: "bloom", s: ch.bloom[0], e: ch.bloom[0] + ch.bloom[1], rg: rg.i, c: ch.c });
            if (ch.ci) segs.push({ k: "ci", s: ch.ci[0], e: ch.ci[0] + ch.ci[1], rg: rg.i, c: ch.c });
            if (ch.oi) segs.push({ k: "oi", s: ch.oi[0], e: ch.oi[0] + ch.oi[1], rg: rg.i, c: ch.c });
          });
        });
        segs.push({ k: "footer", s: F.footer_offset, e: F.footer_offset + F.footer_size });
        segs.push({ k: "flen", s: F.file_size - 8, e: F.file_size - 4 });
        segs.push({ k: "magic", s: F.file_size - 4, e: F.file_size });
        segs.sort(function (a, b) { return a.s - b.s || a.e - b.e; });
        (function () {
          // gaps starting at a chunk's file_offset hold an inline copy of its ColumnMetaData
          var metaAt = {};
          D.row_groups.forEach(function (rg) { rg.chunks.forEach(function (ch) { if (ch.file_offset != null && ch.file_offset >= ch.end) metaAt[ch.file_offset] = { rg: rg.i, c: ch.c }; }); });
          var out = [], pos = 0;
          segs.forEach(function (s) {
            if (s.s > pos) { var m = metaAt[pos]; out.push(m ? { k: "cmeta", s: pos, e: s.s, rg: m.rg, c: m.c } : { k: "unknown", s: pos, e: s.s }); }
            out.push(s); pos = Math.max(pos, s.e);
          });
          segs = out;
        })();
        var dataEnd = 4;
        segs.forEach(function (s) { if (s.k === "data" || s.k === "dict" || s.k === "chunk") dataEnd = Math.max(dataEnd, s.e); });
        var tailStart = F.footer_offset;
        segs.forEach(function (s) { if (s.s >= dataEnd && s.s < tailStart && s.k !== "unknown") tailStart = s.s; });
        var bodySegs = segs.filter(function (s) { return s.s < tailStart; });
        var tailSegs = segs.filter(function (s) { return s.s >= tailStart; });
        function lowerBound(list, off) { var lo = 0, hi = list.length; while (lo < hi) { var m = (lo + hi) >> 1; if (list[m].e <= off) lo = m + 1; else hi = m; } return lo; }
        function segsIn(list, from, to) { var out = []; for (var i = lowerBound(list, from); i < list.length && list[i].s < to; i++) out.push(list[i]); return out; }

        // ---------- canvas strips ----------
        var strips = [];
        function Strip(host, from, to, list, opts) {
          this.host = host; this.from = from; this.to = Math.max(to, from + 1); this.list = list; this.opts = opts || {};
          this.canvas = h("canvas", { "aria-label": this.opts.label || "byte layout" });
          host.appendChild(this.canvas);
          var self = this;
          this.canvas.addEventListener("pointermove", function (ev) { if (ev.pointerType !== "mouse") return; var s = self.at(ev); self.hover = s; self.paint(); showPop(s, ev); });
          this.canvas.addEventListener("pointerleave", function () { self.hover = null; self.paint(); hidePop(); });
          this.canvas.addEventListener("click", function (ev) { var s = self.at(ev); if (self.opts.onpick) self.opts.onpick(s, ev); else showPop(s, ev); });
          strips.push(this);
          this.render();
        }
        Strip.prototype.at = function (ev) {
          var r = this.canvas.getBoundingClientRect();
          var span = this.to - this.from, off = this.from + (ev.clientX - r.left) / r.width * span, slack = span / r.width * 2;
          var list = this.list, lo = 0, hi = list.length - 1, best = -1;
          while (lo <= hi) { var m = (lo + hi) >> 1; if (list[m].s <= off) { best = m; lo = m + 1; } else hi = m - 1; }
          var hit = list[best];
          if (hit && off <= hit.e + slack) return hit;
          var next = list[best + 1];
          return next && next.s - off < slack ? next : null;
        };
        Strip.prototype.render = function () {
          var w = this.host.clientWidth, hh = this.host.clientHeight;
          if (!w || !hh) return;
          var dpr = window.devicePixelRatio || 1, W = Math.round(w * dpr), H = Math.round(hh * dpr);
          var base = document.createElement("canvas"); base.width = W; base.height = H;
          var ctx = base.getContext("2d"), from = this.from, to = this.to, list = this.list;
          ctx.fillStyle = cssVar("--strip-bg"); ctx.fillRect(0, 0, W, H);
          // each device pixel takes the colour of the segment covering most of its bytes
          var bpp = (to - from) / W, first = 0, runStart = 0, runColor = null;
          for (var px = 0; px < W; px++) {
            var b0 = from + px * bpp, b1 = b0 + bpp, best = null, bestBytes = 0;
            while (first < list.length && list[first].e <= b0) first++;
            for (var i = first; i < list.length && list[i].s < b1; i++) {
              var sg = list[i], cov = Math.min(b1, sg.e) - Math.max(b0, sg.s);
              if (cov > bestBytes) { bestBytes = cov; best = sg; }
            }
            var col = best ? segColor(best) : null;
            if (col !== runColor) { if (runColor) { ctx.fillStyle = runColor; ctx.fillRect(runStart, 0, px - runStart, H); } runStart = px; runColor = col; }
          }
          if (runColor) { ctx.fillStyle = runColor; ctx.fillRect(runStart, 0, W - runStart, H); }
          ctx.fillStyle = cssVar("--seam");
          var x = function (o) { return (o - from) / (to - from) * W; };
          for (var j = 0; j < list.length; j++) { var a = x(list[j].s), b = x(list[j].e); if (b - a > 4 * dpr) ctx.fillRect(a, 0, dpr, H); }
          if (this.opts.targets) {
            ctx.fillStyle = cssVar("--bg");
            this.opts.targets.forEach(function (t) { if (x(t.e) - x(t.s) > 3 * dpr) ctx.fillRect(x(t.s), 0, 1.5 * dpr, H); });
          }
          this.base = base; this.dpr = dpr;
          this.paint();
        };
        Strip.prototype.paint = function () {
          if (!this.base) return;
          var c = this.canvas, dpr = this.dpr, ctx = c.getContext("2d");
          c.width = this.base.width; c.height = this.base.height;
          ctx.drawImage(this.base, 0, 0);
          var from = this.from, to = this.to, W = c.width, H = c.height;
          var x = function (o) { return (o - from) / (to - from) * W; };
          ctx.lineWidth = 2 * dpr;
          var outline = function (s, color) { if (!s) return; ctx.strokeStyle = color; ctx.strokeRect(Math.max(0, x(s.s)) + dpr, dpr, Math.max(Math.min(W, x(s.e)) - Math.max(0, x(s.s)) - 2 * dpr, 2 * dpr), H - 2 * dpr); };
          outline(this.opts.selected && this.opts.selected(), cssVar("--accent"));
          outline(this.hover, cssVar("--outline"));
        };
        function redrawStrips() { strips = strips.filter(function (s) { return s.canvas.isConnected; }); strips.forEach(function (s) { s.render(); }); }
        var rsTimer;
        window.addEventListener("resize", function () { clearTimeout(rsTimer); rsTimer = setTimeout(redrawStrips, 60); });
        if (dark && dark.addEventListener) dark.addEventListener("change", function () { renderAll(); });

        // ---------- popover ----------
        var pop = document.getElementById("pop");
        function colPath(c) { return D.columns[c] ? D.columns[c].path : "#" + c; }
        function chunkOf(rg, c) { var g = D.row_groups[rg]; return g && g.chunks.find(function (x) { return x.c === c; }); }
        function showPop(s, ev) {
          if (!s) { hidePop(); return; }
          var K = KINDS[s.k], rows = [];
          rows.push(["Bytes", num(s.s) + " – " + num(s.e)]);
          rows.push(["Size", bytes(s.e - s.s) + " · " + pct(s.e - s.s, F.file_size) + " of file"]);
          var ch = s.rg != null ? chunkOf(s.rg, s.c) : null;
          if (ch && (s.k === "data" || s.k === "dict") && ch.pages) {
            var p = ch.pages[s.p];
            rows.push(["Header", bytes(p[2])]);
            rows.push(["Body", bytes(p[3]) + " (" + bytes(p[4]) + " uncompressed)"]);
            rows.push([s.k === "dict" ? "Entries" : "Values", num(p[5]) + (p[6] != null ? " · " + num(p[6]) + " nulls" : "")]);
            if (p[7] != null && s.k !== "dict") rows.push(["Rows", num(p[7]) + (p[8] != null ? " from row " + num(p[8]) : "")]);
            rows.push(["Encoding", p[9] || "–"]);
            if (p[12]) rows.push(["CRC", CRC[p[12]]]);
            if (p[10] != null || p[11] != null) rows.push(["Min … max", (p[10] || "–") + " … " + (p[11] || "–")]);
          }
          if (ch && (s.k === "data" || s.k === "dict" || s.k === "chunk")) {
            rows.push(["Codec", ch.codec]);
            if (s.k === "chunk") rows.push(["Encodings", ch.enc.join(", ")]);
          }
          clear(pop);
          add(pop, [
            h("div", { class: "t" }, h("span", { class: "sw-inline", style: "background:" + segColor(s) }), K.label + (s.p != null ? " " + s.p : "")),
            ch || s.c != null ? h("div", { class: "p" }, colPath(s.c) + " · row group " + s.rg) : null,
            h("div", { class: "w" }, K.what),
            h("dl", null, rows.map(function (r) { return [h("dt", { text: r[0] }), h("dd", { text: r[1] })]; }))
          ]);
          pop.style.display = "block";
          var pw = pop.offsetWidth, ph = pop.offsetHeight, px = ev.clientX + 14, py = ev.clientY + 16;
          if (px + pw > innerWidth - 8) px = Math.max(8, ev.clientX - pw - 14);
          if (py + ph > innerHeight - 8) py = Math.max(8, ev.clientY - ph - 12);
          pop.style.left = px + "px"; pop.style.top = py + "px";
        }
        function hidePop() { pop.style.display = "none"; }

        // ---------- state changes ----------
        function selectRg(i, toggle) { S.rg = toggle && S.rg === i ? null : i; S.page = null; S.pageOffset = 0; renderAll(); }
        function selectCol(c, toggle) { S.col = toggle && S.col === c ? null : c; S.page = null; S.pageOffset = 0; renderAll(); }
        function selectChunk(rg, c, page) {
          S.rg = rg; S.col = c; S.page = page == null ? null : page; S.tab = "pages";
          S.pageOffset = page == null ? 0 : Math.floor(page / PAGE_SIZE) * PAGE_SIZE;
          renderAll();
          var d = document.getElementById("detail"); if (d && d.scrollIntoView) d.scrollIntoView({ behavior: "smooth", block: "start" });
        }

        // ---------- summary ----------
        function renderSummary() {
          var el = clear(document.getElementById("summary"));
          var dicts = D.columns.some(function (c) { return c.dict_pages > 0; });
          var stats = D.row_groups.some(function (g) { return g.chunks.some(function (c) { return c.stats && (c.stats.min != null || c.stats.max != null); }); });
          var crc = D.row_groups.some(function (g) { return g.chunks.some(function (c) { return c.pages && c.pages.some(function (p) { return p[12]; }); }); });
          var sorting = (D.row_groups[0] && D.row_groups[0].sorting) || [];
          var sortedCols = sortedAcrossRowGroups();
          function badge(ok, label, extra) { return h("span", { class: "badge" + (ok ? " ok" : "") }, h("span", { "aria-hidden": "true", text: ok ? "✓" : "–" }), h("span", { text: label }), extra ? h("code", { text: extra }) : null); }
          function flag(cls, label, extra) { return h("span", { class: "badge " + cls }, h("span", { "aria-hidden": "true", text: "✗" }), h("span", { text: label }), extra ? h("code", { text: extra }) : null); }
          var cs = F.checksums, crcBadge;
          if (cs && cs.mismatch) crcBadge = flag("err", "Page CRC mismatches", num(cs.mismatch) + " of " + num(cs.ok + cs.mismatch));
          else if (cs && cs.ok) crcBadge = badge(true, "Page CRCs verified", num(cs.ok) + " ok" + (cs.absent ? ", " + num(cs.absent) + " without" : ""));
          else crcBadge = badge(crc, "Page CRCs", crc ? "not verified" : null);
          add(el, [
            h("header", null, h("h2", { text: F.name }), h("span", { class: "subtle" }, "created by ", h("span", { class: "mono", text: F.created_by || "unknown" }))),
            h("dl", { class: "stats" },
              [["Size", bytes(F.file_size)], ["Rows", num(F.num_rows)], ["Row groups", num(F.num_row_groups)], ["Columns", num(F.num_columns)],
               ["Footer", bytes(F.footer_size)], ["Compression", ratio(F.uncompressed_size, F.compressed_size)]].map(function (p) {
                return h("div", null, h("dt", { text: p[0] }), h("dd", { class: "num", text: p[1] }));
              }),
              h("div", { class: "wide" }, h("dt", { text: "Codecs · format version" }), h("dd", { class: "mono", text: (F.codecs.join(", ") || "none") + " · v" + F.format_version }))),
            h("div", { class: "badges" },
              badge(F.page_index, "Page index"),
              badge(F.bloom_filters, "Bloom filters"),
              badge(stats, "Statistics"),
              badge(dicts, "Dictionary encoding"),
              crcBadge,
              F.index_mismatches ? flag("warn", "Page stats disagree with page index", num(F.index_mismatches)) : null,
              badge(sorting.length > 0, "Sorting columns", sorting.length ? sorting.map(function (s) { return s.column + (s.descending ? " desc" : ""); }).join(", ") : null),
              badge(sortedCols.length > 0, "Sorted across row groups", sortedCols.length ? (sortedCols.length > 2 ? sortedCols[0] + " +" + (sortedCols.length - 1) : sortedCols.join(", ")) : null),
              F.pages_truncated ? h("span", { class: "badge" }, "page detail capped for size") : null)
          ]);
        }
        // Columns whose row group [min, max] ranges don't overlap, in order (can't compare display strings reliably, so only numbers)
        function sortedAcrossRowGroups() {
          if (D.row_groups.length < 2) return [];
          return D.columns.filter(function (col) {
            var prev = null;
            for (var g = 0; g < D.row_groups.length; g++) {
              var ch = chunkOf(g, col.i); if (!ch || !ch.stats) return false;
              var lo = Number(ch.stats.min), hi = Number(ch.stats.max);
              if (!isFinite(lo) || !isFinite(hi)) return false;
              if (prev != null && lo < prev) return false;
              prev = hi;
            }
            return true;
          }).map(function (c) { return c.path; });
        }

        // ---------- file map ----------
        function renderMap() {
          var el = clear(document.getElementById("map"));
          var rgTargets = D.row_groups.map(function (g) { return { s: g.start, e: g.end, rg: g.i }; });
          var bodyHost = h("div", { class: "strip pick" }), tailHost = h("div", { class: "strip" });
          add(el, h("div", { class: "map-grid" },
            h("div", null, h("div", { class: "strip-label" }, h("span", null, h("b", { text: "File" }), " · " + plural(D.row_groups.length, "row group") + " · click one to open it"), h("span", { text: bytes(tailStart) })), bodyHost),
            h("div", null, h("div", { class: "strip-label" }, h("span", null, h("b", { text: F.page_index || F.bloom_filters ? "Indexes + footer" : "Footer" }), " magnified"), h("span", { text: bytes(F.file_size - tailStart) })), tailHost)));
          new Strip(bodyHost, 0, tailStart, bodySegs, {
            label: "File layout", targets: rgTargets,
            selected: function () { var g = S.rg != null && D.row_groups[S.rg]; return g ? { s: g.start, e: g.end } : null; },
            onpick: function (s) {
              if (!s) return;
              var rg = s.rg; if (rg == null) { var t = rgTargets.find(function (t) { return s.s >= t.s && s.s < t.e; }); rg = t ? t.rg : null; }
              if (rg != null) { hidePop(); selectRg(rg, true); }
            }
          });
          new Strip(tailHost, tailStart, F.file_size, tailSegs, { label: "Indexes and footer",
            onpick: function (s, ev) { if (s && s.rg != null && s.c != null) { hidePop(); selectChunk(s.rg, s.c); } else showPop(s, ev); } });
          if (S.rg != null && D.row_groups[S.rg]) {
            var g = D.row_groups[S.rg], host = h("div", { class: "strip pick" });
            add(el, h("div", { class: "zoom" }, h("div", { class: "strip-label" }, h("span", null, h("b", { text: "Row group " + g.i }), " · bytes " + num(g.start) + "–" + num(g.end) + " · click a page to open its column chunk"), h("span", { text: bytes(g.end - g.start) })), host));
            new Strip(host, g.start, g.end, segsIn(bodySegs, g.start, g.end), { label: "Row group layout",
              selected: function () { var ch = S.col != null && chunkOf(S.rg, S.col); return ch ? { s: ch.start, e: ch.end } : null; },
              onpick: function (s) { if (s && s.c != null) { hidePop(); selectChunk(s.rg, s.c, s.p); } } });
            var ch = S.col != null ? chunkOf(S.rg, S.col) : null;
            if (ch && ch.pages && ch.pages.length > 1) {
              var host2 = h("div", { class: "strip pick" });
              add(el, h("div", { class: "zoom" }, h("div", { class: "strip-label" }, h("span", null, h("b", { text: colPath(ch.c) }), " in row group " + g.i + " · " + plural(ch.pages.length, "page")), h("span", { text: bytes(ch.end - ch.start) })), host2));
              new Strip(host2, ch.start, ch.end, segsIn(bodySegs, ch.start, ch.end).filter(function (s) { return s.c === ch.c; }), { label: "Column chunk pages",
                selected: function () { if (S.page == null || !ch.pages[S.page]) return null; var p = ch.pages[S.page]; return { s: p[1], e: p[1] + p[2] + p[3] }; },
                onpick: function (s) { if (s && s.p != null) { hidePop(); selectChunk(s.rg, s.c, s.p); } } });
            }
          }
          var legend = h("div", { class: "legend" });
          D.columns.slice(0, 16).forEach(function (c) {
            add(legend, h("span", { class: "item" + (S.col != null && S.col !== c.i ? " dim" : ""), onclick: function () { selectCol(c.i, true); } },
              h("span", { class: "sw", style: "background:" + colColor(c.i, false, true) }), h("span", { class: "mono", text: c.path })));
          });
          if (D.columns.length > 16) add(legend, h("span", { class: "faint", text: "+" + num(D.columns.length - 16) + " more" }));
          var kinds = h("span", { class: "kinds" });
          ["dict", "data", "ci", "oi", "bloom", "footer"].forEach(function (k) {
            if ((k === "ci" || k === "oi") && !F.page_index) return;
            if (k === "bloom" && !F.bloom_filters) return;
            var color = k === "dict" ? (isDark() ? "#394150" : "#e2e5ea") : k === "data" ? (isDark() ? "#566072" : "#b8bec8") : kindColor(k);
            add(kinds, h("span", null, h("span", { class: "sw", style: "background:" + color }), KINDS[k].label.toLowerCase()));
          });
          if (segs.some(function (s) { return s.k === "cmeta"; })) add(kinds, h("span", null, h("span", { class: "sw", style: "background:" + kindColor("cmeta") }), "column metadata copy"));
          if (segs.some(function (s) { return s.k === "unknown" && s.e - s.s > 0; })) add(kinds, h("span", null, h("span", { class: "sw", style: "background:" + kindColor("unknown") }), "unaccounted"));
          add(legend, kinds);
          add(el, legend);
          add(el, h("p", { class: "hint", text: "Drawn to scale by compressed bytes; each pixel shows whatever covers most of its bytes. Hover for details, click to drill down." }));
        }

        // ---------- schema ----------
        function renderSchema() {
          var el = clear(document.getElementById("schema"));
          var total = D.columns.reduce(function (a, c) { return a + c.cs; }, 0) || 1;
          var lines = [];
          lines.push({ depth: 0, html: [h("span", { class: "kw", text: "message " }), h("span", { class: "nm", text: "schema" }), " {"] });
          function walk(n, depth) {
            var ann = n.logical_type || n.converted_type;
            if (n.children) {
              lines.push({ depth: depth, html: [h("span", { class: "kw", text: n.repetition + " " }), h("span", { class: "ty", text: "group " }), h("span", { class: "nm", text: n.name }), ann ? h("span", { class: "ann", text: " (" + ann + ")" }) : null, " {", arrowNote(n)] });
              n.children.forEach(function (c) { walk(c, depth + 1); });
              lines.push({ depth: depth, html: ["}"] });
            } else {
              var phys = n.physical_type.toLowerCase() + (n.type_length ? "(" + n.type_length + ")" : "");
              lines.push({ depth: depth, leaf: n.column, html: [h("span", { class: "kw", text: n.repetition + " " }), h("span", { class: "ty", text: phys + " " }), h("span", { class: "nm", text: n.name }), ann ? h("span", { class: "ann", text: " (" + ann + ")" }) : null, ";",
                h("span", { class: "lv", text: "  d" + n.max_definition_level + " r" + n.max_repetition_level }), arrowNote(n)] });
            }
          }
          function arrowNote(n) { return n.arrow_type ? h("span", { class: "arrow", title: "Arrow type (from ARROW:schema): " + n.arrow_type, text: "  // arrow: " + n.arrow_type }) : null; }
          D.schema.forEach(function (n) { walk(n, 1); });
          lines.push({ depth: 0, html: ["}"] });
          var box = h("div", { class: "schema" });
          var limit = S.allSchema ? lines.length : 400;
          lines.slice(0, limit).forEach(function (l, n) {
            var code = h("span", { class: "code", style: "padding-left:" + (l.depth * 2) + "ch" }, l.html);
            if (l.leaf == null) { add(box, h("div", { class: "sline" }, h("span", { class: "ln", text: n + 1 }), code)); return; }
            var c = D.columns[l.leaf];
            add(box, h("button", { type: "button", class: "sline" + (S.col === c.i ? " sel" : ""), title: c.type + " · max definition level " + c.max_def + ", max repetition level " + c.max_rep, onclick: function () { selectCol(c.i, true); } },
              h("span", { class: "ln", text: n + 1 }), code,
              h("span", { class: "size" }, h("span", { class: "bar" }, h("span", { style: "width:" + (c.cs / total * 100) + "%;background:" + colColor(c.i, false) })), h("span", { class: "v", text: bytes(c.cs) }))));
          });
          var hasArrow = D.schema.some(function (n) { return n.arrow_type; });
          add(el, [h("h2", null, "Schema", h("small", { text: "size on disk · d/r = max definition/repetition level" + (hasArrow ? " · Arrow types from ARROW:schema" : "") + " · click a column" })), box]);
          if (D.arrow_error) add(el, h("div", { class: "note", text: D.arrow_error }));
          if (lines.length > limit) add(el, h("button", { class: "more", onclick: function () { S.allSchema = true; renderSchema(); } }, "Show all " + num(lines.length) + " lines"));
        }

        // ---------- row groups ----------
        function renderRowGroups() {
          var el = clear(document.getElementById("rowgroups"));
          var maxSize = Math.max.apply(null, D.row_groups.map(function (g) { return g.end - g.start; }).concat([1]));
          var box = h("div", { class: "card rgs" });
          var shown = S.allRgs ? D.row_groups : D.row_groups.slice(0, 100);
          if (!D.row_groups.length) add(box, h("div", { class: "pad faint", text: "No row groups: the file has no data." }));
          shown.forEach(function (g) {
            var open = S.rg === g.i;
            add(box, h("button", { type: "button", class: "rg-row" + (open ? " open" : ""), "aria-expanded": open ? "true" : "false", onclick: function () { selectRg(g.i, true); } },
              h("span", { class: "caret", text: open ? "▾" : "▸" }), h("span", { class: "mono", text: g.i }),
              h("span", { class: "mono faint", text: g.rows ? num(g.first_row) + "–" + num(g.first_row + g.rows - 1) : "0 rows" }),
              h("span", { class: "gcell" }, h("span", { class: "gbar", style: "width:" + Math.max(1, (g.end - g.start) / maxSize * 100) + "%;background:" + gradient(g) })),
              h("span", { class: "mono", style: "text-align:right", text: bytes(g.end - g.start) })));
            if (open) add(box, rowGroupBody(g));
          });
          add(el, [h("h2", null, "Row groups", h("small", { text: num(D.row_groups.length) + " · click one, or click it in the file map" })), box]);
          if (shown.length < D.row_groups.length) add(el, h("button", { class: "more", onclick: function () { S.allRgs = true; renderRowGroups(); } }, "Show all " + num(D.row_groups.length) + " row groups"));
        }
        function gradient(g) {
          var total = g.chunks.reduce(function (a, c) { return a + (c.end - c.start); }, 0) || 1, at = 0, stops = [];
          var step = Math.max(1, Math.ceil(g.chunks.length / 300));
          for (var i = 0; i < g.chunks.length; i += step) {
            var sz = 0; for (var j = i; j < Math.min(i + step, g.chunks.length); j++) sz += g.chunks[j].end - g.chunks[j].start;
            var from = at / total * 100; at += sz;
            stops.push(colColor(g.chunks[i].c, false) + " " + from + "% " + (at / total * 100) + "%");
          }
          return stops.length ? "linear-gradient(to right," + stops.join(",") + ")" : "var(--line)";
        }
        function rowGroupBody(g) {
          var body = h("div", { class: "rg-body" });
          add(body, h("div", { class: "kvline" },
            [["rows", num(g.rows)], ["compressed", bytes(g.cs)], ["uncompressed", bytes(g.us)], ["bytes", num(g.start) + "–" + num(g.end)],
             g.sorting.length ? ["sorted by", g.sorting.map(function (s) { return s.column + (s.descending ? " desc" : "") + (s.nulls_first ? " nulls first" : ""); }).join(", ")] : null]
              .filter(Boolean).map(function (p) { return h("span", null, h("span", { class: "k", text: p[0] }), h("span", { class: "mono", text: p[1] })); })));
          var maxChunk = Math.max.apply(null, g.chunks.map(function (c) { return c.end - c.start; }).concat([1]));
          var chunks = g.chunks.length > 200 && !S.allChunkRgs ? g.chunks.slice(0, 200) : g.chunks;
          chunks.forEach(function (ch) {
            var pages = h("span", { class: "pages", style: "width:" + Math.max(6, (ch.end - ch.start) / maxChunk * 100) + "%" });
            if (ch.pages && ch.pages.length <= 40) ch.pages.forEach(function (p) { add(pages, h("span", { style: "flex:" + (p[2] + p[3]) + " 0 0;background:" + colColor(ch.c, p[0] === 2) })); });
            else {
              // Too many pages to draw one by one: dictionary pages, then all data pages as one hatched block
              var dictBytes = 0, dataBytes = 0;
              (ch.pages || []).forEach(function (p) { if (p[0] === 2) dictBytes += p[2] + p[3]; else dataBytes += p[2] + p[3]; });
              if (!ch.pages) dataBytes = ch.end - ch.start;
              if (dictBytes) add(pages, h("span", { style: "flex:" + dictBytes + " 0 0;background:" + colColor(ch.c, true) }));
              add(pages, h("span", { title: plural(ch.np, "page"), style: "flex:" + Math.max(1, dataBytes) + " 0 0;background:repeating-linear-gradient(90deg," + colColor(ch.c, false) + " 0 3px,var(--seam) 3px 4px)" }));
            }
            var info = [ch.np ? plural(ch.ndp, "page") : "no pages", ch.nulls ? num(ch.nulls) + " nulls" : null,
              ch.crc_bad ? "✗ CRC" : null, ch.idx_mm ? "✗ index" : null].filter(Boolean).join(" · ");
            add(body, h("div", { class: "chunk-row" + (S.col === ch.c ? " sel" : ""), onclick: function (ev) { ev.stopPropagation(); selectChunk(g.i, ch.c); } },
              h("span", { class: "name", title: colPath(ch.c), text: colPath(ch.c) }), pages,
              h("span", { class: "size", text: bytes(ch.cs) }),
              h("span", { class: "minmax", text: ch.stats && (ch.stats.min != null || ch.stats.max != null) ? (ch.stats.min || "–") + " … " + (ch.stats.max || "–") : "no min/max" }),
              h("span", { class: "info", text: info })));
          });
          if (chunks.length < g.chunks.length) add(body, h("button", { class: "more", onclick: function (ev) { ev.stopPropagation(); S.allChunkRgs = true; renderRowGroups(); } }, "Show all " + num(g.chunks.length) + " column chunks"));
          return body;
        }

        // ---------- columns table ----------
        function renderColumns() {
          var el = clear(document.getElementById("columns"));
          var maxRatio = Math.max.apply(null, D.columns.map(function (c) { return c.cs ? c.us / c.cs : 0; }).concat([1]));
          var shown = S.allCols ? D.columns : D.columns.slice(0, 200);
          var tb = h("tbody");
          shown.forEach(function (c) {
            var r = c.cs ? c.us / c.cs : 0;
            add(tb, h("tr", { class: "click" + (S.col === c.i ? " sel" : ""), onclick: function () { selectCol(c.i, true); } },
              h("td", { class: "mono clip", title: c.path }, h("span", { class: "sw-inline", style: "background:" + colColor(c.i, false, true) }), c.path),
              h("td", { class: "mono", text: c.type }),
              h("td", null, c.codecs.map(function (x) { return h("span", { class: "pill", text: x }); })),
              h("td", null, c.encodings.map(function (x) { return h("span", { class: "pill", text: x }); })),
              h("td", { class: "r num", text: bytes(c.cs) }),
              h("td", { class: "r num", text: bytes(c.us) }),
              h("td", null, h("span", { class: "ratio" }, h("span", { class: "bar" }, h("span", { style: "width:" + (r / maxRatio * 100) + "%;background:var(--accent)" })), h("span", { class: "num", text: ratio(c.us, c.cs) }))),
              h("td", { class: "r num", text: num(c.values) }),
              h("td", { class: "r num", text: num(c.nulls) }),
              h("td", { class: "r num", text: num(c.data_pages) }),
              h("td", { class: "r num", text: c.dict_pages ? bytes(c.dict_bytes) : "–" }),
              h("td", { class: "mono clip", title: c.min || "", text: c.min != null ? c.min : "–" }),
              h("td", { class: "mono clip", title: c.max || "", text: c.max != null ? c.max : "–" })));
          });
          var head = h("tr", null, ["column", "type", "codec", "encodings", "compressed", "uncompressed", "ratio", "values", "nulls", "data pages", "dictionary", "min", "max"].map(function (t, i) {
            return h("th", { class: (i >= 4 && i <= 5) || (i >= 7 && i <= 10) ? "r" : null, text: t });
          }));
          add(el, [h("h2", null, "Columns", h("small", { text: "totals across all row groups · click a row for per-row-group and per-page detail" })),
            h("div", { class: "card tablewrap" }, h("table", null, h("thead", null, head), tb))]);
          if (shown.length < D.columns.length) add(el, h("button", { class: "more", onclick: function () { S.allCols = true; renderColumns(); } }, "Show all " + num(D.columns.length) + " columns"));
        }

        // ---------- column / chunk detail ----------
        var PAGE_SIZE = 100;
        function renderDetail() {
          var el = clear(document.getElementById("detail"));
          if (S.col == null) return;
          var col = D.columns[S.col];
          var card = h("div", { class: "card pad detail" });
          add(el, [h("h2", null, h("span", { class: "mono", text: col.path }), h("small", { text: col.type + " · " + col.repetition + " · " + col.sort_order + " sort order" }),
            h("button", { class: "more", style: "margin:0 0 0 auto", onclick: function () { selectCol(col.i, true); } }, "close")), card]);
          add(card, h("div", { class: "kvline" },
            [["compressed", bytes(col.cs) + " (" + pct(col.cs, F.file_size) + " of file)"], ["uncompressed", bytes(col.us)], ["ratio", ratio(col.us, col.cs)],
             ["values", num(col.values)], ["nulls", num(col.nulls)], ["pages", num(col.pages)], ["max def/rep", col.max_def + "/" + col.max_rep]]
              .map(function (p) { return h("span", null, h("span", { class: "k", text: p[0] }), h("span", { class: "mono", text: p[1] })); })));
          // per row group
          var tb = h("tbody");
          var rgs = D.row_groups.length > 500 && !S.allChunkRgs ? D.row_groups.slice(0, 500) : D.row_groups;
          rgs.forEach(function (g) {
            var ch = chunkOf(g.i, col.i); if (!ch) return;
            var st = ch.stats || {};
            add(tb, h("tr", { class: "click" + (S.rg === g.i ? " sel" : ""), onclick: function () { selectChunk(g.i, col.i); } },
              h("td", { class: "mono", text: g.i }),
              h("td", { class: "mono clip", title: st.min || "", text: st.min != null ? st.min : "–" }),
              h("td", { class: "mono clip", title: st.max || "", text: st.max != null ? st.max : "–" }),
              h("td", { class: "r num", text: num(st.nulls) }),
              h("td", { class: "r num", text: num(st.distinct) }),
              h("td", { class: "r num", text: num(ch.values) }),
              h("td", { class: "r num", text: num(ch.ndp) }),
              h("td", { class: "r num", text: ch.dict ? num(ch.dict.n) : "–" }),
              h("td", { class: "r num", text: bytes(ch.cs) }),
              h("td", { class: "r num", text: ratio(ch.us, ch.cs) }),
              h("td", null, h("span", { class: "pill", text: ch.codec }), st.caveat ? h("span", { class: "pill warn", title: st.caveat, text: "legacy stats" }) : null, st.source && st.source.indexOf("legacy") >= 0 && !st.caveat ? h("span", { class: "pill", text: "legacy min/max" }) : null,
                st.min_exact === false || st.max_exact === false ? h("span", { class: "pill", title: "min/max were truncated by the writer", text: "truncated" }) : null,
                ch.err ? h("span", { class: "pill err", title: ch.err, text: "error" }) : null,
                ch.crc_bad ? h("span", { class: "pill err", text: "CRC mismatch" }) : null,
                ch.idx_mm ? h("span", { class: "pill warn", title: "page statistics disagree with the column index", text: "index mismatch" }) : null)));
          });
          add(card, h("div", { class: "tablewrap", style: "max-height:360px;overflow:auto" }, h("table", null,
            h("thead", null, h("tr", null, ["rg", "min", "max", "nulls", "distinct", "values", "data pages", "dict entries", "size", "ratio", ""].map(function (t, i) { return h("th", { class: i >= 3 && i <= 9 ? "r" : null, text: t }); }))), tb)));
          if (S.rg == null) { add(card, h("p", { class: "hint", text: "Click a row group to see its column chunk: page headers, page index and metadata." })); return; }
          var ch = chunkOf(S.rg, col.i);
          if (ch) add(card, chunkDetail(D.row_groups[S.rg], ch, col));
        }

        function chunkDetail(g, ch, col) {
          var box = h("div", { style: "margin-top:16px" });
          add(box, h("h2", null, "Column chunk", h("small", { text: col.path + " · row group " + g.i })));
          if (ch.err) add(box, h("div", { class: "note err", text: "While walking page headers: " + ch.err }));
          if (ch.stats && ch.stats.caveat) add(box, h("div", { class: "note", text: "Statistics: " + ch.stats.caveat }));
          if (ch.crc_bad) add(box, h("div", { class: "note err", text: plural(ch.crc_bad, "page") + " failed CRC verification: the bytes stored don't match the checksum in the page header." }));
          if (ch.idx_mm) add(box, h("div", { class: "note" }, "Page statistics disagree with the column index:",
            h("ul", { style: "margin:4px 0 0;padding-left:18px" }, ch.idx_mm.slice(0, 20).map(function (m) {
              return h("li", { class: "mono", text: m[0] == null ? m[2] + " data pages but " + m[3] + " column index entries" : "page " + m[0] + " " + m[1] + ": page header " + (m[2] == null ? "–" : m[2]) + ", column index " + (m[3] == null ? "–" : m[3]) });
            }), ch.idx_mm.length > 20 ? h("li", { text: "+" + num(ch.idx_mm.length - 20) + " more" }) : null)));
          var items = [
            ["codec", ch.codec], ["encodings", ch.enc.join(", ")],
            ["compressed / uncompressed", bytes(ch.cs) + " / " + bytes(ch.us) + " (" + ratio(ch.us, ch.cs) + ")"],
            ["bytes", num(ch.start) + " – " + num(ch.end) + (ch.end > ch.declared_end ? " (metadata says " + num(ch.declared_end) + ")" : "")],
            ["data page offset", num(ch.data_off)], ["dictionary page offset", ch.dict_off != null ? num(ch.dict_off) : "–"],
            ["values · nulls", num(ch.values) + " · " + num(ch.nulls)],
            ["dictionary", ch.dict ? num(ch.dict.n) + " entries, " + bytes(ch.dict.cs) + (ch.dict.sorted ? ", sorted" : "") : "none"],
            ["statistics", ch.stats ? (ch.stats.source || "null count only") : "none"],
            ["min … max", ch.stats && (ch.stats.min != null || ch.stats.max != null) ? (ch.stats.min || "–") + " … " + (ch.stats.max || "–") : "–"],
            ["distinct count", ch.stats && ch.stats.distinct != null ? num(ch.stats.distinct) : "–"],
            ["bloom filter", ch.bloom ? "at " + num(ch.bloom[0]) + (ch.bloom[1] ? ", " + bytes(ch.bloom[1]) : "") : "none"],
            ["column index", ch.ci ? "at " + num(ch.ci[0]) + ", " + bytes(ch.ci[1]) : "none"],
            ["offset index", ch.oi ? "at " + num(ch.oi[0]) + ", " + bytes(ch.oi[1]) : "none"]
          ];
          if (ch.estats && ch.estats.length) items.push(["encoding stats", ch.estats.map(function (e) { return e.page_type + " " + e.encoding + " ×" + e.count; }).join("; ")]);
          if (ch.size_stats && ch.size_stats.unencoded_byte_array_data_bytes != null) items.push(["unencoded byte array data", bytes(ch.size_stats.unencoded_byte_array_data_bytes)]);
          if (ch.kv) Object.keys(ch.kv).forEach(function (k) { items.push(["metadata: " + k, ch.kv[k]]); });
          add(box, h("dl", { class: "dl" }, items.map(function (p) { return h("div", null, h("dt", { text: p[0] }), h("dd", { text: p[1] })); })));
          if (!ch.pages) { add(box, h("p", { class: "hint", text: "Page detail was left out to keep this page small (" + num(ch.np) + " pages in this chunk)." })); return box; }
          var hasIdx = !!(ch.column_index || ch.offset_index);
          var tabs = h("div", { class: "tabs" });
          [["pages", "Pages (" + num(ch.pages.length) + ")"], hasIdx ? ["index", "Page index"] : null].filter(Boolean).forEach(function (t) {
            add(tabs, h("button", { class: S.tab === t[0] ? "on" : null, onclick: function () { S.tab = t[0]; S.pageOffset = 0; renderDetail(); } }, t[1]));
          });
          add(box, tabs);
          if (S.tab === "index" && hasIdx) add(box, pageIndexTable(ch)); else add(box, pagesTable(ch));
          return box;
        }

        function pager(total, rerender) {
          if (total <= PAGE_SIZE) return null;
          var from = S.pageOffset, to = Math.min(total, from + PAGE_SIZE);
          return h("div", { class: "pager" },
            h("button", { disabled: from === 0 ? true : null, onclick: function () { S.pageOffset = Math.max(0, from - PAGE_SIZE); rerender(); } }, "‹ prev"),
            h("span", { class: "num", text: num(from + 1) + "–" + num(to) + " of " + num(total) }),
            h("button", { disabled: to >= total ? true : null, onclick: function () { S.pageOffset = from + PAGE_SIZE; rerender(); } }, "next ›"));
        }

        function pagesTable(ch) {
          var wrap = h("div");
          var tb = h("tbody"), from = S.pageOffset, rows = ch.pages.slice(from, from + PAGE_SIZE);
          var bad = {};
          (ch.idx_mm || []).forEach(function (m) { if (m[0] != null) (bad[m[0]] = bad[m[0]] || []).push(m[1] + ": index says " + (m[3] == null ? "–" : m[3])); });
          rows.forEach(function (p, k) {
            var i = from + k;
            add(tb, h("tr", { class: "click" + (S.page === i ? " hl" : ""), onclick: function () { S.page = S.page === i ? null : i; renderMap(); renderDetail(); } },
              h("td", { class: "num", text: i }),
              h("td", null, h("span", { class: "sw-inline", style: "background:" + colColor(ch.c, p[0] === 2, true) }), PT[p[0]] || p[0]),
              h("td", { class: "r num", text: num(p[1]) }),
              h("td", { class: "r num", text: num(p[2]) }),
              h("td", { class: "r num", text: num(p[3]) }),
              h("td", { class: "r num", text: num(p[4]) }),
              h("td", { class: "r num", text: num(p[5]) }),
              h("td", { class: "r num", text: p[6] != null ? num(p[6]) : "–" }),
              h("td", { class: "r num", text: p[7] != null ? num(p[7]) : "–" }),
              h("td", { class: "r num", text: p[8] != null ? num(p[8]) : "–" }),
              h("td", null, p[9] ? h("span", { class: "pill", text: p[9] }) : "–"),
              h("td", { class: "mono clip", title: p[10] || "", text: p[10] != null ? p[10] : "–" }),
              h("td", { class: "mono clip", title: p[11] || "", text: p[11] != null ? p[11] : "–" }),
              h("td", null, crcCell(p[12]), bad[i] ? h("span", { class: "pill warn", title: bad[i].join("\n"), text: "≠ index" }) : null),
              h("td", { class: "faint", text: p[13] || "" })));
          });
          add(wrap, h("div", { class: "tablewrap" }, h("table", null,
            h("thead", null, h("tr", null, ["#", "type", "offset", "header", "compressed", "uncompressed", "values", "nulls", "rows", "first row", "encoding", "min", "max", "crc", "levels"].map(function (t, i) { return h("th", { class: i >= 2 && i <= 9 ? "r" : null, text: t }); }))), tb)));
          add(wrap, pager(ch.pages.length, renderDetail));
          return wrap;
        }

        function crcCell(v) {
          if (v === 2) return h("span", { class: "pill ok", title: "CRC verified", text: "✓ ok" });
          if (v === 3) return h("span", { class: "pill err", title: "the page bytes don't match the CRC in its header", text: "✗ mismatch" });
          return v ? h("span", { title: "the page header has a CRC (not verified; use --verify-checksums)", text: "✓" }) : "";
        }

        function pageIndexTable(ch) {
          var wrap = h("div");
          var ci = ch.column_index, oi = ch.offset_index || [];
          var n = Math.max(ci ? ci.rows.length : 0, oi.length);
          if (ci) add(wrap, h("div", { class: "kvline" }, h("span", null, h("span", { class: "k", text: "boundary order" }), h("span", { class: "mono", text: String(ci.boundary) })), h("span", null, h("span", { class: "k", text: "entries" }), h("span", { class: "mono", text: num(n) }))));
          var tb = h("tbody"), from = S.pageOffset;
          // column index entries follow the data pages; map them back to page numbers
          var dataPages = [], badEntry = {};
          ch.pages.forEach(function (p, k) { if (p[0] !== 2) dataPages.push(k); });
          (ch.idx_mm || []).forEach(function (m) { if (m[0] != null) badEntry[dataPages.indexOf(m[0])] = true; });
          for (var i = from; i < Math.min(n, from + PAGE_SIZE); i++) {
            var c = ci && ci.rows[i], o = oi[i];
            add(tb, h("tr", { class: badEntry[i] ? "hl" : null, title: badEntry[i] ? "disagrees with the page header's statistics" : null },
              h("td", { class: "num", text: i }),
              h("td", { class: "r num", text: o ? num(o[0]) : "–" }),
              h("td", { class: "r num", text: o ? num(o[1]) : "–" }),
              h("td", { class: "r num", text: o ? num(o[2]) : "–" }),
              h("td", { text: c ? (c[0] ? "yes" : "") : "–" }),
              h("td", { class: "mono clip", title: c && c[1] || "", text: c && c[1] != null ? c[1] : "–" }),
              h("td", { class: "mono clip", title: c && c[2] || "", text: c && c[2] != null ? c[2] : "–" }),
              h("td", { class: "r num", text: c && c[3] != null ? num(c[3]) : "–" })));
          }
          add(wrap, h("div", { class: "tablewrap" }, h("table", null,
            h("thead", null, h("tr", null, ["#", "offset", "compressed size", "first row", "null page", "min", "max", "null count"].map(function (t, i) { return h("th", { class: (i >= 1 && i <= 3) || i === 7 ? "r" : null, text: t }); }))), tb)));
          add(wrap, pager(n, renderDetail));
          return wrap;
        }

        // ---------- key/value metadata ----------
        function renderKV() {
          var el = clear(document.getElementById("kv"));
          if (!D.kv.length) return;
          var card = h("div", { class: "card pad" });
          D.kv.forEach(function (kv) {
            var body;
            if (kv.json !== undefined) body = code(JSON.stringify(kv.json, null, 2), "json");
            else body = h("pre", null, h("code", { text: kv.value }));
            var extra = kv.arrow_schema ? arrowTree(kv.arrow_schema)
              : kv.arrow_fields ? h("div", { class: "hint", text: "Arrow schema fields: " + kv.arrow_fields.join(", ") }) : null;
            if (kv.arrow_error) extra = [h("div", { class: "note", text: kv.arrow_error }), extra];
            var head = h("div", { class: "head" }, h("span", { class: "key", text: kv.key }), h("span", { class: "pill", text: kv.format }), h("span", { class: "faint", text: bytes(kv.bytesize) }), kv.summary ? h("span", { class: "subtle", text: kv.summary }) : null);
            if (kv.format === "arrow_schema" || kv.bytesize > 4000) add(card, h("div", { class: "kv" }, head, extra, h("details", null, h("summary", { text: "show value" }), body)));
            else add(card, h("div", { class: "kv" }, head, body));
          });
          add(el, [h("h2", null, "Key/value metadata", h("small", { text: num(D.kv.length) + " entries" })), card]);
        }
        function arrowTree(a) {
          var box = h("div", { class: "schema", style: "margin:4px 0 8px" }), n = 0;
          function walk(f, depth) {
            if (n++ > 2000) return;
            var notes = [];
            if (!f.nullable) notes.push("not null");
            if (f.extension) notes.push("extension " + f.extension);
            if (f.dictionary) notes.push("dictionary-encoded, " + f.dictionary.index_type + " indices" + (f.dictionary.ordered ? ", ordered" : ""));
            var meta = f.metadata ? Object.keys(f.metadata).filter(function (k) { return k.indexOf("ARROW:extension:") !== 0; }) : [];
            if (meta.length) notes.push("metadata " + meta.map(function (k) { return k + "=" + JSON.stringify(f.metadata[k]).slice(0, 80); }).join(", "));
            add(box, h("div", { class: "sline", title: f.type },
              h("span", { class: "ln" }),
              h("span", { class: "code", style: "padding-left:" + (depth * 2) + "ch" }, h("span", { class: "nm", text: f.name }), ": ",
                h("span", { class: "ty", text: f.children && f.type.length > 60 ? f.type.slice(0, f.type.indexOf("<") + 1) + "…>" : f.type }),
                notes.length ? h("span", { class: "ann", text: "  " + notes.join("; ") }) : null)));
            (f.children || []).forEach(function (c) { walk(c, depth + 1); });
          }
          a.fields.forEach(function (f) { walk(f, 0); });
          var meta = a.metadata ? Object.keys(a.metadata) : [];
          return [h("div", { class: "hint", text: "Arrow schema" + (a.endianness === "big" ? " (big-endian)" : "") + (meta.length ? " · schema metadata: " + meta.join(", ") : "") }), box];
        }
        function code(text, lang) {
          var c = h("code", { class: "language-" + lang, text: text });
          highlight(c);
          return h("pre", null, c);
        }
        var pending = [];
        function highlight(el) {
          if (window.hljs) { try { window.hljs.highlightElement(el); } catch (e) {} }
          else pending.push(el);
        }
        window.__hbHighlight = function () { var p = pending; pending = []; p.forEach(function (el) { if (el.isConnected) highlight(el); }); };

        // ---------- footer JSON ----------
        function renderFooter() {
          var el = clear(document.getElementById("footer"));
          var det = h("details", null, h("summary", { text: "FileMetaData as JSON (" + bytes(F.footer_size) + " footer)" }));
          if (D.footer_json) {
            var done = false;
            det.addEventListener("toggle", function () { if (det.open && !done) { done = true; add(det, code(D.footer_json, "json")); } });
          } else add(det, h("p", { class: "hint", text: "The footer is too large to embed." }));
          add(el, [h("h2", null, "Footer", h("small", { text: "the raw metadata this page was drawn from" })), h("div", { class: "card pad" }, det)]);
        }

        function renderAll() {
          renderSummary(); renderMap(); renderSchema(); renderRowGroups(); renderDetail(); renderColumns();
        }
        renderAll(); renderKV(); renderFooter();
        document.getElementById("gen").textContent = "Generated by " + D.generator + " · " + F.name;
        document.addEventListener("click", function (ev) { if (ev.target.tagName !== "CANVAS") hidePop(); });
      })();
      </script>
      <script src="%%HIGHLIGHT_JS%%" async onload="window.__hbHighlight && window.__hbHighlight()"></script>
      </body>
      </html>
    HTML
  end
end
