import XCTest
@testable import JBarCore

/// Golden tests for `Ranking` (DESIGN.md §6.5). Hand-built `MatchFacts`; no scorer involved.
final class RankingTests: XCTestCase {
    private let w = RankingWeights.default
    /// Fixed "now" so recency math is deterministic: 2026-08-19 12:00:00 UTC-ish (seconds since 2001).
    private let now = Date(timeIntervalSinceReferenceDate: 808_000_000)
    private let day: TimeInterval = 86_400

    /// mtime (seconds since 2001) for an item modified `age` seconds before `now`.
    private func mtime(age: TimeInterval) -> UInt32 {
        UInt32(now.timeIntervalSinceReferenceDate - age)
    }

    /// Shorthand for `finalScore` with the common defaults.
    private func score(_ facts: MatchFacts, kind: ItemKind = .document, flags: ItemFlags = [], depth: Int = 0,
                       mtime: UInt32 = 0, frecency: Int = 0, queryPick: Int = 0) -> Int {
        Ranking.finalScore(facts: facts, kind: kind, flags: flags, depth: depth, mtime: mtime,
                           frecencyBoost: frecency, queryPickBoost: queryPick, now: now, weights: w)
    }

    // MARK: - Tiers

    func testTierExactAppIsZero() {
        XCTAssertEqual(Ranking.tier(facts: MatchFacts(textScore: 10, exactName: true), kind: .app), Tier.exactApp)
        XCTAssertEqual(Ranking.tier(facts: MatchFacts(textScore: 10, exactName: true, prefixName: true), kind: .app), Tier.exactApp)
    }

    func testTierPrefixAppIsOne() {
        XCTAssertEqual(Ranking.tier(facts: MatchFacts(textScore: 10, prefixName: true), kind: .app), Tier.prefixApp)
    }

    func testTierOtherForFuzzyAppAndAllFiles() {
        XCTAssertEqual(Ranking.tier(facts: MatchFacts(textScore: 10), kind: .app), Tier.other)
        for kind in ItemKind.allCases where kind != .app {
            XCTAssertEqual(Ranking.tier(facts: MatchFacts(textScore: 999, exactName: true, prefixName: true), kind: kind), Tier.other,
                           "non-app kind \(kind) must never get an app tier")
        }
    }

    func testTierConstantsOrdering() {
        XCTAssertLessThan(Tier.exactApp, Tier.prefixApp)
        XCTAssertLessThan(Tier.prefixApp, Tier.other)
    }

    // MARK: - Type boost

    func testTypeBoostPerKind() {
        XCTAssertEqual(Ranking.typeBoost(kind: .app, flags: [], weights: w), 40)
        XCTAssertEqual(Ranking.typeBoost(kind: .folder, flags: [], weights: w), 12)
        XCTAssertEqual(Ranking.typeBoost(kind: .document, flags: [], weights: w), 8)
        XCTAssertEqual(Ranking.typeBoost(kind: .image, flags: [], weights: w), 4)
        XCTAssertEqual(Ranking.typeBoost(kind: .video, flags: [], weights: w), 4)
        XCTAssertEqual(Ranking.typeBoost(kind: .audio, flags: [], weights: w), 4)
        XCTAssertEqual(Ranking.typeBoost(kind: .code, flags: [], weights: w), 4)
        XCTAssertEqual(Ranking.typeBoost(kind: .archive, flags: [], weights: w), 0)
        XCTAssertEqual(Ranking.typeBoost(kind: .other, flags: [], weights: w), 0)
        XCTAssertEqual(Ranking.typeBoost(kind: .packageInternal, flags: [], weights: w), -20)
    }

    func testTypeBoostHiddenOverridesKind() {
        for kind in ItemKind.allCases {
            XCTAssertEqual(Ranking.typeBoost(kind: kind, flags: [.hidden], weights: w), -20, "hidden \(kind)")
        }
        // Other flags do not affect the type boost.
        XCTAssertEqual(Ranking.typeBoost(kind: .folder, flags: [.junk, .dotName, .cloud, .symlink, .package], weights: w), 12)
    }

    // MARK: - Recency

    func testRecencyUnknownMtimeIsZero() {
        XCTAssertEqual(Ranking.recencyBoost(mtime: 0, now: now, weights: w), 0)
    }

