import Foundation

/// All ranking weights in one place (DESIGN.md §6.5). Regression-tested by golden tests, never tuned by feel.
public struct RankingWeights: Sendable, Equatable {
    public var initialsExact: Int = 60
    public var initialsPrefix: Int = 40
    public var typeApp: Int = 40
    public var typeFolder: Int = 12
    public var typeDocument: Int = 8
    public var typeMedia: Int = 4      // image/video/audio
    public var typeCode: Int = 4
    public var typeHiddenOrPackageInternal: Int = -20
    public var frecencyCap: Int = 64
    public var frecencyScale: Double = 16 // boost = min(cap, scale*log2(1+f))
    public var queryPick: Int = 30
    public var recency1d: Int = 12
    public var recency7d: Int = 8
    public var recency30d: Int = 4
    public var recency180d: Int = 1
    public var depthFree: Int = 4       // no penalty up to this depth
    public var depthPerLevel: Int = 2
    public var depthCap: Int = 12
    public var junk: Int = 30
    public var dotName: Int = 10
    public var extMatch: Int = 30
    public var wholeToken: Int = 20
    public var wholePrefix: Int = 30
    public var pinyinInitialsExact: Int = 20
    public init() {}
    public static let `default` = RankingWeights()
}

/// Result tiers: lower wins regardless of score.
public enum Tier {
    public static let exactApp = 0
    public static let prefixApp = 1
    public static let other = 2
}

/// Facts about how the query matched one item — computed by `SearchEngine`, consumed by `Ranking`.
public struct MatchFacts: Sendable, Equatable {
    /// Sum over terms of the best text score (max over name + aliases), already including the
    /// scorer's own bonuses. Int (not Int16) because it's a sum.
    public var textScore: Int
    /// Whole (folded, trimmed) query equals the item's name or an alias.
    public var exactName: Bool
    /// Whole query is a prefix of the name or an alias.
    public var prefixName: Bool
    /// Single-term query equals the item's packed initials (e.g. "vsc").
    public var initialsExact: Bool
    /// Single-term query is a proper prefix of the initials.
    public var initialsPrefix: Bool
    /// A term equals the item's extension (or alias jpeg~jpg, doc~docx).
    public var extMatched: Bool
    /// A term ≥ 8 chars equals a whole token of the name.
    public var wholeTokenMatch: Bool
    /// Query matched a pinyin-initials alias exactly.
    public var pinyinInitialsExact: Bool
    public init(textScore: Int, exactName: Bool = false, prefixName: Bool = false, initialsExact: Bool = false, initialsPrefix: Bool = false,
                extMatched: Bool = false, wholeTokenMatch: Bool = false, pinyinInitialsExact: Bool = false) {
        self.textScore = textScore; self.exactName = exactName; self.prefixName = prefixName
        self.initialsExact = initialsExact; self.initialsPrefix = initialsPrefix; self.extMatched = extMatched
        self.wholeTokenMatch = wholeTokenMatch; self.pinyinInitialsExact = pinyinInitialsExact
    }
}

/// A ranked candidate. Sorted by `Ranking.order`, grouped by `Ranking.group`.
public struct RankedItem: Sendable, Equatable {
    public var itemIndex: Int
    public var tier: Int
    public var finalScore: Int
    public var nameLength: Int
    public var firstMatch: Int
    public init(itemIndex: Int, tier: Int, finalScore: Int, nameLength: Int, firstMatch: Int) {
        self.itemIndex = itemIndex; self.tier = tier; self.finalScore = finalScore; self.nameLength = nameLength; self.firstMatch = firstMatch
    }
}

/// Pure ranking functions (DESIGN.md §6.5). Owner: ranking agent.
///
/// Everything here is deterministic and allocation-free except `order`/`group`, which allocate
/// their output arrays. No I/O, no clocks: `now` is always passed in so golden tests are stable.
public enum Ranking {
    // MARK: Time constants (seconds)

    /// One day in seconds.
    public static let day: TimeInterval = 86_400

