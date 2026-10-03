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
    /// Number of matches observed by the scan. When `totalMatchesIsComplete` is true this is the exact
    /// total even when `rows` was capped; otherwise it is only a lower bound (currently zero for cancelled or
    /// unavailable scans). Callers must not present an incomplete value as an exact result count.
    public var totalMatches: Int
    public var mode: QueryMode
    /// Whether `totalMatches` is exact. Path mode sets this to false when the directory cannot be read or
    /// when no scan was requested (`limit == 0`); every cancelled response is also incomplete.
    public var totalMatchesIsComplete: Bool
    /// `true`/`false` when the exact total is known; `nil` means truncation cannot be determined because the
    /// scan was unavailable or cancelled. This keeps UI from presenting an incomplete count as authoritative.
    public var hasMoreResults: Bool? {
        guard !cancelled, totalMatchesIsComplete else { return nil }
        return totalMatches > rows.count
    }
    /// True when the scan was abandoned because a newer request arrived (`rows` is then empty and the
    /// response must be ignored by the UI). Always false for responses that carry real results.
    public var cancelled: Bool = false
    public init(query: String, rows: [ResultRow], generation: UInt64, requestId: UInt64, elapsed: TimeInterval,
                totalMatches: Int, mode: QueryMode, totalMatchesIsComplete: Bool = true) {
        self.query = query; self.rows = rows; self.generation = generation; self.requestId = requestId
        self.elapsed = elapsed; self.totalMatches = totalMatches; self.mode = mode
        self.totalMatchesIsComplete = totalMatchesIsComplete
    }
}

