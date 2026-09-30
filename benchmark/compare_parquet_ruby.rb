# frozen_string_literal: true

# Compares parakiet with parquet-ruby (https://github.com/njaremko/parquet-ruby, Rust/arrow-rs).
#
#   cd benchmark && bundle install
#   ROWS=500000 bundle exec ruby compare_parquet_ruby.rb
#
# Every case runs in a forked child so peak memory is measured in isolation. The input rows are
# generated once in the parent (not timed) and shared with the children copy-on-write.
require "parakiet"
require "parquet"
require "get_process_mem"
require "tmpdir"
require_relative "dataset"

ROWS = Integer(ENV.fetch("ROWS", 500_000))
DIR = Dir.mktmpdir("parakiet-bench")

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
puts "parakiet #{Parakiet::VERSION}, parquet-ruby #{Gem.loaded_specs["parquet"].version}, #{RUBY_DESCRIPTION}"
puts

parakiet_file = File.join(DIR, "parakiet.parquet")
parquet_ruby_file = File.join(DIR, "parquet_ruby.parquet")
size = ->(path) { "#{(File.size(path) / 1024.0 / 1024).round(1)} MB" }

puts "== Write (snappy)"
measure("parakiet Writer (hash rows)") do
  Parakiet::Writer.open(parakiet_file, Dataset.parakiet_schema, compression: :snappy) { |w| w.write_rows(ROWS_HASHES) }
  size.call(parakiet_file)
end
measure("parakiet Writer (hash rows, uncompressed)") do
  path = File.join(DIR, "parakiet_none.parquet")
  Parakiet::Writer.open(path, Dataset.parakiet_schema, compression: :none) { |w| w.write_rows(ROWS_HASHES) }
  size.call(path)
end
measure("parakiet Writer (hash rows, zstd via zstd-ruby)") do
  path = File.join(DIR, "parakiet_zstd.parquet")
  Parakiet::Writer.open(path, Dataset.parakiet_schema, compression: :zstd) { |w| w.write_rows(ROWS_HASHES) }
  size.call(path)
end
measure("parquet-ruby write_rows (array rows)") do
  Parquet.write_rows(ROWS_ARRAYS.each, schema: Dataset.parquet_ruby_schema, write_to: parquet_ruby_file, compression: "snappy")
  size.call(parquet_ruby_file)
end

# Both files exist now (the children wrote them), so cross-reading also checks interop
puts
puts "== Read all rows"
{ "parakiet file" => parakiet_file, "parquet-ruby file" => parquet_ruby_file }.each do |name, path|
  measure("parakiet each_row, #{name}") do
    n = 0
    Parakiet::Reader.open(path) { |r| r.each_row { n += 1 } }
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
{ "parakiet file" => parakiet_file, "parquet-ruby file" => parquet_ruby_file }.each do |name, path|
  measure("parakiet column, #{name}") do
    sum = Parakiet::Reader.open(path) { |r| r.column("amount").sum }
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
a = Parakiet::Reader.open(parquet_ruby_file) { |r| r.each_row.first(3) }
b = Parakiet::Reader.open(parakiet_file) { |r| r.each_row.first(3) }
c = Parquet.each_row(parakiet_file).first(3)
puts "parakiet reads parquet-ruby's file identically to its own: #{a == b}"
puts "parquet-ruby reads parakiet's file (first row): #{c.first.inspect}"
