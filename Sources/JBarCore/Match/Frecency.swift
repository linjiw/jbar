import Foundation
import os

/// Mozilla-style frecency with exponential decay, persisted as JSON. Thread-safe (internal lock).
///
/// Owner: ranking agent. File: `~/Library/Application Support/JBar/history.json` (caller passes the URL).
/// Semantics (DESIGN.md §6.5): per path `(f, last)`; on open `f = f·2^(−Δt/halfLife) + w` where
/// w = 1, or 2 if `query` has ≥ 2 chars; read `f' = f·2^(−Δt/halfLife)`; boost = `min(cap, scale·log2(1+f'))`.
/// `query_pick[query] = path` remembers the last item picked for an exact query (+queryPick boost).
/// Max `maxEntries` paths (lowest f' evicted), atomic save (temp + rename), never throws to callers.
///
/// Usage: `init` does NOT touch the disk; call `load()` once at startup, `record` on every open,
/// `save()` afterwards (debouncing is the caller's concern — `save()` for 500 entries costs ~1 ms).
/// All public methods are safe to call from any thread; `load()`/`save()` do their I/O outside the lock.
///
/// On-disk format (version 1):
/// ```json
/// { "version": 1,
///   "entries": [ { "path": "/Applications/Xcode.app", "f": 3.2, "last": 1767225600.0 } ],
///   "queryPicks": { "xc": "/Applications/Xcode.app" } }
/// ```
/// `last` is seconds since 1970 (UNIX time). Unknown/corrupt/foreign-version files are ignored
/// (logged under subsystem `com.linji.jbar`, category `frecency`) and the store starts empty.
public final class FrecencyStore: @unchecked Sendable {
    public let fileURL: URL
    /// Decay half-life in seconds. Non-positive → no decay (never expected; guarded for safety).
    public let halfLife: TimeInterval
    /// Maximum number of tracked paths (≥ 1; smaller values are clamped).
    public let maxEntries: Int

    /// Maximum number of remembered `query → path` picks (LRU-ish eviction).
    public static let maxQueryPicks = 200
    /// Current on-disk format version.
    public static let formatVersion = 1

    // MARK: State (guarded by `lock`)

    private struct Entry {
        var f: Double
        var last: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var queryPicks: [String: String] = [:]
    /// Query keys in least-recently-set → most-recently-set order (parallel to `queryPicks`).
    private var queryPickOrder: [String] = []

    private static let logger = Logger(subsystem: "com.linji.jbar", category: "frecency")

    // MARK: Codable file format

    private struct FileEntry: Codable {
        var path: String
        var f: Double
        var last: Date
    }

    private struct FileFormat: Codable {
        var version: Int
        var entries: [FileEntry]
        var queryPicks: [String: String]
    }

    public init(fileURL: URL, halfLife: TimeInterval = 7 * 86400, maxEntries: Int = 500) {
        self.fileURL = fileURL
        self.halfLife = halfLife
        self.maxEntries = max(1, maxEntries)
    }

    // MARK: Decay

    /// `f · 2^(−Δt/halfLife)` with Δt clamped to ≥ 0 (a `last` in the future never inflates f).
    private func decayed(_ e: Entry, now: Date) -> Double {
        guard halfLife > 0 else { return e.f }
        let dt = max(0, now.timeIntervalSince(e.last))
        return e.f * pow(2.0, -dt / halfLife)
    }

    // MARK: Persistence

