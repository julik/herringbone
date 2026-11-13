# frozen_string_literal: true

BenchmarkSuite.register_implementation("broken") do
  Herringbone::Codecs::Snappy.define_singleton_method(:compress) { |*| raise "intentional failure" }
  {"example" => true}
end
