# frozen_string_literal: true

# Regenerates the LZO fixtures with the reference liblzo2 (`brew install lzo`), loaded via Fiddle
# so herringbone itself never links against it:
#
#   ruby test/fixtures/lzo/generate.rb
#
# Each <name>.bin gets <name>.lzo1x_1 (what hadoop-lzo writes) and <name>.lzo1x_999 (best
# compression, which uses more of the instruction set). lzo.parquet has its pages compressed
# with lzo1x_1 in hadoop-lzo framing.
require "fiddle"
require "fiddle/import"
require "stringio"
require_relative "../../../lib/herringbone"

module LibLZO
  extend Fiddle::Importer

  dlload ENV.fetch("LIBLZO2", "/opt/homebrew/lib/liblzo2.dylib")
  extern "int lzo1x_1_compress(void*, unsigned long, void*, void*, void*)"
  extern "int lzo1x_999_compress(void*, unsigned long, void*, void*, void*)"

  WORKMEM = Fiddle::Pointer.malloc(1024 * 1024, Fiddle::RUBY_FREE)

  def self.compress(fn, data)
    dst = Fiddle::Pointer.malloc(data.bytesize + data.bytesize / 16 + 64 + 3, Fiddle::RUBY_FREE)
    dst_len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_LONG, Fiddle::RUBY_FREE)
    rc = send(fn, data, data.bytesize, dst, dst_len, WORKMEM)
    raise "#{fn} failed with #{rc}" unless rc == 0
    dst.to_s(dst_len[0, Fiddle::SIZEOF_LONG].unpack1("Q"))
  end
end

dir = __dir__
rng = Random.new(42)
words = %w[parquet column page dictionary herringbone lzo hadoop block stream literal match]
inputs = {
  "text" => Array.new(4000) { words[rng.rand(words.size)] }.join(" "),
  "runs" => ("a" * 1000) + ("ab" * 700) + ("xyz" * 333) + ("\x00" * 5000),
  "random" => rng.bytes(3000),
  # Repeats 20-40KB back, which need the long-distance match instruction
  "far" => begin
    chunk = rng.bytes(24_000)
    chunk + rng.bytes(9000) + chunk.byteslice(0, 6000) + chunk.byteslice(12_000, 8000)
  end
}
inputs.each do |name, data|
  File.binwrite(File.join(dir, "#{name}.bin"), data)
  File.binwrite(File.join(dir, "#{name}.lzo1x_1"), LibLZO.compress(:lzo1x_1_compress, data.b))
  File.binwrite(File.join(dir, "#{name}.lzo1x_999"), LibLZO.compress(:lzo1x_999_compress, data.b))
end

# Write snappy, then swap in hadoop-lzo framing as the pages go out
module LZOPages
  def compress(codec, data)
    return super unless codec == Herringbone::Format::Codec::SNAPPY
    lzo = LibLZO.compress(:lzo1x_1_compress, data.b)
    [data.bytesize, lzo.bytesize].pack("NN") + lzo
  end
end
Herringbone::Compression.singleton_class.prepend(LZOPages)

schema = Herringbone::Schema.define do
  int64 :id, null: false
  string :name
  double :score
end
io = StringIO.new("".b)
Herringbone::Writer.open(io, schema, compression: :snappy, page_rows: 700) do |w|
  2000.times { |i| w << [i, "row #{i % 37}", i.even? ? i * 0.5 : nil] }
end
# Mark the column chunks as LZO-compressed by re-encoding the footer
bytes = io.string
footer_len = bytes.byteslice(-8, 4).unpack1("V")
footer_start = bytes.bytesize - 8 - footer_len
meta, = Herringbone::Format::FileMetaData.decode(bytes.byteslice(footer_start, footer_len))
meta.row_groups.each { |rg| rg.columns.each { |c| c.meta_data.codec = Herringbone::Format::Codec::LZO } }
footer = meta.encode
File.binwrite(File.join(dir, "lzo.parquet"), bytes.byteslice(0, footer_start) + footer + [footer.bytesize].pack("V") + "PAR1")
