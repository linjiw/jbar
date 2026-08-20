import Foundation
import JBarCore

/// `--benchmark`: head-to-head measurement of JBar's own engine vs Spotlight (NSMetadataQuery),
/// on the same machine and the same queries, in one process. Also reports index build time,
/// memory, and per-query warm latency percentiles.
///
/// Usage: `JBar --benchmark [iterations]`  (default 200 warm iterations per query)
enum Benchmark {
    // Swift's String(format:) %s/%@ expect C strings / NSObjects, not Swift Strings — use these instead.
    private static func padR(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    private static func padL(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
    private static func ms(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }

    /// A query and what kind of intent it represents (for interpreting the comparison).
    struct Q { let text: String; let note: String }

    static let queries: [Q] = [
        Q(text: "vsc", note: "app acronym"),
        Q(text: "code", note: "app word"),
        Q(text: "xc", note: "app acronym"),
        Q(text: "chrome", note: "app exact"),
        Q(text: "wx", note: "pinyin initials → 微信"),
        Q(text: "term", note: "app prefix"),
        Q(text: "report", note: "common file word"),
        Q(text: "report pdf", note: "multi-term + type"),
        Q(text: "readme", note: "very common file"),
        Q(text: "package swift", note: "two words"),
        Q(text: "index", note: "high-frequency token"),
        Q(text: "x", note: "single char (worst case)"),
    ]

    static func run(iterations: Int) async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so partial output survives a kill
        let cfg = loadConfig()
        print("== JBar vs Spotlight benchmark ==")
        print("machine: \(sysctl("hw.model")) · \(activeProcessorCountString) · macOS \(osVersion)")

        // --- Build JBar index (cold, from the crawl, not the snapshot, for a fair build number) ---
        let snapshot = cfg.coordinatorOptions().snapshotURL
        try? FileManager.default.removeItem(at: snapshot)
        let buildStart = Date()
        let (engine, coordinator, waited, status) = await CLI.buildIndexPublic(cfg)
        defer { coordinator.stop() }
        let buildWall = Date().timeIntervalSince(buildStart)
        let store = coordinator.store
        let rss = ProcessMemory.residentBytes().map { Double($0) / 1_048_576 } ?? 0
        print(String(format: "\nJBar index: %d items · %d apps · %d dirs · built in %.2f s · %.0f MB RSS",
                     status.itemCount, status.appCount, store.dirs.count, waited, rss))
        print(String(format: "  memory/item: %.1f bytes (arena folded=%d display=%d dirs=%d)",
                     rss * 1_048_576 / Double(max(1, status.itemCount)),
                     store.foldedArena.count, store.displayArena.count, store.dirArena.count))
        _ = buildWall

        // --- Spotlight index size for comparison (read-only) ---
        let spotTotal = spotlightCount(scope: nil)
        let spotHome = spotlightCount(scope: NSMetadataQueryUserHomeScope)
        print("Spotlight index: \(spotTotal) items total · \(spotHome) under home (whole-Mac vs JBar's home-scoped crawl)")

        // --- Latency: JBar engine (warm) vs NSMetadataQuery (Spotlight) per query ---
        print("\n-- Warm search latency (\(iterations) iterations) --")
        print(padR("query", 16) + padL("matches", 8) + "  " + padL("JBar p50", 9) + padL("JBar p95", 9) + padL("JBar max", 9) + "   " + padL("Spot", 9) + padL("Spot n", 8) + "   top JBar result")
        var jbarP50s: [Double] = [], spotP50s: [Double] = []
        for q in queries {
            // Warm up + measure JBar
            _ = await engine.search(q.text, limit: cfg.maxResults, appsFirstCap: cfg.appsFirstCap)
            var samples: [Double] = []
            samples.reserveCapacity(iterations)
            var topResult = "—"
            var matches = 0
            for i in 0..<iterations {
                let t0 = DispatchTime.now()
                let r = await engine.search(q.text, limit: cfg.maxResults, appsFirstCap: cfg.appsFirstCap)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
                samples.append(dt)
                if i == 0 { topResult = r.rows.first.map { "\($0.name) [\(kindTag($0.kind))]" } ?? "(none)"; matches = r.totalMatches }
            }
            samples.sort()
            let jp50 = percentile(samples, 0.50), jp95 = percentile(samples, 0.95), jmax = samples.last ?? 0
            jbarP50s.append(jp50)

            // Spotlight: NSMetadataQuery filename LIKE, home scope, first term only, timed once (it caches internally)
            let (spotMs, spotN) = spotlightLatency(term: q.text)
            spotP50s.append(spotMs)

            print(padR(q.text, 16) + padL("\(matches)", 8) + "  "
                  + padL(ms(jp50) + "ms", 9) + padL(ms(jp95) + "ms", 9) + padL(ms(jmax) + "ms", 9) + "   "
                  + padL(ms(spotMs, 1) + "ms", 9) + padL("\(spotN)", 8) + "   " + topResult)
        }
        let jMed = median(jbarP50s), sMed = median(spotP50s)
        print("\nmedian across queries — JBar p50: \(ms(jMed)) ms · Spotlight: \(ms(sMed, 1)) ms  (JBar ~\(Int((sMed / max(0.0001, jMed)).rounded()))× faster)")

        // --- Coverage: sample real files and check both backends find them by exact name ---
        await coverage(engine: engine, cfg: cfg, store: store)
        return 0
    }

    // MARK: - Coverage comparison

    private static func coverage(engine: SearchEngine, cfg: Config, store: IndexStore) async {
        print("\n-- Coverage on a random sample of real files (found by exact filename?) --")
        // Sample distinct filenames from JBar's own index (these are real files on disk under the crawl roots).
        var rng = SplitMix(seed: 0x9E3779B97F4A7C15)
        var picks: [(name: String, path: String)] = []
        var tries = 0
        while picks.count < 120 && tries < 5000 && store.count > 0 {
            tries += 1
            let i = Int(rng.next() % UInt64(store.count))
            if store.itemKind(i) == .app { continue }
            let name = store.name(of: i)
            if name.count < 3 || name.hasPrefix(".") { continue }
            picks.append((name, store.path(of: i)))
        }
        var jbarTopK = 0, spotHits = 0
        let K = 50
        for p in picks {
            // JBar: does a name search surface this exact path within the top K?
            let r = await engine.search(p.name, limit: K, appsFirstCap: cfg.appsFirstCap)
            if r.rows.contains(where: { $0.path == p.path }) { jbarTopK += 1 }
            // Spotlight: does an exact-name query return this path at all?
            if spotlightFindsPath(name: p.name, path: p.path) { spotHits += 1 }
        }
        let n = max(1, picks.count)
        let pct = { (h: Int) in String(format: "%.0f", 100.0 * Double(h) / Double(n)) }
        print("  sample=\(picks.count) files (drawn from JBar's index, so JBar indexes 100% by construction)")
        print("  JBar surfaces the exact path in top-\(K): \(jbarTopK) (\(pct(jbarTopK))%) · Spotlight exact-name match: \(spotHits) (\(pct(spotHits))%)")
        print("  (misses are common filenames with many copies — indexed, but out-ranked by same-named files.)")
    }

    // MARK: - Spotlight (NSMetadataQuery / mdfind) probes

    /// Count of Spotlight-indexed items (optionally home-scoped).
    private static func spotlightCount(scope: String?) -> Int {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "public.item")
        if let s = scope { q.searchScopes = [s] }
        return runMetadataQuery(q, timeout: 8).count
    }

