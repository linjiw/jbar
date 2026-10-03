#!/usr/bin/env ruby
require_relative "../compare-benchmarks"

before = JBarBenchmarkReportGate.fixture
after = Marshal.load(Marshal.dump(before))
after.fetch("measurements").fetch("cacheCold").first.fetch("samples").each do |sample|
  sample["latencyMilliseconds"] *= 0.5
end
comparison = JBarBenchmarkComparison.compare(before, after)
raise "incorrect percentile change" unless comparison.fetch("measurements").first.fetch("changePercent").fetch("p50") == -50.0
after.fetch("environment")["jbarVersion"] = "0.2.0"
version_comparison = JBarBenchmarkComparison.compare(before, after)
raise "missing version provenance" unless version_comparison.fetch("afterVersion") == "0.2.0"

def rejects(before, label)
  after = Marshal.load(Marshal.dump(before))
  yield after
  begin
    JBarBenchmarkComparison.compare(before, after)
  rescue RuntimeError
    return
  end
  raise "accepted #{label}"
end

rejects(before, "changed corpus") { |report| report.fetch("corpus")["fingerprint"] = "0x0000000000000001" }
rejects(before, "changed machine") { |report| report.fetch("environment")["hardwareModel"] = "different" }
rejects(before, "changed ranking") do |report|
  report.fetch("measurements").fetch("cacheCold").first.fetch("validatedRows").first["score"] += 1
end
puts "PASS: benchmark comparison accepts measured improvements and rejects incomparable results"
