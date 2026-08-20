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

    /// Heap box handed to FSEvents as the context `info`. Holds the watcher weakly so a late callback after `deinit`
    /// is a no-op; FSEvents releases the box via the context `release` callback when the stream is released.
    private final class Context {
        weak var watcher: FSEventsWatcher?
        init(_ w: FSEventsWatcher) { watcher = w }
    }

    /// `handler` is invoked on `queue`.
    public init(paths: [String], sinceWhen: UInt64 = 0, latency: TimeInterval = 1.0, queue: DispatchQueue, handler: @escaping (FSEventsBatch) -> Void) {
        self.paths = paths; self.latency = latency; self.latestEventId = sinceWhen
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
        lock.lock()
        guard let s = stream else { lock.unlock(); return }
        let streamLatest = FSEventStreamGetLatestEventId(s)
        let maxId = ids.max() ?? 0
        let latest = streamLatest != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) ? max(streamLatest, maxId) : max(latestEventId, maxId)
        latestEventId = latest
        lock.unlock()
        let (changes, full) = FSEventsWatcher.mapEvents(paths: paths, flags: flags, roots: self.paths)
        handler(FSEventsBatch(changes: changes, needsFullRescan: full, latestEventId: latest))
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
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (changes: [IndexUpdater.Change], needsFullRescan: Bool) {
        let rootSet = Set(roots.map(stripTrailingSlash))
        var order: [String] = []
        var recursive: [String: Bool] = [:]
        var full = false
        func add(_ path: String, _ rec: Bool) {
            if let existing = recursive[path] {
                if rec && !existing { recursive[path] = true }
            } else {
                order.append(path); recursive[path] = rec
            }
        }
        for (i, rawPath) in paths.enumerated() {
            let f = i < flags.count ? flags[i] : 0
            if f & FSEventsWatcher.fullRescanFlags != 0 { full = true }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = FSEventsWatcher.stripTrailingSlash(rawPath)
            guard !path.isEmpty else { continue }
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                add(path, true)
                continue
            }
            add(rootSet.contains(path) ? path : FSEventsWatcher.dirname(path), false)
            let isDir = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let createdOrRenamed = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
            if isDir && createdOrRenamed && exists(path) {
                // A renamed-in directory brings its whole subtree without per-file events → recursive.
                add(path, f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0)
            }
        }
        let changes = order.map { IndexUpdater.Change(path: $0, mustScanSubDirs: recursive[$0] ?? false) }
        return (changes, full)
    }

    /// Parent directory of `path` (`/a/b/c` → `/a/b`, `/a` → `/`, `/` → `/`).
    static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    /// Remove trailing slashes (but keep `/`).
    static func stripTrailingSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