    func testRecencyThresholds() {
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 3600), now: now, weights: w), 12)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: day - 1), now: now, weights: w), 12)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: day), now: now, weights: w), 8)      // strict <
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 3 * day), now: now, weights: w), 8)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 7 * day), now: now, weights: w), 4)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 29 * day), now: now, weights: w), 4)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 30 * day), now: now, weights: w), 1)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 179 * day), now: now, weights: w), 1)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 180 * day), now: now, weights: w), 0)
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: 3650 * day), now: now, weights: w), 0)
    }

    func testRecencyFutureMtimeIsTreatedAsNow() {
        XCTAssertEqual(Ranking.recencyBoost(mtime: mtime(age: -10 * day), now: now, weights: w), 12)
    }

    // MARK: - Depth

    func testDepthPenaltyStartsAfterFreeDepthAndCaps() {
        XCTAssertEqual(Ranking.depthPenalty(depth: 0, weights: w), 0)
        XCTAssertEqual(Ranking.depthPenalty(depth: 2, weights: w), 0)
        XCTAssertEqual(Ranking.depthPenalty(depth: 4, weights: w), 0)
        XCTAssertEqual(Ranking.depthPenalty(depth: 5, weights: w), 2)
        XCTAssertEqual(Ranking.depthPenalty(depth: 7, weights: w), 6)
        XCTAssertEqual(Ranking.depthPenalty(depth: 10, weights: w), 12)
        XCTAssertEqual(Ranking.depthPenalty(depth: 11, weights: w), 12)
        XCTAssertEqual(Ranking.depthPenalty(depth: 200, weights: w), 12)
        XCTAssertEqual(Ranking.depthPenalty(depth: -3, weights: w), 0)
    }

    func testDepthPenaltyIsTotalForExtremePublicIntegers() {
        var extreme = RankingWeights()
        extreme.depthFree = Int.min
        extreme.depthPerLevel = Int.max
        extreme.depthCap = Int.max
        XCTAssertEqual(Ranking.depthPenalty(depth: Int.max, weights: extreme), Int.max)

        extreme.depthFree = Int.max
        XCTAssertEqual(Ranking.depthPenalty(depth: Int.min, weights: extreme), 0)

        extreme.depthFree = 0
        extreme.depthPerLevel = Int.min
        XCTAssertEqual(Ranking.depthPenalty(depth: Int.max, weights: extreme), 0,
                       "a negative public penalty is normalized instead of becoming a score bonus")
    }

    // MARK: - finalScore components

    func testFinalScoreBaselineIsTextPlusType() {
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .other), 100)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document), 108)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .folder), 112)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .app), 140)
    }

    func testInitialsBonusExactBeatsPrefixNeverBoth() {
        let base = score(MatchFacts(textScore: 50), kind: .app)
        XCTAssertEqual(score(MatchFacts(textScore: 50, initialsPrefix: true), kind: .app), base + 40)
        XCTAssertEqual(score(MatchFacts(textScore: 50, initialsExact: true), kind: .app), base + 60)
        XCTAssertEqual(score(MatchFacts(textScore: 50, initialsExact: true, initialsPrefix: true), kind: .app), base + 60)
    }

    func testInitialsMakeVscBeatRandomSubsequence() {
        // "vsc" → Visual Studio Code (fuzzy 72 + initials) must beat "vas Screaming…" (fuzzy 77).
        let vscode = score(MatchFacts(textScore: 72, initialsExact: true), kind: .app)
        let screaming = score(MatchFacts(textScore: 77), kind: .app)
        XCTAssertGreaterThan(vscode, screaming)
    }

    func testJunkAndDotPenalties() {
        let base = score(MatchFacts(textScore: 100), kind: .code)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .code, flags: [.junk]), base - 30)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .code, flags: [.dotName]), base - 10)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .code, flags: [.junk, .dotName]), base - 40)
    }

    func testJunkFileBelowNonJunkOfEqualTextScore() {
        let clean = score(MatchFacts(textScore: 120), kind: .document, depth: 3)
        let junk = score(MatchFacts(textScore: 120), kind: .document, flags: [.junk], depth: 3)
        XCTAssertLessThan(junk, clean)
    }

    func testDepthPenaltyAppliedToFilesAndFolders() {
        let base = score(MatchFacts(textScore: 100), kind: .document)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, depth: 4), base)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, depth: 6), base - 4)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, depth: 30), base - 12)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .folder, depth: 30), score(MatchFacts(textScore: 100), kind: .folder) - 12)
    }

    func testRecencyAppliedToFiles() {
        let stale = score(MatchFacts(textScore: 100), kind: .document, mtime: mtime(age: 400 * day))
        let fresh = score(MatchFacts(textScore: 100), kind: .document, mtime: mtime(age: 3600))
        XCTAssertEqual(fresh, stale + 12)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .folder, mtime: mtime(age: 10 * day)),
                       score(MatchFacts(textScore: 100), kind: .folder) + 4)
    }

    func testAppsGetNeitherRecencyNorDepth() {
        let base = score(MatchFacts(textScore: 100), kind: .app)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .app, depth: 40, mtime: mtime(age: 60)), base)
    }

    func testFrecencyBoostAddedAndCapped() {
        let base = score(MatchFacts(textScore: 100), kind: .document)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, frecency: 16), base + 16)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, frecency: 64), base + 64)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, frecency: 500), base + 64)
    }

    func testQueryPickBoostAdded() {
        let base = score(MatchFacts(textScore: 100), kind: .document)
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, queryPick: 30), base + 30)
    }

    func testRecentlyOpenedBeatsEquallyScoredStale() {
        let a = score(MatchFacts(textScore: 100), kind: .document, frecency: 16)
        let b = score(MatchFacts(textScore: 100), kind: .document, frecency: 0)
        XCTAssertGreaterThan(a, b)
    }

    func testExtWholeTokenPrefixAndPinyinBonuses() {
        let base = score(MatchFacts(textScore: 100), kind: .other)
        XCTAssertEqual(score(MatchFacts(textScore: 100, extMatched: true), kind: .other), base + 30)
        XCTAssertEqual(score(MatchFacts(textScore: 100, wholeTokenMatch: true), kind: .other), base + 20)
        XCTAssertEqual(score(MatchFacts(textScore: 100, prefixName: true), kind: .other), base + 30)
        XCTAssertEqual(score(MatchFacts(textScore: 100, exactName: true), kind: .other), base + 30)
        XCTAssertEqual(score(MatchFacts(textScore: 100, exactName: true, prefixName: true), kind: .other), base + 30, "prefix bonus applied once")
        XCTAssertEqual(score(MatchFacts(textScore: 100, pinyinInitialsExact: true), kind: .other), base + 20)
    }

    func testReportPdfBeatsNonPdf() {
        // "report pdf": the pdf gets the ext bonus and document type; a .txt named report gets only document type.
        let pdf = score(MatchFacts(textScore: 150, extMatched: true), kind: .document)
        let txt = score(MatchFacts(textScore: 150), kind: .document)
        XCTAssertGreaterThan(pdf, txt)
    }

    func testHiddenFileGetsNegativeTypeBoost() {
        XCTAssertEqual(score(MatchFacts(textScore: 100), kind: .document, flags: [.hidden, .dotName]), 100 - 20 - 10)
    }

    func testEverythingAtOnce() {
        let facts = MatchFacts(textScore: 100, exactName: true, prefixName: true, initialsExact: true, initialsPrefix: true,
                               extMatched: true, wholeTokenMatch: true, pinyinInitialsExact: true)
        // document: 100 + 60 + 8 + 64 (cap) + 30 + 12 (recency) − 6 (depth 7) − 30 − 10 + 30 + 20 + 30 + 20
        let s = score(facts, kind: .document, flags: [.junk, .dotName], depth: 7, mtime: mtime(age: 10), frecency: 1000, queryPick: 30)
        XCTAssertEqual(s, 100 + 60 + 8 + 64 + 30 + 12 - 6 - 30 - 10 + 30 + 20 + 30 + 20)
    }

    func testScoreAndComponentSumsSaturateInsteadOfOverflowing() {
        var extreme = RankingWeights()
        extreme.initialsExact = Int.max
        extreme.typeApp = Int.max
        extreme.frecencyCap = Int.max
        extreme.junk = Int.max
        extreme.dotName = Int.max
        extreme.extMatch = Int.max
        extreme.wholeToken = Int.max
        extreme.wholePrefix = Int.max
        extreme.pinyinInitialsExact = Int.max

        let allMatches = MatchFacts(textScore: Int.max, exactName: true, initialsExact: true,
                                    extMatched: true, wholeTokenMatch: true,
                                    pinyinInitialsExact: true)
        XCTAssertEqual(Ranking.flagPenalty(flags: [.junk, .dotName], weights: extreme), Int.max)
        XCTAssertEqual(Ranking.matchBonuses(facts: allMatches, weights: extreme), Int.max)
        XCTAssertEqual(
            Ranking.finalScore(facts: allMatches, kind: .app, flags: [.junk, .dotName],
                               depth: Int.max, mtime: 0, frecencyBoost: Int.max,
                               queryPickBoost: Int.max, now: now, weights: extreme),
            Int.max
        )

        extreme.initialsExact = Int.min
        extreme.typeApp = Int.min
        extreme.frecencyCap = Int.min
        XCTAssertNoThrow(
            Ranking.finalScore(facts: MatchFacts(textScore: Int.min, initialsExact: true),
                               kind: .app, flags: [], depth: Int.min, mtime: 0,
                               frecencyBoost: Int.min, queryPickBoost: Int.min,
                               now: now, weights: extreme)
        )
    }

    func testCustomWeightsAreHonoured() {
        var custom = RankingWeights()
        custom.typeApp = 1; custom.initialsExact = 2; custom.frecencyCap = 3; custom.junk = 4; custom.wholePrefix = 5
        let s = Ranking.finalScore(facts: MatchFacts(textScore: 10, exactName: true, initialsExact: true), kind: .app, flags: [.junk],
                                   depth: 0, mtime: 0, frecencyBoost: 50, queryPickBoost: 0, now: now, weights: custom)
        XCTAssertEqual(s, 10 + 1 + 2 + 3 - 4 + 5)
    }

    // MARK: - order()

    private func item(_ idx: Int, tier: Int = 2, score: Int = 0, len: Int = 10, first: Int = 0) -> RankedItem {
        RankedItem(itemIndex: idx, tier: tier, finalScore: score, nameLength: len, firstMatch: first)
    }

    func testOrderTierDominatesScore() {
        let fuzzyFile = item(1, tier: 2, score: 900)
        let exactApp = item(2, tier: 0, score: 100)
        let prefixApp = item(3, tier: 1, score: 50)
        XCTAssertEqual(Ranking.order([fuzzyFile, prefixApp, exactApp]).map(\.itemIndex), [2, 3, 1])
    }

    func testOrderScoreDescWithinTier() {
        let out = Ranking.order([item(1, score: 10), item(2, score: 30), item(3, score: 20)])
        XCTAssertEqual(out.map(\.itemIndex), [2, 3, 1])
    }

    func testOrderTieBreaksNameLengthFirstMatchItemIndex() {
        let a = item(5, score: 10, len: 8, first: 3)
        let b = item(4, score: 10, len: 8, first: 3)   // same as a but lower index → before a
        let c = item(1, score: 10, len: 8, first: 1)   // earlier first match → before a,b
        let d = item(9, score: 10, len: 4, first: 7)   // shorter name → before all
        XCTAssertEqual(Ranking.order([a, b, c, d]).map(\.itemIndex), [9, 1, 4, 5])
    }

    func testOrderIsStableForIdenticalKeys() {
        // Every field is part of the key, so identical keys are identical values; verify the sort
        // neither drops nor duplicates them and a mixed list keeps the duplicates adjacent.
        let dup = item(7, score: 1)
        let out = Ranking.order([dup, item(8, score: 1), dup, item(6, score: 1), dup])
        XCTAssertEqual(out.map(\.itemIndex), [6, 7, 7, 7, 8])
    }

    func testOrderEmptyAndSingle() {
        XCTAssertEqual(Ranking.order([]), [])
        XCTAssertEqual(Ranking.order([item(3)]), [item(3)])
    }

    func testOrderIsDeterministicOnShuffledInput() {
        var rng = SystemRandomNumberGenerator()
        let items = (0..<200).map { i in item(i, tier: i % 3, score: (i * 37) % 50, len: (i * 13) % 20, first: i % 4) }
        let reference = Ranking.order(items)
        for _ in 0..<5 {
            XCTAssertEqual(Ranking.order(items.shuffled(using: &rng)), reference)
        }
    }

    // MARK: - group()

    /// Apps are even item indices, files odd.
    private func isApp(_ idx: Int) -> Bool { idx % 2 == 0 }

    private func ordered(apps: Int, files: Int) -> [RankedItem] {
        // Interleave so relative order is visible: apps 0,2,4…, files 1,3,5…
        var out: [RankedItem] = []
        for i in 0..<max(apps, files) {
            if i < apps { out.append(item(2 * i, score: 100 - i)) }
            if i < files { out.append(item(2 * i + 1, score: 100 - i)) }
        }
        return out
    }

    func testGroupOnlyAppsTakesUpToMaxResults() {
        let out = Ranking.group(ordered(apps: 12, files: 0), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 4, 6, 8, 10, 12, 14])
    }

    func testGroupOnlyFilesTakesUpToMaxResults() {
        let out = Ranking.group(ordered(apps: 0, files: 12), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [1, 3, 5, 7, 9, 11, 13, 15])
    }

    func testGroupMixedCapsAppsAtFive() {
        let out = Ranking.group(ordered(apps: 10, files: 10), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 4, 6, 8, 1, 3, 5])
    }

    func testGroupMixedWithCapEight() {
        let out = Ranking.group(ordered(apps: 10, files: 10), maxResults: 8, appsFirstCap: 8, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 4, 6, 8, 10, 12, 14])
    }

    func testGroupBackfillsWithAppsWhenFewFiles() {
        let out = Ranking.group(ordered(apps: 10, files: 1), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 4, 6, 8, 1, 10, 12])
    }

    func testGroupFewerAppsThanCap() {
        let out = Ranking.group(ordered(apps: 2, files: 10), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 1, 3, 5, 7, 9, 11])
    }

    func testGroupFewerTotalThanMax() {
        let out = Ranking.group(ordered(apps: 2, files: 2), maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [0, 2, 1, 3])
    }

    func testGroupEdgeCases() {
        XCTAssertEqual(Ranking.group([], maxResults: 8, appsFirstCap: 5, isApp: isApp), [])
        XCTAssertEqual(Ranking.group(ordered(apps: 3, files: 3), maxResults: 0, appsFirstCap: 5, isApp: isApp), [])
        XCTAssertEqual(Ranking.group(ordered(apps: 3, files: 3), maxResults: Int.min, appsFirstCap: Int.max, isApp: isApp), [])
        XCTAssertEqual(Ranking.group(ordered(apps: 3, files: 3), maxResults: Int.max, appsFirstCap: Int.max, isApp: isApp).count, 6,
                       "an extreme public-API limit is bounded by the available input")
        // Cap larger than maxResults behaves like cap == maxResults.
        XCTAssertEqual(Ranking.group(ordered(apps: 10, files: 10), maxResults: 3, appsFirstCap: 50, isApp: isApp).map(\.itemIndex), [0, 2, 4])
        // Cap 0 → files first, apps backfill only if files run out.
        XCTAssertEqual(Ranking.group(ordered(apps: 3, files: 2), maxResults: 4, appsFirstCap: 0, isApp: isApp).map(\.itemIndex), [1, 3, 0, 2])
    }

    func testGroupPreservesOrderWithinGroups() {
        let input = [item(1, score: 5), item(2, score: 4), item(3, score: 3), item(4, score: 2)]
        let out = Ranking.group(input, maxResults: 8, appsFirstCap: 5, isApp: isApp)
        XCTAssertEqual(out.map(\.itemIndex), [2, 4, 1, 3])
    }

    // MARK: - End-to-end golden: compute → order → group

    func testGoldenChromeExactAboveFuzzyAndFilesBelow() {
        struct Cand { let idx: Int; let kind: ItemKind; let facts: MatchFacts; let len: Int }
        let cands = [
            Cand(idx: 0, kind: .app, facts: MatchFacts(textScore: 140), len: 20),                               // "Chromium Helper" fuzzy
            Cand(idx: 1, kind: .app, facts: MatchFacts(textScore: 120, exactName: true, prefixName: true), len: 13), // "Google Chrome" alias exact
            Cand(idx: 2, kind: .document, facts: MatchFacts(textScore: 300), len: 10),                          // chrome.pdf (huge fuzzy)
            Cand(idx: 3, kind: .app, facts: MatchFacts(textScore: 100, prefixName: true), len: 22),             // "Chrome Remote Desktop"
        ]
        let ranked = cands.map { c in
            RankedItem(itemIndex: c.idx, tier: Ranking.tier(facts: c.facts, kind: c.kind),
                       finalScore: score(c.facts, kind: c.kind), nameLength: c.len, firstMatch: 0)
        }
        let out = Ranking.group(Ranking.order(ranked), maxResults: 8, appsFirstCap: 5) { $0 != 2 }
        XCTAssertEqual(out.map(\.itemIndex), [1, 3, 0, 2])
    }
}
