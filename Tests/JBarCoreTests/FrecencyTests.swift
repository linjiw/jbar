import XCTest
@testable import JBarCore

/// Tests for `FrecencyStore` (DESIGN.md §6.5): decay math, weights, boost formula, query picks,
/// eviction, prune, persistence round-trip, corrupt-file tolerance and thread safety.
final class FrecencyTests: XCTestCase {
    private var tempDir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 86_400

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-frecency-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
    }

    private func makeStore(name: String = "history.json", halfLife: TimeInterval = 7 * 86_400, maxEntries: Int = 500) -> FrecencyStore {
        FrecencyStore(fileURL: tempDir.appendingPathComponent(name), halfLife: halfLife, maxEntries: maxEntries)
    }

    // MARK: - Init / empty

    func testInitDoesNotTouchDiskAndStartsEmpty() {
        let s = makeStore()
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.queryPickCount, 0)
        XCTAssertEqual(s.boost(for: "/x", now: t0), 0)
        XCTAssertEqual(s.score(for: "/x", now: t0), 0)
        XCTAssertEqual(s.recents(limit: 10, now: t0), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL.path))
    }

    func testMaxEntriesClampedToAtLeastOne() {
        XCTAssertEqual(makeStore(maxEntries: 0).maxEntries, 1)
        XCTAssertEqual(makeStore(maxEntries: -5).maxEntries, 1)
        XCTAssertEqual(makeStore(maxEntries: 42).maxEntries, 42)
    }

    // MARK: - Record weights and decay

    func testRecordWeightOneWithoutQuery() {
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0), 1, accuracy: 1e-9)
        s.record(open: "/a", query: "", at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0), 2, accuracy: 1e-9)
        s.record(open: "/a", query: " x ", at: t0) // trimmed length 1 → w = 1
        XCTAssertEqual(s.score(for: "/a", now: t0), 3, accuracy: 1e-9)
    }

    func testRecordWeightTwoWithQueryOfTwoOrMoreChars() {
        let s = makeStore()
        s.record(open: "/a", query: "xc", at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0), 2, accuracy: 1e-9)
        s.record(open: "/a", query: "  xcode  ", at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0), 4, accuracy: 1e-9)
    }

    func testDecayHalvesAfterHalfLife() {
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0), 1, accuracy: 1e-9)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(week)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(2 * week)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(3.5 * 86_400)), pow(2, -0.5), accuracy: 1e-9)
    }

    func testDecayUsesConfiguredHalfLife() {
        let s = makeStore(halfLife: 100)
        s.record(open: "/a", query: nil, at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(100)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(300)), 0.125, accuracy: 1e-9)
    }

    func testRecordDecaysBeforeAdding() {
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0)                              // f = 1
        s.record(open: "/a", query: nil, at: t0.addingTimeInterval(week))     // f = 0.5 + 1 = 1.5
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(week)), 1.5, accuracy: 1e-9)
        s.record(open: "/a", query: "ab", at: t0.addingTimeInterval(2 * week)) // f = 0.75 + 2 = 2.75
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(2 * week)), 2.75, accuracy: 1e-9)
    }

    func testClockGoingBackwardsDoesNotInflate() {
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(-week)), 1, accuracy: 1e-9)
        s.record(open: "/a", query: nil, at: t0.addingTimeInterval(-week))
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(-week)), 2, accuracy: 1e-9)
    }

    func testNoDecayWhenHalfLifeNonPositive() {
        let s = makeStore(halfLife: 0)
        s.record(open: "/a", query: nil, at: t0)
        XCTAssertEqual(s.score(for: "/a", now: t0.addingTimeInterval(1_000 * week)), 1, accuracy: 1e-9)
    }

    func testEmptyPathIsIgnored() {
        let s = makeStore()
        s.record(open: "", query: "ab", at: t0)
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.queryPickCount, 0)
    }

    // MARK: - Boost formula

    func testBoostFormula() {
        let s = makeStore()
        s.record(open: "/one", query: nil, at: t0)                   // f = 1 → 16·log2(2) = 16
        for _ in 0..<3 { s.record(open: "/three", query: nil, at: t0) } // f = 3 → 16·log2(4) = 32
        for _ in 0..<15 { s.record(open: "/fifteen", query: nil, at: t0) } // f = 15 → 16·log2(16) = 64
        for _ in 0..<100 { s.record(open: "/hundred", query: nil, at: t0) } // f = 100 → capped 64
        XCTAssertEqual(s.boost(for: "/one", now: t0), 16)
        XCTAssertEqual(s.boost(for: "/three", now: t0), 32)
        XCTAssertEqual(s.boost(for: "/fifteen", now: t0), 64)
        XCTAssertEqual(s.boost(for: "/hundred", now: t0), 64)
        XCTAssertEqual(s.boost(for: "/unknown", now: t0), 0)
    }

    func testBoostDecaysOverTime() {
        let s = makeStore()
        for _ in 0..<3 { s.record(open: "/a", query: nil, at: t0) } // f = 3
        XCTAssertEqual(s.boost(for: "/a", now: t0), 32)
        // After a week f' = 1.5 → 16·log2(2.5) ≈ 21.15 → 21
        XCTAssertEqual(s.boost(for: "/a", now: t0.addingTimeInterval(week)), 21)
        // After 10 weeks f' ≈ 0.0029 → 16·log2(1.0029) ≈ 0.07 → 0
        XCTAssertEqual(s.boost(for: "/a", now: t0.addingTimeInterval(10 * week)), 0)
    }

    func testBoostHonoursCustomWeights() {
        var w = RankingWeights()
        w.frecencyScale = 10
        w.frecencyCap = 12
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0) // f = 1 → 10
        XCTAssertEqual(s.boost(for: "/a", now: t0, weights: w), 10)
        for _ in 0..<2 { s.record(open: "/a", query: nil, at: t0) } // f = 3 → 20 → cap 12
        XCTAssertEqual(s.boost(for: "/a", now: t0, weights: w), 12)
    }

    // MARK: - Query picks

    func testQueryPickBoost() {
        let s = makeStore()
        s.record(open: "/Applications/Xcode.app", query: "  Xc ", at: t0)
        XCTAssertEqual(s.queryPickBoost(query: "xc", path: "/Applications/Xcode.app"), 30)
        XCTAssertEqual(s.queryPickBoost(query: "XC", path: "/Applications/Xcode.app"), 30)
        XCTAssertEqual(s.queryPickBoost(query: " xc\n", path: "/Applications/Xcode.app"), 30)
        XCTAssertEqual(s.queryPickBoost(query: "xc", path: "/Applications/Other.app"), 0)
        XCTAssertEqual(s.queryPickBoost(query: "x", path: "/Applications/Xcode.app"), 0)
        XCTAssertEqual(s.queryPickBoost(query: "xco", path: "/Applications/Xcode.app"), 0)
        XCTAssertEqual(s.queryPickBoost(query: "", path: "/Applications/Xcode.app"), 0)
        var w = RankingWeights(); w.queryPick = 7
        XCTAssertEqual(s.queryPickBoost(query: "xc", path: "/Applications/Xcode.app", weights: w), 7)
    }

    func testQueryPickFoldsDiacriticsAndCase() {
        let s = makeStore()
        s.record(open: "/cafe", query: "Café", at: t0)
        XCTAssertEqual(s.queryPickBoost(query: "cafe", path: "/cafe"), 30)
        XCTAssertEqual(s.queryPickBoost(query: "CAFÉ", path: "/cafe"), 30)
    }

    func testQueryPickNotStoredForShortOrMissingQuery() {
        let s = makeStore()
        s.record(open: "/a", query: nil, at: t0)
        s.record(open: "/a", query: "x", at: t0)
        XCTAssertEqual(s.queryPickCount, 0)
    }

    func testQueryPickLastWins() {
        let s = makeStore()
        s.record(open: "/a", query: "ab", at: t0)
        s.record(open: "/b", query: "ab", at: t0)
        XCTAssertEqual(s.queryPickBoost(query: "ab", path: "/a"), 0)
        XCTAssertEqual(s.queryPickBoost(query: "ab", path: "/b"), 30)
        XCTAssertEqual(s.queryPickCount, 1)
    }

    func testQueryPicksCappedAt200LRU() {
        let s = makeStore(maxEntries: 1000)
        for i in 0..<200 { s.record(open: "/p\(i)", query: "q\(i)", at: t0) }
        XCTAssertEqual(s.queryPickCount, 200)
        XCTAssertEqual(s.queryPickBoost(query: "q0", path: "/p0"), 30)
        // Touch q0 again so it becomes the most recent; then add a new one → q1 (oldest) is evicted.
        s.record(open: "/p0", query: "q0", at: t0)
        s.record(open: "/pnew", query: "qnew", at: t0)
        XCTAssertEqual(s.queryPickCount, 200)
        XCTAssertEqual(s.queryPickBoost(query: "q0", path: "/p0"), 30)
        XCTAssertEqual(s.queryPickBoost(query: "q1", path: "/p1"), 0)
        XCTAssertEqual(s.queryPickBoost(query: "qnew", path: "/pnew"), 30)
    }

    // MARK: - Eviction

    func testEvictsLowestDecayedWhenOverMaxEntries() {
        let s = makeStore(maxEntries: 3)
        for _ in 0..<5 { s.record(open: "/big", query: nil, at: t0) }
        s.record(open: "/old", query: nil, at: t0.addingTimeInterval(-10 * week)) // decays to ~0
        s.record(open: "/mid", query: "ab", at: t0)
        XCTAssertEqual(s.count, 3)
        s.record(open: "/new", query: nil, at: t0) // 4 > 3 → evict /old (lowest decayed f)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.score(for: "/old", now: t0), 0)
        XCTAssertGreaterThan(s.score(for: "/big", now: t0), 0)
        XCTAssertGreaterThan(s.score(for: "/mid", now: t0), 0)
        XCTAssertGreaterThan(s.score(for: "/new", now: t0), 0)
    }

    func testEvictionNeverRemovesTheJustRecordedEntryWhenOthersAreLower() {
        let s = makeStore(maxEntries: 1)
        s.record(open: "/a", query: nil, at: t0)
        s.record(open: "/b", query: "ab", at: t0) // f=2 beats /a f=1
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.recents(limit: 5, now: t0), ["/b"])
    }

    // MARK: - Recents and prune

    func testRecentsSortedByDecayedFrecency() {
        let s = makeStore()
        s.record(open: "/low", query: nil, at: t0.addingTimeInterval(-3 * week))
        for _ in 0..<2 { s.record(open: "/high", query: nil, at: t0) }
        s.record(open: "/mid", query: nil, at: t0)
        XCTAssertEqual(s.recents(limit: 10, now: t0), ["/high", "/mid", "/low"])
        XCTAssertEqual(s.recents(limit: 2, now: t0), ["/high", "/mid"])
        XCTAssertEqual(s.recents(limit: 0, now: t0), [])
        XCTAssertEqual(s.recents(limit: -1, now: t0), [])
    }

    func testRecentsTieBreaksByPath() {
        let s = makeStore()
        s.record(open: "/b", query: nil, at: t0)
        s.record(open: "/a", query: nil, at: t0)
        s.record(open: "/c", query: nil, at: t0)
        XCTAssertEqual(s.recents(limit: 3, now: t0), ["/a", "/b", "/c"])
    }

    func testPruneRemovesMissingAndTheirQueryPicks() {
        let s = makeStore()
        s.record(open: "/keep", query: "keep", at: t0)
        s.record(open: "/gone", query: "gone", at: t0)
        s.record(open: "/gone2", query: nil, at: t0)
        s.prune { $0 == "/keep" }
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.recents(limit: 5, now: t0), ["/keep"])
        XCTAssertEqual(s.queryPickBoost(query: "keep", path: "/keep"), 30)
        XCTAssertEqual(s.queryPickBoost(query: "gone", path: "/gone"), 0)
        XCTAssertEqual(s.queryPickCount, 1)
    }

    func testPruneWithNothingMissingIsNoop() {
        let s = makeStore()
        s.record(open: "/a", query: "aa", at: t0)
        s.prune { _ in true }
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.queryPickCount, 1)
    }

    // MARK: - Persistence

    func testSaveLoadRoundTripCreatesParentDirectory() {
        let nested = tempDir.appendingPathComponent("deep/er/history.json")
        let s = FrecencyStore(fileURL: nested)
        s.record(open: "/a", query: "aa", at: t0)
        for _ in 0..<3 { s.record(open: "/b", query: nil, at: t0.addingTimeInterval(-week)) }
        s.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))

        let s2 = FrecencyStore(fileURL: nested)
        s2.load()
        XCTAssertEqual(s2.count, 2)
        XCTAssertEqual(s2.score(for: "/a", now: t0), 2, accuracy: 1e-6)
        XCTAssertEqual(s2.score(for: "/b", now: t0.addingTimeInterval(-week)), 3, accuracy: 1e-6)
        XCTAssertEqual(s2.score(for: "/b", now: t0), 1.5, accuracy: 1e-6)   // `last` survived the round trip
        XCTAssertEqual(s2.queryPickBoost(query: "aa", path: "/a"), 30)
        XCTAssertEqual(s2.recents(limit: 5, now: t0), ["/a", "/b"])
    }

    func testSavedFileHasDocumentedShape() throws {
        let s = makeStore()
        s.record(open: "/a", query: "aa", at: t0)
        s.save()
        let data = try Data(contentsOf: s.fileURL)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["version"] as? Int, 1)
        let entries = try XCTUnwrap(obj["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["path"] as? String, "/a")
        XCTAssertEqual(entries[0]["f"] as? Double, 2)
        XCTAssertEqual(try XCTUnwrap(entries[0]["last"] as? Double), t0.timeIntervalSince1970, accuracy: 1e-3)
        XCTAssertEqual(obj["queryPicks"] as? [String: String], ["aa": "/a"])
    }

    func testLoadMissingFileStartsEmpty() {
        let s = makeStore(name: "does-not-exist.json")
        s.record(open: "/stale", query: nil, at: t0)
        s.load()
        XCTAssertEqual(s.count, 0)
    }

    func testLoadCorruptFileStartsEmptyWithoutCrash() throws {
        let url = tempDir.appendingPathComponent("history.json")
        try Data("{ this is not json".utf8).write(to: url)
        let s = FrecencyStore(fileURL: url)
        s.record(open: "/stale", query: nil, at: t0)
        s.load()
        XCTAssertEqual(s.count, 0)
        // Still usable afterwards and can overwrite the corrupt file.
        s.record(open: "/a", query: nil, at: t0)
        s.save()
        let s2 = FrecencyStore(fileURL: url); s2.load()
        XCTAssertEqual(s2.count, 1)
    }

    func testLoadWrongShapeAndWrongVersionStartEmpty() throws {
        let url = tempDir.appendingPathComponent("history.json")
        try Data(#"{"version":1,"entries":"nope"}"#.utf8).write(to: url)
        let s = FrecencyStore(fileURL: url); s.load()
        XCTAssertEqual(s.count, 0)
        try Data(#"{"version":99,"entries":[{"path":"/a","f":1,"last":0}],"queryPicks":{}}"#.utf8).write(to: url)
        s.load()
        XCTAssertEqual(s.count, 0)
        try Data().write(to: url) // empty file
        s.load()
        XCTAssertEqual(s.count, 0)
    }

    func testLoadSanitizesBadEntriesAndClampsToMaxEntries() throws {
        let url = tempDir.appendingPathComponent("history.json")
        let json = #"""
        {"version":1,"entries":[
          {"path":"/a","f":5,"last":0},
          {"path":"/a","f":7,"last":0},
          {"path":"","f":9,"last":0},
          {"path":"/neg","f":-1,"last":0},
          {"path":"/b","f":1,"last":0},
          {"path":"/c","f":2,"last":0}
        ],"queryPicks":{"":"/a","aa":"","bb":"/b"}}
        """#
        try Data(json.utf8).write(to: url)
        let s = FrecencyStore(fileURL: url, halfLife: 0, maxEntries: 2)
        s.load()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.recents(limit: 5, now: t0), ["/a", "/c"])      // /a keeps the larger duplicate (7)
        XCTAssertEqual(s.score(for: "/a", now: t0), 7, accuracy: 1e-9)
        XCTAssertEqual(s.queryPickCount, 1)
        XCTAssertEqual(s.queryPickBoost(query: "bb", path: "/b"), 30)
    }

    func testSaveToUnwritableLocationDoesNotCrash() {
        // A path under a regular file cannot be created as a directory.
        let blocker = tempDir.appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        let s = FrecencyStore(fileURL: blocker.appendingPathComponent("sub/history.json"))
        s.record(open: "/a", query: nil, at: t0)
        s.save() // logs, no throw
        XCTAssertEqual(s.count, 1)
    }

    func testSavePerformanceFor500Entries() {
        let s = makeStore()
        for i in 0..<500 { s.record(open: "/Users/me/Documents/folder\(i % 17)/file-\(i).txt", query: "q\(i % 50)", at: t0) }
        XCTAssertEqual(s.count, 500)
        s.save() // warm-up
        let iterations = 20
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { s.save() }
        let perSaveMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations)
        print("FrecencyStore.save() 500 entries: \(String(format: "%.3f", perSaveMs)) ms/save")
        // Spec target is < 2 ms in release; debug builds are several times slower, so assert a loose bound.
        XCTAssertLessThan(perSaveMs, 25)
        let s2 = makeStore(); s2.load()
        XCTAssertEqual(s2.count, 500)
    }

    // MARK: - Thread safety

    func testConcurrentRecordFromEightThreadsDoesNotCrash() {
        let s = makeStore(maxEntries: 100)
        let perThread = 500
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<perThread {
                let path = "/p\(i % 150)"
                s.record(open: path, query: i % 3 == 0 ? "q\(i % 40)" : nil, at: t0.addingTimeInterval(Double(i)))
                _ = s.boost(for: path, now: t0.addingTimeInterval(Double(i)))
                _ = s.queryPickBoost(query: "q\(i % 40)", path: path)
                if i % 100 == 0 { _ = s.recents(limit: 10, now: t0); s.save() }
                if t == 0 && i % 250 == 0 { s.prune { _ in true } }
            }
        }
        XCTAssertLessThanOrEqual(s.count, 100)
        XCTAssertGreaterThan(s.count, 0)
        XCTAssertLessThanOrEqual(s.queryPickCount, FrecencyStore.maxQueryPicks)
        // Total mass conservation is not testable under eviction, but the store must remain consistent and loadable.
        s.save()
        let s2 = makeStore(maxEntries: 100); s2.load()
        XCTAssertEqual(s2.count, s.count)
    }

    func testConcurrentRecordWithoutEvictionAccumulatesAllWeight() {
        let s = makeStore(halfLife: 0, maxEntries: 10_000)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1000 { s.record(open: "/same", query: nil, at: t0) }
        }
        XCTAssertEqual(s.score(for: "/same", now: t0), 8000, accuracy: 1e-6)
        XCTAssertEqual(s.count, 1)
    }
}
