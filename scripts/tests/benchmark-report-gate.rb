#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

# Independent, fail-closed validation for a JBar benchmark v2 machine report.
#
# This gate intentionally validates evidence identity and correctness only. It does not impose an
# absolute latency threshold: reports produced by unrelated shared machines are not a product SLA.
module JBarBenchmarkReportGate
  MAX_REPORT_BYTES = 32 * 1_048_576
  MAX_SAMPLES = 10_000
  MAX_RESULTS = 500
  MAX_ITEMS = 2_000_000
  UINT64_MAX = (1 << 64) - 1
  FINGERPRINT = /\A0x[0-9a-f]{16}\z/.freeze

  QUERIES = [
    { "text" => "", "category" => "empty" },
    { "text" => "x", "category" => "common-letter" },
    { "text" => "chrome", "category" => "selective" },
    { "text" => "vsc", "category" => "acronym" },
    { "text" => "report pdf", "category" => "multi-term" },
    { "text" => ".pdf", "category" => "extension" },
  ].freeze
  TYPING_SEQUENCES = [
    { "name" => "common→selective", "steps" => %w[r re rep repo report] },
    { "name" => "selective", "steps" => %w[c ch chr chro chrome] },
    { "name" => "multi-term", "steps" => ["r", "re", "report", "report ", "report p", "report pdf"] },
  ].freeze
  DELETION_SEQUENCES = [
    { "name" => "backspace", "steps" => %w[repor repo rep re r] },
    { "name" => "multi-term backspace",
      "steps" => ["report pd", "report p", "report ", "report", "repor"] },
  ].freeze
  WORKLOAD_CLOCK =
    "DispatchTime.now().uptimeNanoseconds; caller-observed wall latency in milliseconds"
  PERCENTILE_METHOD = "nearest-rank p50/p95/p99/max; no best-of-N"
  CORRECTNESS_POLICY =
    "each measured normal, sequence, newest-supersession, and completed older-supersession " \
    "response is non-cancelled with an exact bounded total; every repeated query across all " \
    "workloads directly equals its first ordered result rows plus total; fingerprints are report " \
    "identity only"
  HISTORY_MODE = "deterministic-in-memory-production-stage-2"
  HISTORY_PERSISTENCE =
    "none (FrecencyStore load/save never called; sentinel URL is never touched)"
  HISTORY_SELECTION =
    "up to 500 evenly spaced corpus rows; 1...3 opens; ages 0...29 days; matching " \
    "chrome/vsc/report-pdf/package-swift query picks"
  RANKING_KEYS = %w[
    depthCap depthFree depthPerLevel dotName extMatch frecencyCap initialsExact initialsPrefix
    junk pinyinInitialsExact queryPick recency1d recency7d recency30d recency180d typeApp
    typeCode typeDocument typeFolder typeHiddenOrPackageInternal typeMedia wholePrefix wholeToken
  ].sort.freeze

  class UniqueKeyHash < Hash
    def []=(key, value)
      raise RuntimeError, "duplicate JSON object key #{key.inspect}" if key?(key)
      super
    end
  end

  module_function

  def fail_gate(message)
    raise RuntimeError, message
  end

  def exact_keys(value, keys, label)
    fail_gate("#{label} must be an object") unless value.is_a?(Hash)
    actual = value.keys.sort
    expected = keys.sort
    fail_gate("#{label} keys differ: got #{actual.inspect}, expected #{expected.inspect}") unless
      actual == expected
    value
  end

  def exact_array(value, label)
    fail_gate("#{label} must be an array") unless value.is_a?(Array)
    value
  end

  def integer(value, label, minimum: nil, maximum: nil)
    fail_gate("#{label} must be a JSON integer") unless value.is_a?(Integer)
    fail_gate("#{label} is below #{minimum}") if !minimum.nil? && value < minimum
    fail_gate("#{label} is above #{maximum}") if !maximum.nil? && value > maximum
    value
  end

  def number(value, label, minimum: nil)
    fail_gate("#{label} must be a finite JSON number") unless
      value.is_a?(Numeric) && value.to_f.finite?
    fail_gate("#{label} is below #{minimum}") if !minimum.nil? && value < minimum
    value
  end

  def boolean(value, label)
    fail_gate("#{label} must be a JSON boolean") unless value == true || value == false
    value
  end

  def bounded_string(value, label, allow_empty: false, max_bytes: 4_096)
    fail_gate("#{label} must be a string") unless value.is_a?(String)
    fail_gate("#{label} must not be empty") if !allow_empty && value.empty?
    fail_gate("#{label} contains NUL or is oversized") if
      value.include?("\0") || value.bytesize > max_bytes
    value
  end

  def fingerprint(value, label)
    bounded_string(value, label, max_bytes: 18)
    fail_gate("#{label} is not a lowercase 64-bit fingerprint") unless FINGERPRINT.match?(value)
    value
  end

  def sample_plan(requested)
    {
      "requested" => requested,
      "warm" => requested,
      "fullScan" => [requested, 100].min,
      "sequence" => [requested, 100].min,
      "supersession" => [requested, 100].min,
      "spotlight" => [requested, 5].min,
    }
  end

  def validate_environment(value)
    environment = exact_keys(
      value,
      %w[jbarVersion buildMode hardwareModel cpuBrand processArchitecture rosettaTranslated
         operatingSystemVersion activeProcessorCount physicalMemoryBytes localeIdentifier
         timeZoneIdentifier],
      "environment"
    )
    %w[jbarVersion hardwareModel cpuBrand operatingSystemVersion localeIdentifier
       timeZoneIdentifier].each do |key|
      bounded_string(environment.fetch(key), "environment.#{key}")
    end
    fail_gate("environment.buildMode must be release") unless environment.fetch("buildMode") == "release"
    fail_gate("unsupported process architecture") unless
      %w[arm64 x86_64].include?(environment.fetch("processArchitecture"))
    boolean(environment.fetch("rosettaTranslated"), "environment.rosettaTranslated")
    integer(environment.fetch("activeProcessorCount"), "environment.activeProcessorCount", minimum: 1)
    integer(environment.fetch("physicalMemoryBytes"), "environment.physicalMemoryBytes",
            minimum: 1, maximum: UINT64_MAX)
  end

  def validate_workload(value, expected_samples)
    workload = exact_keys(
      value,
      %w[version samplePlan queries serialTypingSequences deletionSequences
         supersessionOlderQuery supersessionNewestQuery clock percentileMethod correctnessPolicy],
      "workload"
    )
    fail_gate("wrong workload version") unless workload.fetch("version") == 2
    plan = exact_keys(workload.fetch("samplePlan"),
                      %w[requested warm fullScan sequence supersession spotlight],
                      "workload.samplePlan")
    requested = integer(plan.fetch("requested"), "workload.samplePlan.requested",
                        minimum: 1, maximum: MAX_SAMPLES)
    fail_gate("sample plan is not the workload-v2 bounded plan") unless plan == sample_plan(requested)
    if expected_samples && requested != expected_samples
      fail_gate("requested samples #{requested} differ from expected #{expected_samples}")
    end
    fail_gate("wrong workload query matrix") unless workload.fetch("queries") == QUERIES
    fail_gate("wrong serial typing matrix") unless
      workload.fetch("serialTypingSequences") == TYPING_SEQUENCES
    fail_gate("wrong deletion matrix") unless workload.fetch("deletionSequences") == DELETION_SEQUENCES
    fail_gate("wrong supersession query matrix") unless
      workload.fetch("supersessionOlderQuery") == "x" &&
        workload.fetch("supersessionNewestQuery") == "chrome"
    fail_gate("wrong workload clock identity") unless workload.fetch("clock") == WORKLOAD_CLOCK
    fail_gate("wrong percentile identity") unless
      workload.fetch("percentileMethod") == PERCENTILE_METHOD
    fail_gate("wrong correctness policy identity") unless
      workload.fetch("correctnessPolicy") == CORRECTNESS_POLICY
    plan
  end

  def validate_config(value)
    config = exact_keys(value,
                        %w[source maxResults appsFirstCap searchReferenceUnixSeconds
                           rankingIntegerWeights frecencyScale], "config")
    bounded_string(config.fetch("source"), "config.source")
    max_results = integer(config.fetch("maxResults"), "config.maxResults",
                          minimum: 1, maximum: MAX_RESULTS)
    integer(config.fetch("appsFirstCap"), "config.appsFirstCap", minimum: 0,
            maximum: max_results)
    fail_gate("wrong fixed search reference time") unless
      number(config.fetch("searchReferenceUnixSeconds"),
             "config.searchReferenceUnixSeconds") == 1_800_000_000
    weights = config.fetch("rankingIntegerWeights")
    fail_gate("config.rankingIntegerWeights must be an object") unless weights.is_a?(Hash)
    fail_gate("ranking weight key set differs") unless weights.keys.sort == RANKING_KEYS
    weights.each { |key, weight| integer(weight, "config.rankingIntegerWeights.#{key}") }
    number(config.fetch("frecencyScale"), "config.frecencyScale", minimum: 0)
    max_results
  end

  def expected_history_operations(entries)
    groups, remainder = entries.divmod(3)
    groups * 6 + [0, 1, 3].fetch(remainder)
  end

  def validate_history(value, corpus_items)
    history = exact_keys(
      value,
      %w[profileVersion mode persistence maxEntries seededEntries recordOperations queryPicks
         halfLifeSeconds referenceUnixSeconds selection profileFingerprint],
      "history"
    )
    fail_gate("wrong history profile version") unless history.fetch("profileVersion") == 1
    fail_gate("wrong history mode") unless history.fetch("mode") == HISTORY_MODE
    fail_gate("wrong history persistence identity") unless
      history.fetch("persistence") == HISTORY_PERSISTENCE
    fail_gate("wrong history capacity") unless history.fetch("maxEntries") == 500
    entries = integer(history.fetch("seededEntries"), "history.seededEntries",
                      minimum: 0, maximum: 500)
    fail_gate("history did not seed the fixed bounded corpus selection") unless
      entries == [500, corpus_items].min
    fail_gate("wrong deterministic history record count") unless
      history.fetch("recordOperations") == expected_history_operations(entries)
    integer(history.fetch("queryPicks"), "history.queryPicks", minimum: 0, maximum: 10_000)
    fail_gate("wrong history half-life") unless history.fetch("halfLifeSeconds") == 604_800
    fail_gate("wrong history reference time") unless
      history.fetch("referenceUnixSeconds") == 1_800_000_000
    fail_gate("wrong history selection identity") unless history.fetch("selection") == HISTORY_SELECTION
    fingerprint(history.fetch("profileFingerprint"), "history.profileFingerprint")
  end

  def validate_corpus(value, options)
    corpus = value
    fail_gate("corpus must be an object") unless corpus.is_a?(Hash)
    kind = corpus.fetch("kind")
    fixture = kind == "deterministic-fixture"
    real = kind == "isolated-real-crawl"
    fail_gate("unsupported corpus kind #{kind.inspect}") unless fixture || real
    expected_keys = %w[kind description fingerprint itemCount appCount directoryCount generation
                       builtAtUnixSeconds buildSeconds]
    expected_keys += %w[fixtureGeneratorVersion fixtureSeed] if fixture
    exact_keys(corpus, expected_keys, "corpus")
    bounded_string(corpus.fetch("description"), "corpus.description")
    corpus_fingerprint = fingerprint(corpus.fetch("fingerprint"), "corpus.fingerprint")
    item_count = integer(corpus.fetch("itemCount"), "corpus.itemCount",
                         minimum: 0, maximum: MAX_ITEMS)
    integer(corpus.fetch("appCount"), "corpus.appCount", minimum: 0, maximum: item_count)
    integer(corpus.fetch("directoryCount"), "corpus.directoryCount", minimum: 0)
    integer(corpus.fetch("generation"), "corpus.generation", minimum: 0, maximum: UINT64_MAX)
    number(corpus.fetch("builtAtUnixSeconds"), "corpus.builtAtUnixSeconds")
    number(corpus.fetch("buildSeconds"), "corpus.buildSeconds", minimum: 0)

    if fixture
      fail_gate("wrong fixture generator version") unless corpus.fetch("fixtureGeneratorVersion") == 2
      fail_gate("wrong fixture seed") unless corpus.fetch("fixtureSeed") == "0x4a4241525f42454e"
      expected_description =
        "deterministic fixture v2, items=#{item_count}, seed=0x4a4241525f42454e, " \
        "fingerprint=#{corpus_fingerprint}"
      fail_gate("fixture description disagrees with structured identity") unless
        corpus.fetch("description") == expected_description
    end

    case options[:expected_corpus]
    when :fixture
      fail_gate("expected deterministic fixture report") unless fixture
    when :real
      fail_gate("expected isolated real-crawl report") unless real
    end
    if options[:expected_fixture_items]
      fail_gate("fixture item count differs from expected") unless
        fixture && item_count == options.fetch(:expected_fixture_items)
    end
    if options[:expected_fixture_fingerprint]
      fail_gate("fixture fingerprint differs from expected") unless
        fixture && corpus_fingerprint == options.fetch(:expected_fixture_fingerprint)
    end
    [corpus, item_count]
  end

  def validate_row(value, label, item_count, detached: false)
    row = exact_keys(value,
                     %w[itemIndex name path parentDisplay kind matchedByteOffsets score tier], label)
    item_index = integer(row.fetch("itemIndex"), "#{label}.itemIndex",
                         minimum: detached ? -1 : 0,
                         maximum: detached ? -1 : item_count - 1)
    if detached
      fail_gate("#{label}.itemIndex must be the detached-row sentinel -1") unless item_index == -1
    end
    bounded_string(row.fetch("name"), "#{label}.name", max_bytes: 1_024)
    path = bounded_string(row.fetch("path"), "#{label}.path", max_bytes: 4_096)
    fail_gate("#{label}.path must be absolute") unless path.start_with?("/")
    bounded_string(row.fetch("parentDisplay"), "#{label}.parentDisplay", max_bytes: 4_096)
    integer(row.fetch("kind"), "#{label}.kind", minimum: 0, maximum: 9)
    offsets = exact_array(row.fetch("matchedByteOffsets"), "#{label}.matchedByteOffsets")
    fail_gate("#{label}.matchedByteOffsets is unbounded") if offsets.length > 1_024
    offsets.each_with_index do |offset, index|
      integer(offset, "#{label}.matchedByteOffsets[#{index}]", minimum: 0, maximum: 1_024)
    end
    fail_gate("#{label}.matchedByteOffsets must be empty for a recent row") if
      detached && !offsets.empty?
    integer(row.fetch("score"), "#{label}.score")
    integer(row.fetch("tier"), "#{label}.tier")
    row
  end

  def validate_rows(value, label, item_count, max_results, detached: false)
    rows = exact_array(value, label)
    fail_gate("#{label} exceeds maxResults") if rows.length > max_results
    rows.each_with_index do |row, index|
      validate_row(row, "#{label}[#{index}]", item_count, detached: detached)
    end
    rows
  end

  def validate_correctness(value, label, row_count, item_count)
    correctness = exact_keys(value,
                             %w[cancelled totalMatchesIsComplete totalMatches resultFingerprint],
                             label)
    fail_gate("#{label} claims cancellation") unless correctness.fetch("cancelled") == false
    fail_gate("#{label} claims an incomplete total") unless
      correctness.fetch("totalMatchesIsComplete") == true
    total = integer(correctness.fetch("totalMatches"), "#{label}.totalMatches",
                    minimum: row_count, maximum: item_count)
    fingerprint(correctness.fetch("resultFingerprint"), "#{label}.resultFingerprint")
    [correctness, total]
  end

  def validate_response_samples(samples_value, rows, expected_count, label, item_count)
    samples = exact_array(samples_value, "#{label}.samples")
    fail_gate("#{label} has #{samples.length} samples; expected #{expected_count}") unless
      samples.length == expected_count
    first_correctness = nil
    total = nil
    samples.each_with_index do |value, index|
      sample = exact_keys(value, %w[latencyMilliseconds correctness],
                          "#{label}.samples[#{index}]")
      number(sample.fetch("latencyMilliseconds"),
             "#{label}.samples[#{index}].latencyMilliseconds", minimum: 0)
      correctness, sample_total = validate_correctness(
        sample.fetch("correctness"), "#{label}.samples[#{index}].correctness",
        rows.length, item_count
      )
      first_correctness ||= correctness
      total ||= sample_total
      fail_gate("#{label} output changed across samples") unless
        correctness == first_correctness && sample_total == total
    end
    { rows: rows, total: total, fingerprint: first_correctness.fetch("resultFingerprint") }
  end

  def expected_top_result(rows)
    return "(none)" if rows.empty?
    row = rows.first
    tag = case row.fetch("kind")
          when 0 then "app"
          when 1 then "dir"
          else "file"
          end
    "#{row.fetch("name")} [#{tag}]"
  end

  def validate_query_measurement(value, expected_query, expected_count, label,
                                 item_count, max_results)
    measurement = exact_keys(value, %w[query samples topResult validatedRows], label)
    fail_gate("#{label} query identity differs") unless measurement.fetch("query") == expected_query
    detached = expected_query.fetch("text").empty?
    rows = validate_rows(measurement.fetch("validatedRows"), "#{label}.validatedRows",
                         item_count, max_results, detached: detached)
    fail_gate("#{label}.topResult disagrees with retained rows") unless
      measurement.fetch("topResult") == expected_top_result(rows)
    validate_response_samples(measurement.fetch("samples"), rows, expected_count, label, item_count)
  end

  def validate_sequence_measurement(value, expected_sequence, expected_count, label,
                                    item_count, max_results, register)
    sequence = exact_keys(value, %w[name steps], label)
    fail_gate("#{label}.name differs") unless sequence.fetch("name") == expected_sequence.fetch("name")
    steps = exact_array(sequence.fetch("steps"), "#{label}.steps")
    expected_steps = expected_sequence.fetch("steps")
    fail_gate("#{label} step count differs") unless steps.length == expected_steps.length
    steps.zip(expected_steps).each_with_index do |(value_step, query), index|
      step_label = "#{label}.steps[#{index}]"
      step = exact_keys(value_step, %w[query samples validatedRows], step_label)
      fail_gate("#{step_label}.query differs") unless step.fetch("query") == query
      rows = validate_rows(step.fetch("validatedRows"), "#{step_label}.validatedRows",
                           item_count, max_results)
      exact = validate_response_samples(step.fetch("samples"), rows, expected_count,
                                        step_label, item_count)
      register.call(query, exact, step_label)
    end
  end

  def validate_measurements(value, plan, item_count, max_results)
    series = exact_keys(value, %w[cacheCold cacheWarm serialTyping deletion supersession],
                        "measurements")
    exact_by_query = {}
    fingerprint_by_query = {}
    register = lambda do |query, exact, label|
      bounded_string(query, "#{label}.query", allow_empty: true, max_bytes: 16_384)
      comparable = [exact.fetch(:rows), exact.fetch(:total)]
      if exact_by_query.key?(query)
        fail_gate("#{label}: rows or total differ from another workload for #{query.inspect}") unless
          exact_by_query.fetch(query) == comparable
        fail_gate("#{label}: correctness fingerprint differs for #{query.inspect}") unless
          fingerprint_by_query.fetch(query) == exact.fetch(:fingerprint)
      else
        exact_by_query[query] = comparable
        fingerprint_by_query[query] = exact.fetch(:fingerprint)
      end
    end

    cold = exact_array(series.fetch("cacheCold"), "measurements.cacheCold")
    warm = exact_array(series.fetch("cacheWarm"), "measurements.cacheWarm")
    fail_gate("cache-cold query count differs") unless cold.length == QUERIES.length
    fail_gate("cache-warm query count differs") unless warm.length == QUERIES.length
    cold.zip(QUERIES).each_with_index do |(measurement, query), index|
      label = "measurements.cacheCold[#{index}]"
      exact = validate_query_measurement(measurement, query, plan.fetch("fullScan"), label,
                                         item_count, max_results)
      register.call(query.fetch("text"), exact, label)
    end
    warm.zip(QUERIES).each_with_index do |(measurement, query), index|
      label = "measurements.cacheWarm[#{index}]"
      exact = validate_query_measurement(measurement, query, plan.fetch("warm"), label,
                                         item_count, max_results)
      register.call(query.fetch("text"), exact, label)
    end

    [["serialTyping", TYPING_SEQUENCES], ["deletion", DELETION_SEQUENCES]].each do |key, expected|
      sequences = exact_array(series.fetch(key), "measurements.#{key}")
      fail_gate("measurements.#{key} sequence count differs") unless sequences.length == expected.length
      sequences.zip(expected).each_with_index do |(sequence, expected_sequence), index|
        validate_sequence_measurement(sequence, expected_sequence, plan.fetch("sequence"),
                                      "measurements.#{key}[#{index}]", item_count,
                                      max_results, register)
      end
    end

    supersession = series.fetch("supersession")
    fail_gate("measurements.supersession must be an object") unless supersession.is_a?(Hash)
    base_keys = %w[olderQuery newestQuery samples newestValidatedRows]
    allowed_keys = [base_keys.sort, (base_keys + ["completedOlderResult"]).sort]
    fail_gate("measurements.supersession keys differ") unless
      allowed_keys.include?(supersession.keys.sort)
    fail_gate("wrong measured supersession query identity") unless
      supersession.fetch("olderQuery") == "x" && supersession.fetch("newestQuery") == "chrome"
    newest_rows = validate_rows(supersession.fetch("newestValidatedRows"),
                                "measurements.supersession.newestValidatedRows",
                                item_count, max_results)
    samples = exact_array(supersession.fetch("samples"), "measurements.supersession.samples")
    fail_gate("wrong supersession sample count") unless samples.length == plan.fetch("supersession")
    newest_samples = []
    completed_count = 0
    samples.each_with_index do |value_sample, index|
      sample = exact_keys(value_sample, %w[newest pairCompletionLatencyMilliseconds olderCancelled],
                          "measurements.supersession.samples[#{index}]")
      newest_samples << sample.fetch("newest")
      number(sample.fetch("pairCompletionLatencyMilliseconds"),
             "measurements.supersession.samples[#{index}].pairCompletionLatencyMilliseconds",
             minimum: 0)
      cancelled = boolean(sample.fetch("olderCancelled"),
                          "measurements.supersession.samples[#{index}].olderCancelled")
      completed_count += 1 unless cancelled
    end
    newest = validate_response_samples(newest_samples, newest_rows, plan.fetch("supersession"),
                                       "measurements.supersession.newest", item_count)
    register.call("chrome", newest, "measurements.supersession.newest")

    completed_present = supersession.key?("completedOlderResult")
    if completed_count.zero?
      fail_gate("completedOlderResult is present although every older request was cancelled") if
        completed_present
    else
      fail_gate("completedOlderResult is missing although an older request completed") unless
        completed_present
      completed = exact_keys(supersession.fetch("completedOlderResult"), %w[totalMatches rows],
                             "measurements.supersession.completedOlderResult")
      older_rows = validate_rows(completed.fetch("rows"),
                                 "measurements.supersession.completedOlderResult.rows",
                                 item_count, max_results)
      older_total = integer(completed.fetch("totalMatches"),
                            "measurements.supersession.completedOlderResult.totalMatches",
                            minimum: older_rows.length, maximum: item_count)
      # ExactResultEvidence has no independent fingerprint. The cold-x fingerprint is used solely
      # to participate in the same global query accumulator after rows/total equality is checked.
      older = { rows: older_rows, total: older_total,
                fingerprint: fingerprint_by_query.fetch("x") }
      register.call("x", older, "measurements.supersession.completedOlderResult")
    end
  end

  def evaluate(report, options = {})
    top = exact_keys(report,
                     %w[schemaVersion generatedAtUnixSeconds environment workload config history
                        corpus measurements], "report")
    fail_gate("wrong report schema") unless top.fetch("schemaVersion") == 1
    number(top.fetch("generatedAtUnixSeconds"), "generatedAtUnixSeconds")
    validate_environment(top.fetch("environment"))
    plan = validate_workload(top.fetch("workload"), options[:expected_samples])
    max_results = validate_config(top.fetch("config"))
    _corpus, item_count = validate_corpus(top.fetch("corpus"), options)
    validate_history(top.fetch("history"), item_count)
    validate_measurements(top.fetch("measurements"), plan, item_count, max_results)
    corpus = top.fetch("corpus")
    repeat_identity = {
      "schemaVersion" => top.fetch("schemaVersion"),
      "workload" => top.fetch("workload"),
      "config" => top.fetch("config"),
      "history" => top.fetch("history"),
      "corpus" => corpus.reject { |key, _value| key == "buildSeconds" },
    }
    canonical = lambda do |value|
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, output| output[key] = canonical.call(value.fetch(key)) }
      when Array
        value.map { |entry| canonical.call(entry) }
      else
        value
      end
    end
    {
      item_count: item_count,
      samples: plan.fetch("requested"),
      corpus_kind: corpus.fetch("kind"),
      corpus_fingerprint: corpus.fetch("fingerprint"),
      history_fingerprint: top.fetch("history").fetch("profileFingerprint"),
      repeat_identity_sha256: Digest::SHA256.hexdigest(JSON.generate(canonical.call(repeat_identity))),
    }
  end

  def parse_json(data)
    JSON.parse(data, object_class: UniqueKeyHash)
  end

  def read_secure_report(path)
    fail_gate("report path must be a bounded, unambiguous absolute path") unless
      path.is_a?(String) && path.start_with?("/") && path.bytesize <= 4_096 &&
        !path.include?("\0") && !path.include?("\n") && !path.include?("\r")
    flags = File::RDONLY
    fail_gate("this Ruby lacks O_NOFOLLOW support") unless File.const_defined?(:NOFOLLOW)
    flags |= File::NOFOLLOW
    File.open(path, flags) do |io|
      io.binmode
      stat = io.stat
      lstat = File.lstat(path)
      fail_gate("report is not one stable regular file") unless
        stat.file? && lstat.file? && stat.dev == lstat.dev && stat.ino == lstat.ino && stat.nlink == 1
      fail_gate("report is not owned by the current user") unless stat.uid == Process.euid
      fail_gate("report mode must be POSIX 0600") unless (stat.mode & 0o777) == 0o600
      fail_gate("report is empty or exceeds #{MAX_REPORT_BYTES} bytes") unless
        stat.size.positive? && stat.size <= MAX_REPORT_BYTES
      data = io.read(MAX_REPORT_BYTES + 1)
      after = io.stat
      fail_gate("report changed or exceeded its bound while being read") unless
        data.bytesize == stat.size &&
          [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime] ==
            [after.dev, after.ino, after.size, after.mtime, after.ctime]
      data
    end
  rescue Errno::ELOOP
    fail_gate("report path must not be a symbolic link")
  end

  def parse_options(arguments)
    options = { expected_corpus: nil, expected_samples: nil,
                expected_fixture_items: nil, expected_fixture_fingerprint: nil }
    files = []
    index = 0
    while index < arguments.length
      argument = arguments.fetch(index)
      case argument
      when "--expected-samples", "--expected-fixture-items", "--expected-fixture-fingerprint"
        index += 1
        fail_gate("missing value for #{argument}") if index >= arguments.length
        value = arguments.fetch(index)
        case argument
        when "--expected-samples"
          fail_gate("duplicate --expected-samples") unless options[:expected_samples].nil?
          fail_gate("invalid expected sample count") unless /\A[1-9][0-9]{0,4}\z/.match?(value)
          options[:expected_samples] = integer(value.to_i, "expected samples",
                                               minimum: 1, maximum: MAX_SAMPLES)
        when "--expected-fixture-items"
          fail_gate("duplicate --expected-fixture-items") unless options[:expected_fixture_items].nil?
          fail_gate("conflicting corpus expectations") if options[:expected_corpus] == :real
          fail_gate("invalid expected fixture item count") unless /\A[1-9][0-9]{0,6}\z/.match?(value)
          options[:expected_fixture_items] = integer(value.to_i, "expected fixture items",
                                                     minimum: 1, maximum: MAX_ITEMS)
          options[:expected_corpus] = :fixture
        else
          fail_gate("duplicate --expected-fixture-fingerprint") unless
            options[:expected_fixture_fingerprint].nil?
          fail_gate("conflicting corpus expectations") if options[:expected_corpus] == :real
          options[:expected_fixture_fingerprint] = fingerprint(value, "expected fixture fingerprint")
          options[:expected_corpus] = :fixture
        end
      when "--expect-real"
        fail_gate("duplicate or conflicting corpus expectations") unless options[:expected_corpus].nil?
        options[:expected_corpus] = :real
      else
        fail_gate("unknown option #{argument}") if argument.start_with?("-")
        files << argument
      end
      index += 1
    end
    fail_gate("exactly one report path is required") unless files.length == 1
    [options, files.first]
  end

  def fixture(samples: 2, completed_older: true)
    row = {
      "itemIndex" => 0, "name" => "row", "path" => "/fixture/row.pdf",
      "parentDisplay" => "/fixture", "kind" => 2, "matchedByteOffsets" => [0],
      "score" => 10, "tier" => 1,
    }
    fingerprint_for = lambda do |query|
      "0x#{Digest::SHA256.hexdigest(query)[0, 16]}"
    end
    response_samples = lambda do |query, count|
      Array.new(count) do |index|
        {
          "latencyMilliseconds" => index + 0.25,
          "correctness" => {
            "cancelled" => false, "totalMatchesIsComplete" => true, "totalMatches" => 1,
            "resultFingerprint" => fingerprint_for.call(query),
          },
        }
      end
    end
    query_measurement = lambda do |query|
      result_row = row.dup
      if query.fetch("text").empty?
        result_row["itemIndex"] = -1
        result_row["matchedByteOffsets"] = []
      end
      { "query" => query, "samples" => response_samples.call(query.fetch("text"), samples),
        "topResult" => "row [file]", "validatedRows" => [result_row] }
    end
    sequence_measurement = lambda do |sequence|
      { "name" => sequence.fetch("name"), "steps" => sequence.fetch("steps").map { |query|
        { "query" => query, "samples" => response_samples.call(query, samples),
          "validatedRows" => [row.dup] }
      } }
    end
    supersession_samples = Array.new(samples) do |index|
      { "newest" => response_samples.call("chrome", samples).fetch(index),
        "pairCompletionLatencyMilliseconds" => index + 0.5,
        "olderCancelled" => completed_older ? index != 0 : true }
    end
    supersession = {
      "olderQuery" => "x", "newestQuery" => "chrome", "samples" => supersession_samples,
      "newestValidatedRows" => [row.dup],
    }
    supersession["completedOlderResult"] = { "totalMatches" => 1, "rows" => [row.dup] } if
      completed_older
    corpus_fingerprint = "0x0123456789abcdef"
    plan = sample_plan(samples)
    {
      "schemaVersion" => 1, "generatedAtUnixSeconds" => 1_800_000_001.0,
      "environment" => {
        "jbarVersion" => "0.1.0", "buildMode" => "release", "hardwareModel" => "test",
        "cpuBrand" => "test", "processArchitecture" => "arm64", "rosettaTranslated" => false,
        "operatingSystemVersion" => "macOS test", "activeProcessorCount" => 8,
        "physicalMemoryBytes" => 16_000_000_000, "localeIdentifier" => "en_US",
        "timeZoneIdentifier" => "UTC",
      },
      "workload" => {
        "version" => 2, "samplePlan" => plan, "queries" => QUERIES,
        "serialTypingSequences" => TYPING_SEQUENCES, "deletionSequences" => DELETION_SEQUENCES,
        "supersessionOlderQuery" => "x", "supersessionNewestQuery" => "chrome",
        "clock" => WORKLOAD_CLOCK, "percentileMethod" => PERCENTILE_METHOD,
        "correctnessPolicy" => CORRECTNESS_POLICY,
      },
      "config" => {
        "source" => "built-in defaults", "maxResults" => 60, "appsFirstCap" => 15,
        "searchReferenceUnixSeconds" => 1_800_000_000,
        "rankingIntegerWeights" => RANKING_KEYS.each_with_object({}) { |key, hash| hash[key] = 1 },
        "frecencyScale" => 1.0,
      },
      "history" => {
        "profileVersion" => 1, "mode" => HISTORY_MODE, "persistence" => HISTORY_PERSISTENCE,
        "maxEntries" => 500, "seededEntries" => 500, "recordOperations" => 999,
        "queryPicks" => 4, "halfLifeSeconds" => 604_800,
        "referenceUnixSeconds" => 1_800_000_000, "selection" => HISTORY_SELECTION,
        "profileFingerprint" => "0xfedcba9876543210",
      },
      "corpus" => {
        "kind" => "deterministic-fixture",
        "description" => "deterministic fixture v2, items=1000, seed=0x4a4241525f42454e, " \
                         "fingerprint=#{corpus_fingerprint}",
        "fingerprint" => corpus_fingerprint, "fixtureGeneratorVersion" => 2,
        "fixtureSeed" => "0x4a4241525f42454e", "itemCount" => 1000, "appCount" => 10,
        "directoryCount" => 20, "generation" => 1, "builtAtUnixSeconds" => 1_800_000_000.0,
        "buildSeconds" => 0.1,
      },
      "measurements" => {
        "cacheCold" => QUERIES.map { |query| query_measurement.call(query) },
        "cacheWarm" => QUERIES.map { |query| query_measurement.call(query) },
        "serialTyping" => TYPING_SEQUENCES.map { |sequence| sequence_measurement.call(sequence) },
        "deletion" => DELETION_SEQUENCES.map { |sequence| sequence_measurement.call(sequence) },
        "supersession" => supersession,
      },
    }
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def self_test!
    baseline = fixture
    summary = evaluate(baseline, expected_samples: 2, expected_corpus: :fixture,
                        expected_fixture_items: 1000,
                        expected_fixture_fingerprint: "0x0123456789abcdef")
    fail_gate("self-test baseline summary differs") unless
      summary.fetch(:item_count) == 1000 && summary.fetch(:samples) == 2 &&
        summary.fetch(:corpus_kind) == "deterministic-fixture" &&
        summary.fetch(:corpus_fingerprint) == "0x0123456789abcdef" &&
        summary.fetch(:history_fingerprint) == "0xfedcba9876543210" &&
        /\A[0-9a-f]{64}\z/.match?(summary.fetch(:repeat_identity_sha256))

    reject = lambda do |description, &mutation|
      changed = deep_copy(baseline)
      mutation.call(changed)
      begin
        evaluate(changed)
      rescue KeyError, IndexError, ArgumentError, TypeError, RuntimeError
        next
      end
      fail_gate("self-test: #{description} was accepted")
    end
    reject.call("wrong schema") { |report| report["schemaVersion"] = 2 }
    reject.call("wrong sample plan") { |report| report["workload"]["samplePlan"]["warm"] = 1 }
    reject.call("wrong history") { |report| report["history"]["recordOperations"] = 998 }
    reject.call("wrong corpus identity") { |report| report["corpus"]["fixtureGeneratorVersion"] = 1 }
    reject.call("indexed identity on detached empty-query row") do |report|
      report["measurements"]["cacheCold"][0]["validatedRows"][0]["itemIndex"] = 0
    end
    reject.call("match offsets on detached empty-query row") do |report|
      report["measurements"]["cacheCold"][0]["validatedRows"][0]["matchedByteOffsets"] = [0]
    end
    reject.call("detached identity on corpus-backed search row") do |report|
      report["measurements"]["cacheCold"][1]["validatedRows"][0]["itemIndex"] = -1
    end
    reject.call("second repeated r drift") do |report|
      report["measurements"]["serialTyping"][2]["steps"][0]["validatedRows"][0]["score"] += 1
    end
    reject.call("repeated report-p drift") do |report|
      report["measurements"]["deletion"][1]["steps"][1]["validatedRows"][0]["tier"] += 1
    end
    reject.call("repeated repor drift") do |report|
      report["measurements"]["deletion"][1]["steps"][4]["validatedRows"][0]["tier"] += 1
    end
    reject.call("changed correctness sample") do |report|
      report["measurements"]["cacheCold"][0]["samples"][1]["correctness"]["totalMatches"] = 2
    end
    reject.call("negative latency") do |report|
      report["measurements"]["cacheWarm"][0]["samples"][0]["latencyMilliseconds"] = -1
    end
    reject.call("missing completed-older evidence") do |report|
      report["measurements"]["supersession"].delete("completedOlderResult")
    end
    reject.call("completed-older rows differ from cold x") do |report|
      report["measurements"]["supersession"]["completedOlderResult"]["rows"][0]["score"] += 1
    end
    all_cancelled = fixture(completed_older: false)
    evaluate(all_cancelled)
    all_cancelled["measurements"]["supersession"]["completedOlderResult"] = {
      "totalMatches" => 1,
      "rows" => deep_copy(all_cancelled["measurements"]["cacheCold"][1]["validatedRows"]),
    }
    begin
      evaluate(all_cancelled)
    rescue RuntimeError
      all_cancelled = nil
    end
    fail_gate("self-test: completed-older evidence with all cancellations was accepted") unless
      all_cancelled.nil?

    [%w[--expect-real --expected-fixture-items 1000 /tmp/report.json],
     %w[--expected-fixture-items 1000 --expect-real /tmp/report.json],
     %w[--expected-samples 2 --expected-samples 2 /tmp/report.json],
     %w[--expect-real --expect-real /tmp/report.json]].each do |arguments|
      begin
        parse_options(arguments)
      rescue RuntimeError
        next
      end
      fail_gate("self-test: conflicting or duplicate options were accepted: #{arguments.inspect}")
    end

    Dir.mktmpdir("jbar-benchmark-gate.") do |directory|
      report_path = File.join(directory, "report.json")
      File.open(report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(baseline))
      end
      loaded = parse_json(read_secure_report(report_path))
      evaluate(loaded)
      File.chmod(0o644, report_path)
      begin
        read_secure_report(report_path)
      rescue RuntimeError
        report_path = nil
      end
      fail_gate("self-test: permissive report mode was accepted") unless report_path.nil?
    end
    begin
      parse_json('{"schemaVersion":1,"schemaVersion":1}')
    rescue RuntimeError
      puts "PASS: benchmark report JSON duplicate-key rejection"
    else
      fail_gate("self-test: duplicate JSON object keys were accepted")
    end
    puts "PASS: benchmark report gate rejects schema, parity, sample, and completed-older drift"
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--self-test"]
    begin
      JBarBenchmarkReportGate.self_test!
      exit 0
    rescue KeyError, IndexError, JSON::ParserError, ArgumentError, TypeError, RuntimeError,
           SystemCallError => error
      abort "benchmark report gate self-test error: #{error.message}"
    end
  end

  begin
    options, report_path = JBarBenchmarkReportGate.parse_options(ARGV)
    report = JBarBenchmarkReportGate.parse_json(JBarBenchmarkReportGate.read_secure_report(report_path))
    summary = JBarBenchmarkReportGate.evaluate(report, options)
    puts "PASS: benchmark schema v1/workload v2 correctness; " \
         "corpus=#{summary.fetch(:corpus_kind)}, items=#{summary.fetch(:item_count)}, " \
         "requested-samples=#{summary.fetch(:samples)}"
    puts "IDENTITY schemaVersion=1 workloadVersion=2 samples=#{summary.fetch(:samples)} " \
         "corpusKind=#{summary.fetch(:corpus_kind)} itemCount=#{summary.fetch(:item_count)} " \
         "corpusFingerprint=#{summary.fetch(:corpus_fingerprint)} " \
         "historyProfileFingerprint=#{summary.fetch(:history_fingerprint)} " \
         "identitySha256=#{summary.fetch(:repeat_identity_sha256)}"
  rescue KeyError, IndexError, JSON::ParserError, ArgumentError, TypeError, RuntimeError,
         SystemCallError => error
    abort "benchmark report gate error: #{error.message}"
  end
end
