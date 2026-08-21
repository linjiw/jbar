import Foundation
import CoreServices

/// A coalesced batch of file-system changes.
public struct FSEventsBatch: Sendable, Equatable {
    public var changes: [IndexUpdater.Change]
    /// Set when the kernel/user dropped events, ids wrapped, a root changed, or history replay is unreliable → full recrawl.
    public var needsFullRescan: Bool
    public var latestEventId: UInt64
    public init(changes: [IndexUpdater.Change], needsFullRescan: Bool, latestEventId: UInt64) {
        self.changes = changes; self.needsFullRescan = needsFullRescan; self.latestEventId = latestEventId
    }
}

/// Thin wrapper over one FSEventStream covering all roots. DESIGN.md §4.6. Owner: watcher/config agent.
///
/// `FSEventStreamCreate(nil, cb, &ctx, paths, sinceWhen, latency, kFSEventStreamCreateFlagFileEvents | UseCFTypes | NoDefer | IgnoreSelf | WatchRoot)`
/// + `FSEventStreamSetDispatchQueue` (NOT ScheduleWithRunLoop — deprecated) + `FSEventStreamStart`.
/// Delivers batches on `queue` after `latency` seconds; for FileEvents the path is the FILE path — the watcher reports the
/// PARENT directory (deduped) so the updater re-lists directories. `kFSEventStreamEventFlagMustScanSubDirs` → mustScanSubDirs.
/// `sinceWhen == 0` → `kFSEventStreamEventIdSinceNow`. Needs no TCC permission.
///
/// Event mapping (see `FSEventsWatcher.mapEvents`): every event path `p` yields `dirname(p)` (non-recursive re-list);
/// a directory that was created/renamed-in additionally yields `p` itself (recursive for renames, because FSEvents does
/// not report the contents of a moved-in tree); `MustScanSubDirs` yields `p` recursively. `UserDropped`, `KernelDropped`,
/// `EventIdsWrapped`, `RootChanged`, `Mount`, `Unmount` set `needsFullRescan`; `HistoryDone` is ignored. Changes are
/// de-duplicated by path (recursive wins). Note `IgnoreSelf`: changes made by this process are not reported.
public final class FSEventsWatcher {
    public let paths: [String]
    public let latency: TimeInterval
    /// Last event id seen (updated on every batch, on `stop()` and by `currentEventId()`). Read it via
    /// `currentEventId()` from other threads; the property itself is not synchronised.
    public private(set) var latestEventId: UInt64

    private let queue: DispatchQueue
    private let handler: (FSEventsBatch) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Hard ceilings are deliberately below any allocation that could destabilize the process. A
    /// larger kernel batch is still consumed once for flags/ids, then converted to a full-rescan
    /// marker without bridging/copying attacker-controlled paths.
    static let maxRawEventsPerBatch = 4_096
    static let maxUniquePathsPerBatch = IndexUpdater.fullRecrawlThreshold

    /// Heap box handed to FSEvents as the context `info`. Holds the watcher weakly so a late callback after `deinit`
    /// is a no-op; FSEvents releases the box via the context `release` callback when the stream is released.
    private final class Context {
        weak var watcher: FSEventsWatcher?
        init(_ w: FSEventsWatcher) { watcher = w }
    }

    /// `handler` is invoked on `queue`.
    public init(paths: [String], sinceWhen: UInt64 = 0, latency: TimeInterval = 1.0, queue: DispatchQueue, handler: @escaping (FSEventsBatch) -> Void) {
        // Public embedding callers can bypass Config validation. Bound roots before constructing a
        // CFArray, and normalize non-finite/negative latency before handing it to the C API.
        self.paths = Array(paths.prefix(SafetyLimits.maxRootEntries)).filter {
            SafetyLimits.isSafeAbsolutePath($0)
        }
        self.latency = latency.isFinite ? max(0, latency) : 1.0
        self.latestEventId = sinceWhen
        self.queue = queue
        self.handler = handler
    }

