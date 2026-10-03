import XCTest
@testable import JBarCore

final class SearchEngineCacheTests: XCTestCase {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func store(count: Int = 340, generation: UInt64 = 1) -> IndexStore {
        let builder = IndexBuilder()
        let root = builder.addRoot("/cache-fixture")
        for index in 0..<count {
            let name = String(format: "report-%03d.txt", index)
            builder.addItem(dir: root, name: name, analyzed: TextAnalyzer.analyze(name),
                            kind: .document, flags: [],
                            mtime: Self.now.addingTimeInterval(-Ranking.day + 1), depth: 1, ext: "txt")
        }
        return builder.build(generation: generation)
    }

    private func engine(store: IndexStore, history: FrecencyStore? = nil,
                        weights: RankingWeights = .default, home: String = "/cache-fixture") async -> SearchEngine {
        let engine = SearchEngine(weights: weights, frecency: history)
        await engine.setHome(home)
        await engine.update(store: store)
        return engine
    }

    func testIdenticalQueryReusesOnlyStageOneWithinIntegerSecond() async {
        let store = store()
        let engine = await engine(store: store)
        let first = await engine.search("report", limit: 500, now: Self.now.addingTimeInterval(0.1))
        let observer = SearchScanWorkObserver()
        await engine.setScanWorkObserver(observer)
        await engine.setHome("/another-home")
        let repeated = await engine.search("report", limit: 64, appsFirstCap: 0,
                                           now: Self.now.addingTimeInterval(0.9))
        let fresh = await self.engine(store: store, home: "/another-home")
            .search("report", limit: 64, appsFirstCap: 0, now: Self.now.addingTimeInterval(0.9))
        XCTAssertEqual(repeated.rows, fresh.rows)
        XCTAssertEqual(repeated.totalMatches, first.totalMatches)
        XCTAssertTrue(repeated.totalMatchesIsComplete)
        XCTAssertGreaterThan(repeated.requestId, first.requestId)
        XCTAssertEqual(observer.snapshot, SearchScanWork(), "repeated queries must skip all candidate scans")
        XCTAssertEqual(repeated.rows.count, 64)
        XCTAssertEqual(repeated.rows.first?.parentDisplay, "/cache-fixture")
    }

    func testLargerResultLimitGrowsCachedWindowAndReturnsAllRequestedRows() async {
        let store = store(count: 700)
        let engine = await engine(store: store)
        _ = await engine.search("report", limit: 8, now: Self.now)
        let growObserver = SearchScanWorkObserver()
        await engine.setScanWorkObserver(growObserver)
        let grown = await engine.search("report", limit: 500, now: Self.now)
        let fresh = await self.engine(store: store).search("report", limit: 500, now: Self.now)
        XCTAssertEqual(grown.rows.count, 500)
        XCTAssertEqual(grown.rows, fresh.rows)
        XCTAssertEqual(grown.totalMatches, 700)
        XCTAssertGreaterThan(growObserver.snapshot.visitedCandidates, 0)
        let reuseObserver = SearchScanWorkObserver()
        await engine.setScanWorkObserver(reuseObserver)
        let reused = await engine.search("report", limit: 500, now: Self.now)
        XCTAssertEqual(reused.rows, grown.rows)
        XCTAssertEqual(reuseObserver.snapshot, SearchScanWork())
    }

    func testRepeatedQueryImmediatelyReflectsMutableHistory() async {
        let store = store()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let history = FrecencyStore(fileURL: repository.appendingPathComponent(".build/search-tests/history-unused.json"))
        let engine = await engine(store: store, history: history)
        let first = await engine.search("report", now: Self.now)
        let picked = store.path(of: 20)
        XCTAssertNotEqual(first.rows.first?.path, picked)
        history.record(open: picked, query: "report", at: Self.now)
        let observer = SearchScanWorkObserver()
        await engine.setScanWorkObserver(observer)
        let repeated = await engine.search("report", now: Self.now.addingTimeInterval(0.5))
        let fresh = await self.engine(store: store, history: history)
            .search("report", now: Self.now.addingTimeInterval(0.5))
        XCTAssertEqual(repeated.rows.first?.path, picked)
        XCTAssertEqual(repeated.rows, fresh.rows)
        XCTAssertEqual(observer.snapshot, SearchScanWork())
        history.clear()
        let cleared = await engine.search("report", now: Self.now.addingTimeInterval(0.6))
        XCTAssertEqual(cleared.rows, first.rows)
        XCTAssertEqual(observer.snapshot, SearchScanWork())
    }

    func testRecencyThresholdAndBackwardsClockInvalidateStageOne() async {
        let store = store()
        let engine = await engine(store: store)
        let before = await engine.search("report", now: Self.now.addingTimeInterval(0.9))
        for seconds in [1.0, 0.9] {
            let observer = SearchScanWorkObserver()
            await engine.setScanWorkObserver(observer)
            let date = Self.now.addingTimeInterval(seconds)
            let response = await engine.search("report", now: date)
            let fresh = await self.engine(store: store).search("report", now: date)
            XCTAssertEqual(response.rows, fresh.rows)
            XCTAssertEqual(response.totalMatches, fresh.totalMatches)
            XCTAssertGreaterThan(observer.snapshot.visitedCandidates, 0)
            if seconds == 1.0 {
                XCTAssertEqual(response.rows.first?.score, (before.rows.first?.score ?? 0) - 4)
            }
        }
    }

    func testWeightsAndSameGenerationStoreReplacementInvalidateStageOne() async {
        let original = store()
        let engine = await engine(store: original)
        _ = await engine.search("report", now: Self.now)
        var weights = RankingWeights.default
        weights.typeDocument += 100
        await engine.setWeights(weights)
        let observer = SearchScanWorkObserver()
        await engine.setScanWorkObserver(observer)
        let changedWeights = await engine.search("report", now: Self.now)
        let fresh = await self.engine(store: original, weights: weights).search("report", now: Self.now)
        XCTAssertEqual(changedWeights.rows, fresh.rows)
        XCTAssertGreaterThan(observer.snapshot.visitedCandidates, 0)

        let replacement = store(count: 341)
        await engine.update(store: replacement)
        let replaced = await engine.search("report", now: Self.now)
        XCTAssertEqual(replaced.totalMatches, 341)
    }

    func testExtensionOnlyCacheRebuildsRowsForChangedLimitAndTime() async {
        let store = store()
        let engine = await engine(store: store)
        let first = await engine.search(".txt", limit: 8, now: Self.now)
        let repeated = await engine.search(".txt", limit: 32, now: Self.now.addingTimeInterval(0.5))
        let fresh = await self.engine(store: store).search(".txt", limit: 32, now: Self.now.addingTimeInterval(0.5))
        XCTAssertEqual(repeated.rows, fresh.rows)
        XCTAssertEqual(repeated.rows.count, 32)
        XCTAssertEqual(repeated.totalMatches, first.totalMatches)
        let nextSecond = await engine.search(".txt", now: Self.now.addingTimeInterval(1))
        XCTAssertEqual(nextSecond.rows.first?.score, (first.rows.first?.score ?? 0) - 4)
    }
}
