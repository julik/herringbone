# frozen_string_literal: true

module BenchmarkSuite
  class Runner
    COMPLETION_EVENTS = {"prepare" => "prepared", "discover" => "implementations", "case" => "validated"}.freeze

    attr_reader :output

    def initialize(config: Corpus::DEFAULT, corpus: nil, output: nil, implementation_file: nil)
      @config = config
      @corpus_path = corpus && File.expand_path(corpus)
      @output = output && File.expand_path(output)
      @implementation_file = implementation_file && File.expand_path(implementation_file)
    end

    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      prepare_output
      @sources = BenchmarkSuite.sources(@implementation_file)
      @sources_valid = true
      @jobs = []
      @discovery = nil
      puts "Results and retained corpus: #{output}"

      File.open(File.join(output, "results.jsonl"), "w") do |log|
        @log = log
        setup = execute(base_job.merge("action" => "prepare"))
        implementations = discover_implementations
        run_trials(implementations, setup["passed"])
        summaries = summarize
        final_sources = BenchmarkSuite.sources(@implementation_file)
        @sources_valid &&= @sources == final_sources
        warn "Source identity could not be verified; run is invalid (see results.jsonl)" unless @sources_valid
        passed = @sources_valid && setup["passed"] && @jobs.all? { |job| job["passed"] } &&
          (!@discovery || @discovery["passed"])
        summary = {
          passed: passed,
          config: @config,
          total_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          sources: @sources,
          final_sources: final_sources,
          sources_valid: @sources_valid,
          summaries: summaries
        }
        File.write(File.join(output, "summary.json"), JSON.pretty_generate(summary))
        puts format("Total including generation and validation: %.2fs", summary[:total_seconds])
        passed
      end
    end

    def time_prefix
      @time_prefix ||= begin
        prefix = if File.executable?("/usr/bin/time") && RUBY_PLATFORM.match?(/darwin|linux/)
          ["/usr/bin/time", RUBY_PLATFORM.include?("darwin") ? "-l" : "-v"]
        else
          []
        end
        _, _, status = Open3.capture3(*prefix, RbConfig.ruby, "-e", "exit")
        status.success? ? prefix : []
      end
    end

    private

    def prepare_output
      @output ||= Dir.mktmpdir("herringbone-benchmark-")
      raise "output directory must be empty" if Dir.exist?(output) && !Dir.empty?(output)

      FileUtils.mkdir_p(output)
      @corpus_path ||= File.join(output, "corpus")
    end

    def discover_implementations
      return ["ruby"] unless @implementation_file

      @discovery = execute("action" => "discover")
      if @discovery["passed"]
        names = @discovery["records"].find { |record| record["event"] == "implementations" }.fetch("names")
        ["ruby", *names]
      else
        warn "Implementation discovery failed; continuing the baseline (see results.jsonl)"
        ["ruby"]
      end
    end

    def run_trials(implementations, corpus_ready)
      CASES.each do |scenario|
        @config.fetch("runs").times do |trial|
          implementations.rotate(trial % implementations.length).each do |implementation|
            job = base_job.merge(
              "action" => "case",
              "scenario" => scenario,
              "trial" => trial + 1,
              "implementation" => implementation,
              "implementation_file" => @implementation_file,
              "scratch" => File.join(output, "trial-#{@jobs.length}")
            )
            result = if corpus_ready || scenario.start_with?("write_")
              execute(job)
            else
              job.merge("event" => "blocked", "passed" => false).tap { |blocked| record_job(blocked) }
            end
            @jobs << result
            puts "#{result["passed"] ? "ok" : "FAILED"} #{scenario} #{implementation} trial #{trial + 1}"
          end
        end
      end
    end

    def summarize
      successful = @jobs.select { |job| job["passed"] }
      groups = successful.group_by { |job| job.values_at("scenario", "implementation") }
      groups.map do |(scenario, implementation), jobs|
        measurements = jobs.map do |job|
          job["records"].find { |record| record["event"] == "measured" }
        end
        times = statistics(measurements.map { |sample| sample.fetch("seconds") })
        summary = {
          scenario: scenario,
          implementation: implementation,
          samples: jobs.length,
          median_seconds: times[:median],
          min_seconds: times[:min],
          max_seconds: times[:max]
        }
        if scenario.start_with?("write_")
          summary[:writer_active_seconds] = statistics(measurements.map { |sample| sample.fetch("writer_active_seconds") })
        end
        print_summary(summary)
        summary
      end
    end

    def base_job
      {"config" => @config, "corpus" => @corpus_path, "implementation" => "ruby"}
    end

    def execute(job)
      job = job.merge("sources" => @sources, "implementation_file" => @implementation_file)
      command = time_prefix + [RbConfig.ruby, SCRIPT, "__worker", JSON.generate(job)]
      stdout, stderr, status = Open3.capture3({"LC_ALL" => "C"}, *command)
      events = parse_events(stdout)
      sources_valid = sources_verified?(events)
      @sources_valid &&= sources_valid
      completed = events.any? { |event| event["event"] == COMPLETION_EVENTS.fetch(job["action"]) }
      record = job.merge(
        "event" => "job",
        "command" => command,
        "stdout" => stdout,
        "stderr" => stderr,
        "status" => status.exitstatus,
        "sources_valid" => sources_valid,
        "passed" => status.success? && sources_valid && completed,
        "records" => events,
        "worker_peak_rss_bytes" => peak_rss(stderr)
      )
      record_job(record)
      record
    end

    def parse_events(stdout)
      stdout.lines.filter_map do |line|
        event = JSON.parse(line)
        event if event.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def sources_verified?(events)
      %w[sources_started sources_finished].all? do |name|
        events.any? { |event| event["event"] == name && event["sources"] == @sources }
      end
    end

    def peak_rss(stderr)
      if RUBY_PLATFORM.include?("darwin")
        stderr[/([0-9]+)\s+maximum resident set size/, 1]&.to_i
      elsif RUBY_PLATFORM.include?("linux")
        value = stderr[/Maximum resident set size \(kbytes\):\s*(\d+)/, 1]
        value.to_i * 1024 if value
      end
    end

    def record_job(record)
      @log.puts(JSON.generate(record))
      @log.flush
    end

    def statistics(values)
      sorted = values.sort
      {
        median: (sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2,
        min: sorted.first,
        max: sorted.last
      }
    end

    def print_summary(summary)
      median = summary.fetch(:median_seconds)
      puts format("%-18s %-16s %7.3fs [%7.3f, %7.3f] %8.0f rows/s (%d samples)",
        summary[:scenario], summary[:implementation], median, summary[:min_seconds],
        summary[:max_seconds], @config["rows"] / median, summary[:samples])
      if summary[:writer_active_seconds]
        values = summary[:writer_active_seconds].values_at(:median, :min, :max)
        puts format("  Writer-active: %.3fs [%.3f, %.3f]", *values)
      end
    end
  end
end