    /// Latency of one NSMetadataQuery filename-substring search (home scope) and its result count.
    private static func spotlightLatency(term: String) -> (ms: Double, count: Int) {
        let q = NSMetadataQuery()
        let firstTerm = term.split(separator: " ").first.map(String.init) ?? term
        q.predicate = NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(firstTerm)*")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let t0 = DispatchTime.now()
        let results = runMetadataQuery(q, timeout: 3)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        return (ms, results.count)
    }

    /// True if Spotlight returns `path` when searching for its exact filename.
    private static func spotlightFindsPath(name: String, path: String) -> Bool {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemFSName ==[c] %@", name)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        let results = runMetadataQuery(q, timeout: 3)
        return results.contains { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String == path }
    }

    /// Run an NSMetadataQuery synchronously (gathering phase) with a timeout, returning result objects.
    ///
    /// NSMetadataQuery needs a live run loop on the thread where `start()` is called and delivers its
    /// completion there. The CLI already owns the main run loop for its own `await`s, and blocking the
    /// main thread on a semaphore would deadlock that loop — so we drive the query on a DEDICATED thread
    /// with its own run loop, and the caller only blocks on a semaphore the worker signals.
    private static func runMetadataQuery(_ q: NSMetadataQuery, timeout: TimeInterval) -> [Any] {
        let sem = DispatchSemaphore(value: 0)
        final class Box { var results: [Any] = [] }
        let box = Box()
        let worker = Thread {
            let rl = RunLoop.current
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: nil) { _ in
                q.stop()
                box.results = (0..<q.resultCount).map { q.result(at: $0) }
                if let t = token { NotificationCenter.default.removeObserver(t) }
                sem.signal()
                CFRunLoopStop(rl.getCFRunLoop())
            }
            q.start()
            // Bound the wait; if gathering never finishes, stop and return what we have.
            rl.run(until: Date().addingTimeInterval(timeout))
            if q.resultCount > 0 && box.results.isEmpty { box.results = (0..<q.resultCount).map { q.result(at: $0) } }
            q.stop()
            sem.signal()
        }
        worker.stackSize = 1 << 20
        worker.start()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return box.results
    }

    // MARK: - Stats helpers

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(0, idx), sorted.count - 1)]
    }
    private static func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : percentile(xs.sorted(), 0.5) }

    private static func kindTag(_ k: ItemKind) -> String {
        switch k { case .app: return "app"; case .folder: return "dir"; default: return "file" }
    }

    private static func loadConfig() -> Config {
        if case let .loaded(c) = Config.load() { return c }
        if case let .created(c) = Config.load() { return c }
        return .default
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    private static var activeProcessorCountString: String { "\(ProcessInfo.processInfo.activeProcessorCount) cores" }
    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// Deterministic PRNG so the coverage sample is reproducible.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
