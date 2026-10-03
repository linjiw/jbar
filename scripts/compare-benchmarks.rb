#!/usr/bin/env ruby
# Compare equivalent JBar runs only after the existing correctness gate accepts both.
require_relative "tests/benchmark-report-gate"

module JBarBenchmarkComparison
  module_function

  def distribution(samples)
    values = samples.map { |sample| sample.fetch("latencyMilliseconds") }.sort
    { "p50" => 0.50, "p95" => 0.95, "p99" => 0.99, "max" => 1.0 }.transform_values do |percentile|
      values.fetch([(percentile * values.length).ceil - 1, 0].max)
    end
  end

  def workloads(report)
    measurements = report.fetch("measurements")
    entries = {}
    %w[cacheCold cacheWarm].each do |mode|
      measurements.fetch(mode).each do |query|
        entries[[mode, query.fetch("query").fetch("text")]] = query
      end
    end
    %w[serialTyping deletion].each do |mode|
      measurements.fetch(mode).each do |sequence|
        sequence.fetch("steps").each_with_index do |step, index|
          entries[[mode, sequence.fetch("name"), index, step.fetch("query")]] = step
        end
      end
    end
    supersession = measurements.fetch("supersession")
    entries[["supersession", supersession.fetch("newestQuery")]] = {
      "samples" => supersession.fetch("samples").map { |sample| sample.fetch("newest") },
      "validatedRows" => supersession.fetch("newestValidatedRows"),
    }
    entries
  end

  def compare(before, after)
    before_identity = JBarBenchmarkReportGate.evaluate(before)
    after_identity = JBarBenchmarkReportGate.evaluate(after)
    unless before_identity.fetch(:repeat_identity_sha256) == after_identity.fetch(:repeat_identity_sha256)
      raise "corpus, configuration, history or workload identity differs"
    end
    comparable_environment = ->(report) { report.fetch("environment").reject { |key, _| key == "jbarVersion" } }
    unless comparable_environment.call(before) == comparable_environment.call(after)
      raise "machine, architecture, build mode or environment identity differs"
    end
    previous = workloads(before)
    current = workloads(after)
    raise "workload keys differ" unless previous.keys == current.keys
    rows = previous.map do |key, old|
      new = current.fetch(key)
      unless old.fetch("validatedRows") == new.fetch("validatedRows") &&
             old.fetch("samples").first.fetch("correctness") == new.fetch("samples").first.fetch("correctness")
        raise "ordered results, highlights, scores or exact match totals differ for #{key.inspect}"
      end
      old_stats = distribution(old.fetch("samples"))
      new_stats = distribution(new.fetch("samples"))
      changes = old_stats.each_with_object({}) do |(percentile, value), output|
        output[percentile] = value.zero? ? nil : (new_stats.fetch(percentile) / value - 1) * 100
      end
      { "workload" => key, "samples" => old.fetch("samples").length,
        "beforeMilliseconds" => old_stats, "afterMilliseconds" => new_stats,
        "changePercent" => changes }
    end
    { "schemaVersion" => 1, "items" => before_identity.fetch(:item_count),
      "correctness" => "identical ordered rows, highlights, scores and exact totals",
      "identitySha256" => before_identity.fetch(:repeat_identity_sha256),
      "beforeVersion" => before.fetch("environment").fetch("jbarVersion"),
      "afterVersion" => after.fetch("environment").fetch("jbarVersion"),
      "beforeBuildSeconds" => before.fetch("corpus").fetch("buildSeconds"),
      "afterBuildSeconds" => after.fetch("corpus").fetch("buildSeconds"),
      "measurements" => rows }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise "usage: #{$PROGRAM_NAME} before.json after.json" unless ARGV.length == 2
    reports = ARGV.map do |path|
      JBarBenchmarkReportGate.parse_json(JBarBenchmarkReportGate.read_secure_report(File.expand_path(path)))
    end
    puts JSON.pretty_generate(JBarBenchmarkComparison.compare(*reports))
  rescue KeyError, IndexError, JSON::ParserError, ArgumentError, TypeError, RuntimeError,
         SystemCallError => error
    abort "benchmark comparison error: #{error.message}"
  end
end
