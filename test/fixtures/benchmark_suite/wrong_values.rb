# frozen_string_literal: true

BenchmarkSuite.register_implementation("wrong-values") do
  Herringbone::Writer.prepend(Module.new do
    def <<(row)
      super(row.merge("id" => row.fetch("id").to_i + 1))
    end
  end)
  nil
end
