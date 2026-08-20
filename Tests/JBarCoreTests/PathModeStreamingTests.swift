import Darwin
import Foundation
import XCTest
@testable import JBarCore

/// Regression and scale tests for the streaming, bounded, cancellable path-mode pipeline.
final class PathModeStreamingTests: XCTestCase {
    private struct LatencyDistribution {
        let p50: Double
        let p95: Double
        let maximum: Double
    }

    private func temporaryDirectory(_ tag: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jbar-path-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func createEmptyFile(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw NSError(domain: "PathModeStreamingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.path)"])
        }
    }

    private func elapsedMilliseconds(_ operation: () async -> SearchResponse) async -> (SearchResponse, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let response = await operation()
        return (response, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func distribution(_ samples: [Double]) -> LatencyDistribution {
        let sorted = samples.sorted()
        func nearestRank(_ percentile: Double) -> Double {
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }
        return LatencyDistribution(p50: nearestRank(0.50), p95: nearestRank(0.95), maximum: sorted.last!)
    }

    /// The pre-#6 implementation, retained in tests only so release measurements compare identical filesystem,
    /// filtering, metadata, ordering, row construction and process state. It intentionally materialises every URL
    /// and every matching PathEntry; production must never call it.
    private func materializedBaseline(base: String, filter: String, cap: Int) -> (rows: [ResultRow], total: Int) {
        let url = URL(fileURLWithPath: base, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []
        ) else { return ([], 0) }
        let dotFilter = SafetyLimits.hasDotPrefix(filter)
        let filterAnalysis: SearchString? = filter.isEmpty ? nil : TextAnalyzer.analyze(filter)
        let scratch = ScorerScratch()
        var entries: [PathEntry] = []
        entries.reserveCapacity(urls.count)
        for entryURL in urls {
            let name = entryURL.lastPathComponent
            if SafetyLimits.hasDotPrefix(name) != dotFilter { continue }
            let values = try? entryURL.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            var entry = PathEntry(name: name, isDirectory: isDirectory, isPackage: isPackage,
                                  isFolder: isDirectory && !isPackage, group: 0, score: 0, analyzed: nil)
            if let filterAnalysis {
                let analysis = TextAnalyzer.analyze(name)
                if analysis.folded.starts(with: filterAnalysis.folded) {
                    entry.group = 0
                } else if let match = Scorer.score(query: filterAnalysis.folded[...], text: analysis.folded[...],
                                                   bonus: analysis.bonus[...], scratch: scratch) {
                    entry.group = 1
                    entry.score = Int(match.score)
                } else {
                    continue
                }
                entry.analyzed = analysis
            }
            entries.append(entry)
        }
        entries.sort(by: SearchEngine.pathOrder)
        let rows = entries.prefix(cap).map { entry -> ResultRow in
            let path = base + "/" + entry.name
            var offsets: [Int] = []
            if let filterAnalysis, let analysis = entry.analyzed {
                offsets = entry.group == 0
                    ? Array(0..<filterAnalysis.folded.count)
                    : Scorer.matchPositions(query: filterAnalysis.folded[...], text: analysis.folded[...],
                                            bonus: analysis.bonus[...])
            }
            return SearchEngine.row(forPath: path, isDirectory: entry.isDirectory,
                                    isPackage: entry.isPackage, home: NSHomeDirectory(),
                                    matchedByteOffsets: offsets, score: entry.score)
        }
        return (Array(rows), entries.count)
    }

    func testEmptySingleMissingAndNonDirectoryCompleteness() async throws {
        let empty = try temporaryDirectory("empty")
        let engine = SearchEngine()

        let zero = await engine.search(empty.path + "/", limit: 8)
        XCTAssertTrue(zero.rows.isEmpty)
        XCTAssertEqual(zero.totalMatches, 0)
        XCTAssertTrue(zero.totalMatchesIsComplete, "a readable empty directory has an exact zero")
        XCTAssertEqual(zero.hasMoreResults, false)
        XCTAssertFalse(zero.cancelled)

        try createEmptyFile(empty.appendingPathComponent("only.txt"))
        let one = await engine.search(empty.path + "/", limit: 8)
        XCTAssertEqual(one.rows.map(\.name), ["only.txt"])
        XCTAssertEqual(one.totalMatches, 1)
        XCTAssertTrue(one.totalMatchesIsComplete)
        XCTAssertEqual(one.hasMoreResults, false)

        let missing = await engine.search(empty.appendingPathComponent("missing", isDirectory: true).path + "/", limit: 8)
        XCTAssertTrue(missing.rows.isEmpty)
        XCTAssertEqual(missing.totalMatches, 0)
        XCTAssertFalse(missing.totalMatchesIsComplete, "unavailable is not the same as an exact empty directory")
        XCTAssertNil(missing.hasMoreResults)

        let regularFile = await engine.search(empty.appendingPathComponent("only.txt").path + "/", limit: 8)
        XCTAssertTrue(regularFile.rows.isEmpty)
        XCTAssertFalse(regularFile.totalMatchesIsComplete)

        let noScan = await engine.search(empty.path + "/", limit: 0)
        XCTAssertTrue(noScan.rows.isEmpty)
        XCTAssertFalse(noScan.totalMatchesIsComplete, "limit zero intentionally avoids an otherwise unbounded count scan")

        let oversizedBase = "/" + String(repeating: "界", count: (SafetyLimits.maxPathUTF8Bytes / 3) + 1) + "/"
        let oversized = await engine.search(oversizedBase, limit: 8)
        XCTAssertTrue(oversized.rows.isEmpty)
        XCTAssertFalse(oversized.totalMatchesIsComplete)
    }

    func testUnreadableDirectoryIsSafeAndExplicitlyIncomplete() async throws {
        let parent = try temporaryDirectory("permission")
        let denied = parent.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try createEmptyFile(denied.appendingPathComponent("secret.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }

        let response = await SearchEngine().search(denied.path + "/", limit: 8)
        if geteuid() == 0 {
            // A root test runner legitimately bypasses POSIX mode bits; still require a safe, exact result.
            XCTAssertEqual(response.rows.map(\.name), ["secret.txt"])
            XCTAssertTrue(response.totalMatchesIsComplete)
        } else {
            XCTAssertTrue(response.rows.isEmpty)
            XCTAssertEqual(response.totalMatches, 0)
            XCTAssertFalse(response.totalMatchesIsComplete)
        }
        XCTAssertFalse(response.cancelled)
    }

    func testIndependentVisitAndTimeBudgetsReturnUsefulIncompleteResults() throws {
        let directory = try temporaryDirectory("budget")
        for index in 0..<10 {
            try createEmptyFile(directory.appendingPathComponent("item-\(index).txt"))
        }
        let counter = RequestCounter()
        let request = counter.next()
        let visited = SearchEngine.listDirectory(base: directory.path, filter: "", cap: 8,
                                                 home: NSHomeDirectory(), requestId: request,
                                                 counter: counter, visitLimit: 3, timeBudget: 3)
        XCTAssertEqual(visited.totalMatches, 3)
        XCTAssertEqual(visited.rows.count, 3)
        XCTAssertFalse(visited.totalMatchesIsComplete)
        XCTAssertFalse(visited.cancelled)

        let timedOut = SearchEngine.listDirectory(base: directory.path, filter: "", cap: 8,
                                                  home: NSHomeDirectory(), requestId: request,
                                                  counter: counter, visitLimit: 10,
                                                  timeBudget: 0)
        XCTAssertTrue(timedOut.rows.isEmpty)
        XCTAssertEqual(timedOut.totalMatches, 0)
        XCTAssertFalse(timedOut.totalMatchesIsComplete)
    }

    func testOneThousandEntriesCommonSelectiveFiltersAndCap() async throws {
        let directory = try temporaryDirectory("1k")
        let fm = FileManager.default
        for index in 0..<8 {
            try fm.createDirectory(at: directory.appendingPathComponent(String(format: "alpha-folder-%03d", index)),
                                   withIntermediateDirectories: false)
        }
        // Top-level path mode must not recursively enumerate a retained folder.
        try createEmptyFile(directory.appendingPathComponent("alpha-folder-000/nested-must-not-appear.txt"))
        for index in 0..<991 {
            try createEmptyFile(directory.appendingPathComponent(String(format: "alpha-item-%04d.txt", index)))
        }
        try createEmptyFile(directory.appendingPathComponent("unique-needle.dat"))
        try createEmptyFile(directory.appendingPathComponent(".hidden-path-entry"))

        let engine = SearchEngine()
        let capped = await engine.search(directory.path + "/", limit: 1)
        XCTAssertEqual(capped.totalMatches, 1_000)
        XCTAssertTrue(capped.totalMatchesIsComplete)
        XCTAssertEqual(capped.hasMoreResults, true)
        XCTAssertEqual(capped.rows.count, SearchEngine.pathModeRowMultiplier)
        XCTAssertTrue(capped.rows.allSatisfy { $0.kind == .folder }, "folders win within the unfiltered group")
        XCTAssertFalse(capped.rows.contains { $0.name == "nested-must-not-appear.txt" })

        let common = await engine.search(directory.path + "/alpha", limit: 8)
        XCTAssertEqual(common.totalMatches, 999)
        XCTAssertTrue(common.totalMatchesIsComplete)
        XCTAssertEqual(common.rows.count, 8 * SearchEngine.pathModeRowMultiplier)
        XCTAssertTrue(common.rows.prefix(8).allSatisfy { $0.kind == .folder })
        XCTAssertTrue(common.rows.allSatisfy { !$0.matchedByteOffsets.isEmpty })

        let selective = await engine.search(directory.path + "/unique-needle", limit: 8)
        XCTAssertEqual(selective.rows.map(\.name), ["unique-needle.dat"])
        XCTAssertEqual(selective.totalMatches, 1)
        XCTAssertTrue(selective.totalMatchesIsComplete)
        XCTAssertEqual(selective.hasMoreResults, false)

        let none = await engine.search(directory.path + "/definitely-absent", limit: 8)
        XCTAssertTrue(none.rows.isEmpty)
        XCTAssertEqual(none.totalMatches, 0)
        XCTAssertTrue(none.totalMatchesIsComplete)

        let hidden = await engine.search(directory.path + "/.", limit: 8)
        XCTAssertEqual(hidden.rows.map(\.name), [".hidden-path-entry"])
        XCTAssertEqual(hidden.totalMatches, 1)
        XCTAssertTrue(hidden.totalMatchesIsComplete)
    }

    func testPathTopKIsBoundedAndEquivalentToFullSort() {
        var all: [PathEntry] = []
        var heap = PathTopK(capacity: 17)
        for index in 0..<10_000 {
            let entry = PathEntry(name: String(format: "entry-%05d", 9_999 - index),
                                  isDirectory: index.isMultiple(of: 13), isPackage: false,
                                  isFolder: index.isMultiple(of: 13), group: index.isMultiple(of: 3) ? 0 : 1,
                                  score: index % 101, analyzed: nil)
            all.append(entry)
            heap.insert(entry)
            XCTAssertLessThanOrEqual(heap.items.count, 17)
        }
        let expected = all.sorted(by: SearchEngine.pathOrder).prefix(17).map(\.name)
        XCTAssertEqual(heap.items.sorted(by: SearchEngine.pathOrder).map(\.name), Array(expected))

        var zero = PathTopK(capacity: Int.min)
        zero.insert(all[0])
        XCTAssertTrue(zero.items.isEmpty)
        XCTAssertEqual(PathTopK(capacity: Int.max).capacity, SearchEngine.maxPathModeRows)
    }

    func testPathOrderingCompatibilityMatrix() {
        func entry(_ name: String, folder: Bool, group: Int, score: Int) -> PathEntry {
            PathEntry(name: name, isDirectory: folder, isPackage: false, isFolder: folder,
                      group: group, score: score, analyzed: nil)
        }

        // Prefix-before-fuzzy is the primary contract, even when the prefix is a file and the fuzzy hit a folder.
        XCTAssertTrue(SearchEngine.pathOrder(entry("prefix-file", folder: false, group: 0, score: 0),
                                             entry("fuzzy-folder", folder: true, group: 1, score: 10_000)))
        // In unfiltered/prefix results, folders precede files before Finder-style name order.
        XCTAssertTrue(SearchEngine.pathOrder(entry("z-folder", folder: true, group: 0, score: 0),
                                             entry("a-file", folder: false, group: 0, score: 0)))
        // Preserve the existing fuzzy contract: score first, with folders first only when scores tie.
        XCTAssertTrue(SearchEngine.pathOrder(entry("high-file", folder: false, group: 1, score: 20),
                                             entry("low-folder", folder: true, group: 1, score: 10)))
        XCTAssertTrue(SearchEngine.pathOrder(entry("z-folder", folder: true, group: 1, score: 10),
                                             entry("a-file", folder: false, group: 1, score: 10)))

        let names = ["file-10", "file-2", "File-2"].map {
            entry($0, folder: false, group: 0, score: 0)
        }.sorted(by: SearchEngine.pathOrder).map(\.name)
        for _ in 0..<20 {
            XCTAssertEqual(["File-2", "file-10", "file-2"].map {
                entry($0, folder: false, group: 0, score: 0)
            }.sorted(by: SearchEngine.pathOrder).map(\.name), names,
            "tie-breaking must not depend on enumeration order")
        }
    }

    private func makeTwentyThousandEntryDirectory() throws -> URL {
        let directory = try temporaryDirectory("20k")
        let fm = FileManager.default
        for index in 0..<20 {
            try fm.createDirectory(at: directory.appendingPathComponent(String(format: "item-folder-%03d", index)),
                                   withIntermediateDirectories: false)
        }
        for index in 0..<19_979 {
            try createEmptyFile(directory.appendingPathComponent(String(format: "item-%05d.txt", index)))
        }
        try createEmptyFile(directory.appendingPathComponent("unique-needle.dat"))
        return directory
    }

    func testTwentyThousandEntriesBoundedTotalsAndSupersessionSmoke() async throws {
        let directory = try makeTwentyThousandEntryDirectory()

        let engine = SearchEngine()
        let (common, commonMS) = await elapsedMilliseconds {
            await engine.search(directory.path + "/item", limit: 8)
        }
        XCTAssertEqual(common.totalMatches, 19_999)
        XCTAssertTrue(common.totalMatchesIsComplete)
        XCTAssertEqual(common.rows.count, 8 * SearchEngine.pathModeRowMultiplier)

        let maximumPage = await engine.search(directory.path + "/item", limit: Int.max)
        XCTAssertEqual(maximumPage.rows.count, SearchEngine.maxPathModeRows)
        XCTAssertEqual(maximumPage.totalMatches, 19_999)
        XCTAssertTrue(maximumPage.totalMatchesIsComplete)

        let (selective, selectiveMS) = await elapsedMilliseconds {
            await engine.search(directory.path + "/unique-needle", limit: 8)
        }
        XCTAssertEqual(selective.rows.map(\.name), ["unique-needle.dat"])
        XCTAssertEqual(selective.totalMatches, 1)
        XCTAssertTrue(selective.totalMatchesIsComplete)

        // This is a shared-runner smoke ceiling, not the release latency acceptance gate. The strict p50/p95
        // distribution and same-process legacy comparison live in the explicitly enabled benchmark below.
        #if DEBUG
        XCTAssertLessThan(commonMS, 15_000)
        XCTAssertLessThan(selectiveMS, 15_000)
        #else
        XCTAssertLessThan(commonMS, 3_000)
        XCTAssertLessThan(selectiveMS, 3_000)
        #endif

        let cancelEngine = SearchEngine()
        let baselineRequest = await cancelEngine.latestRequestId
        let supersededTask = Task {
            await cancelEngine.search(directory.path + "/item", limit: SafetyLimits.maxResults.upperBound)
        }
        var didStart = false
        for _ in 0..<10_000 {
            if await cancelEngine.latestRequestId > baselineRequest {
                didStart = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(didStart, "path scan should have entered the actor")
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        let latest = await cancelEngine.search("latest-query", limit: 8)
        let superseded = await supersededTask.value
        let cancellationMS = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000
        XCTAssertFalse(latest.cancelled)
        XCTAssertTrue(superseded.cancelled)
        XCTAssertTrue(superseded.rows.isEmpty)
        XCTAssertEqual(superseded.totalMatches, 0)
        XCTAssertFalse(superseded.totalMatchesIsComplete)
        XCTAssertNil(superseded.hasMoreResults)
        XCTAssertLessThan(cancellationMS, 2_000)
        print(String(format: "PATH SMOKE 20k: common %.2f ms | selective %.2f ms | cancel %.2f ms | retained %d/%d",
                     commonMS, selectiveMS, cancellationMS, common.rows.count, common.totalMatches))
    }

    /// Explicit isolated release gate:
    /// `JBAR_RUN_PATH_BENCHMARK=1 swift test -c release --filter PathModeStreamingTests/testPathModeTwentyThousandIsolatedReleaseBenchmark`
    ///
    /// It is skipped by the default suite because filesystem p95 is meaningless when other test workers/builds
    /// contend for the same volume. The default 20k smoke test above still protects correctness and cancellation.
    func testPathModeTwentyThousandIsolatedReleaseBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["JBAR_RUN_PATH_BENCHMARK"] == "1" else {
            throw XCTSkip("set JBAR_RUN_PATH_BENCHMARK=1 and run this test alone in release mode")
        }
        #if DEBUG
        throw XCTSkip("the strict path-mode latency gate must run with -c release")
        #else
        let directory = try makeTwentyThousandEntryDirectory()
        let engine = SearchEngine()
        let sampleCount = 10
        let common = await engine.search(directory.path + "/item", limit: 8)
        let selective = await engine.search(directory.path + "/unique-needle", limit: 8)
        XCTAssertEqual(common.totalMatches, 19_999)
        XCTAssertEqual(selective.totalMatches, 1)
        var commonSamples: [Double] = []
        var selectiveSamples: [Double] = []
        for _ in 0..<sampleCount {
            let (_, commonSample) = await elapsedMilliseconds {
                await engine.search(directory.path + "/item", limit: 8)
            }
            commonSamples.append(commonSample)
            let (_, selectiveSample) = await elapsedMilliseconds {
                await engine.search(directory.path + "/unique-needle", limit: 8)
            }
            selectiveSamples.append(selectiveSample)
        }
        let commonDistribution = distribution(commonSamples)
        let selectiveDistribution = distribution(selectiveSamples)
        XCTAssertLessThan(commonDistribution.p95, 750, "20k common-filter path p95 regressed")
        XCTAssertLessThan(selectiveDistribution.p95, 750, "20k selective path p95 regressed")

        var baselineCommon: [Double] = []
        var baselineSelective: [Double] = []
        for _ in 0..<sampleCount {
            var start = DispatchTime.now().uptimeNanoseconds
            let commonBaseline = materializedBaseline(base: directory.path, filter: "item", cap: 32)
            baselineCommon.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(commonBaseline.total, 19_999)
            XCTAssertEqual(commonBaseline.rows.map(\.path), common.rows.map(\.path))

            start = DispatchTime.now().uptimeNanoseconds
            let selectiveBaseline = materializedBaseline(base: directory.path, filter: "unique-needle", cap: 32)
            baselineSelective.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(selectiveBaseline.total, 1)
            XCTAssertEqual(selectiveBaseline.rows.map(\.path), selective.rows.map(\.path))
        }

        let legacyCommonDistribution = distribution(baselineCommon)
        let legacySelectiveDistribution = distribution(baselineSelective)
        let performanceReport = String(format:
            "PATH PERF 20k isolated (n=%d): streaming common p50 %.2f p95 %.2f max %.2f ms | selective p50 %.2f p95 %.2f max %.2f ms | retained %d/%d | materialized baseline common p50 %.2f p95 %.2f ms, selective p50 %.2f p95 %.2f ms",
            sampleCount,
            commonDistribution.p50, commonDistribution.p95, commonDistribution.maximum,
            selectiveDistribution.p50, selectiveDistribution.p95, selectiveDistribution.maximum,
            common.rows.count, common.totalMatches,
            legacyCommonDistribution.p50, legacyCommonDistribution.p95,
            legacySelectiveDistribution.p50, legacySelectiveDistribution.p95)
        print(performanceReport)

        let cancelEngine = SearchEngine()
        var cancellationSamples: [Double] = []
        for sample in 0..<sampleCount {
            let baselineRequest = await cancelEngine.latestRequestId
            let supersededTask = Task {
                await cancelEngine.search(directory.path + "/item", limit: SafetyLimits.maxResults.upperBound)
            }
            var didStart = false
            for _ in 0..<10_000 {
                if await cancelEngine.latestRequestId > baselineRequest {
                    didStart = true
                    break
                }
                await Task.yield()
            }
            XCTAssertTrue(didStart, "path scan sample \(sample) should have entered the actor")
            let cancelStart = DispatchTime.now().uptimeNanoseconds
            let latest = await cancelEngine.search("latest-query-\(sample)", limit: 8)
            let superseded = await supersededTask.value
            cancellationSamples.append(Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000)

            XCTAssertFalse(latest.cancelled)
            XCTAssertTrue(superseded.cancelled)
            XCTAssertTrue(superseded.rows.isEmpty)
            XCTAssertEqual(superseded.totalMatches, 0)
            XCTAssertFalse(superseded.totalMatchesIsComplete)
        }
        let cancellationDistribution = distribution(cancellationSamples)
        XCTAssertLessThan(cancellationDistribution.p95, 250,
                          "a superseded directory scan did not stop within the cancellation budget")
        print(String(format: "PATH CANCEL 20k (n=%d): p50 %.2f p95 %.2f max %.2f ms",
                     sampleCount, cancellationDistribution.p50,
                     cancellationDistribution.p95, cancellationDistribution.maximum))
        #endif
    }
}