    /// Create-flags used for the stream (DESIGN.md §4.6).
    public static let createFlags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)

    /// Start the stream. Returns false if creation/start failed. Idempotent (a running stream returns true).
    @discardableResult public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stream != nil { return true }
        guard !paths.isEmpty else { return false }
        // First start: the caller's sinceWhen (0 → now). Restart after stop(): resume from the last id we saw so the gap is replayed.
        let since: FSEventStreamEventId = latestEventId == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : latestEventId
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passRetained(Context(self)).toOpaque(),
                                       retain: nil,
                                       release: { info in if let info = info { Unmanaged<Context>.fromOpaque(info).release() } },
                                       copyDescription: nil)
        guard let s = FSEventStreamCreate(nil, FSEventsWatcher.callback, &ctx, paths as CFArray, since, latency, FSEventsWatcher.createFlags) else {
            // FSEvents did not take ownership of the context → release it ourselves.
            Unmanaged<Context>.fromOpaque(ctx.info!).release()
            return false
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        if latestEventId == 0 {
            // "Now" as a concrete id, so a snapshot written before the first event can still be replayed from.
            latestEventId = FSEventsGetCurrentEventId()
        }
        return true
    }

    /// Stop + invalidate + release the stream. Safe to call twice. A batch already being delivered on `queue` may still
    /// reach the handler right after `stop()` returns. A later `start()` resumes from the last seen event id.
    public func stop() {
        // Detach the stream under the lock, then tear it down outside the lock so a callback blocked on the lock
        // (or FSEvents waiting for that callback) cannot deadlock with us.
        lock.lock()
        guard let s = stream else { lock.unlock(); return }
        let id = FSEventStreamGetLatestEventId(s)
        if id != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) { latestEventId = id }
        stream = nil
        lock.unlock()
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// Current last event id (`FSEventStreamGetLatestEventId`) — persist in snapshot headers.
    /// Before the first event on a `sinceNow` stream this is `FSEventsGetCurrentEventId()` taken at `start()`.
    public func currentEventId() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let s = stream {
            let id = FSEventStreamGetLatestEventId(s)
            if id != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) { latestEventId = id }
        }
        return latestEventId
    }

    /// True while the stream is running.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    deinit { stop() }

    // MARK: - Callback

    /// The C callback: unwraps the context box and forwards to the live watcher (if any).
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIds in
        guard let info = info, let watcher = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        guard numEvents <= FSEventsWatcher.maxRawEventsPerBatch else {
            // Do not bridge the CFString paths in an oversized batch. One allocation-free pass over
            // fixed-size metadata preserves the newest replay id and observes reliability flags.
            let summary = FSEventsWatcher.summarizeOversizedBatch(count: numEvents,
                                                                   flags: eventFlags, ids: eventIds)
            watcher.deliverOversized(latestRawEventId: summary.latestEventId,
                                     observedFullRescanFlag: summary.observedFullRescanFlag)
            return
        }
        // UseCFTypes → eventPaths is a CFArray of CFString.
        let array = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(eventPaths)).takeUnretainedValue()
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for i in 0..<numEvents {
            let value = CFArrayGetValueAtIndex(array, i)
            paths.append(value.map { unsafeBitCast($0, to: CFString.self) as String } ?? "")
        }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
        let ids = Array(UnsafeBufferPointer(start: eventIds, count: numEvents))
        watcher.deliver(paths: paths, flags: flags, ids: ids)
    }

    /// Build and deliver a batch (already on `queue`). Skips delivery if the stream was stopped meanwhile.
    private func deliver(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        let maxId = ids.max() ?? 0
        guard let latest = updateLatestEventId(rawMaximum: maxId) else { return }
        let (changes, full) = FSEventsWatcher.mapEvents(paths: paths, flags: flags, roots: self.paths)
        handler(FSEventsBatch(changes: changes, needsFullRescan: full, latestEventId: latest))
    }

    /// Deliver the fail-closed representation of an oversized raw callback. `observedFullRescanFlag`
    /// is intentionally retained in the common summary contract even though size alone requires a
    /// full rescan; this proves the metadata pass examined both arrays without retaining either.
    private func deliverOversized(latestRawEventId: UInt64, observedFullRescanFlag: Bool) {
        _ = observedFullRescanFlag
        guard let latest = updateLatestEventId(rawMaximum: latestRawEventId) else { return }
        handler(FSEventsBatch(changes: [], needsFullRescan: true, latestEventId: latest))
    }

    private func updateLatestEventId(rawMaximum: UInt64) -> UInt64? {
        lock.lock()
        guard let s = stream else { lock.unlock(); return nil }
        let streamLatest = FSEventStreamGetLatestEventId(s)
        let latest = streamLatest != FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            ? max(streamLatest, rawMaximum) : max(latestEventId, rawMaximum)
        latestEventId = latest
        lock.unlock()
        return latest
    }

    struct OversizedBatchSummary: Equatable {
        var latestEventId: UInt64
        var observedFullRescanFlag: Bool
    }

    /// Allocation-free single-pass metadata reduction used before any oversized callback paths are
    /// bridged. Internal visibility is a deterministic test seam for the C callback boundary.
    static func summarizeOversizedBatch(count: Int,
                                        flags: UnsafePointer<FSEventStreamEventFlags>,
                                        ids: UnsafePointer<FSEventStreamEventId>) -> OversizedBatchSummary {
        var latest: UInt64 = 0
        var observedFullRescanFlag = false
        guard count > 0 else { return OversizedBatchSummary(latestEventId: 0, observedFullRescanFlag: false) }
        for index in 0..<count {
            latest = max(latest, ids[index])
            if flags[index] & fullRescanFlags != 0 { observedFullRescanFlag = true }
        }
        return OversizedBatchSummary(latestEventId: latest,
                                     observedFullRescanFlag: observedFullRescanFlag)
    }

    // MARK: - Event mapping (pure, testable)

    /// Flags that make incremental replay unreliable → full recrawl.
    static let fullRescanFlags: FSEventStreamEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    /// Map raw FSEvents (path, flags) pairs to de-duplicated directory changes. `roots` are the watched roots: an event
    /// on a root itself re-lists the root (never its parent, which is outside the watched tree). `exists` is injectable
    /// for tests (default: `FileManager.fileExists`), used to decide whether a created/renamed directory should itself be listed.
    static func mapEvents(paths: [String], flags: [FSEventStreamEventFlags], roots: [String] = [],
                          rawEventLimit: Int = maxRawEventsPerBatch,
                          uniquePathLimit: Int = maxUniquePathsPerBatch,
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (changes: [IndexUpdater.Change], needsFullRescan: Bool) {
        let rawLimit = min(max(0, rawEventLimit), maxRawEventsPerBatch)
        let uniqueLimit = min(max(0, uniquePathLimit), maxUniquePathsPerBatch)
        // This guard runs before root-set/dictionary allocation and before any filesystem probe.
        guard paths.count <= rawLimit else { return ([], true) }
        let rootSet = Set(roots.map(stripTrailingSlash))
        var order: [String] = []
        var recursive: [String: Bool] = [:]
        var uniquePaths = Set<String>()
        var existence = [String: Bool]()
        var full = false
        func add(_ path: String, _ rec: Bool) -> Bool {
            if let existing = recursive[path] {
                if rec && !existing { recursive[path] = true }
            } else {
                guard order.count < uniqueLimit else { return false }
                order.append(path); recursive[path] = rec
            }
            return true
        }
        for (i, rawPath) in paths.enumerated() {
            let f = i < flags.count ? flags[i] : 0
            if f & FSEventsWatcher.fullRescanFlags != 0 { full = true }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            guard SafetyLimits.utf8Fits(rawPath, maxBytes: SafetyLimits.maxPathUTF8Bytes) else {
                return ([], true)
            }
            let path = FSEventsWatcher.stripTrailingSlash(rawPath)
            guard !path.isEmpty else { continue }
            if uniquePaths.insert(path).inserted, uniquePaths.count > uniqueLimit {
                return ([], true)
            }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                guard add(path, true) else { return ([], true) }
                continue
            }
            guard add(rootSet.contains(path) ? path : FSEventsWatcher.dirname(path), false) else {
                return ([], true)
            }
            let isDir = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let createdOrRenamed = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            let pathExists: Bool
            if let cached = existence[path] {
                pathExists = cached
            } else if isDir && createdOrRenamed {
                pathExists = exists(path)
                existence[path] = pathExists
            } else {
                pathExists = false
            }
            if isDir && createdOrRenamed && pathExists {
                // A renamed-in directory brings its whole subtree without per-file events → recursive.
                guard add(path, f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0) else {
                    return ([], true)
                }
            }
        }
        let changes = order.map { IndexUpdater.Change(path: $0, mustScanSubDirs: recursive[$0] ?? false) }
        return (changes, full)
    }

    /// Parent directory of `path` (`/a/b/c` → `/a/b`, `/a` → `/`, `/` → `/`).
    static func dirname(_ path: String) -> String {
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: 0x2F) else { return "." }
        if slash == 0 { return "/" }
        return String(decoding: bytes[..<slash], as: UTF8.self)
    }

    /// Remove trailing slashes (but keep `/`).
    static func stripTrailingSlash(_ path: String) -> String {
        SafetyLimits.trimmingTrailingPathSlashes(path)
    }
}