    /// Ranking accepts programmatic/custom weights, so every arithmetic boundary must remain total
    /// for all Int values. Normal product weights never reach these saturation paths.
    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? Int.max : Int.min) : value
    }

    private static func saturatedSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? Int.min : Int.max) : value
    }

    private static func saturatedMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return value }
        return (lhs < 0) == (rhs < 0) ? Int.max : Int.min
    }

    // MARK: Tier

    /// Tier for an item given the facts. Apps: exact → 0, prefix → 1; everything else 2.
    ///
    /// Tiers dominate the sort key, so an app whose name equals the query always beats a file with
    /// a higher fuzzy score. Files and folders never get a tier better than `Tier.other`.
    public static func tier(facts: MatchFacts, kind: ItemKind) -> Int {
        tier(facts: facts, kind: kind, flags: [])
    }

    /// Flag-aware variant: an `.app` that lives in a DOWNRANK directory (`junk`, e.g. `build/JBar.app`,
    /// `DerivedData/...`) or is hidden never gets an app tier — it is a build artifact, not an installed app.
    public static func tier(facts: MatchFacts, kind: ItemKind, flags: ItemFlags) -> Int {
        guard kind == .app, !flags.contains(.junk), !flags.contains(.hidden) else { return Tier.other }
        if facts.exactName { return Tier.exactApp }
        if facts.prefixName { return Tier.prefixApp }
        return Tier.other
    }

    // MARK: Final score

    /// finalScore = textScore + initials + type + frecency + queryPick + recency(mtime) − depth − junk − dot + ext + wholeToken + wholePrefix + pinyinInitials.
    /// `mtime` is seconds since 2001 (0 = unknown → no recency). `frecencyBoost`/`queryPickBoost` come from `FrecencyStore`.
    ///
    /// Notes:
    /// - `frecencyBoost` is clamped to `weights.frecencyCap` here as well, so a mis-configured store cannot
    ///   blow past the cap.
    /// - Recency and depth apply to files/folders only. An app's mtime is its install/update time and its
    ///   depth is meaningless (`/Applications/X.app` vs `~/Applications/Y.app`), so apps get neither.
    /// - Junk (DOWNRANK dir) and dot-name penalties come from `flags`; both may apply.
    public static func finalScore(facts: MatchFacts, kind: ItemKind, flags: ItemFlags, depth: Int, mtime: UInt32,
                                  frecencyBoost: Int, queryPickBoost: Int, now: Date, weights: RankingWeights) -> Int {
        var score = facts.textScore
        score = saturatedAdd(score, initialsBonus(facts: facts, weights: weights))
        score = saturatedAdd(score, typeBoost(kind: kind, flags: flags, weights: weights))
        score = saturatedAdd(score, min(frecencyBoost, weights.frecencyCap))
        score = saturatedAdd(score, queryPickBoost)
        if kind != .app {
            score = saturatedAdd(score, recencyBoost(mtime: mtime, now: now, weights: weights))
            score = saturatedSubtract(score, depthPenalty(depth: depth, weights: weights))
        }
        score = saturatedSubtract(score, flagPenalty(flags: flags, weights: weights))
        score = saturatedAdd(score, matchBonuses(facts: facts, weights: weights))
        return score
    }

    /// Initials bonus: exact initials match wins over prefix-of-initials; never both.
    public static func initialsBonus(facts: MatchFacts, weights: RankingWeights) -> Int {
        if facts.initialsExact { return weights.initialsExact }
        if facts.initialsPrefix { return weights.initialsPrefix }
        return 0
    }

    /// Penalties derived from item flags: `junk` (DOWNRANK dir) and `dotName` (`.foo`, `~$foo`).
    public static func flagPenalty(flags: ItemFlags, weights: RankingWeights) -> Int {
        var p = 0
        if flags.contains(.junk) { p = saturatedAdd(p, weights.junk) }
        if flags.contains(.dotName) { p = saturatedAdd(p, weights.dotName) }
        return p
    }

    /// Bonuses for structural query/name relationships: extension term, whole-token term,
    /// whole-query-is-prefix (or equal), pinyin-initials exact.
    public static func matchBonuses(facts: MatchFacts, weights: RankingWeights) -> Int {
        var b = 0
        if facts.extMatched { b = saturatedAdd(b, weights.extMatch) }
        if facts.wholeTokenMatch { b = saturatedAdd(b, weights.wholeToken) }
        if facts.prefixName || facts.exactName { b = saturatedAdd(b, weights.wholePrefix) }
        if facts.pinyinInitialsExact { b = saturatedAdd(b, weights.pinyinInitialsExact) }
        return b
    }

    // MARK: Type boost

    /// Type boost for a kind/flags pair. Hidden items and package-internal files get the
    /// negative `typeHiddenOrPackageInternal` regardless of kind (hidden overrides kind).
    public static func typeBoost(kind: ItemKind, flags: ItemFlags, weights: RankingWeights) -> Int {
        if flags.contains(.hidden) || kind == .packageInternal { return weights.typeHiddenOrPackageInternal }
        switch kind {
        case .app: return weights.typeApp
        case .folder: return weights.typeFolder
        case .document: return weights.typeDocument
        case .image, .video, .audio: return weights.typeMedia
        case .code: return weights.typeCode
        case .archive, .other, .packageInternal: return 0
        }
    }

    // MARK: Recency

    /// Recency boost from mtime (seconds since 2001). 0 = unknown → no boost.
    /// Thresholds are strict (`age < 1 d`). A future mtime (clock skew) is treated as "just now".
    public static func recencyBoost(mtime: UInt32, now: Date, weights: RankingWeights) -> Int {
        guard mtime != 0 else { return 0 }
        let age = now.timeIntervalSinceReferenceDate - TimeInterval(mtime)
        if age < 1 * day { return weights.recency1d }
        if age < 7 * day { return weights.recency7d }
        if age < 30 * day { return weights.recency30d }
        if age < 180 * day { return weights.recency180d }
        return 0
    }

    // MARK: Depth

    /// Depth penalty: `depthPerLevel` per component beyond `depthFree`, capped at `depthCap`.
    /// Never negative (a negative or small depth yields 0).
    public static func depthPenalty(depth: Int, weights: RankingWeights) -> Int {
        let extra = max(0, saturatedSubtract(depth, weights.depthFree))
        let perLevel = max(0, weights.depthPerLevel)
        let cap = max(0, weights.depthCap)
        return min(saturatedMultiply(extra, perLevel), cap)
    }

    // MARK: Ordering

    /// Sort key: (tier ASC, finalScore DESC, nameLength ASC, firstMatch ASC, itemIndex ASC).
    ///
    /// Stable: elements whose whole key is equal (duplicate `itemIndex`) keep their input order.
    public static func order(_ items: [RankedItem]) -> [RankedItem] {
        // Swift's `sort` is not documented as stable; carry the input position as the final tie-break.
        let indexed = Array(items.enumerated())
        let sorted = indexed.sorted { a, b in
            if a.element.tier != b.element.tier { return a.element.tier < b.element.tier }
            if a.element.finalScore != b.element.finalScore { return a.element.finalScore > b.element.finalScore }
            if a.element.nameLength != b.element.nameLength { return a.element.nameLength < b.element.nameLength }
            if a.element.firstMatch != b.element.firstMatch { return a.element.firstMatch < b.element.firstMatch }
            if a.element.itemIndex != b.element.itemIndex { return a.element.itemIndex < b.element.itemIndex }
            return a.offset < b.offset
        }
        return sorted.map { $0.element }
    }

    // MARK: Grouping

    /// Display grouping: apps first (cap `appsFirstCap` when non-apps also present, else up to maxResults),
    /// then the rest, total ≤ maxResults. Input must already be ordered. `isApp(itemIndex)` tells kind.
    ///
    /// Rules (DESIGN.md §6.5):
    /// - only apps matched → first `maxResults` apps
    /// - only non-apps matched → first `maxResults` non-apps
    /// - both → up to `appsFirstCap` apps, then non-apps until `maxResults`; if there are not enough
    ///   non-apps to fill the list, more apps (beyond the cap) backfill the remaining slots.
    /// Relative order within each group is preserved. O(n).
    public static func group(_ ordered: [RankedItem], maxResults: Int, appsFirstCap: Int, isApp: (Int) -> Bool) -> [RankedItem] {
        // Config normally validates this value, but keep the pure API safe for arbitrary callers:
        // never reserve more than the input can actually produce.
        let resultLimit = min(max(0, maxResults), ordered.count)
        guard resultLimit > 0 else { return [] }
        var apps: [RankedItem] = []
        var others: [RankedItem] = []
        for item in ordered {
            if isApp(item.itemIndex) { apps.append(item) } else { others.append(item) }
        }
        if others.isEmpty { return Array(apps.prefix(resultLimit)) }
        if apps.isEmpty { return Array(others.prefix(resultLimit)) }

        let cap = min(max(0, appsFirstCap), resultLimit)
        var out: [RankedItem] = []
        out.reserveCapacity(resultLimit)
        out.append(contentsOf: apps.prefix(cap))
        out.append(contentsOf: others.prefix(resultLimit - out.count))
        if out.count < resultLimit {
            // Fewer non-apps than slots: backfill with apps beyond the cap.
            out.append(contentsOf: apps.dropFirst(cap).prefix(resultLimit - out.count))
        }
        return out
    }
}
