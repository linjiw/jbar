#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

# Validates the LLVM JSON schema and enforces target-scoped coverage floors. The thresholds are
# deliberately attached to JBarCore only: AppKit coverage is reported separately and must never be
# combined with core coverage to make either number look better.
module JBarCoverageGate
  SUPPORTED_SCHEMA_VERSIONS = ["2.0.1"].freeze
  CORE_THRESHOLDS = { "lines" => 95, "functions" => 90 }.freeze
  REPORTED_METRICS = %w[lines functions regions].freeze
  TARGETS = %w[JBarCore JBarApp].freeze
  REPOSITORY_ROOT = File.expand_path("../..", __dir__).freeze

  module_function

  def source_manifest(repository_root = REPOSITORY_ROOT)
    TARGETS.each_with_object({}) do |target, manifest|
      pattern = File.join(repository_root, "Sources", target, "**", "*.swift")
      paths = Dir.glob(pattern).select { |path| File.file?(path) }.map { |path| File.expand_path(path) }.sort
      raise "no repository source files for #{target}" if paths.empty?

      manifest[target] = paths
    end
  end

  def coverage_files(document)
    raise "unexpected LLVM coverage type" unless document["type"] == "llvm.coverage.json.export"
    raise "unsupported coverage schema version #{document["version"].inspect}" unless
      SUPPORTED_SCHEMA_VERSIONS.include?(document["version"])

    data = document["data"]
    raise "coverage data must contain exactly one export record" unless data.is_a?(Array) && data.length == 1
    entry = data.fetch(0)
    raise "coverage export record must be an object" unless entry.is_a?(Hash)
    files = entry["files"]
    raise "coverage files must be a non-empty array" unless files.is_a?(Array) && !files.empty?

    seen = {}
    files.each do |file|
      raise "coverage file record must be an object" unless file.is_a?(Hash)
      filename = file["filename"]
      raise "coverage filename must be an absolute string" unless
        filename.is_a?(String) && filename.start_with?(File::SEPARATOR)
      normalized = File.expand_path(filename)
      raise "duplicate coverage filename #{normalized}" if seen.key?(normalized)

      seen[normalized] = file
    end
    seen
  end

  def aggregate(files, metric)
    covered = 0
    count = 0
    files.each do |file|
      summary = file.fetch("summary")
      raise "coverage summary must be an object" unless summary.is_a?(Hash)
      values = summary.fetch(metric)
      raise "#{metric} summary must be an object" unless values.is_a?(Hash)
      file_count = values.fetch("count")
      file_covered = values.fetch("covered")
      raise "#{metric} counts must be JSON integers" unless
        file_count.is_a?(Integer) && file_covered.is_a?(Integer)
      raise "invalid #{metric} counts for #{file.fetch("filename", "unknown")}" if
        file_count.negative? || file_covered.negative? || file_covered > file_count

      count += file_count
      covered += file_covered
    end
    raise "#{metric} count is zero" if count.zero?

    { covered: covered, count: count, percent: 100.0 * covered / count }
  end

  def evaluate(document, manifest = source_manifest)
    indexed_files = coverage_files(document)
    reports = {}
    TARGETS.each do |target|
      expected = manifest.fetch(target).map { |path| File.expand_path(path) }.sort
      raise "source manifest contains duplicates for #{target}" unless expected.uniq.length == expected.length
      missing = expected.reject { |path| indexed_files.key?(path) }
      raise "missing coverage records for #{target}: #{missing.join(", ")}" unless missing.empty?
      files = expected.map { |path| indexed_files.fetch(path) }

      reports[target] = {
        files: files.length,
        metrics: REPORTED_METRICS.each_with_object({}) do |metric, values|
          values[metric] = aggregate(files, metric)
        end,
      }
    end

    failures = CORE_THRESHOLDS.each_with_object([]) do |(metric, threshold), values|
      value = reports.fetch("JBarCore").fetch(:metrics).fetch(metric)
      next if value.fetch(:covered) * 100 >= threshold * value.fetch(:count)

      values << "JBarCore #{metric} #{value.fetch(:covered)}/#{value.fetch(:count)} " \
                "(#{format("%.4f", value.fetch(:percent))}%) is below #{threshold}%"
    end
    [reports, failures]
  end

  def print_report(reports)
    %w[JBarCore JBarApp].each do |target|
      report = reports.fetch(target)
      puts "#{target}: #{report.fetch(:files)} source files"
      REPORTED_METRICS.each do |metric|
        value = report.fetch(:metrics).fetch(metric)
        threshold = target == "JBarCore" ? CORE_THRESHOLDS[metric] : nil
        suffix = threshold ? " (minimum #{threshold}%)" : " (reported only; no threshold)"
        puts format("  %-9s %d/%d = %.4f%%%s", metric, value.fetch(:covered),
                    value.fetch(:count), value.fetch(:percent), suffix)
      end
    end
  end

  def fixture(core_lines:, core_functions:, version: "2.0.1", extra_data: [], core_count: 100)
    metric = lambda do |covered, count|
      { "count" => count, "covered" => covered, "notcovered" => count - covered,
        "percent" => 100.0 * covered / count }
    end
    core_summary = {
      "lines" => metric.call(core_lines, core_count),
      "functions" => metric.call(core_functions, 100),
      "regions" => metric.call(80, 100),
    }
    app_summary = {
      "lines" => metric.call(1, 10),
      "functions" => metric.call(1, 10),
      "regions" => metric.call(1, 10),
    }
    {
      "type" => "llvm.coverage.json.export", "version" => version,
      "data" => [{ "files" => [
        { "filename" => "/workspace/Sources/JBarCore/Core.swift", "summary" => core_summary },
        { "filename" => "/workspace/Sources/JBarApp/App.swift", "summary" => app_summary },
      ] }] + extra_data,
    }
  end

  def self_test!
    manifest = {
      "JBarCore" => ["/workspace/Sources/JBarCore/Core.swift"],
      "JBarApp" => ["/workspace/Sources/JBarApp/App.swift"],
    }
    reports, failures = evaluate(fixture(core_lines: 95, core_functions: 90), manifest)
    raise "exact thresholds must pass" unless failures.empty?
    raise "target scopes were combined" unless reports.dig("JBarCore", :metrics, "lines", :count) == 100

    _reports, line_failures = evaluate(fixture(core_lines: 94, core_functions: 90), manifest)
    raise "line regression was accepted" unless line_failures.any? { |failure| failure.include?("lines") }

    _reports, rounded_line_failures = evaluate(
      fixture(core_lines: 18_999, core_functions: 90, core_count: 20_000), manifest
    )
    raise "below-threshold value that rounds to 95.00% was accepted" unless
      rounded_line_failures.any? { |failure| failure.include?("18999/20000") }

    _reports, function_failures = evaluate(fixture(core_lines: 95, core_functions: 89), manifest)
    raise "function regression was accepted" unless function_failures.any? { |failure| failure.include?("functions") }

    expect_rejection = lambda do |description, document, custom_manifest = manifest|
      begin
        evaluate(document, custom_manifest)
      rescue KeyError, ArgumentError, TypeError, RuntimeError
        next
      end
      raise "#{description} was accepted"
    end
    expect_rejection.call("unknown schema", fixture(core_lines: 95, core_functions: 90,
                                                     version: "totally-unsupported"))
    expect_rejection.call("multiple data records", fixture(core_lines: 95, core_functions: 90,
                                                            extra_data: [{}]))
    expect_rejection.call("fractional counts", fixture(core_lines: 95, core_functions: 90,
                                                       core_count: 100.5))
    duplicate = fixture(core_lines: 95, core_functions: 90)
    duplicate["data"][0]["files"] << duplicate["data"][0]["files"].first.dup
    expect_rejection.call("duplicate filename", duplicate)
    fake_scope = fixture(core_lines: 95, core_functions: 90)
    fake_scope["data"][0]["files"][0]["filename"] =
      "/workspace/Tests/Fake/Sources/JBarCore/AlwaysCovered.swift"
    expect_rejection.call("substring target scope", fake_scope)
    puts "PASS: coverage gate self-test"
  end
end

if ARGV == ["--self-test"]
  JBarCoverageGate.self_test!
  exit 0
end

abort "usage: #{$PROGRAM_NAME} <llvm-coverage.json> | --self-test" unless ARGV.length == 1

begin
  document = JSON.parse(File.read(ARGV.fetch(0)))
  reports, failures = JBarCoverageGate.evaluate(document)
  JBarCoverageGate.print_report(reports)
  abort failures.join("\n") unless failures.empty?
  puts "PASS: JBarCore coverage thresholds"
rescue JSON::ParserError, KeyError, ArgumentError, TypeError, RuntimeError => error
  abort "coverage gate error: #{error.message}"
end
