# frozen_string_literal: true

require "json"
require "base64"
require "digest"

# Converts values read by Parakiet into the canonical JSON form used by the
# pyarrow-generated expectations (see test/fixtures/parquet-testing/README.md).
module Canonical
  module_function

  def row(schema, row)
    schema.fields.to_h { |f| [f.name, value(f, row[f.name])] }
  end

  def value(field, v)
    return nil if v.nil?
    case field.kind
    when :struct then field.children.to_h { |c| [c.name, value(c, v[c.name])] }
    when :list then v.map { |e| value(field.element, e) }
    when :map then v.map { |k, val| [value(field.key, k), field.value ? value(field.value, val) : nil] }
    else leaf(field.node, v)
    end
  end

  FRACTION_DIGITS = { millis: 3, micros: 6, nanos: 9 }.freeze

  def leaf(node, v)
    kind, a, b = Parakiet::Types.logical_of(node)
    type = node.type
    case v
    when Float
      return "NaN" if v.nan?
      return(v.positive? ? "Infinity" : "-Infinity") if v.infinite?
      v
    when Time
      if type == Parakiet::Format::Type::INT96
        timestamp(v, 9, false)
      else
        timestamp(v, FRACTION_DIGITS.fetch(a), b)
      end
    when Date then v.iso8601
    when Integer
      return time_of_day(v, a) if kind == :time
      v
    when String
      if kind == :uuid
        { "base64" => Base64.strict_encode64([v.delete("-")].pack("H*")) }
      elsif %i[string json enum].include?(kind)
        v
      else
        { "base64" => Base64.strict_encode64(v) }
      end
    when Rational then decimal(v, a)
    else
      if defined?(BigDecimal) && v.is_a?(BigDecimal)
        decimal(v, a)
      else
        v
      end
    end
  end

  def timestamp(t, digits, utc)
    t = t.utc
    frac = (t.nsec / 10**(9 - digits)).to_s.rjust(digits, "0")
    format("%04d-%02d-%02dT%02d:%02d:%02d.%s%s", t.year, t.month, t.day, t.hour, t.min, t.sec, frac, utc ? "Z" : "")
  end

  def time_of_day(v, unit)
    per_sec = { millis: 1_000, micros: 1_000_000, nanos: 1_000_000_000 }.fetch(unit)
    secs, frac = v.divmod(per_sec)
    h, rem = secs.divmod(3600)
    m, s = rem.divmod(60)
    format("%02d:%02d:%02d.%s", h, m, s, frac.to_s.rjust(FRACTION_DIGITS.fetch(unit), "0"))
  end

  def decimal(v, scale)
    unscaled = (v * 10**scale).to_i
    sign = unscaled.negative? ? "-" : ""
    digits = unscaled.abs.to_s
    return sign + digits if scale.zero?
    digits = digits.rjust(scale + 1, "0")
    "#{sign}#{digits[0...-scale]}.#{digits[-scale..]}"
  end

  # Canonical JSON matching Python's json.dumps(sort_keys=True, separators=(",", ":"))
  def dump(v)
    case v
    when nil then "null"
    when true then "true"
    when false then "false"
    when Integer then v.to_s
    when Float then python_float_repr(v)
    when String then JSON.generate(v)
    when Array then "[#{v.map { |e| dump(e) }.join(",")}]"
    when Hash then "{#{v.keys.sort.map { |k| "#{JSON.generate(k.to_s)}:#{dump(v[k])}" }.join(",")}}"
    else raise ArgumentError, "Cannot dump #{v.class}"
    end
  end

  def python_float_repr(f)
    return "-0.0" if f.zero? && (1.0 / f).negative?
    return "0.0" if f.zero?
    s = f.abs.to_s
    mantissa, exp = s.split("e")
    int_part, frac_part = mantissa.split(".")
    digits = (int_part + frac_part.to_s).sub(/\A0+/, "")
    decpt = exp ? exp.to_i + 1 : (int_part == "0" ? -(frac_part[/\A0*/].length) : int_part.length)
    digits = digits.sub(/0+\z/, "")
    digits = "0" if digits.empty?
    sign = f.negative? ? "-" : ""
    if decpt > -4 && decpt <= 16
      if decpt <= 0
        sign + "0." + ("0" * -decpt) + digits
      elsif digits.length <= decpt
        sign + digits + ("0" * (decpt - digits.length)) + ".0"
      else
        sign + digits[0, decpt] + "." + digits[decpt..]
      end
    else
      e = decpt - 1
      m = digits.length > 1 ? digits[0] + "." + digits[1..] : digits
      sign + m + "e" + (e.negative? ? "-" : "+") + e.abs.to_s.rjust(2, "0")
    end
  end

  def row_hash(lines)
    Digest::SHA256.hexdigest(lines.join("\n"))
  end
end
