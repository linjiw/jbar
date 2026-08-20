import Foundation

/// A search response for one query.
public struct SearchResponse: Sendable {
    public var query: String
    public var rows: [ResultRow]
    /// Store generation the rows came from.
    public var generation: UInt64
    /// Engine-side request id (monotonic); UI drops responses older than the latest request.
    public var requestId: UInt64
    public var elapsed: TimeInterval
    public var totalMatches: Int
    public var mode: QueryMode
    /// True when the scan was abandoned because a newer request arrived (`rows` is then empty and the
    /// response must be ignored by the UI). Always false for responses that carry real results.
    public var cancelled: Bool = false
    public init(query: String, rows: [ResultRow], generation: UInt64, requestId: UInt64, elapsed: TimeInterval, totalMatches: Int, mode: QueryMode) {
        self.query = query; self.rows = rows; self.generation = generation; self.requestId = requestId
        self.elapsed = elapsed; self.totalMatches = totalMatches; self.mode = mode
    }
}

/// The search pipeline: parse → mask prefilter → greedy subsequence → DP (parallel chunks, top-K heaps) → facts →
/// rank → group → rows with highlight positions. DESIGN.md §2.3, §6.4–6.5, §7.5. Owner: engine agent.
///
/// - Apps are scored against name + all `AppInfo.aliases` (textScore = max; pinyin-initials exact → fact).
/// - Multi-term: every term must match (AND, any order); score = sum of per-term best scores; an "extension term"
///   (equals the item's ext, or alias jpeg~jpg / doc~docx) is satisfied by the ext and sets `extMatched`.
/// - Trailing-space (lastTermComplete) → last term must be a contiguous substring.
/// - Incremental cache: when the new query extends the previous one (same terms prefix-extended), rescan only the
///   previous candidate set; otherwise full scan.
/// - Cancellation: each `search` bumps `requestId`; worker chunks poll `latestRequestId` and bail early.
/// - `.empty` → `recents` (frecency paths that still exist, mapped to rows; itemIndex = -1 if not in the store).
/// - `.path` → list the directory (FileManager), folders first, hidden only if filter starts with ".", prefix-then-fuzzy filter.
/// - `.extensionOnly` → items with that ext, ranked by recency/frecency.
/// - Never blocks the main thread; the UI `await`s this actor.
///
/// Implementation notes (engine agent):
/// - The heavy work (scan, directory listing) runs on a private concurrent `DispatchQueue`, bridged with a
///   continuation, so the actor stays re-entrant: a newer `search` can enter, bump the request counter and make
///   the older scan bail out between candidate blocks.
/// - Ranking is two-stage: stage 1 scores every candidate WITHOUT frecency (no path strings needed) and keeps the
///   best `rerankWindow` (300) by the ranking key in bounded heaps; stage 2 reconstructs paths for that window
///   only, adds frecency/query-pick boosts, then orders and groups. Frecency can therefore not lift an item
///   from outside the top-300 text matches into the visible rows (documented deviation).
/// - Per-item extension terms use interned ext ids (computed once per query from `store.extensions`), so the
///   hot loop never builds strings.
public actor SearchEngine {
    public private(set) var store: IndexStore = .empty
    public var weights: RankingWeights
    public var frecency: FrecencyStore?
    public private(set) var latestRequestId: UInt64 = 0

    /// Home directory used for `~` expansion in path mode and for `~`-abbreviated parent display.
    public private(set) var home: String = NSHomeDirectory()

    /// Path mode returns at most `limit × pathModeRowMultiplier` rows (the table scrolls beyond `limit`).
    public static let pathModeRowMultiplier = 4
    /// Number of best stage-1 candidates that get frecency/query-pick boosts before final ordering.
    public static let rerankWindow = 300
    /// Candidate count above which the scan is split into parallel chunks. Measured sweet spot: below this,
    /// thread-dispatch overhead of concurrentPerform exceeds the tiny per-candidate work (mask + rare DP),
    /// so the common warm/type-more rescan (~few-thousand candidates) is fastest single-threaded.
    public static let parallelThreshold = 20_000
    /// Candidates per parallel chunk (fixed; measured better than finer adaptive splits for large scans).
    public static let chunkSize = 8_192
    /// Extension aliases (both directions): a term equal to any member satisfies an item with any other member.
    public static let extensionAliases: [String: [String]] = [
        "jpg": ["jpeg"], "jpeg": ["jpg"],
        "doc": ["docx"], "docx": ["doc"],
        "htm": ["html"], "html": ["htm"],
        "yml": ["yaml"], "yaml": ["yml"],
        "tif": ["tiff"], "tiff": ["tif"],
    ]

    // MARK: Private state

    /// Monotonic epoch bumped on every `update(store:)` (the store's own `generation` may repeat across rebuilds).
    private var storeEpoch: UInt64 = 0
    /// `store.extensions` → id, rebuilt on every store swap.
    private var extLookup: [String: Int16] = [:]
    /// Candidate set of the previous successful `.search` scan (DESIGN.md §6.4 step 4).
    private var cache: IncrementalCache?
    /// Shared with worker threads for cancellation polling.
    private let requestCounter = RequestCounter()
    /// Worker queue for scans and directory listings (keeps the cooperative pool and the actor free).
    private static let workerQueue = DispatchQueue(label: "com.linji.jbar.search-engine", qos: .userInitiated, attributes: .concurrent)

    public init(weights: RankingWeights = .default, frecency: FrecencyStore? = nil) {
        self.weights = weights; self.frecency = frecency
    }

    // MARK: Configuration helpers (actor-isolated vars cannot be assigned from outside)

    /// Replace the ranking weights (takes effect on the next `search`).
    public func setWeights(_ w: RankingWeights) { weights = w }
    /// Attach/detach the frecency store (takes effect on the next `search`).
    public func setFrecency(_ f: FrecencyStore?) { frecency = f }
    /// Override the home directory (tests; `~` expansion and parent display).
    public func setHome(_ h: String) { home = h }

    /// Highest `store.generation` applied so far. `IndexCoordinator` numbers generations monotonically
    /// for the life of the process (never reset by rebuild/update), so this rejects out-of-order applies.
    private var appliedGeneration: UInt64 = 0

    /// Swap in a new store generation (clears the incremental cache). Ignores a store older than the one
    /// already applied — the store-changed callbacks are delivered via independent `Task`s that can race,
    /// and applying an older generation last would strand the engine on a stale (e.g. apps-only) store.
    public func update(store: IndexStore) {
        guard store.generation >= appliedGeneration else { return }
        appliedGeneration = store.generation
        self.store = store
        storeEpoch &+= 1
        cache = nil
        var lookup: [String: Int16] = [:]
        lookup.reserveCapacity(store.extensions.count)
        for (i, e) in store.extensions.enumerated() where lookup[e] == nil { lookup[e] = Int16(clamping: i) }
        extLookup = lookup
    }

    /// Run a query. `limit` = maxResults (8), `appsFirstCap` (5). Returns quickly for empty/path modes.
    public func search(_ raw: String, limit: Int = 8, appsFirstCap: Int = 5, now: Date = Date()) async -> SearchResponse {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let rid = requestCounter.next()
        latestRequestId = rid
        let parsed = QueryParser.parse(raw, home: home)
        let gen = store.generation
        func finish(_ rows: [ResultRow], total: Int, cancelled: Bool = false) -> SearchResponse {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
            var r = SearchResponse(query: raw, rows: rows, generation: gen, requestId: rid, elapsed: elapsed, totalMatches: total, mode: parsed.mode)
            r.cancelled = cancelled
            return r
        }
        switch parsed.mode {
        case .empty:
            let rows = recents(limit: limit, now: now)
            return finish(rows, total: rows.count)
        case .path(let base, let filter):
            let cap = max(limit, limit * Self.pathModeRowMultiplier)
            let homeDir = home
            let listing = await Self.onWorker { Self.listDirectory(base: base, filter: filter, cap: cap, home: homeDir) }
            return finish(listing.rows, total: listing.total)
        case .extensionOnly(let ext):
            // No terms: the rows carry no highlight offsets (the extension is implied by the query).
            let ctx = makeContext(parsed: parsed, terms: [], limit: limit, appsFirstCap: appsFirstCap, now: now, rid: rid)
            let ids = extIds(for: ext)
            let outcome = await Self.onWorker { Self.scanExtensionOnly(ids: ids, ctx: ctx) }
            if outcome.cancelled { return finish([], total: 0, cancelled: true) }
            return finish(outcome.rows, total: outcome.totalMatches)
        case .search:
            guard !parsed.terms.isEmpty else {
                let rows = recents(limit: limit, now: now)
                return finish(rows, total: rows.count)
            }
            let ctx = makeContext(parsed: parsed, terms: prepareTerms(parsed), limit: limit, appsFirstCap: appsFirstCap, now: now, rid: rid)
            let epoch = storeEpoch
            let cached = cachedCandidates(for: ctx)
            ctx.candidates = cached.map { .list($0) } ?? .all(store.count)
            let outcome = await Self.onWorker { Self.scanSearch(ctx: ctx) }
            if outcome.cancelled { return finish([], total: 0, cancelled: true) }
            if epoch == storeEpoch {
                cache = IncrementalCache(storeEpoch: epoch, terms: ctx.terms, lastTermComplete: parsed.lastTermComplete, candidates: outcome.matched)
            }
            return finish(outcome.rows, total: outcome.totalMatches)
        }
    }

    /// Rows for recently/frequently opened items (empty query). `exists` defaults to FileManager check.
    public func recents(limit: Int, now: Date = Date()) -> [ResultRow] {
        guard limit > 0, let f = frecency else { return [] }
        let fm = FileManager.default
        var rows: [ResultRow] = []
        rows.reserveCapacity(limit)
        for p in f.recents(limit: limit * 2, now: now) where fm.fileExists(atPath: p) {
            rows.append(Self.row(forPath: p, home: home))
            if rows.count >= limit { break }
        }
        return rows
    }

    /// Build a `ResultRow` for an arbitrary path (used for recents/path mode); kind inferred from extension/directory/.app.
    public nonisolated static func row(forPath path: String, home: String = NSHomeDirectory()) -> ResultRow {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        var isPackage = false
        if isDir.boolValue {
            isPackage = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
        return row(forPath: path, isDirectory: isDir.boolValue, isPackage: isPackage, home: home)
    }

    /// `row(forPath:)` when the caller already knows the directory/package flags (saves a stat per entry).
    nonisolated static func row(forPath path: String, isDirectory: Bool, isPackage: Bool, home: String,
                                matchedByteOffsets: [Int] = [], score: Int = 0) -> ResultRow {
        let clean = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let ns = clean as NSString
        var name = ns.lastPathComponent
        let parent = ns.deletingLastPathComponent
        let kind: ItemKind
        if isDirectory {
            if name.lowercased().hasSuffix(".app") && name.count > 4 {
                kind = .app
                name = String(name.dropLast(4))
            } else if isPackage {
                kind = ItemKind.forExtension(TextAnalyzer.fileExtension(of: name) ?? "")
            } else {
                kind = .folder
            }
        } else {
            kind = ItemKind.forExtension(TextAnalyzer.fileExtension(of: name) ?? "")
        }
        return ResultRow(itemIndex: -1, name: name, path: clean, parentDisplay: abbreviate(parent, home: home), kind: kind,
                         matchedByteOffsets: matchedByteOffsets, score: score, tier: Tier.other)
    }

    /// `~`-abbreviate `dir` (mirrors `IndexStore.parentDisplayPath`).
    nonisolated static func abbreviate(_ dir: String, home: String) -> String {
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }

    // MARK: - Query preparation (actor side)

    /// Terms of a `.search` query with their interned ext ids.
    private func prepareTerms(_ parsed: ParsedQuery) -> [PreparedTerm] {
        parsed.terms.map { t in
            PreparedTerm(folded: t.folded, mask: t.mask, extIds: extIds(for: String(decoding: t.folded, as: UTF8.self)))
        }
    }

    private func makeContext(parsed: ParsedQuery, terms: [PreparedTerm], limit: Int, appsFirstCap: Int, now: Date, rid: UInt64) -> ScanContext {
        ScanContext(store: store, parsed: parsed, terms: terms, weights: weights, frecency: frecency, now: now,
                    limit: limit, appsFirstCap: appsFirstCap, home: home, requestId: rid, counter: requestCounter)
    }

    /// Interned ids of `ext` and its aliases in the current store (empty if the store has no such extension).
    private func extIds(for ext: String) -> [Int16] {
        var ids: [Int16] = []
        if let id = extLookup[ext] { ids.append(id) }
        for alias in Self.extensionAliases[ext] ?? [] {
            if let id = extLookup[alias], !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Candidate list from the incremental cache if it is valid for `ctx` (DESIGN.md §6.4 step 4), else nil.
    ///
    /// Valid when: same store epoch; the new query has at least as many terms; each old term's folded bytes are a
    /// prefix of the corresponding new term; an ext-satisfiable new term has the same ext ids as the old one (so the
    /// set of items satisfied by extension did not grow); and an old trailing-space query is only reused by the
    /// identical trailing-space query (substring semantics are not monotone under extension).
    private func cachedCandidates(for ctx: ScanContext) -> [Int32]? {
        guard let c = cache, c.storeEpoch == storeEpoch, !c.terms.isEmpty, ctx.terms.count >= c.terms.count else { return nil }
        for k in 0..<c.terms.count {
            guard ctx.terms[k].folded.starts(with: c.terms[k].folded) else { return nil }
            // The extension-substring rule makes match membership non-monotone across the
            // extension/non-extension boundary, so any change to a term's ext ids — GAINING or LOSING
            // extension-ness — must invalidate the cache (e.g. "pdf" → "pdfx" lifts the substring rule).
            if ctx.terms[k].extIds != c.terms[k].extIds { return nil }
        }
        if c.lastTermComplete {
            guard ctx.parsed.lastTermComplete, ctx.terms.count == c.terms.count,
                  ctx.terms[ctx.terms.count - 1].folded == c.terms[c.terms.count - 1].folded else { return nil }
        }
        return c.candidates
    }

    // MARK: - Worker bridge

    private static func onWorker<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            workerQueue.async { cont.resume(returning: body()) }
        }
    }

    // MARK: - Search scan (worker side)

    /// Full `.search` pipeline for `ctx.candidates`. Runs on the worker queue.
    private static func scanSearch(ctx: ScanContext) -> ScanOutcome {
        let n = ctx.candidates.count
        guard n > 0 else { return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: false) }
        let chunks = chunkRanges(count: n)
        var results: [ChunkResult] = []
        if chunks.count == 1 {
            results = [runChunk(index: 0, range: chunks[0], ctx: ctx)]
        } else {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
                if ctx.isStale { return }
                let r = runChunk(index: c, range: chunks[c], ctx: ctx)
                lock.lock(); results.append(r); lock.unlock()
            }
        }
        if ctx.isStale || results.count != chunks.count || results.contains(where: { $0.cancelled }) {
            return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: true)
        }
        results.sort { $0.index < $1.index }
        var matched: [Int32] = []
        var total = 0
        var pool: [Scored] = []
        for r in results {
            matched.append(contentsOf: r.matched)
            total += r.total
            pool.append(contentsOf: r.top.items)
        }
        let rows = rankAndBuildRows(pool: pool, ctx: ctx)
        return ScanOutcome(rows: rows, matched: matched, totalMatches: total, cancelled: false)
    }

    /// `.extensionOnly` pipeline: every item whose ext id is in `ids`, ranked by type/recency/frecency.
    private static func scanExtensionOnly(ids: [Int16], ctx: ScanContext) -> ScanOutcome {
        guard !ids.isEmpty else { return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: false) }
        let store = ctx.store
        var top = TopK(capacity: rerankWindow)
        var total = 0
        let facts = MatchFacts(textScore: 0, extMatched: true)
        for i in 0..<store.count {
            if i & 4095 == 0 && ctx.isStale { return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: true) }
            let e = store.extId[i]
            guard e >= 0, ids.contains(e) else { continue }
            total += 1
            let kind = store.itemKind(i)
            let score = Ranking.finalScore(facts: facts, kind: kind, flags: store.itemFlags(i), depth: Int(store.depth[i]), mtime: store.mtime[i],
                                           frecencyBoost: 0, queryPickBoost: 0, now: ctx.now, weights: ctx.weights)
            let item = RankedItem(itemIndex: i, tier: Ranking.tier(facts: facts, kind: kind, flags: store.itemFlags(i)), finalScore: score,
                                  nameLength: Int(store.nameLen[i]), firstMatch: 0)
            top.insert(Scored(item: item, facts: facts, kind: kind))
        }
        let rows = rankAndBuildRows(pool: top.items, ctx: ctx)
        return ScanOutcome(rows: rows, matched: [], totalMatches: total, cancelled: false)
    }

    /// Split `0..<count` into parallel chunks (one chunk when below `parallelThreshold`).
    static func chunkRanges(count: Int) -> [Range<Int>] {
        guard count > parallelThreshold else { return [0..<count] }
        var out: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(count, start + chunkSize)
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// Score one chunk of candidates with its own scratch and bounded heap.
    private static func runChunk(index: Int, range: Range<Int>, ctx: ScanContext) -> ChunkResult {
        var worker = ChunkWorker(ctx: ctx)
        worker.run(range: range)
        return ChunkResult(index: index, top: worker.top, matched: worker.matched, total: worker.total, cancelled: worker.cancelled)
    }

    /// Stage 2: take the best `rerankWindow` of `pool`, add frecency/query-pick, order, group, build rows.
    private static func rankAndBuildRows(pool: [Scored], ctx: ScanContext) -> [ResultRow] {
        var window = pool
        if window.count > rerankWindow {
            window.sort { Self.better($0.item, $1.item) }
            window.removeLast(window.count - rerankWindow)
        }
        let store = ctx.store
        var items: [RankedItem] = []
        items.reserveCapacity(window.count)
        for s in window {
            var item = s.item
            if let f = ctx.frecency {
                let path = store.path(of: item.itemIndex)
                let fb = f.boost(for: path, now: ctx.now, weights: ctx.weights)
                let qp = f.queryPickBoost(query: ctx.parsed.raw, path: path, weights: ctx.weights)
                if fb != 0 || qp != 0 {
                    item.finalScore = Ranking.finalScore(facts: s.facts, kind: s.kind, flags: store.itemFlags(item.itemIndex),
                                                         depth: Int(store.depth[item.itemIndex]), mtime: store.mtime[item.itemIndex],
                                                         frecencyBoost: fb, queryPickBoost: qp, now: ctx.now, weights: ctx.weights)
                }
            }
            items.append(item)
        }
        let ordered = Ranking.order(items)
        // Apps-first grouping applies to installed apps only; a junk/hidden .app (build artifact) ranks with files.
        let grouped = Ranking.group(ordered, maxResults: ctx.limit, appsFirstCap: ctx.appsFirstCap) {
            store.kind[$0] == ItemKind.app.rawValue && store.flags[$0] & (ItemFlags.junk.rawValue | ItemFlags.hidden.rawValue) == 0
        }
        return grouped.map { makeRow($0, ctx: ctx) }
    }

    /// Materialise a result row (name/path/parent + highlight offsets) for one ranked item.
    private static func makeRow(_ r: RankedItem, ctx: ScanContext) -> ResultRow {
        let store = ctx.store
        let i = r.itemIndex
        let nameF = store.foldedName(of: i), nameB = store.bonus(of: i)
        var offsets: [Int] = []
        for t in ctx.terms {
            let p = Scorer.matchPositions(query: t.folded[...], text: nameF, bonus: nameB)
            if !p.isEmpty { offsets.append(contentsOf: p) }
        }
        offsets = ctx.terms.count > 1 ? Array(Set(offsets)).sorted() : offsets.sorted()
        return ResultRow(itemIndex: i, name: store.name(of: i), path: store.path(of: i), parentDisplay: store.parentDisplayPath(of: i, home: ctx.home),
                         kind: store.itemKind(i), matchedByteOffsets: offsets, score: r.finalScore, tier: r.tier)
    }

    /// Ranking key (DESIGN.md §6.5): tier ASC, finalScore DESC, nameLength ASC, firstMatch ASC, itemIndex ASC.
    static func better(_ a: RankedItem, _ b: RankedItem) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        if a.finalScore != b.finalScore { return a.finalScore > b.finalScore }
        if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
        if a.firstMatch != b.firstMatch { return a.firstMatch < b.firstMatch }
        return a.itemIndex < b.itemIndex
    }

    // MARK: - Path mode (worker side)

    /// List `base` (DESIGN.md §7.5): hidden (dot-name) entries only — and exclusively — when `filter` starts with ".",
    /// folders first then files,
    /// alphabetical (`localizedStandardCompare`); a non-empty `filter` keeps case-insensitive prefix matches first
    /// (folders first, alphabetical) then fuzzy subsequence matches (by score). Returns at most `cap` rows and
    /// the number of entries that matched before capping. Unreadable/missing directory → no rows.
    nonisolated static func listDirectory(base: String, filter: String, cap: Int, home: String) -> (rows: [ResultRow], total: Int) {
        let url = URL(fileURLWithPath: base, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard cap > 0, let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return ([], 0)
        }
        // A filter starting with "." browses hidden entries: only dot-names are listed (and without it, none are).
        let dotFilter = filter.hasPrefix(".")
        let filterA: SearchString? = filter.isEmpty ? nil : TextAnalyzer.analyze(filter)
        let scratch = ScorerScratch()
        var entries: [PathEntry] = []
        entries.reserveCapacity(urls.count)
        for u in urls {
            let name = u.lastPathComponent
            if name.hasPrefix(".") != dotFilter { continue }
            let rv = try? u.resourceValues(forKeys: Set(keys))
            let isDir = rv?.isDirectory ?? false
            let isPkg = rv?.isPackage ?? false
            var e = PathEntry(name: name, isDirectory: isDir, isPackage: isPkg, isFolder: isDir && !isPkg, group: 0, score: 0, analyzed: nil)
            if let f = filterA {
                let a = TextAnalyzer.analyze(name)
                if a.folded.starts(with: f.folded) {
                    e.group = 0
                } else if let r = Scorer.score(query: f.folded[...], text: a.folded[...], bonus: a.bonus[...], scratch: scratch) {
                    e.group = 1; e.score = Int(r.score)
                } else { continue }
                e.analyzed = a
            }
            entries.append(e)
        }
        entries.sort(by: pathOrder)
        let total = entries.count
        let rows = entries.prefix(cap).map { e -> ResultRow in
            let path = base.hasSuffix("/") ? base + e.name : base + "/" + e.name
            var offsets: [Int] = []
            if let f = filterA, let a = e.analyzed {
                offsets = e.group == 0 ? Array(0..<f.folded.count) : Scorer.matchPositions(query: f.folded[...], text: a.folded[...], bonus: a.bonus[...])
            }
            return row(forPath: path, isDirectory: e.isDirectory, isPackage: e.isPackage, home: home, matchedByteOffsets: offsets, score: e.score)
        }
        return (Array(rows), total)
    }

    /// Path-mode order: prefix group before fuzzy group; folders before files; fuzzy by score desc; then name.
    private nonisolated static func pathOrder(_ a: PathEntry, _ b: PathEntry) -> Bool {
        if a.group != b.group { return a.group < b.group }
        if a.group == 1 && a.score != b.score { return a.score > b.score }
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// MARK: - Internal types

/// Thread-safe monotonic request counter shared between the actor and worker threads (cancellation polling).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    /// Increment and return the new id.
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    /// The latest id issued.
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}

