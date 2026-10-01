# frozen_string_literal: true

# read(as: :numo) against read(as: :columns) and read (rows): time, peak RSS growth and Ruby
# objects allocated, for 1M rows of int64 id, double, int32, boolean, a nullable double (10%
# nulls) and a dictionary-encoded string, uncompressed and with Snappy.
#
#   bundle exec ruby benchmark/numo_read.rb      # from the repository root (needs the :numo group)
#   ROWS=200000 bundle exec ruby benchmark/numo_read.rb
#
# The files are written once to Dir.tmpdir and reused. Every read runs in a forked child, so
# peak memory is measured in isolation (ru_maxrss through Fiddle).
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "herringbone"
require "numo/narray"
require "fiddle"
require "tmpdir"

ROWS = Integer(ENV.fetch("ROWS", 1_000_000))
CATEGORIES = Array.new(50) { |i| "category-#{i}" }.freeze

SCHEMA = Herringbone::Schema.define do
  int64 :id, null: false
  double :amount
  int32 :quantity
  boolean :active
  double :score # 10% nulls
  string :category
end

def file_for(compression)
  path = File.join(Dir.tmpdir, "herringbone-numo-#{ROWS}-#{compression}.parquet")
  return path if File.exist?(path)
  puts "Writing #{ROWS} rows (#{compression}) to #{path}..."
  rng = Random.new(42)
  File.open(path, "wb") do |f|
    Herringbone::Writer.open(f, SCHEMA, compression: compression) do |w|
      ROWS.times do |i|
        w << [i, rng.rand * 1000, rng.rand(1000), i.odd?, (rng.rand < 0.1 ? nil : rng.rand), CATEGORIES[i % 50]]
      end
    end
  end
  path
end

# Peak resident set size of this process in MB
GETRUSAGE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["getrusage"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
def max_rss_mb
  buf = Fiddle::Pointer.malloc(256, Fiddle::RUBY_FREE)
  GETRUSAGE.call(0, buf)
  # struct rusage: two struct timevals (16 bytes each on 64-bit), then long ru_maxrss
  maxrss = buf[32, 8].unpack1("q")
  RUBY_PLATFORM.include?("darwin") ? maxrss / 1024.0 / 1024 : maxrss / 1024.0
end

def measure(label)
  reader, writer = IO.pipe
  pid = fork do
    reader.close
    GC.start
    base = max_rss_mb
    objects = GC.stat(:total_allocated_objects)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    objects = GC.stat(:total_allocated_objects) - objects
    writer.write(Marshal.dump([elapsed, max_rss_mb - base, objects]))
    writer.close
    exit!(0)
  end
  writer.close
  data = reader.read
  Process.wait(pid)
  raise "#{label} failed" if data.empty?
  elapsed, mem, objects = Marshal.load(data)
  puts format("  %-42s %8.1f ms %8.0f MB peak RSS growth %10.2fM objects", label, elapsed * 1000, mem, objects / 1e6)
end

%i[none snappy].each do |compression|
  path = file_for(compression)
  puts "#{ROWS} rows, #{compression} (#{(File.size(path) / 1e6).round(1)} MB):"
  open_reader = ->(&blk) { File.open(path, "rb") { |f| blk.call(Herringbone::Reader.new(f)) } }
  measure("read(as: :numo)") { open_reader.call { |r| r.read(as: :numo) } }
  measure("read(as: :numo, columns: [id, amount])") { open_reader.call { |r| r.read(as: :numo, columns: %w[id amount]) } }
  measure("read(as: :numo) numeric columns only") { open_reader.call { |r| r.read(as: :numo, columns: %w[id amount quantity active score]) } }
  measure("each_batch(100_000, as: :numo)") { open_reader.call { |r| r.each_batch(100_000, as: :numo) { } } }
  measure("read(as: :columns)") { open_reader.call { |r| r.read(as: :columns) } }
  measure("read(as: :columns, columns: [id, amount])") { open_reader.call { |r| r.read(as: :columns, columns: %w[id amount]) } }
  measure("read") { open_reader.call { |r| r.read } }
end
