import Foundation
import Darwin
import CoreServices
import JBarCore

/// `--benchmark`: a reproducible, non-destructive benchmark for JBar's search engine.
///
/// The default run performs a real, cold crawl using an isolated temporary snapshot and then reports
/// cache-cold, cache-warm, typing, deletion and rapid-supersession workloads separately. Spotlight is
/// shown only as a same-root, filename-substring reference: its query semantics and system-wide service
/// architecture differ from JBar, so this command deliberately does not calculate a speedup ratio.
///
/// Deterministic synthetic corpora are selected with `JBAR_BENCHMARK_FIXTURE_ITEMS`. The release harness
/// runs the audited 300k / 500k / 1M sizes in separate processes so their RSS measurements do not mix.
///
/// Usage: `JBar --benchmark [iterations]`
enum Benchmark {
    static let fixtureSeed: UInt64 = 0x4A_42_41_52_5F_42_45_4E // "JBAR_BEN"
    static let fixtureGeneratorVersion = 2
    static let workloadVersion = 2
    static let reportSchemaVersion = 1
    static let fixtureItemsEnvironmentKey = "JBAR_BENCHMARK_FIXTURE_ITEMS"
    static let reportOutputEnvironmentKey = "JBAR_BENCHMARK_JSON_OUTPUT"
    static let maxReportBytes = 32 * 1_048_576
    static let benchmarkReferenceUnixSeconds: TimeInterval = 1_800_000_000
    static let benchmarkHistoryEntries = 500
    static let coverageSeed: UInt64 = 0xC0_FF_EE_20_26_08_19
    static let maxSpotlightMembershipResults = 100_000
    static let crossToolComparisonPolicy =
        "ratio omitted: JBar fuzzy name/alias ranking and Spotlight filename-substring metadata queries are not equivalent workloads"

    struct QueryCase: Sendable, Equatable, Codable {
        enum Category: String, Sendable, Codable {
            case empty
            case commonLetter = "common-letter"
            case selective
            case acronym
            case multiTerm = "multi-term"
            case extensionQuery = "extension"
        }

        let text: String
        let category: Category
    }

    /// The fixed suite explicitly covers every query-density class named in issue #3.
    static let queryCases: [QueryCase] = [
        QueryCase(text: "", category: .empty),
        QueryCase(text: "x", category: .commonLetter),
        QueryCase(text: "chrome", category: .selective),
        QueryCase(text: "vsc", category: .acronym),
        QueryCase(text: "report pdf", category: .multiTerm),
        QueryCase(text: ".pdf", category: .extensionQuery),
    ]

    struct SequenceCase: Sendable, Equatable, Codable {
        let name: String
        let steps: [String]
    }

    static let typingSequences: [SequenceCase] = [
        SequenceCase(name: "common→selective", steps: ["r", "re", "rep", "repo", "report"]),
        SequenceCase(name: "selective", steps: ["c", "ch", "chr", "chro", "chrome"]),
        SequenceCase(name: "multi-term", steps: ["r", "re", "report", "report ", "report p", "report pdf"]),
    ]

    static let deletionSequences: [SequenceCase] = [
        SequenceCase(name: "backspace", steps: ["repor", "repo", "rep", "re", "r"]),
        SequenceCase(name: "multi-term backspace", steps: ["report pd", "report p", "report ", "report", "repor"]),
    ]

    struct SamplePlan: Equatable, Sendable, Codable {
        let requested: Int
        let warm: Int
        let fullScan: Int
        let sequence: Int
        let supersession: Int
        let spotlight: Int
    }

    /// Full-store scans and Spotlight gathers are intentionally capped independently of the cheap
    /// repeated-query count. The exact sample count is printed, so a short smoke run cannot be mistaken
    /// for a publication run.
    static func samplePlan(iterations value: Int) -> SamplePlan {
        let n = boundedIterations(value)
        // One hundred observations makes nearest-rank p99 a real order statistic instead of merely
        // aliasing p95/max as it would with a 20-sample publication run.
        return SamplePlan(requested: n, warm: n, fullScan: min(n, 100), sequence: min(n, 100),
                          supersession: min(n, 100), spotlight: min(n, 5))
    }

    struct Distribution: Equatable, Sendable, Codable {
        let count: Int
        let minimum: Double
        let p50: Double
        let p95: Double
        let p99: Double
        let maximum: Double
    }

    /// Nearest-rank percentiles over caller-observed wall latency. No best-of-N selection is used.
    static func distribution(_ values: [Double]) -> Distribution? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func nearestRank(_ p: Double) -> Double {
            let rank = max(1, Int(ceil(p * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }
        return Distribution(count: sorted.count, minimum: sorted[0], p50: nearestRank(0.50),
                            p95: nearestRank(0.95), p99: nearestRank(0.99), maximum: sorted[sorted.count - 1])
    }

    struct ScopePlan: Equatable, Sendable {
        let fileRoots: [String]
        let appRoots: [String]
        let extraBundles: [String]
        let spotlightScopes: [String]
        let missingScopes: [String]

        var jbarRootCount: Int { fileRoots.count + appRoots.count + extraBundles.count }

        func containsForSpotlight(_ path: String) -> Bool {
            spotlightScopes.contains { Benchmark.path(path, isWithinRoot: $0) }
        }
    }

    struct ConfigSource: Sendable {
        let config: Config
        let description: String
    }

    struct Fixture: Sendable {
        let store: IndexStore
        let fingerprint: UInt64
    }

    struct HistoryProfile: Codable, Equatable, Sendable {
        let profileVersion: Int
        let mode: String
        let persistence: String
        let maxEntries: Int
        let seededEntries: Int
        let recordOperations: Int
        let queryPicks: Int
        let halfLifeSeconds: Double
        let referenceUnixSeconds: Double
        let selection: String
        let profileFingerprint: String
    }

    struct HistoryFixture: Sendable {
        let store: FrecencyStore
        let profile: HistoryProfile
    }

    struct CorrectnessSignature: Codable, Equatable, Sendable {
        let cancelled: Bool
        let totalMatchesIsComplete: Bool
        let totalMatches: Int
        let resultFingerprint: String
    }

    struct ResponseSample: Codable, Equatable, Sendable {
        let latencyMilliseconds: Double
        let correctness: CorrectnessSignature
    }

    private struct CodableResultRow: Codable, Equatable, Sendable {
        let itemIndex: Int
        let name: String
        let path: String
        let parentDisplay: String
        let kind: ItemKind
        let matchedByteOffsets: [Int]
        let score: Int
        let tier: Int

        init(_ row: ResultRow) {
            itemIndex = row.itemIndex
            name = row.name
            path = row.path
            parentDisplay = row.parentDisplay
            kind = row.kind
            matchedByteOffsets = row.matchedByteOffsets
            score = row.score
            tier = row.tier
        }

        var row: ResultRow {
            ResultRow(itemIndex: itemIndex, name: name, path: path,
                      parentDisplay: parentDisplay, kind: kind,
                      matchedByteOffsets: matchedByteOffsets, score: score, tier: tier)
        }
    }

    struct QueryMeasurement: Equatable, Sendable, Codable {
        let query: QueryCase
        let samples: [ResponseSample]
        let topResult: String
        let validatedRows: [ResultRow]

        var stats: Distribution { distribution(samples.map(\.latencyMilliseconds))! }
        var matches: Int { samples[0].correctness.totalMatches }
        var fingerprint: String { samples[0].correctness.resultFingerprint }

        private enum CodingKeys: String, CodingKey { case query, samples, topResult, validatedRows }
        init(query: QueryCase, samples: [ResponseSample], topResult: String,
             validatedRows: [ResultRow]) {
            self.query = query; self.samples = samples; self.topResult = topResult
            self.validatedRows = validatedRows
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            query = try container.decode(QueryCase.self, forKey: .query)
            samples = try container.decode([ResponseSample].self, forKey: .samples)
            topResult = try container.decode(String.self, forKey: .topResult)
            validatedRows = try container.decode([CodableResultRow].self, forKey: .validatedRows).map(\.row)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(query, forKey: .query)
            try container.encode(samples, forKey: .samples)
            try container.encode(topResult, forKey: .topResult)
            try container.encode(validatedRows.map(CodableResultRow.init), forKey: .validatedRows)
        }
    }

    struct SequenceStepMeasurement: Equatable, Sendable, Codable {
        let query: String
        let samples: [ResponseSample]
        let validatedRows: [ResultRow]

        var stats: Distribution { distribution(samples.map(\.latencyMilliseconds))! }

        private enum CodingKeys: String, CodingKey { case query, samples, validatedRows }
        init(query: String, samples: [ResponseSample], validatedRows: [ResultRow]) {
            self.query = query; self.samples = samples; self.validatedRows = validatedRows
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            query = try container.decode(String.self, forKey: .query)
            samples = try container.decode([ResponseSample].self, forKey: .samples)
            validatedRows = try container.decode([CodableResultRow].self, forKey: .validatedRows).map(\.row)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(query, forKey: .query)
            try container.encode(samples, forKey: .samples)
            try container.encode(validatedRows.map(CodableResultRow.init), forKey: .validatedRows)
        }
    }

    struct SequenceMeasurement: Codable, Equatable, Sendable {
        let name: String
        let steps: [SequenceStepMeasurement]
    }

    struct SupersessionSample: Codable, Equatable, Sendable {
        let newest: ResponseSample
        let pairCompletionLatencyMilliseconds: Double
        let olderCancelled: Bool
    }

    struct ExactResultEvidence: Equatable, Sendable, Codable {
        let totalMatches: Int
        let rows: [ResultRow]

        private enum CodingKeys: String, CodingKey { case totalMatches, rows }
        init(totalMatches: Int, rows: [ResultRow]) {
            self.totalMatches = totalMatches
            self.rows = rows
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalMatches = try container.decode(Int.self, forKey: .totalMatches)
            rows = try container.decode([CodableResultRow].self, forKey: .rows).map(\.row)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(totalMatches, forKey: .totalMatches)
            try container.encode(rows.map(CodableResultRow.init), forKey: .rows)
        }
    }

    struct SupersessionMeasurement: Equatable, Sendable, Codable {
        let olderQuery: String
        let newestQuery: String
        let samples: [SupersessionSample]
        let newestValidatedRows: [ResultRow]
        /// Present iff at least one older request completed instead of being cancelled. All such
        /// completions have already passed one direct-row validator and therefore share this output.
        let completedOlderResult: ExactResultEvidence?

        var newest: Distribution { distribution(samples.map { $0.newest.latencyMilliseconds })! }
        var pair: Distribution { distribution(samples.map(\.pairCompletionLatencyMilliseconds))! }
        var olderCancelled: Int { samples.lazy.filter(\.olderCancelled).count }
        var newestCancelled: Int { 0 }

        private enum CodingKeys: String, CodingKey {
            case olderQuery, newestQuery, samples, newestValidatedRows, completedOlderResult
        }
        init(olderQuery: String, newestQuery: String, samples: [SupersessionSample],
             newestValidatedRows: [ResultRow], completedOlderResult: ExactResultEvidence?) {
            self.olderQuery = olderQuery; self.newestQuery = newestQuery
            self.samples = samples; self.newestValidatedRows = newestValidatedRows
            self.completedOlderResult = completedOlderResult
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            olderQuery = try container.decode(String.self, forKey: .olderQuery)
            newestQuery = try container.decode(String.self, forKey: .newestQuery)
            samples = try container.decode([SupersessionSample].self, forKey: .samples)
            newestValidatedRows = try container.decode(
                [CodableResultRow].self, forKey: .newestValidatedRows
            ).map(\.row)
            completedOlderResult = try container.decodeIfPresent(
                ExactResultEvidence.self, forKey: .completedOlderResult
            )
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(olderQuery, forKey: .olderQuery)
            try container.encode(newestQuery, forKey: .newestQuery)
            try container.encode(samples, forKey: .samples)
            try container.encode(newestValidatedRows.map(CodableResultRow.init),
                                 forKey: .newestValidatedRows)
            try container.encodeIfPresent(completedOlderResult, forKey: .completedOlderResult)
        }
    }

    struct EnvironmentIdentity: Codable, Equatable, Sendable {
        let jbarVersion: String
        let buildMode: String
        let hardwareModel: String
        let cpuBrand: String
        let processArchitecture: String
        let rosettaTranslated: Bool
        let operatingSystemVersion: String
        let activeProcessorCount: Int
        let physicalMemoryBytes: UInt64
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    struct WorkloadIdentity: Codable, Equatable, Sendable {
        let version: Int
        let samplePlan: SamplePlan
        let queries: [QueryCase]
        let serialTypingSequences: [SequenceCase]
        let deletionSequences: [SequenceCase]
        let supersessionOlderQuery: String
        let supersessionNewestQuery: String
        let clock: String
        let percentileMethod: String
        let correctnessPolicy: String
    }

    struct ConfigIdentity: Codable, Equatable, Sendable {
        let source: String
        let maxResults: Int
        let appsFirstCap: Int
        let searchReferenceUnixSeconds: Double
        let rankingIntegerWeights: [String: Int]
        let frecencyScale: Double
    }

    struct CorpusIdentity: Codable, Equatable, Sendable {
        let kind: String
        let description: String
        let fingerprint: String
        let fixtureGeneratorVersion: Int?
        let fixtureSeed: String?
        let itemCount: Int
        let appCount: Int
        let directoryCount: Int
        let generation: UInt64
        let builtAtUnixSeconds: Double
        let buildSeconds: Double
    }

    struct MeasurementReport: Codable, Equatable, Sendable {
        let cacheCold: [QueryMeasurement]
        let cacheWarm: [QueryMeasurement]
        let serialTyping: [SequenceMeasurement]
        let deletion: [SequenceMeasurement]
        let supersession: SupersessionMeasurement
    }

    struct MachineReport: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let generatedAtUnixSeconds: Double
        let environment: EnvironmentIdentity
        let workload: WorkloadIdentity
        let config: ConfigIdentity
        let history: HistoryProfile
        let corpus: CorpusIdentity
        let measurements: MeasurementReport
    }

    private struct Corpus {
        enum Kind { case real, fixture }
        let kind: Kind
        let store: IndexStore
        let fingerprint: UInt64
        let buildSeconds: Double
        let description: String
        let scope: ScopePlan?
        let status: IndexStatus?
    }

    struct ResponseValidationState: Sendable {
        let context: String
        let expectedQuery: String
        let expectedMode: QueryMode
        let expectedGeneration: UInt64
        let rowCap: Int
        let totalUpperBound: Int
        private(set) var expectedRows: [ResultRow]?
        private(set) var expectedTotalMatches: Int?

        init(context: String, expectedQuery: String, expectedMode: QueryMode,
             expectedGeneration: UInt64, rowCap: Int, totalUpperBound: Int) {
            self.context = context; self.expectedQuery = expectedQuery; self.expectedMode = expectedMode
            self.expectedGeneration = expectedGeneration; self.rowCap = rowCap
            self.totalUpperBound = totalUpperBound
        }

        mutating func accept(_ response: SearchResponse, latencyMilliseconds: Double) throws -> ResponseSample {
            guard latencyMilliseconds.isFinite, latencyMilliseconds >= 0 else {
                throw BenchmarkError.invalidMeasurement("\(context): non-finite or negative latency")
            }
            guard !response.cancelled else {
                throw BenchmarkError.invalidMeasurement("\(context): measured response was cancelled")
            }
            guard response.totalMatchesIsComplete else {
                throw BenchmarkError.invalidMeasurement("\(context): measured response has an incomplete total")
            }
            guard response.query == expectedQuery, response.mode == expectedMode,
                  response.generation == expectedGeneration else {
                throw BenchmarkError.invalidMeasurement(
                    "\(context): response query/mode/generation does not match the submitted workload"
                )
            }
            guard rowCap >= 0, response.rows.count <= rowCap else {
                throw BenchmarkError.invalidMeasurement(
                    "\(context): response returned \(response.rows.count) rows above cap \(rowCap)"
                )
            }
            guard totalUpperBound >= 0, (0...totalUpperBound).contains(response.totalMatches),
                  response.rows.count <= response.totalMatches else {
                throw BenchmarkError.invalidMeasurement(
                    "\(context): exact total \(response.totalMatches) is outside rows...\(totalUpperBound)"
                )
            }
            if let expectedTotalMatches, expectedTotalMatches != response.totalMatches {
                throw BenchmarkError.invalidMeasurement(
                    "\(context): total changed from \(expectedTotalMatches) to \(response.totalMatches)"
                )
            }
            if let expectedRows, expectedRows != response.rows {
                throw BenchmarkError.invalidMeasurement("\(context): ordered result rows changed across samples")
            }
            let signature = CorrectnessSignature(cancelled: response.cancelled,
                                                 totalMatchesIsComplete: response.totalMatchesIsComplete,
                                                 totalMatches: response.totalMatches,
                                                 resultFingerprint: responseFingerprint(response))
            if expectedTotalMatches == nil { expectedTotalMatches = response.totalMatches }
            if expectedRows == nil { expectedRows = response.rows }
            return ResponseSample(latencyMilliseconds: latencyMilliseconds, correctness: signature)
        }
    }

    enum BenchmarkError: LocalizedError {
        case invalidFixtureSize(String)
        case invalidReportOutput(String)
        case invalidMeasurement(String)
        case invalidReport(String)
        case reportWriteFailed(String)
        case cannotCreateState(String)
        case cannotRemoveState(String)
        case crawlFailed(String)
        case crawlTimedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .invalidFixtureSize(let value):
                return "\(fixtureItemsEnvironmentKey)=\(value) must be an integer in 1...\(SafetyLimits.maxIndexedItems.upperBound)"
            case .invalidReportOutput(let message): return "invalid \(reportOutputEnvironmentKey): \(message)"
            case .invalidMeasurement(let message): return "correctness validation failed: \(message)"
            case .invalidReport(let message): return "invalid benchmark report: \(message)"
            case .reportWriteFailed(let message): return "could not write benchmark report: \(message)"
            case .cannotCreateState(let message): return "could not create isolated benchmark state: \(message)"
            case .cannotRemoveState(let message): return "could not remove isolated benchmark state: \(message)"
            case .crawlFailed(let message): return "isolated crawl failed: \(message)"
            case .crawlTimedOut(let seconds): return String(format: "isolated crawl did not finish within %.0f s", seconds)
            }
        }
    }