/// The search pipeline: parse → mask prefilter → greedy subsequence → DP (parallel chunks, top-K heaps) → facts →
/// rank → group → rows with highlight positions. DESIGN.md §2.3, §6.4–6.5, §7.5. Owner: engine agent.
///
/// - Apps are scored against name + all `AppInfo.aliases` (textScore = max; pinyin-initials exact → fact).
/// - Multi-term: every term must match (AND, any order); score = sum of per-term best scores; an "extension term"
///   (equals the item's ext, or alias jpeg~jpg / doc~docx) is satisfied by the ext and sets `extMatched`.
/// - Trailing-space (lastTermComplete) → last term must be a contiguous substring.
/// - Candidate accelerator: a cache-cold search starts from the least-populated bitset for any required character;
///   the normal mask check still validates every remaining bit. Apps occur in every bitset because aliases can
///   contain characters absent from the bundle name.
/// - Incremental cache: when the new query extends the previous one (same terms prefix-extended), rescan only the
///   previous matching candidate set; otherwise use the character-bitset accelerator (or a full scan when no
///   term can safely constrain names, such as an extension-only satisfiable term).
/// - Cancellation: each `search` bumps `requestId`; worker chunks poll `latestRequestId` and bail early.
/// - `.empty` → `recents` (frecency paths that still exist, mapped to rows; itemIndex = -1 if not in the store).
/// - `.path` → stream the directory into a bounded top-K; prefix before fuzzy, folders on equal group/score,
///   hidden entries only when the filter starts with ".".
/// - `.extensionOnly` → items with that ext, ranked by recency/frecency.
/// - Never blocks the main thread; the UI `await`s this actor.
///
/// Implementation notes (engine agent):
/// - The heavy work (scan, directory listing) runs on a private concurrent `DispatchQueue`, bridged with a
///   continuation, so the actor stays re-entrant: a newer `search` can enter, bump the request counter and make
///   the older scan bail out between candidate blocks.
/// - Ranking is two-stage: stage 1 scores every candidate WITHOUT frecency (no path strings needed) and keeps the
///   best `max(rerankWindow, limit)` (normally 300) by the ranking key in bounded heaps; stage 2 reconstructs paths for that window
///   only, adds frecency/query-pick boosts, then orders and groups. Frecency can therefore not lift an item
///   from outside this text window into the visible rows (documented deviation).
/// - Per-item extension terms use interned ext ids (computed once per query from `store.extensions`), so the
///   hot loop never builds strings.
public actor SearchEngine {
    public private(set) var store: IndexStore = .empty
    public var weights: RankingWeights
    public var frecency: FrecencyStore?
    public private(set) var latestRequestId: UInt64 = 0

    /// Home directory used for `~` expansion in path mode and for `~`-abbreviated parent display.
    public private(set) var home: String = QueryParser.normalizedHome(NSHomeDirectory())

    /// Path mode returns at most `limit × pathModeRowMultiplier` rows (the table scrolls beyond `limit`).
    public static let pathModeRowMultiplier = 4
    /// Absolute path-mode result-pool ceiling after the public `limit` is validated.
    public static let maxPathModeRows = SafetyLimits.maxResults.upperBound * pathModeRowMultiplier
    /// Exact path totals are useful, but must not turn one keypress into an unbounded directory walk.
    /// When either budget is reached the retained top rows are returned with an explicitly incomplete total.
    public static let maxPathModeVisitedEntries = 100_000
    public static let pathModeTimeBudget: TimeInterval = 3
    /// Minimum number of best stage-1 candidates that get history boosts before final ordering.
    /// Larger validated result limits expand the window so up to 500 requested rows can be returned.
    public static let rerankWindow = 300
    /// Candidate count above which the scan is split into parallel chunks. Measured sweet spot: below this,
    /// thread-dispatch overhead of concurrentPerform exceeds the tiny per-candidate work (mask + rare DP),
    /// so the common warm/type-more rescan (~few-thousand candidates) is fastest single-threaded.
    public static let parallelThreshold = 32_768
    /// Minimum candidates per parallel chunk before the bounded fan-out is balanced across the
    /// candidate domain. This amortizes the per-chunk 300-item heap and final merge.
    public static let chunkSize = 32_768
    /// Bound parallel fan-out. Each chunk owns a 300-item heap, and letting `concurrentPerform` spill
    /// dozens of memory-heavy chunks across efficiency cores increased both p50 and tail latency on
    /// million-item scans. Four balanced chunks saturate the tested Apple-Silicon performance cores.
    public static let maxParallelChunks = 4
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
    /// Bounded stage-1 pool for an identical query. Final ranking/rows are always rebuilt so
    /// history mutations, result limits, grouping and home-display settings take effect immediately.
    private var rankedCache: RankedScanCache?
    /// Optional internal-only work counter used by deterministic performance tests. Production leaves this nil,
    /// so the candidate hot loop performs no observation or locking.
    private var scanWorkObserver: SearchScanWorkObserver?
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
    public func setHome(_ h: String) { home = QueryParser.normalizedHome(h) }
    /// Attach a deterministic scan-work observer for tests/benchmarks.
    func setScanWorkObserver(_ observer: SearchScanWorkObserver?) { scanWorkObserver = observer }

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
        rankedCache = nil
        var lookup: [String: Int16] = [:]
        lookup.reserveCapacity(store.extensions.count)
        for (i, e) in store.extensions.prefix(Int(Int16.max) + 1).enumerated() where lookup[e] == nil {
            lookup[e] = Int16(i)
        }
        extLookup = lookup
    }

    /// Run a query. `limit` = maxResults (8), `appsFirstCap` (5). Returns quickly for empty/path modes.
    public func search(_ raw: String, limit: Int = 8, appsFirstCap: Int = 5, now: Date = Date()) async -> SearchResponse {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let rid = requestCounter.next()
        latestRequestId = rid
        let parsed = QueryParser.parse(raw, home: home)
        let gen = store.generation
        // Config loading rejects out-of-range values, but this is a public core API too. Bound it
        // independently so Int.max/Int.min cannot overflow arithmetic or request huge capacities.
        let safeLimit = min(max(0, limit), SafetyLimits.maxResults.upperBound)
        let safeAppsFirstCap = min(max(0, appsFirstCap), safeLimit)
        func finish(_ rows: [ResultRow], total: Int, cancelled: Bool = false,
                    totalMatchesIsComplete: Bool = true) -> SearchResponse {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
            var r = SearchResponse(query: parsed.raw, rows: rows, generation: gen, requestId: rid,
                                   elapsed: elapsed, totalMatches: total, mode: parsed.mode,
                                   totalMatchesIsComplete: totalMatchesIsComplete && !cancelled)
            r.cancelled = cancelled
            return r
        }
        // A zero/negative public limit requests no rows, not an expensive count-only scan. Returning
        // an explicitly incomplete total avoids walking up to two million items merely to discard
        // every match and prevents callers from presenting zero as an authoritative count.
        guard safeLimit > 0 else {
            return finish([], total: 0, totalMatchesIsComplete: false)
        }
        switch parsed.mode {
        case .empty:
            let rows = recents(limit: safeLimit, now: now)
            return finish(rows, total: rows.count)
        case .path(let base, let filter):
            let cap = safeLimit * Self.pathModeRowMultiplier
            let homeDir = home
            let counter = requestCounter
            let listing = await Self.onWorker {
                Self.listDirectory(base: base, filter: filter, cap: cap, home: homeDir,
                                   requestId: rid, counter: counter)
            }
            // A request can be superseded after the worker's last poll but before this continuation resumes.
            if listing.cancelled || requestCounter.current != rid {
                return finish([], total: 0, cancelled: true, totalMatchesIsComplete: false)
            }
            return finish(listing.rows, total: listing.totalMatches,
                          totalMatchesIsComplete: listing.totalMatchesIsComplete)
        case .extensionOnly(let ext):
            // No terms: the rows carry no highlight offsets (the extension is implied by the query).
            let ctx = makeContext(parsed: parsed, terms: [], limit: safeLimit, appsFirstCap: safeAppsFirstCap, now: now, rid: rid)
            if let cached = reusableRankedScan(parsed: parsed, now: now, capacity: ctx.rerankCapacity) {
                let rows = await Self.onWorker { Self.rankAndBuildRows(pool: cached.pool, ctx: ctx) }
                if requestCounter.current != rid { return finish([], total: 0, cancelled: true) }
                return finish(rows, total: cached.totalMatches)
            }
            let epoch = storeEpoch
            let ids = extIds(for: ext)
            let outcome = await Self.onWorker { Self.scanExtensionOnly(ids: ids, ctx: ctx) }
            if outcome.cancelled || requestCounter.current != rid { return finish([], total: 0, cancelled: true) }
            if epoch == storeEpoch { saveRankedScan(outcome, parsed: parsed, ctx: ctx, epoch: epoch) }
            return finish(outcome.rows, total: outcome.totalMatches)
        case .search:
            guard !parsed.terms.isEmpty else {
                let rows = recents(limit: safeLimit, now: now)
                return finish(rows, total: rows.count)
            }
            let terms = prepareTerms(parsed)
            let epoch = storeEpoch
            let cached = cachedCandidates(parsed: parsed, terms: terms)
            let candidates: CandidateSet = cached.map { .list($0) } ?? initialCandidates(terms: terms)
            let ctx = makeContext(parsed: parsed, terms: terms, limit: safeLimit,
                                  appsFirstCap: safeAppsFirstCap, now: now, rid: rid,
                                  candidates: candidates)
            if let cached = reusableRankedScan(parsed: parsed, now: now, capacity: ctx.rerankCapacity) {
                let rows = await Self.onWorker { Self.rankAndBuildRows(pool: cached.pool, ctx: ctx) }
                if requestCounter.current != rid { return finish([], total: 0, cancelled: true) }
                return finish(rows, total: cached.totalMatches)
            }
            let outcome = await Self.onWorker { Self.scanSearch(ctx: ctx) }
            if outcome.cancelled || requestCounter.current != rid { return finish([], total: 0, cancelled: true) }
            if epoch == storeEpoch {
                cache = IncrementalCache(storeEpoch: epoch, terms: ctx.terms, lastTermComplete: parsed.lastTermComplete, candidates: outcome.matched)
                saveRankedScan(outcome, parsed: parsed, ctx: ctx, epoch: epoch)
            }
            return finish(outcome.rows, total: outcome.totalMatches)
        }
    }

    /// Rows for recently/frequently opened items (empty query). `exists` defaults to FileManager check.
    public func recents(limit: Int, now: Date = Date()) -> [ResultRow] {
        let safeLimit = min(max(0, limit), SafetyLimits.maxResults.upperBound)
        guard safeLimit > 0, let f = frecency else { return [] }
        let fm = FileManager.default
        var rows: [ResultRow] = []
        rows.reserveCapacity(safeLimit)
        for p in f.recents(limit: safeLimit * 2, now: now) where fm.fileExists(atPath: p) {
            rows.append(Self.row(forPath: p, home: home))
            if rows.count >= safeLimit { break }
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
        let clean = SafetyLimits.trimmingTrailingPathSlashes(path)
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
        SafetyLimits.abbreviatingHome(dir, home: home)
    }

    // MARK: - Query preparation (actor side)

    /// Terms of a `.search` query with their interned ext ids.
    private func prepareTerms(_ parsed: ParsedQuery) -> [PreparedTerm] {
        parsed.terms.map { t in
            PreparedTerm(folded: t.folded, mask: t.mask, extIds: extIds(for: String(decoding: t.folded, as: UTF8.self)))
        }
    }

    private func makeContext(parsed: ParsedQuery, terms: [PreparedTerm], limit: Int, appsFirstCap: Int,
                             now: Date, rid: UInt64, candidates: CandidateSet = .all(0)) -> ScanContext {
        ScanContext(store: store, parsed: parsed, terms: terms, weights: weights, frecency: frecency, now: now,
                    limit: limit, appsFirstCap: appsFirstCap, home: home, requestId: rid,
                    counter: requestCounter, candidates: candidates, workObserver: scanWorkObserver)
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
    private func cachedCandidates(parsed: ParsedQuery, terms: [PreparedTerm]) -> [Int32]? {
        guard let c = cache, c.storeEpoch == storeEpoch, !c.terms.isEmpty, terms.count >= c.terms.count else { return nil }
        for k in 0..<c.terms.count {
            guard terms[k].folded.starts(with: c.terms[k].folded) else { return nil }
            // The extension-substring rule makes match membership non-monotone across the
            // extension/non-extension boundary, so any change to a term's ext ids — GAINING or LOSING
            // extension-ness — must invalidate the cache (e.g. "pdf" → "pdfx" lifts the substring rule).
            if terms[k].extIds != c.terms[k].extIds { return nil }
        }
        if c.lastTermComplete {
            guard parsed.lastTermComplete, terms.count == c.terms.count,
                  terms[terms.count - 1].folded == c.terms[c.terms.count - 1].folded else { return nil }
        }
        return c.candidates
    }

    private func reusableRankedScan(parsed: ParsedQuery, now: Date, capacity: Int) -> RankedScanCache? {
        guard let cached = rankedCache, cached.storeEpoch == storeEpoch,
              cached.parsed == parsed, cached.weights == weights, cached.capacity >= capacity,
              let bucket = Self.rankingTimeBucket(now), cached.timeBucket == bucket else { return nil }
        return cached
    }

    private func saveRankedScan(_ outcome: ScanOutcome, parsed: ParsedQuery, ctx: ScanContext, epoch: UInt64) {
        guard let bucket = Self.rankingTimeBucket(ctx.now) else { rankedCache = nil; return }
        rankedCache = RankedScanCache(storeEpoch: epoch, parsed: parsed, weights: ctx.weights,
                                    timeBucket: bucket, capacity: ctx.rerankCapacity, pool: outcome.pool,
                                    totalMatches: outcome.totalMatches)
    }

    /// Item mtimes and all recency cutoffs are integer seconds. Stage-1 scores therefore remain
    /// identical throughout one reference-date second, including when the clock moves backwards
    /// within that second. Frecency decay is intentionally excluded and is recomputed in stage 2.
    private static func rankingTimeBucket(_ now: Date) -> Double? {
        let seconds = now.timeIntervalSinceReferenceDate
        return seconds.isFinite ? floor(seconds) : nil
    }

    /// Cold-query candidate set. Terms satisfiable by extension cannot constrain the filename: a
    /// `pdf` item may match even when its name lacks p/d/f. For all other terms, choosing the
    /// least-populated one-character bitset is a safe superset and lets the existing combined-mask check
    /// reject remaining false positives cheaply.
    private func initialCandidates(terms: [PreparedTerm]) -> CandidateSet {
        var requiredMask: UInt64 = 0
        for term in terms where term.extIds.isEmpty { requiredMask |= term.mask }
        guard let selected = store.rarestMaskBitset(requiredMask: requiredMask) else {
            return .all(store.count)
        }
        return .bitset(words: selected.words, upperBound: store.count,
                       candidateCount: selected.candidateCount)
    }

    // MARK: - Worker bridge

    private static func onWorker<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            workerQueue.async { cont.resume(returning: body()) }
        }
    }

    // MARK: - Search scan (worker side)

    /// Full `.search` pipeline for `ctx.candidates`. Runs on the worker queue.
    private static func scanSearch(ctx: ScanContext) -> ScanOutcome {
        let n = ctx.candidates.count
        guard n > 0 else { return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: false) }
        let chunks = chunkRanges(candidates: ctx.candidates)
        let results: [ChunkResult]
        if chunks.count == 1 {
            results = [runChunk(index: 0, range: chunks[0], ctx: ctx)]
        } else {
            let slots = ChunkResultSlots(count: chunks.count)
            DispatchQueue.concurrentPerform(iterations: chunks.count) { c in
                if ctx.isStale { return }
                let r = runChunk(index: c, range: chunks[c], ctx: ctx)
                slots.store(r, at: c)
            }
            guard let completed = slots.completed() else {
                return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: true)
            }
            results = completed
        }
        if ctx.isStale || results.count != chunks.count || results.contains(where: { $0.cancelled }) {
            return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: true)
        }
        var matched: [Int32] = []
        var total = 0
        var pool: [Scored] = []
        for r in results {
            matched.append(contentsOf: r.matched)
            total += r.total
            pool.append(contentsOf: r.top.items)
        }
        let rows = rankAndBuildRows(pool: pool, ctx: ctx)
        return ScanOutcome(rows: rows, matched: matched, totalMatches: total, cancelled: false, pool: pool)
    }

    /// `.extensionOnly` pipeline: every item whose ext id is in `ids`, ranked by type/recency/frecency.
    private static func scanExtensionOnly(ids: [Int16], ctx: ScanContext) -> ScanOutcome {
        guard !ids.isEmpty else { return ScanOutcome(rows: [], matched: [], totalMatches: 0, cancelled: false) }
        let store = ctx.store
        var top = TopK(capacity: ctx.rerankCapacity)
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
        return ScanOutcome(rows: rows, matched: [], totalMatches: total, cancelled: false, pool: top.items)
    }

    /// Split `0..<count` into parallel chunks (one chunk when below `parallelThreshold`).
    static func chunkRanges(count: Int) -> [Range<Int>] {
        guard count > parallelThreshold else { return [0..<count] }
        let desiredChunks = min(maxParallelChunks, max(1, (count + chunkSize - 1) / chunkSize))
        let balancedChunkSize = max(1, (count + desiredChunks - 1) / desiredChunks)
        var out: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(count, start + balancedChunkSize)
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// Candidate ranges use item/list positions normally and 64-item words for the packed cold-query
    /// accelerator. Bitset chunking is still based on the number of actual candidates, so a sparse
    /// posting does not pay parallel-dispatch overhead merely because the store itself is large.
    static func chunkRanges(candidates: CandidateSet) -> [Range<Int>] {
        switch candidates {
        case .bitset(let words, _, let candidateCount):
            guard !words.isEmpty else { return [] }
            guard candidateCount > parallelThreshold else { return [0..<words.count] }
            // Partition by SET-bit population, not merely word count. Index order can cluster a
            // character by root/file type; equal word ranges would then make the barrier wait for
            // one dense straggler. This one cheap popcount pass also keeps the number of top-K
            // heaps bounded for sparse postings.
            let desiredChunks = min(maxParallelChunks,
                                    max(1, (candidateCount + chunkSize - 1) / chunkSize))
            let candidatesPerChunk = max(1, (candidateCount + desiredChunks - 1) / desiredChunks)
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(desiredChunks)
            var start = 0
            var population = 0
            for wordIndex in words.indices {
                population += words[wordIndex].nonzeroBitCount
                if population >= candidatesPerChunk && ranges.count + 1 < desiredChunks {
                    ranges.append(start..<(wordIndex + 1))
                    start = wordIndex + 1
                    population = 0
                }
            }
            if start < words.count { ranges.append(start..<words.count) }
            return ranges
        case .all, .list:
            return chunkRanges(count: candidates.count)
        }
    }

    /// Score one chunk of candidates with its own scratch and bounded heap.
    private static func runChunk(index: Int, range: Range<Int>, ctx: ScanContext) -> ChunkResult {
        var worker = ChunkWorker(ctx: ctx)
        worker.run(range: range)
        return ChunkResult(index: index, top: worker.top, matched: worker.matched, total: worker.total, cancelled: worker.cancelled)
    }

    /// Stage 2: bound the pool to the current window, add history, order, group, and build rows.
    private static func rankAndBuildRows(pool: [Scored], ctx: ScanContext) -> [ResultRow] {
        var window = pool
        if window.count > ctx.rerankCapacity {
            window.sort { Self.better($0.item, $1.item) }
            window.removeLast(window.count - ctx.rerankCapacity)
        }
        let store = ctx.store
        let queryPickPath = ctx.frecency?.queryPickPath(query: ctx.parsed.raw)
        var items: [RankedItem] = []
        items.reserveCapacity(window.count)
        for s in window {
            var item = s.item
            if let f = ctx.frecency {
                let path = store.path(of: item.itemIndex)
                let fb = f.boost(for: path, now: ctx.now, weights: ctx.weights)
                let qp = queryPickPath == path ? ctx.weights.queryPick : 0
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
        let storedName = store.name(of: i)
        let app = store.itemKind(i) == .app ? store.appInfo[Int32(i)] : nil
        let displayName = app.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? storedName
        var offsets: [Int]
        if displayName == storedName {
            offsets = matchOffsets(terms: ctx.terms, folded: store.foldedName(of: i), bonus: store.bonus(of: i))
        } else {
            // Finder's localized display name is the UI contract for apps. Re-run highlight mapping on
            // that short string so offsets never point into the hidden filesystem/bundle name.
            let analyzed = TextAnalyzer.analyze(displayName)
            offsets = matchOffsets(terms: ctx.terms, folded: analyzed.folded[...], bonus: analyzed.bonus[...])
        }
        offsets = ctx.terms.count > 1 ? Array(Set(offsets)).sorted() : offsets.sorted()
        return ResultRow(itemIndex: i, name: displayName, path: store.path(of: i), parentDisplay: store.parentDisplayPath(of: i, home: ctx.home),
                         kind: store.itemKind(i), matchedByteOffsets: offsets, score: r.finalScore, tier: r.tier)
    }

    private static func matchOffsets(terms: [PreparedTerm], folded: ArraySlice<UInt8>,
                                     bonus: ArraySlice<UInt8>) -> [Int] {
        var offsets: [Int] = []
        for term in terms {
            let positions = Scorer.matchPositions(query: term.folded[...], text: folded, bonus: bonus)
            if !positions.isEmpty { offsets.append(contentsOf: positions) }
        }
        return offsets
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

    /// List `base` (DESIGN.md §7.5) without materialising the directory. The enumerator is consumed one URL
    /// at a time and a bounded heap retains only the best `cap` entries; `totalMatches` is still exact after a
    /// complete scan. Hidden (dot-name) entries are listed only — and exclusively — when `filter` starts with
    /// ".". Prefix matches precede fuzzy matches, comparable folders precede files, and the final order is
    /// deterministic. Missing/unreadable directories return an incomplete empty result, rather than claiming an
    /// exact zero. A superseding request abandons enumeration, scoring, metadata, sorting, or row construction.
    nonisolated static func listDirectory(base: String, filter: String, cap: Int, home: String,
                                          requestId: UInt64, counter: RequestCounter,
                                          visitLimit: Int = maxPathModeVisitedEntries,
                                          timeBudget: TimeInterval = pathModeTimeBudget) -> PathScanOutcome {
        let boundedCap = min(max(0, cap), maxPathModeRows)
        guard boundedCap > 0, SafetyLimits.isSafeAbsolutePath(base) else {
            return PathScanOutcome(rows: [], totalMatches: 0, totalMatchesIsComplete: false, cancelled: false)
        }
        guard counter.current == requestId else { return .cancelled }
        let boundedVisitLimit = min(max(0, visitLimit), maxPathModeVisitedEntries)
        let boundedSeconds = timeBudget.isFinite ? min(max(0, timeBudget), pathModeTimeBudget) : 0
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started &+ UInt64(boundedSeconds * 1_000_000_000)

        let url = URL(fileURLWithPath: base, isDirectory: true)
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey]
        let packageKeys: Set<URLResourceKey> = [.isPackageKey]
        let enumerationStatus = PathEnumerationStatus()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(directoryKeys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                enumerationStatus.markFailed()
                // Continue when Foundation can skip a single bad entry. The response remains explicitly
                // incomplete because one or more matches may have been inaccessible.
                return true
            }
        ) else {
            return PathScanOutcome(rows: [], totalMatches: 0, totalMatchesIsComplete: false, cancelled: false)
        }

        // A filter starting with "." browses hidden entries: only dot-names are listed (and without it, none are).
        let dotFilter = SafetyLimits.hasDotPrefix(filter)
        let filterA: SearchString? = filter.isEmpty ? nil : TextAnalyzer.analyze(filter)
        let scratch = ScorerScratch()
        var best = PathTopK(capacity: boundedCap)
        var total = 0
        var visited = 0

        while true {
            // Check before advancing Foundation's enumerator: the visit budget is a bound on actual
            // filesystem entries requested, not merely on entries processed after one extra read.
            guard visited < boundedVisitLimit else {
                enumerationStatus.markFailed()
                break
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                enumerationStatus.markFailed()
                break
            }
            guard let object = enumerator.nextObject() else { break }
            visited &+= 1
            // Poll each phase on a staggered 32-entry cadence. Matching entries reach a cancellation point every
            // eight entries; hidden/nonmatching runs still poll at least every 32. This avoids taking an NSLock
            // four times for every filename while keeping supersession latency sub-millisecond in the 20k test.
            let cancellationPhase = visited & 31
            if cancellationPhase == 0, counter.current != requestId { return .cancelled }
            guard let entryURL = object as? URL else {
                enumerationStatus.markFailed()
                continue
            }
            let name = entryURL.lastPathComponent
            if SafetyLimits.hasDotPrefix(name) != dotFilter { continue }

            var analyzed: SearchString?
            var group = 0
            var score = 0
            if let f = filterA {
                let a = TextAnalyzer.analyze(name)
                if cancellationPhase == 8, counter.current != requestId { return .cancelled }
                if a.folded.starts(with: f.folded) {
                    group = 0
                } else if let match = Scorer.score(query: f.folded[...], text: a.folded[...],
                                                   bonus: a.bonus[...], scratch: scratch) {
                    group = 1
                    score = Int(match.score)
                } else {
                    continue
                }
                analyzed = a
            }

            let values = try? entryURL.resourceValues(forKeys: directoryKeys)
            if cancellationPhase == 16, counter.current != requestId { return .cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                enumerationStatus.markFailed()
                break
            }
            let isDirectory = values?.isDirectory ?? false
            // Package metadata is meaningful only for a directory. Avoid asking Launch Services/Foundation
            // for it on the overwhelmingly common regular-file path.
            let isPackage = isDirectory
                ? ((try? entryURL.resourceValues(forKeys: packageKeys).isPackage) ?? false)
                : false
            let entry = PathEntry(name: name, isDirectory: isDirectory, isPackage: isPackage,
                                  isFolder: isDirectory && !isPackage, group: group, score: score,
                                  analyzed: analyzed)
            if total < Int.max {
                total += 1
            } else {
                // Defensive only (a real directory cannot reach this on supported macOS), but do not label a
                // saturated counter as exact if a synthetic filesystem ever exposes more than Int.max entries.
                enumerationStatus.markFailed()
            }
            best.insert(entry)
            if cancellationPhase == 24, counter.current != requestId { return .cancelled }
        }

        guard counter.current == requestId else { return .cancelled }
        var entries = best.items
        entries.sort(by: pathOrder)
        guard counter.current == requestId else { return .cancelled }

        var rows: [ResultRow] = []
        rows.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if index & 31 == 0, counter.current != requestId { return .cancelled }
            let path = base.hasSuffix("/") ? base + entry.name : base + "/" + entry.name
            var offsets: [Int] = []
            if let f = filterA, let analyzed = entry.analyzed {
                offsets = entry.group == 0
                    ? Array(0..<f.folded.count)
                    : Scorer.matchPositions(query: f.folded[...], text: analyzed.folded[...], bonus: analyzed.bonus[...])
            }
            rows.append(row(forPath: path, isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                            home: home, matchedByteOffsets: offsets, score: entry.score))
        }
        return PathScanOutcome(rows: rows, totalMatches: total,
                               totalMatchesIsComplete: !enumerationStatus.failed, cancelled: false)
    }

    /// Path-mode order: prefix group before fuzzy; fuzzy score descending; within an equal group/score folders
    /// before files; finally deterministic Finder-style name order.
    nonisolated static func pathOrder(_ a: PathEntry, _ b: PathEntry) -> Bool {
        if a.group != b.group { return a.group < b.group }
        if a.group == 1 && a.score != b.score { return a.score > b.score }
        if a.isFolder != b.isFolder { return a.isFolder }
        let localized = a.name.localizedStandardCompare(b.name)
        if localized != .orderedSame { return localized == .orderedAscending }
        // Finder-style comparison can consider case/canonical variants equivalent. A binary tie-break prevents
        // filesystem enumeration order from leaking into results and makes repeated scans deterministic.
        if a.name != b.name { return a.name.utf8.lexicographicallyPrecedes(b.name.utf8) }
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        if a.isPackage != b.isPackage { return a.isPackage }
        return false
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
struct PreparedTerm: Equatable, Sendable {
    var folded: [UInt8]
    var mask: UInt64
    /// Interned ext ids this term satisfies by extension (empty if none in the store).
    var extIds: [Int16]
}

/// Candidate set of the previous `.search` scan.
struct IncrementalCache: Sendable {
    var storeEpoch: UInt64
    var terms: [PreparedTerm]
    var lastTermComplete: Bool
    /// Every item index that matched all terms (ascending).
    var candidates: [Int32]
}

struct RankedScanCache: Sendable {
    var storeEpoch: UInt64
    var parsed: ParsedQuery
    var weights: RankingWeights
    var timeBucket: Double
    var capacity: Int
    /// At most max(rerankWindow, limit) per chunk; no paths or final rows are retained.
    var pool: [Scored]
    var totalMatches: Int
}

/// Which item indices a scan iterates.
enum CandidateSet: Sendable {
    case all(Int)
    case list([Int32])
    /// Packed membership over `0..<upperBound`. Direct set-bit enumeration avoids allocating a
    /// large, short-lived Int32 list for every cache-cold query; `candidateCount` drives chunking.
    case bitset(words: [UInt64], upperBound: Int, candidateCount: Int)
    var count: Int {
        switch self {
        case .all(let n): return n
        case .list(let l): return l.count
        case .bitset(_, _, let candidateCount): return candidateCount
        }
    }
    /// Item index at scan position `k` for dense/list candidates. Bitsets are enumerated a word at a
    /// time by `ChunkWorker` so excluded positions never enter the loop.
    @inline(__always) func item(at k: Int) -> Int {
        switch self {
        case .all: return k
        case .list(let l): return Int(l[k])
        case .bitset:
            preconditionFailure("bitset candidates must be enumerated by word")
        }
    }
}

/// A stage-1 scored candidate (facts kept so stage 2 can recompute the score with frecency).
struct Scored: Sendable {
    var item: RankedItem
    var facts: MatchFacts
    var kind: ItemKind
}

/// Everything a worker needs for one scan. The actor finishes construction before handing this immutable
/// value graph to a worker; `IndexStore`, `FrecencyStore`, and `RequestCounter` provide their own synchronization.
final class ScanContext: Sendable {
    let store: IndexStore
    let parsed: ParsedQuery
    let terms: [PreparedTerm]
    let weights: RankingWeights
    let frecency: FrecencyStore?
    let now: Date
    let limit: Int
    let rerankCapacity: Int
    let appsFirstCap: Int
    let home: String
    let requestId: UInt64
    let counter: RequestCounter
    let candidates: CandidateSet
    let workObserver: SearchScanWorkObserver?
    /// OR of the masks of terms that cannot be satisfied by an extension (items lacking any bit cannot match).
    let baseMask: UInt64
    /// Packed single term (≤ 8 ASCII alnum bytes) for the initials facts; 0 when not applicable.
    let singleTermPacked: UInt64
    /// Byte mask covering `singleTermPacked`'s length (for the proper-prefix check).
    let singleTermLenMask: UInt64
    /// Any term ≥ 8 bytes (whole-token fact worth checking).
    let hasLongTerm: Bool

    init(store: IndexStore, parsed: ParsedQuery, terms: [PreparedTerm], weights: RankingWeights, frecency: FrecencyStore?, now: Date,
         limit: Int, appsFirstCap: Int, home: String, requestId: UInt64, counter: RequestCounter,
         candidates: CandidateSet = .all(0), workObserver: SearchScanWorkObserver? = nil) {
        self.store = store; self.parsed = parsed; self.terms = terms; self.weights = weights; self.frecency = frecency; self.now = now
        self.limit = limit; self.appsFirstCap = appsFirstCap; self.home = home; self.requestId = requestId; self.counter = counter
        rerankCapacity = max(SearchEngine.rerankWindow, min(max(0, limit), SafetyLimits.maxResults.upperBound))
        self.candidates = candidates; self.workObserver = workObserver
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

/// Aggregate work from one or more search scans. Tests use this for deterministic scan-shape assertions.
/// This records only chunk starts and candidate visits; it does not observe or prove allocation, retain,
/// or arena-borrow behaviour.
struct SearchScanWork: Equatable, Sendable {
    var chunkScansStarted = 0
    var visitedCandidates = 0
}

/// Optional, thread-safe observer for deterministic hot-loop work accounting. The production engine never
/// installs one, so normal scans do not take this lock.
final class SearchScanWorkObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var work = SearchScanWork()

    func recordChunkScan(visitedCandidates: Int) {
        lock.lock()
        work.chunkScansStarted += 1
        work.visitedCandidates += visitedCandidates
        lock.unlock()
    }

    var snapshot: SearchScanWork {
        lock.lock()
        defer { lock.unlock() }
        return work
    }
}

/// Result of one scan.
struct ScanOutcome: Sendable {
    var rows: [ResultRow]
    var matched: [Int32]
    var totalMatches: Int
    var cancelled: Bool
    var pool: [Scored] = []
}

/// Result of one parallel chunk.
struct ChunkResult: Sendable {
    var index: Int
    var top: TopK
    var matched: [Int32]
    var total: Int
    var cancelled: Bool
}

/// Parallel chunks publish to their own fixed slot. Filesystem/search work never runs under the lock;
/// the lock only protects short value assignments and the final snapshot. Fixed indices preserve the
/// serial chunk order exactly. This complete invariant is the narrow basis for `@unchecked Sendable`.
private final class ChunkResultSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChunkResult?]

    init(count: Int) { values = [ChunkResult?](repeating: nil, count: count) }

    func store(_ result: ChunkResult, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        values[index] = result
    }

    func completed() -> [ChunkResult]? {
        lock.lock()
        defer { lock.unlock() }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }
    }
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

/// Result of a streaming path-mode scan. `rows` is empty for cancellation so a partial heap can never reach UI.
struct PathScanOutcome: Sendable {
    var rows: [ResultRow]
    var totalMatches: Int
    var totalMatchesIsComplete: Bool
    var cancelled: Bool

    static let cancelled = PathScanOutcome(rows: [], totalMatches: 0,
                                           totalMatchesIsComplete: false, cancelled: true)
}

/// Foundation's enumeration error handler may be invoked from implementation-defined code. Keep its state behind
/// a lock so this remains valid under strict-concurrency checking as well as today's synchronous implementation.
final class PathEnumerationStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false

    func markFailed() {
        lock.lock()
        didFail = true
        lock.unlock()
    }

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFail
    }
}

