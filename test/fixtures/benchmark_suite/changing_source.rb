# frozen_string_literal: true

BenchmarkSuite.register_implementation("changing") do
  File.open(__FILE__, "a") { |io| io.puts "# Source changed during execution" }
  nil
end
