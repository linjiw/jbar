import Foundation
import CoreServices
import Darwin

/// Lock-isolated timestamp used by crawl callbacks, which may cross a worker-queue boundary.
/// The lock is the complete synchronization invariant for `lastPublish`.
private final class CrawlPublishThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastPublish: Date

    init(minimumInterval: TimeInterval, now: Date = Date()) {
        self.minimumInterval = minimumInterval
        self.lastPublish = now
    }

    func shouldPublish(now: Date = Date()) -> Bool {
        lock.withLock {
            guard now.timeIntervalSince(lastPublish) >= minimumInterval else { return false }
            lastPublish = now
            return true
        }
    }
}

/// Observable status of the index, for the menu bar.
public struct IndexStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, loadingSnapshot, scanningApps, crawling(progress: Int), updating, failed(String) }
    public var phase: Phase = .idle
    public var itemCount: Int = 0
    public var appCount: Int = 0
    public var lastBuilt: Date? = nil
    public var deniedPaths: [String] = []
    public var cappedDirs: [String] = []
    /// Entries/directories skipped because descriptor identity, symlink, or root-boundary safety checks failed.
    /// This is a count only: unsafe paths are deliberately never retained or exposed.
    public var unsafeEntriesSkipped: Int = 0
    public var hitItemCap: Bool = false
    public var watcherRunning: Bool = false
    public init() {}
}

/// Owns the current `IndexStore` and everything that produces it: snapshot load, app scan, file crawl,
/// FSEvents-driven incremental updates, periodic snapshot writes, and "Rebuild Index". DESIGN.md §2.3/§4.
/// Owner: indexer agent. App-agnostic (no AppKit) so it is unit-testable with a temp home directory.
///
/// Lifecycle: `start()` → apps scanned & published within ~1 s (even before the snapshot loads) → snapshot loaded if
/// valid (else crawl) → FSEvents watcher started with the snapshot's fsEventId (or sinceNow after a fresh crawl) →
/// snapshot written after the crawl and then every ≥ 60 s when dirty, plus on `stop()`.
/// All work on a private serial utility-QoS queue; callbacks are delivered on `callbackQueue` (default main).
///
/// Threading: every mutable field lives on `queue`; `store`/`status` are additionally mirrored behind a lock so the
/// main thread can read them at any time. `stop()`/`flushSnapshot()` block on the queue (they detect being called
/// from the queue itself and run inline). A running crawl is cancelled co-operatively by `stop()`, `rebuild()`,
/// and `update(options:)`.
///
/// Snapshot validity: header hash over exclusions + expanded file roots + app roots + bonus constants; the snapshot is
/// also discarded when older than `fullRecrawlInterval` or (when watching) when it carries no FSEvents id.
/// `IndexStore.builtAt` is the time of the last FULL crawl (incremental merges preserve it).
public final class IndexCoordinator: @unchecked Sendable {
    public struct Options: Sendable {
        public var home: String = NSHomeDirectory()
        public var appRoots: [String] = AppScanner.defaultRoots
        public var fileRoots: [String] = ["~"]          // "~" expands to Crawler.defaultRoots(home:exclusions:)
        public var exclusions: Exclusions
        public var maxItems: Int = 1_000_000
        public var snapshotURL: URL = Snapshot.defaultURL()
        public var watchFileSystem: Bool = true
        public var fullRecrawlInterval: TimeInterval = 7 * 86400
        public var snapshotWriteInterval: TimeInterval = 60
        public var fsLatency: TimeInterval = 1.0
        public init(exclusions: Exclusions) { self.exclusions = exclusions }
    }

    /// Minimum interval between partial-store publishes during a crawl.
    public static let publishInterval: TimeInterval = 0.5
    static let maximumSnapshotWriteInterval: TimeInterval = 86_400
    static let maximumFSEventsLatency: TimeInterval = 60
    static let maximumFullRecrawlInterval: TimeInterval = 366 * 86_400