/// Bounded heap of path entries (root = worst retained). Directory size affects scan time and exact total only;
/// retained entry memory never exceeds the validated path-mode row cap.
struct PathTopK {
    private(set) var items: [PathEntry] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = min(max(0, capacity), SearchEngine.maxPathModeRows)
        items.reserveCapacity(self.capacity)
    }

    mutating func insert(_ entry: PathEntry) {
        guard capacity > 0 else { return }
        if items.count < capacity {
            items.append(entry)
            siftUp(items.count - 1)
        } else if SearchEngine.pathOrder(entry, items[0]) {
            items[0] = entry
            siftDown(0)
        }
    }

    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            // The parent is the worse entry. If it is better than its child, swap them.
            if SearchEngine.pathOrder(items[parent], items[i]) {
                items.swapAt(parent, i)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        while true {
            let left = 2 * i + 1
            let right = left + 1
            var worst = i
            if left < items.count && SearchEngine.pathOrder(items[worst], items[left]) { worst = left }
            if right < items.count && SearchEngine.pathOrder(items[worst], items[right]) { worst = right }
            guard worst != i else { return }
            items.swapAt(i, worst)
            i = worst
        }
    }
}

/// Bounded "best K" heap keyed by `SearchEngine.better` (root = worst kept item).
struct TopK: Sendable {
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
    var top: TopK
    var matched: [Int32] = []
    var total = 0
    var cancelled = false

