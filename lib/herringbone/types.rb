# frozen_string_literal: true

require "date"
require "time"
require "json"
require "bigdecimal"

module Herringbone
  # Conversion between physical Parquet values and Ruby objects, driven by the
  # logical type (or legacy converted type) of a column.
  #
  #   STRING/ENUM/JSON      <-> String (UTF-8)
  #   BYTE_ARRAY/FLBA/BSON  <-> String (binary)
  #   INTEGER (signed/uns.) <-> Integer
  #   DATE                  <-> Date
  #   TIMESTAMP, INT96      <-> Time (UTC)
  #   TIME                  <-> Integer in the column's unit since midnight
  #   DECIMAL               <-> BigDecimal
  #   UUID                  <-> String "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  #   FLOAT16               <-> Float
  module Types
    module_function

    # Shorthand for Format::Type
    T = Format::Type
    # Shorthand for Format::ConvertedType
    C = Format::ConvertedType

    # Julian day number of 1970-01-01, the origin of DATE columns
    EPOCH_JD = Date.new(1970, 1, 1).jd
    # Julian day number of 1970-01-01, the origin of the day half of an INT96 timestamp
    JULIAN_EPOCH_DAY = 2_440_588 # Julian day number of 1970-01-01, used by INT96
    # Nanoseconds in a day, used to split INT96 timestamps into day and nanoseconds of day
    NANOS_PER_DAY = 86_400 * 1_000_000_000

    # Ticks per second for each TimeUnit
    UNIT_DIVISORS = {millis: 1_000, micros: 1_000_000, nanos: 1_000_000_000}.freeze
    # Sub-second unit names understood by +Time.at+, for each TimeUnit
    UNIT_NAMES = {millis: :millisecond, micros: :microsecond, nanos: :nanosecond}.freeze

    # Shorthand for building a LogicalType union.
    # @param kw [Hash{Symbol => Thrift::Struct}] the single union member to set; any LogicalType
    #   field is accepted, those used in this module are listed below
    # @option kw [Format::StringType] :string
    # @option kw [Format::EnumType] :enum
    # @option kw [Format::JsonType] :json
    # @option kw [Format::BsonType] :bson
    # @option kw [Format::UUIDType] :uuid
    # @option kw [Format::DateType] :date
    # @option kw [Format::Float16Type] :float16
    # @option kw [Format::IntType] :integer bit width and signedness
    # @option kw [Format::DecimalType] :decimal scale and precision
    # @option kw [Format::TimeType] :time unit and UTC adjustment
    # @option kw [Format::TimestampType] :timestamp unit and UTC adjustment
    # @return [Format::LogicalType]
    def lt(**kw) = Format::LogicalType.new(**kw)

    # TimeUnit union for a unit name.
    # @param unit [Symbol, String] +:millis+/+:ms+, +:micros+/+:us+ or +:nanos+/+:ns+
    # @return [Format::TimeUnit]
    # @raise [ArgumentError] for any other unit
    def time_unit(unit)
      case unit.to_sym
      when :millis, :ms then Format::TimeUnit.millis
      when :micros, :us then Format::TimeUnit.micros
      when :nanos, :ns then Format::TimeUnit.nanos
      else raise ArgumentError, "Unknown time unit #{unit.inspect}"
      end
    end

    # Physical attributes of an annotated integer column, with both the INTEGER logical type
    # and the matching INT_n/UINT_n converted type.
    # @param bits [Integer] bit width: 8, 16, 32 or 64 (64 is stored as INT64, the rest as INT32)
    # @param signed [Boolean] whether the integers are signed
    # @return [Hash{Symbol => Object}] +:type+, +:converted_type+ and +:logical_type+
    def int_type(bits, signed)
      physical = (bits == 64) ? T::INT64 : T::INT32
      converted = signed ? C.const_get("INT_#{bits}") : C.const_get("UINT_#{bits}")
      {type: physical, converted_type: converted,
       logical_type: lt(integer: Format::IntType.new(bit_width: bits, is_signed: signed))}
    end

    # Physical attributes (type, logical type etc.) for a DSL type name
    # @param type [Symbol, String] column type name, e.g. +:string+, +:int64+, +:decimal+, +:timestamp+
    # @param opts [Hash{Symbol => Object}] type-specific options
    # @option opts [Boolean] :parquet_enum for +:enum+, annotate as ENUM instead of STRING
    # @option opts [Integer] :length byte length for +:fixed+ (required)
    # @option opts [Symbol] :unit (:micros) for +:time+ and +:timestamp+, see {time_unit}
    # @option opts [Boolean] :utc (true) for +:time+ and +:timestamp+, sets +is_adjusted_to_utc+;
    #   the legacy converted type is only written when true
    # @option opts [Integer] :precision number of decimal digits for +:decimal+ (required)
    # @option opts [Integer] :scale (0) digits after the decimal point for +:decimal+
    # @option opts [Symbol] :physical for +:decimal+, force +:int32+, +:int64+, +:binary+ or
    #   +:fixed+ storage instead of picking the smallest by precision
    # @return [Hash{Symbol => Object}] keyword arguments for Schema::Node.new: +:type+ and,
    #   where applicable, +:type_length+, +:converted_type+, +:logical_type+, +:scale+, +:precision+
    # @raise [ArgumentError] for an unknown type, unit, or invalid decimal precision/scale
    # @raise [KeyError] when a required option is missing or +:physical+ is not recognized
    def physical_attributes(type, **opts)
      case type.to_sym
      when :boolean then {type: T::BOOLEAN}
      when :int8 then int_type(8, true)
      when :int16 then int_type(16, true)
      when :int32 then {type: T::INT32}
      when :int64 then {type: T::INT64}
      when :uint8 then int_type(8, false)
      when :uint16 then int_type(16, false)
      when :uint32 then int_type(32, false)
      when :uint64 then int_type(64, false)
      when :float then {type: T::FLOAT}
      when :double then {type: T::DOUBLE}
      when :float16 then {type: T::FIXED_LEN_BYTE_ARRAY, type_length: 2, logical_type: lt(float16: Format::Float16Type.new)}
      when :string then {type: T::BYTE_ARRAY, converted_type: C::UTF8, logical_type: lt(string: Format::StringType.new)}
      when :binary then {type: T::BYTE_ARRAY}
      when :json then {type: T::BYTE_ARRAY, converted_type: C::JSON, logical_type: lt(json: Format::JsonType.new)}
      when :bson then {type: T::BYTE_ARRAY, converted_type: C::BSON, logical_type: lt(bson: Format::BsonType.new)}
      when :enum
        if opts[:parquet_enum]
          {type: T::BYTE_ARRAY, converted_type: C::ENUM, logical_type: lt(enum: Format::EnumType.new)}
        else
          physical_attributes(:string)
        end
      when :uuid then {type: T::FIXED_LEN_BYTE_ARRAY, type_length: 16, logical_type: lt(uuid: Format::UUIDType.new)}
      when :date then {type: T::INT32, converted_type: C::DATE, logical_type: lt(date: Format::DateType.new)}
      when :int96 then {type: T::INT96}
      when :fixed
        {type: T::FIXED_LEN_BYTE_ARRAY, type_length: Integer(opts.fetch(:length))}
      when :time
        unit = time_unit(opts.fetch(:unit, :micros))
        converted = {millis: C::TIME_MILLIS, micros: C::TIME_MICROS}[unit.to_sym]
        {type: unit.millis ? T::INT32 : T::INT64, converted_type: opts.fetch(:utc, true) ? converted : nil,
         logical_type: lt(time: Format::TimeType.new(is_adjusted_to_utc: opts.fetch(:utc, true), unit: unit))}
      when :timestamp
        unit = time_unit(opts.fetch(:unit, :micros))
        converted = {millis: C::TIMESTAMP_MILLIS, micros: C::TIMESTAMP_MICROS}[unit.to_sym]
        {type: T::INT64, converted_type: opts.fetch(:utc, true) ? converted : nil,
         logical_type: lt(timestamp: Format::TimestampType.new(is_adjusted_to_utc: opts.fetch(:utc, true), unit: unit))}
      when :decimal
        precision = Integer(opts.fetch(:precision))
        scale = Integer(opts.fetch(:scale, 0))
        raise ArgumentError, "Decimal precision must be positive" unless precision.positive?
        raise ArgumentError, "Decimal scale must be between 0 and precision" unless scale.between?(0, precision)
        physical = if opts[:physical]
          {int32: {type: T::INT32}, int64: {type: T::INT64}, binary: {type: T::BYTE_ARRAY},
           fixed: {type: T::FIXED_LEN_BYTE_ARRAY, type_length: decimal_bytes(precision)}}.fetch(opts[:physical])
        elsif precision <= 9 then {type: T::INT32}
        elsif precision <= 18 then {type: T::INT64}
        else {type: T::FIXED_LEN_BYTE_ARRAY, type_length: decimal_bytes(precision)}
        end
        physical.merge(converted_type: C::DECIMAL, scale: scale, precision: precision,
          logical_type: lt(decimal: Format::DecimalType.new(scale: scale, precision: precision)))
      else
        raise ArgumentError, "Unknown column type #{type.inspect}"
      end
    end

    # Minimal number of bytes to hold a signed integer of +precision+ decimal digits
    # @param precision [Integer] number of decimal digits
    # @return [Integer] byte length for a FIXED_LEN_BYTE_ARRAY decimal
    def decimal_bytes(precision)
      max = 10**precision
      n = 1
      n += 1 while (1 << (8 * n - 1)) <= max
      n
    end

    # Normalized logical kind of a node: [symbol, details]
    #
    # The LogicalType wins when present; otherwise the legacy converted type is mapped onto
    # the same shapes. Details depend on the kind:
    #   [:integer, bit_width, signed]
    #   [:decimal, scale, precision]
    #   [:timestamp, unit, adjusted_to_utc]   (unit is :millis, :micros or :nanos)
    #   [:time, unit, adjusted_to_utc]
    #   [kind]                                for other annotations (:string, :date, :uuid ...)
    #   [nil]                                 for unannotated columns
    # @param node [Schema::Node] leaf node of the physical schema
    # @return [Array] kind Symbol (or nil) followed by its details
    def logical_of(node)
      if (kind = node.logical_type&.kind)
        name, payload = kind
        case name
        when :integer then return [:integer, payload.bit_width, payload.is_signed]
        when :decimal then return [:decimal, payload.scale, payload.precision]
        when :timestamp then return [:timestamp, payload.unit.to_sym, payload.is_adjusted_to_utc]
        when :time then return [:time, payload.unit.to_sym, payload.is_adjusted_to_utc]
        else return [name]
        end
      end
      case node.converted_type
      when C::UTF8 then [:string]
      when C::ENUM then [:enum]
      when C::JSON then [:json]
      when C::BSON then [:bson]
      when C::DECIMAL then [:decimal, node.scale || 0, node.precision]
      when C::DATE then [:date]
      when C::TIME_MILLIS then [:time, :millis, true]
      when C::TIME_MICROS then [:time, :micros, true]
      when C::TIMESTAMP_MILLIS then [:timestamp, :millis, true]
      when C::TIMESTAMP_MICROS then [:timestamp, :micros, true]
      when C::UINT_8 then [:integer, 8, false]
      when C::UINT_16 then [:integer, 16, false]
      when C::UINT_32 then [:integer, 32, false]
      when C::UINT_64 then [:integer, 64, false]
      when C::INT_8 then [:integer, 8, true]
      when C::INT_16 then [:integer, 16, true]
      when C::INT_32 then [:integer, 32, true]
      when C::INT_64 then [:integer, 64, true]
      else [nil]
      end
    end

    # Returns a lambda converting a physical value into a Ruby value, or nil when no conversion is needed.
    # @param node [Schema::Node] leaf node of the physical schema
    # @return [Proc, nil] one-argument converter, or nil when decoded values are used as-is
    def reader_for(node)
      kind, a, b = logical_of(node)
      type = node.type
      case kind
      when :string, :enum, :json
        return ->(v) { v.force_encoding(Encoding::UTF_8) } if type == T::BYTE_ARRAY || type == T::FIXED_LEN_BYTE_ARRAY
      when :integer
        if !b && (type == T::INT32 || type == T::INT64)
          mask = (type == T::INT32) ? 0xFFFF_FFFF : 0xFFFF_FFFF_FFFF_FFFF
          return ->(v) { v & mask }
        end
      when :date
        return ->(v) { Date.jd(EPOCH_JD + v, Date::GREGORIAN) } if type == T::INT32
      when :timestamp
        return timestamp_reader(a) if type == T::INT64
      when :decimal
        return decimal_reader(type, a)
      when :uuid
        return ->(v) { v.unpack1("H*").insert(20, "-").insert(16, "-").insert(12, "-").insert(8, "-") } if type == T::FIXED_LEN_BYTE_ARRAY
      when :float16
        return ->(v) { half_to_float(v.unpack1("v")) } if type == T::FIXED_LEN_BYTE_ARRAY
      end
      return int96_reader if type == T::INT96
      nil
    end

    # Converter from an INT64 timestamp to a UTC Time.
    # @param unit [Symbol] +:millis+, +:micros+ or +:nanos+
    # @return [Proc] lambda taking an Integer count of +unit+ since the epoch
    # @raise [KeyError] for an unknown unit
    def timestamp_reader(unit)
      div = UNIT_DIVISORS.fetch(unit)
      name = UNIT_NAMES.fetch(unit)
      ->(v) { Time.at(v / div, v % div, name).utc }
    end

    # Converter from a decoded INT96 value to a UTC Time.
    # @return [Proc] lambda taking a +[nanoseconds_of_day, julian_day]+ pair
    def int96_reader
      lambda do |(nanos, day)|
        secs = (day - JULIAN_EPOCH_DAY) * 86_400
        Time.at(secs + nanos / 1_000_000_000, nanos % 1_000_000_000, :nanosecond).utc
      end
    end

    # Converter from a stored unscaled decimal to a BigDecimal.
    # @param type [Integer] physical type (Format::Type) of the column
    # @param scale [Integer] digits after the decimal point
    # @return [Proc, nil] lambda taking an Integer (INT32/INT64) or big-endian two's complement
    #   bytes (BYTE_ARRAY/FIXED_LEN_BYTE_ARRAY), or nil for any other physical type
    def decimal_reader(type, scale)
      to_decimal = scale.zero? ? ->(i) { BigDecimal(i) } : ->(i) { BigDecimal("#{i}e-#{scale}") }
      case type
      when T::INT32, T::INT64 then to_decimal
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY
        ->(v) { to_decimal.call(be_to_int(v)) }
      end
    end

    # Big-endian two's complement bytes to Integer
    # @param bytes [String] binary string; empty decodes as 0
    # @return [Integer]
    def be_to_int(bytes)
      return 0 if bytes.empty?
      i = bytes.unpack1("H*").to_i(16)
      bits = bytes.bytesize * 8
      (i >= (1 << (bits - 1))) ? i - (1 << bits) : i
    end

    # Integer to big-endian two's complement bytes of a fixed width
    # @param i [Integer] value to encode
    # @param nbytes [Integer] output width in bytes
    # @return [String] binary string of +nbytes+ bytes
    # @raise [EncodeError] when +i+ does not fit in +nbytes+ bytes
    def int_to_be(i, nbytes)
      bits = nbytes * 8
      raise EncodeError, "Decimal value #{i} does not fit in #{nbytes} bytes" unless i.bit_length < bits
      i += 1 << bits if i.negative?
      [i.to_s(16).rjust(nbytes * 2, "0")].pack("H*")
    end

    # Decodes an IEEE 754 half-precision value, including subnormals, infinities and NaN.
    # @param h [Integer] 16-bit pattern
    # @return [Float]
    def half_to_float(h)
      sign = (h >> 15).zero? ? 1.0 : -1.0
      exp = (h >> 10) & 0x1F
      frac = h & 0x3FF
      if exp.zero?
        sign * frac * 2.0**-24
      elsif exp == 31
        frac.zero? ? sign * Float::INFINITY : Float::NAN
      else
        sign * (1 + frac / 1024.0) * 2.0**(exp - 15)
      end
    end

    # Rounds a Float to the nearest half-precision value (ties to even). Every step is exact
    # in double arithmetic, so there is no double rounding.
    # @param f [Float] value to round; overflows to infinity, NaN becomes the canonical quiet NaN
    # @return [Integer] 16-bit pattern
    def float_to_half(f)
      return 0x7E00 if f.nan?
      sign = (f.negative? || (f.zero? && (1.0 / f).negative?)) ? 0x8000 : 0
      a = f.abs
      return sign | 0x7C00 if a >= 65_520.0
      return sign | (a * 2.0**24).round(half: :even) if a < 2.0**-14
      e = Math.frexp(a)[1] - 1
      m = ((a / 2.0**e - 1) * 1024).round(half: :even)
      if m == 1024
        m = 0
        e += 1
      end
      sign | ((e + 15) << 10) | m
    end

    # Returns a lambda converting a Ruby value into the physical value for +node+.
    # Besides the canonical Ruby type of each column (see the table at the top), columns accept
    # the values Rails and plain Ruby code commonly hand over:
    #   date:      Date, Time/DateTime (its calendar date), ISO-8601 String, Integer days since epoch
    #   timestamp: Time, DateTime, ActiveSupport::TimeWithZone, Date (midnight UTC), ISO-8601 String,
    #              Integer in the column's unit
    #   time:      Time (its time of day), "HH:MM[:SS[.fraction]]" String, Integer in the column's unit
    #   json:      String (used as-is) or any other object (serialized with JSON.generate)
    #   string:    String, Symbol or anything responding to to_s
    #   boolean:   true/false, 1/0, "true"/"false", "t"/"f", "1"/"0", "yes"/"no"
    #   integers:  Integer, or a Float/BigDecimal/Rational/String holding a whole number
    #   decimal:   BigDecimal, Integer, Rational, Float or numeric String
    #   uuid:      String with or without dashes, or 16 raw bytes
    # The returned lambda raises ArgumentError or RangeError for values it cannot convert.
    # @param node [Schema::Node] leaf node of the physical schema
    # @return [Proc, nil] one-argument converter; nil only for a column with no recognized
    #   physical type
    def writer_for(node)
      kind, a, b = logical_of(node)
      type = node.type
      case kind
      when :date
        return method(:date_to_days)
      when :timestamp
        return timestamp_writer(a, b)
      when :time
        return time_writer(a) if type == T::INT32 || type == T::INT64
      when :json
        return ->(v) { v.is_a?(String) ? v : JSON.generate(v) }
      when :string, :enum
        values = node.enum_values
        return enum_writer(values) if values
        return ->(v) { v.is_a?(String) ? v : v.to_s }
      when :decimal
        return decimal_writer(node, a)
      when :uuid
        return fixed_checker(16) do |v|
          (v.bytesize == 16 && v.encoding == Encoding::BINARY) ? v : [v.to_s.delete("-")].pack("H*")
        end
      when :float16
        return ->(v) { [float_to_half(Float(v))].pack("v") }
      when :integer
        if !b && (type == T::INT32 || type == T::INT64)
          bits = (type == T::INT32) ? 32 : 64
          check = int_checker(0, (1 << a) - 1)
          return ->(v) { Encodings::Delta.wrap(check.call(v), bits) }
        elsif type == T::INT32 || type == T::INT64
          return int_checker(-(1 << (a - 1)), (1 << (a - 1)) - 1)
        end
      end

      case type
      when T::BOOLEAN then method(:to_boolean)
      when T::INT32 then int_checker(-(1 << 31), (1 << 31) - 1)
      when T::INT64 then int_checker(-(1 << 63), (1 << 63) - 1)
      when T::FLOAT, T::DOUBLE then ->(v) { v.is_a?(Float) ? v : Float(v) }
      when T::BYTE_ARRAY then ->(v) { v.is_a?(String) ? v : v.to_s }
      when T::FIXED_LEN_BYTE_ARRAY then fixed_checker(node.type_length) { |v| v.is_a?(String) ? v : v.to_s }
      when T::INT96
        lambda do |v|
          return v if v.is_a?(Array)
          v = to_time(v)
          nanos = v.to_i * 1_000_000_000 + v.nsec
          day, nanos_of_day = nanos.divmod(NANOS_PER_DAY)
          [nanos_of_day, day + JULIAN_EPOCH_DAY]
        end
      end
    end

    # Values accepted for a boolean column (strings are also matched case-insensitively)
    BOOLEANS = {
      true => true, false => false, 1 => true, 0 => false,
      "true" => true, "false" => false, "t" => true, "f" => false, "1" => true, "0" => false,
      "yes" => true, "no" => false, "TRUE" => true, "FALSE" => false, "T" => true, "F" => false
    }.freeze

    # Coerces a value to true/false using BOOLEANS.
    # @param v [Object] true/false, 1/0, or a String/Symbol such as "yes" or :false
    # @return [Boolean]
    # @raise [ArgumentError] when +v+ is not recognized as a boolean
    def to_boolean(v)
      BOOLEANS.fetch(v) do
        s = (v.is_a?(String) || v.is_a?(Symbol)) ? v.to_s.downcase : nil
        BOOLEANS.fetch(s) { raise ArgumentError, "expected a boolean, got #{v.inspect}" }
      end
    end

    # Days since the Unix epoch in the proleptic Gregorian calendar, as stored in DATE columns.
    # @param v [Date, String, Integer, #to_date] a Date, an ISO-8601 date String, an Integer
    #   (returned as-is) or anything responding to +to_date+ (Time, DateTime)
    # @return [Integer]
    # @raise [ArgumentError] when +v+ cannot be turned into a Date
    def date_to_days(v)
      return v if v.is_a?(Integer)
      d = case v
      when Date then v
      when String then Date.iso8601(v)
      else
        raise ArgumentError, "expected a Date, got #{v.class}" unless v.respond_to?(:to_date)
        v.to_date
      end
      # Use the civil date, so dates before 1582 in Ruby's default calendar are proleptic Gregorian
      Date.civil(d.year, d.mon, d.mday, Date::GREGORIAN).jd - EPOCH_JD
    end

    # Converts the values a timestamp column accepts into a Time (or Time-like) object
    # @param v [Time, DateTime, Date, String, #to_i] a Time, DateTime, Date (taken as midnight UTC),
    #   ISO-8601 (or +Date._parse+-able) String, taken as UTC when it has no offset, or a Time-like
    #   object responding to +to_i+ and +nsec+
    # @return [Time, Object] a Time, or +v+ itself when it is Time-like
    # @raise [ArgumentError] when +v+ is none of the above, or the String cannot be parsed, has no
    #   date or names a zone without its offset
    def to_time(v)
      case v
      when Time then v
      when DateTime then v.to_time
      when Date then Time.utc(v.year, v.month, v.day)
      when String then string_to_time(v)
      else
        # ActiveSupport::TimeWithZone and friends
        raise ArgumentError, "expected a Time, got #{v.class}" unless v.respond_to?(:to_i) && v.respond_to?(:nsec)
        v
      end
    end

    # Parses a timestamp String, taking one without an offset as UTC
    # @param v [String] e.g. "2024-05-01T12:00:00+02:00", "2024-05-01 12:00" or "2024-05-01"
    # @return [Time] at the String's offset, or in UTC
    # @raise [ArgumentError] when +v+ has no date, or names a zone without its offset
    def string_to_time(v)
      # Time.parse would read a String without an offset in the zone of the machine
      # running the write, so the same input would give different files
      h = Date._parse(v)
      raise ArgumentError, "no date in timestamp #{v.inspect}" unless h[:year] && h[:mon] && h[:mday]
      raise ArgumentError, "unknown time zone in timestamp #{v.inspect}" if h[:zone] && !h[:offset]
      sec = (h[:sec] || 0) + (h[:sec_fraction] || 0)
      Time.new(h[:year], h[:mon], h[:mday], h[:hour] || 0, h[:min] || 0, sec, h[:offset] || "UTC")
    end

    # Converter from a timestamp-like value to an INT64 count of +unit+ since the epoch.
    # Integers pass through unchanged; sub-unit precision is truncated.
    # @param unit [Symbol] +:millis+, +:micros+ or +:nanos+
    # @param utc [Boolean] whether the column is adjusted to UTC; when false the local wall
    #   clock time of the value (its UTC offset added) is stored
    # @return [Proc] one-argument lambda, see {to_time} for accepted values
    # @raise [KeyError] for an unknown unit
    def timestamp_writer(unit, utc)
      mult = UNIT_DIVISORS.fetch(unit)
      lambda do |v|
        return v if v.is_a?(Integer)
        t = to_time(v)
        secs = t.to_i
        # Local (not UTC-adjusted) timestamps store the wall clock time
        secs += t.utc_offset unless utc
        secs * mult + t.nsec * mult / 1_000_000_000
      end
    end

    # Converter from a time of day to a count of +unit+ since midnight.
    # The lambda accepts an Integer (returned as-is), an "HH:MM[:SS[.fraction]]" String or
    # anything responding to +hour+ and +nsec+ (Time, DateTime), and raises ArgumentError or
    # RangeError for anything else or a time past 23:59:59.
    # @param unit [Symbol] +:millis+, +:micros+ or +:nanos+
    # @return [Proc] one-argument lambda
    # @raise [KeyError] for an unknown unit
    def time_writer(unit)
      mult = UNIT_DIVISORS.fetch(unit)
      lambda do |v|
        return v if v.is_a?(Integer)
        if v.is_a?(String)
          m = /\A(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?\z/.match(v) or
            raise ArgumentError, "expected HH:MM[:SS[.fraction]], got #{v.inspect}"
          nanos = (m[4] || "").ljust(9, "0").to_i
          secs = m[1].to_i * 3600 + m[2].to_i * 60 + m[3].to_i
        else
          raise ArgumentError, "expected a Time, got #{v.class}" unless v.respond_to?(:hour) && v.respond_to?(:nsec)
          nanos = v.nsec
          secs = v.hour * 3600 + v.min * 60 + v.sec
        end
        raise RangeError, "time of day out of range: #{v.inspect}" unless secs < 86_400
        secs * mult + nanos * mult / 1_000_000_000
      end
    end

    # String column restricted to a set of values. +values+ is an Array of labels, or a Hash of
    # label => stored value like Rails' `Model.statuses`, in which case either is accepted.
    # Symbols are accepted in place of String labels.
    # @param values [Array<String, Symbol>, Hash{String, Symbol => Object}] allowed labels
    # @return [Proc] lambda returning the String label, raising ArgumentError for any other value
    def enum_writer(values)
      labels = {}
      if values.is_a?(Hash)
        values.each do |label, stored|
          labels[label.to_s] = label.to_s
          labels[stored] = label.to_s unless stored.is_a?(String) || stored.is_a?(Symbol)
        end
      else
        values.each { |label| labels[label.to_s] = label.to_s }
      end
      lambda do |v|
        labels.fetch(v.is_a?(Symbol) ? v.to_s : v) do
          raise ArgumentError, "#{v.inspect} is not one of #{labels.values.uniq.join(", ")}"
        end
      end
    end

    # Converts to Integer, rejecting fractional numbers and values outside min..max
    # @param min [Integer] smallest accepted value
    # @param max [Integer] largest accepted value
    # @return [Proc] lambda raising ArgumentError for non-integers and RangeError when out of range
    def int_checker(min, max)
      lambda do |v|
        i = Integer(v)
        raise ArgumentError, "#{v.inspect} is not an integer" unless v.is_a?(Integer) || !v.is_a?(Numeric) || v == i
        raise RangeError, "#{i} is outside #{min}..#{max}" unless i.between?(min, max)
        i
      end
    end

    # Wraps a conversion to a String and checks the result has exactly +length+ bytes.
    # @param length [Integer] required byte length
    # @yield [v] converts the incoming value
    # @yieldparam v [Object] value handed to the writer
    # @yieldreturn [String] bytes to store
    # @return [Proc] lambda raising ArgumentError when the converted String has another length
    def fixed_checker(length, &convert)
      lambda do |v|
        s = convert.call(v)
        raise ArgumentError, "expected #{length} bytes, got #{s.bytesize}" unless s.bytesize == length
        s
      end
    end

    # Converter from a numeric value to the stored unscaled decimal. Values are rounded
    # (half away from zero) to +scale+ digits; the lambda raises RangeError when the result
    # exceeds the column's precision.
    # @param node [Schema::Node] DECIMAL leaf node, for its physical type, precision and type length
    # @param scale [Integer] digits after the decimal point
    # @return [Proc, nil] lambda returning an Integer (INT32/INT64) or big-endian two's complement
    #   bytes (FIXED_LEN_BYTE_ARRAY, BYTE_ARRAY with minimal length), or nil for any other
    #   physical type
    def decimal_writer(node, scale)
      mult = 10**scale
      limit = node.precision ? 10**node.precision : nil
      to_unscaled = lambda do |v|
        r = case v
        when Integer then v * mult
        when Float, String then Rational(v.to_s) * mult
        else v.to_r * mult
        end
        r = r.round if r.is_a?(Rational)
        i = r.to_i
        raise RangeError, "#{v} does not fit DECIMAL(#{node.precision}, #{scale})" if limit && i.abs >= limit
        i
      end
      case node.type
      when T::INT32, T::INT64 then to_unscaled
      when T::FIXED_LEN_BYTE_ARRAY
        len = node.type_length
        ->(v) { int_to_be(to_unscaled.call(v), len) }
      when T::BYTE_ARRAY
        lambda do |v|
          i = to_unscaled.call(v)
          int_to_be(i, [(i.bit_length + 8) / 8, 1].max)
        end
      end
    end
  end
end