    public private(set) var store: IndexStore {
        get { lock.withLock { _store } }
        set { lock.withLock { _store = newValue } }
    }
    public private(set) var status: IndexStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Called (serially on callbackQueue) whenever a new store generation is published.
    public var onStoreChanged: (@Sendable (IndexStore) -> Void)? {
        get { lock.withLock { _onStoreChanged } }
        set { lock.withLock { _onStoreChanged = newValue } }
    }
    /// Called (serially on callbackQueue) whenever `status` changes.
    public var onStatusChanged: (@Sendable (IndexStatus) -> Void)? {
        get { lock.withLock { _onStatusChanged } }
        set { lock.withLock { _onStatusChanged = newValue } }
    }

    // Queue-confined state.
    private var options: Options
    private var started = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var apps: [ScannedApp] = []
    /// Whether the latest application discovery hit its candidate/entry safety ceiling.
    private var appScanTruncated = false
    private var watcher: FSEventsWatcher?
    private var timer: DispatchSourceTimer?
    private var dirty = false
    private var storeComplete = false
    private var appliedEventId: UInt64 = 0
    private var lastCrawlStats: CrawlStats?

    // Lock-protected mirrors.
    private let lock = NSLock()
    private var _store: IndexStore = .empty
    private var _status = IndexStatus()
    private var cancelRequested = false
    private var statusCallbackPending = false
    private var _onStoreChanged: (@Sendable (IndexStore) -> Void)?
    private var _onStatusChanged: (@Sendable (IndexStatus) -> Void)?

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let snapshotRemover: @Sendable (URL) throws -> Void
    private let appScanner: @Sendable ([String], [String], String) -> AppScanOutcome

    public convenience init(options: Options, callbackQueue: DispatchQueue = .main) {
        self.init(options: options, callbackQueue: callbackQueue,
                  snapshotRemover: { try IndexCoordinator.removeSnapshotIfPresent($0) })
    }

