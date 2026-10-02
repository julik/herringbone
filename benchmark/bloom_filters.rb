# frozen_string_literal: true

# Cost of bloom filters when writing: XXH64 throughput, then writing ROWS rows (an INT64 id and a
# ~22-byte String) without filters, with a filter on the int column and on the string column.
# Runs with the pure-Ruby XXH64 and, when the optional "xxhash" gem is installed, with it too.
#
#   ruby -Ilib benchmark/bloom_filters.rb
#   ROWS=100000 ruby -Ilib benchmark/bloom_filters.rb
require "herringbone"
require "stringio"
# Herringbone uses the optional gems only when they are loaded
%w[zstd-ruby snappy xxhash].each do |lib|
  require lib
rescue LoadError
end

ROWS = Integer(ENV.fetch("ROWS", 1_000_000))
HASHES = Integer(ENV.fetch("HASHES", 500_000))

XX = Herringbone::XXHash
backends = [:ruby]
backends << :native if XX.native_available?

def time
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
end

puts "Ruby #{RUBY_VERSION}, native XXH64: #{XX.native_available? ? "xxhash gem" : "not installed"}"
puts

ints = Array.new(HASHES) { |i| i * 7_919 + 1 }
strings = Array.new(HASHES) { |i| format("user-%015d", i) } # 20 bytes
backends.each do |backend|
  XX.backend = backend
  t = time { ints.each { |v| XX.xxh64_u64(v) } }
  puts format("%-7s xxh64 8-byte ints:    %6.2f M/s", backend, HASHES / t / 1e6)
  t = time { strings.each { |v| XX.xxh64(v) } }
  puts format("%-7s xxh64 20-byte strings: %6.2f M/s", backend, HASHES / t / 1e6)
end
puts

schema = Herringbone::Schema.define do |s|
  s.int64 :id, null: false
  s.string :email, null: false
end
rows = Array.new(ROWS) { |i| {"id" => i * 7_919 + 1, "email" => format("u%010d@example.com", i)} }

def write(schema, rows, bloom_filters)
  io = StringIO.new("".b)
  Herringbone::Writer.open(io, schema, bloom_filters: bloom_filters) { |w| rows.each { |r| w << r } }
end

puts "Writing #{ROWS} rows (int64 id + 22-byte string):"
GC.start
puts format("  no bloom filters:           %6.2f s", time { write(schema, rows, nil) })
backends.each do |backend|
  XX.backend = backend
  [["id"], ["email"]].each do |filters|
    GC.start
    puts format("  %-7s filter on %-8s %6.2f s", backend, "#{filters.first}:", time { write(schema, rows, filters) })
  end
end
