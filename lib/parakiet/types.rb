# frozen_string_literal: true

require "date"

module Parakiet
  # Conversion between physical Parquet values and Ruby objects, driven by the
  # logical type (or legacy converted type) of a column.
  #
  #   STRING/ENUM/JSON      <-> String (UTF-8)
  #   BYTE_ARRAY/FLBA/BSON  <-> String (binary)
  #   INTEGER (signed/uns.) <-> Integer
  #   DATE                  <-> Date
  #   TIMESTAMP, INT96      <-> Time (UTC)
  #   TIME                  <-> Integer in the column's unit since midnight
  #   DECIMAL               <-> BigDecimal (Rational if bigdecimal cannot be loaded)
  #   UUID                  <-> String "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  #   FLOAT16               <-> Float
  module Types
    module_function

    T = Format::Type
    C = Format::ConvertedType

    EPOCH_JD = Date.new(1970, 1, 1).jd
    JULIAN_EPOCH_DAY = 2_440_588 # Julian day number of 1970-01-01, used by INT96
    NANOS_PER_DAY = 86_400 * 1_000_000_000

    UNIT_DIVISORS = { millis: 1_000, micros: 1_000_000, nanos: 1_000_000_000 }.freeze
    UNIT_NAMES = { millis: :millisecond, micros: :microsecond, nanos: :nanosecond }.freeze

    BIGDECIMAL_AVAILABLE = begin
      require "bigdecimal"
      true
    rescue LoadError
      false
    end

    def lt(**kw) = Format::LogicalType.new(**kw)

    def time_unit(unit)
      case unit.to_sym
      when :millis, :ms then Format::TimeUnit.millis
      when :micros, :us then Format::TimeUnit.micros
      when :nanos, :ns then Format::TimeUnit.nanos
      else raise ArgumentError, "Unknown time unit #{unit.inspect}"
      end
    end

    def int_type(bits, signed)
      physical = bits == 64 ? T::INT64 : T::INT32
      converted = signed ? C.const_get("INT_#{bits}") : C.const_get("UINT_#{bits}")
      { type: physical, converted_type: converted,
        logical_type: lt(integer: Format::IntType.new(bit_width: bits, is_signed: signed)) }
    end

    # Physical attributes (type, logical type etc.) for a DSL type name
    def physical_attributes(type, **opts)
      case type.to_sym
      when :boolean, :bool then { type: T::BOOLEAN }
      when :int8 then int_type(8, true)
      when :int16 then int_type(16, true)
      when :int32 then { type: T::INT32 }
      when :int64 then { type: T::INT64 }
      when :uint8 then int_type(8, false)
      when :uint16 then int_type(16, false)
      when :uint32 then int_type(32, false)
      when :uint64 then int_type(64, false)
      when :float then { type: T::FLOAT }
      when :double then { type: T::DOUBLE }
      when :float16 then { type: T::FIXED_LEN_BYTE_ARRAY, type_length: 2, logical_type: lt(float16: Format::Float16Type.new) }
      when :string, :utf8 then { type: T::BYTE_ARRAY, converted_type: C::UTF8, logical_type: lt(string: Format::StringType.new) }
      when :binary, :bytes then { type: T::BYTE_ARRAY }
      when :json then { type: T::BYTE_ARRAY, converted_type: C::JSON, logical_type: lt(json: Format::JsonType.new) }
      when :bson then { type: T::BYTE_ARRAY, converted_type: C::BSON, logical_type: lt(bson: Format::BsonType.new) }
      when :enum then { type: T::BYTE_ARRAY, converted_type: C::ENUM, logical_type: lt(enum: Format::EnumType.new) }
      when :uuid then { type: T::FIXED_LEN_BYTE_ARRAY, type_length: 16, logical_type: lt(uuid: Format::UUIDType.new) }
      when :date then { type: T::INT32, converted_type: C::DATE, logical_type: lt(date: Format::DateType.new) }
      when :int96 then { type: T::INT96 }
      when :fixed
        { type: T::FIXED_LEN_BYTE_ARRAY, type_length: Integer(opts.fetch(:length)) }
      when :time
        unit = time_unit(opts.fetch(:unit, :micros))
        converted = { millis: C::TIME_MILLIS, micros: C::TIME_MICROS }[unit.to_sym]
        { type: unit.millis ? T::INT32 : T::INT64, converted_type: opts.fetch(:utc, true) ? converted : nil,
          logical_type: lt(time: Format::TimeType.new(is_adjusted_to_utc: opts.fetch(:utc, true), unit: unit)) }
      when :timestamp
        unit = time_unit(opts.fetch(:unit, :micros))
        converted = { millis: C::TIMESTAMP_MILLIS, micros: C::TIMESTAMP_MICROS }[unit.to_sym]
        { type: T::INT64, converted_type: opts.fetch(:utc, true) ? converted : nil,
          logical_type: lt(timestamp: Format::TimestampType.new(is_adjusted_to_utc: opts.fetch(:utc, true), unit: unit)) }
      when :decimal
        precision = Integer(opts.fetch(:precision))
        scale = Integer(opts.fetch(:scale, 0))
        raise ArgumentError, "Decimal precision must be positive" unless precision.positive?
        raise ArgumentError, "Decimal scale must be between 0 and precision" unless scale.between?(0, precision)
        physical = if opts[:physical]
          { int32: { type: T::INT32 }, int64: { type: T::INT64 }, binary: { type: T::BYTE_ARRAY },
            fixed: { type: T::FIXED_LEN_BYTE_ARRAY, type_length: decimal_bytes(precision) } }.fetch(opts[:physical])
        elsif precision <= 9 then { type: T::INT32 }
        elsif precision <= 18 then { type: T::INT64 }
        else { type: T::FIXED_LEN_BYTE_ARRAY, type_length: decimal_bytes(precision) }
        end
        physical.merge(converted_type: C::DECIMAL, scale: scale, precision: precision,
          logical_type: lt(decimal: Format::DecimalType.new(scale: scale, precision: precision)))
      else
        raise ArgumentError, "Unknown column type #{type.inspect}"
      end
    end

    # Minimal number of bytes to hold a signed integer of +precision+ decimal digits
    def decimal_bytes(precision)
      max = 10**precision
      n = 1
      n += 1 while (1 << (8 * n - 1)) <= max
      n
    end

    # Normalized logical kind of a node: [symbol, details]
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
    def reader_for(node)
      kind, a, b = logical_of(node)
      type = node.type
      case kind
      when :string, :enum, :json
        return ->(v) { v.force_encoding(Encoding::UTF_8) } if type == T::BYTE_ARRAY || type == T::FIXED_LEN_BYTE_ARRAY
      when :integer
        if !b && (type == T::INT32 || type == T::INT64)
          mask = type == T::INT32 ? 0xFFFF_FFFF : 0xFFFF_FFFF_FFFF_FFFF
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

    def timestamp_reader(unit)
      div = UNIT_DIVISORS.fetch(unit)
      name = UNIT_NAMES.fetch(unit)
      ->(v) { Time.at(v / div, v % div, name).utc }
    end

    def int96_reader
      lambda do |(nanos, day)|
        secs = (day - JULIAN_EPOCH_DAY) * 86_400
        Time.at(secs + nanos / 1_000_000_000, nanos % 1_000_000_000, :nanosecond).utc
      end
    end

    def decimal_reader(type, scale)
      to_decimal = if BIGDECIMAL_AVAILABLE
        scale.zero? ? ->(i) { BigDecimal(i) } : ->(i) { BigDecimal("#{i}e-#{scale}") }
      else
        denom = 10**scale
        ->(i) { Rational(i, denom) }
      end
      case type
      when T::INT32, T::INT64 then to_decimal
      when T::BYTE_ARRAY, T::FIXED_LEN_BYTE_ARRAY
        ->(v) { to_decimal.call(be_to_int(v)) }
      end
    end

    # Big-endian two's complement bytes to Integer
    def be_to_int(bytes)
      return 0 if bytes.empty?
      i = bytes.unpack1("H*").to_i(16)
      bits = bytes.bytesize * 8
      i >= (1 << (bits - 1)) ? i - (1 << bits) : i
    end

    def int_to_be(i, nbytes)
      bits = nbytes * 8
      raise EncodeError, "Decimal value #{i} does not fit in #{nbytes} bytes" unless i.bit_length < bits
      i += 1 << bits if i.negative?
      [i.to_s(16).rjust(nbytes * 2, "0")].pack("H*")
    end

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
    def float_to_half(f)
      return 0x7E00 if f.nan?
      sign = f.negative? || (f.zero? && (1.0 / f).negative?) ? 0x8000 : 0
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
    def writer_for(node)
      kind, a, _b = logical_of(node)
      type = node.type
      case kind
      when :date
        return lambda do |v|
          return v if v.is_a?(Integer)
          d = v.to_date
          # Use the civil date, so dates before 1582 in Ruby's default calendar are proleptic Gregorian
          Date.civil(d.year, d.mon, d.mday, Date::GREGORIAN).jd - EPOCH_JD
        end
      when :timestamp
        mult = UNIT_DIVISORS.fetch(a)
        return lambda do |v|
          return v if v.is_a?(Integer)
          v = v.to_time if v.respond_to?(:to_time) && !v.is_a?(Time)
          v.to_i * mult + v.nsec * mult / 1_000_000_000
        end
      when :decimal
        return decimal_writer(node, a)
      when :uuid
        return fixed_checker(16) do |v|
          v.bytesize == 16 && v.encoding == Encoding::BINARY ? v : [v.delete("-")].pack("H*")
        end
      when :float16
        return ->(v) { [float_to_half(Float(v))].pack("v") }
      when :integer
        if !_b && (type == T::INT32 || type == T::INT64)
          bits = type == T::INT32 ? 32 : 64
          check = int_checker(0, (1 << a) - 1)
          return ->(v) { Delta.wrap(check.call(v), bits) }
        elsif type == T::INT32 || type == T::INT64
          return int_checker(-(1 << (a - 1)), (1 << (a - 1)) - 1)
        end
      end

      case type
      when T::BOOLEAN
        lambda do |v|
          raise ArgumentError, "expected true or false" unless v == true || v == false
          v
        end
      when T::INT32 then int_checker(-(1 << 31), (1 << 31) - 1)
      when T::INT64 then int_checker(-(1 << 63), (1 << 63) - 1)
      when T::FLOAT, T::DOUBLE then ->(v) { Float(v) }
      when T::BYTE_ARRAY then ->(v) { v.is_a?(String) ? v : v.to_s }
      when T::FIXED_LEN_BYTE_ARRAY then fixed_checker(node.type_length) { |v| v.is_a?(String) ? v : v.to_s }
      when T::INT96
        lambda do |v|
          return v if v.is_a?(Array)
          nanos = v.to_i * 1_000_000_000 + v.nsec
          day, nanos_of_day = nanos.divmod(NANOS_PER_DAY)
          [nanos_of_day, day + JULIAN_EPOCH_DAY]
        end
      end
    end

    # Converts to Integer, rejecting fractional numbers and values outside min..max
    def int_checker(min, max)
      lambda do |v|
        i = Integer(v)
        raise ArgumentError, "#{v.inspect} is not an integer" unless v.is_a?(Integer) || !v.is_a?(Numeric) || v == i
        raise RangeError, "#{i} is outside #{min}..#{max}" unless i >= min && i <= max
        i
      end
    end

    def fixed_checker(length, &convert)
      lambda do |v|
        s = convert.call(v)
        raise ArgumentError, "expected #{length} bytes, got #{s.bytesize}" unless s.bytesize == length
        s
      end
    end

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
