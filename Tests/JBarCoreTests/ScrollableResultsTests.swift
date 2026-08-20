import XCTest
@testable import JBarCore

/// A search returns `Config.maxResults` (40) rows so the user can scroll past the ~8 that fit on screen.
/// The rows that were already visible must not move when the pool grows — these tests pin that invariant,
/// plus the config plumbing for `maxResults` / `visibleRows`.
final class ScrollableResultsTests: XCTestCase {

    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// Build an ordered candidate list of `apps` app rows and `files` non-app rows, interleaved by score.
    private func ordered(apps: Int, files: Int, seed: UInt64) -> (items: [RankedItem], isApp: (Int) -> Bool) {
        var rng = RNG(s: seed)
        var items: [RankedItem] = []
        var appIndices = Set<Int>()
        for i in 0..<(apps + files) {
            if i < apps { appIndices.insert(i) }
            items.append(RankedItem(itemIndex: i, tier: 2, finalScore: 1000 - i * 3 - rng.below(2),
                                    nameLength: 8 + rng.below(20), firstMatch: rng.below(4)))
        }
        items = Ranking.order(items)
        return (items, { appIndices.contains($0) })
    }

    /// The core guarantee: growing `maxResults` only appends rows — the prefix a user already sees is identical.
    func testGrowingTheResultPoolDoesNotReorderVisibleRows() {
        for seed in UInt64(1)...40 {
            var rng = RNG(s: seed &* 7)
            let apps = rng.below(14), files = rng.below(60)
            guard apps + files > 0 else { continue }
            let (items, isApp) = ordered(apps: apps, files: files, seed: seed)
            for cap in [0, 3, 5, 8] {
                let small = Ranking.group(items, maxResults: 8, appsFirstCap: cap, isApp: isApp)
                let large = Ranking.group(items, maxResults: 40, appsFirstCap: cap, isApp: isApp)
                XCTAssertGreaterThanOrEqual(large.count, small.count,
                                            "a bigger pool can never return fewer rows (apps=\(apps) files=\(files) cap=\(cap))")
                XCTAssertEqual(small.map(\.itemIndex), Array(large.prefix(small.count)).map(\.itemIndex),
                               "visible rows moved when the pool grew (seed=\(seed) apps=\(apps) files=\(files) cap=\(cap))")
            }
        }
    }

    /// The pool is bounded by what the ranker actually had, and never exceeds `maxResults`.
    func testGroupNeverExceedsMaxResults() {
        let (items, isApp) = ordered(apps: 9, files: 80, seed: 99)
        for max in [1, 5, 8, 40, 200] {
            let g = Ranking.group(items, maxResults: max, appsFirstCap: 5, isApp: isApp)
            XCTAssertLessThanOrEqual(g.count, max)
            XCTAssertLessThanOrEqual(g.count, items.count)
        }
    }

    /// With more results than fit, apps still lead and the cap still applies to the visible portion.
    func testAppsStillLeadWithALargePool() {
        let (items, isApp) = ordered(apps: 9, files: 80, seed: 7)
        let g = Ranking.group(items, maxResults: 40, appsFirstCap: 5, isApp: isApp)
        let firstFive = g.prefix(5).map(\.itemIndex)
        XCTAssertTrue(firstFive.allSatisfy(isApp), "apps-first grouping must survive a large pool: \(firstFive)")
        XCTAssertFalse(isApp(g[5].itemIndex), "the app group is capped at appsFirstCap before files start")
    }

    // MARK: - Config plumbing

    func testConfigDefaultsGiveSomethingToScroll() {
        let c = Config.default
        XCTAssertEqual(c.visibleRows, 8)
        XCTAssertEqual(c.maxResults, 40)
        XCTAssertGreaterThan(c.maxResults, c.visibleRows,
                             "maxResults must exceed visibleRows or there is never anything to scroll to")
    }

    func testVisibleRowsRoundTripsAndDefaultsWhenAbsent() throws {
        // Present in JSON → decoded.
        let json = #"{"visibleRows": 5, "maxResults": 12}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(c.visibleRows, 5)
        XCTAssertEqual(c.maxResults, 12)
        // Absent → default (an old config file keeps working).
        let old = #"{"hotkey": "option+space"}"#.data(using: .utf8)!
        let c2 = try JSONDecoder().decode(Config.self, from: old)
        XCTAssertEqual(c2.visibleRows, Config.default.visibleRows)
        XCTAssertEqual(c2.maxResults, Config.default.maxResults)
        // Encode → decode round-trip.
        var c3 = Config.default
        c3.visibleRows = 3
        c3.maxResults = 99
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c3))
        XCTAssertEqual(back.visibleRows, 3)
        XCTAssertEqual(back.maxResults, 99)
    }
}

/// Migration of configs written before `visibleRows` existed, when `maxResults` meant "rows shown".
final class ConfigMigrationTests: XCTestCase {
    func testLegacyMaxResultsBecomesVisibleRows() throws {
        // A config written by an older build: maxResults present, visibleRows absent.
        let legacy = #"{"hotkey":"option+space","maxResults":8}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: legacy)
        XCTAssertEqual(c.visibleRows, 8, "the old 'rows shown' value must carry over to visibleRows")
        XCTAssertEqual(c.maxResults, Config.default.maxResults, "the pool takes the new default so scrolling works")
        XCTAssertGreaterThan(c.maxResults, c.visibleRows)
    }

    func testLegacyLargeMaxResultsIsNeverShrunk() throws {
        // Someone who asked for 60 rows should still get at least 60 results.
        let legacy = #"{"maxResults":60}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: legacy)
        XCTAssertEqual(c.visibleRows, 60)
        XCTAssertGreaterThanOrEqual(c.maxResults, 60)
    }

    func testExplicitVisibleRowsDisablesMigration() throws {
        // Both keys present → take them at face value, no reinterpretation.
        let modern = #"{"maxResults":12,"visibleRows":6}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: modern)
        XCTAssertEqual(c.maxResults, 12)
        XCTAssertEqual(c.visibleRows, 6)
    }

    func testEmptyConfigTakesDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(c.maxResults, Config.default.maxResults)
        XCTAssertEqual(c.visibleRows, Config.default.visibleRows)
    }
}