/// One query term, prepared for the hot loop.
struct PreparedTerm: Equatable {
    var folded: [UInt8]
    var mask: UInt64
    /// Interned ext ids this term satisfies by extension (empty if none in the store).
    var extIds: [Int16]
}

/// Candidate set of the previous `.search` scan.
struct IncrementalCache {
    var storeEpoch: UInt64
    var terms: [PreparedTerm]
    var lastTermComplete: Bool
    /// Every item index that matched all terms (ascending).
    var candidates: [Int32]
}

/// Which item indices a scan iterates.
enum CandidateSet {
    case all(Int)
    case list([Int32])
    var count: Int {
        switch self { case .all(let n): return n; case .list(let l): return l.count }
    }
    /// Item index of the k-th candidate.
    @inline(__always) func item(at k: Int) -> Int {
        switch self { case .all: return k; case .list(let l): return Int(l[k]) }
    }
}

/// A stage-1 scored candidate (facts kept so stage 2 can recompute the score with frecency).
struct Scored {
    var item: RankedItem
    var facts: MatchFacts
    var kind: ItemKind
}

/// Everything a worker needs for one scan. Immutable after construction except `candidates`, which the actor sets
/// before handing the context over. Store/frecency are thread-safe by contract.
final class ScanContext: @unchecked Sendable {
    let store: IndexStore
    let parsed: ParsedQuery
    let terms: [PreparedTerm]
    let weights: RankingWeights
    let frecency: FrecencyStore?
    let now: Date
    let limit: Int
    let appsFirstCap: Int
    let home: String
    let requestId: UInt64
    let counter: RequestCounter
    var candidates: CandidateSet = .all(0)
    /// OR of the masks of terms that cannot be satisfied by an extension (items lacking any bit cannot match).
    let baseMask: UInt64
    /// Packed single term (≤ 8 ASCII alnum bytes) for the initials facts; 0 when not applicable.
    let singleTermPacked: UInt64
    /// Byte mask covering `singleTermPacked`'s length (for the proper-prefix check).
    let singleTermLenMask: UInt64
    /// Any term ≥ 8 bytes (whole-token fact worth checking).
    let hasLongTerm: Bool