    /// Load from disk (missing/corrupt file → empty, no throw).
    /// Replaces any in-memory state. Decoding happens outside the lock.
    public func load() {
        guard let data = readFile() else {
            lock.lock(); entries = [:]; queryPicks = [:]; queryPickOrder = []; lock.unlock()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file: FileFormat
        do {
            file = try decoder.decode(FileFormat.self, from: data)
        } catch {
            Self.logger.error("history.json is corrupt, starting empty: \(error.localizedDescription, privacy: .public)")
            lock.lock(); entries = [:]; queryPicks = [:]; queryPickOrder = []; lock.unlock()
            return
        }
        guard file.version == Self.formatVersion else {
            Self.logger.error("history.json has unsupported version \(file.version), starting empty")
            lock.lock(); entries = [:]; queryPicks = [:]; queryPickOrder = []; lock.unlock()
            return
        }
        let (newEntries, newPicks, newOrder) = Self.sanitize(file, maxEntries: maxEntries)
        lock.lock()
        entries = newEntries
        queryPicks = newPicks
        queryPickOrder = newOrder
        lock.unlock()
    }

    /// Reads the file's bytes; nil if it does not exist or cannot be read (logged unless simply missing).
    private func readFile() -> Data? {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            Self.logger.debug("no history file at \(self.fileURL.path, privacy: .public); starting empty")
            return nil
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("cannot read history.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drop invalid entries (non-finite / negative f, empty path), merge duplicates (keep larger f),
    /// clamp to `maxEntries` (largest raw f kept) and `maxQueryPicks`.
    private static func sanitize(_ file: FileFormat, maxEntries: Int) -> ([String: Entry], [String: String], [String]) {
        var entries: [String: Entry] = [:]
        for fe in file.entries where !fe.path.isEmpty && fe.f.isFinite && fe.f >= 0 {
            if let existing = entries[fe.path], existing.f >= fe.f { continue }
            entries[fe.path] = Entry(f: fe.f, last: fe.last)
        }
        if entries.count > maxEntries {
            let keep = entries.sorted { a, b in a.value.f != b.value.f ? a.value.f > b.value.f : a.key < b.key }.prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        // Dictionary order is arbitrary; sort keys so eviction after load is deterministic.
        let picks = file.queryPicks.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        var order = picks.keys.sorted()
        var kept = picks
        while order.count > maxQueryPicks {
            kept.removeValue(forKey: order.removeFirst())
        }
        return (entries, kept, order)
    }

    /// Save atomically. Safe to call often; coalesce if you like.
    /// Creates the parent directory if needed. Errors are logged, never thrown.
    public func save() {
        lock.lock()
        let snapshot = FileFormat(version: Self.formatVersion,
                                  entries: entries.map { FileEntry(path: $0.key, f: $0.value.f, last: $0.value.last) }
                                      .sorted { $0.path < $1.path },
                                  queryPicks: queryPicks)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(snapshot)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("cannot save history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Recording

    /// Record that the user opened `path` (optionally from typed `query`).
    ///
    /// `f = decayed(f) + w` with w = 2 when the trimmed query has ≥ 2 characters, else 1. The same
    /// query (trimmed, folded) is remembered as the last pick for `path`. When more than `maxEntries`
    /// paths are tracked, the one with the lowest decayed f is evicted.
    public func record(open path: String, query: String?, at now: Date = Date()) {
        guard !path.isEmpty else { return }
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fromQuery = trimmed.count >= 2
        let w: Double = fromQuery ? 2 : 1
        lock.lock()
        defer { lock.unlock() }
        let existing = entries[path]
        let base = existing.map { decayed($0, now: now) } ?? 0
        entries[path] = Entry(f: base + w, last: now)
        if fromQuery { setQueryPick(TextAnalyzer.fold(trimmed), path: path) }
        evictIfNeeded(now: now)
    }

    /// Must be called with the lock held. LRU-ish: re-setting a key moves it to the newest position.
    private func setQueryPick(_ key: String, path: String) {
        if queryPicks.updateValue(path, forKey: key) != nil {
            if let i = queryPickOrder.firstIndex(of: key) { queryPickOrder.remove(at: i) }
        }
        queryPickOrder.append(key)
        while queryPickOrder.count > Self.maxQueryPicks {
            queryPicks.removeValue(forKey: queryPickOrder.removeFirst())
        }
    }

    /// Must be called with the lock held. Evicts lowest decayed f until `count ≤ maxEntries`.
    private func evictIfNeeded(now: Date) {
        while entries.count > maxEntries {
            var victim: (path: String, f: Double)?
            for (path, e) in entries {
                let d = decayed(e, now: now)
                if victim == nil || d < victim!.f || (d == victim!.f && path < victim!.path) {
                    victim = (path, d)
                }
            }
            guard let v = victim else { return }
            entries.removeValue(forKey: v.path)
        }
    }

    // MARK: Reading

    /// Decayed frecency value `f'` of `path` at `now` (0 if unknown). Exposed for tests and status UI.
    public func score(for path: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path] else { return 0 }
        return decayed(e, now: now)
    }

    /// Frecency boost for ranking (0 if unknown): `min(cap, scale · log2(1 + f'))`, rounded to nearest.
    public func boost(for path: String, now: Date = Date(), weights: RankingWeights = .default) -> Int {
        let f = score(for: path, now: now)
        guard f > 0 else { return 0 }
        let raw = weights.frecencyScale * log2(1 + f)
        guard raw.isFinite else { return weights.frecencyCap }
        return min(weights.frecencyCap, Int(raw.rounded()))
    }

    /// `weights.queryPick` if the exact (trimmed, folded) `query` last resulted in opening `path`, else 0.
    public func queryPickBoost(query: String, path: String, weights: RankingWeights = .default) -> Int {
        let key = TextAnalyzer.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return queryPicks[key] == path ? weights.queryPick : 0
    }

    /// Paths by decayed frecency, descending (ties: path ascending). `limit` ≤ maxEntries. Does NOT check existence (caller prunes).
    public func recents(limit: Int, now: Date = Date()) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        let scored = entries.map { (path: $0.key, f: decayed($0.value, now: now)) }
        return scored.sorted { a, b in a.f != b.f ? a.f > b.f : a.path < b.path }
            .prefix(limit)
            .map { $0.path }
    }

    /// Remove entries for which `exists(path)` is false (and query picks pointing at them).
    /// `exists` is evaluated outside the lock so slow file-system checks do not block `record`/`boost`.
    public func prune(exists: (String) -> Bool) {
        lock.lock()
        let paths = Array(entries.keys)
        lock.unlock()
        let dead = Set(paths.filter { !exists($0) })
        guard !dead.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for p in dead { entries.removeValue(forKey: p) }
        let deadKeys = queryPicks.filter { dead.contains($0.value) }.map { $0.key }
        for k in deadKeys {
            queryPicks.removeValue(forKey: k)
            if let i = queryPickOrder.firstIndex(of: k) { queryPickOrder.remove(at: i) }
        }
    }

    /// Number of tracked paths (for tests/status).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Number of remembered query picks (for tests/status).
    public var queryPickCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queryPicks.count
    }
}
