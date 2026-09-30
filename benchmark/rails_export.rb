# frozen_string_literal: true

# Simulates exporting a large ActiveRecord table: records arrive `find_each`-style in batches of
# 1000 attribute Hashes and are streamed into one Parquet file. Logs throughput and RSS as it goes,
# to show whether memory stays flat while row groups are flushed to disk.
#
#   cd benchmark
#   ROWS=20_000_000 ROW_GROUP_SIZE=100_000 COMPRESSION=snappy bundle exec ruby rails_export.rb [out.parquet]
require "parakiet"
require "get_process_mem"
require_relative "dataset"

rows = Integer(ENV.fetch("ROWS", "20000000").delete("_"))
row_group_size = Integer(ENV.fetch("ROW_GROUP_SIZE", "100000").delete("_"))
compression = ENV.fetch("COMPRESSION", "snappy").to_sym
path = ARGV[0] || File.join(Dir.tmpdir, "rails_export.parquet")
report_every = [rows / 20, 100_000].max

def rss_mb = GetProcessMem.new.mb.round

puts "Exporting #{rows} rows to #{path} (row groups of #{row_group_size}, #{compression})"
puts format("%12s %9s %10s %9s %9s %11s", "rows", "elapsed", "rows/s", "RSS MB", "file MB", "GC runs")
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
peak = 0
Parakiet::Writer.open(path, Dataset.parakiet_schema, compression: compression, row_group_size: row_group_size) do |writer|
  n = 0
  Dataset.each_record(rows, batch_size: 1000) do |attributes|
    writer << attributes
    n += 1
    next unless (n % report_every).zero? || n == rows
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    rss = rss_mb
    peak = rss if rss > peak
    puts format("%12d %8.1fs %10d %9d %9.1f %11d", n, elapsed, n / elapsed, rss, File.size(path) / 1048576.0, GC.count)
  end
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts format("Done in %.1fs (%d rows/s), file %.1f MB, peak sampled RSS %d MB",
  elapsed, rows / elapsed, File.size(path) / 1048576.0, peak)

# Verify: row count, and a handful of rows spread across the file match the source records
Parakiet::Reader.open(path) do |reader|
  raise "row count mismatch: #{reader.num_rows}" unless reader.num_rows == rows
  sample_groups = [0, reader.num_row_groups / 2, reader.num_row_groups - 1].uniq
  sample_groups.each do |rg|
    first_row = reader.row_groups.first(rg).sum(&:num_rows)
    data = reader.read_row_group(rg)
    [0, reader.row_groups[rg].num_rows - 1].each do |offset|
      expected = Dataset.record(first_row + offset)
      actual = data.to_h { |name, values| [name, values[offset]] }
      raise "row #{first_row + offset} differs:\n#{expected}\n#{actual}" unless actual == expected
    end
  end
  puts "Verified #{reader.num_row_groups} row groups, #{reader.num_rows} rows; sampled rows match the source"
end
