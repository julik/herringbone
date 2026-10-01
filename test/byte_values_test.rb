# frozen_string_literal: true

require_relative "test_helper"

class ByteValuesTest < Minitest::Test
  BV = Herringbone::ByteValues

  def test_dictionary_mode_for_low_cardinality
    bv = BV.new
    10_000.times { |i| bv << %w[pending paid shipped][i % 3] }
    assert bv.dictionary?
    kind, dict, indices = bv.materialize
    assert_equal :dictionary, kind
    assert_equal %w[pending paid shipped], dict
    assert_equal [0, 1, 2, 0], indices.first(4)
    assert_operator bv.memory_bytes, :<, 100_000
  end

  def test_switches_to_bytes_for_high_cardinality
    bv = BV.new
    values = Array.new(10_000) { |i| "value #{i}" }
    values.each { |v| bv << v }
    refute bv.dictionary?
    assert_equal [:plain, values], bv.materialize
  end

  def test_switches_to_bytes_when_dictionary_is_too_large
    bv = BV.new
    big = Array.new(20) { |i| i.to_s * 100_000 }
    big.each { |v| bv << v }
    refute bv.dictionary?
    assert_equal big, bv.materialize[1]
  end

  def test_without_dictionary
    bv = BV.new(dictionary: false)
    bv << "a" << "a"
    refute bv.dictionary?
    assert_equal [:plain, %w[a a]], bv.materialize
  end

  def test_mixed_encodings
    [true, false].each do |dictionary|
      bv = BV.new(dictionary: dictionary)
      values = ["\xFF\x00".b, "zoë", "日本", "plain", :sym.to_s]
      values.each { |v| bv << v }
      bv.send(:switch_to_bytes) if dictionary
      out = bv.materialize[1]
      assert_equal values.map(&:b), out.map(&:b)
    end
  end

  def test_fixed_width
    bv = BV.new(width: 2, dictionary: false)
    bv << "ab" << "cd" << "ef"
    bv.pop
    assert_equal [:plain, %w[ab cd]], bv.materialize.map { |x| x.is_a?(Array) ? x.map(&:b) : x }
  end

  def test_rollback_in_both_modes
    [true, false].each do |dictionary|
      bv = BV.new(dictionary: dictionary)
      %w[a bb ccc dddd].each { |v| bv << v }
      bv.pop
      bv.slice!(2..)
      bv << "e"
      assert_equal 3, bv.size
      values = bv.materialize
      values = (values[0] == :dictionary) ? values[2].map { |i| values[1][i] } : values[1]
      assert_equal %w[a bb e], values
    end
  end
end
