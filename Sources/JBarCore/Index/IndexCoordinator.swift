import Foundation
import CoreServices

/// Observable status of the index, for the menu bar.
public struct IndexStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, loadingSnapshot, scanningApps, crawling(progress: Int), updating, failed(String) }
    public var phase: Phase = .idle
    public var itemCount: Int = 0
    public var appCount: Int = 0
    public var lastBuilt: Date? = nil
    public var deniedPaths: [String] = []
    public var cappedDirs: [String] = []
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

    public private(set) var store: IndexStore {
        get { lock.withLock { _store } }
        set { lock.withLock { _store = newValue } }
    }
    public private(set) var status: IndexStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Called (on callbackQueue) whenever a new store generation is published.
    public var onStoreChanged: ((IndexStore) -> Void)?
    /// Called (on callbackQueue) whenever `status` changes.
    public var onStatusChanged: ((IndexStatus) -> Void)?

    // Queue-confined state.
    private var options: Options
    private var started = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var apps: [ScannedApp] = []
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

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    public init(options: Options, callbackQueue: DispatchQueue = .main) {
        self.options = options
        self.callbackQueue = callbackQueue
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
            if let snap = loadSnapshot() {
                publish(IndexCoordinator.rebuildStore(apps: apps, filesFrom: snap, generation: nextGeneration(), fsEventId: snap.fsEventId), complete: true)
                appliedEventId = snap.fsEventId
                dirty = true
                setStatus { $0.phase = .idle; $0.lastBuilt = snap.builtAt }
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
            try? FileManager.default.removeItem(at: options.snapshotURL)
            rescanAppsInternal(publishNow: false)
            fullCrawl()
            if watcher == nil { startWatcher() }
        }
    }

    /// Re-scan only the app roots (cheap; call on app-root FSEvents and on every launch).
    public func rescanApps() {
        queue.async { [self] in
            guard !stopped else { return }
            rescanAppsInternal(publishNow: true)
        }
    }

    /// Apply new options (e.g. config hot reload). If roots/exclusions changed → rebuild, else just re-register the watcher.
    public func update(options new: Options) {
        let old = runOnQueue { options }
        let indexChanged = IndexCoordinator.indexInputsDiffer(old, new)
        if indexChanged { requestCancel() }
        queue.async { [self] in
            options = new
            guard started, !stopped else { return }
            if indexChanged {
                try? FileManager.default.removeItem(at: old.snapshotURL)
                rescanAppsInternal(publishNow: false)
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

    // MARK: Apps

    private func scanAppsAndPublish() {
        setStatus { $0.phase = .scanningApps }
        apps = AppScanner.scan(roots: options.appRoots, extraBundles: AppScanner.extraBundles, home: options.home)
        let b = IndexBuilder()
        AppScanner.add(apps, to: b)
        publish(b.build(generation: nextGeneration()), complete: false)
        setStatus { $0.appCount = self.apps.count }
    }

    private func rescanAppsInternal(publishNow: Bool) {
        apps = AppScanner.scan(roots: options.appRoots, extraBundles: AppScanner.extraBundles, home: options.home)
        setStatus { $0.appCount = self.apps.count }
        guard publishNow else { return }
        let merged = IndexCoordinator.rebuildStore(apps: apps, filesFrom: store, generation: nextGeneration(), fsEventId: store.fsEventId)
        publish(merged, complete: storeComplete)
        if storeComplete { dirty = true }
    }

    /// Fresh app items + every non-app item of `base` (scanner apps removed, crawled files kept, dir ids stable).
    static func rebuildStore(apps: [ScannedApp], filesFrom base: IndexStore?, generation: UInt64, fsEventId: UInt64) -> IndexStore {
        let b = IndexBuilder()
        AppScanner.add(apps, to: b)
        guard let base = base else { return b.build(generation: generation, fsEventId: fsEventId) }
        let keep = (0..<base.count).filter { !StoreMerge.isScannerApp(base, $0) }
        return StoreMerge.merge(base: base, keep: keep, extra: b.build(generation: 0), rootMap: [:], generation: generation, fsEventId: fsEventId)
    }

    // MARK: Snapshot

    private var headerHash: UInt64 {
        Snapshot.headerHash(exclusions: options.exclusions, roots: fileRootPaths() + appRootPaths())
    }

    private func loadSnapshot() -> IndexStore? {
        setStatus { $0.phase = .loadingSnapshot }
        guard let s = Snapshot.read(from: options.snapshotURL, expectedHeaderHash: headerHash) else { return nil }
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
            let roots = entry == "~" ? Crawler.defaultRoots(home: options.home, exclusions: options.exclusions)
                                      : [CrawlRoot(path: Exclusions.expandTilde(entry, home: options.home))]
            for r in roots where seen.insert(r.path).inserted { out.append(r) }
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
        setStatus { $0.phase = .crawling(progress: 0); $0.deniedPaths = []; $0.cappedDirs = []; $0.hitItemCap = false }
        let eventId = options.watchFileSystem ? UInt64(FSEventsGetCurrentEventId()) : 0
        let builder = IndexBuilder()
        builder.reserve(items: max(store.count, 50_000), dirs: max(store.dirs.count, 5_000))
        AppScanner.add(apps, to: builder)
        storeComplete = false
        var lastPublish = Date()
        let stats = makeCrawler().crawl(into: builder, onBatch: { [self] b in
            guard Date().timeIntervalSince(lastPublish) >= IndexCoordinator.publishInterval else { return }
            lastPublish = Date()
            publish(b.build(generation: nextGeneration(), fsEventId: eventId), complete: false)
            setStatus { $0.phase = .crawling(progress: b.count) }
        }, shouldCancel: { [self] in isCancelRequested })
        lastCrawlStats = stats
        if stats.cancelled {
            setStatus { $0.phase = .idle }
            return
        }
        publish(builder.build(generation: nextGeneration(), fsEventId: eventId), complete: true)
        appliedEventId = eventId
        dirty = true
        setStatus {
            $0.phase = .idle; $0.deniedPaths = stats.deniedPaths; $0.cappedDirs = stats.cappedDirs
            $0.hitItemCap = stats.hitItemCap; $0.lastBuilt = Date()
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
            rescanAppsInternal(publishNow: true)
        }
        let crawler = makeCrawler()
        let fileChanges = batch.changes.filter { IndexUpdater.isUnderRoots($0.path, crawler: crawler) }
        if !fileChanges.isEmpty {
            setStatus { $0.phase = .updating }
            if let s = IndexUpdater.apply(changes: fileChanges, to: store, crawler: crawler, generation: nextGeneration(), fsEventId: batch.latestEventId) {
                publish(s, complete: true)
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
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: Publishing / status

    private func nextGeneration() -> UInt64 { generation += 1; return generation }

    private func publish(_ s: IndexStore, complete: Bool) {
        store = s
        storeComplete = complete
        setStatus { $0.itemCount = s.count }
        let cb = onStoreChanged
        callbackQueue.async { cb?(s) }
    }

    /// Mutate status under the lock and deliver one coalesced callback.
    private func setStatus(_ f: @escaping (inout IndexStatus) -> Void) {
        let schedule: Bool = lock.withLock {
            f(&_status)
            let s = !statusCallbackPending
            statusCallbackPending = true
            return s
        }
        guard schedule else { return }
        callbackQueue.async { [self] in
            let s: IndexStatus = lock.withLock { statusCallbackPending = false; return _status }
            onStatusChanged?(s)
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