    init(ctx: ScanContext) {
        self.ctx = ctx
        top = TopK(capacity: ctx.rerankCapacity)
    }

    /// Scan `range` of `ctx.candidates`, polling for cancellation every 2,048 list/store positions.
    mutating func run(range: Range<Int>) {
        let cands = ctx.candidates
        let store = ctx.store
        var visited = 0
        defer { ctx.workObserver?.recordChunkScan(visitedCandidates: visited) }
        // Keep the two immutable store arenas borrowed for the whole chunk. Constructing an ArraySlice for
        // every candidate retains/releases its backing Array; these rebased pointer views are trivial values
        // whose lifetime cannot escape either closure.
        store.foldedArena.withUnsafeBufferPointer { foldedArena in
            store.bonusArena.withUnsafeBufferPointer { bonusArena in
                switch cands {
                case .bitset(let words, let upperBound, _):
                    for wordIndex in range {
                        // 32 words cover 2,048 item positions, matching the dense scan's polling cadence.
                        if wordIndex & 31 == 0 && ctx.isStale { cancelled = true; return }
                        var bits = words[wordIndex]
                        while bits != 0 {
                            let i = wordIndex * UInt64.bitWidth + bits.trailingZeroBitCount
                            bits &= bits &- 1
                            guard i < upperBound else { continue }
                            visited += 1
                            guard let s = evaluate(i, foldedArena: foldedArena,
                                                   bonusArena: bonusArena) else { continue }
                            total += 1
                            matched.append(Int32(i))
                            top.insert(s)
                        }
                    }
                case .all, .list:
                    for k in range {
                        if k & 2047 == 0 && ctx.isStale { cancelled = true; return }
                        visited += 1
                        let i = cands.item(at: k)
                        guard let s = evaluate(i, foldedArena: foldedArena,
                                               bonusArena: bonusArena) else { continue }
                        total += 1
                        matched.append(Int32(i))
                        top.insert(s)
                    }
                }
            }
        }
    }

