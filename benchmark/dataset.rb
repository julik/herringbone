# frozen_string_literal: true

require "bigdecimal"
require "date"

# A Rails-shaped record: what `record.attributes` looks like for a typical `orders` table,
# with enums already mapped to their String names.
module Dataset
  STATUSES = %w[pending paid shipped delivered cancelled refunded].freeze
  PLANS = %w[free starter pro enterprise].freeze
  CURRENCIES = %w[EUR USD GBP].freeze
  EPOCH = Time.utc(2020, 1, 1).to_i

  COLUMNS = %w[
    id user_id status plan currency amount discount_rate email name notes
    item_count gift created_at updated_at shipped_on
  ].freeze

  module_function

  def herringbone_schema
    Herringbone::Schema.define do
      int64 :id, null: false
      int64 :user_id, null: false
      enum :status, values: STATUSES, null: false
      enum :plan, values: PLANS, null: false
      string :currency, null: false
      decimal :amount, precision: 12, scale: 2, null: false
      double :discount_rate
      string :email, null: false
      string :name
      string :notes
      int32 :item_count, null: false
      boolean :gift, null: false
      timestamp :created_at, unit: :micros, null: false
      timestamp :updated_at, unit: :micros, null: false
      date :shipped_on
    end
  end

  # Schema for parquet-ruby (njaremko/parquet-ruby). Its DSL is used because the documented
  # hash form for decimals fails in 0.9.0 ("no implicit conversion of Integer into String").
  def parquet_ruby_schema
    Parquet::Schema.define do
      field :id, :int64, nullable: false
      field :user_id, :int64, nullable: false
      field :status, :string, nullable: false
      field :plan, :string, nullable: false
      field :currency, :string, nullable: false
      field :amount, :decimal, precision: 12, scale: 2, nullable: false
      field :discount_rate, :double
      field :email, :string, nullable: false
      field :name, :string
      field :notes, :string
      field :item_count, :int32, nullable: false
      field :gift, :boolean, nullable: false
      field :created_at, :timestamp_micros, timezone: "UTC", nullable: false
      field :updated_at, :timestamp_micros, timezone: "UTC", nullable: false
      field :shipped_on, :date32
    end
  end

  # parquet-ruby 0.9.0 rejects Date values, and stores "YYYY-MM-DD" Strings a day early when the
  # local zone is ahead of UTC, so dates are handed to it as UTC-midnight Times
  def parquet_ruby_row(record)
    record.values.map { |v| v.is_a?(Date) ? Time.utc(v.year, v.month, v.day) : v }
  end

  # Deterministic record number +i+ (no RNG state, so it can be regenerated lazily in any order)
  def record(i)
    h = (i * 2_654_435_761) & 0xFFFF_FFFF
    created = Time.at(EPOCH + (h % 150_000_000), (h % 1_000_000), :usec).utc
    status = STATUSES[h % 6]
    {
      "id" => i,
      "user_id" => 1 + (h % 250_000),
      "status" => status,
      "plan" => PLANS[(h >> 3) % 4],
      "currency" => CURRENCIES[(h >> 5) % 3],
      "amount" => BigDecimal(h % 10_000_000) / 100,
      "discount_rate" => h % 5 == 0 ? nil : (h % 30) / 100.0,
      "email" => "user#{h % 250_000}@example.com",
      "name" => h % 11 == 0 ? nil : "Customer #{h % 250_000}",
      "notes" => h % 7 == 0 ? "Please leave the parcel at the door, order #{i}" : nil,
      "item_count" => 1 + (h % 12),
      "gift" => h.odd?,
      "created_at" => created,
      "updated_at" => created + (h % 86_400),
      "shipped_on" => %w[shipped delivered].include?(status) ? (created + 86_400 * 2).to_date : nil
    }
  end

  # Mimics `Model.find_each(batch_size:)`: yields records batch by batch, never holding more than one batch
  def each_record(count, batch_size: 1000)
    return enum_for(:each_record, count, batch_size: batch_size) unless block_given?
    (0...count).step(batch_size) do |start|
      batch = (start...[start + batch_size, count].min).map { |i| record(i) }
      batch.each { |r| yield r }
    end
  end
end