    init(store: IndexStore, parsed: ParsedQuery, terms: [PreparedTerm], weights: RankingWeights, frecency: FrecencyStore?, now: Date,
         limit: Int, appsFirstCap: Int, home: String, requestId: UInt64, counter: RequestCounter) {
        self.store = store; self.parsed = parsed; self.terms = terms; self.weights = weights; self.frecency = frecency; self.now = now
        self.limit = limit; self.appsFirstCap = appsFirstCap; self.home = home; self.requestId = requestId; self.counter = counter
        var m: UInt64 = 0
        for t in terms where t.extIds.isEmpty { m |= t.mask }
        baseMask = m
        if terms.count == 1, terms[0].folded.count <= TextAnalyzer.maxInitials, terms[0].folded.allSatisfy(ScanContext.isASCIIAlnum) {
            let k = terms[0].folded.count
            singleTermPacked = TextAnalyzer.packInitials(terms[0].folded)
            singleTermLenMask = k >= 8 ? UInt64.max : (UInt64(1) << UInt64(8 * k)) - 1
        } else {
            singleTermPacked = 0; singleTermLenMask = 0
        }
        hasLongTerm = terms.contains { $0.folded.count >= 8 }
    }

    /// True when a newer request has been issued (workers bail out).
    var isStale: Bool { counter.current != requestId }

