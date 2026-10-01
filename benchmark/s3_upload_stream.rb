# frozen_string_literal: true

# Streams a Parquet file into S3 with a multipart upload and checks it: the file is never held
# in memory or on disk in full. Needs the aws-sdk-s3 gem (not a dependency of herringbone or of
# the benchmark bundle) and an S3 endpoint:
#
#   gem install aws-sdk-s3
#   S3_BUCKET=my-bucket ruby -I../lib s3_upload_stream.rb
#
# Against a local S3-compatible server (e.g. `moto_server -p 5055` or MinIO):
#
#   S3_ENDPOINT=http://127.0.0.1:5055 S3_BUCKET=herringbone CREATE_BUCKET=1 \
#     AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x ruby -I../lib s3_upload_stream.rb
#
# ROWS (default 400_000, about 20MB), PART_SIZE (default 5MB), TEMPFILE=1 (buffer parts on disk)
# and DOWNLOAD_TO=path (keep the downloaded file, e.g. to check it with pyarrow) are optional.
# After the upload it downloads the object and reads it back, then runs an upload that fails
# halfway through and checks that the multipart upload was aborted and no object was created.
require "herringbone"
# Herringbone uses the optional gems only when they are loaded
%w[zstd-ruby snappy xxhash].each do |lib|
  require lib
rescue LoadError
end
require "aws-sdk-s3"
require "securerandom"
require "tempfile"

ROWS = Integer(ENV.fetch("ROWS", 400_000))
PART_SIZE = Integer(ENV.fetch("PART_SIZE", 5 * 1024 * 1024))
BUCKET = ENV.fetch("S3_BUCKET")
KEY = ENV.fetch("S3_KEY", "herringbone-upload-stream-test.parquet")

client_options = {region: ENV.fetch("AWS_REGION", "us-east-1")}
if ENV["S3_ENDPOINT"]
  client_options[:endpoint] = ENV["S3_ENDPOINT"]
  client_options[:force_path_style] = true
end
CLIENT = Aws::S3::Client.new(**client_options)
CLIENT.create_bucket(bucket: BUCKET) if ENV["CREATE_BUCKET"]

# Counts the parts as they are uploaded
UPLOADED_PARTS = []
CLIENT.singleton_class.prepend(Module.new do
  def upload_part(params = {}, options = {})
    UPLOADED_PARTS << params[:body].size
    super
  end
end)

SCHEMA = Herringbone::Schema.define do
  int64 :id, null: false
  string :token          # random, so the file does not compress away
  string :category
  double :amount
  timestamp :created_at
end

def each_row(count)
  rng = Random.new(42)
  count.times do |i|
    yield({id: i, token: rng.bytes(24).unpack1("H*"), category: "c#{i % 50}",
           amount: (i % 10_000) / 100.0, created_at: Time.at(1_700_000_000 + i).utc})
  end
end

def rss_mb = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0

# Aws::S3::TransferManager was added in aws-sdk-s3 1.197; Object#upload_stream is deprecated there
def upload_stream(key, &block)
  opts = {part_size: PART_SIZE, tempfile: ENV["TEMPFILE"] == "1"}
  if defined?(Aws::S3::TransferManager)
    Aws::S3::TransferManager.new(client: CLIENT).upload_stream(bucket: BUCKET, key: key, **opts, &block)
  else
    Aws::S3::Object.new(BUCKET, key, client: CLIENT).upload_stream(**opts, &block)
  end
end

GC.start
base = rss_mb
peak = base
sampler = Thread.new {
  loop {
    peak = [peak, rss_mb].max
    sleep 0.05
  }
}

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
upload_stream(KEY) do |io|
  Herringbone::Writer.open(io, SCHEMA, bloom_filters: ["token"]) do |writer|
    each_row(ROWS) { |row| writer << row }
  end
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
sampler.kill
size = CLIENT.head_object(bucket: BUCKET, key: KEY).content_length

puts format("uploaded %s: %.1f MB, %d rows, %d parts of %.1f MB (last %.1f MB) in %.1f s",
  KEY, size / 1048576.0, ROWS, UPLOADED_PARTS.size, PART_SIZE / 1048576.0,
  UPLOADED_PARTS.last / 1048576.0, elapsed)
puts format("RSS: %.0f MB before, %.0f MB peak during the upload (+%.0f MB for a %.0f MB file)",
  base, peak, peak - base, size / 1048576.0)

# Download and read it back
file = ENV["DOWNLOAD_TO"] ? File.open(ENV["DOWNLOAD_TO"], "w+b") : Tempfile.new(["herringbone", ".parquet"], binmode: true)
CLIENT.get_object(bucket: BUCKET, key: KEY, response_target: file.path)
file.reopen(file.path, "rb")
reader = Herringbone::Reader.new(file)
count = 0
id_sum = 0
reader.each_batch(50_000, as: :columns) do |batch|
  count += batch["id"].size
  id_sum += batch["id"].sum
end
expected_first = nil
each_row(1) { |row| expected_first = row }
first = reader.read(limit: 1).first
raise "row count #{count} != #{ROWS}" unless count == ROWS && reader.num_rows == ROWS
raise "id sum mismatch" unless id_sum == ROWS * (ROWS - 1) / 2
raise "first row mismatch: #{first.inspect}" unless first["token"] == expected_first[:token]
token = reader.read(from: ROWS - 1, limit: 1).first["token"]
raise "lookup failed" unless reader.read(where: {token: token}).map { |r| r["id"] } == [ROWS - 1]
puts "read back: #{reader.num_rows} rows in #{reader.row_groups.size} row groups, contents match"

# An upload whose block raises halfway through must be aborted
failed_key = "#{KEY}.failed"
UPLOADED_PARTS.clear
begin
  upload_stream(failed_key) do |io|
    Herringbone::Writer.open(io, SCHEMA) do |writer|
      each_row(ROWS) do |row|
        writer << row
        raise "simulated failure" if row[:id] == ROWS / 2
      end
    end
  end
  raise "the failed upload did not raise"
rescue Aws::S3::MultipartUploadError => e
  puts "failed upload raised #{e.class}: #{e.message} (#{UPLOADED_PARTS.size} parts had been uploaded)"
end
pending = CLIENT.list_multipart_uploads(bucket: BUCKET).uploads.select { |u| u.key == failed_key }
raise "multipart upload was not aborted: #{pending.map(&:upload_id)}" unless pending.empty?
begin
  CLIENT.head_object(bucket: BUCKET, key: failed_key)
  raise "an object was created for the failed upload"
rescue Aws::S3::Errors::NotFound
  puts "no object and no pending multipart upload left for #{failed_key}"
end
