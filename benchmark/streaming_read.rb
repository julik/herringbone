# frozen_string_literal: true

# Memory use of reading a file with one huge row group (parquet-rs writes up to 1M rows per group).
#
#   cd benchmark && bundle install
#   ROWS=1000000 bundle exec ruby streaming_read.rb
#
# HERRINGBONE_LIB=/path/to/other/lib compares another checkout (e.g. `git archive HEAD lib`).
# FILE=path reuses an existing file instead of writing one (it is kept between runs otherwise).
# Reading runs in a forked child so peak memory is measured in isolation.
$LOAD_PATH.unshift(File.expand_path(ENV["HERRINGBONE_LIB"])) if ENV["HERRINGBONE_LIB"]
require "herringbone"
require "get_process_mem"
require "tmpdir"
require_relative "dataset"

ROWS = Integer(ENV.fetch("ROWS", 1_000_000))
# PAGE_ROWS: rows per data page (the writer default is 20_000; other writers produce much bigger pages)
PAGE_ROWS = Integer(ENV.fetch("PAGE_ROWS", 20_000))
FILE = ENV.fetch("FILE") { File.join(Dir.tmpdir, "herringbone-streaming-#{ROWS}-#{PAGE_ROWS}.parquet") }

def measure(label)
  reader, writer = IO.pipe
  pid = fork do
    reader.close
    GC.start
    base = GetProcessMem.new.mb
    peak = base
    sampler = Thread.new do
      while true
        m = GetProcessMem.new.mb
        peak = m if m > peak
        sleep 0.02
      end
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    detail = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    sampler.kill
    writer.write(Marshal.dump([elapsed, peak - base, detail]))
    writer.close
    exit!(0)
  end
  writer.close
  data = reader.read
  Process.wait(pid)
  raise "#{label} failed" if data.empty?
  elapsed, mem, detail = Marshal.load(data)
  rate = (ROWS / elapsed / 1000).round
  puts format("%-44s %8.2fs %6dk rows/s %7.0f MB peak RSS growth  %s", label, elapsed, rate, mem, detail)
end

unless File.exist?(FILE)
  puts "Writing #{ROWS} rows in one row group to #{FILE}..."
  pid = fork do
    File.open(FILE, "wb") do |f|
      Herringbone::Writer.open(f, Dataset.herringbone_schema, row_group_rows: 1_000_000, page_rows: PAGE_ROWS,
        page_bytes: 64 * 1024 * 1024, row_group_bytes: 4 * 1024 * 1024 * 1024) do |w|
        Dataset.each_record(ROWS) { |r| w << r }
      end
    end
    exit!(0)
  end
  Process.wait(pid)
end

lib = $LOADED_FEATURES.grep(%r{herringbone/reader\.rb\z}).first
File.open(FILE, "rb") do |f|
  r = Herringbone::Reader.new(f)
  puts "#{r.num_rows} rows, #{r.row_groups.size} row group(s), #{(File.size(FILE) / 1024.0 / 1024).round(1)} MB, #{RUBY_DESCRIPTION}"
end
puts "reader: #{lib}"
puts

measure("each_row") do
  n = 0
  File.open(FILE, "rb") { |f| Herringbone::Reader.new(f).each_row { n += 1 } }
  "#{n} rows"
end
measure("each_batch(10_000)") do
  n = 0
  File.open(FILE, "rb") { |f| Herringbone::Reader.new(f).each_batch(10_000) { |b| n += b.size } }
  "#{n} rows"
end
measure("each_row(columns: [id, email])") do
  n = 0
  File.open(FILE, "rb") { |f| Herringbone::Reader.new(f).each_row(columns: %w[id email]) { n += 1 } }
  "#{n} rows"
end
measure("read(as: :columns, columns: [amount])") do
  sum = File.open(FILE, "rb") { |f| Herringbone::Reader.new(f).read(as: :columns, columns: ["amount"])["amount"].sum }
  "sum=#{sum.to_s("F")}"
end
