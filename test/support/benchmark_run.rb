# frozen_string_literal: true

class BenchmarkRun
  attr_reader :passed, :output, :jobs, :summary

  def initialize(passed, output)
    @passed = passed
    @output = output
    @jobs = File.readlines(File.join(output, "results.jsonl")).map { |line| JSON.parse(line) }
    @summary = JSON.parse(File.read(File.join(output, "summary.json")))
  end

  def cases(implementation: nil)
    jobs.select do |job|
      job["action"] == "case" && (implementation.nil? || job["implementation"] == implementation)
    end
  end

  def job(scenario, implementation: "ruby", trial: 1)
    cases(implementation: implementation).find do |job|
      job["scenario"] == scenario && job["trial"] == trial
    end || raise("missing #{implementation} #{scenario} trial #{trial}")
  end

  def event(job, name)
    job.fetch("records").find { |record| record["event"] == name } || raise("missing #{name} event")
  end
end