    static func isASCIIAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
}

/// Result of one scan.
struct ScanOutcome {
    var rows: [ResultRow]
    var matched: [Int32]
    var totalMatches: Int
    var cancelled: Bool
}

/// Result of one parallel chunk.
struct ChunkResult {
    var index: Int
    var top: TopK
    var matched: [Int32]
    var total: Int
    var cancelled: Bool
}

/// One directory entry in path mode.
struct PathEntry {
    var name: String
    var isDirectory: Bool
    var isPackage: Bool
    var isFolder: Bool
    /// 0 = prefix match (or unfiltered), 1 = fuzzy match.
    var group: Int
    var score: Int
    var analyzed: SearchString?
}

/// Bounded "best K" heap keyed by `SearchEngine.better` (root = worst kept item).
struct TopK {
    private(set) var items: [Scored] = []
    let capacity: Int
    init(capacity: Int) { self.capacity = max(1, capacity); items.reserveCapacity(self.capacity) }

    /// Insert if there is room or `s` beats the current worst.
    mutating func insert(_ s: Scored) {
        if items.count < capacity {
            items.append(s)
            siftUp(items.count - 1)
        } else if SearchEngine.better(s.item, items[0].item) {
            items[0] = s
            siftDown(0)
        }
    }

    /// Heap invariant: parent is WORSE than (or equal to) children, i.e. `!better(child, parent)` fails → swap.
    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let p = (i - 1) / 2
            // Parent must be worse than child; if the child is worse than the parent, swap.
            if SearchEngine.better(items[p].item, items[i].item) { items.swapAt(p, i); i = p } else { break }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        let n = items.count
        while true {
            let l = 2 * i + 1, r = l + 1
            var worst = i
            if l < n && SearchEngine.better(items[worst].item, items[l].item) { worst = l }
            if r < n && SearchEngine.better(items[worst].item, items[r].item) { worst = r }
            if worst == i { break }
            items.swapAt(i, worst); i = worst
        }
    }
}