    /// Internal dependency seam for deterministic deletion-failure tests.
    init(options: Options, callbackQueue: DispatchQueue = .main,
         snapshotRemover: @escaping @Sendable (URL) throws -> Void,
         appScanner: @escaping @Sendable ([String], [String], String) -> AppScanOutcome = { roots, extraBundles, home in
             AppScanner.scanOutcome(roots: roots, extraBundles: extraBundles, home: home)
         }) {
        self.options = IndexCoordinator.normalized(options)
        // Preserve generation/status ordering even when an embedding client supplies a concurrent target.
        self.callbackQueue = DispatchQueue(label: "com.linji.jbar.index.callbacks", target: callbackQueue)
        self.snapshotRemover = snapshotRemover
        self.appScanner = appScanner
        queue = DispatchQueue(label: "com.linji.jbar.index", qos: .utility)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { timer?.cancel(); watcher?.stop() }

    // MARK: Public API

    /// Begin: app scan → snapshot/crawl → watcher. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            scanAppsAndPublish()
            if let snap = loadSnapshot(),
               let rebuilt = IndexCoordinator.rebuildStore(apps: apps, filesFrom: snap,
                                                           generation: nextGeneration(), fsEventId: snap.fsEventId,
                                                           maxItems: options.maxItems,
                                                           rootAllowance: indexRootAllowance) {
                publish(rebuilt.store, complete: true)
                appliedEventId = snap.fsEventId
                dirty = true
                setStatus {
                    $0.phase = .idle; $0.lastBuilt = snap.builtAt
                    // Snapshot format does not persist crawl diagnostics; zero means no unsafe
                    // entries were observed in this process/session's loaded-cache path.
                    $0.unsafeEntriesSkipped = 0
                    $0.hitItemCap = self.appScanTruncated || rebuilt.hitItemCap
                        || (self.options.maxItems > 0 && snap.count == self.options.maxItems)
                }
            } else {
                fullCrawl()
            }
            startWatcher()
            startTimer()
        }
    }

    /// Stop watcher, write snapshot if dirty. Blocks until the snapshot is written (call on quit).
    public func stop() {
        requestCancel()
        runOnQueue {
            stopped = true
            stopWatcher()
            timer?.cancel(); timer = nil
            writeSnapshotIfDirty()
        }
    }

    /// Discard the snapshot and recrawl everything (apps + files). Publishes partial generations while crawling.
    public func rebuild() {
        requestCancel()
        queue.async { [self] in
            guard started, !stopped else { return }
            guard removeSnapshotForRebuild(at: options.snapshotURL) else { return }
            _ = rescanAppsInternal(publishNow: false)
            fullCrawl()
            if watcher == nil { startWatcher() }
        }
    }

    /// Re-scan only the app roots (cheap; call on app-root FSEvents and on every launch).
    public func rescanApps() {
        queue.async { [self] in
            guard !stopped else { return }
            if !rescanAppsInternal(publishNow: true) { fullCrawl() }
        }
    }

    /// Apply new options (e.g. config hot reload). If roots/exclusions changed → rebuild, else just re-register the watcher.
    public func update(options new: Options) {
        let normalizedNew = IndexCoordinator.normalized(new)
        let old = runOnQueue { options }
        let indexChanged = IndexCoordinator.indexInputsDiffer(old, normalizedNew)
        if indexChanged { requestCancel() }
        queue.async { [self] in
            guard started, !stopped else { options = normalizedNew; return }
            if indexChanged {
                // Keep the current options/index/watchers intact unless the old cache is definitely gone.
                guard removeSnapshotForRebuild(at: old.snapshotURL) else { return }
            }
            options = normalizedNew
            if indexChanged {
                _ = rescanAppsInternal(publishNow: false)
                fullCrawl()
            }
            stopWatcher(); startWatcher()
            timer?.cancel(); timer = nil; startTimer()
        }
    }

    /// Write the snapshot now if dirty (exposed for tests).
    public func flushSnapshot() { runOnQueue { writeSnapshotIfDirty() } }

    /// True if the two option sets describe a different index (roots, exclusions, cap, home).
    static func indexInputsDiffer(_ a: Options, _ b: Options) -> Bool {
        a.home != b.home || a.appRoots != b.appRoots || a.fileRoots != b.fileRoots || a.exclusions != b.exclusions
            || a.maxItems != b.maxItems || a.snapshotURL != b.snapshotURL
    }

    /// Public options can also be constructed directly by embedding clients, bypassing config
    /// validation. Normalize them before comparison, allocation, hashing, or crawling.
    static func normalized(_ value: Options) -> Options {
        var out = value
        out.maxItems = IndexStoreLimits.normalizedMaxItems(value.maxItems)
        if !SafetyLimits.isSafeAbsolutePath(value.home) {
            out.home = NSHomeDirectory()
        }
        let appRootLimit = min(SafetyLimits.maxRootEntries,
                               SafetyLimits.maxIndexRoots - AppScanner.extraBundles.count)
        out.appRoots = boundedPaths(value.appRoots, home: out.home,
                                    limit: appRootLimit, storeExpanded: true)
        let remainingIndexRoots = max(0, SafetyLimits.maxIndexRoots
            - AppScanner.extraBundles.count - out.appRoots.count)
        out.fileRoots = boundedPaths(value.fileRoots, home: out.home,
                                     limit: min(SafetyLimits.maxRootEntries, remainingIndexRoots),
                                     storeExpanded: false)

        let defaults = Exclusions.defaults(home: out.home)
        var exclusions = value.exclusions
        exclusions.excludeNames = boundedNames(value.exclusions.excludeNames,
                                                limit: SafetyLimits.maxNameEntries,
                                                fallback: defaults.excludeNames)
        exclusions.downrankNames = boundedNames(value.exclusions.downrankNames,
                                                 limit: SafetyLimits.maxNameEntries,
                                                 fallback: defaults.downrankNames)
        if value.exclusions.excludePaths.count > SafetyLimits.maxExcludedPathEntries {
            exclusions.excludePaths = defaults.excludePaths
        } else {
            exclusions.excludePaths = boundedPaths(value.exclusions.excludePaths, home: out.home,
                                                    limit: SafetyLimits.maxExcludedPathEntries,
                                                    storeExpanded: true)
        }
        exclusions.maxDepth = min(max(value.exclusions.maxDepth, SafetyLimits.maxDepth.lowerBound),
                                  SafetyLimits.maxDepth.upperBound)
        exclusions.maxDirEntries = min(max(0, value.exclusions.maxDirEntries), Crawler.hardMaxDirectoryEntries)
        exclusions.downrankDirEntries = min(max(0, value.exclusions.downrankDirEntries),
                                            Crawler.hardMaxDirectoryEntries)
        out.exclusions = exclusions

        out.snapshotWriteInterval = boundedFinite(value.snapshotWriteInterval,
                                                  fallback: 0,
                                                  range: 0...maximumSnapshotWriteInterval)
        out.fsLatency = boundedFinite(value.fsLatency, fallback: 1.0,
                                      range: 0...maximumFSEventsLatency)
        out.fullRecrawlInterval = boundedFinite(value.fullRecrawlInterval,
                                                fallback: 7 * 86_400,
                                                range: 0...maximumFullRecrawlInterval)
        return out
    }

    private static func boundedFinite(_ value: TimeInterval, fallback: TimeInterval,
                                      range: ClosedRange<TimeInterval>) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Inspect only the allowed prefix, validate bytes before tilde expansion, then validate the
    /// expanded result again. Stable first-occurrence de-duplication preserves configured root order.
    private static func boundedPaths(_ values: [String], home: String, limit: Int,
                                     storeExpanded: Bool) -> [String] {
        var result: [String] = []
        result.reserveCapacity(min(values.count, limit))
        var seen = Set<String>()
        for raw in values.prefix(limit) {
            guard SafetyLimits.isSafeAbsoluteOrTildePath(raw) else { continue }
            let expanded = Exclusions.expandTilde(raw, home: home)
            guard SafetyLimits.isSafeAbsolutePath(expanded) else { continue }
            // Preserve the special file-root token "~": `fileRoots()` expands it to the curated
            // default top-level roots rather than crawling the entire home as one root.
            let stored = storeExpanded ? expanded : raw
            guard seen.insert(stored).inserted else { continue }
            result.append(stored)
        }
        return result
    }

    /// Set cardinality is O(1), so reject an oversized public set before sorting/folding it. Invalid
    /// individual names are dropped after a bounded byte check; lowercasing is rechecked because
    /// Unicode case mapping can expand.
    private static func boundedNames(_ values: Set<String>, limit: Int,
                                     fallback: Set<String>) -> Set<String> {
        guard values.count <= limit else { return fallback }
        var result = Set<String>()
        result.reserveCapacity(values.count)
        for raw in values where !raw.isEmpty
            && SafetyLimits.utf8Fits(raw, maxBytes: SafetyLimits.maxNameUTF8Bytes) {
            let normalized = raw.lowercased()
            if SafetyLimits.utf8Fits(normalized, maxBytes: SafetyLimits.maxNameUTF8Bytes) {
                result.insert(normalized)
            }
        }
        return result
    }

    /// Remove exactly the snapshot filesystem entry without following symlinks or recursively deleting
    /// an unexpected directory. A missing entry is already the desired state.
    static func removeSnapshotIfPresent(_ url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { errno = EINVAL; return -1 }
            return unlink(path)
        }
        guard result != 0 else { return }
        let code = errno
        guard code != ENOENT else { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Queue-confined fail-closed deletion gate. The diagnostic intentionally contains no URL/path;
    /// only the stable error domain/code is exposed for support and telemetry correlation.
    private func removeSnapshotForRebuild(at url: URL) -> Bool {
        do {
            try snapshotRemover(url)
            return true
        } catch {
            let ns = error as NSError
            setStatus { $0.phase = .failed("snapshot removal failed (\(ns.domain):\(ns.code))") }
            return false
        }
    }

    /// A conservative allowance for all configured file/app roots plus AppScanner's explicit
    /// bundles. Keeping this constant avoids rediscovering `~` roots on every partial publish.
    private var indexRootAllowance: Int {
        SafetyLimits.maxIndexRoots
    }

    // MARK: Apps

    private func scanAppsAndPublish() {
        setStatus { $0.phase = .scanningApps }
        let outcome = appScanner(options.appRoots, AppScanner.extraBundles, options.home)
        apps = outcome.apps
        appScanTruncated = outcome.truncated
        let b = IndexBuilder()
        let hitCap = appScanTruncated || AppScanner.add(apps, to: b, maxItems: options.maxItems)
        let appStore = b.build(generation: nextGeneration())
        publish(appStore, complete: false)
        setStatus { $0.appCount = appStore.appItems.count; $0.hitItemCap = hitCap }
    }

    @discardableResult
    private func rescanAppsInternal(publishNow: Bool) -> Bool {
        let outcome = appScanner(options.appRoots, AppScanner.extraBundles, options.home)
        apps = outcome.apps
        appScanTruncated = outcome.truncated
        guard publishNow else { return true }
        guard let rebuilt = IndexCoordinator.rebuildStore(apps: apps, filesFrom: store,
                                                          generation: nextGeneration(), fsEventId: store.fsEventId,
                                                          maxItems: options.maxItems,
                                                          rootAllowance: indexRootAllowance) else { return false }
        let previouslyIncomplete = status.hitItemCap
        guard publish(rebuilt.store, complete: storeComplete) else { return false }
        setStatus {
            $0.appCount = rebuilt.store.appItems.count
            // An earlier capped full crawl may have omitted files; only another full crawl can
            // prove completeness even if a later app rescan frees capacity.
            $0.hitItemCap = previouslyIncomplete || self.appScanTruncated || rebuilt.hitItemCap
        }
        if storeComplete { dirty = true }
        return true
    }

    /// Fresh app items + every non-catalog item of `base`. Directory ids may be compacted/remapped;
    /// callers must treat the returned store as a complete immutable generation.
    struct RebuildResult {
        var store: IndexStore
        var hitItemCap: Bool
    }

    static func rebuildStore(apps: [ScannedApp], filesFrom base: IndexStore?, generation: UInt64,
                             fsEventId: UInt64, maxItems: Int, rootAllowance: Int) -> RebuildResult? {
        let limit = IndexStoreLimits.normalizedMaxItems(maxItems)
        let b = IndexBuilder()
        var hitCap = AppScanner.add(apps, to: b, maxItems: limit)
        guard let base else {
            let result = b.build(generation: generation, fsEventId: fsEventId)
            guard IndexStoreLimits.acceptsDirectoryMetadata(itemCount: result.count, dirCount: result.dirs.count,
                                                            dirArenaBytes: result.dirArena.count,
                                                            rootAllowance: rootAllowance) else { return nil }
            return RebuildResult(store: result, hitItemCap: hitCap)
        }
        let remaining = limit - b.count
        var keep: [Int] = []
        keep.reserveCapacity(min(base.count, remaining))
        for i in 0..<base.count where !StoreMerge.isScannerApp(base, i) {
            if keep.count < remaining { keep.append(i) } else { hitCap = true }
        }
        guard let store = StoreMerge.merge(base: base, keep: keep, extra: b.build(generation: 0),
                                           rootMap: [:], generation: generation, fsEventId: fsEventId,
                                           maxItems: limit, rootAllowance: rootAllowance) else { return nil }
        return RebuildResult(store: store, hitItemCap: hitCap)
    }

    // MARK: Snapshot

    private var headerHash: UInt64 {
        Snapshot.headerHash(exclusions: options.exclusions, fileRoots: fileRootPaths(),
                            appRoots: appRootPaths(), maxItems: options.maxItems)
    }

    private func loadSnapshot() -> IndexStore? {
        setStatus { $0.phase = .loadingSnapshot }
        guard let s = Snapshot.read(from: options.snapshotURL, expectedHeaderHash: headerHash,
                                    maxItems: options.maxItems, rootAllowance: indexRootAllowance) else { return nil }
        if Date().timeIntervalSince(s.builtAt) > options.fullRecrawlInterval { return nil }
        if options.watchFileSystem && s.fsEventId == 0 { return nil }
        return s
    }

    private func writeSnapshotIfDirty() {
        guard dirty, storeComplete else { return }
        let current = store
        let toWrite = current.fsEventId == appliedEventId ? current
            : StoreMerge.rebrand(current, generation: current.generation, fsEventId: appliedEventId, builtAt: current.builtAt)
        do {
            try Snapshot.write(toWrite, to: options.snapshotURL, headerHash: headerHash)
            dirty = false
        } catch {
            setStatus { $0.phase = .failed("snapshot write failed: \(error.localizedDescription)") }
        }
    }

    private func startTimer() {
        guard timer == nil, options.snapshotWriteInterval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + options.snapshotWriteInterval, repeating: options.snapshotWriteInterval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.writeSnapshotIfDirty() }
        t.resume()
        timer = t
    }

    // MARK: Crawl

    private func fileRoots() -> [CrawlRoot] {
        var out: [CrawlRoot] = []
        var seen = Set<String>()
        for entry in options.fileRoots {
            if out.count >= SafetyLimits.maxRootEntries { break }
            let roots = entry == "~" ? Crawler.defaultRoots(home: options.home, exclusions: options.exclusions)
                                      : [CrawlRoot(path: Exclusions.expandTilde(entry, home: options.home))]
            for r in roots where seen.insert(r.path).inserted {
                out.append(r)
                if out.count >= SafetyLimits.maxRootEntries { break }
            }
        }
        return out
    }

    private func fileRootPaths() -> [String] { fileRoots().map { $0.path } }
    private func appRootPaths() -> [String] { options.appRoots.map { Exclusions.expandTilde($0, home: options.home) } }

    private func makeCrawler() -> Crawler {
        Crawler(roots: fileRoots(), exclusions: options.exclusions, maxItems: options.maxItems)
    }

    private func fullCrawl() {
        guard !stopped else { return }
        clearCancel()
        // Keep the previous completeness signal while rebuilding. Only a successfully completed
        // full crawl can prove that an earlier capped generation is now complete.
        setStatus {
            $0.phase = .crawling(progress: 0)
            $0.deniedPaths = []
            $0.cappedDirs = []
            $0.unsafeEntriesSkipped = 0
        }
        let eventId = options.watchFileSystem ? UInt64(FSEventsGetCurrentEventId()) : 0
        let builder = IndexBuilder()
        builder.reserve(items: min(options.maxItems, max(store.count, 50_000)),
                        dirs: max(store.dirs.count, 5_000))
        let appHitCap = appScanTruncated || AppScanner.add(apps, to: builder, maxItems: options.maxItems)
        storeComplete = false
        let publishThrottle = CrawlPublishThrottle(minimumInterval: IndexCoordinator.publishInterval)
        let stats = makeCrawler().crawl(into: builder, onBatch: { [self] b in
            guard publishThrottle.shouldPublish() else { return }
            _ = publish(b.build(generation: nextGeneration(), fsEventId: eventId), complete: false)
            setStatus { $0.phase = .crawling(progress: b.count) }
        }, shouldCancel: { [self] in isCancelRequested })
        lastCrawlStats = stats
        if stats.cancelled {
            setStatus { $0.phase = .idle }
            return
        }
        let completed = builder.build(generation: nextGeneration(), fsEventId: eventId)
        let hitBudget = appHitCap || stats.hitItemCap
        let incomplete = hitBudget || !stats.deniedPaths.isEmpty || !stats.cappedDirs.isEmpty
        // A capped budget/directory or denied location produces a useful launcher generation, but it
        // is not an exact filesystem view: do not enable incremental updates or persist it as a
        // complete snapshot. A later explicit rebuild may prove completeness.
        guard publish(completed, complete: !incomplete) else { return }
        appliedEventId = eventId
        dirty = !incomplete
        setStatus {
            $0.phase = .idle; $0.deniedPaths = stats.deniedPaths; $0.cappedDirs = stats.cappedDirs
            $0.unsafeEntriesSkipped = stats.skippedUnsafe
            $0.appCount = completed.appItems.count
            $0.hitItemCap = hitBudget; $0.lastBuilt = completed.builtAt
        }
        writeSnapshotIfDirty()
    }

    // MARK: Watcher

    private func startWatcher() {
        guard options.watchFileSystem, watcher == nil, !stopped else { return }
        let paths = (fileRootPaths() + appRootPaths()).filter { IndexUpdater.directoryExists($0) }
        guard !paths.isEmpty else { return }
        let w = FSEventsWatcher(paths: paths, sinceWhen: appliedEventId, latency: options.fsLatency, queue: queue) { [weak self] batch in
            self?.handle(batch)
        }
        let ok = w.start()
        watcher = ok ? w : nil
        setStatus { $0.watcherRunning = ok }
    }

    private func stopWatcher() {
        watcher?.stop(); watcher = nil
        setStatus { $0.watcherRunning = false }
    }

    /// FSEvents batch (on `queue`).
    private func handle(_ batch: FSEventsBatch) {
        guard !stopped, storeComplete else { return }
        if batch.needsFullRescan { fullCrawl(); return }
        let appRoots = appRootPaths()
        if batch.changes.contains(where: { c in appRoots.contains { IndexCoordinator.isUnder(c.path, root: $0) } }) {
            if !rescanAppsInternal(publishNow: true) { fullCrawl(); return }
        }
        let crawler = makeCrawler()
        let fileChanges = batch.changes.filter { IndexUpdater.isUnderRoots($0.path, crawler: crawler) }
        if !fileChanges.isEmpty {
            setStatus { $0.phase = .updating }
            if let s = IndexUpdater.apply(changes: fileChanges, to: store, crawler: crawler, generation: nextGeneration(), fsEventId: batch.latestEventId) {
                guard publish(s, complete: true) else { fullCrawl(); return }
                setStatus { $0.phase = .idle }
            } else {
                fullCrawl()
                return
            }
        }
        appliedEventId = max(appliedEventId, batch.latestEventId)
        dirty = true
    }

    static func isUnder(_ path: String, root: String) -> Bool {
        SafetyLimits.isPath(path, within: root)
    }

    // MARK: Publishing / status

    private func nextGeneration() -> UInt64 { generation += 1; return generation }

    @discardableResult
    private func publish(_ s: IndexStore, complete: Bool) -> Bool {
        guard s.count <= options.maxItems,
              IndexStoreLimits.acceptsDirectoryMetadata(itemCount: s.count, dirCount: s.dirs.count,
                                                        dirArenaBytes: s.dirArena.count,
                                                        rootAllowance: indexRootAllowance) else {
            storeComplete = false
            setStatus { $0.phase = .failed("index exceeded configured resource limits") }
            return false
        }
        store = s
        storeComplete = complete
        setStatus { $0.itemCount = s.count }
        let cb = lock.withLock { _onStoreChanged }
        callbackQueue.async { cb?(s) }
        return true
    }

    /// Mutate status under the lock and deliver one coalesced callback.
    private func setStatus(_ f: (inout IndexStatus) -> Void) {
        let schedule: Bool = lock.withLock {
            f(&_status)
            let s = !statusCallbackPending
            statusCallbackPending = true
            return s
        }
        guard schedule else { return }
        callbackQueue.async { [self] in
            let delivery: (IndexStatus, (@Sendable (IndexStatus) -> Void)?) = lock.withLock {
                statusCallbackPending = false
                return (_status, _onStatusChanged)
            }
            delivery.1?(delivery.0)
        }
    }

    // MARK: Cancellation / queue helpers

    private var isCancelRequested: Bool { lock.withLock { cancelRequested } }
    private func requestCancel() { lock.withLock { cancelRequested = true } }
    private func clearCancel() { lock.withLock { cancelRequested = false } }

    /// Run `body` on the queue synchronously (inline if already on it).
    @discardableResult
    private func runOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 { return body() }
        return queue.sync(execute: body)
    }
}
