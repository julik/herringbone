# frozen_string_literal: true

# Compares herringbone with parquet-ruby (https://github.com/njaremko/parquet-ruby, Rust/arrow-rs).
#
#   cd benchmark && bundle install
#   ROWS=500000 bundle exec ruby compare_parquet_ruby.rb
#
# Every case runs in a forked child so peak memory is measured in isolation. The input rows are
# generated once in the parent (not timed) and shared with the children copy-on-write.
require "herringbone"
# Herringbone uses the optional gems only when they are loaded
%w[zstd-ruby snappy xxhash].each do |lib|
  require lib
rescue LoadError
end
require "parquet"
require "get_process_mem"
require "tmpdir"
require_relative "dataset"

ROWS = Integer(ENV.fetch("ROWS", 500_000))
DIR = Dir.mktmpdir("herringbone-bench")

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
  puts format("%-52s %8.2fs %7dk rows/s %8.0f MB peak RSS growth  %s", label, elapsed, rate, mem, detail)
end

puts "Generating #{ROWS} rows..."
ROWS_HASHES = Dataset.each_record(ROWS).to_a
ROWS_ARRAYS = ROWS_HASHES.map { |r| Dataset.parquet_ruby_row(r) } # parquet-ruby takes Arrays in schema order
puts "herringbone #{Herringbone::VERSION}, parquet-ruby #{Gem.loaded_specs["parquet"].version}, #{RUBY_DESCRIPTION}"
puts

herringbone_file = File.join(DIR, "herringbone.parquet")
parquet_ruby_file = File.join(DIR, "parquet_ruby.parquet")
size = ->(path) { "#{(File.size(path) / 1024.0 / 1024).round(1)} MB" }

puts "== Write (snappy)"
measure("herringbone Writer (hash rows)") do
  File.open(herringbone_file, "wb") { |f| Herringbone::Writer.open(f, Dataset.herringbone_schema, compression: :snappy) { |w| ROWS_HASHES.each { |r| w << r } } }
  size.call(herringbone_file)
end
measure("herringbone Writer (hash rows, uncompressed)") do
  path = File.join(DIR, "herringbone_none.parquet")
  File.open(path, "wb") { |f| Herringbone::Writer.open(f, Dataset.herringbone_schema, compression: :none) { |w| ROWS_HASHES.each { |r| w << r } } }
  size.call(path)
end
measure("herringbone Writer (hash rows, zstd via zstd-ruby)") do
  path = File.join(DIR, "herringbone_zstd.parquet")
  File.open(path, "wb") { |f| Herringbone::Writer.open(f, Dataset.herringbone_schema, compression: :zstd) { |w| ROWS_HASHES.each { |r| w << r } } }
  size.call(path)
end
measure("parquet-ruby write_rows (array rows)") do
  Parquet.write_rows(ROWS_ARRAYS.each, schema: Dataset.parquet_ruby_schema, write_to: parquet_ruby_file, compression: "snappy")
  size.call(parquet_ruby_file)
end

# Both files exist now (the children wrote them), so cross-reading also checks interop
puts
puts "== Read all rows"
{"herringbone file" => herringbone_file, "parquet-ruby file" => parquet_ruby_file}.each do |name, path|
  measure("herringbone each_row, #{name}") do
    n = 0
    File.open(path, "rb") { |f| Herringbone::Reader.new(f).each_row { n += 1 } }
    "#{n} rows"
  end
  measure("parquet-ruby each_row, #{name}") do
    n = 0
    Parquet.each_row(path) { n += 1 }
    "#{n} rows"
  end
end

puts
puts "== Read one column (amount)"
{"herringbone file" => herringbone_file, "parquet-ruby file" => parquet_ruby_file}.each do |name, path|
  measure("herringbone column, #{name}") do
    sum = File.open(path, "rb") { |f| Herringbone::Reader.new(f).read(as: :columns, columns: ["amount"])["amount"].sum }
    "sum=#{sum.to_s("F")}"
  end
  measure("parquet-ruby each_column, #{name}") do
    sum = 0
    Parquet.each_column(path, columns: ["amount"], batch_size: 65_536) { |b| sum += b["amount"].sum }
    "sum=#{sum.to_s("F")}"
  end
end

puts
puts "== Round trip check"
a = File.open(parquet_ruby_file, "rb") { |f| Herringbone::Reader.new(f).each_row.first(3) }
b = File.open(herringbone_file, "rb") { |f| Herringbone::Reader.new(f).each_row.first(3) }
c = Parquet.each_row(herringbone_file).first(3)
puts "herringbone reads parquet-ruby's file identically to its own: #{a == b}"
puts "parquet-ruby reads herringbone's file (first row): #{c.first.inspect}"