/// Per-thread scan worker: iterates a range of candidates, scores them and keeps a bounded heap.
struct ChunkWorker {
    let ctx: ScanContext
    let scratch = ScorerScratch()
    var top = TopK(capacity: SearchEngine.rerankWindow)
    var matched: [Int32] = []
    var total = 0
    var cancelled = false

    init(ctx: ScanContext) { self.ctx = ctx }

    /// Scan `range` of `ctx.candidates`, polling for cancellation every 2048 items.
    mutating func run(range: Range<Int>) {
        let cands = ctx.candidates
        for k in range {
            if k & 2047 == 0 && ctx.isStale { cancelled = true; return }
            let i = cands.item(at: k)
            guard let s = evaluate(i) else { continue }
            total += 1
            matched.append(Int32(i))
            top.insert(s)
        }
    }

    /// Score item `i` against all terms; nil if it does not satisfy every term.
    func evaluate(_ i: Int) -> Scored? {
        let store = ctx.store
        let itemMask = store.mask[i]
        let kindRaw = store.kind[i]
        // Apps may match through an alias whose characters are absent from the name, so only non-apps are
        // rejected by the name mask (apps are a few hundred items; the alias masks are checked per alias).
        if itemMask & ctx.baseMask != ctx.baseMask && kindRaw != ItemKind.app.rawValue { return nil }
        let nameF = store.foldedName(of: i)
        let nameB = store.bonus(of: i)
        let app: AppInfo? = kindRaw == ItemKind.app.rawValue ? store.appInfo[Int32(i)] : nil
        let extId = store.extId[i]
        var textScore = 0
        var firstMatch = Int(Int16.max)
        var extMatched = false
        let last = ctx.terms.count - 1
        for (k, term) in ctx.terms.enumerated() {
            let byExt = extId >= 0 && !term.extIds.isEmpty && term.extIds.contains(extId)
            if byExt { extMatched = true }
            var best: ScoreResult? = nil
            if itemMask & term.mask == term.mask {
                best = Scorer.score(query: term.folded[...], text: nameF, bonus: nameB, scratch: scratch)
                // An extension-like term ("pdf", "md", "zip" — a term equal to an extension present in the
                // index) that is NOT this item's extension must occur literally in the name; a scattered
                // fuzzy hit ("re·p·ort ·d·ra·f·t") does not count. Users type such terms to mean the type.
                if best != nil, !byExt, !term.extIds.isEmpty, app == nil,
                   Scorer.substringStart(query: term.folded[...], text: nameF) == nil { best = nil }
            }
            if let a = app { best = bestAlias(term, a, best) }
            if k == last && ctx.parsed.lastTermComplete && !byExt && !Self.hasSubstring(term, nameF, app) { return nil }
            guard best != nil || byExt else { return nil }
            if let r = best { textScore += Int(r.score); firstMatch = min(firstMatch, Int(r.firstMatch)) }
        }
        let kind = ItemKind(rawValue: kindRaw) ?? .other
        let facts = computeFacts(i, nameF: nameF, nameB: nameB, app: app, textScore: textScore, extMatched: extMatched)
        let flags = ItemFlags(rawValue: store.flags[i])
        let tier = Ranking.tier(facts: facts, kind: kind, flags: flags)
        let score = Ranking.finalScore(facts: facts, kind: kind, flags: flags, depth: Int(store.depth[i]),
                                       mtime: store.mtime[i], frecencyBoost: 0, queryPickBoost: 0, now: ctx.now, weights: ctx.weights)
        let item = RankedItem(itemIndex: i, tier: tier, finalScore: score, nameLength: Int(store.nameLen[i]),
                              firstMatch: firstMatch == Int(Int16.max) ? 0 : firstMatch)
        return Scored(item: item, facts: facts, kind: kind)
    }

