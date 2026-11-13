# frozen_string_literal: true

BenchmarkSuite.register_implementation("slow-records") do
  BenchmarkSuite::Corpus.prepend(Module.new do
    def record(*args, **options)
      sleep 0.005
      super
    end
  end)
  nil
end
