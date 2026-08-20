import XCTest
import Darwin
import JBarCore
@testable import JBarApp

final class BenchmarkTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-benchmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `/tmp` and `/var` are symlinks on macOS. Output-success tests use the physical namespace so
    /// `O_NOFOLLOW_ANY` exercises a genuinely symlink-free absolute path.
    private func secureTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("jbar-benchmark-output-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func replacing(
        _ report: Benchmark.MachineReport,
        environment: Benchmark.EnvironmentIdentity? = nil,
        workload: Benchmark.WorkloadIdentity? = nil,
        config: Benchmark.ConfigIdentity? = nil,
        history: Benchmark.HistoryProfile? = nil,
        corpus: Benchmark.CorpusIdentity? = nil,
        measurements: Benchmark.MeasurementReport? = nil
    ) -> Benchmark.MachineReport {
        Benchmark.MachineReport(
            schemaVersion: report.schemaVersion,
            generatedAtUnixSeconds: report.generatedAtUnixSeconds,
            environment: environment ?? report.environment,
            workload: workload ?? report.workload,
            config: config ?? report.config,
            history: history ?? report.history,
            corpus: corpus ?? report.corpus,
            measurements: measurements ?? report.measurements
        )
    }

    private func replacingEnvironmentString(
        _ environment: Benchmark.EnvironmentIdentity, field: String, value: String
    ) -> Benchmark.EnvironmentIdentity {
        Benchmark.EnvironmentIdentity(
            jbarVersion: field == "jbarVersion" ? value : environment.jbarVersion,
            buildMode: field == "buildMode" ? value : environment.buildMode,
            hardwareModel: field == "hardwareModel" ? value : environment.hardwareModel,
            cpuBrand: field == "cpuBrand" ? value : environment.cpuBrand,
            processArchitecture: field == "processArchitecture" ? value : environment.processArchitecture,
            rosettaTranslated: environment.rosettaTranslated,
            operatingSystemVersion: field == "operatingSystemVersion" ? value : environment.operatingSystemVersion,
            activeProcessorCount: environment.activeProcessorCount,
            physicalMemoryBytes: environment.physicalMemoryBytes,
            localeIdentifier: field == "localeIdentifier" ? value : environment.localeIdentifier,
            timeZoneIdentifier: field == "timeZoneIdentifier" ? value : environment.timeZoneIdentifier
        )
    }

    private func makeMachineReport(itemCount: Int = 500) async throws -> Benchmark.MachineReport {
        let plan = Benchmark.samplePlan(iterations: 1)
        let fixture = Benchmark.makeFixture(itemCount: itemCount)
        let history = Benchmark.makeDeterministicHistory(for: fixture.store)
        let engine = SearchEngine(frecency: history.store)
        let config = Config.default
        let cold = try await Benchmark.measureQueries(
            Benchmark.queryCases, engine: engine, store: fixture.store,
            cfg: config, samples: plan.fullScan, warmCache: false
        )
        let warm = try await Benchmark.measureQueries(
            Benchmark.queryCases, engine: engine, store: fixture.store,
            cfg: config, samples: plan.warm, warmCache: true
        )
        let typing = try await Benchmark.measureSequences(
            Benchmark.typingSequences, deletion: false, engine: engine,
            store: fixture.store, cfg: config, repetitions: plan.sequence
        )
        let deletion = try await Benchmark.measureSequences(
            Benchmark.deletionSequences, deletion: true, engine: engine,
            store: fixture.store, cfg: config, repetitions: plan.sequence
        )
        let supersession = try await Benchmark.measureSupersession(
            engine: engine, store: fixture.store, cfg: config,
            repetitions: plan.supersession
        )
        return Benchmark.MachineReport(
            schemaVersion: Benchmark.reportSchemaVersion,
            generatedAtUnixSeconds: 1_800_000_001,
            environment: Benchmark.environmentIdentity(),
            workload: Benchmark.workloadIdentity(plan: plan),
            config: Benchmark.configIdentity(config, source: "test defaults"),
            history: history.profile,
            corpus: Benchmark.CorpusIdentity(
                kind: "deterministic-fixture",
                description: "unit-test deterministic fixture",
                fingerprint: String(format: "0x%016llx", fixture.fingerprint),
                fixtureGeneratorVersion: Benchmark.fixtureGeneratorVersion,
                fixtureSeed: String(format: "0x%016llx", Benchmark.fixtureSeed),
                itemCount: fixture.store.count,
                appCount: fixture.store.appItems.count,
                directoryCount: fixture.store.dirs.count,
                generation: fixture.store.generation,
                builtAtUnixSeconds: fixture.store.builtAt.timeIntervalSince1970,
                buildSeconds: 0
            ),
            measurements: Benchmark.MeasurementReport(
                cacheCold: cold, cacheWarm: warm, serialTyping: typing,
                deletion: deletion, supersession: supersession
            )
        )
    }

    func testSamplePlanBoundsExpensiveWorkAndReportsActualCounts() {
        XCTAssertEqual(Benchmark.samplePlan(iterations: Int.min),
                       .init(requested: 1, warm: 1, fullScan: 1, sequence: 1, supersession: 1, spotlight: 1))
        XCTAssertEqual(Benchmark.samplePlan(iterations: 200),
                       .init(requested: 200, warm: 200, fullScan: 100, sequence: 100,
                             supersession: 100, spotlight: 5))
        XCTAssertEqual(Benchmark.samplePlan(iterations: Int.max),
                       .init(requested: SafetyLimits.maxBenchmarkIterations,
                             warm: SafetyLimits.maxBenchmarkIterations, fullScan: 100,
                             sequence: 100, supersession: 100, spotlight: 5))
    }

    func testDistributionUsesNearestRankAndNeverBestOfN() throws {
        XCTAssertNil(Benchmark.distribution([]))
        XCTAssertEqual(Benchmark.distribution([5]),
                       .init(count: 1, minimum: 5, p50: 5, p95: 5, p99: 5, maximum: 5))
        let values = (1...100).reversed().map(Double.init)
        XCTAssertEqual(Benchmark.distribution(values),
                       .init(count: 100, minimum: 1, p50: 50, p95: 95, p99: 99, maximum: 100))
    }

    func testWorkloadMatrixCoversIssueThreeCategoriesAndTransitions() {
        XCTAssertEqual(Benchmark.fixtureGeneratorVersion, 2)
        XCTAssertEqual(Benchmark.workloadVersion, 2)
        XCTAssertEqual(Set(Benchmark.queryCases.map(\.category.rawValue)),
                       Set(["empty", "common-letter", "selective", "acronym", "multi-term", "extension"]))
        XCTAssertTrue(Benchmark.typingSequences.contains { $0.steps.first == "r" && $0.steps.last == "report" })
        XCTAssertTrue(Benchmark.typingSequences.contains { $0.steps.contains("report pdf") })
        XCTAssertTrue(Benchmark.deletionSequences.contains { $0.steps == ["repor", "repo", "rep", "re", "r"] })
        XCTAssertTrue(Benchmark.crossToolComparisonPolicy.contains("ratio omitted"))
        XCTAssertFalse(Benchmark.crossToolComparisonPolicy.localizedCaseInsensitiveContains("faster"))
        let identity = Benchmark.workloadIdentity(plan: Benchmark.samplePlan(iterations: 1))
        XCTAssertEqual(identity.serialTypingSequences, Benchmark.typingSequences)
        XCTAssertFalse(identity.correctnessPolicy.localizedCaseInsensitiveContains("realistic"))
    }

    func testFixtureEnvironmentIsExplicitAndBounded() throws {
        XCTAssertNil(try Benchmark.requestedFixtureItems(environment: [:]))
        XCTAssertEqual(try Benchmark.requestedFixtureItems(environment: [
            Benchmark.fixtureItemsEnvironmentKey: "300000",
        ]), 300_000)
        for invalid in ["", "0", "-1", "2000001", "9223372036854775807", "abc"] {
            XCTAssertThrowsError(try Benchmark.requestedFixtureItems(environment: [
                Benchmark.fixtureItemsEnvironmentKey: invalid,
            ]), invalid)
        }
    }

    func testMissingConfigReadIsNonDestructive() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("missing/config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        let source = Benchmark.readOnlyConfig(from: configURL)
        XCTAssertEqual(source.config, .default)
        XCTAssertTrue(source.description.contains("no file created"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path),
                       "benchmark inspection must not create config or parent directories")
    }

    func testExistingConfigReadDoesNotRewriteIt() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        let bytes = try Config.default.jsonData()
        try bytes.write(to: configURL)
        let before = try Data(contentsOf: configURL)
        let source = Benchmark.readOnlyConfig(from: configURL)
        XCTAssertEqual(source.config, .default)
        XCTAssertEqual(try Data(contentsOf: configURL), before)
        XCTAssertTrue(source.description.contains("read-only"))
    }

    func testReadOnlyConfigRejectsSymlinkAndFIFONonBlocking() throws {
        let directory = try temporaryDirectory()
        var nonDefault = Config.default
        nonDefault.hotkey = "control+space"
        let target = directory.appendingPathComponent("target.json")
        try nonDefault.jsonData().write(to: target)
        let link = directory.appendingPathComponent("config-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = Benchmark.readOnlyConfig(from: link)
        XCTAssertEqual(linked.config, .default, "benchmark must not follow an attacker-selected config symlink")
        XCTAssertTrue(linked.description.contains("no writes performed"))

        let fifo = directory.appendingPathComponent("config-fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = Date()
        let piped = Benchmark.readOnlyConfig(from: fifo)
        XCTAssertEqual(piped.config, .default)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1,
                          "opening a FIFO must be non-blocking and fail regular-file validation")
    }

    func testIsolatedOptionsNeverUseProductionSnapshotOrWatcher() throws {
        let directory = try temporaryDirectory()
        let options = Benchmark.isolatedOptions(config: .default, stateDirectory: directory,
                                                home: directory.path)
        XCTAssertEqual(options.snapshotURL, directory.appendingPathComponent("index.snapshot"))
        XCTAssertNotEqual(options.snapshotURL.standardizedFileURL, Snapshot.defaultURL().standardizedFileURL)
        XCTAssertFalse(options.watchFileSystem)
        XCTAssertEqual(options.snapshotWriteInterval, 0)
    }

    func testScopeUsesTheConfiguredRootsAndRemovesNestedSpotlightScopes() throws {
        let directory = try temporaryDirectory()
        let files = directory.appendingPathComponent("files", isDirectory: true)
        let nestedFiles = files.appendingPathComponent("nested", isDirectory: true)
        let apps = directory.appendingPathComponent("apps", isDirectory: true)
        let nestedApps = apps.appendingPathComponent("nested", isDirectory: true)
        for url in [nestedFiles, nestedApps] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var config = Config.default
        config.fileRoots = [files.path, nestedFiles.path]
        config.appDirectories = [apps.path, nestedApps.path]
        let scope = Benchmark.scopePlan(config: config, home: directory.path)
        XCTAssertEqual(scope.fileRoots, [files.path, nestedFiles.path])
        XCTAssertEqual(scope.appRoots, [apps.path, nestedApps.path])
        XCTAssertTrue(scope.spotlightScopes.contains(files.path))
        XCTAssertTrue(scope.spotlightScopes.contains(apps.path))
        XCTAssertFalse(scope.spotlightScopes.contains(nestedFiles.path))
        XCTAssertFalse(scope.spotlightScopes.contains(nestedApps.path))
        XCTAssertTrue(scope.containsForSpotlight(nestedFiles.appendingPathComponent("report.pdf").path))
    }

    func testSpotlightExpressionsPreserveANDSemanticsAndEscapeMetadataWildcards() {
        XCTAssertEqual(Benchmark.spotlightQueryExpression(forTerms: ["chrome"]),
                       #"kMDItemFSName == "*chrome*"cd"#)
        XCTAssertEqual(Benchmark.spotlightQueryExpression(forTerms: ["report", "pdf"]),
                       #"kMDItemFSName == "*report*"cd && kMDItemFSName == "*pdf*"cd"#)
        XCTAssertEqual(Benchmark.spotlightExactNameExpression(#"a"b*c?\d"#),
                       #"kMDItemFSName == "a\"b\*c\?\\d"cd"#)
        XCTAssertEqual(Benchmark.spotlightExactNameExpression("\"\u{301}*\u{FE0F}"),
                       "kMDItemFSName == \"\\\"\u{301}\\*\u{FE0F}\"cd",
                       "syntax characters must be escaped by scalar even when they share a grapheme")
        XCTAssertEqual(Benchmark.spotlightExactNameExpression("Joe's"),
                       #"kMDItemFSName == "Joe\'s"cd"#)
    }

    func testRootScopeContainsAllAbsolutePathsAndEliminatesNestedScopes() {
        XCTAssertTrue(Benchmark.path("/Applications/JBar.app", isWithinRoot: "/"))
        XCTAssertTrue(Benchmark.path("/", isWithinRoot: "/"))
        XCTAssertTrue(Benchmark.path("/Applications/\u{301}组合.app", isWithinRoot: "/Applications"))
        XCTAssertFalse(Benchmark.path("relative", isWithinRoot: "/"))

        var config = Config.default
        config.fileRoots = ["/", "/Applications"]
        config.appDirectories = []
        let scope = Benchmark.scopePlan(config: config, home: NSHomeDirectory())
        XCTAssertEqual(scope.spotlightScopes, ["/"])
        XCTAssertTrue(scope.containsForSpotlight("/Applications/JBar.app"))
    }

    func testSpotlightCoverageMembershipIsBoundedAndNeverTurnsUnknownIntoMiss() {
        let paths = ["/other", "/target", "/later"]
        let found = Benchmark.boundedTargetMembership(resultCount: paths.count, targetPath: "/target",
                                                       maxResults: 2) { paths[$0] }
        XCTAssertEqual(found, .init(found: true, complete: true, inspected: 2))

        let truncated = Benchmark.boundedTargetMembership(resultCount: paths.count, targetPath: "/missing",
                                                           maxResults: 2) { paths[$0] }
        XCTAssertEqual(truncated, .init(found: false, complete: false, inspected: 2))

        let completeMiss = Benchmark.boundedTargetMembership(resultCount: paths.count, targetPath: "/missing",
                                                              maxResults: paths.count) { paths[$0] }
        XCTAssertEqual(completeMiss, .init(found: false, complete: true, inspected: paths.count))

        let noBudget = Benchmark.boundedTargetMembership(resultCount: Int.max, targetPath: "/missing",
                                                         maxResults: 0) { _ in
            XCTFail("a zero inspection budget must not access a metadata result")
            return nil
        }
        XCTAssertEqual(noBudget, .init(found: false, complete: false, inspected: 0))
    }

    func testFixtureIsDeterministicAndSeeded() {
        let first = Benchmark.makeFixture(itemCount: 1_000)
        let second = Benchmark.makeFixture(itemCount: 1_000)
        let otherSeed = Benchmark.makeFixture(itemCount: 1_000, seed: Benchmark.fixtureSeed &+ 1)
        XCTAssertEqual(first.store.count, 1_000)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.fingerprint, otherSeed.fingerprint)
        for index in [0, 1, 17, 29, 997] {
            XCTAssertEqual(first.store.name(of: index), second.store.name(of: index))
            XCTAssertEqual(first.store.path(of: index), second.store.path(of: index))
        }
        XCTAssertEqual(first.store.builtAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertGreaterThan(Benchmark.trackedPayloadBytes(first.store), 0)
    }

    func testStoreFingerprintCoversTopologyRankingColumnsExtensionsAndAppMetadata() {
        func file(rootPath: String = "/fixture", directoryName: String = "bucket",
                  kind: ItemKind = .document, flags: ItemFlags = [], depth: Int = 2,
                  ext: String = "pdf") -> UInt64 {
            let builder = IndexBuilder()
            let root = builder.addRoot(rootPath)
            let directory = builder.addDir(parent: root, name: directoryName)
            builder.addItem(dir: directory, name: "report.pdf", analyzed: TextAnalyzer.analyze("report.pdf"),
                            kind: kind, flags: flags, mtime: nil, depth: depth, ext: ext)
            return Benchmark.storeFingerprint(
                builder.build(generation: 1, builtAt: Date(timeIntervalSinceReferenceDate: 0))
            )
        }
        let baseline = file()
        XCTAssertNotEqual(baseline, file(rootPath: "/other"), "absolute path topology must be covered")
        XCTAssertNotEqual(baseline, file(directoryName: "other"), "directory topology must be covered")
        XCTAssertNotEqual(baseline, file(kind: .code), "kind must be covered")
        XCTAssertNotEqual(baseline, file(flags: [.hidden]), "flags must be covered")
        XCTAssertNotEqual(baseline, file(depth: 9), "depth must be covered")
        XCTAssertNotEqual(baseline, file(ext: "doc"), "extension must be covered")

        func app(bundleID: String, displayName: String) -> UInt64 {
            let builder = IndexBuilder()
            let root = builder.addRoot("/Applications")
            builder.addItem(dir: root, name: "Editor", analyzed: TextAnalyzer.analyze("Editor"),
                            kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: "app",
                            app: AppInfo(bundleID: bundleID, displayName: displayName,
                                         aliases: [TextAnalyzer.analyze("编辑器")]))
            return Benchmark.storeFingerprint(
                builder.build(generation: 1, builtAt: Date(timeIntervalSinceReferenceDate: 0))
            )
        }
        XCTAssertNotEqual(app(bundleID: "example.one", displayName: "Editor"),
                          app(bundleID: "example.two", displayName: "Editor"))
        XCTAssertNotEqual(app(bundleID: "example.one", displayName: "Editor"),
                          app(bundleID: "example.one", displayName: "Localized Editor"))
    }

    func testDeterministicHistoryIsBoundedNonNilAndNeverTouchesDisk() {
        let sentinel = URL(fileURLWithPath: "/__jbar_benchmark_memory_only__")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let fixture = Benchmark.makeFixture(itemCount: 1_000)
        let history = Benchmark.makeDeterministicHistory(for: fixture.store)
        let second = Benchmark.makeDeterministicHistory(for: fixture.store)
        XCTAssertEqual(history.store.maxEntries, Benchmark.benchmarkHistoryEntries)
        XCTAssertEqual(history.profile.seededEntries, Benchmark.benchmarkHistoryEntries)
        XCTAssertEqual(history.store.count, Benchmark.benchmarkHistoryEntries)
        XCTAssertGreaterThan(history.profile.recordOperations, history.profile.seededEntries)
        XCTAssertGreaterThan(history.profile.queryPicks, 0)
        XCTAssertLessThanOrEqual(history.profile.queryPicks, FrecencyStore.maxQueryPicks)
        XCTAssertTrue(history.profile.persistence.contains("never touched"))
        XCTAssertEqual(history.profile, second.profile)
        XCTAssertTrue(history.profile.profileFingerprint.hasPrefix("0x"))
        XCTAssertGreaterThan(history.store.score(
            for: fixture.store.path(of: 0),
            now: Date(timeIntervalSince1970: Benchmark.benchmarkReferenceUnixSeconds)
        ), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testMeasuredResponseValidationFailsClosedOnCancellationIncompleteOrDrift() throws {
        let row = ResultRow(itemIndex: 1, name: "Report", path: "/fixture/Report",
                            parentDisplay: "/fixture", kind: .document,
                            matchedByteOffsets: [0, 1], score: 42, tier: 2)
        let good = SearchResponse(query: "re", rows: [row], generation: 1, requestId: 1,
                                  elapsed: 0.001, totalMatches: 7, mode: .search)
        var validator = Benchmark.ResponseValidationState(
            context: "unit test", expectedQuery: "re", expectedMode: .search,
            expectedGeneration: 1, rowCap: 1, totalUpperBound: 10
        )
        XCTAssertNoThrow(try validator.accept(good, latencyMilliseconds: 1))
        XCTAssertNoThrow(try validator.accept(good, latencyMilliseconds: 2))

        var cancelled = good
        cancelled.cancelled = true
        cancelled.totalMatchesIsComplete = false
        XCTAssertThrowsError(try validator.accept(cancelled, latencyMilliseconds: 1))

        var incomplete = good
        incomplete.totalMatchesIsComplete = false
        XCTAssertThrowsError(try validator.accept(incomplete, latencyMilliseconds: 1))

        var countDrift = good
        countDrift.totalMatches += 1
        XCTAssertThrowsError(try validator.accept(countDrift, latencyMilliseconds: 1))

        var resultDrift = good
        resultDrift.rows[0].score += 1
        XCTAssertThrowsError(try validator.accept(resultDrift, latencyMilliseconds: 1))

        var queryDrift = good
        queryDrift.query = "r"
        XCTAssertThrowsError(try validator.accept(queryDrift, latencyMilliseconds: 1))
        var modeDrift = good
        modeDrift.mode = .empty
        XCTAssertThrowsError(try validator.accept(modeDrift, latencyMilliseconds: 1))
        var generationDrift = good
        generationDrift.generation = 2
        XCTAssertThrowsError(try validator.accept(generationDrift, latencyMilliseconds: 1))

        var rowCap = Benchmark.ResponseValidationState(
            context: "row cap", expectedQuery: "re", expectedMode: .search,
            expectedGeneration: 1, rowCap: 0, totalUpperBound: 10
        )
        XCTAssertThrowsError(try rowCap.accept(good, latencyMilliseconds: 1))
        var totalCap = Benchmark.ResponseValidationState(
            context: "total cap", expectedQuery: "re", expectedMode: .search,
            expectedGeneration: 1, rowCap: 1, totalUpperBound: 6
        )
        XCTAssertThrowsError(try totalCap.accept(good, latencyMilliseconds: 1))
        XCTAssertThrowsError(try validator.accept(good, latencyMilliseconds: .nan))
    }

    func testCancelledOlderSupersessionRequiresExactEmptyIncompleteEnvelope() throws {
        let fixture = Benchmark.makeFixture(itemCount: 10)
        let generation = fixture.store.generation
        var good = SearchResponse(query: "x", rows: [], generation: generation,
                                  requestId: 1, elapsed: 0, totalMatches: 0,
                                  mode: .search, totalMatchesIsComplete: false)
        good.cancelled = true
        XCTAssertNoThrow(try Benchmark.validateCancelledOlderSupersession(good,
                                                                           store: fixture.store))

        var variants: [SearchResponse] = []
        var value = good; value.cancelled = false; variants.append(value)
        value = good; value.query = "X"; variants.append(value)
        value = good; value.mode = .empty; variants.append(value)
        value = good; value.generation &+= 1; variants.append(value)
        value = good
        value.rows = [ResultRow(itemIndex: 0, name: "row", path: "/row",
                                parentDisplay: "/", kind: .other,
                                matchedByteOffsets: [], score: 0, tier: 0)]
        variants.append(value)
        value = good; value.totalMatches = 1; variants.append(value)
        value = good; value.totalMatchesIsComplete = true; variants.append(value)
        for variant in variants {
            XCTAssertThrowsError(try Benchmark.validateCancelledOlderSupersession(
                variant, store: fixture.store
            ))
        }
    }

    func testMachineReportRoundTripsHasRequiredSchemaAndWritesPOSIXMode0600() async throws {
        let report = try await makeMachineReport()
        let data = try Benchmark.encodedMachineReport(report)
        XCTAssertLessThanOrEqual(data.count, Benchmark.maxReportBytes)
        XCTAssertEqual(try Benchmark.decodeMachineReport(data), report)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, Benchmark.reportSchemaVersion)
        for required in ["environment", "workload", "config", "history", "corpus", "measurements"] {
            XCTAssertNotNil(object[required], "missing top-level schema field \(required)")
        }
        let measurements = try XCTUnwrap(object["measurements"] as? [String: Any])
        for required in ["cacheCold", "cacheWarm", "serialTyping", "deletion", "supersession"] {
            XCTAssertNotNil(measurements[required], "missing measurement series \(required)")
        }
        let cold = try XCTUnwrap(measurements["cacheCold"] as? [[String: Any]])
        XCTAssertNotNil(cold.first?["validatedRows"],
                        "report must retain the exact rows used by direct correctness validation")
        let rawSamples = try XCTUnwrap(cold.first?["samples"] as? [[String: Any]])
        let raw = try XCTUnwrap(rawSamples.first)
        XCTAssertNotNil(raw["latencyMilliseconds"])
        let correctness = try XCTUnwrap(raw["correctness"] as? [String: Any])
        XCTAssertEqual(correctness["cancelled"] as? Bool, false)
        XCTAssertEqual(correctness["totalMatchesIsComplete"] as? Bool, true)
        XCTAssertNotNil(correctness["totalMatches"])
        XCTAssertNotNil(correctness["resultFingerprint"])

        let directory = try secureTemporaryDirectory()
        let output = directory.appendingPathComponent("benchmark.json")
        let parsed = try Benchmark.requestedReportOutput(environment: [
            Benchmark.reportOutputEnvironmentKey: output.path,
        ])
        XCTAssertEqual(parsed, output)
        try Benchmark.writeMachineReport(report, to: output)
        XCTAssertEqual(try Benchmark.decodeMachineReport(Data(contentsOf: output)), report)
        var info = stat()
        XCTAssertEqual(lstat(output.path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o600))
    }

    func testExactRowsAgreeAcrossColdWarmOverlappingSequencesAndNewest() async throws {
        let report = try await makeMachineReport()
        XCTAssertNoThrow(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold,
            warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + report.measurements.deletion,
            supersession: report.measurements.supersession
        ))

        var duplicateCold = report.measurements.cacheCold
        duplicateCold.append(try XCTUnwrap(duplicateCold.first))
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: duplicateCold,
            warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + report.measurements.deletion,
            supersession: report.measurements.supersession
        ))

        let warmIndex = try XCTUnwrap(report.measurements.cacheWarm.firstIndex {
            $0.query.text == "chrome"
        })
        var badWarmRows = report.measurements.cacheWarm[warmIndex].validatedRows
        XCTAssertFalse(badWarmRows.isEmpty)
        badWarmRows[0].score &+= 1
        var badWarm = report.measurements.cacheWarm
        let originalWarm = badWarm[warmIndex]
        badWarm[warmIndex] = Benchmark.QueryMeasurement(
            query: originalWarm.query, samples: originalWarm.samples,
            topResult: originalWarm.topResult, validatedRows: badWarmRows
        )
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: badWarm,
            sequences: report.measurements.serialTyping + report.measurements.deletion,
            supersession: report.measurements.supersession
        ))

        var badTyping = report.measurements.serialTyping
        let sequenceIndex = try XCTUnwrap(badTyping.firstIndex { $0.name == "selective" })
        var steps = badTyping[sequenceIndex].steps
        let stepIndex = try XCTUnwrap(steps.firstIndex { $0.query == "chrome" })
        var badStepRows = steps[stepIndex].validatedRows
        XCTAssertFalse(badStepRows.isEmpty)
        badStepRows[0].tier &+= 1
        steps[stepIndex] = Benchmark.SequenceStepMeasurement(
            query: steps[stepIndex].query, samples: steps[stepIndex].samples,
            validatedRows: badStepRows
        )
        badTyping[sequenceIndex] = Benchmark.SequenceMeasurement(
            name: badTyping[sequenceIndex].name, steps: steps
        )
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold,
            warm: report.measurements.cacheWarm,
            sequences: badTyping + report.measurements.deletion,
            supersession: report.measurements.supersession
        ))
    }

    func testParityRejectsSecondRReportPAndReporContextDrift() async throws {
        let report = try await makeMachineReport()

        func tampered(
            _ source: [Benchmark.SequenceMeasurement], sequenceName: String,
            query: String
        ) throws -> [Benchmark.SequenceMeasurement] {
            var output = source
            let sequenceIndex = try XCTUnwrap(output.firstIndex { $0.name == sequenceName })
            var steps = output[sequenceIndex].steps
            let stepIndex = try XCTUnwrap(steps.firstIndex { $0.query == query })
            var rows = steps[stepIndex].validatedRows
            XCTAssertFalse(rows.isEmpty)
            rows[0].score &+= 1
            steps[stepIndex] = Benchmark.SequenceStepMeasurement(
                query: steps[stepIndex].query, samples: steps[stepIndex].samples,
                validatedRows: rows
            )
            output[sequenceIndex] = Benchmark.SequenceMeasurement(
                name: output[sequenceIndex].name, steps: steps
            )
            return output
        }

        // `r` first appears in common→selective; this alters its second occurrence in multi-term.
        let secondR = try tampered(report.measurements.serialTyping,
                                   sequenceName: "multi-term", query: "r")
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: report.measurements.cacheWarm,
            sequences: secondR + report.measurements.deletion,
            supersession: report.measurements.supersession
        ))

        // `report p` first appears during typing, then reappears in deletion.
        let secondReportP = try tampered(report.measurements.deletion,
                                         sequenceName: "multi-term backspace",
                                         query: "report p")
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + secondReportP,
            supersession: report.measurements.supersession
        ))

        // `repor` occurs in both deletion sequences; alter the later occurrence.
        let secondRepor = try tampered(report.measurements.deletion,
                                       sequenceName: "multi-term backspace",
                                       query: "repor")
        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + secondRepor,
            supersession: report.measurements.supersession
        ))
    }

    func testCompletedOlderSupersessionEvidenceMustEqualColdX() async throws {
        let report = try await makeMachineReport()
        let coldX = try XCTUnwrap(report.measurements.cacheCold.first {
            $0.query.text == "x"
        })
        let original = report.measurements.supersession
        let completedSamples = original.samples.map {
            Benchmark.SupersessionSample(
                newest: $0.newest,
                pairCompletionLatencyMilliseconds: $0.pairCompletionLatencyMilliseconds,
                olderCancelled: false
            )
        }
        let evidence = Benchmark.ExactResultEvidence(
            totalMatches: coldX.matches, rows: coldX.validatedRows
        )
        func supersession(_ result: Benchmark.ExactResultEvidence?) -> Benchmark.SupersessionMeasurement {
            Benchmark.SupersessionMeasurement(
                olderQuery: original.olderQuery, newestQuery: original.newestQuery,
                samples: completedSamples, newestValidatedRows: original.newestValidatedRows,
                completedOlderResult: result
            )
        }
        func reportWith(_ value: Benchmark.SupersessionMeasurement) -> Benchmark.MachineReport {
            replacing(report, measurements: Benchmark.MeasurementReport(
                cacheCold: report.measurements.cacheCold,
                cacheWarm: report.measurements.cacheWarm,
                serialTyping: report.measurements.serialTyping,
                deletion: report.measurements.deletion,
                supersession: value
            ))
        }

        let valid = supersession(evidence)
        XCTAssertNoThrow(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + report.measurements.deletion,
            supersession: valid
        ))
        let encoded = try Benchmark.encodedMachineReport(reportWith(valid))
        XCTAssertEqual(try Benchmark.decodeMachineReport(encoded), reportWith(valid))

        XCTAssertThrowsError(try Benchmark.validateCrossWorkloadParity(
            cold: report.measurements.cacheCold, warm: report.measurements.cacheWarm,
            sequences: report.measurements.serialTyping + report.measurements.deletion,
            supersession: supersession(nil)
        ))

        var tamperedRows = evidence.rows
        XCTAssertFalse(tamperedRows.isEmpty)
        tamperedRows[0].tier &+= 1
        let tamperedRowsEvidence = Benchmark.ExactResultEvidence(
            totalMatches: evidence.totalMatches, rows: tamperedRows
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(
            reportWith(supersession(tamperedRowsEvidence))
        ))

        let tamperedTotal = Benchmark.ExactResultEvidence(
            totalMatches: evidence.totalMatches + 1, rows: evidence.rows
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(
            reportWith(supersession(tamperedTotal))
        ))

        let cancelledSamples = original.samples.map {
            Benchmark.SupersessionSample(
                newest: $0.newest,
                pairCompletionLatencyMilliseconds: $0.pairCompletionLatencyMilliseconds,
                olderCancelled: true
            )
        }
        let impossibleEvidence = Benchmark.SupersessionMeasurement(
            olderQuery: original.olderQuery, newestQuery: original.newestQuery,
            samples: cancelledSamples, newestValidatedRows: original.newestValidatedRows,
            completedOlderResult: evidence
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(reportWith(impossibleEvidence)))
    }

    func testMachineReportBoundsEveryEnvironmentStringOnDecode() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        let oversized = String(repeating: "界", count: SafetyLimits.maxPathUTF8Bytes)
        for field in [
            "jbarVersion", "buildMode", "hardwareModel", "cpuBrand",
            "processArchitecture", "operatingSystemVersion", "localeIdentifier",
            "timeZoneIdentifier",
        ] {
            let changed = replacing(
                report,
                environment: replacingEnvironmentString(report.environment,
                                                        field: field, value: oversized)
            )
            let directJSON = try JSONEncoder().encode(changed)
            XCTAssertThrowsError(try Benchmark.decodeMachineReport(directJSON), field)
        }
    }

    func testMachineReportBoundsRepresentativeStringsInEveryReportSection() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        let oversized = String(repeating: "界", count: SafetyLimits.maxPathUTF8Bytes)
        func assertRejected(_ changed: Benchmark.MachineReport, _ field: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
            let directJSON = try JSONEncoder().encode(changed)
            XCTAssertThrowsError(try Benchmark.decodeMachineReport(directJSON), field,
                                 file: file, line: line)
        }

        let workload = Benchmark.WorkloadIdentity(
            version: report.workload.version, samplePlan: report.workload.samplePlan,
            queries: report.workload.queries,
            serialTypingSequences: report.workload.serialTypingSequences,
            deletionSequences: report.workload.deletionSequences,
            supersessionOlderQuery: report.workload.supersessionOlderQuery,
            supersessionNewestQuery: report.workload.supersessionNewestQuery,
            clock: oversized, percentileMethod: report.workload.percentileMethod,
            correctnessPolicy: report.workload.correctnessPolicy
        )
        try assertRejected(replacing(report, workload: workload), "workload.clock")

        var weights = report.config.rankingIntegerWeights
        weights[oversized] = 1
        let config = Benchmark.ConfigIdentity(
            source: oversized, maxResults: report.config.maxResults,
            appsFirstCap: report.config.appsFirstCap,
            searchReferenceUnixSeconds: report.config.searchReferenceUnixSeconds,
            rankingIntegerWeights: weights, frecencyScale: report.config.frecencyScale
        )
        try assertRejected(replacing(report, config: config), "config")

        for changedHistory in [
            Benchmark.HistoryProfile(
                profileVersion: report.history.profileVersion, mode: oversized,
                persistence: report.history.persistence, maxEntries: report.history.maxEntries,
                seededEntries: report.history.seededEntries,
                recordOperations: report.history.recordOperations,
                queryPicks: report.history.queryPicks,
                halfLifeSeconds: report.history.halfLifeSeconds,
                referenceUnixSeconds: report.history.referenceUnixSeconds,
                selection: report.history.selection,
                profileFingerprint: report.history.profileFingerprint
            ),
            Benchmark.HistoryProfile(
                profileVersion: report.history.profileVersion, mode: report.history.mode,
                persistence: report.history.persistence, maxEntries: report.history.maxEntries,
                seededEntries: report.history.seededEntries,
                recordOperations: report.history.recordOperations,
                queryPicks: report.history.queryPicks,
                halfLifeSeconds: report.history.halfLifeSeconds,
                referenceUnixSeconds: report.history.referenceUnixSeconds,
                selection: oversized,
                profileFingerprint: report.history.profileFingerprint
            ),
        ] {
            try assertRejected(replacing(report, history: changedHistory), "history")
        }

        let corpus = Benchmark.CorpusIdentity(
            kind: report.corpus.kind, description: oversized,
            fingerprint: report.corpus.fingerprint,
            fixtureGeneratorVersion: report.corpus.fixtureGeneratorVersion,
            fixtureSeed: report.corpus.fixtureSeed, itemCount: report.corpus.itemCount,
            appCount: report.corpus.appCount, directoryCount: report.corpus.directoryCount,
            generation: report.corpus.generation,
            builtAtUnixSeconds: report.corpus.builtAtUnixSeconds,
            buildSeconds: report.corpus.buildSeconds
        )
        try assertRejected(replacing(report, corpus: corpus), "corpus.description")

        var cold = report.measurements.cacheCold
        let measurementIndex = try XCTUnwrap(cold.firstIndex { $0.query.text == "chrome" })
        let measurement = cold[measurementIndex]
        cold[measurementIndex] = Benchmark.QueryMeasurement(
            query: measurement.query, samples: measurement.samples,
            topResult: oversized, validatedRows: measurement.validatedRows
        )
        var measurements = Benchmark.MeasurementReport(
            cacheCold: cold, cacheWarm: report.measurements.cacheWarm,
            serialTyping: report.measurements.serialTyping,
            deletion: report.measurements.deletion,
            supersession: report.measurements.supersession
        )
        try assertRejected(replacing(report, measurements: measurements),
                           "measurement.topResult")

        var rows = measurement.validatedRows
        let first = try XCTUnwrap(rows.first)
        rows[0] = ResultRow(
            itemIndex: first.itemIndex, name: oversized, path: first.path,
            parentDisplay: first.parentDisplay, kind: first.kind,
            matchedByteOffsets: first.matchedByteOffsets,
            score: first.score, tier: first.tier
        )
        cold[measurementIndex] = Benchmark.QueryMeasurement(
            query: measurement.query, samples: measurement.samples,
            topResult: measurement.topResult, validatedRows: rows
        )
        measurements = Benchmark.MeasurementReport(
            cacheCold: cold, cacheWarm: report.measurements.cacheWarm,
            serialTyping: report.measurements.serialTyping,
            deletion: report.measurements.deletion,
            supersession: report.measurements.supersession
        )
        try assertRejected(replacing(report, measurements: measurements),
                           "measurement.validatedRows.name")
    }

    func testMachineReportRejectsConstructedOversizeBeforeEncoding() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        var warm = report.measurements.cacheWarm
        let original = warm[0]
        warm[0] = Benchmark.QueryMeasurement(
            query: original.query,
            samples: Array(repeating: try XCTUnwrap(original.samples.first), count: 100_000),
            topResult: original.topResult, validatedRows: original.validatedRows
        )
        let measurements = Benchmark.MeasurementReport(
            cacheCold: report.measurements.cacheCold, cacheWarm: warm,
            serialTyping: report.measurements.serialTyping,
            deletion: report.measurements.deletion,
            supersession: report.measurements.supersession
        )
        let oversized = replacing(report, measurements: measurements)
        XCTAssertGreaterThan(Benchmark.estimatedMachineReportJSONUpperBound(oversized),
                             Benchmark.maxReportBytes)
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(oversized)) { error in
            XCTAssertTrue(error.localizedDescription.contains("estimated JSON upper bound"))
        }
    }

    func testMachineReportRejectsTamperedRowsRowCapAndCorpusTotal() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        let index = try XCTUnwrap(report.measurements.cacheCold.firstIndex {
            $0.query.text == "chrome"
        })
        let original = report.measurements.cacheCold[index]
        let firstRow = try XCTUnwrap(original.validatedRows.first)

        func reportWith(_ measurement: Benchmark.QueryMeasurement) -> Benchmark.MachineReport {
            var cold = report.measurements.cacheCold
            cold[index] = measurement
            return replacing(report, measurements: Benchmark.MeasurementReport(
                cacheCold: cold, cacheWarm: report.measurements.cacheWarm,
                serialTyping: report.measurements.serialTyping,
                deletion: report.measurements.deletion,
                supersession: report.measurements.supersession
            ))
        }

        var tamperedRows = original.validatedRows
        tamperedRows[0].score &+= 1
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(reportWith(
            Benchmark.QueryMeasurement(
                query: original.query, samples: original.samples,
                topResult: original.topResult, validatedRows: tamperedRows
            )
        )))

        let tooManyRows = Array(repeating: firstRow, count: report.config.maxResults + 1)
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(reportWith(
            Benchmark.QueryMeasurement(
                query: original.query, samples: original.samples,
                topResult: original.topResult, validatedRows: tooManyRows
            )
        )))

        let sample = try XCTUnwrap(original.samples.first)
        let impossibleTotal = Benchmark.ResponseSample(
            latencyMilliseconds: sample.latencyMilliseconds,
            correctness: Benchmark.CorrectnessSignature(
                cancelled: false, totalMatchesIsComplete: true,
                totalMatches: report.corpus.itemCount + 1,
                resultFingerprint: sample.correctness.resultFingerprint
            )
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(reportWith(
            Benchmark.QueryMeasurement(
                query: original.query, samples: [impossibleTotal],
                topResult: original.topResult, validatedRows: original.validatedRows
            )
        )))
    }

    func testMachineReportAcceptsFilesystemRecentSentinelAndRejectsWrongRowIdentity() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        let recent = ResultRow(
            itemIndex: -1, name: "Recent.txt", path: "/fixture/Recent.txt",
            parentDisplay: "/fixture", kind: .document,
            matchedByteOffsets: [], score: 0, tier: 2
        )

        func replacingEmptyRows(_ rows: [ResultRow]) -> Benchmark.MachineReport {
            func replace(_ values: [Benchmark.QueryMeasurement]) -> [Benchmark.QueryMeasurement] {
                values.map { measurement in
                    guard measurement.query.text.isEmpty else { return measurement }
                    let response = SearchResponse(
                        query: "", rows: rows, generation: report.corpus.generation,
                        requestId: 0, elapsed: 0, totalMatches: rows.count, mode: .empty
                    )
                    let signature = Benchmark.CorrectnessSignature(
                        cancelled: false, totalMatchesIsComplete: true,
                        totalMatches: rows.count,
                        resultFingerprint: Benchmark.responseFingerprint(response)
                    )
                    return Benchmark.QueryMeasurement(
                        query: measurement.query,
                        samples: Array(repeating: Benchmark.ResponseSample(
                            latencyMilliseconds: 0, correctness: signature
                        ), count: measurement.samples.count),
                        topResult: rows.first.map { "\($0.name) [file]" } ?? "(none)",
                        validatedRows: rows
                    )
                }
            }
            return replacing(report, measurements: Benchmark.MeasurementReport(
                cacheCold: replace(report.measurements.cacheCold),
                cacheWarm: replace(report.measurements.cacheWarm),
                serialTyping: report.measurements.serialTyping,
                deletion: report.measurements.deletion,
                supersession: report.measurements.supersession
            ))
        }

        XCTAssertNoThrow(try Benchmark.encodedMachineReport(replacingEmptyRows([recent])))

        var indexedRecent = recent
        indexedRecent.itemIndex = 0
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(replacingEmptyRows([indexedRecent])))

        var highlightedRecent = recent
        highlightedRecent.matchedByteOffsets = [0]
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(replacingEmptyRows([highlightedRecent])))

        let searchIndex = try XCTUnwrap(report.measurements.cacheCold.firstIndex {
            $0.query.text == "chrome"
        })
        let search = report.measurements.cacheCold[searchIndex]
        let row = try XCTUnwrap(search.validatedRows.first)
        var sentinelRow = row
        sentinelRow.itemIndex = -1
        var cold = report.measurements.cacheCold
        cold[searchIndex] = Benchmark.QueryMeasurement(
            query: search.query, samples: search.samples,
            topResult: search.topResult, validatedRows: [sentinelRow]
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(replacing(
            report,
            measurements: Benchmark.MeasurementReport(
                cacheCold: cold, cacheWarm: report.measurements.cacheWarm,
                serialTyping: report.measurements.serialTyping,
                deletion: report.measurements.deletion,
                supersession: report.measurements.supersession
            )
        )))
    }

    func testMeasuredEmptyQueryRetainsExistingFilesystemRecentWithDetachedIdentity() async throws {
        let directory = try temporaryDirectory()
        let recentURL = directory.appendingPathComponent("Recent.txt")
        try Data("recent".utf8).write(to: recentURL)
        let history = FrecencyStore(
            fileURL: directory.appendingPathComponent("history.json"), maxEntries: 10
        )
        history.record(
            open: recentURL.path, query: nil,
            at: Date(timeIntervalSince1970: Benchmark.benchmarkReferenceUnixSeconds)
        )
        let fixture = Benchmark.makeFixture(itemCount: 10)
        let measurements = try await Benchmark.measureQueries(
            [Benchmark.QueryCase(text: "", category: .empty)],
            engine: SearchEngine(frecency: history), store: fixture.store,
            cfg: .default, samples: 1, warmCache: false
        )
        let row = try XCTUnwrap(measurements.first?.validatedRows.first)
        XCTAssertEqual(row.itemIndex, -1)
        XCTAssertEqual(row.path, recentURL.path)
        XCTAssertTrue(row.matchedByteOffsets.isEmpty)
    }

    func testIsolatedStateCleanupFailureIsObservableAndFailClosed() throws {
        struct CleanupFailure: LocalizedError {
            var errorDescription: String? { "injected cleanup failure" }
        }
        let url = URL(fileURLWithPath: "/private/tmp/jbar-cleanup-test")
        XCTAssertThrowsError(try Benchmark.cleanupIsolatedState(at: url) { _ in
            throw CleanupFailure()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not remove isolated"))
            XCTAssertTrue(error.localizedDescription.contains("injected cleanup failure"))
        }
        var removed: URL?
        XCTAssertNoThrow(try Benchmark.cleanupIsolatedState(at: url) { removed = $0 })
        XCTAssertEqual(removed, url)
    }

    func testMachineReportRejectsSchemaSampleAndSizeDrift() async throws {
        let report = try await makeMachineReport(itemCount: 100)
        let wrongSchema = Benchmark.MachineReport(
            schemaVersion: Benchmark.reportSchemaVersion + 1,
            generatedAtUnixSeconds: report.generatedAtUnixSeconds,
            environment: report.environment, workload: report.workload,
            config: report.config, history: report.history, corpus: report.corpus,
            measurements: report.measurements
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(wrongSchema))
        let directlyEncodedWrongSchema = try JSONEncoder().encode(wrongSchema)
        XCTAssertThrowsError(try Benchmark.decodeMachineReport(directlyEncodedWrongSchema))

        let missingQuery = Benchmark.MeasurementReport(
            cacheCold: Array(report.measurements.cacheCold.dropLast()),
            cacheWarm: report.measurements.cacheWarm,
            serialTyping: report.measurements.serialTyping,
            deletion: report.measurements.deletion,
            supersession: report.measurements.supersession
        )
        let missingSampleReport = Benchmark.MachineReport(
            schemaVersion: report.schemaVersion,
            generatedAtUnixSeconds: report.generatedAtUnixSeconds,
            environment: report.environment, workload: report.workload,
            config: report.config, history: report.history, corpus: report.corpus,
            measurements: missingQuery
        )
        XCTAssertThrowsError(try Benchmark.encodedMachineReport(missingSampleReport))
        XCTAssertThrowsError(try Benchmark.decodeMachineReport(
            Data(repeating: 0, count: Benchmark.maxReportBytes + 1)
        ))
    }

    func testMachineReportOutputPathIsExplicitSafeAndOutsideProductionState() throws {
        XCTAssertNil(try Benchmark.requestedReportOutput(environment: [:]))
        for invalid in ["", "relative.json", "/tmp/../unsafe.json", "/tmp/report.txt", "/"] {
            XCTAssertThrowsError(try Benchmark.requestedReportOutput(environment: [
                Benchmark.reportOutputEnvironmentKey: invalid,
            ]), invalid)
        }
        let oversized = "/tmp/" + String(repeating: "a", count: SafetyLimits.maxPathUTF8Bytes) + ".json"
        XCTAssertThrowsError(try Benchmark.requestedReportOutput(environment: [
            Benchmark.reportOutputEnvironmentKey: oversized,
        ]))
        let production = Config.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("benchmark.json")
        XCTAssertThrowsError(try Benchmark.requestedReportOutput(environment: [
            Benchmark.reportOutputEnvironmentKey: production.path,
        ]))

        let directory = try secureTemporaryDirectory()
        let target = directory.appendingPathComponent("target.json")
        try Data("preserve".utf8).write(to: target)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let minimal = Data("{}".utf8)
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: link, protectedDirectories: []
        ))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))

        let fifo = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: fifo, protectedDirectories: []
        ))
    }

    func testReportOutputRejectsAncestorSymlinkAndProtectedDescriptorAncestry() throws {
        let root = try secureTemporaryDirectory()
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("ancestor-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let minimal = Data("{}".utf8)
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: alias.appendingPathComponent("report.json"), protectedDirectories: []
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: physical.appendingPathComponent("report.json").path
        ))

        let production = root.appendingPathComponent("ProductionState", isDirectory: true)
        let reports = production.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let protectedOutput = reports.appendingPathComponent("benchmark.json")
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: protectedOutput, protectedDirectories: [production]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedOutput.path))
    }

    func testReportOutputRejectsCaseAndNFCAliasesOfProtectedDirectories() throws {
        let root = try secureTemporaryDirectory()
        let minimal = Data("{}".utf8)

        let caseProtected = root.appendingPathComponent("CaseSensitiveState", isDirectory: true)
        try FileManager.default.createDirectory(at: caseProtected, withIntermediateDirectories: false)
        let caseAliasOutput = root.appendingPathComponent("casesensitivestate", isDirectory: true)
            .appendingPathComponent("case.json")
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: caseAliasOutput, protectedDirectories: [caseProtected]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: caseAliasOutput.path))

        let composed = root.appendingPathComponent("Caf\u{00E9}State", isDirectory: true)
        try FileManager.default.createDirectory(at: composed, withIntermediateDirectories: false)
        let decomposedOutput = root.appendingPathComponent("Cafe\u{0301}State", isDirectory: true)
            .appendingPathComponent("nfc.json")
        XCTAssertThrowsError(try Benchmark.writeReportDataAtomically(
            minimal, to: decomposedOutput, protectedDirectories: [composed]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: decomposedOutput.path))
    }

    func testReportOutputWritesUsingValidatedDirectoryDescriptor() throws {
        let directory = try secureTemporaryDirectory()
        let output = directory.appendingPathComponent("descriptor.json")
        let bytes = Data("{\"schema\":1}".utf8)
        try Benchmark.writeReportDataAtomically(bytes, to: output, protectedDirectories: [])
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        var information = stat()
        XCTAssertEqual(lstat(output.path, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(0o777), mode_t(0o600),
                       "report output must use POSIX mode 0600")
    }

    func testSupersessionSubmitsOlderRequestBeforeNewest() async throws {
        let fixture = Benchmark.makeFixture(itemCount: 10_000)
        let history = Benchmark.makeDeterministicHistory(for: fixture.store)
        let engine = SearchEngine(frecency: history.store)
        let measurement = try await Benchmark.measureSupersession(engine: engine, store: fixture.store,
                                                                  cfg: .default, repetitions: 10)
        XCTAssertEqual(measurement.newestCancelled, 0,
                       "the benchmark itself must not reverse task submission and cancel the nominal newest request")
        XCTAssertEqual(measurement.newest.count, 10)
        XCTAssertEqual(measurement.pair.count, 10)
    }
}