    /// Best of `current` and the term's score against each alias.
    private func bestAlias(_ term: PreparedTerm, _ app: AppInfo, _ current: ScoreResult?) -> ScoreResult? {
        var best = current
        for alias in app.aliases where alias.mask & term.mask == term.mask {
            if let r = Scorer.score(query: term.folded[...], text: alias.folded[...], bonus: alias.bonus[...], scratch: scratch),
               best == nil || r.score > best!.score {
                best = r
            }
        }
        return best
    }

    /// Contiguous-substring check on the name or any alias (trailing-space semantics).
    private static func hasSubstring(_ term: PreparedTerm, _ nameF: ArraySlice<UInt8>, _ app: AppInfo?) -> Bool {
        if Scorer.substringStart(query: term.folded[...], text: nameF) != nil { return true }
        guard let a = app else { return false }
        return a.aliases.contains { Scorer.substringStart(query: term.folded[...], text: $0.folded[...]) != nil }
    }

    /// Facts for `Ranking` (DESIGN.md §6.5): exact/prefix name, initials, whole token, pinyin initials.
    private func computeFacts(_ i: Int, nameF: ArraySlice<UInt8>, nameB: ArraySlice<UInt8>, app: AppInfo?, textScore: Int, extMatched: Bool) -> MatchFacts {
        var f = MatchFacts(textScore: textScore, extMatched: extMatched)
        let whole = ctx.parsed.wholeFolded
        if !whole.isEmpty {
            if nameF.starts(with: whole) {
                f.prefixName = true
                f.exactName = nameF.count == whole.count
            }
            if let a = app, !f.exactName {
                for alias in a.aliases where alias.folded.starts(with: whole) {
                    f.prefixName = true
                    if alias.folded.count == whole.count { f.exactName = true; break }
                }
            }
        }
        if ctx.singleTermPacked != 0 {
            applyInitials(ctx.store.initials[i], to: &f)
            if let a = app, !f.initialsExact {
                for alias in a.aliases { applyInitials(alias.initials, to: &f); if f.initialsExact { break } }
            }
        }
        if ctx.hasLongTerm {
            f.wholeTokenMatch = ctx.terms.contains { $0.folded.count >= 8 && Self.matchesWholeToken(term: $0.folded, name: nameF, bonus: nameB) }
        }
        if let a = app, ctx.terms.count == 1 {
            f.pinyinInitialsExact = Self.isPinyinInitialsExact(term: ctx.terms[0].folded, app: a, nameF: nameF, displayName: { ctx.store.name(of: i) })
        }
        return f
    }