    /// Score item `i` against all terms; nil if it does not satisfy every term.
    func evaluate(_ i: Int, foldedArena: UnsafeBufferPointer<UInt8>,
                  bonusArena: UnsafeBufferPointer<UInt8>) -> Scored? {
        let store = ctx.store
        let itemMask = store.mask[i]
        let kindRaw = store.kind[i]
        // Apps may match through an alias whose characters are absent from the name, so only non-apps are
        // rejected by the name mask (apps are a few hundred items; the alias masks are checked per alias).
        if itemMask & ctx.baseMask != ctx.baseMask && kindRaw != ItemKind.app.rawValue { return nil }
        let start = Int(store.nameStart[i])
        let length = Int(store.nameLen[i])
        guard start >= 0, start <= foldedArena.count, length <= foldedArena.count - start,
              start <= bonusArena.count, length <= bonusArena.count - start else { return nil }
        let nameF = UnsafeBufferPointer(rebasing: foldedArena[start..<(start + length)])
        let nameB = UnsafeBufferPointer(rebasing: bonusArena[start..<(start + length)])
        let app: AppInfo? = kindRaw == ItemKind.app.rawValue ? store.appInfo[Int32(i)] : nil
        let extId = store.extId[i]
        var textScore = 0
        var firstMatch = Int(Int16.max)
        var extMatched = false
        let last = ctx.terms.count - 1
        for (k, term) in ctx.terms.enumerated() {
            let byExt = extId >= 0 && !term.extIds.isEmpty && term.extIds.contains(extId)
            if byExt { extMatched = true }
            // These query modes require a literal match even when the fuzzy scorer would accept
            // the term. Reject before DP rather than scoring scattered bytes only to discard them.
            // Apps remain eligible through aliases; an extension-satisfied term needs neither check.
            let requiresLiteralName = !byExt && !term.extIds.isEmpty && app == nil
            let nameMaskMatches = itemMask & term.mask == term.mask
            if requiresLiteralName {
                guard nameMaskMatches, Self.substringStart(query: term.folded, text: nameF) != nil else { return nil }
            }
            if k == last && ctx.parsed.lastTermComplete && !byExt && !requiresLiteralName,
               !Self.hasSubstring(term, nameF, app) { return nil }
            var best: ScoreResult? = nil
            if nameMaskMatches {
                best = term.folded.withUnsafeBufferPointer {
                    Scorer.score(query: $0, text: nameF, bonus: nameB, scratch: scratch)
                }
            }
            if let a = app { best = bestAlias(term, a, best) }
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
    private static func hasSubstring(_ term: PreparedTerm, _ nameF: UnsafeBufferPointer<UInt8>, _ app: AppInfo?) -> Bool {
        if substringStart(query: term.folded, text: nameF) != nil { return true }
        guard let a = app else { return false }
        return a.aliases.contains { Scorer.substringStart(query: term.folded[...], text: $0.folded[...]) != nil }
    }

    /// Pointer-backed contiguous-substring check for a name already borrowed from the folded arena.
    private static func substringStart(query: [UInt8], text: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = query.count, n = text.count
        if m == 0 { return 0 }
        if m > n { return nil }
        return query.withUnsafeBufferPointer { q -> Int? in
            guard let qp = q.baseAddress, let tp = text.baseAddress else { return nil }
            guard let hit = memmem(tp, n, qp, m) else { return nil }
            return UnsafeRawPointer(hit).assumingMemoryBound(to: UInt8.self) - tp
        }
    }

    /// Facts for `Ranking` (DESIGN.md §6.5): exact/prefix name, initials, whole token, pinyin initials.
    private func computeFacts(_ i: Int, nameF: UnsafeBufferPointer<UInt8>, nameB: UnsafeBufferPointer<UInt8>,
                              app: AppInfo?, textScore: Int, extMatched: Bool) -> MatchFacts {
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
            f.pinyinInitialsExact = Self.isPinyinInitialsExact(term: ctx.terms[0].folded, app: a, nameF: nameF,
                                                               displayName: { a.displayName })
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
        name.withUnsafeBufferPointer { nameBuffer in
            bonus.withUnsafeBufferPointer { bonusBuffer in
                matchesWholeToken(term: term, name: nameBuffer, bonus: bonusBuffer)
            }
        }
    }

    /// Pointer-backed variant used while the store arenas are pinned for a complete chunk.
    static func matchesWholeToken(term: [UInt8], name: UnsafeBufferPointer<UInt8>,
                                  bonus: UnsafeBufferPointer<UInt8>) -> Bool {
        let k = term.count, n = name.count
        guard k > 0, k <= n, bonus.count == n else { return false }
        var p = 0
        while p + k <= n {
            let startsToken = p == 0 || bonus[p] > 0 || !isWordByte(name[p - 1])
            let endsToken = p + k == n || bonus[p + k] > 0 || !isWordByte(name[p + k])
            if startsToken && endsToken {
                var eq = true
                for j in 0..<k where name[p + j] != term[j] { eq = false; break }
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
        nameF.withUnsafeBufferPointer {
            isPinyinInitialsExact(term: term, app: app, nameF: $0, displayName: displayName)
        }
    }

    /// Pointer-backed variant used while the store folded-name arena is pinned for a complete chunk.
    static func isPinyinInitialsExact(term: [UInt8], app: AppInfo, nameF: UnsafeBufferPointer<UInt8>,
                                      displayName: () -> String) -> Bool {
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
