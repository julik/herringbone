# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"
require "json"
require "digest"

module BenchmarkSuite
  class Corpus
    MANIFEST_VERSION = 1
    RECIPE_VERSION = 1
    INPUT_BATCH_ROWS = 1000
    DEFAULT = {
      "rows" => 20_000,
      "runs" => 3,
      "page_bytes" => 16_384,
      "page_rows" => 256,
      "group_rows" => 1000
    }.freeze
    LONG = DEFAULT.merge("rows" => 1_000_000, "runs" => 5).freeze
    SIGNED = %w[int8 int16 int32 int64].freeze
    UNSIGNED = %w[uint8 uint16 uint32 uint64].freeze
    LABELS = {"pending" => 0, "paid" => 1, "shipped" => 2}.freeze
    TEXT = ["Leave the parcel by the door", "東京 — café — مرحبا", "An ordinary customer note"].freeze
    TIMESTAMP_NANOSECONDS = {"millis" => 123_000_000, "micros" => 123_456_000, "nanos" => 123_456_789}.freeze

    attr_reader :directory, :config

    def initialize(directory, config)
      @directory = directory
      @config = config
      positive = config.values.all? { |value| value.is_a?(Integer) && value > 0 }
      unless positive && config.fetch("rows") % 40 == 0
        raise ArgumentError, "positive settings and rows divisible by 40 required"
      end
    end

    def prepare
      manifest_path = File.join(directory, "manifest.json")
      manifest = File.exist?(manifest_path) ? reuse_manifest(manifest_path) : create_manifest(manifest_path)
      files.each do |shard, legacy|
        verify([path(shard, legacy: legacy)], "read", shards: [shard], legacy: legacy)
      end
      manifest
    end

    def write(path, shard, legacy: false, coercible: false)
      active_seconds = 0.0
      interval_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      File.open(path, "wb") do |io|
        Herringbone::Writer.open(io, schema(legacy), **writer_options) do |writer|
          range(shard).each_slice(INPUT_BATCH_ROWS) do |indices|
            active_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - interval_started
            rows = indices.map { |index| record(index, legacy: legacy, coercible: coercible) }
            interval_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            rows.each { |row| writer << row }
            rows.clear
          end
        end
      end
      active_seconds + Process.clock_gettime(Process::CLOCK_MONOTONIC) - interval_started
    end

    def verify(paths, scenario, shards: (0...4).to_a, legacy: false)
      indices = expected_indices(shards, scenario)
      target_schema = expected_schema(scenario, legacy)
      count = paths.sum { |path| verify_file(path, target_schema, indices, scenario, legacy) }
      wanted_count = shards.sum { |shard| range(shard).size }
      wanted_count -= wanted_count / 10 if scenario == "delete"
      raise "row count mismatch: #{count} != #{wanted_count}" unless count == wanted_count

      count
    end

    def schema(legacy = false)
      Herringbone::Schema.define do |schema|
        legacy ? schema.int32(:id, null: false) : schema.int64(:id, null: false)
        schema.int32 :bucket, null: false
        (SIGNED + UNSIGNED).each { |type| schema.public_send(type, type) }
        schema.float :float32
        schema.double :float64
        schema.boolean :enabled
        schema.decimal :amount, precision: 12, scale: 2
        schema.string :email
        schema.string :notes
        schema.enum :status, values: LABELS
        schema.json :document
        schema.binary :bytes
        schema.fixed :fixed, length: 8
        schema.uuid :uuid
        schema.date :day
        schema.time :clock, unit: :micros
        %i[millis micros nanos].each { |unit| schema.timestamp unit, unit: unit }
        schema.string :segment unless legacy
      end
    end

    def record(index, legacy: false, coercible: false)
      row = expected(index, legacy: legacy)
      row["clock"] = Time.utc(2020, 1, 1) + Rational(row["clock"], 1_000_000)
      coercible ? coercible_record(row, index) : row
    end

    def expected(index, legacy: false)
      row = {
        "id" => index,
        "bucket" => index % 10,
        "int8" => index % 128 - 64,
        "int16" => index % 32_768 - 16_384,
        "int32" => index % 8_388_608 - 4_194_304,
        "int64" => -(1 << 40) + index,
        "uint8" => (1 << 7) + index % 127,
        "uint16" => (1 << 15) + index % 127,
        "uint32" => (1 << 31) + index % 127,
        "uint64" => (1 << 63) + index % 127,
        "float32" => (index % 2048 - 1024) / 8.0,
        "float64" => (index % 100_000 - 50_000) / 8.0,
        "enabled" => index.even?,
        "amount" => (index % 11 == 0) ? nil : BigDecimal(index % 100_000 - 50_000) / 100,
        "email" => "user#{index}@example.com",
        "notes" => (index % 7 == 0) ? nil : "#{TEXT[index % 3]}: order #{index}",
        "status" => LABELS.keys[index % 3],
        "document" => JSON.generate(id: index, tags: ["order", nil]),
        "bytes" => [index, index ^ 0xabcdef].pack("VV"),
        "fixed" => [index, 0].pack("VV"),
        "uuid" => format("00000000-0000-0000-0000-%012x", index),
        "day" => Date.new(2020, 1, 1) + index % 365,
        "clock" => (45_000 + index % 60) * 1_000_000 + 123_456
      }
      TIMESTAMP_NANOSECONDS.each do |name, fraction|
        row[name] = Time.at(1_700_000_000 + index, fraction, :nsec).utc
      end
      row["segment"] = index.even? ? "retail" : "business" unless legacy
      row
    end

    def files
      current = (0...4).map { |shard| [shard, false] }
      current + [[0, true], [2, true]]
    end

    def range(shard)
      shard_rows = config.fetch("rows") / 4
      (shard * shard_rows)...((shard + 1) * shard_rows)
    end

    def path(shard, legacy: false)
      File.join(directory, "#{legacy ? "legacy" : "current"}-#{shard}.parquet")
    end

    def writer_options
      {
        compression: :snappy,
        page_bytes: config.fetch("page_bytes"),
        page_rows: config.fetch("page_rows"),
        row_group_rows: config.fetch("group_rows"),
        row_group_bytes: 1 << 30
      }
    end

    private

    def reuse_manifest(manifest_path)
      manifest = JSON.parse(File.read(manifest_path))
      unless manifest["manifest_version"] == MANIFEST_VERSION && manifest["recipe_version"] == RECIPE_VERSION
        raise "unsupported corpus manifest or recipe; generate a corpus in a new directory"
      end
      unless manifest.fetch("settings") == config.except("runs")
        raise "corpus settings differ; choose another directory"
      end
      expected_paths = files.map { |shard, legacy| File.basename(path(shard, legacy: legacy)) }.sort
      raise "unexpected corpus files" unless manifest.fetch("files").keys.sort == expected_paths

      manifest.fetch("files").each do |name, hash|
        actual = Digest::SHA256.file(File.join(directory, name)).hexdigest
        raise "corrupt corpus file: #{name}" unless actual == hash
      end
      manifest
    end

    def create_manifest(manifest_path)
      raise "corpus directory is not empty" if Dir.exist?(directory) && !Dir.empty?(directory)

      Dir.mkdir(directory) unless Dir.exist?(directory)
      files.each { |shard, legacy| write(path(shard, legacy: legacy), shard, legacy: legacy) }
      hashes = files.to_h do |shard, legacy|
        input_path = path(shard, legacy: legacy)
        [File.basename(input_path), Digest::SHA256.file(input_path).hexdigest]
      end
      manifest = {
        "manifest_version" => MANIFEST_VERSION,
        "recipe_version" => RECIPE_VERSION,
        "settings" => config.except("runs"),
        "producer" => {
          "herringbone" => Herringbone::VERSION,
          "generator_sha256" => Digest::SHA256.file(__FILE__).hexdigest
        },
        "files" => hashes
      }
      File.write(manifest_path, JSON.pretty_generate(manifest))
      manifest
    end

    def coercible_record(row, index)
      (SIGNED + UNSIGNED + %w[id bucket float32 float64 amount]).each do |field|
        row[field] = row[field].to_s unless row[field].nil?
      end
      row["enabled"] = row["enabled"] ? "yes" : "no"
      row["status"] = LABELS.fetch(row["status"])
      row["document"] = {id: index, tags: ["order", nil]}
      row["uuid"] = row["uuid"].delete("-")
      row["day"] = row["day"].iso8601
      row["clock"] = row["clock"].strftime("%H:%M:%S.%6N")
      TIMESTAMP_NANOSECONDS.each_key { |name| row[name] = row[name].iso8601(9) }
      row
    end

    def verify_file(path, target_schema, indices, scenario, legacy)
      count = 0
      File.open(path, "rb") do |io|
        reader = Herringbone::Reader.new(io)
        raise "schema mismatch: #{path}" unless reader.schema == target_schema

        reader.each_row do |actual|
          index = next_index(indices)
          wanted = expected_output(index, scenario, legacy)
          raise "value/order mismatch at row #{index}: #{path}" unless actual == wanted

          count += 1
        end
      end
      count
    end

    def expected_schema(scenario, legacy)
      case scenario
      when "union" then schema(true).union(schema)
      when "intersection" then schema(true).intersect(schema)
      else schema(legacy)
      end
    end

    def expected_indices(shards, scenario)
      Enumerator.new do |indices|
        shards.each do |shard|
          range(shard).each do |index|
            next if scenario == "delete" && index % 10 == 0

            indices << index
          end
        end
      end
    end

    def next_index(indices)
      indices.next
    rescue StopIteration
      raise "unexpected extra output rows"
    end

    def expected_output(index, scenario, legacy)
      row = expected(index, legacy: legacy)
      case scenario
      when "replace_rows"
        row["email"] = nil if index % 10 == 0
      when "replace_column"
        row["email"] = nil
      when "union"
        shard = index / (config.fetch("rows") / 4)
        row["segment"] = nil if shard.even?
      when "intersection"
        row.delete("segment")
      end
      row
    end
  end
end
