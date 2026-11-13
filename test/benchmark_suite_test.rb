# frozen_string_literal: true

require_relative "test_helper"
require_relative "../benchmark/suite"
require_relative "support/benchmark_run"
require "minitest/mock"

class BenchmarkSuiteTest < Minitest::Test
  CONFIG = BenchmarkSuite::Corpus::DEFAULT.merge("rows" => 40, "runs" => 1, "group_rows" => 10).freeze

  def setup
    @directory = Dir.mktmpdir("herringbone-suite-test-")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_baseline_validates_every_scenario_and_removes_successful_outputs
    run = run_suite("baseline")

    assert run.passed
    assert_equal BenchmarkSuite::CASES, run.cases.map { |job| job["scenario"] }
    run.cases.each do |job|
      assert job["passed"]
      assert_equal 0, job["status"]
      assert_measurement(run.event(job, "measured"), job["scenario"])
      expected_rows = (job["scenario"] == "delete") ? 36 : 40
      assert_equal expected_rows, run.event(job, "validated")["rows"]
    end
    assert_empty Dir[File.join(run.output, "trial-*")]
    assert_equal 6, read_json(File.join(run.output, "corpus/manifest.json"))["files"].length
    assert_equal 9, run.summary["summaries"].length
    assert_operator run.summary["total_seconds"], :>, 0
    assert run.summary["sources_valid"]
    assert_equal run.summary["sources"], run.summary["final_sources"]
    run.jobs.each do |job|
      assert job["sources_valid"]
      assert_equal run.summary["sources"], job["sources"]
    end
    writes = run.summary["summaries"].select { |item| item["scenario"].start_with?("write_") }
    writes.each { |item| assert_operator item["writer_active_seconds"]["median"], :>, 0 }
  end

  def test_corpus_reuse_preserves_input_files
    first = run_suite("first")
    corpus = File.join(first.output, "corpus")
    original_files = fingerprints(corpus)

    reused = run_suite("reuse", corpus: corpus)

    assert reused.passed
    assert_equal original_files, fingerprints(corpus)
  end

  def test_corrupt_inputs_block_dependents_but_not_independent_writes
    first = run_suite("first")
    corpus = File.join(first.output, "corpus")
    damaged_file = File.join(corpus, "current-0.parquet")
    File.binwrite(damaged_file, "broken")

    run = run_suite("corrupt", corpus: corpus)

    refute run.passed
    assert_match(/corrupt corpus file/, run.jobs.first["stderr"])
    assert_equal "broken", File.binread(damaged_file)
    assert_equal 7, run.jobs.count { |job| job["event"] == "blocked" }
    assert_equal 2, run.cases.count { |job| job["passed"] }
  end

  def test_nonempty_output_is_never_overwritten
    path = File.join(@directory, "keep")
    File.write(path, "mine")
    runner = BenchmarkSuite::Runner.new(config: CONFIG, output: @directory)

    assert_raises(RuntimeError) { runner.run }

    assert_equal "mine", File.read(path)
  end

  def test_incompatible_corpus_is_rejected
    first = run_suite("first")
    incompatible = CONFIG.merge("page_rows" => 1)

    run = run_suite("different", config: incompatible, corpus: File.join(first.output, "corpus"))

    refute run.passed
    assert_includes run.jobs.first["stderr"], "corpus settings differ"
  end

  def test_source_changes_between_runs_are_allowed
    extension = implementation_file("candidate")
    first = run_suite("before", implementation_file: extension)
    File.open(extension, "a") { |io| io.puts "\n# Another source revision" }

    second = run_suite("after", implementation_file: extension)

    assert first.passed
    assert second.passed
    before = first.summary["sources"]
    after = second.summary["sources"]
    assert_equal before.except("implementation"), after.except("implementation")
    refute_equal before["implementation"], after["implementation"]
  end

  def test_relative_cli_path_has_the_same_source_identity
    job = {
      "action" => "prepare",
      "implementation" => "ruby",
      "config" => CONFIG,
      "corpus" => File.join(@directory, "relative"),
      "sources" => BenchmarkSuite.sources
    }

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "benchmark/suite.rb", "__worker", JSON.generate(job),
      chdir: File.expand_path("..", __dir__)
    )

    assert status.success?, stderr
    records = stdout.lines.map { |line| JSON.parse(line) }
    assert_equal %w[sources_started prepared sources_finished], records.map { |record| record["event"] }
    assert_equal job["sources"], records.first["sources"]
    assert_equal job["sources"], records.last["sources"]
  end

  def test_source_changes_during_execution_invalidate_and_preserve_measurements
    run = run_suite("changed", implementation_file: implementation_file("changing_source"))
    changed = run.job("write_typed", implementation: "changing")

    refute run.passed
    refute changed["passed"]
    refute changed["sources_valid"]
    assert run.event(changed, "measured")
    assert_includes changed["stderr"], "source changed during worker execution"
    refute run.summary["passed"]
    refute run.summary["sources_valid"]
    refute_equal run.summary["sources"], run.summary["final_sources"]
    assert_equal 18, run.cases.length
  end

  def test_candidate_failure_is_isolated_and_other_cases_continue
    run = run_suite("comparison", implementation_file: implementation_file("broken_compressor"))
    baseline = run.cases(implementation: "ruby")
    candidate = run.cases(implementation: "broken")
    failure = run.job("union", implementation: "broken")

    refute run.passed
    assert_equal 9, baseline.length
    assert baseline.all? { |job| job["passed"] }
    assert_equal 9, candidate.length
    assert run.job("read", implementation: "broken")["passed"]
    assert run.job("same", implementation: "broken")["passed"]
    refute failure["passed"]
    assert_includes failure["stderr"], "intentional failure"
    assert Dir.exist?(failure["scratch"])
    assert File.file?(File.join(run.output, "summary.json"))
  end

  def test_comparisons_alternate_order_and_keep_metadata_separate
    run = run_suite("ordered", config: CONFIG.merge("runs" => 2),
      implementation_file: implementation_file("candidate"))
    writes = run.cases.select { |job| job["scenario"] == "write_typed" }

    assert run.passed
    assert_equal %w[ruby candidate candidate ruby], writes.map { |job| job["implementation"] }
    writes.each do |job|
      metadata = run.event(job, "measured")["backend"]["custom"]
      if job["implementation"] == "ruby"
        assert_nil metadata
      else
        assert_equal({"marker" => "candidate-only"}, metadata)
      end
    end
    run.summary["summaries"].each do |summary|
      jobs = run.cases(implementation: summary["implementation"]).select do |job|
        job["scenario"] == summary["scenario"]
      end
      samples = jobs.map { |job| run.event(job, "measured") }
      times = samples.map { |sample| sample["seconds"] }
      assert_equal 2, summary["samples"]
      assert_equal times.sum / 2, summary["median_seconds"]
      assert_equal times.min, summary["min_seconds"]
      assert_equal times.max, summary["max_seconds"]
      next unless summary["scenario"].start_with?("write_")

      active = samples.map { |sample| sample["writer_active_seconds"] }
      assert_equal({"median" => active.sum / 2, "min" => active.min, "max" => active.max},
        summary["writer_active_seconds"])
    end
  end

  def test_unknown_options_and_extra_arguments_are_rejected
    assert_raises(OptionParser::InvalidOption) { BenchmarkSuite.cli(%w[--rows 40]) }
    assert_raises(OptionParser::InvalidArgument) { BenchmarkSuite.cli(%w[extra]) }
  end

  def test_help_exits_successfully
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, BenchmarkSuite::SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: ruby benchmark/suite.rb [options]"
    %w[--long --corpus --output --implementation-file --help].each do |option|
      assert_includes stdout, option
    end
  end

  def test_writer_active_time_excludes_input_preparation
    run = run_suite("slow-records", implementation_file: implementation_file("slow_records"))

    assert run.passed
    %w[write_typed write_coercible].each do |scenario|
      sample = run.event(run.job(scenario, implementation: "slow-records"), "measured")
      preparation_seconds = sample["seconds"] - sample["writer_active_seconds"]
      assert_operator preparation_seconds, :>=, 0.15
    end
  end

  def test_invalid_registration_is_rejected
    assert_raises(ArgumentError) { BenchmarkSuite.register_implementation("ruby") {} }
    assert_raises(ArgumentError) { BenchmarkSuite.register_implementation("empty") }
  end

  def test_invalid_extension_does_not_stop_the_baseline
    run = run_suite("bad-extension", implementation_file: implementation_file("invalid"))
    discovery = run.jobs.find { |job| job["action"] == "discover" }

    refute run.passed
    assert_equal 9, run.cases.count { |job| job["passed"] }
    refute discovery["passed"]
  end

  def test_missing_rss_support_does_not_disable_benchmarks
    runner = BenchmarkSuite::Runner.new(config: CONFIG, output: File.join(@directory, "no-rss"))
    passed = nil

    runner.stub(:time_prefix, []) { capture_io { passed = runner.run } }
    run = BenchmarkRun.new(passed, runner.output)

    assert run.passed
    assert run.jobs.all? { |job| job["worker_peak_rss_bytes"].nil? }
  end

  def test_validation_failure_keeps_measurements_and_output
    run = run_suite("wrong-values", implementation_file: implementation_file("wrong_values"))
    failure = run.job("write_typed", implementation: "wrong-values")

    refute run.passed
    refute failure["passed"]
    assert run.event(failure, "measured")
    refute failure["records"].any? { |record| record["event"] == "validated" }
    assert_includes failure["stderr"], "value/order mismatch"
    assert File.exist?(File.join(failure["scratch"], "0.parquet"))
    assert_equal 9, run.cases(implementation: "ruby").count { |job| job["passed"] }
  end

  private

  def run_suite(name, config: CONFIG, **options)
    runner = BenchmarkSuite::Runner.new(config: config, output: File.join(@directory, name), **options)
    passed = nil
    capture_io { passed = runner.run }
    BenchmarkRun.new(passed, runner.output)
  end

  def implementation_file(name)
    source = File.join(__dir__, "fixtures/benchmark_suite", "#{name}.rb")
    destination = File.join(@directory, "#{name}.rb")
    FileUtils.cp(source, destination)
    destination
  end

  def read_json(path)
    JSON.parse(File.read(path))
  end

  def fingerprints(directory)
    Dir[File.join(directory, "*")].to_h do |path|
      [path, [File.mtime(path), Digest::SHA256.file(path).hexdigest]]
    end
  end

  def assert_measurement(sample, scenario)
    assert_equal "ruby", sample["backend"]["snappy"]
    assert_equal Herringbone::IOBufferSupport::AVAILABLE, sample["backend"]["io_buffer_available"]
    buffer = Herringbone::IOBufferSupport::AVAILABLE ? "io_buffer" : "string"
    assert_equal buffer, sample["backend"]["ruby_buffer"]
    assert_operator sample["seconds"], :>, 0
    assert_equal 40, sample["input_rows"]
    if scenario.start_with?("write_")
      assert_operator sample["writer_active_seconds"], :>, 0
      assert_operator sample["writer_active_seconds"], :<=, sample["seconds"]
    else
      refute sample.key?("writer_active_seconds")
    end
  end
end
