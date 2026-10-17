# frozen_string_literal: true

# Regenerates the Zstandard fixtures with the reference zstd CLI (`brew install zstd`):
#
#   ruby test/fixtures/zstd/generate.rb
#
# Each input gets <name>.<variant>.zst for the variants below: fast and strongest levels, with
# and without the content checksum, and a long window. The inputs themselves are not kept: the
# .check variant carries an XXH64 of the content, and the others must decode to the same bytes.
# text and ints are over 128 KiB, so their frames have several blocks.
require "open3"
require "tmpdir"

DIR = __dir__
WORDS = %w[parquet column page row group dictionary encoding the a of and zstd ruby].freeze

def zstd(data, *flags)
  out, status = Open3.capture2("zstd", "-q", "-c", *flags, stdin_data: data, binmode: true)
  raise "zstd #{flags.join(" ")} failed" unless status.success?
  out
end

rng = Random.new(2026)
inputs = {
  "text" => Array.new(24_000) { WORDS[rng.rand(WORDS.size)] }.join(" "),
  "ints" => Array.new(17_000) { rng.rand(5000) }.pack("q<*"), # Huffman-heavy
  "runs" => Array.new(100) { rng.rand(256).chr * rng.rand(1..2000) }.join,
  "random" => rng.bytes(3000) # stored as raw blocks
}
variants = {
  "1" => ["-1", "--no-check"],
  "19" => ["-19", "--no-check"],
  "check" => ["-3", "--check"],
  "long" => ["--long=20", "-12", "--no-check"]
}

inputs.each do |name, data|
  variants.each { |variant, flags| File.binwrite(File.join(DIR, "#{name}.#{variant}.zst"), zstd(data, *flags)) }
end