    /// Set `initialsExact`/`initialsPrefix` from one packed initials word.
    private func applyInitials(_ packed: UInt64, to f: inout MatchFacts) {
        guard packed != 0 else { return }
        if packed == ctx.singleTermPacked { f.initialsExact = true; f.initialsPrefix = false; return }
        if !f.initialsExact && (packed & ctx.singleTermLenMask) == ctx.singleTermPacked { f.initialsPrefix = true }
    }

    /// True when `term` equals a whole token of `name` (token boundaries from the bonus array / non-word bytes).
    static func matchesWholeToken(term: [UInt8], name: ArraySlice<UInt8>, bonus: ArraySlice<UInt8>) -> Bool {
        let k = term.count, n = name.count
        guard k > 0, k <= n else { return false }
        let ns = name.startIndex, bs = bonus.startIndex
        var p = 0
        while p + k <= n {
            let startsToken = p == 0 || bonus[bs + p] > 0 || !isWordByte(name[ns + p - 1])
            let endsToken = p + k == n || bonus[bs + p + k] > 0 || !isWordByte(name[ns + p + k])
            if startsToken && endsToken {
                var eq = true
                for j in 0..<k where name[ns + p + j] != term[j] { eq = false; break }
                if eq { return true }
            }
            p += 1
        }
        return false
    }

    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || b >= 0x80
    }

    /// Heuristic: the single term equals a short pure-letter alias of an app whose display name contains CJK
    /// (that alias is then the pinyin-initials string, e.g. "wx" for 微信).
    static func isPinyinInitialsExact(term: [UInt8], app: AppInfo, nameF: ArraySlice<UInt8>, displayName: () -> String) -> Bool {
        guard term.count <= TextAnalyzer.maxInitials, term.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return false }
        guard !nameF.elementsEqual(term), app.aliases.contains(where: { $0.folded == term }) else { return false }
        return containsCJK(displayName()) || app.aliases.contains { $0.folded.contains { $0 >= 0x80 } }
    }

    /// CJK Unified Ideographs (U+4E00–9FFF, U+3400–4DBF, U+20000–2A6DF).
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            let v = u.value
            return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x20000 && v <= 0x2A6DF)
        }
    }
}
