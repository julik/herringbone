# frozen_string_literal: true

module BenchmarkSuite
  class Worker
    def initialize(job, implementations)
      @job = job
      @implementations = implementations
    end

    def run
      $stdout.sync = true
      expected = @job.fetch("sources")
      initial = source_snapshot
      emit("sources_started", sources: initial)
      raise "source changed since run started" unless initial == expected

      begin
        perform
      ensure
        final = source_snapshot
        emit("sources_finished", sources: final)
        raise "source changed during worker execution" unless final == expected
      end
    end

    private

    def perform
      return discover if @job.fetch("action") == "discover"

      configure_implementation
      @corpus = Corpus.new(@job.fetch("corpus"), @job.fetch("config"))
      if @job.fetch("action") == "prepare"
        emit("prepared", manifest: @corpus.prepare, backend: @backend)
        return
      end
      run_case
    end

    def discover
      load @job.fetch("implementation_file")
      raise "implementation file registered no implementations" if @implementations.empty?

      emit("implementations", names: @implementations.keys)
    end

    def configure_implementation
      Herringbone::Codecs::Snappy.backend = :ruby
      original_decoder = BenchmarkSuite.decoder_methods
      details = nil
      if @job.fetch("implementation") != "ruby"
        load @job.fetch("implementation_file")
        details = @implementations.fetch(@job.fetch("implementation")).call
        unless details.nil? || details.is_a?(Hash)
          raise "implementation metadata must be a Hash or nil"
        end
      end
      Herringbone.eager_load!
      @backend = BenchmarkSuite.backend(original_decoder).merge("custom" => details)
      if @job["implementation"] == "ruby" && @backend["snappy"] != "ruby"
        raise "baseline is not pure Ruby"
      end
    end

    def run_case
      @scenario = @job.fetch("scenario")
      @output = @job.fetch("scratch")
      Dir.mkdir(@output)
      @paths = []
      @reports = []
      @writer_active = nil
      @rewrite_options = @corpus.writer_options.except(:row_group_rows, :row_group_bytes)

      measurement = measure_operation
      measurement[:writer_active_seconds] = @writer_active if @writer_active
      emit("measured", **measurement,
        input_rows: @corpus.config.fetch("rows"),
        rows_per_second: @corpus.config.fetch("rows") / measurement.fetch(:seconds),
        output_bytes: @paths.sum { |path| File.size(path) },
        reports: @reports, backend: @backend)

      rows = @corpus.verify(@paths, @scenario)
      verify_combine_report if %w[same union intersection].include?(@scenario)
      emit("validated", rows: rows)
      FileUtils.remove_entry(@output)
    end

    def measure_operation
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      case @scenario
      when "write_typed", "write_coercible" then write
      when "read" then read
      when "same", "union", "intersection" then combine
      else redact
      end

      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      cpu_seconds = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
      allocated_objects = GC.stat(:total_allocated_objects) - allocated
      {seconds: seconds, cpu_seconds: cpu_seconds, allocated_objects: allocated_objects}
    end

    def write
      @writer_active = 0.0
      4.times do |shard|
        @paths << File.join(@output, "#{shard}.parquet")
        @writer_active += @corpus.write(@paths.last, shard, coercible: @scenario == "write_coercible")
      end
    end

    def read
      count = 0
      @paths = 4.times.map { |shard| @corpus.path(shard) }
      @paths.each do |path|
        File.open(path, "rb") do |io|
          Herringbone::Reader.new(io).each_row { count += 1 }
        end
      end
      raise "read row count mismatch" unless count == @corpus.config.fetch("rows")
    end

    def combine
      inputs = []
      begin
        4.times do |shard|
          inputs << File.open(@corpus.path(shard, legacy: @scenario != "same" && shard.even?), "rb")
        end
        @paths << File.join(@output, "combined.parquet")
        schema_mode = {"same" => nil, "union" => :union, "intersection" => :intersect}.fetch(@scenario)
        report = File.open(@paths.last, "wb") do |io|
          Herringbone.combine(inputs, io, schema: schema_mode, **@rewrite_options)
        end
        @reports << report.to_h
      ensure
        inputs.each(&:close)
      end
    end

    def redact
      4.times do |shard|
        @paths << File.join(@output, "#{shard}.parquet")
        report = File.open(@corpus.path(shard), "rb") do |input|
          File.open(@paths.last, "wb") do |output|
            Herringbone.redact(input, output, **@rewrite_options) do |redaction|
              case @scenario
              when "replace_rows" then redaction.where(bucket: 0).replace(email: nil)
              when "replace_column" then redaction.replace(email: nil)
              when "delete" then redaction.where(bucket: 0).delete
              else raise "unknown scenario #{@scenario}"
              end
            end
          end
        end
        @reports << report.to_h
      end
    end

    def verify_combine_report
      shard_rows = @corpus.range(0).size
      group_rows = @corpus.config.fetch("group_rows")
      groups = 4 * ((shard_rows + group_rows - 1) / group_rows)
      expected = if @scenario == "same"
        {copied: groups, rewritten: 0}
      else
        {copied: groups / 2, rewritten: groups / 2}
      end
      raise "unexpected copied/rewritten groups" unless @reports.first[:row_groups] == expected
    end

    def source_snapshot
      BenchmarkSuite.sources(@job["implementation_file"])
    end

    def emit(event, **values)
      puts JSON.generate({event: event}.merge(values))
    end
  end
end