    static func run(iterations: Int) async -> Int32 {
        let plan = samplePlan(iterations: iterations)
        setvbuf(stdout, nil, _IONBF, 0)

        let reportOutput: URL?
        do {
            reportOutput = try requestedReportOutput()
        } catch {
            writeBenchmarkError(error)
            return 2
        }

        print("== JBar reproducible search benchmark ==")
        printEnvironment(plan: plan)
        print("comparison policy: \(crossToolComparisonPolicy)")
        print("percentiles: nearest-rank p50/p95/p99/max of caller-observed wall time; no best-of-N")
        if let reportOutput { print("machine report requested: \(reportOutput.path)") }

        let baselineRSS = ProcessMemory.residentBytes()
        let corpus: Corpus
        let cfg: Config
        let configDescription: String
        do {
            if let fixtureItems = try requestedFixtureItems() {
                cfg = .default
                configDescription = "built-in defaults"
                let start = monotonicNow()
                let fixture = makeFixture(itemCount: fixtureItems)
                corpus = Corpus(kind: .fixture, store: fixture.store, fingerprint: fixture.fingerprint,
                                buildSeconds: elapsedMS(since: start) / 1_000,
                                description: "deterministic fixture v\(fixtureGeneratorVersion), items=\(fixtureItems), seed=0x\(String(fixtureSeed, radix: 16)), fingerprint=0x\(String(fixture.fingerprint, radix: 16))",
                                scope: nil, status: nil)
            } else {
                let source = readOnlyConfig()
                cfg = source.config
                configDescription = source.description
                print("config: \(source.description)")
                corpus = try await buildIsolatedRealCorpus(config: cfg)
            }
        } catch {
            writeBenchmarkError(error)
            if case BenchmarkError.invalidFixtureSize = error { return 2 }
            return 1
        }

        printCorpus(corpus, rssBefore: baselineRSS, rssAfter: ProcessMemory.residentBytes())

        let history = makeDeterministicHistory(for: corpus.store)
        printHistory(history.profile)
        let engine = SearchEngine(frecency: history.store)
        await engine.update(store: corpus.store)
        await engine.setHome(NSHomeDirectory())

        do {
            print("\n-- Engine cache cold / full-store work (n=\(plan.fullScan) per query) --")
            print("cache state: SearchEngine cache is cleared before every sample; search/extension modes scan the store, while <empty> is a no-scan control; file pages and CPU caches may still be warm")
            let cold = try await measureQueries(queryCases, engine: engine, store: corpus.store, cfg: cfg,
                                                samples: plan.fullScan, warmCache: false)
            printMeasurements(cold)

            print("\n-- Repeated identical query / cache-hit work (n=\(plan.warm) per query) --")
            print("cache state: one validated, unmeasured warm-up, followed by identical queries on the same engine/store; candidate-cache reuse applies to normal search mode, not <empty> or extension mode")
            let warm = try await measureQueries(queryCases, engine: engine, store: corpus.store, cfg: cfg,
                                                samples: plan.warm, warmCache: true)
            printMeasurements(warm)

            print("\n-- Serial typing sequences (n=\(plan.sequence) sequences; each cell has n samples) --")
            print("execution: serial synthetic query submissions, not key-to-paint UI latency; cache is cleared before each sequence, then extensions may reuse candidates")
            let typing = try await measureSequences(typingSequences, deletion: false, engine: engine,
                                                    store: corpus.store, cfg: cfg,
                                                    repetitions: plan.sequence)
            printSequences(typing)

            print("\n-- Deletion/backspace sequences (n=\(plan.sequence) sequences; each cell has n samples) --")
            print("execution: serial synthetic query submissions; final text is seeded and validated unmeasured, then shortening invalidates the incremental cache")
            let deletion = try await measureSequences(deletionSequences, deletion: true, engine: engine,
                                                      store: corpus.store, cfg: cfg,
                                                      repetitions: plan.sequence)
            printSequences(deletion)

            print("\n-- Rapid supersession / cancellation (n=\(plan.supersession) pairs) --")
            let supersession = try await measureSupersession(engine: engine, store: corpus.store, cfg: cfg,
                                                             repetitions: plan.supersession)
            try validateCrossWorkloadParity(cold: cold, warm: warm,
                                            sequences: typing + deletion,
                                            supersession: supersession)
            print("older='x', newest='chrome'; newest " + format(supersession.newest)
                  + "; pair completion " + format(supersession.pair))
            print("older cancelled: \(supersession.olderCancelled)/\(plan.supersession); newest unexpectedly cancelled: \(supersession.newestCancelled)/\(plan.supersession)")

            if corpus.kind == .real, let scope = corpus.scope {
                await printSpotlightReference(scope: scope, samples: plan.spotlight)
                await printCoverage(engine: engine, store: corpus.store, cfg: cfg, scope: scope)
            } else {
                print("\n-- Spotlight reference --")
                print("not run: deterministic fixture paths do not exist in Spotlight; cross-tool counts/latencies would be fabricated")
            }

            if let finalRSS = ProcessMemory.residentBytes() {
                print(String(format: "\nfinal process RSS: %.1f MiB (JBar process only; Spotlight/system-service memory excluded)", mib(finalRSS)))
            }

            if let reportOutput {
                let report = makeMachineReport(plan: plan, config: cfg,
                                               configDescription: configDescription,
                                               corpus: corpus, history: history.profile,
                                               cold: cold, warm: warm, typing: typing,
                                               deletion: deletion, supersession: supersession)
                try writeMachineReport(report, to: reportOutput)
                print("machine report: wrote schema v\(reportSchemaVersion) to \(reportOutput.path)")
            }
        } catch {
            writeBenchmarkError(error)
            return 1
        }
        return 0
    }

    static func boundedIterations(_ value: Int) -> Int {
        min(max(1, value), SafetyLimits.maxBenchmarkIterations)
    }

    // MARK: - Configuration and isolated corpus construction

    /// Read configuration without calling `Config.load`, because that API creates a default file when
    /// none exists. A benchmark must never mutate production state merely by inspecting configuration.
    static func readOnlyConfig(from url: URL = Config.defaultURL()) -> ConfigSource {
        switch Config.loadReadOnly(from: url) {
        case .loaded(let config):
            return ConfigSource(config: config, description: "read-only \(abbreviate(url.path))")
        case .missing:
            return ConfigSource(config: .default, description: "defaults (config absent; no file created)")
        case .invalid(let message):
            return ConfigSource(config: .default,
                                description: "defaults (config unreadable/invalid: \(message); no writes performed)")
        }
    }

    static func requestedFixtureItems(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int? {
        guard let raw = environment[fixtureItemsEnvironmentKey] else { return nil }
        guard let value = Int(raw), SafetyLimits.maxIndexedItems.contains(value) else {
            throw BenchmarkError.invalidFixtureSize(raw)
        }
        return value
    }

    static func isolatedOptions(config: Config, stateDirectory: URL,
                                home: String = NSHomeDirectory()) -> IndexCoordinator.Options {
        var options = config.coordinatorOptions(home: home)
        options.watchFileSystem = false
        options.snapshotWriteInterval = 0
        options.snapshotURL = stateDirectory.appendingPathComponent("index.snapshot", isDirectory: false)
        return options
    }

    static func scopePlan(config: Config, home: String = NSHomeDirectory()) -> ScopePlan {
        let exclusions = config.exclusions(home: home)
        var files: [String] = []
        for entry in config.fileRoots {
            if entry == "~" {
                files.append(contentsOf: Crawler.defaultRoots(home: home, exclusions: exclusions).map(\.path))
            } else {
                files.append(Exclusions.expandTilde(entry, home: home))
            }
        }
        let apps = config.appDirectories.map { Exclusions.expandTilde($0, home: home) }
        let extras = AppScanner.extraBundles.map { Exclusions.expandTilde($0, home: home) }
        let all = uniqueStandardized(files + apps + extras)
        let existing = all.filter { FileManager.default.fileExists(atPath: $0) }
        let missing = all.filter { !FileManager.default.fileExists(atPath: $0) }
        return ScopePlan(fileRoots: uniqueStandardized(files), appRoots: uniqueStandardized(apps),
                         extraBundles: uniqueStandardized(extras), spotlightScopes: minimalRoots(existing),
                         missingScopes: missing)
    }

    private static func buildIsolatedRealCorpus(config: Config) async throws -> Corpus {
        let fm = FileManager.default
        let state = fm.temporaryDirectory.appendingPathComponent("jbar-benchmark-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: state, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            throw BenchmarkError.cannotCreateState(error.localizedDescription)
        }
        let options = isolatedOptions(config: config, stateDirectory: state)
        let productionSnapshot = Snapshot.defaultURL().standardizedFileURL.path
        precondition(options.snapshotURL.standardizedFileURL.path != productionSnapshot,
                     "benchmark snapshot must not alias production state")

        let coordinator = IndexCoordinator(options: options, callbackQueue: .main)
        do {
            let timeout: TimeInterval = 120
            let start = monotonicNow()
            let initialGeneration = coordinator.store.generation
            var ready = false
            coordinator.start()
            while elapsedMS(since: start) < timeout * 1_000 {
                switch coordinator.status.phase {
                case .failed(let message): throw BenchmarkError.crawlFailed(message)
                case .idle:
                    ready = coordinator.store.generation > initialGeneration
                default: break
                }
                if ready { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard ready else { throw BenchmarkError.crawlTimedOut(timeout) }
            let buildSeconds = elapsedMS(since: start) / 1_000
            let status = coordinator.status
            let store = coordinator.store
            coordinator.stop()
            try cleanupIsolatedState(at: state)

            return Corpus(kind: .real, store: store, fingerprint: storeFingerprint(store),
                          buildSeconds: buildSeconds,
                          description: "real filesystem, forced cold crawl, isolated temporary snapshot removed before measurement",
                          scope: scopePlan(config: config), status: status)
        } catch {
            coordinator.stop()
            do {
                try cleanupIsolatedState(at: state)
            } catch let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }

    static func cleanupIsolatedState(
        at url: URL,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        do {
            try remove(url)
        } catch {
            throw BenchmarkError.cannotRemoveState(error.localizedDescription)
        }
    }

    /// Stable synthetic corpus generator. It intentionally contains dense common-letter names, selective
    /// app names, multi-term documents and multiple extensions so every workload remains non-trivial.
    static func makeFixture(itemCount requested: Int, seed: UInt64 = fixtureSeed) -> Fixture {
        let itemCount = min(max(0, requested), SafetyLimits.maxIndexedItems.upperBound)
        let builder = IndexBuilder()
        let directoryCount = max(1, min(64, (itemCount + 9_999) / 10_000))
        builder.reserve(items: itemCount, dirs: directoryCount + 1)
        let root = builder.addRoot("/__jbar_benchmark_fixture_v\(fixtureGeneratorVersion)")
        let dirs = (0..<directoryCount).map { builder.addDir(parent: root, name: String(format: "bucket-%02d", $0)) }
        let stems = ["report", "chrome", "visual-studio-code", "xylophone", "index", "readme",
                     "package-swift", "terminal", "project", "invoice", "example", "archive"]
        let extensions = ["pdf", "swift", "md", "txt", "png", "json", "zip", "mov"]
        var rng = SplitMix(seed: seed)

        for i in 0..<itemCount {
            let stem = stems[Int(rng.next() % UInt64(stems.count))]
            let ext = extensions[Int(rng.next() % UInt64(extensions.count))]
            let suffix = String(i, radix: 36)
            let isApp = i % 997 == 0
            let name: String
            if isApp {
                name = i % 1_994 == 0 ? "Chrome Benchmark \(suffix)" : "Visual Studio Code \(suffix)"
            } else if i % 17 == 0 {
                name = "report \(suffix).pdf"
            } else if i % 29 == 0 {
                name = "package swift \(suffix).swift"
            } else {
                name = "\(stem)-\(suffix).\(ext)"
            }
            let actualExt = isApp ? "app" : TextAnalyzer.fileExtension(of: name)
            let kind: ItemKind = isApp ? .app : ItemKind.forExtension(actualExt ?? "")
            let flags: ItemFlags = isApp ? [.appBundle] : []
            builder.addItem(dir: dirs[i % dirs.count], name: name, analyzed: TextAnalyzer.analyze(name),
                            kind: kind, flags: flags, mtime: nil, depth: 2, ext: actualExt,
                            app: isApp ? AppInfo(bundleID: "benchmark.\(suffix)", displayName: name, aliases: []) : nil)
        }
        let store = builder.build(generation: 1, builtAt: Date(timeIntervalSinceReferenceDate: 0))
        return Fixture(store: store, fingerprint: storeFingerprint(store))
    }

    // MARK: - JBar workloads

    /// A production-shaped history that remains wholly in memory: `FrecencyStore.init` does no I/O,
    /// and this benchmark deliberately never calls `load()` or `save()` on the sentinel URL.
    static func makeDeterministicHistory(for index: IndexStore) -> HistoryFixture {
        let reference = Date(timeIntervalSince1970: benchmarkReferenceUnixSeconds)
        let history = FrecencyStore(
            fileURL: URL(fileURLWithPath: "/__jbar_benchmark_memory_only__/history.json"),
            halfLife: 7 * 86_400,
            maxEntries: benchmarkHistoryEntries
        )
        let target = min(benchmarkHistoryEntries, index.count)
        var operations = 0
        var profileHash = FNV64()
        profileHash.updateString("JBar.BenchmarkHistory.v1")
        if target > 0 {
            for slot in 0..<target {
                let item = target == 1 ? 0 : Int(Int64(slot) * Int64(index.count - 1) / Int64(target - 1))
                let path = index.path(of: item)
                guard SafetyLimits.isSafeAbsolutePath(path) else { continue }
                let name = index.name(of: item).lowercased()
                let query: String?
                if name.contains("chrome") { query = "chrome" }
                else if name.contains("visual studio") { query = "vsc" }
                else if name.contains("report") && name.contains("pdf") { query = "report pdf" }
                else if name.contains("package") && name.contains("swift") { query = "package swift" }
                else { query = nil }
                let repeats = 1 + slot % 3
                let ageDays = slot % 30
                for repeatIndex in 0..<repeats {
                    let timestamp = reference.addingTimeInterval(
                        -Double(ageDays) * 86_400 - Double(repeatIndex) * 3_600
                    )
                    profileHash.updateString(path)
                    profileHash.updateOptionalString(repeatIndex == repeats - 1 ? query : nil)
                    profileHash.updateInteger(timestamp.timeIntervalSince1970.bitPattern)
                    history.record(open: path, query: repeatIndex == repeats - 1 ? query : nil,
                                   at: timestamp)
                    operations += 1
                }
            }
        }
        let profile = HistoryProfile(
            profileVersion: 1,
            mode: "deterministic-in-memory-production-stage-2",
            persistence: "none (FrecencyStore load/save never called; sentinel URL is never touched)",
            maxEntries: benchmarkHistoryEntries,
            seededEntries: history.count,
            recordOperations: operations,
            queryPicks: history.queryPickCount,
            halfLifeSeconds: history.halfLife,
            referenceUnixSeconds: benchmarkReferenceUnixSeconds,
            selection: "up to 500 evenly spaced corpus rows; 1...3 opens; ages 0...29 days; matching chrome/vsc/report-pdf/package-swift query picks",
            profileFingerprint: fingerprintHex(profileHash.value)
        )
        return HistoryFixture(store: history, profile: profile)
    }

    static func measureQueries(_ cases: [QueryCase], engine: SearchEngine, store: IndexStore,
                               cfg: Config, samples: Int, warmCache: Bool) async throws -> [QueryMeasurement] {
        guard (1...SafetyLimits.maxBenchmarkIterations).contains(samples) else {
            throw BenchmarkError.invalidMeasurement("query sample count \(samples) is outside the safe range")
        }
        var output: [QueryMeasurement] = []
        output.reserveCapacity(cases.count)
        for query in cases {
            await engine.update(store: store)
            var validator = responseValidator(
                context: "\(warmCache ? "cache-warm" : "cache-cold") query '\(query.text)'",
                query: query.text, store: store, rowCap: cfg.maxResults
            )
            if warmCache {
                let warmup = await engine.search(query.text, limit: cfg.maxResults,
                                                 appsFirstCap: cfg.appsFirstCap,
                                                 now: benchmarkReferenceDate)
                _ = try validator.accept(warmup, latencyMilliseconds: 0)
            }
            var recorded: [ResponseSample] = []
            recorded.reserveCapacity(samples)
            var top = "(none)"
            for sample in 0..<samples {
                if !warmCache { await engine.update(store: store) }
                let start = monotonicNow()
                let response = await engine.search(query.text, limit: cfg.maxResults,
                                                   appsFirstCap: cfg.appsFirstCap,
                                                   now: benchmarkReferenceDate)
                let measured = try validator.accept(response, latencyMilliseconds: elapsedMS(since: start))
                recorded.append(measured)
                if sample == 0 {
                    top = response.rows.first.map { "\($0.name) [\(kindTag($0.kind))]" } ?? "(none)"
                }
            }
            guard let validatedRows = validator.expectedRows else {
                throw BenchmarkError.invalidMeasurement("query '\(query.text)' produced no validated samples")
            }
            output.append(QueryMeasurement(query: query, samples: recorded, topResult: top,
                                           validatedRows: validatedRows))
        }
        return output
    }

    static func measureSequences(_ sequences: [SequenceCase], deletion: Bool, engine: SearchEngine,
                                 store: IndexStore, cfg: Config,
                                 repetitions: Int) async throws -> [SequenceMeasurement] {
        guard (1...100).contains(repetitions) else {
            throw BenchmarkError.invalidMeasurement("sequence repetition count \(repetitions) is outside 1...100")
        }
        var output: [SequenceMeasurement] = []
        output.reserveCapacity(sequences.count)
        for sequence in sequences {
            var buckets = [[ResponseSample]](repeating: [], count: sequence.steps.count)
            var validators = sequence.steps.map {
                responseValidator(
                    context: "\(deletion ? "deletion" : "serial-typing") sequence '\(sequence.name)' step '\($0)'",
                    query: $0, store: store, rowCap: cfg.maxResults
                )
            }
            for _ in 0..<repetitions {
                await engine.update(store: store)
                if deletion {
                    let seed = sequence.name.hasPrefix("multi") ? "report pdf" : "report"
                    let seeded = await engine.search(seed, limit: cfg.maxResults,
                                                     appsFirstCap: cfg.appsFirstCap,
                                                     now: benchmarkReferenceDate)
                    var seedValidator = responseValidator(
                        context: "deletion sequence '\(sequence.name)' unmeasured seed",
                        query: seed, store: store, rowCap: cfg.maxResults
                    )
                    _ = try seedValidator.accept(seeded, latencyMilliseconds: 0)
                }
                for (index, step) in sequence.steps.enumerated() {
                    let start = monotonicNow()
                    let response = await engine.search(step, limit: cfg.maxResults,
                                                       appsFirstCap: cfg.appsFirstCap,
                                                       now: benchmarkReferenceDate)
                    let sample = try validators[index].accept(
                        response, latencyMilliseconds: elapsedMS(since: start)
                    )
                    buckets[index].append(sample)
                }
            }
            var measuredSteps: [SequenceStepMeasurement] = []
            measuredSteps.reserveCapacity(sequence.steps.count)
            for (index, query) in sequence.steps.enumerated() {
                guard let validatedRows = validators[index].expectedRows else {
                    throw BenchmarkError.invalidMeasurement(
                        "sequence '\(sequence.name)' step '\(query)' produced no validated samples"
                    )
                }
                measuredSteps.append(SequenceStepMeasurement(
                    query: query, samples: buckets[index], validatedRows: validatedRows
                ))
            }
            output.append(SequenceMeasurement(name: sequence.name, steps: measuredSteps))
        }
        return output
    }

    static func measureSupersession(engine: SearchEngine, store: IndexStore, cfg: Config,
                                    repetitions: Int) async throws -> SupersessionMeasurement {
        guard (1...100).contains(repetitions) else {
            throw BenchmarkError.invalidMeasurement("supersession repetition count \(repetitions) is outside 1...100")
        }
        var samples: [SupersessionSample] = []
        samples.reserveCapacity(repetitions)
        var newestValidator = responseValidator(context: "supersession newest query 'chrome'",
                                                query: "chrome", store: store,
                                                rowCap: cfg.maxResults)
        var olderCompletedValidator = responseValidator(
            context: "supersession completed older query 'x'", query: "x",
            store: store, rowCap: cfg.maxResults
        )
        for _ in 0..<repetitions {
            await engine.update(store: store)
            let pairStart = monotonicNow()
            let requestBeforeOlder = await engine.latestRequestId
            let older = Task {
                await engine.search("x", limit: cfg.maxResults, appsFirstCap: cfg.appsFirstCap,
                                    now: benchmarkReferenceDate)
            }
            // `Task.yield()` alone does not guarantee submission order. Wait until the actor has assigned
            // the older request id (and yielded to its worker) before submitting the newer request; otherwise
            // the nominally "older" Task can enter second and cancel the very request it was meant to lose to.
            while await engine.latestRequestId == requestBeforeOlder { await Task.yield() }
            let newestStart = monotonicNow()
            let newest = Task {
                await engine.search("chrome", limit: cfg.maxResults, appsFirstCap: cfg.appsFirstCap,
                                    now: benchmarkReferenceDate)
            }
            let newestResponse = await newest.value
            let newestSample = try newestValidator.accept(
                newestResponse, latencyMilliseconds: elapsedMS(since: newestStart)
            )
            let olderResponse = await older.value
            let pairLatency = elapsedMS(since: pairStart)
            if olderResponse.cancelled {
                try validateCancelledOlderSupersession(olderResponse, store: store)
            } else {
                _ = try olderCompletedValidator.accept(olderResponse, latencyMilliseconds: pairLatency)
            }
            samples.append(SupersessionSample(newest: newestSample,
                                              pairCompletionLatencyMilliseconds: pairLatency,
                                              olderCancelled: olderResponse.cancelled))
        }
        guard let newestRows = newestValidator.expectedRows else {
            throw BenchmarkError.invalidMeasurement("supersession newest query produced no validated samples")
        }
        let completedOlderResult: ExactResultEvidence?
        switch (olderCompletedValidator.expectedRows,
                olderCompletedValidator.expectedTotalMatches) {
        case (nil, nil):
            completedOlderResult = nil
        case (.some(let rows), .some(let total)):
            completedOlderResult = ExactResultEvidence(totalMatches: total, rows: rows)
        default:
            throw BenchmarkError.invalidMeasurement(
                "supersession completed-older validator retained partial evidence"
            )
        }
        return SupersessionMeasurement(olderQuery: "x", newestQuery: "chrome", samples: samples,
                                       newestValidatedRows: newestRows,
                                       completedOlderResult: completedOlderResult)
    }

    private static func responseValidator(context: String, query: String, store: IndexStore,
                                          rowCap: Int) -> ResponseValidationState {
        let parsed = QueryParser.parse(query, home: NSHomeDirectory())
        return ResponseValidationState(context: context, expectedQuery: parsed.raw,
                                       expectedMode: parsed.mode,
                                       expectedGeneration: store.generation,
                                       rowCap: min(max(0, rowCap), SafetyLimits.maxResults.upperBound),
                                       totalUpperBound: store.count)
    }

    static func validateCancelledOlderSupersession(_ response: SearchResponse,
                                                    store: IndexStore) throws {
        let parsed = QueryParser.parse("x", home: NSHomeDirectory())
        guard response.cancelled, response.query == parsed.raw, response.mode == parsed.mode,
              response.generation == store.generation, response.rows.isEmpty,
              response.totalMatches == 0, !response.totalMatchesIsComplete else {
            throw BenchmarkError.invalidMeasurement(
                "cancelled older supersession response violated query/mode/generation/empty-result invariants"
            )
        }
    }

    static func validateCrossWorkloadParity(
        cold: [QueryMeasurement], warm: [QueryMeasurement],
        sequences: [SequenceMeasurement], supersession: SupersessionMeasurement? = nil
    ) throws {
        struct ExactOutput: Equatable {
            let rows: [ResultRow]
            let total: Int
        }
        var firstOutputByQuery: [String: ExactOutput] = [:]
        func register(query: String, rows: [ResultRow], total: Int,
                      context: String) throws {
            let output = ExactOutput(rows: rows, total: total)
            if let first = firstOutputByQuery[query] {
                guard output == first else {
                    throw BenchmarkError.invalidMeasurement(
                        "\(context) query '\(query)' differs from the first exact rows/total observed for that query"
                    )
                }
            } else {
                firstOutputByQuery[query] = output
            }
        }
        var coldByQuery: [String: QueryMeasurement] = [:]
        coldByQuery.reserveCapacity(cold.count)
        for measurement in cold {
            guard coldByQuery.updateValue(measurement, forKey: measurement.query.text) == nil else {
                throw BenchmarkError.invalidMeasurement("cache-cold workload contains duplicate queries")
            }
            try register(query: measurement.query.text, rows: measurement.validatedRows,
                         total: measurement.matches, context: "cache-cold")
        }
        guard warm.count == cold.count else {
            throw BenchmarkError.invalidMeasurement("cache-cold/cache-warm query counts differ")
        }
        var warmQueries: Set<String> = []
        for measurement in warm {
            guard coldByQuery[measurement.query.text] != nil else {
                throw BenchmarkError.invalidMeasurement(
                    "cache-warm query '\(measurement.query.text)' has no cache-cold reference"
                )
            }
            guard warmQueries.insert(measurement.query.text).inserted else {
                throw BenchmarkError.invalidMeasurement("cache-warm workload contains duplicate queries")
            }
            try register(query: measurement.query.text, rows: measurement.validatedRows,
                         total: measurement.matches, context: "cache-warm")
        }
        guard warmQueries == Set(coldByQuery.keys) else {
            throw BenchmarkError.invalidMeasurement("cache-cold/cache-warm query sets differ")
        }
        for sequence in sequences {
            for step in sequence.steps {
                guard let total = step.samples.first?.correctness.totalMatches else {
                    throw BenchmarkError.invalidMeasurement(
                        "sequence '\(sequence.name)' query '\(step.query)' has no correctness sample"
                    )
                }
                try register(query: step.query, rows: step.validatedRows, total: total,
                             context: "sequence '\(sequence.name)'")
            }
        }
        if let supersession {
            guard coldByQuery[supersession.newestQuery] != nil,
                  let total = supersession.samples.first?.newest.correctness.totalMatches else {
                throw BenchmarkError.invalidMeasurement(
                    "supersession newest query has no cache-cold reference"
                )
            }
            try register(query: supersession.newestQuery,
                         rows: supersession.newestValidatedRows, total: total,
                         context: "supersession newest")

            let completedOlderCount = supersession.samples.lazy
                .filter { !$0.olderCancelled }.count
            if completedOlderCount == 0 {
                guard supersession.completedOlderResult == nil else {
                    throw BenchmarkError.invalidMeasurement(
                        "supersession retained completed-older evidence without a completed older sample"
                    )
                }
            } else {
                guard coldByQuery[supersession.olderQuery] != nil,
                      let older = supersession.completedOlderResult else {
                    throw BenchmarkError.invalidMeasurement(
                        "completed supersession older query has no exact cache-cold evidence"
                    )
                }
                try register(query: supersession.olderQuery, rows: older.rows,
                             total: older.totalMatches,
                             context: "supersession completed older")
            }
        }
    }

    // MARK: - Spotlight reference and coverage

    private static func printSpotlightReference(scope: ScopePlan, samples: Int) async {
        print("\n-- Spotlight same-root reference (n=\(samples) independent gathers per non-empty query) --")
        print("scope: \(scope.spotlightScopes.count) existing minimal roots derived from JBar's crawl/app roots")
        if !scope.missingScopes.isEmpty { print("missing configured scopes skipped by both practical measurements: \(scope.missingScopes.count)") }
        print("semantics: Spotlight ANDs case/diacritic-insensitive filename substrings; JBar uses fuzzy terms, aliases, pinyin, exclusions, depth and ranking")
        print("comparison: \(crossToolComparisonPolicy)")

        guard !scope.spotlightScopes.isEmpty else {
            print("Spotlight unavailable: no configured scope exists")
            return
        }
        print("resource bound: every Spotlight gather is capped at \(maxSpotlightMembershipResults) results; a capped count is partial")
        print(padR("query", 18) + padL("p50", 11) + padL("p95", 11) + padL("p99", 11)
              + padL("max", 11) + padL("results", 12) + padL("timeouts", 10))

        for query in queryCases where !query.text.isEmpty {
            let terms = spotlightTerms(query.text)
            var times: [Double] = []
            var counts: [Int] = []
            var timeouts = 0
            var anyResultCap = false
            for _ in 0..<samples {
                let result = await runMetadataQuery(MetadataSpec(predicate: .tokens(terms), scopes: scope.spotlightScopes,
                                                                 timeout: 3, targetPath: nil))
                if result.timedOut || !result.started { timeouts += 1 }
                else {
                    times.append(result.elapsedMS)
                    counts.append(result.count)
                    anyResultCap = anyResultCap || result.resultLimitReached
                }
            }
            guard let stats = distribution(times) else {
                print(padR(displayQuery(query.text), 18) + padL("—", 44) + padL("partial", 12) + padL("\(timeouts)", 10))
                continue
            }
            let countLabel: String
            if anyResultCap {
                countLabel = "≥\(maxSpotlightMembershipResults)"
            } else if let low = counts.min(), let high = counts.max() {
                countLabel = low == high ? "\(low)" : "\(low)...\(high)"
            } else { countLabel = "—" }
            print(padR(displayQuery(query.text), 18) + padL(ms(stats.p50), 11) + padL(ms(stats.p95), 11)
                  + padL(ms(stats.p99), 11) + padL(ms(stats.maximum), 11)
                  + padL(countLabel, 12) + padL("\(timeouts)", 10))
        }
    }

    private static func printCoverage(engine: SearchEngine, store: IndexStore, cfg: Config,
                                      scope: ScopePlan) async {
        print("\n-- Source-biased coverage probe (deterministic seed=0x\(String(coverageSeed, radix: 16))) --")
        print("sample source: JBar's real index; therefore this is not an estimate of files JBar failed to index")
        let target = 24
        let topK = min(50, SafetyLimits.maxResults.upperBound)
        var rng = SplitMix(seed: coverageSeed)
        var picks: [(name: String, path: String)] = []
        var seen = Set<String>()
        var tries = 0
        let maxTries = min(20_000, max(1_000, store.count * 2))
        while picks.count < target && tries < maxTries && store.count > 0 {
            tries += 1
            let index = Int(rng.next() % UInt64(store.count))
            if store.itemKind(index) == .app { continue }
            let name = store.name(of: index)
            let path = store.path(of: index)
            guard name.count >= 3, !SafetyLimits.hasDotPrefix(name),
                  scope.containsForSpotlight(path), seen.insert(path).inserted else { continue }
            picks.append((name, path))
        }

        var jbarHits = 0
        var spotlightHits = 0
        var spotlightMisses = 0
        var spotlightTimeouts = 0
        for pick in picks {
            await engine.update(store: store)
            let response = await engine.search(pick.name, limit: topK, appsFirstCap: cfg.appsFirstCap)
            if response.rows.contains(where: { $0.path == pick.path }) { jbarHits += 1 }
            let result = await runMetadataQuery(MetadataSpec(predicate: .exactName(pick.name), scopes: scope.spotlightScopes,
                                                             timeout: 3, targetPath: pick.path))
            if result.targetFound { spotlightHits += 1 }
            else if result.timedOut || !result.started || !result.targetLookupComplete { spotlightTimeouts += 1 }
            else { spotlightMisses += 1 }
        }
        print("sample=\(picks.count), JBar exact path in top-\(topK)=\(jbarHits)")
        print("Spotlight exact filename/path: found=\(spotlightHits), not-found=\(spotlightMisses), timeout/unknown=\(spotlightTimeouts)")
        print("interpretation: ranking misses, metadata misses and timeout/unknown are kept separate; no cross-tool percentage or speed ratio is inferred")
    }

    private enum MetadataPredicate: Sendable {
        case tokens([String])
        case exactName(String)
    }

    private struct MetadataSpec: Sendable {
        let predicate: MetadataPredicate
        let scopes: [String]
        let timeout: TimeInterval
        /// Coverage probes need only target membership. Never retain every path from a potentially
        /// huge set of same-name metadata results.
        let targetPath: String?
    }

    private struct MetadataResult: Sendable {
        var elapsedMS: Double = 0
        var count: Int = 0
        var targetFound = false
        var targetLookupComplete = true
        var timedOut: Bool = false
        var started: Bool = false
        var resultLimitReached: Bool = false
    }

    /// Core Services exposes the result ceiling that `NSMetadataQuery` does not. Keep the complete
    /// query lifecycle on the main run loop, cap results before execution, and export only value types.
    @MainActor
    private final class MetadataQuerySession {
        private static let didFinishCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            // The callback is delivered on the run loop that executes the query (main). Bridge the
            // opaque address through a Sendable integer before reasserting that actor isolation;
            // capturing UnsafeRawPointer directly is rejected by complete Swift 6 concurrency.
            let observerAddress = UInt(bitPattern: observer)
            MainActor.assumeIsolated {
                guard let pointer = UnsafeRawPointer(bitPattern: observerAddress) else { return }
                Unmanaged<MetadataQuerySession>.fromOpaque(pointer).takeUnretainedValue().finish()
            }
        }

        let spec: MetadataSpec
        private var query: MDQuery?
        private var didFinish = false
        private var capturedCount = 0
        private var targetFound = false
        private var targetLookupComplete = true
        private var resultLimitReached = false

        init(spec: MetadataSpec) { self.spec = spec }

        func run() -> MetadataResult {
            let expression: String
            switch spec.predicate {
            case .tokens(let terms): expression = Benchmark.spotlightQueryExpression(forTerms: terms)
            case .exactName(let name): expression = Benchmark.spotlightExactNameExpression(name)
            }
            guard let query = MDQueryCreate(nil, expression as CFString, nil, nil) else {
                return MetadataResult(started: false)
            }
            self.query = query
            MDQuerySetSearchScope(query, spec.scopes as CFArray, 0)
            MDQuerySetMaxCount(query, maxSpotlightMembershipResults)
            let center = CFNotificationCenterGetLocalCenter()
            let observer = Unmanaged.passUnretained(self).toOpaque()
            let queryObject = Unmanaged.passUnretained(query).toOpaque()
            CFNotificationCenterAddObserver(center, observer, Self.didFinishCallback,
                                            kMDQueryDidFinishNotification, queryObject, .deliverImmediately)
            defer {
                CFNotificationCenterRemoveEveryObserver(center, observer)
                MDQueryStop(query)
                self.query = nil
            }

            let start = monotonicNow()
            guard MDQueryExecute(query, 0) else {
                return MetadataResult(elapsedMS: elapsedMS(since: start), count: 0,
                                      timedOut: false, started: false)
            }
            let safeTimeout = spec.timeout.isFinite ? min(max(0, spec.timeout), 30) : 0
            let timeoutNanos = UInt64(safeTimeout * 1_000_000_000)
            let (candidateDeadline, overflow) = start.addingReportingOverflow(timeoutNanos)
            let deadline = overflow ? UInt64.max : candidateDeadline
            while !didFinish {
                let now = monotonicNow()
                if now >= deadline { break }
                let slice = min(0.05, Double(deadline - now) / 1_000_000_000)
                _ = RunLoop.current.run(mode: .default,
                                        before: Date(timeIntervalSinceNow: max(0.001, slice)))
            }
            let timedOut = !didFinish
            if timedOut { MDQueryStop(query) }
            capture(query)
            return MetadataResult(elapsedMS: elapsedMS(since: start), count: capturedCount,
                                  targetFound: targetFound, targetLookupComplete: targetLookupComplete,
                                  timedOut: timedOut, started: true,
                                  resultLimitReached: resultLimitReached)
        }

        private func finish() {
            didFinish = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        private func capture(_ query: MDQuery) {
            capturedCount = max(0, MDQueryGetResultCount(query))
            resultLimitReached = capturedCount >= maxSpotlightMembershipResults
            guard let targetPath = spec.targetPath else { return }
            let membership = Benchmark.boundedTargetMembership(resultCount: capturedCount,
                                                                targetPath: targetPath) { index in
                guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                return MDItemCopyAttribute(item, kMDItemPath) as? String
            }
            targetFound = membership.found
            targetLookupComplete = membership.complete && !resultLimitReached
        }
    }

    @MainActor
    private static func runMetadataQuery(_ spec: MetadataSpec) -> MetadataResult {
        MetadataQuerySession(spec: spec).run()
    }

    struct TargetMembership: Equatable, Sendable {
        let found: Bool
        let complete: Bool
        let inspected: Int
    }

    /// Perform a bounded, allocation-free membership check over metadata results. A miss is only
    /// authoritative when the complete result set fit inside the inspection budget; otherwise the
    /// benchmark reports the coverage result as unknown.
    static func boundedTargetMembership(resultCount: Int, targetPath: String,
                                        maxResults: Int = maxSpotlightMembershipResults,
                                        pathAt: (Int) -> String?) -> TargetMembership {
        let count = max(0, resultCount)
        let inspected = min(count, max(0, maxResults))
        for index in 0..<inspected where pathAt(index) == targetPath {
            return TargetMembership(found: true, complete: true, inspected: index + 1)
        }
        return TargetMembership(found: false, complete: inspected == count, inspected: inspected)
    }

    private static func escapedMetadataLiteral(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0...0x1F, 0x22, 0x27, 0x2A, 0x3F, 0x5C:
                output.append("\\")
            default:
                break
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    static func spotlightQueryExpression(forTerms terms: [String]) -> String {
        guard !terms.isEmpty else { return "kMDItemFSName == \"\"" }
        return terms.map {
            "kMDItemFSName == \"*\(escapedMetadataLiteral($0))*\"cd"
        }.joined(separator: " && ")
    }

    static func spotlightExactNameExpression(_ name: String) -> String {
        "kMDItemFSName == \"\(escapedMetadataLiteral(name))\"cd"
    }

    // MARK: - Reporting and deterministic helpers

    private static func printEnvironment(plan: SamplePlan) {
        let environment = environmentIdentity()
        let translated = environment.rosettaTranslated ? " (Rosetta translated)" : ""
        print("JBar: \(environment.jbarVersion) · build=\(environment.buildMode)")
        print("machine: \(environment.hardwareModel) · process architecture=\(environment.processArchitecture)\(translated)")
        print(String(format: "OS: %@ · active cores=%d · physical memory=%.1f GiB",
                     environment.operatingSystemVersion, environment.activeProcessorCount,
                     Double(environment.physicalMemoryBytes) / 1_073_741_824))
        print("workload: v\(workloadVersion) · correctness: every measured response must be complete, non-cancelled, and stable")
        print("samples: requested=\(plan.requested), warm=\(plan.warm), full-scan=\(plan.fullScan), sequence=\(plan.sequence), supersession=\(plan.supersession), Spotlight=\(plan.spotlight)")
    }

    private static func printHistory(_ profile: HistoryProfile) {
        print("history: \(profile.mode); entries=\(profile.seededEntries)/\(profile.maxEntries), records=\(profile.recordOperations), query-picks=\(profile.queryPicks), half-life=\(Int(profile.halfLifeSeconds / 86_400))d, fingerprint=\(profile.profileFingerprint)")
        print("history persistence: \(profile.persistence)")
    }

    private static func printCorpus(_ corpus: Corpus, rssBefore: UInt64?, rssAfter: UInt64?) {
        print("\ncorpus: \(corpus.description)")
        print(String(format: "build: %.3f s · items=%d · apps=%d · dirs=%d",
                     corpus.buildSeconds, corpus.store.count, corpus.store.appItems.count, corpus.store.dirs.count))
        if let status = corpus.status {
            print("crawl status: denied paths=\(status.deniedPaths.count), unsafe entries skipped=\(status.unsafeEntriesSkipped), capped dirs=\(status.cappedDirs.count), hit item cap=\(status.hitItemCap)")
        }
        if let scope = corpus.scope {
            print("JBar scope: files=\(scope.fileRoots.count), app roots=\(scope.appRoots.count), extra bundles=\(scope.extraBundles.count); Spotlight reference minimal existing scopes=\(scope.spotlightScopes.count)")
            for root in scope.spotlightScopes { print("  scope: \(abbreviate(root))") }
        }
        print(String(format: "tracked IndexStore payload lower bound: %.1f MiB (array elements/arenas only; excludes Swift container/dictionary overhead)",
                     mib(trackedPayloadBytes(corpus.store))))
        if let before = rssBefore, let after = rssAfter {
            let delta = after >= before ? after - before : 0
            print(String(format: "process RSS: baseline %.1f MiB · post-build %.1f MiB · delta %.1f MiB",
                         mib(before), mib(after), mib(delta)))
            print("RSS note: process-wide allocator/runtime/crawl retention is included; this is not per-index memory and excludes Spotlight/system services")
        } else {
            print("process RSS: unavailable")
        }
    }

    private static func printMeasurements(_ measurements: [QueryMeasurement]) {
        print(padR("query/category", 30) + padL("matches", 10) + padL("p50", 11) + padL("p95", 11)
              + padL("p99", 11) + padL("max", 11) + "   fingerprint / top JBar result")
        for measurement in measurements {
            let label = "\(displayQuery(measurement.query.text)) [\(measurement.query.category.rawValue)]"
            print(padR(label, 30) + padL("\(measurement.matches)", 10)
                  + padL(ms(measurement.stats.p50), 11) + padL(ms(measurement.stats.p95), 11)
                  + padL(ms(measurement.stats.p99), 11) + padL(ms(measurement.stats.maximum), 11)
                  + "   " + measurement.fingerprint + " / " + truncated(measurement.topResult, to: 60))
        }
    }

    private static func printSequences(_ measurements: [SequenceMeasurement]) {
        print(padR("sequence", 24) + padR("step", 18) + padL("p50", 11) + padL("p95", 11)
              + padL("p99", 11) + padL("max", 11) + "   fingerprint")
        for sequence in measurements {
            for (index, step) in sequence.steps.enumerated() {
                let stats = step.stats
                print(padR(index == 0 ? sequence.name : "", 24) + padR(displayQuery(step.query), 18)
                      + padL(ms(stats.p50), 11) + padL(ms(stats.p95), 11)
                      + padL(ms(stats.p99), 11) + padL(ms(stats.maximum), 11)
                      + "   " + step.samples[0].correctness.resultFingerprint)
            }
        }
    }

    private static func format(_ stats: Distribution) -> String {
        "n=\(stats.count), p50=\(ms(stats.p50)), p95=\(ms(stats.p95)), p99=\(ms(stats.p99)), max=\(ms(stats.maximum))"
    }

    // MARK: - Machine-readable evidence

    static func environmentIdentity() -> EnvironmentIdentity {
        let process = ProcessInfo.processInfo
        return EnvironmentIdentity(
            jbarVersion: Runtime.version,
            buildMode: buildMode,
            hardwareModel: sysctl("hw.model"),
            cpuBrand: sysctl("machdep.cpu.brand_string"),
            processArchitecture: processArchitecture,
            rosettaTranslated: isRunningUnderRosetta,
            operatingSystemVersion: process.operatingSystemVersionString,
            activeProcessorCount: process.activeProcessorCount,
            physicalMemoryBytes: process.physicalMemory,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    static func workloadIdentity(plan: SamplePlan) -> WorkloadIdentity {
        WorkloadIdentity(
            version: workloadVersion,
            samplePlan: plan,
            queries: queryCases,
            serialTypingSequences: typingSequences,
            deletionSequences: deletionSequences,
            supersessionOlderQuery: "x",
            supersessionNewestQuery: "chrome",
            clock: "DispatchTime.now().uptimeNanoseconds; caller-observed wall latency in milliseconds",
            percentileMethod: "nearest-rank p50/p95/p99/max; no best-of-N",
            correctnessPolicy: "each measured normal, sequence, newest-supersession, and completed older-supersession response is non-cancelled with an exact bounded total; every repeated query across all workloads directly equals its first ordered result rows plus total; fingerprints are report identity only"
        )
    }

    static func configIdentity(_ config: Config, source: String) -> ConfigIdentity {
        let weights = RankingWeights.default
        return ConfigIdentity(
            source: source,
            maxResults: config.maxResults,
            appsFirstCap: config.appsFirstCap,
            searchReferenceUnixSeconds: benchmarkReferenceUnixSeconds,
            rankingIntegerWeights: [
                "depthCap": weights.depthCap,
                "depthFree": weights.depthFree,
                "depthPerLevel": weights.depthPerLevel,
                "dotName": weights.dotName,
                "extMatch": weights.extMatch,
                "frecencyCap": weights.frecencyCap,
                "initialsExact": weights.initialsExact,
                "initialsPrefix": weights.initialsPrefix,
                "junk": weights.junk,
                "pinyinInitialsExact": weights.pinyinInitialsExact,
                "queryPick": weights.queryPick,
                "recency1d": weights.recency1d,
                "recency7d": weights.recency7d,
                "recency30d": weights.recency30d,
                "recency180d": weights.recency180d,
                "typeApp": weights.typeApp,
                "typeCode": weights.typeCode,
                "typeDocument": weights.typeDocument,
                "typeFolder": weights.typeFolder,
                "typeHiddenOrPackageInternal": weights.typeHiddenOrPackageInternal,
                "typeMedia": weights.typeMedia,
                "wholePrefix": weights.wholePrefix,
                "wholeToken": weights.wholeToken,
            ],
            frecencyScale: weights.frecencyScale
        )
    }

    private static func corpusIdentity(_ corpus: Corpus) -> CorpusIdentity {
        let fixture = corpus.kind == .fixture
        return CorpusIdentity(
            kind: fixture ? "deterministic-fixture" : "isolated-real-crawl",
            description: corpus.description,
            fingerprint: fingerprintHex(corpus.fingerprint),
            fixtureGeneratorVersion: fixture ? fixtureGeneratorVersion : nil,
            fixtureSeed: fixture ? fingerprintHex(fixtureSeed) : nil,
            itemCount: corpus.store.count,
            appCount: corpus.store.appItems.count,
            directoryCount: corpus.store.dirs.count,
            generation: corpus.store.generation,
            builtAtUnixSeconds: corpus.store.builtAt.timeIntervalSince1970,
            buildSeconds: corpus.buildSeconds
        )
    }

    private static func makeMachineReport(plan: SamplePlan, config: Config,
                                          configDescription: String, corpus: Corpus,
                                          history: HistoryProfile,
                                          cold: [QueryMeasurement], warm: [QueryMeasurement],
                                          typing: [SequenceMeasurement], deletion: [SequenceMeasurement],
                                          supersession: SupersessionMeasurement) -> MachineReport {
        MachineReport(
            schemaVersion: reportSchemaVersion,
            generatedAtUnixSeconds: Date().timeIntervalSince1970,
            environment: environmentIdentity(),
            workload: workloadIdentity(plan: plan),
            config: configIdentity(config, source: configDescription),
            history: history,
            corpus: corpusIdentity(corpus),
            measurements: MeasurementReport(cacheCold: cold, cacheWarm: warm,
                                            serialTyping: typing, deletion: deletion,
                                            supersession: supersession)
        )
    }

    static func encodedMachineReport(_ report: MachineReport) throws -> Data {
        try validateMachineReportStrings(report)
        let estimatedUpperBound = estimatedMachineReportJSONUpperBound(report)
        guard estimatedUpperBound <= maxReportBytes else {
            throw BenchmarkError.invalidReport(
                "estimated JSON upper bound \(estimatedUpperBound) exceeds the \(maxReportBytes)-byte limit"
            )
        }
        try validateMachineReport(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        guard data.count <= maxReportBytes else {
            throw BenchmarkError.invalidReport(
                "encoded size \(data.count) exceeds the \(maxReportBytes)-byte limit"
            )
        }
        return data
    }

    static func decodeMachineReport(_ data: Data) throws -> MachineReport {
        guard data.count <= maxReportBytes else {
            throw BenchmarkError.invalidReport(
                "input size \(data.count) exceeds the \(maxReportBytes)-byte limit"
            )
        }
        let report: MachineReport
        do {
            report = try JSONDecoder().decode(MachineReport.self, from: data)
        } catch {
            throw BenchmarkError.invalidReport("JSON decode failed: \(error.localizedDescription)")
        }
        try validateMachineReport(report)
        return report
    }

    private static func forEachReportString(
        _ report: MachineReport,
        _ visit: (_ value: String, _ field: String, _ maxUTF8Bytes: Int,
                  _ allowsEmpty: Bool) throws -> Void
    ) rethrows {
        func metadata(_ value: String, _ field: String) throws {
            try visit(value, field, SafetyLimits.maxPathUTF8Bytes, false)
        }
        func name(_ value: String, _ field: String) throws {
            try visit(value, field, SafetyLimits.maxNameUTF8Bytes, false)
        }
        func query(_ value: String, _ field: String) throws {
            try visit(value, field, SafetyLimits.maxQueryUTF8Bytes, true)
        }
        func fingerprint(_ value: String, _ field: String) throws {
            try visit(value, field, SafetyLimits.maxNameUTF8Bytes, false)
        }
        func row(_ value: ResultRow, _ field: String) throws {
            try name(value.name, "\(field).name")
            try visit(value.path, "\(field).path", SafetyLimits.maxPathUTF8Bytes, false)
            try visit(value.parentDisplay, "\(field).parentDisplay",
                      SafetyLimits.maxPathUTF8Bytes, false)
        }
        func samples(_ values: [ResponseSample], _ field: String) throws {
            for (index, sample) in values.enumerated() {
                try fingerprint(sample.correctness.resultFingerprint,
                                "\(field)[\(index)].correctness.resultFingerprint")
            }
        }
        func rows(_ values: [ResultRow], _ field: String) throws {
            for (index, value) in values.enumerated() { try row(value, "\(field)[\(index)]") }
        }

        try metadata(report.environment.jbarVersion, "environment.jbarVersion")
        try metadata(report.environment.buildMode, "environment.buildMode")
        try metadata(report.environment.hardwareModel, "environment.hardwareModel")
        try metadata(report.environment.cpuBrand, "environment.cpuBrand")
        try metadata(report.environment.processArchitecture, "environment.processArchitecture")
        try metadata(report.environment.operatingSystemVersion,
                     "environment.operatingSystemVersion")
        try metadata(report.environment.localeIdentifier, "environment.localeIdentifier")
        try metadata(report.environment.timeZoneIdentifier, "environment.timeZoneIdentifier")

        for (index, value) in report.workload.queries.enumerated() {
            try query(value.text, "workload.queries[\(index)].text")
            try name(value.category.rawValue, "workload.queries[\(index)].category")
        }
        for (index, sequence) in report.workload.serialTypingSequences.enumerated() {
            try name(sequence.name, "workload.serialTypingSequences[\(index)].name")
            for (step, value) in sequence.steps.enumerated() {
                try query(value, "workload.serialTypingSequences[\(index)].steps[\(step)]")
            }
        }
        for (index, sequence) in report.workload.deletionSequences.enumerated() {
            try name(sequence.name, "workload.deletionSequences[\(index)].name")
            for (step, value) in sequence.steps.enumerated() {
                try query(value, "workload.deletionSequences[\(index)].steps[\(step)]")
            }
        }
        try query(report.workload.supersessionOlderQuery,
                  "workload.supersessionOlderQuery")
        try query(report.workload.supersessionNewestQuery,
                  "workload.supersessionNewestQuery")
        try metadata(report.workload.clock, "workload.clock")
        try metadata(report.workload.percentileMethod, "workload.percentileMethod")
        try metadata(report.workload.correctnessPolicy, "workload.correctnessPolicy")

        try metadata(report.config.source, "config.source")
        for key in report.config.rankingIntegerWeights.keys {
            try name(key, "config.rankingIntegerWeights key")
        }

        try metadata(report.history.mode, "history.mode")
        try metadata(report.history.persistence, "history.persistence")
        try metadata(report.history.selection, "history.selection")
        try fingerprint(report.history.profileFingerprint, "history.profileFingerprint")

        try metadata(report.corpus.kind, "corpus.kind")
        try metadata(report.corpus.description, "corpus.description")
        try fingerprint(report.corpus.fingerprint, "corpus.fingerprint")
        if let seed = report.corpus.fixtureSeed {
            try fingerprint(seed, "corpus.fixtureSeed")
        }

        for (index, measurement) in report.measurements.cacheCold.enumerated() {
            try query(measurement.query.text, "measurements.cacheCold[\(index)].query.text")
            try name(measurement.query.category.rawValue,
                     "measurements.cacheCold[\(index)].query.category")
            try metadata(measurement.topResult, "measurements.cacheCold[\(index)].topResult")
            try samples(measurement.samples, "measurements.cacheCold[\(index)].samples")
            try rows(measurement.validatedRows,
                     "measurements.cacheCold[\(index)].validatedRows")
        }
        for (index, measurement) in report.measurements.cacheWarm.enumerated() {
            try query(measurement.query.text, "measurements.cacheWarm[\(index)].query.text")
            try name(measurement.query.category.rawValue,
                     "measurements.cacheWarm[\(index)].query.category")
            try metadata(measurement.topResult, "measurements.cacheWarm[\(index)].topResult")
            try samples(measurement.samples, "measurements.cacheWarm[\(index)].samples")
            try rows(measurement.validatedRows,
                     "measurements.cacheWarm[\(index)].validatedRows")
        }
        func sequenceStrings(_ measurements: [SequenceMeasurement], _ field: String) throws {
            for (index, measurement) in measurements.enumerated() {
                try name(measurement.name, "\(field)[\(index)].name")
                for (stepIndex, step) in measurement.steps.enumerated() {
                    try query(step.query, "\(field)[\(index)].steps[\(stepIndex)].query")
                    try samples(step.samples,
                                "\(field)[\(index)].steps[\(stepIndex)].samples")
                    try rows(step.validatedRows,
                             "\(field)[\(index)].steps[\(stepIndex)].validatedRows")
                }
            }
        }
        try sequenceStrings(report.measurements.serialTyping, "measurements.serialTyping")
        try sequenceStrings(report.measurements.deletion, "measurements.deletion")
        let supersession = report.measurements.supersession
        try query(supersession.olderQuery, "measurements.supersession.olderQuery")
        try query(supersession.newestQuery, "measurements.supersession.newestQuery")
        for (index, sample) in supersession.samples.enumerated() {
            try fingerprint(sample.newest.correctness.resultFingerprint,
                            "measurements.supersession.samples[\(index)].newest.correctness.resultFingerprint")
        }
        try rows(supersession.newestValidatedRows,
                 "measurements.supersession.newestValidatedRows")
        if let completedOlder = supersession.completedOlderResult {
            try rows(completedOlder.rows,
                     "measurements.supersession.completedOlderResult.rows")
        }
    }

    static func validateMachineReportStrings(_ report: MachineReport) throws {
        try forEachReportString(report) { value, field, maxUTF8Bytes, allowsEmpty in
            guard (allowsEmpty || !value.isEmpty),
                  SafetyLimits.utf8Fits(value, maxBytes: maxUTF8Bytes),
                  !SafetyLimits.containsNULByte(value) else {
                throw BenchmarkError.invalidReport(
                    "\(field) is \(allowsEmpty ? "oversized or contains NUL" : "empty, oversized, or contains NUL")"
                )
            }
        }
    }

    /// Conservative byte ceiling for this fixed, pretty-printed schema. The constants cover all JSON
    /// keys, punctuation, numeric spellings and maximum indentation; dynamic strings use the shared
    /// saturating escape estimator. This is intentionally evaluated before `JSONEncoder` allocates.
    static func estimatedMachineReportJSONUpperBound(_ report: MachineReport) -> Int {
        var total = 128 * 1_024
        func claim(_ amount: Int) {
            guard amount >= 0, total != Int.max else { total = Int.max; return }
            let (sum, overflow) = total.addingReportingOverflow(amount)
            total = overflow ? Int.max : sum
        }
        func claim(_ count: Int, times amount: Int) {
            guard count >= 0, amount >= 0 else { total = Int.max; return }
            let (product, overflow) = count.multipliedReportingOverflow(by: amount)
            claim(overflow ? Int.max : product)
        }
        func claimRows(_ rows: [ResultRow]) {
            claim(rows.count, times: 384)
            for row in rows { claim(row.matchedByteOffsets.count, times: 40) }
        }
        func claimSamples(_ samples: [ResponseSample]) { claim(samples.count, times: 384) }

        forEachReportString(report) { value, _, _, _ in
            let escaped = SafetyLimits.jsonEscapedStringByteUpperBound(value)
            claim(escaped)
            claim(2) // surrounding quotes
        }
        claim(report.workload.queries.count, times: 128)
        for sequences in [report.workload.serialTypingSequences,
                          report.workload.deletionSequences] {
            claim(sequences.count, times: 192)
            for sequence in sequences { claim(sequence.steps.count, times: 64) }
        }
        claim(report.config.rankingIntegerWeights.count, times: 64)
        for measurements in [report.measurements.cacheCold, report.measurements.cacheWarm] {
            for measurement in measurements {
                claim(192)
                claimSamples(measurement.samples)
                claimRows(measurement.validatedRows)
            }
        }
        for sequences in [report.measurements.serialTyping, report.measurements.deletion] {
            for sequence in sequences {
                claim(192)
                for step in sequence.steps {
                    claim(160)
                    claimSamples(step.samples)
                    claimRows(step.validatedRows)
                }
            }
        }
        let supersession = report.measurements.supersession
        claim(256)
        claim(supersession.samples.count, times: 384)
        claim(supersession.samples.count, times: 192)
        claimRows(supersession.newestValidatedRows)
        if let completedOlder = supersession.completedOlderResult {
            claim(128)
            claimRows(completedOlder.rows)
        }
        return total
    }

    static func validateMachineReport(_ report: MachineReport) throws {
        func fail(_ message: String) throws -> Never {
            throw BenchmarkError.invalidReport(message)
        }
        try validateMachineReportStrings(report)
        func validateSamples(_ samples: [ResponseSample], expectedCount: Int,
                             expectedQuery: String, expectedRows: [ResultRow],
                             context: String) throws {
            guard samples.count == expectedCount, let first = samples.first else {
                try fail("\(context) has \(samples.count) samples; expected \(expectedCount)")
            }
            guard !first.correctness.cancelled, first.correctness.totalMatchesIsComplete,
                  report.corpus.itemCount >= 0,
                  first.correctness.totalMatches >= 0,
                  first.correctness.totalMatches <= report.corpus.itemCount,
                  expectedRows.count <= report.config.maxResults,
                  expectedRows.count <= first.correctness.totalMatches,
                  isFingerprint(first.correctness.resultFingerprint) else {
                try fail("\(context) has an invalid correctness signature")
            }
            let parsed = QueryParser.parse(expectedQuery, home: NSHomeDirectory())
            guard parsed.raw == expectedQuery else {
                try fail("\(context) query is not the exact bounded parser input")
            }
            for (ordinal, row) in expectedRows.enumerated() {
                let itemIdentityIsValid: Bool
                let expectedItemIdentity: String
                switch parsed.mode {
                case .empty, .path:
                    // Recents and streamed path-mode rows are materialised from filesystem paths rather
                    // than the immutable index, so SearchEngine deliberately uses the -1 sentinel.
                    itemIdentityIsValid = row.itemIndex == -1
                    expectedItemIdentity = "the detached-row sentinel -1"
                case .search, .extensionOnly:
                    itemIdentityIsValid = row.itemIndex >= 0 && row.itemIndex < report.corpus.itemCount
                    expectedItemIdentity = "a corpus index in 0..<\(report.corpus.itemCount)"
                }
                guard itemIdentityIsValid else {
                    try fail("\(context) retained row \(ordinal) has itemIndex \(row.itemIndex); expected \(expectedItemIdentity)")
                }
                guard row.matchedByteOffsets.count <= SafetyLimits.maxNameUTF8Bytes,
                      row.matchedByteOffsets.allSatisfy({
                          (0...SafetyLimits.maxNameUTF8Bytes).contains($0)
                      }) else {
                    try fail("\(context) retained row \(ordinal) has invalid or unbounded match offsets")
                }
                guard parsed.mode != .empty || row.matchedByteOffsets.isEmpty else {
                    try fail("\(context) retained recent row \(ordinal) unexpectedly contains match offsets")
                }
            }
            let response = SearchResponse(
                query: expectedQuery, rows: expectedRows,
                generation: report.corpus.generation, requestId: 0, elapsed: 0,
                totalMatches: first.correctness.totalMatches, mode: parsed.mode
            )
            guard responseFingerprint(response) == first.correctness.resultFingerprint else {
                try fail("\(context) correctness fingerprint does not describe its retained rows")
            }
            for sample in samples {
                guard sample.latencyMilliseconds.isFinite, sample.latencyMilliseconds >= 0,
                      sample.correctness == first.correctness else {
                    try fail("\(context) contains non-finite latency or inconsistent output")
                }
            }
        }
        func validateQueries(_ measurements: [QueryMeasurement], expectedCount: Int,
                             context: String) throws {
            guard measurements.map(\.query) == queryCases else {
                try fail("\(context) query matrix does not match workload v\(workloadVersion)")
            }
            for measurement in measurements {
                try validateSamples(measurement.samples, expectedCount: expectedCount,
                                    expectedQuery: measurement.query.text,
                                    expectedRows: measurement.validatedRows,
                                    context: "\(context) query '\(measurement.query.text)'")
                let expectedTop = measurement.validatedRows.first
                    .map { "\($0.name) [\(kindTag($0.kind))]" } ?? "(none)"
                guard measurement.topResult == expectedTop else {
                    try fail("\(context) top result does not match its retained rows")
                }
            }
        }
        func validateSequences(_ measurements: [SequenceMeasurement], expected: [SequenceCase],
                               expectedCount: Int, context: String) throws {
            guard measurements.count == expected.count else {
                try fail("\(context) sequence count does not match workload v\(workloadVersion)")
            }
            for (measurement, sequence) in zip(measurements, expected) {
                guard measurement.name == sequence.name,
                      measurement.steps.map(\.query) == sequence.steps else {
                    try fail("\(context) sequence matrix does not match workload v\(workloadVersion)")
                }
                for step in measurement.steps {
                    try validateSamples(step.samples, expectedCount: expectedCount,
                                        expectedQuery: step.query,
                                        expectedRows: step.validatedRows,
                                        context: "\(context) '\(sequence.name)'/'\(step.query)'")
                }
            }
        }

        guard report.schemaVersion == reportSchemaVersion else {
            try fail("unsupported schema version \(report.schemaVersion)")
        }
        guard report.generatedAtUnixSeconds.isFinite else { try fail("generated timestamp is not finite") }
        let expectedPlan = samplePlan(iterations: report.workload.samplePlan.requested)
        guard report.workload == workloadIdentity(plan: expectedPlan) else {
            try fail("workload identity does not match workload v\(workloadVersion)")
        }
        let plan = report.workload.samplePlan
        try validateQueries(report.measurements.cacheCold, expectedCount: plan.fullScan,
                            context: "cache-cold")
        try validateQueries(report.measurements.cacheWarm, expectedCount: plan.warm,
                            context: "cache-warm")
        try validateSequences(report.measurements.serialTyping, expected: typingSequences,
                              expectedCount: plan.sequence, context: "serial-typing")
        try validateSequences(report.measurements.deletion, expected: deletionSequences,
                              expectedCount: plan.sequence, context: "deletion")
        let supersession = report.measurements.supersession
        guard supersession.olderQuery == "x", supersession.newestQuery == "chrome",
              supersession.samples.count == plan.supersession else {
            try fail("supersession matrix/sample count does not match workload v\(workloadVersion)")
        }
        try validateSamples(supersession.samples.map(\.newest), expectedCount: plan.supersession,
                            expectedQuery: supersession.newestQuery,
                            expectedRows: supersession.newestValidatedRows,
                            context: "supersession newest")
        for sample in supersession.samples where !sample.pairCompletionLatencyMilliseconds.isFinite
            || sample.pairCompletionLatencyMilliseconds < 0 {
            try fail("supersession contains non-finite or negative pair latency")
        }
        do {
            try validateCrossWorkloadParity(
                cold: report.measurements.cacheCold,
                warm: report.measurements.cacheWarm,
                sequences: report.measurements.serialTyping + report.measurements.deletion,
                supersession: supersession
            )
        } catch {
            try fail(error.localizedDescription)
        }
        guard SafetyLimits.maxResults.contains(report.config.maxResults),
              (0...report.config.maxResults).contains(report.config.appsFirstCap),
              report.config.searchReferenceUnixSeconds == benchmarkReferenceUnixSeconds,
              report.config.frecencyScale == RankingWeights.default.frecencyScale,
              report.config.rankingIntegerWeights
                == configIdentity(.default, source: "validation").rankingIntegerWeights else {
            try fail("search configuration is outside product bounds")
        }
        guard report.history.profileVersion == 1,
              report.history.mode == "deterministic-in-memory-production-stage-2",
              report.history.persistence
                == "none (FrecencyStore load/save never called; sentinel URL is never touched)",
              report.history.maxEntries == benchmarkHistoryEntries,
              (0...benchmarkHistoryEntries).contains(report.history.seededEntries),
              report.history.recordOperations >= report.history.seededEntries,
              report.history.recordOperations <= benchmarkHistoryEntries * 3,
              (0...FrecencyStore.maxQueryPicks).contains(report.history.queryPicks),
              report.history.halfLifeSeconds == 7 * 86_400,
              report.history.referenceUnixSeconds == benchmarkReferenceUnixSeconds,
              report.history.selection
                == "up to 500 evenly spaced corpus rows; 1...3 opens; ages 0...29 days; matching chrome/vsc/report-pdf/package-swift query picks",
              isFingerprint(report.history.profileFingerprint) else {
            try fail("history profile is invalid or unbounded")
        }
        guard (0...SafetyLimits.maxIndexedItems.upperBound).contains(report.corpus.itemCount),
              (0...report.corpus.itemCount).contains(report.corpus.appCount),
              report.corpus.directoryCount >= 0,
              report.corpus.builtAtUnixSeconds.isFinite,
              report.corpus.buildSeconds.isFinite, report.corpus.buildSeconds >= 0,
              isFingerprint(report.corpus.fingerprint) else {
            try fail("corpus identity is invalid or unbounded")
        }
        switch report.corpus.kind {
        case "deterministic-fixture":
            guard report.corpus.fixtureGeneratorVersion == fixtureGeneratorVersion,
                  report.corpus.fixtureSeed == fingerprintHex(fixtureSeed) else {
                try fail("fixture corpus is missing the exact generator version or seed")
            }
        case "isolated-real-crawl":
            guard report.corpus.fixtureGeneratorVersion == nil,
                  report.corpus.fixtureSeed == nil else {
                try fail("real corpus must not claim fixture generator identity")
            }
        default:
            try fail("unsupported corpus kind '\(report.corpus.kind)'")
        }
        guard report.environment.activeProcessorCount > 0,
              report.environment.physicalMemoryBytes > 0 else {
            try fail("environment resource identity is invalid")
        }
    }

    static func requestedReportOutput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL? {
        guard let raw = environment[reportOutputEnvironmentKey] else { return nil }
        guard SafetyLimits.isSafeAbsolutePath(raw), raw != "/" else {
            throw BenchmarkError.invalidReportOutput("path must be a bounded absolute path without '.'/'..'/NUL")
        }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.pathExtension.lowercased() == "json",
              SafetyLimits.isSafePathComponent(url.lastPathComponent,
                                               maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes) else {
            throw BenchmarkError.invalidReportOutput("destination must have a safe .json file name")
        }
        let productionDirectories = productionStateDirectories().map(\.path)
        guard !productionDirectories.contains(where: { SafetyLimits.isPath(url.path, within: $0) }) else {
            throw BenchmarkError.invalidReportOutput("destination must not be inside a JBar production-state directory")
        }
        return url
    }

    static func productionStateDirectories() -> [URL] {
        [
            Config.defaultURL().standardizedFileURL.deletingLastPathComponent(),
            Snapshot.defaultURL().standardizedFileURL.deletingLastPathComponent(),
            AppDelegate.historyURL().standardizedFileURL.deletingLastPathComponent(),
        ]
    }

    static func writeMachineReport(_ report: MachineReport, to url: URL) throws {
        let data = try encodedMachineReport(report)
        try writeReportDataAtomically(data, to: url)
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static let secureDirectoryOpenFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY

    private static func directoryIdentity(_ descriptor: Int32, context: String) throws -> DirectoryIdentity {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw BenchmarkError.reportWriteFailed(
                "\(context) is not a readable directory descriptor (errno \(errno))"
            )
        }
        return DirectoryIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func existingProtectedDirectoryIdentities(
        _ directories: [URL]
    ) throws -> [DirectoryIdentity] {
        var identities: [DirectoryIdentity] = []
        identities.reserveCapacity(directories.count)
        for directory in directories {
            let path = directory.standardizedFileURL.path
            let descriptor = Darwin.open(path, secureDirectoryOpenFlags)
            if descriptor < 0 {
                if errno == ENOENT { continue }
                throw BenchmarkError.reportWriteFailed(
                    "open production-state directory without following symlinks failed (errno \(errno))"
                )
            }
            defer { _ = Darwin.close(descriptor) }
            let identity = try directoryIdentity(descriptor, context: "production-state path")
            if !identities.contains(identity) { identities.append(identity) }
        }
        return identities
    }

    private static func rejectProtectedDirectoryAncestry(
        of directoryFD: Int32, protectedIdentities: [DirectoryIdentity]
    ) throws {
        guard !protectedIdentities.isEmpty else { return }
        let duplicated = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicated >= 0 else {
            throw BenchmarkError.reportWriteFailed("duplicate parent descriptor failed (errno \(errno))")
        }
        var currentFD = duplicated
        defer { _ = Darwin.close(currentFD) }

        for _ in 0...SafetyLimits.maxPathUTF8Bytes {
            let current = try directoryIdentity(currentFD, context: "output parent ancestry")
            guard !protectedIdentities.contains(current) else {
                throw BenchmarkError.reportWriteFailed(
                    "destination resolves inside a JBar production-state directory"
                )
            }
            let parentFD = "..".withCString {
                openat(currentFD, $0, secureDirectoryOpenFlags)
            }
            guard parentFD >= 0 else {
                throw BenchmarkError.reportWriteFailed(
                    "open output-parent ancestry without following symlinks failed (errno \(errno))"
                )
            }
            let parent: DirectoryIdentity
            do {
                parent = try directoryIdentity(parentFD, context: "output parent ancestry")
            } catch {
                _ = Darwin.close(parentFD)
                throw error
            }
            if parent == current {
                _ = Darwin.close(parentFD)
                return
            }
            _ = Darwin.close(currentFD)
            currentFD = parentFD
        }
        throw BenchmarkError.reportWriteFailed("output-parent ancestry exceeds the bounded path depth")
    }

    static func writeReportDataAtomically(
        _ data: Data, to url: URL, protectedDirectories: [URL]? = nil
    ) throws {
        guard data.count <= maxReportBytes else {
            throw BenchmarkError.reportWriteFailed("data exceeds the bounded report size")
        }
        guard let validated = try? requestedReportOutput(
            environment: [reportOutputEnvironmentKey: url.path]
        ), validated == url.standardizedFileURL else {
            throw BenchmarkError.reportWriteFailed("destination failed output-path validation")
        }
        let directory = url.deletingLastPathComponent()
        let directoryFD = Darwin.open(directory.path, secureDirectoryOpenFlags)
        guard directoryFD >= 0 else {
            throw BenchmarkError.reportWriteFailed(
                "open parent failed (errno \(errno)); parent and every ancestor must already exist without symlinks"
            )
        }
        defer { _ = Darwin.close(directoryFD) }
        _ = try directoryIdentity(directoryFD, context: "output parent")
        let protected = try existingProtectedDirectoryIdentities(
            protectedDirectories ?? productionStateDirectories()
        )
        try rejectProtectedDirectoryAncestry(of: directoryFD,
                                             protectedIdentities: protected)

        let fileName = url.lastPathComponent
        var existing = stat()
        let existingStatus = fileName.withCString {
            fstatat(directoryFD, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if existingStatus == 0, existing.st_mode & S_IFMT != S_IFREG {
            throw BenchmarkError.reportWriteFailed("existing destination is not a regular file")
        }
        if existingStatus != 0, errno != ENOENT {
            throw BenchmarkError.reportWriteFailed("inspect destination failed (errno \(errno))")
        }

        let temporaryName = ".jbar-benchmark-report-\(getpid())-\(UUID().uuidString)"
        let fileFD = temporaryName.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                   mode_t(0o600))
        }
        guard fileFD >= 0 else {
            throw BenchmarkError.reportWriteFailed("create temporary file failed (errno \(errno))")
        }
        var temporaryExists = true
        defer {
            _ = Darwin.close(fileFD)
            if temporaryExists { temporaryName.withCString { _ = unlinkat(directoryFD, $0, 0) } }
        }
        guard fchmod(fileFD, mode_t(0o600)) == 0 else {
            throw BenchmarkError.reportWriteFailed("chmod temporary file failed (errno \(errno))")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fileFD, bytes.baseAddress?.advanced(by: offset),
                                           bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BenchmarkError.reportWriteFailed("write failed (errno \(errno))")
                }
                guard written > 0 else {
                    throw BenchmarkError.reportWriteFailed("write made no progress")
                }
                offset += written
            }
        }
        guard fsync(fileFD) == 0 else {
            throw BenchmarkError.reportWriteFailed("sync file failed (errno \(errno))")
        }
        let renamed = temporaryName.withCString { temporary in
            fileName.withCString { destination in
                renameat(directoryFD, temporary, directoryFD, destination)
            }
        }
        guard renamed == 0 else {
            throw BenchmarkError.reportWriteFailed("atomic replace failed (errno \(errno))")
        }
        temporaryExists = false
        guard fsync(directoryFD) == 0 else {
            throw BenchmarkError.reportWriteFailed("sync parent directory failed (errno \(errno))")
        }
    }

    private static func writeBenchmarkError(_ error: Error) {
        let message = "benchmark error: \(error.localizedDescription)\n"
        if let data = message.data(using: .utf8) { FileHandle.standardError.write(data) }
    }

    static func responseFingerprint(_ response: SearchResponse) -> String {
        var hash = FNV64()
        hash.updateString("JBar.SearchResponse.v1")
        hash.updateString(response.query)
        hash.updateInteger(response.generation)
        switch response.mode {
        case .empty:
            hash.updateString("empty")
        case .search:
            hash.updateString("search")
        case .path(let base, let filter):
            hash.updateString("path")
            hash.updateString(base)
            hash.updateString(filter)
        case .extensionOnly(let ext):
            hash.updateString("extension")
            hash.updateString(ext)
        }
        hash.updateInteger(UInt64(response.rows.count))
        for row in response.rows {
            hash.updateInteger(Int64(row.itemIndex))
            hash.updateString(row.name)
            hash.updateString(row.path)
            hash.updateString(row.parentDisplay)
            hash.updateInteger(row.kind.rawValue)
            hash.updateInteger(Int64(row.score))
            hash.updateInteger(Int64(row.tier))
            hash.updateInteger(UInt64(row.matchedByteOffsets.count))
            for offset in row.matchedByteOffsets { hash.updateInteger(Int64(offset)) }
        }
        return fingerprintHex(hash.value)
    }

    /// Hash the actual immutable store rather than just generated names. This covers the directory/path
    /// topology, every hot-loop arena/column, extensions, flags/depth/kind, and complete app metadata.
    static func storeFingerprint(_ store: IndexStore) -> UInt64 {
        var hash = FNV64()
        hash.updateString("JBar.IndexStore.performance-identity.v2")
        hash.updateInteger(UInt64(store.count))
        hash.updateIntegers(store.dirId)
        hash.updateIntegers(store.nameStart)
        hash.updateIntegers(store.nameLen)
        hash.updateIntegers(store.displayStart)
        hash.updateIntegers(store.displayLen)
        hash.updateIntegers(store.mask)
        hash.updateIntegers(store.initials)
        hash.updateIntegers(store.mtime)
        hash.updateBytes(store.kind)
        hash.updateBytes(store.flags)
        hash.updateBytes(store.depth)
        hash.updateIntegers(store.extId)
        hash.updateBytes(store.foldedArena)
        hash.updateBytes(store.bonusArena)
        hash.updateBytes(store.displayArena)
        hash.updateInteger(UInt64(store.dirs.count))
        for directory in store.dirs {
            hash.updateInteger(directory.parent)
            hash.updateInteger(directory.nameStart)
            hash.updateInteger(directory.nameLen)
        }
        hash.updateBytes(store.dirArena)
        hash.updateInteger(UInt64(store.extensions.count))
        for ext in store.extensions { hash.updateString(ext) }
        let appIndices = store.appInfo.keys.sorted()
        hash.updateInteger(UInt64(appIndices.count))
        for index in appIndices {
            guard let info = store.appInfo[index] else { continue }
            hash.updateInteger(index)
            hash.updateOptionalString(info.bundleID)
            hash.updateString(info.displayName)
            hash.updateInteger(UInt64(info.aliases.count))
            for alias in info.aliases {
                hash.updateBytes(alias.folded)
                hash.updateBytes(alias.bonus)
                hash.updateInteger(alias.mask)
                hash.updateInteger(alias.initials)
            }
        }
        hash.updateIntegers(store.appItems)
        hash.updateInteger(store.generation)
        hash.updateInteger(store.fsEventId)
        hash.updateInteger(store.builtAt.timeIntervalSince1970.bitPattern)
        return hash.value
    }

    private static func fingerprintHex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    private static func isFingerprint(_ value: String) -> Bool {
        guard value.utf8.count == 18, value.hasPrefix("0x") else { return false }
        return value.utf8.dropFirst(2).allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func trackedPayloadBytes(_ store: IndexStore) -> UInt64 {
        var bytes: UInt64 = 0
        func add<T>(_ array: [T]) { bytes &+= UInt64(array.count) * UInt64(MemoryLayout<T>.stride) }
        add(store.dirId); add(store.nameStart); add(store.nameLen); add(store.displayStart); add(store.displayLen)
        add(store.mask); add(store.initials); add(store.mtime); add(store.kind); add(store.flags); add(store.depth); add(store.extId)
        add(store.foldedArena); add(store.bonusArena); add(store.displayArena); add(store.dirs); add(store.dirArena); add(store.appItems)
        for ext in store.extensions { bytes &+= UInt64(ext.utf8.count) }
        return bytes
    }

    private static func spotlightTerms(_ raw: String) -> [String] {
        let terms = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return terms.isEmpty ? [raw] : terms
    }

    private static func uniqueStandardized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
    }

    static func path(_ path: String, isWithinRoot root: String) -> Bool {
        SafetyLimits.isPath(path, within: root)
    }

    private static func minimalRoots(_ paths: [String]) -> [String] {
        let ordered = uniqueStandardized(paths).sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0 < $1
        }
        var roots: [String] = []
        for path in ordered where !roots.contains(where: { Benchmark.path(path, isWithinRoot: $0) }) {
            roots.append(path)
        }
        return roots.sorted()
    }

    private static func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static var benchmarkReferenceDate: Date {
        Date(timeIntervalSince1970: benchmarkReferenceUnixSeconds)
    }
    private static func elapsedMS(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }

    private static func ms(_ value: Double) -> String { String(format: "%.3fms", value) }
    private static func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
    private static func padR(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }
    private static func padL(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
    }
    private static func displayQuery(_ query: String) -> String {
        query.isEmpty ? "<empty>" : query.replacingOccurrences(of: " ", with: "·")
    }
    private static func truncated(_ string: String, to limit: Int) -> String {
        string.count <= limit ? string : String(string.prefix(max(0, limit - 1))) + "…"
    }
    private static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        SafetyLimits.abbreviatingHome(path, home: home)
    }
    private static func kindTag(_ kind: ItemKind) -> String {
        switch kind { case .app: return "app"; case .folder: return "dir"; default: return "file" }
    }

    private static var buildMode: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static var isRunningUnderRosetta: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    private struct FNV64 {
        private(set) var value: UInt64 = 0xcbf29ce484222325

        mutating func updateBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 0x100000001b3
            }
            value ^= 0xfe
            value &*= 0x100000001b3
        }

        mutating func updateString(_ string: String) {
            for byte in string.utf8 {
                value ^= UInt64(byte)
                value &*= 0x100000001b3
            }
            value ^= 0xff
            value &*= 0x100000001b3
        }

        mutating func updateOptionalString(_ string: String?) {
            guard let string else {
                updateInteger(UInt8(0))
                return
            }
            updateInteger(UInt8(1))
            updateString(string)
        }

        mutating func updateInteger<T: FixedWidthInteger>(_ integer: T) {
            var littleEndian = integer.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { bytes in
                for byte in bytes {
                    value ^= UInt64(byte)
                    value &*= 0x100000001b3
                }
            }
            value ^= 0xfd
            value &*= 0x100000001b3
        }

        mutating func updateIntegers<T: FixedWidthInteger>(_ integers: [T]) {
            updateInteger(UInt64(integers.count))
            for integer in integers { updateInteger(integer) }
        }
    }
}
