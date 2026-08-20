import Darwin
import Foundation

// Swift does not import Darwin's variadic `openat` for the no-create form. The POSIX ABI still
// accepts the conventional fourth mode argument (ignored without O_CREAT), so bind that fixed
// signature explicitly. Keeping the operation descriptor-relative is the security boundary here.
@_silgen_name("openat")
private func jbarOpenAt(_ directoryFD: Int32, _ path: UnsafePointer<CChar>,
                        _ flags: Int32, _ mode: mode_t) -> Int32

/// A tiny lock-guarded boolean shared across the parallel crawl's worker threads.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
}

/// A shared item counter that enforces a GLOBAL cap across the parallel crawl's per-root builders:
/// `reserve()` atomically claims one slot iff the running total is still under `max`, so the merged
/// store never exceeds `max` items no matter how many roots crawl concurrently.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int
    init(_ initial: Int = 0) { v = initial }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    /// Claim one slot; returns false (claiming nothing) once `v` has reached `max`.
    func reserve(max: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if v >= max { return false }; v += 1; return true }
    /// Return a previously claimed slot when the downstream bounded builder rejects the item.
    func release() { lock.lock(); defer { lock.unlock() }; precondition(v > 0); v -= 1 }
}

/// Lock-isolated synchronization hooks used only by deterministic race tests. Keeping them in a
/// Sendable container lets the production `Crawler` remain immutable while tests coordinate an
/// exact filesystem swap point without introducing mutable closure storage on the crawler itself.
private final class CrawlerTestHooks: @unchecked Sendable {
    typealias Hook = @Sendable (String) -> Void

    private let lock = NSLock()
    private var beforeOpening: Hook?
    private var afterOpening: Hook?
    private var afterSubmittingRoot: Hook?

    func getBeforeOpening() -> Hook? { lock.lock(); defer { lock.unlock() }; return beforeOpening }
    func setBeforeOpening(_ hook: Hook?) { lock.lock(); beforeOpening = hook; lock.unlock() }
    func getAfterOpening() -> Hook? { lock.lock(); defer { lock.unlock() }; return afterOpening }
    func setAfterOpening(_ hook: Hook?) { lock.lock(); afterOpening = hook; lock.unlock() }
    func getAfterSubmittingRoot() -> Hook? { lock.lock(); defer { lock.unlock() }; return afterSubmittingRoot }
    func setAfterSubmittingRoot(_ hook: Hook?) { lock.lock(); afterSubmittingRoot = hook; lock.unlock() }

    func invokeBeforeOpening(_ path: String) {
        let hook = getBeforeOpening()
        hook?(path)
    }

    func invokeAfterOpening(_ path: String) {
        let hook = getAfterOpening()
        hook?(path)
    }

    func invokeAfterSubmittingRoot(_ path: String) {
        let hook = getAfterSubmittingRoot()
        hook?(path)
    }
}

/// Identity captured with `fstatat(..., AT_SYMLINK_NOFOLLOW)` while a parent descriptor is held.
/// A child is descended only if the descriptor opened later has the same identity.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

private enum DirectorySafetyError: Error {
    case system(Int32)
    case notDirectory
    case identityChanged
    case outsideRoot

    var errorCode: Int32? {
        if case .system(let code) = self { return code }
        return nil
    }
}

/// One directory entry captured without following links. `cName` preserves the exact file-system
/// bytes for later `fstatat`/`openat` calls; `name` is only the safe display/index representation.
private struct PhysicalDirectoryEntry {
    let cName: [CChar] // NUL terminated
    let name: String
    let info: stat

    var identity: FileIdentity { FileIdentity(info) }
    var isSymbolicLink: Bool { info.st_mode & S_IFMT == S_IFLNK }
    var isDirectory: Bool { info.st_mode & S_IFMT == S_IFDIR }
    var isHidden: Bool { SafetyLimits.hasDotPrefix(name) || info.st_flags & UInt32(UF_HIDDEN) != 0 }
    var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
             + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

private struct PhysicalDirectoryListing {
    let entries: [PhysicalDirectoryEntry]
    let truncation: Truncation?

    enum Truncation: Equatable {
        case directoryLimit
        case crawlBudget
    }
}

/// RAII wrapper around an opened physical directory. Descendants are opened relative to this
/// descriptor, never by re-resolving a queued absolute path.
private final class OpenDirectory {
    let fd: Int32
    let info: stat
    let resolvedPath: String

    private init(fd: Int32, info: stat, resolvedPath: String) {
        self.fd = fd
        self.info = info
        self.resolvedPath = resolvedPath
    }

    deinit { _ = Darwin.close(fd) }

    static func root(at path: String) throws -> OpenDirectory {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DirectorySafetyError.system(errno) }
        do { return try validate(fd: fd, expected: nil, rootBoundary: nil) }
        catch { _ = Darwin.close(fd); throw error }
    }

    func child(named cName: [CChar], expected: FileIdentity, rootBoundary: String) throws -> OpenDirectory {
        let childFD = cName.withUnsafeBufferPointer {
            jbarOpenAt(fd, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0))
        }
        guard childFD >= 0 else { throw DirectorySafetyError.system(errno) }
        do { return try OpenDirectory.validate(fd: childFD, expected: expected, rootBoundary: rootBoundary) }
        catch { _ = Darwin.close(childFD); throw error }
    }

    func child(component: String, rootBoundary: String) throws -> OpenDirectory {
        guard SafetyLimits.isSafePathComponent(component,
                                               maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes) else {
            throw DirectorySafetyError.outsideRoot
        }
        return try component.withCString { cName in
            let childFD = jbarOpenAt(fd, cName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0))
            guard childFD >= 0 else { throw DirectorySafetyError.system(errno) }
            do { return try OpenDirectory.validate(fd: childFD, expected: nil, rootBoundary: rootBoundary) }
            catch { _ = Darwin.close(childFD); throw error }
        }
    }

    /// Re-read the descriptor's physical path immediately around enumeration. A directory can be
    /// renamed after it was opened; descriptor-relative I/O still prevents substitution, while this
    /// check additionally refuses to publish names if that same directory has moved outside the root.
    func requireInside(_ rootBoundary: String) throws {
        let currentPath = try OpenDirectory.path(of: fd)
        guard Crawler.path(currentPath, isWithin: rootBoundary) else {
            throw DirectorySafetyError.outsideRoot
        }
    }

    /// Inspect at most `limit + 1` non-dot names and retain at most `limit` visible entries. This
    /// avoids Foundation's unbounded URL array and stops even hidden/churning directories as soon as
    /// their actual traversal work is known to be over the product cap.
    func entries(limit: Int, includeHidden: Bool, rootBoundary: String? = nil,
                 claimCrawlBudget: () -> Bool = { true }) throws -> PhysicalDirectoryListing {
        if let rootBoundary { try requireInside(rootBoundary) }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw DirectorySafetyError.system(errno) }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            _ = Darwin.close(duplicate)
            throw DirectorySafetyError.system(code)
        }
        defer { closedir(stream) }

        var result: [PhysicalDirectoryEntry] = []
        result.reserveCapacity(min(limit, 4_096))
        var inspectedNames = 0
        while true {
            errno = 0
            guard let pointer = readdir(stream) else {
                if errno != 0 { throw DirectorySafetyError.system(errno) }
                break
            }
            var raw = pointer.pointee.d_name
            let length = Int(pointer.pointee.d_namlen)
            let cName: [CChar] = withUnsafePointer(to: &raw) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    var bytes = Array(UnsafeBufferPointer(start: $0, count: length))
                    bytes.append(0)
                    return bytes
                }
            }
            let name = String(decoding: cName.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "." || name == ".." { continue }
            // Count every non-dot directory name, not only visible/fstat-successful entries. Otherwise
            // millions of hidden or concurrently vanishing names could keep memory bounded yet bypass
            // the traversal-work limit and stall indexing.
            guard claimCrawlBudget() else {
                return PhysicalDirectoryListing(entries: result, truncation: .crawlBudget)
            }
            inspectedNames += 1
            if inspectedNames > limit {
                return PhysicalDirectoryListing(entries: result, truncation: .directoryLimit)
            }
            if !includeHidden && SafetyLimits.hasDotPrefix(name) { continue }

            var entryInfo = stat()
            let status = cName.withUnsafeBufferPointer {
                fstatat(fd, $0.baseAddress, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0 {
                // Concurrent removal is expected. Permission failures on the containing directory
                // are surfaced by readdir/open; an individual vanished name is simply skipped.
                continue
            }
            if !includeHidden && entryInfo.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
            result.append(PhysicalDirectoryEntry(cName: cName, name: name, info: entryInfo))
        }
        if let rootBoundary { try requireInside(rootBoundary) }
        return PhysicalDirectoryListing(entries: result, truncation: nil)
    }

    private static func validate(fd: Int32, expected: FileIdentity?, rootBoundary: String?) throws -> OpenDirectory {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DirectorySafetyError.system(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DirectorySafetyError.notDirectory }
        if let expected, FileIdentity(info) != expected { throw DirectorySafetyError.identityChanged }

        let path = try path(of: fd)
        if let rootBoundary, !Crawler.path(path, isWithin: rootBoundary) {
            throw DirectorySafetyError.outsideRoot
        }
        return OpenDirectory(fd: fd, info: info, resolvedPath: path)
    }

    private static func path(of fd: Int32) throws -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &pathBuffer) == 0 else {
            throw DirectorySafetyError.system(errno)
        }
        return String(cString: pathBuffer)
    }
}

/// A file-system root to crawl.
public struct CrawlRoot: Sendable, Equatable {
    public var path: String          // absolute
    public var maxDepth: Int?        // overrides Exclusions.maxDepth if set
    public var cloud: Bool           // names-only, background QoS, budgeted (not used in v1 by default)
    public var timeBudget: TimeInterval? // monotonic elapsed-time cap for this root (cloud roots)
    public init(path: String, maxDepth: Int? = nil, cloud: Bool = false, timeBudget: TimeInterval? = nil) {
        self.path = path; self.maxDepth = maxDepth; self.cloud = cloud; self.timeBudget = timeBudget
    }
}

/// What happened during a crawl (shown in the menu bar status).
public struct CrawlStats: Sendable, Equatable {
    public var items: Int = 0
    public var dirs: Int = 0
    /// Number of physical non-dot directory names inspected. Hidden and concurrently vanished names
    /// count too, because they consume the same kernel and metadata work as visible entries.
    public var inspectedNames: Int = 0
    public var skippedExcluded: Int = 0
    public var deniedPaths: [String] = []      // TCC denial / EACCES on a root or subdir
    public var cappedDirs: [String] = []       // > maxDirEntries
    /// Entries/directories skipped because descriptor-relative validation detected a symlink,
    /// replacement, or a resolved path outside the configured root. This is deliberately a count:
    /// status can explain the safety decision without retaining/logging sensitive paths.
    public var skippedUnsafe: Int = 0
    public var hitItemCap: Bool = false
    public var duration: TimeInterval = 0
    public var cancelled: Bool = false
    public init() {}
}

/// Enumerates files/folders under roots into an `IndexBuilder`. DESIGN.md §4.2–4.5. Owner: indexer agent.
///
/// Implementation: an explicit descriptor-relative depth-first walk. Each directory is streamed with
/// `fdopendir`/`readdir`; entry metadata comes from `fstatat(..., AT_SYMLINK_NOFOLLOW)`, and descent uses
/// `openat(..., O_NOFOLLOW | O_DIRECTORY)` plus device/inode and physical-root validation. At most
/// `maxDirEntries + 1` names are retained, which drives both the cap and `downrankDirEntries` rule.
/// Symlinks are recorded as items but never resolved for descent. Directories are items too (kind .folder).
/// .app bundles found under file roots are NOT added (AppScanner owns apps) unless `indexAppBundlesAsApps` is true
/// (then added as kind .app with an `AppInfo`, bundleID nil). Packages other than .app are leaf items (`.package`).
///
/// Directory table layout: for a root `/Users/me/Desktop` the builder gets a root entry for the PARENT
/// (`/Users/me`, parent -1, shared by all roots with that parent), an item `Desktop` (kind .folder, depth 0) in it,
/// and a child dir entry `Desktop` under which the root's contents live (depth 1 = direct children of the root).
/// `/` as a root gets a single root entry and no item.
///
/// Publishes partial generations via `onBatch` every ~5k items so the UI can show results during the first crawl.
/// Roots are crawled in the order given (`defaultRoots` already orders Desktop > Documents > Downloads > projects > rest).
public final class Crawler: Sendable {
    public let roots: [CrawlRoot]
    public let exclusions: Exclusions
    public let maxItems: Int
    public let indexAppBundlesAsApps: Bool

    /// Items between two `onBatch` calls.
    public static let batchSize = 5_000
    /// Entries between two `shouldCancel` polls.
    public static let cancelPollInterval = 1_000
    /// A programmatic `Exclusions` value must not turn one directory into an unbounded allocation.
    /// The shipped default is 20k; 100k leaves substantial headroom while bounding names to ~25 MiB.
    static let hardMaxDirectoryEntries = 100_000
    /// Process-wide traversal-work ceiling for one crawl. Unlike `maxDirEntries`, this is shared by
    /// every directory and every concurrently crawled root, so a wide tree cannot multiply the
    /// per-directory allowance. Four million names leaves room for the maximum two-million-item
    /// product index plus excluded/hidden entries while keeping hostile work finite.
    public static let maxInspectedNames = 4_000_000
    /// Keep status diagnostics useful without retaining an attacker-controlled number of paths.
    static let maxReportedPaths = 128

    private let pathMatcher: ExcludedPathMatcher
    private let directoryEntryLimit: Int
    private let downrankEntryThreshold: Int
    private let inspectedNameLimit: Int
    private let monotonicNow: @Sendable () -> UInt64
    private let testHooks = CrawlerTestHooks()

    /// Test-only synchronization point. Production leaves this nil. Tests use it to perform a
    /// deterministic directory-to-symlink swap after classification but before descent.
    var beforeOpeningDirectoryForTesting: (@Sendable (String) -> Void)? {
        get { testHooks.getBeforeOpening() }
        set { testHooks.setBeforeOpening(newValue) }
    }
    /// Deterministic test point for a rename after `openat` validation but before enumeration.
    var afterOpeningDirectoryForTesting: (@Sendable (String) -> Void)? {
        get { testHooks.getAfterOpening() }
        set { testHooks.setAfterOpening(newValue) }
    }
    /// Deterministic test point after a parallel root result is buffered/merged.
    var afterSubmittingRootForTesting: (@Sendable (String) -> Void)? {
        get { testHooks.getAfterSubmittingRoot() }
        set { testHooks.setAfterSubmittingRoot(newValue) }
    }

    public convenience init(roots: [CrawlRoot], exclusions: Exclusions, maxItems: Int = 1_000_000,
                            indexAppBundlesAsApps: Bool = true) {
        self.init(roots: roots, exclusions: exclusions, maxItems: maxItems,
                  indexAppBundlesAsApps: indexAppBundlesAsApps,
                  inspectedNameLimit: Crawler.maxInspectedNames,
                  monotonicNow: { DispatchTime.now().uptimeNanoseconds })
    }

    /// Internal dependency seam for deterministic resource/deadline tests. Production callers use
    /// the public initializer above and therefore cannot raise the hard traversal ceiling.
    init(roots: [CrawlRoot], exclusions: Exclusions, maxItems: Int = 1_000_000,
         indexAppBundlesAsApps: Bool = true, inspectedNameLimit: Int,
         monotonicNow: @escaping @Sendable () -> UInt64) {
        self.roots = Array(roots.prefix(SafetyLimits.maxRootEntries)).compactMap { root in
            let raw = root.path
            guard SafetyLimits.isSafeAbsoluteOrTildePath(raw) else { return nil }
            let expanded = Exclusions.expandTilde(raw, home: NSHomeDirectory())
            guard SafetyLimits.isSafeAbsolutePath(expanded) else { return nil }
            var normalized = root
            normalized.path = SafetyLimits.trimmingTrailingPathSlashes(expanded)
            return normalized
        }
        self.exclusions = exclusions
        self.maxItems = IndexStoreLimits.normalizedMaxItems(maxItems)
        self.indexAppBundlesAsApps = indexAppBundlesAsApps
        self.pathMatcher = ExcludedPathMatcher(patterns: exclusions.excludePaths)
        self.directoryEntryLimit = min(max(0, exclusions.maxDirEntries), Crawler.hardMaxDirectoryEntries)
        self.downrankEntryThreshold = min(max(0, exclusions.downrankDirEntries), Crawler.hardMaxDirectoryEntries)
        self.inspectedNameLimit = min(max(0, inspectedNameLimit), Crawler.maxInspectedNames)
        self.monotonicNow = monotonicNow
    }

    // MARK: Default roots

    /// Names under `~` that are never crawled as roots (case-insensitive).
    public static let neverRootNames: Set<String> = ["library", "applications", "public"]
    /// Root priority order (then alphabetical, case-insensitive).
    public static let rootPriority: [String] = ["Desktop", "Documents", "Downloads", "projects"]

    /// Build the default file roots for a home directory: every non-hidden top-level dir under `home` except
    /// Library/Applications/Public (and anything in `exclusions`), ordered Desktop, Documents, Downloads, projects, then alphabetical.
    public static func defaultRoots(home: String = NSHomeDirectory(), exclusions: Exclusions) -> [CrawlRoot] {
        guard SafetyLimits.isSafeAbsolutePath(home) else { return [] }
        let homeURL = URL(fileURLWithPath: SafetyLimits.trimmingTrailingPathSlashes(home), isDirectory: true)
        guard let directory = try? OpenDirectory.root(at: homeURL.path),
              let listing = try? directory.entries(limit: SafetyLimits.maxRootEntries, includeHidden: false) else { return [] }
        let matcher = ExcludedPathMatcher(patterns: exclusions.excludePaths)
        var names: [String] = []
        for e in listing.entries {
            let name = e.name
            guard e.isDirectory, !e.isSymbolicLink else { continue }
            if SafetyLimits.hasDotPrefix(name) || neverRootNames.contains(name.lowercased()) { continue }
            if exclusions.isExcludedName(name) || matcher.matches(homeURL.appendingPathComponent(name).path) { continue }
            names.append(name)
        }
        names.sort { a, b in
            let pa = rootPriority.firstIndex(of: a) ?? Int.max, pb = rootPriority.firstIndex(of: b) ?? Int.max
            if pa != pb { return pa < pb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return names.map { CrawlRoot(path: homeURL.appendingPathComponent($0).path) }
    }

    // MARK: Crawl state

    /// Mutable per-crawl bookkeeping (one instance per `crawl`/`crawlDirectory` call).
    private final class Context {
        let builder: IndexBuilder
        let onBatch: (@Sendable (IndexBuilder) -> Void)?
        let shouldCancel: @Sendable () -> Bool
        var stats = CrawlStats()
        var stopped = false                 // cap hit or cancelled
        var entriesSincePoll = 0
        var itemsAtLastBatch: Int
        var rootDirIds: [String: Int32] = [:]
        var cloud = false
        /// Shared global item budget for the parallel path (nil → serial path uses the local builder count).
        let sharedCount: AtomicInt?
        /// One counter is shared by every root in a full crawl. It bounds traversal work rather than
        /// retained items, so hidden, excluded, and vanished names all consume a slot.
        let inspectedCount: AtomicInt
        let inspectedLimit: Int
        let itemLimit: Int
        /// Absolute `DispatchTime`-domain deadline for the root currently owned by this context.
        var deadline: UInt64?
        init(builder: IndexBuilder, onBatch: (@Sendable (IndexBuilder) -> Void)?,
             shouldCancel: @escaping @Sendable () -> Bool,
             sharedCount: AtomicInt? = nil, inspectedCount: AtomicInt,
             inspectedLimit: Int, itemLimit: Int) {
            self.builder = builder; self.onBatch = onBatch; self.shouldCancel = shouldCancel
            self.itemsAtLastBatch = builder.count; self.sharedCount = sharedCount
            self.inspectedCount = inspectedCount; self.inspectedLimit = inspectedLimit
            self.itemLimit = itemLimit
        }
    }

    /// Immutable ownership-transfer envelope. A worker is the sole owner of `builder` until it
    /// submits this result; afterward only `ParallelMergeState` may touch it. The unchecked marker is
    /// limited to that hand-off invariant rather than applied to `IndexBuilder` globally.
    private final class RootCrawlResult: @unchecked Sendable {
        let builder: IndexBuilder
        let stats: CrawlStats
        let shouldMerge: Bool

        init(builder: IndexBuilder, stats: CrawlStats, shouldMerge: Bool = true) {
            self.builder = builder
            self.stats = stats
            self.shouldMerge = shouldMerge
        }
    }

    /// Owns all cross-worker mutable merge state behind one lock. Results may finish in any order,
    /// but `nextRoot` drains them in configured-root order, making item/diagnostic ordering stable and
    /// guaranteeing `onBatch` is never concurrent. The caller blocks in `group.wait()` and therefore
    /// cannot access `destination` until this state has finished its last merge.
    private final class ParallelMergeState: @unchecked Sendable {
        private let lock = NSLock()
        private let destination: IndexBuilder
        private let onBatch: @Sendable (IndexBuilder) -> Void
        private var pending: [RootCrawlResult?]
        private var nextRoot = 0
        private var merged = CrawlStats()

        init(rootCount: Int, destination: IndexBuilder,
             onBatch: @escaping @Sendable (IndexBuilder) -> Void) {
            self.destination = destination
            self.onBatch = onBatch
            self.pending = [RootCrawlResult?](repeating: nil, count: rootCount)
        }

        func submit(_ result: RootCrawlResult, rootIndex: Int) {
            lock.lock()
            defer { lock.unlock() }
            precondition(rootIndex >= nextRoot && rootIndex < pending.count && pending[rootIndex] == nil,
                         "each crawl root must transfer exactly one result")
            pending[rootIndex] = result
            while nextRoot < pending.count, let ready = pending[nextRoot] {
                pending[nextRoot] = nil
                mergeLocked(ready)
                nextRoot += 1
            }
        }

        func finalStats() -> CrawlStats {
            lock.lock()
            defer { lock.unlock() }
            precondition(nextRoot == pending.count, "all root workers must finish before reading stats")
            return merged
        }

        private func mergeLocked(_ result: RootCrawlResult) {
            let stats = result.stats
            let appended: Bool
            if result.shouldMerge {
                // Every item already claimed a global slot; the destination remains within maxItems.
                appended = destination.append(result.builder)
            } else {
                appended = false
            }
            if appended {
                merged.items = IndexStoreLimits.adding(merged.items, stats.items)
                merged.dirs = IndexStoreLimits.adding(merged.dirs, stats.dirs)
            }
            merged.inspectedNames = IndexStoreLimits.adding(merged.inspectedNames, stats.inspectedNames)
            merged.skippedExcluded = IndexStoreLimits.adding(merged.skippedExcluded, stats.skippedExcluded)
            merged.deniedPaths.append(contentsOf: stats.deniedPaths)
            merged.cappedDirs.append(contentsOf: stats.cappedDirs)
            if merged.deniedPaths.count > Crawler.maxReportedPaths {
                merged.deniedPaths.removeLast(merged.deniedPaths.count - Crawler.maxReportedPaths)
            }
            if merged.cappedDirs.count > Crawler.maxReportedPaths {
                merged.cappedDirs.removeLast(merged.cappedDirs.count - Crawler.maxReportedPaths)
            }
            merged.skippedUnsafe = IndexStoreLimits.adding(merged.skippedUnsafe, stats.skippedUnsafe)
            if stats.cancelled { merged.cancelled = true }
            if stats.hitItemCap || (result.shouldMerge && !appended) { merged.hitItemCap = true }
            if appended { onBatch(destination) }
        }
    }

    // MARK: Public entry points

    /// Crawl all roots into `builder`. `onBatch(builder)` is called every ~5000 items (caller may `build()` a partial
    /// store). `shouldCancel()` is polled every ~1000 entries. Returns stats. Runs synchronously on the caller's queue
    /// (caller uses a utility-QoS queue).
    /// Both callbacks are `@Sendable`: the parallel path polls cancellation from workers and performs
    /// root-ordered batch delivery from one lock-isolated merge path. They remain escaping because a
    /// dispatch block can retain them until `group.wait()` completes.
    @discardableResult
    public func crawl(into builder: IndexBuilder,
                      onBatch: (@Sendable (IndexBuilder) -> Void)? = nil,
                      shouldCancel: @escaping @Sendable () -> Bool = { false }) -> CrawlStats {
        let start = Date()
        // A single root (or a tiny cap, used by tests) is crawled serially, streaming partial results as
        // each ~5k items land. Multiple real roots are crawled concurrently — each into its own thread-local
        // builder, merged on one serial queue as it finishes (see `crawlParallel`) — because on this Mac the
        // home crawl is dominated by one large root (`~/projects`), so overlapping it with the others cuts
        // wall-clock roughly in half. Both paths produce an identical store (item order across roots aside).
        var s: CrawlStats
        let inspectedCount = AtomicInt()
        if roots.count <= 1 {
            let ctx = Context(builder: builder, onBatch: onBatch, shouldCancel: shouldCancel,
                              inspectedCount: inspectedCount, inspectedLimit: inspectedNameLimit,
                              itemLimit: maxItems)
            for root in roots { if ctx.stopped { break }; crawlRoot(root, ctx: ctx) }
            s = ctx.stats
        } else {
            s = crawlParallel(into: builder, onBatch: onBatch, shouldCancel: shouldCancel,
                              inspectedCount: inspectedCount)
        }
        s.duration = Date().timeIntervalSince(start)
        return s
    }

    /// Crawl every root concurrently into a private builder. A lock-isolated merge state buffers
    /// out-of-order completions and drains them in configured-root order; `onBatch` is serialized on
    /// that same path. Concurrency is capped at the active core count.
    private func crawlParallel(into builder: IndexBuilder,
                               onBatch: (@Sendable (IndexBuilder) -> Void)?,
                               shouldCancel: @escaping @Sendable () -> Bool,
                               inspectedCount: AtomicInt) -> CrawlStats {
        let debugTiming = ProcessInfo.processInfo.environment["JBAR_CRAWL_TIMING"] != nil
        let cancel = shouldCancel
        let cancelled = AtomicFlag()
        // Seed with items already in the shared builder (e.g. AppScanner apps) so the global cap counts them.
        let globalCount = AtomicInt(builder.count)
        let group = DispatchGroup()
        let crawlQ = DispatchQueue(label: "com.linji.jbar.crawl", attributes: .concurrent)
        let sem = DispatchSemaphore(value: max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        let mergeState = ParallelMergeState(rootCount: roots.count, destination: builder,
                                            onBatch: onBatch ?? { _ in })
        for (rootIndex, root) in roots.enumerated() {
            group.enter()
            crawlQ.async {
                sem.wait()
                defer { sem.signal(); group.leave() }
                if cancelled.value {
                    var stats = CrawlStats()
                    stats.cancelled = true
                    mergeState.submit(RootCrawlResult(builder: IndexBuilder(), stats: stats,
                                                      shouldMerge: false), rootIndex: rootIndex)
                    self.testHooks.invokeAfterSubmittingRoot(root.path)
                    return
                }
                let t0 = Date()
                let b = IndexBuilder()
                let ctx = Context(builder: b, onBatch: nil, shouldCancel: { cancelled.value || cancel() },
                                  sharedCount: globalCount, inspectedCount: inspectedCount,
                                  inspectedLimit: self.inspectedNameLimit, itemLimit: self.maxItems)
                self.crawlRoot(root, ctx: ctx)
                let st = ctx.stats
                if st.cancelled { cancelled.set(true) }
                if debugTiming {
                    FileHandle.standardError.write("  root \(root.path): \(b.count) items in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
                }
                mergeState.submit(RootCrawlResult(builder: b, stats: st), rootIndex: rootIndex)
                self.testHooks.invokeAfterSubmittingRoot(root.path)
            }
        }
        group.wait()
        return mergeState.finalStats()
    }

    /// Crawl ONE directory (absolute path, must be under a root) into `builder`, non-recursively if `recursive` is
    /// false, else the subtree with the usual rules. Used by `IndexUpdater` for FSEvents deltas. `dirId` is the
    /// builder's id for that directory. `depth` is the depth of the directory itself (its children get `depth + 1`;
    /// a root directory has depth 0). Returns number of items added.
    ///
    /// Junk inheritance is derived from the path components (any component that is a downrank name). In
    /// non-recursive mode every subdirectory found is crawled recursively (new content); use the overload with
    /// `existingSubdirNames` to leave already-indexed subdirectories alone.
    @discardableResult
    public func crawlDirectory(_ absolutePath: String, dirId: Int32, depth: Int, recursive: Bool, into builder: IndexBuilder) -> Int {
        crawlDirectory(absolutePath, dirId: dirId, depth: depth, recursive: recursive, existingSubdirNames: [], into: builder)
    }

    /// `crawlDirectory` variant for incremental updates: in non-recursive mode, subdirectories whose name is in
    /// `existingSubdirNames` get an item but no new dir entry and are not descended (their old entries/items are kept
    /// by the caller); other subdirectories are crawled recursively.
    @discardableResult
    public func crawlDirectory(_ absolutePath: String, dirId: Int32, depth: Int, recursive: Bool,
                               existingSubdirNames: Set<String>, into builder: IndexBuilder) -> Int {
        crawlDirectoryReporting(absolutePath, dirId: dirId, depth: depth, recursive: recursive,
                                existingSubdirNames: existingSubdirNames, into: builder,
                                itemLimit: maxItems).items
    }

    /// Internal variant used by incremental updates. All changed directories share `itemLimit`, and
    /// the returned cap flag lets the updater reject a partially scanned replacement.
    func crawlDirectoryReporting(_ absolutePath: String, dirId: Int32, depth: Int, recursive: Bool,
                                 existingSubdirNames: Set<String>, into builder: IndexBuilder,
                                 itemLimit: Int) -> CrawlStats {
        let limit = min(maxItems, IndexStoreLimits.normalizedMaxItems(itemLimit))
        let ctx = Context(builder: builder, onBatch: nil, shouldCancel: { false },
                          inspectedCount: AtomicInt(), inspectedLimit: inspectedNameLimit,
                          itemLimit: limit)
        let root = mostSpecificRoot(containing: absolutePath)
        ctx.cloud = root?.cloud ?? false
        guard let root else { ctx.stats.skippedUnsafe += 1; return ctx.stats }
        configureDeadline(for: root, ctx: ctx)
        guard checkDeadline(ctx) else { return ctx.stats }
        do {
            let opened = try openDirectory(absolutePath, within: root)
            listDirectory(opened.directory, displayPath: absolutePath, rootBoundary: opened.rootBoundary,
                          dirId: dirId, childDepth: depth + 1,
                          maxDepth: effectiveMaxDepth(root.maxDepth ?? exclusions.maxDepth),
                          inheritedJunk: pathHasDownrankComponent(absolutePath, belowRoot: root.path), recursive: recursive,
                          existingSubdirNames: existingSubdirNames, ctx: ctx)
        } catch {
            handleOpenError(error, path: absolutePath, ctx: ctx)
        }
        return ctx.stats
    }

    private func mostSpecificRoot(containing absolutePath: String) -> CrawlRoot? {
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        return roots.filter {
            let root = URL(fileURLWithPath: Exclusions.expandTilde($0.path, home: NSHomeDirectory())).standardizedFileURL.path
            return Crawler.path(target, isWithin: root)
        }.max { lhs, rhs in
            Crawler.pathComponentCount(lhs.path) < Crawler.pathComponentCount(rhs.path)
        }
    }

    private func openDirectory(_ absolutePath: String, within root: CrawlRoot) throws
        -> (directory: OpenDirectory, rootBoundary: String) {
        let rootPath = URL(fileURLWithPath: Exclusions.expandTilde(root.path, home: NSHomeDirectory())).standardizedFileURL.path
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard Crawler.path(target, isWithin: rootPath) else { throw DirectorySafetyError.outsideRoot }
        var directory = try OpenDirectory.root(at: rootPath)
        let boundary = directory.resolvedPath
        if target != rootPath {
            guard let suffix = SafetyLimits.relativePath(target, within: rootPath),
                  let components = SafetyLimits.posixPathComponents(suffix) else {
                throw DirectorySafetyError.outsideRoot
            }
            for component in components {
                directory = try directory.child(component: component, rootBoundary: boundary)
            }
        }
        guard Crawler.path(directory.resolvedPath, isWithin: boundary) else {
            throw DirectorySafetyError.outsideRoot
        }
        return (directory, boundary)
    }

    /// Depth of `absolutePath` relative to its most-specific containing crawl root: the root's own
    /// directory is depth 0 and its direct children are depth 1, matching what the full crawl assigns.
    /// Computed from path components (not the dir topology), so it is correct for every root shape —
    /// "/", "/opt", or "~/projects" — where topology inference was off by one.
    func depthOf(path absolutePath: String) -> Int {
        let target = ExcludedPathMatcher.normalize(absolutePath)
        var bestRootComps = -1
        for r in roots {
            let rp = ExcludedPathMatcher.normalize(Exclusions.expandTilde(r.path, home: NSHomeDirectory()))
            if SafetyLimits.isPath(target, within: rp) {
                bestRootComps = max(bestRootComps, Crawler.pathComponentCount(rp))
            }
        }
        let comps = Crawler.pathComponentCount(target)
        return bestRootComps < 0 ? 0 : max(0, comps - bestRootComps)
    }

    /// Number of non-empty "/"-separated components ("/" → 0, "/opt" → 1, "/Users/me/x" → 3).
    static func pathComponentCount(_ path: String) -> Int {
        SafetyLimits.posixPathComponentCount(path) ?? 0
    }

    /// Component-boundary containment (so `/root-two` is not under `/root`). Inputs are physical,
    /// standardized paths from `F_GETPATH` or `standardizedFileURL`.
    static func path(_ candidate: String, isWithin root: String) -> Bool {
        SafetyLimits.isPath(candidate, within: root)
    }

    private func effectiveMaxDepth(_ value: Int) -> Int {
        min(max(value, SafetyLimits.maxDepth.lowerBound), SafetyLimits.maxDepth.upperBound)
    }

    /// True if any path component AT OR BELOW the crawl root is a downrank name (used to seed junk for
    /// partial re-lists). Components above the root are ignored, matching the full crawl, which seeds junk
    /// only from the root's own name and downrank names encountered below it.
    func pathHasDownrankComponent(_ absolutePath: String, belowRoot rootPath: String? = nil) -> Bool {
        var pathToScan = absolutePath
        if let rp = rootPath {
            let expanded = Exclusions.expandTilde(rp, home: NSHomeDirectory())
            let rootParent = (expanded as NSString).deletingLastPathComponent   // path above the root's own name
            if !rootParent.isEmpty,
               let relative = SafetyLimits.relativePath(absolutePath, within: rootParent) {
                pathToScan = relative
            }
        }
        return (SafetyLimits.posixPathComponents(pathToScan) ?? []).contains {
            exclusions.isDownrankName($0)
        }
    }

    // MARK: Roots

    private func crawlRoot(_ root: CrawlRoot, ctx: Context) {
        configureDeadline(for: root, ctx: ctx)
        guard checkDeadline(ctx) else { return }
        let path = Exclusions.expandTilde(root.path, home: NSHomeDirectory())
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let directory: OpenDirectory
        do {
            directory = try OpenDirectory.root(at: path)
        } catch {
            handleOpenError(error, path: path, ctx: ctx)
            return
        }
        ctx.cloud = root.cloud
        let rootDirId: Int32
        if path == "/" {
            rootDirId = ctx.builder.addRoot("/")
            guard rootDirId >= 0 else { markBuilderLimit(ctx); return }
        } else {
            let parentPath = url.deletingLastPathComponent().path
            let parentId: Int32
            if let id = ctx.rootDirIds[parentPath] {
                parentId = id
            } else {
                parentId = ctx.builder.addRoot(parentPath)
                guard parentId >= 0 else { markBuilderLimit(ctx); return }
                ctx.rootDirIds[parentPath] = parentId
            }
            let name = url.lastPathComponent
            let flags = itemFlags(name: name, isSymbolicLink: false,
                                  isHidden: directory.info.st_flags & UInt32(UF_HIDDEN) != 0,
                                  junk: false, cloud: root.cloud)
            guard addItem(ctx, dir: parentId, name: name, kind: .folder, flags: flags,
                          mtime: modificationDate(directory.info), depth: 0, ext: nil) else { return }
            rootDirId = ctx.builder.addDir(parent: parentId, name: name)
            guard rootDirId >= 0 else { markBuilderLimit(ctx); return }
        }
        ctx.stats.dirs += 1
        listDirectory(directory, displayPath: path, rootBoundary: directory.resolvedPath,
                      dirId: rootDirId, childDepth: 1,
                      maxDepth: effectiveMaxDepth(root.maxDepth ?? exclusions.maxDepth),
                      inheritedJunk: exclusions.isDownrankName(url.lastPathComponent), recursive: true,
                      existingSubdirNames: [], ctx: ctx)
    }

    /// Permission failures retain a small, bounded path sample for UI remediation. Races, symlinks,
    /// and boundary failures expose only a count.
    private func handleOpenError(_ error: Error, path: String, ctx: Context) {
        guard let safety = error as? DirectorySafetyError else { return }
        if let code = safety.errorCode, code == EACCES || code == EPERM {
            recordDenied(path, ctx: ctx)
        } else if let code = safety.errorCode, code == ENOENT || code == ESTALE {
            return
        } else if let code = safety.errorCode, code == ENOTDIR {
            // Preserve the useful TCC/permission diagnostic for an unreadable non-directory root.
            // `lstat` does not follow the final component and the path is retained only in the
            // already-bounded denied sample.
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & mode_t(0o444) == 0 {
                recordDenied(path, ctx: ctx)
            } else {
                ctx.stats.skippedUnsafe += 1
            }
        } else {
            ctx.stats.skippedUnsafe += 1
        }
    }

    // MARK: Directory listing

    /// List `url` (whose builder id is `dirId`); its entries get depth `childDepth`.
    /// A subdirectory queued while its parent descriptor remains open. The identity was captured by
    /// `fstatat(..., AT_SYMLINK_NOFOLLOW)` and is rechecked on the descriptor returned by `openat`.
    private struct Descent {
        let cName: [CChar]
        let path: String
        let id: Int32
        let junk: Bool
        let identity: FileIdentity
    }

    private func listDirectory(_ directory: OpenDirectory, displayPath: String, rootBoundary: String,
                               dirId: Int32, childDepth: Int, maxDepth: Int, inheritedJunk: Bool,
                               recursive: Bool, existingSubdirNames: Set<String>, ctx: Context) {
        var toDescend: [Descent] = []
        let listing: PhysicalDirectoryListing
        do {
            listing = try directory.entries(limit: directoryEntryLimit, includeHidden: exclusions.includeHidden,
                                            rootBoundary: rootBoundary,
                                            claimCrawlBudget: { self.claimInspectedName(ctx) })
        } catch {
            handleOpenError(error, path: displayPath, ctx: ctx)
            return
        }
        if listing.truncation == .crawlBudget {
            // The partial listing is deliberately discarded: publishing it as if it were an exact
            // directory replacement could make existing entries disappear during an incremental merge.
            ctx.stats.hitItemCap = true
            ctx.stopped = true
            return
        }
        if listing.truncation == .directoryLimit {
            if ctx.stats.cappedDirs.count < Crawler.maxReportedPaths { ctx.stats.cappedDirs.append(displayPath) }
            return
        }
        let junk = inheritedJunk || listing.entries.count > downrankEntryThreshold
        for entry in listing.entries {
            if ctx.stopped { break }
            guard checkDeadline(ctx) else { break }
            pollCancel(ctx)
            if let d = processEntry(entry, parentFD: directory.fd, parentPath: displayPath,
                                    parentId: dirId, depth: childDepth, maxDepth: maxDepth, junk: junk,
                                    recursive: recursive, existingSubdirNames: existingSubdirNames, ctx: ctx) {
                toDescend.append(d)
            }
        }
        for d in toDescend {
            if ctx.stopped { return }
            guard checkDeadline(ctx) else { return }
            testHooks.invokeBeforeOpening(d.path)
            do {
                let child = try directory.child(named: d.cName, expected: d.identity, rootBoundary: rootBoundary)
                testHooks.invokeAfterOpening(d.path)
                listDirectory(child, displayPath: d.path, rootBoundary: rootBoundary,
                              dirId: d.id, childDepth: childDepth + 1, maxDepth: maxDepth,
                              inheritedJunk: d.junk, recursive: true, existingSubdirNames: [], ctx: ctx)
            } catch {
                handleOpenError(error, path: d.path, ctx: ctx)
            }
        }
    }

    private func pollCancel(_ ctx: Context) {
        ctx.entriesSincePoll += 1
        if ctx.entriesSincePoll >= Crawler.cancelPollInterval {
            ctx.entriesSincePoll = 0
            if ctx.shouldCancel() { ctx.stats.cancelled = true; ctx.stopped = true }
        }
    }

    /// Convert a public floating-point duration to an absolute monotonic deadline without trapping
    /// on NaN/infinity or overflowing `UInt64`. `nil` alone means unbudgeted; malformed and non-positive
    /// explicit budgets fail closed immediately.
    private func configureDeadline(for root: CrawlRoot, ctx: Context) {
        guard let seconds = root.timeBudget else { ctx.deadline = nil; return }
        let now = monotonicNow()
        guard seconds.isFinite, seconds > 0 else { ctx.deadline = now; return }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max - now) else {
            ctx.deadline = UInt64.max
            return
        }
        ctx.deadline = now + UInt64(nanoseconds.rounded(.down))
    }

    /// Poll the current root's monotonic deadline. Deadline exhaustion is truncation, not user
    /// cancellation, and therefore sets the same incomplete-store signal as the global item/work cap.
    @discardableResult
    private func checkDeadline(_ ctx: Context) -> Bool {
        guard let deadline = ctx.deadline else { return true }
        guard monotonicNow() < deadline else {
            ctx.stats.hitItemCap = true
            ctx.stopped = true
            return false
        }
        return true
    }

    /// Claim one globally shared inspected-name slot after the per-root deadline check.
    private func claimInspectedName(_ ctx: Context) -> Bool {
        guard checkDeadline(ctx), ctx.inspectedCount.reserve(max: ctx.inspectedLimit) else {
            ctx.stats.hitItemCap = true
            ctx.stopped = true
            return false
        }
        ctx.stats.inspectedNames = IndexStoreLimits.adding(ctx.stats.inspectedNames, 1)
        return true
    }

    private func recordDenied(_ path: String, ctx: Context) {
        if !ctx.stats.deniedPaths.contains(path), ctx.stats.deniedPaths.count < Crawler.maxReportedPaths {
            ctx.stats.deniedPaths.append(path)
        }
    }

    /// EACCES/EPERM (TCC denial shows up as `NSFileReadNoPermissionError` with an EPERM underlying error).
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError) { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(under) }
        return false
    }

    // MARK: Entries

    /// Add the item for `entry`. Returns a `Descent` (with the subtree's inherited junk) when `entry` is a
    /// plain directory that should be recursed into; nil otherwise. The caller opens it relative to
    /// the still-live parent descriptor only after all siblings have been classified.
    private func processEntry(_ entry: PhysicalDirectoryEntry, parentFD: Int32, parentPath: String,
                              parentId: Int32, depth: Int, maxDepth: Int, junk: Bool,
                              recursive: Bool, existingSubdirNames: Set<String>, ctx: Context) -> Descent? {
        let name = entry.name
        let path = parentPath == "/" ? "/" + name : parentPath + "/" + name
        let flags = itemFlags(name: name, isSymbolicLink: entry.isSymbolicLink,
                              isHidden: entry.isHidden, junk: junk, cloud: ctx.cloud)
        let ext = TextAnalyzer.fileExtension(of: name)
        // Some package extensions (notably `xcodeproj`) exceed the search engine's intentionally
        // short extension-interning limit. Package classification must still recognize them.
        let packageExtension = name.lastIndex(of: ".").map {
            String(name[name.index(after: $0)...]).lowercased()
        }
        if entry.isSymbolicLink {
            addItem(ctx, dir: parentId, name: name,
                    kind: symlinkKind(parentFD: parentFD, name: entry.cName, ext: ext),
                    flags: flags, mtime: entry.modificationDate, depth: depth, ext: ext)
            return nil
        }
        guard entry.isDirectory else {
            addItem(ctx, dir: parentId, name: name, kind: ItemKind.forExtension(ext ?? ""),
                    flags: flags, mtime: entry.modificationDate, depth: depth, ext: ext)
            return nil
        }
        if packageExtension == "app"
            || (packageExtension.map { Exclusions.packageExtensions.contains($0) } ?? false) {
            addPackage(name: name, ext: ext, parentId: parentId, depth: depth, flags: flags,
                       mtime: entry.modificationDate, ctx: ctx)
            return nil
        }
        guard addItem(ctx, dir: parentId, name: name, kind: .folder, flags: flags,
                      mtime: entry.modificationDate, depth: depth, ext: nil) else { return nil }
        // Should this plain directory be descended?
        if !recursive && existingSubdirNames.contains(name) { return nil }
        if exclusions.isExcludedName(name) || pathMatcher.matches(path) { ctx.stats.skippedExcluded += 1; return nil }
        guard depth < maxDepth else { return nil }
        let newId = ctx.builder.addDir(parent: parentId, name: name)
        guard newId >= 0 else { markBuilderLimit(ctx); return nil }
        ctx.stats.dirs += 1
        return Descent(cName: entry.cName, path: path, id: newId,
                       junk: junk || exclusions.isDownrankName(name), identity: entry.identity)
    }

    /// .app → app item (if enabled); other packages → leaf item with `.package`.
    private func addPackage(name: String, ext: String?, parentId: Int32, depth: Int,
                            flags: ItemFlags, mtime: Date?, ctx: Context) {
        if ext == "app" {
            guard indexAppBundlesAsApps else { return }
            let itemName = AppScanner.stripAppExtension(name)
            // AppScanner owns localized bundle metadata. The generic crawler deliberately avoids a
            // second path-based metadata read that could follow a concurrently swapped bundle.
            let info = AppInfo(bundleID: nil, displayName: itemName, aliases: [])
            addItem(ctx, dir: parentId, name: itemName, kind: .app, flags: flags.union(.appBundle), mtime: mtime, depth: depth, ext: "app", app: info)
            return
        }
        addItem(ctx, dir: parentId, name: name, kind: ItemKind.forExtension(ext ?? ""), flags: flags.union(.package), mtime: mtime, depth: depth, ext: ext)
    }

    /// Classify from the link text only; never `stat` the target. Extension-bearing targets keep a
    /// useful file kind, while an extensionless target is conservatively shown as a folder (the most
    /// common Finder alias/symlink case). Classification never grants descent authority.
    private func symlinkKind(parentFD: Int32, name: [CChar], ext: String?) -> ItemKind {
        var target = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = name.withUnsafeBufferPointer { linkName in
            target.withUnsafeMutableBytes {
                readlinkat(parentFD, linkName.baseAddress, $0.baseAddress, Int(MAXPATHLEN))
            }
        }
        if count > 0, count < Int(MAXPATHLEN) {
            let linkText = String(decoding: target[..<count], as: UTF8.self)
            let targetName = (linkText as NSString).lastPathComponent
            if let targetExtension = TextAnalyzer.fileExtension(of: targetName) {
                return ItemKind.forExtension(targetExtension)
            }
            if !targetName.isEmpty { return .folder }
        }
        return ItemKind.forExtension(ext ?? "")
    }

    private func itemFlags(name: String, isSymbolicLink: Bool, isHidden: Bool,
                           junk: Bool, cloud: Bool) -> ItemFlags {
        var f: ItemFlags = []
        if junk { f.insert(.junk) }
        if cloud { f.insert(.cloud) }
        if isHidden || SafetyLimits.hasDotPrefix(name) { f.insert(.hidden) }
        if SafetyLimits.hasDotPrefix(name) || SafetyLimits.hasTildeDollarPrefix(name) { f.insert(.dotName) }
        if isSymbolicLink { f.insert(.symlink) }
        return f
    }

    private func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
             + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// Add one item, enforcing the item cap and firing `onBatch`.
    @discardableResult
    private func addItem(_ ctx: Context, dir: Int32, name: String, kind: ItemKind, flags: ItemFlags,
                         mtime: Date?, depth: Int, ext: String?, app: AppInfo? = nil) -> Bool {
        // Cap check: a shared global counter under parallelism (exact global bound), else the local count.
        let reservedSharedSlot = ctx.sharedCount?.reserve(max: ctx.itemLimit)
        let underCap = reservedSharedSlot ?? (ctx.builder.count < ctx.itemLimit)
        if !underCap { ctx.stats.hitItemCap = true; ctx.stopped = true; return false }
        let item = ctx.builder.addItem(dir: dir, name: name, analyzed: TextAnalyzer.analyze(name),
                                       kind: kind, flags: flags, mtime: mtime, depth: depth,
                                       ext: ext, app: app)
        guard item >= 0 else {
            if reservedSharedSlot == true { ctx.sharedCount?.release() }
            markBuilderLimit(ctx)
            return false
        }
        ctx.stats.items += 1
        if ctx.builder.count - ctx.itemsAtLastBatch >= Crawler.batchSize {
            ctx.itemsAtLastBatch = ctx.builder.count
            ctx.onBatch?(ctx.builder)
        }
        return true
    }

    /// Builder refusal means an arena/cardinality/input invariant was reached. It is a safe
    /// truncation boundary, never a successful item/dir, and must prevent complete publication.
    private func markBuilderLimit(_ ctx: Context) {
        ctx.stats.hitItemCap = true
        ctx.stopped = true
    }
}

/// Applies FSEvents deltas to an immutable store by building a new generation:
/// copy every item/dir NOT under a changed directory, then re-list the changed directories (non-recursive, or the
/// subtree when `mustScanSubDirs`). Target: < 100 ms for 500k items and ≤ 200 changed dirs; if more than
/// `fullRecrawlThreshold` dirs changed, signal the caller to do a full recrawl instead. Owner: indexer agent.
///
/// Algorithm (see `StoreMerge` for the array mechanics):
/// 1. Normalise: expand `~`, drop changes outside the crawler's roots or under an excluded name/path, resolve each
///    path to a dir id (or to its nearest indexed ancestor, non-recursively — a new directory is picked up by re-listing
///    its parent, which crawls new subdirectories recursively), merge duplicates (OR of `mustScanSubDirs`), drop
///    descendants of a recursive change. More than `fullRecrawlThreshold` → nil.
/// 2. Affected item-dirs: the changed dir itself; plus its whole subtree for recursive changes, for vanished dirs and
///    for child dirs that no longer exist on disk. Items in affected dirs are not copied. The merge compacts directory
///    metadata to kept items and replacement anchors, remapping ids so removed subtrees cannot accumulate dead entries.
/// 3. Re-list every surviving changed dir into a temporary builder (one temp root per dir), then append the temp
///    store's items/dirs to the kept arrays with ids/offsets rebased.
public enum IndexUpdater {
    public struct Change: Sendable, Equatable {
        public var path: String
        public var mustScanSubDirs: Bool
        public init(path: String, mustScanSubDirs: Bool) { self.path = path; self.mustScanSubDirs = mustScanSubDirs }
    }
    public static let fullRecrawlThreshold = 200
    /// Aggregate raw path budget checked before building `DirIndex`. Individual paths retain the
    /// process-wide PATH_MAX-like ceiling; the aggregate cap prevents a public caller from making
    /// normalization/hash work scale with a large batch of maximum-length strings.
    static let maxRawChangePathBytes = 256 * 1_024

    /// Returns the updated store, or nil if the change set is too large / not applicable (caller should recrawl).
    /// Apps (kind .app under app roots) are preserved untouched; app-root changes are handled by rescanning apps.
    public static func apply(changes: [Change], to store: IndexStore, crawler: Crawler, generation: UInt64, fsEventId: UInt64) -> IndexStore? {
        guard rawChangesAreBounded(changes) else { return nil }
        let limit = crawler.maxItems
        let rootAllowance = max(crawler.roots.count, store.dirs.reduce(into: 0) { count, entry in
            if entry.parent < 0 { count += 1 }
        })
        guard store.count <= limit,
              IndexStoreLimits.acceptsDirectoryMetadata(itemCount: store.count, dirCount: store.dirs.count,
                                                        dirArenaBytes: store.dirArena.count,
                                                        rootAllowance: rootAllowance) else { return nil }
        let index = DirIndex(store: store)
        guard let plan = normalize(changes, store: store, index: index, crawler: crawler) else { return nil }
        if plan.isEmpty { return StoreMerge.rebrand(store, generation: generation, fsEventId: fsEventId) }

        var affected = [Bool](repeating: false, count: store.dirs.count)
        var work: [(dirId: Int32, path: String, recursive: Bool, existing: Set<String>)] = []
        for (dirId, recursive) in plan.sorted(by: { $0.key < $1.key }) {
            let path = index.path(of: dirId)
            let exists = directoryExists(path)
            if recursive || !exists {
                index.markSubtree(dirId, in: &affected)
            } else {
                affected[Int(dirId)] = true
            }
            guard exists else { continue }
            var existing = Set<String>()
            if !recursive {
                for child in index.children(of: dirId) {
                    let name = index.name(of: child)
                    if directoryExists(path + "/" + name) { existing.insert(name) } else { index.markSubtree(child, in: &affected) }
                }
            }
            work.append((dirId, path, recursive, existing))
        }

        // Decide what survives before scanning replacements. The temporary builder then gets one
        // shared remainder across every changed directory; any attempted overflow means the
        // replacement was truncated and must be discarded in favour of a full crawl.
        let keep = (0..<store.count).filter { !affected[Int(store.dirId[$0])] }
        guard keep.count <= limit else { return nil }
        let remaining = limit - keep.count
        let temp = IndexBuilder()
        var rootMap: [Int32: Int32] = [:]
        for w in work {
            let tmpRoot = temp.addRoot(w.path)
            guard tmpRoot >= 0 else { return nil }
            rootMap[tmpRoot] = w.dirId
            let stats = crawler.crawlDirectoryReporting(w.path, dirId: tmpRoot,
                                                        depth: crawler.depthOf(path: w.path), recursive: w.recursive,
                                                        existingSubdirNames: w.existing, into: temp,
                                                        itemLimit: remaining)
            if stats.hitItemCap { return nil }
        }
        return StoreMerge.merge(base: store, keep: keep, extra: temp.build(generation: 0), rootMap: rootMap,
                                generation: generation, fsEventId: fsEventId, maxItems: limit,
                                rootAllowance: rootAllowance)
    }

    // MARK: Normalisation

    /// Validate raw public input before allocating the directory index or expanding `~` paths.
    static func rawChangesAreBounded(_ changes: [Change],
                                     countLimit: Int = fullRecrawlThreshold,
                                     pathByteLimit: Int = maxRawChangePathBytes) -> Bool {
        let safeCountLimit = min(max(0, countLimit), fullRecrawlThreshold)
        let safeByteLimit = min(max(0, pathByteLimit), maxRawChangePathBytes)
        guard changes.count <= safeCountLimit else { return false }
        var totalBytes = 0
        for change in changes {
            guard !change.path.isEmpty,
                  SafetyLimits.utf8Fits(change.path, maxBytes: SafetyLimits.maxPathUTF8Bytes) else { return false }
            let bytes = change.path.utf8.count
            guard bytes <= safeByteLimit - totalBytes else { return false }
            totalBytes += bytes
        }
        return true
    }

    /// dirId → mustScanSubDirs. nil = too many changes.
    static func normalize(_ changes: [Change], store: IndexStore, index: DirIndex, crawler: Crawler) -> [Int32: Bool]? {
        var plan: [Int32: Bool] = [:]
        let matcher = ExcludedPathMatcher(patterns: crawler.exclusions.excludePaths)
        for c in changes {
            let path = Exclusions.expandTilde(c.path, home: NSHomeDirectory())
            guard isUnderRoots(path, crawler: crawler), !isExcluded(path, crawler: crawler, matcher: matcher) else { continue }
            guard let (dirId, exact) = index.resolve(path) else { continue }
            let recursive = exact && c.mustScanSubDirs
            plan[dirId] = (plan[dirId] ?? false) || recursive
            if plan.count > fullRecrawlThreshold { return nil }
        }
        // Drop any change whose subtree is already covered by a recursive ancestor change — including a
        // nested RECURSIVE change (else the descendant subtree is crawled twice and its items duplicated).
        let rset = Set(plan.filter { $0.value }.map { $0.key })
        if !rset.isEmpty {
            for id in Array(plan.keys) {
                if index.hasAncestor(id, in: rset) { plan.removeValue(forKey: id) }
            }
        }
        return plan
    }

    static func isUnderRoots(_ path: String, crawler: Crawler) -> Bool {
        for r in crawler.roots {
            let rp = r.path
            if SafetyLimits.isPath(path, within: rp) { return true }
        }
        return false
    }

    /// Excluded if the path itself or any ancestor matches an exclude path, or any component below the root is an
    /// excluded name.
    static func isExcluded(_ path: String, crawler: Crawler, matcher: ExcludedPathMatcher) -> Bool {
        let ex = crawler.exclusions
        var cur = path
        while true {
            if matcher.matches(cur) { return true }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == cur { break }
            if crawler.roots.contains(where: { $0.path == cur }) { break }
            if ex.isExcludedName((cur as NSString).lastPathComponent) { return true }
            cur = parent
        }
        return false
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - DirIndex

/// Navigation helpers over a store's directory table: children adjacency, path resolution, subtree marking.
/// Build once per `apply` (O(dirs), no string concatenation).
final class DirIndex {
    let store: IndexStore
    private(set) var children: [[Int32]]
    /// Root entries (parent == -1) by absolute path; the newest id wins.
    private(set) var roots: [String: Int32] = [:]

    init(store: IndexStore) {
        self.store = store
        children = [[Int32]](repeating: [], count: store.dirs.count)
        for (i, e) in store.dirs.enumerated() {
            if e.parent >= 0 && Int(e.parent) < store.dirs.count {
                children[Int(e.parent)].append(Int32(i))
            } else {
                roots[name(of: Int32(i))] = Int32(i)
            }
        }
    }

    func name(of d: Int32) -> String {
        let e = store.dirs[Int(d)]
        let s = Int(e.nameStart), l = Int(e.nameLen)
        return String(decoding: store.dirArena[s..<(s + l)], as: UTF8.self)
    }

    func children(of d: Int32) -> [Int32] { children[Int(d)] }

    func path(of d: Int32) -> String { store.dirPath(d) }

    /// Depth of directory `d` (root dirs = 0; the top-level parent entry = -1).
    ///
    /// A normal crawl root contributes TWO entries above a depth-0 directory (a synthetic parent-root
    /// entry plus the root's own dir entry), so the correction is `hops - 2`. A "/" root is a single
    /// entry (no synthetic parent), so it needs `hops - 1` to match the depth the full crawl assigns.
    func depth(of d: Int32) -> Int {
        // Topology-only estimate (hops to the -1 ancestor, minus the synthetic parent + root-dir pair).
        // Prefer `Crawler.depthOf(path:)`, which is exact for every root shape; this remains only for tests.
        var hops = 0
        var cur = d
        while cur >= 0 && hops < 4096 { cur = store.dirs[Int(cur)].parent; hops += 1 }
        return max(0, hops - 2)
    }

    func hasAncestor(_ d: Int32, in set: Set<Int32>) -> Bool {
        var cur = store.dirs[Int(d)].parent
        var guardCount = 0
        while cur >= 0 && guardCount < 4096 {
            if set.contains(cur) { return true }
            cur = store.dirs[Int(cur)].parent
            guardCount += 1
        }
        return false
    }

    /// Resolve an absolute path to (dirId, exact). When the path has no entry, the deepest indexed ancestor is returned
    /// with `exact == false`. Root entries themselves (parents of crawl roots, app roots) are never returned as inexact
    /// ancestors. Among duplicate entries for one path the newest wins.
    func resolve(_ path: String) -> (Int32, Bool)? {
        var best: (String, Int32)?
        for (rp, id) in roots {
            if SafetyLimits.isPath(path, within: rp) {
                let componentCount = SafetyLimits.posixPathComponentCount(rp) ?? -1
                let bestComponentCount = best.flatMap { SafetyLimits.posixPathComponentCount($0.0) } ?? -1
                if best == nil || componentCount > bestComponentCount
                    || (componentCount == bestComponentCount && id > best!.1) {
                    best = (rp, id)
                }
            }
        }
        guard let (rootPath, rootId) = best else { return nil }
        guard let relative = SafetyLimits.relativePath(path, within: rootPath) else { return nil }
        guard let components = SafetyLimits.posixPathComponents(relative) else { return nil }
        var cur = rootId
        var depthBelowRoot = 0
        for comp in components {
            guard let next = child(of: cur, named: comp) else {
                return depthBelowRoot == 0 ? nil : (cur, false)
            }
            cur = next
            depthBelowRoot += 1
        }
        return depthBelowRoot == 0 ? nil : (cur, true)
    }

    private func child(of d: Int32, named comp: String) -> Int32? {
        let bytes = Array(comp.utf8)
        var found: Int32?
        for c in children[Int(d)] {
            let e = store.dirs[Int(c)]
            let s = Int(e.nameStart), l = Int(e.nameLen)
            let storedBytes = store.dirArena[s..<(s + l)]
            if (l == bytes.count && storedBytes.elementsEqual(bytes))
                || String(decoding: storedBytes, as: UTF8.self) == comp {
                found = c // newest wins, including canonically equivalent APFS spellings
            }
        }
        return found
    }

    /// Mark `d` and all its descendants.
    func markSubtree(_ d: Int32, in marks: inout [Bool]) {
        var stack = [d]
        while let cur = stack.popLast() {
            if marks[Int(cur)] { continue }
            marks[Int(cur)] = true
            stack.append(contentsOf: children[Int(cur)])
        }
    }
}

// MARK: - StoreMerge

/// Array-level operations shared by `IndexUpdater` and `IndexCoordinator`: filter a store's items and append the
/// contents of another (freshly built) store with dir ids, arena offsets and extension ids rebased.
enum StoreMerge {
    /// Observable validation work used by performance regressions. Base/extra item topology is
    /// proved with allocation-free UTF-8 byte checks; only extra items whose mapped directory path
    /// semantics changed require a temporary `String` for the shared complete-path validator.
    struct PathValidationWork: Equatable {
        var baseItemsByteValidated: Int
        var extraItemsByteValidated: Int
        var remappedExtraItemStringDecodes: Int
    }

    /// Same contents, new generation/fsEventId (arrays are shared copy-on-write).
    static func rebrand(_ s: IndexStore, generation: UInt64, fsEventId: UInt64, builtAt: Date = Date()) -> IndexStore {
        IndexStore(count: s.count, dirId: s.dirId, nameStart: s.nameStart, nameLen: s.nameLen, displayStart: s.displayStart, displayLen: s.displayLen,
                   mask: s.mask, initials: s.initials, mtime: s.mtime, kind: s.kind, flags: s.flags, depth: s.depth, extId: s.extId,
                   foldedArena: s.foldedArena, bonusArena: s.bonusArena, displayArena: s.displayArena, dirs: s.dirs, dirArena: s.dirArena,
                   extensions: s.extensions, appInfo: s.appInfo, appItems: s.appItems, generation: generation, fsEventId: fsEventId, builtAt: builtAt)
    }

    /// Scanner-owned catalog apps carry an explicit provenance bit. Topology is not identity: the
    /// generic crawler can also discover `.app` bundles, and AppScanner now shares a unified `/`
    /// directory tree whose app items need not sit directly under a root entry.
    static func isScannerApp(_ s: IndexStore, _ i: Int) -> Bool {
        s.kind[i] == ItemKind.app.rawValue
            && ItemFlags(rawValue: s.flags[i]).contains(.appCatalog)
    }

    /// Build `base[keep] + extra`. `rootMap` maps root entries (parent == -1) of `extra` onto existing base dir ids;
    /// unmapped extra roots are matched by absolute path to a base root (newest wins) or appended as new roots.
    /// `keep` must be ascending.
    static func merge(base: IndexStore, keep: [Int], extra: IndexStore, rootMap explicitRootMap: [Int32: Int32],
                      generation: UInt64, fsEventId: UInt64, maxItems: Int,
                      rootAllowance: Int,
                      sideTableByteLimit: Int = SafetyLimits.maxAppSideTableBytes,
                      combinedArenaByteLimit: Int = IndexStoreLimits.maxCombinedArenaBytes,
                      extensionLimit: Int = Int(Int16.max) + 1,
                      pathValidationObserver: ((PathValidationWork) -> Void)? = nil) -> IndexStore? {
        let limit = IndexStoreLimits.normalizedMaxItems(maxItems)
        let safeSideTableLimit = min(max(0, sideTableByteLimit), SafetyLimits.maxAppSideTableBytes)
        let safeCombinedArenaLimit = min(max(0, combinedArenaByteLimit),
                                         IndexStoreLimits.maxCombinedArenaBytes)
        let safeExtensionLimit = min(max(0, extensionLimit), Int(Int16.max) + 1)
        guard rootAllowance >= 0, rootAllowance <= SafetyLimits.maxIndexRoots,
              keep.count <= limit, extra.count <= limit - keep.count,
              hasConsistentItemArrays(base), hasConsistentItemArrays(extra) else { return nil }
        var previous = -1
        for i in keep {
            guard i >= 0, i < base.count, i > previous else { return nil }
            previous = i
        }
        for (root, mapped) in explicitRootMap {
            guard root >= 0, Int(root) < extra.dirs.count, extra.dirs[Int(root)].parent < 0,
                  mapped >= 0, Int(mapped) < base.dirs.count else { return nil }
        }

        // `IndexStore`'s module-internal raw initializer is used by snapshot decoding and tests, so
        // neither operand may be treated as trusted merely because it is immutable. Prove the
        // complete original topology at the entrance. Item components are validated
        // directly from UTF-8 bytes: this remains O(items) safety work but creates no per-item
        // Strings for a million-item unchanged base generation.
        guard let baseValidation = validatedPathMetadata(base),
              let extraValidation = validatedPathMetadata(extra) else { return nil }
        let basePaths = baseValidation.metadata
        let extraPaths = extraValidation.metadata
        var pathValidationWork = PathValidationWork(
            baseItemsByteValidated: baseValidation.itemsByteValidated,
            extraItemsByteValidated: extraValidation.itemsByteValidated,
            remappedExtraItemStringDecodes: 0
        )

        // Compute and budget the exact semantic side tables before copying any potentially large
        // arenas. Extensions are deduplicated across stores with a proven Int16-representable id;
        // kept app tables are remapped now so removed apps do not consume the final budget.
        guard let sideTables = planSideTables(base: base, keep: keep, extra: extra,
                                              extensionLimit: safeExtensionLimit),
              IndexStoreLimits.estimatedSideTableBytes(extensions: sideTables.extensions,
                                                        appInfo: sideTables.appInfo,
                                                        appItems: sideTables.appItems)
                <= safeSideTableLimit,
              let itemArenas = planItemArenas(base: base, keep: keep, extra: extra) else { return nil }

        // Compact the base directory topology to the dirs actually referenced by kept items, plus
        // explicit replacement anchors. Scanner rescans remove every old `.appCatalog` item; without
        // this pass their now-dead child directory chains would be appended again on every rescan.
        // Generic crawler items keep their own chains live, so shared paths remain valid.
        guard let directoryPlan = planBaseDirectories(base, keep: keep,
                                                      explicitTargets: Array(explicitRootMap.values)) else {
            return nil
        }
        let baseRoots = directoryPlan.roots
        guard let compactedBasePaths = compactPathMetadata(basePaths, plan: directoryPlan) else {
            return nil
        }
        let expectedExplicitMapCount = explicitRootMap.count
        let remappedExplicitRoots = explicitRootMap.reduce(into: [Int32: Int32]()) { mapped, entry in
            let target = directoryPlan.oldToNew[Int(entry.value)]
            if target >= 0 { mapped[entry.key] = target }
        }
        guard remappedExplicitRoots.count == expectedExplicitMapCount else { return nil }
        let explicitRootMap = remappedExplicitRoots

        // Plan every extra directory against the compacted base before allocating final arenas.
        // Canonically equal roots can have different NFC/NFD byte lengths, and explicit incremental
        // roots may map onto a non-root directory. The plan recomputes exact final lengths and marks
        // only the affected extra subtree for per-item complete-path revalidation.
        guard let extraDirectoryPlan = planExtraDirectories(
            extra, originalPaths: extraPaths, compactedBasePaths: compactedBasePaths,
            baseRoots: baseRoots, explicitRootMap: explicitRootMap,
            firstAppendedID: directoryPlan.dirCount
        ) else { return nil }
        let finalCount = keep.count + extra.count
        let finalDirCount = IndexStoreLimits.adding(directoryPlan.dirCount,
                                                     extraDirectoryPlan.appendedDirCount)
        let finalDirBytes = IndexStoreLimits.adding(directoryPlan.arenaBytes,
                                                     extraDirectoryPlan.appendedDirBytes)
        let finalRootCount = IndexStoreLimits.adding(directoryPlan.rootCount,
                                                      extraDirectoryPlan.appendedRootCount)
        let finalCombinedArenaBytes = IndexStoreLimits.adding(itemArenas.nonDirectoryBytes,
                                                               finalDirBytes)
        guard finalRootCount <= SafetyLimits.maxIndexRoots,
              IndexStoreLimits.acceptsDirectoryMetadata(itemCount: finalCount, dirCount: finalDirCount,
                                                        dirArenaBytes: finalDirBytes,
                                                        rootAllowance: rootAllowance),
              finalCombinedArenaBytes <= safeCombinedArenaLimit,
              itemArenas.finalFoldedBytes <= Int(Int32.max),
              itemArenas.finalDisplayBytes <= Int(Int32.max),
              finalDirBytes <= Int(Int32.max),
              let compacted = materializeBaseDirectories(base, plan: directoryPlan) else { return nil }

        guard let remappedItemDecodes = validateRemappedExtraItems(
            extra, directoryPlan: extraDirectoryPlan
        ) else { return nil }
        pathValidationWork.remappedExtraItemStringDecodes = remappedItemDecodes

        // 1. Dir table: live base dirs compacted/remapped, extra dirs appended with remapped parents.
        let dirMap = extraDirectoryPlan.dirMap
        var dirs = compacted.dirs
        var dirArena = compacted.arena
        for (i, e) in extra.dirs.enumerated() {
            guard extraDirectoryPlan.shouldAppend[i] else { continue }
            guard dirMap[i] == Int32(dirs.count) else { return nil }
            let start = Int32(dirArena.count)
            dirArena.append(contentsOf: extra.dirArena[Int(e.nameStart)..<(Int(e.nameStart) + Int(e.nameLen))])
            let parent: Int32 = e.parent < 0 ? -1 : dirMap[Int(e.parent)]
            dirs.append(DirEntry(parent: parent, nameStart: start, nameLen: e.nameLen))
        }
        // 2. Extensions were deduplicated and assigned proven-safe Int16 ids in the preflight.
        let extensions = sideTables.extensions
        let extMap = sideTables.extraExtensionMap
        // 3. Arenas: kept arenas are compacted only when more than half is dead.
        let keptNameBytes = itemArenas.keptNameBytes
        let keptDisplayBytes = itemArenas.keptDisplayBytes
        let compact = itemArenas.compactBase
        var foldedArena: [UInt8], bonusArena: [UInt8], displayArena: [UInt8]
        var nameStart: [Int32], displayStart: [Int32]
        if compact {
            foldedArena = []; bonusArena = []; displayArena = []; nameStart = []; displayStart = []
            foldedArena.reserveCapacity(keptNameBytes + extra.foldedArena.count)
            bonusArena.reserveCapacity(keptNameBytes + extra.bonusArena.count)
            displayArena.reserveCapacity(keptDisplayBytes + extra.displayArena.count)
            nameStart.reserveCapacity(keep.count + extra.count); displayStart.reserveCapacity(keep.count + extra.count)
            for i in keep {
                let s = Int(base.nameStart[i]), l = Int(base.nameLen[i])
                nameStart.append(Int32(foldedArena.count))
                foldedArena.append(contentsOf: base.foldedArena[s..<(s + l)])
                bonusArena.append(contentsOf: base.bonusArena[s..<(s + l)])
                let ds = Int(base.displayStart[i]), dl = Int(base.displayLen[i])
                displayStart.append(Int32(displayArena.count))
                displayArena.append(contentsOf: base.displayArena[ds..<(ds + dl)])
            }
        } else {
            foldedArena = base.foldedArena; bonusArena = base.bonusArena; displayArena = base.displayArena
            nameStart = pick(base.nameStart, keep); displayStart = pick(base.displayStart, keep)
        }
        let foldedBase = Int32(foldedArena.count), displayBase = Int32(displayArena.count)
        foldedArena.append(contentsOf: extra.foldedArena); bonusArena.append(contentsOf: extra.bonusArena); displayArena.append(contentsOf: extra.displayArena)
        nameStart.append(contentsOf: extra.nameStart.map { $0 + foldedBase })
        displayStart.append(contentsOf: extra.displayStart.map { $0 + displayBase })
        // 4. Per-item arrays.
        var dirId = keep.map { directoryPlan.oldToNew[Int(base.dirId[$0])] }
        guard dirId.allSatisfy({ $0 >= 0 }) else { return nil }
        dirId.append(contentsOf: extra.dirId.map { dirMap[Int($0)] })
        var nameLen = pick(base.nameLen, keep); nameLen.append(contentsOf: extra.nameLen)
        var displayLen = pick(base.displayLen, keep); displayLen.append(contentsOf: extra.displayLen)
        var mask = pick(base.mask, keep); mask.append(contentsOf: extra.mask)
        var initials = pick(base.initials, keep); initials.append(contentsOf: extra.initials)
        var mtime = pick(base.mtime, keep); mtime.append(contentsOf: extra.mtime)
        var kind = pick(base.kind, keep); kind.append(contentsOf: extra.kind)
        var flags = pick(base.flags, keep); flags.append(contentsOf: extra.flags)
        var depth = pick(base.depth, keep); depth.append(contentsOf: extra.depth)
        var extId = pick(base.extId, keep); extId.append(contentsOf: extra.extId.map { $0 >= 0 ? extMap[Int($0)] : -1 })
        // 5. Side tables were remapped and budgeted before arena allocation.
        let appInfo = sideTables.appInfo
        let appItems = sideTables.appItems
        let result = IndexStore(count: finalCount, dirId: dirId, nameStart: nameStart, nameLen: nameLen, displayStart: displayStart,
                                displayLen: displayLen, mask: mask, initials: initials, mtime: mtime, kind: kind, flags: flags, depth: depth, extId: extId,
                                foldedArena: foldedArena, bonusArena: bonusArena, displayArena: displayArena, dirs: dirs, dirArena: dirArena,
                                extensions: extensions, appInfo: appInfo, appItems: appItems, generation: generation, fsEventId: fsEventId, builtAt: Date())
        pathValidationObserver?(pathValidationWork)
        return result
    }

    private struct SideTablePlan {
        var extensions: [String]
        var extraExtensionMap: [Int16]
        var appInfo: [Int32: AppInfo]
        var appItems: [Int32]
    }

    private struct ItemArenaPlan {
        var compactBase: Bool
        var keptNameBytes: Int
        var keptDisplayBytes: Int
        var finalFoldedBytes: Int
        var finalDisplayBytes: Int
        var nonDirectoryBytes: Int
    }

    private struct DirectoryCompactionPlan {
        var live: [Bool]
        var oldToNew: [Int32]
        var roots: [String: Int32]
        var dirCount: Int
        var rootCount: Int
        var arenaBytes: Int
    }

    private struct CompactedDirectories {
        var dirs: [DirEntry]
        var arena: [UInt8]
    }

    private struct StorePathMetadata {
        var pathLengths: [Int]
        var endsInSlash: [Bool]
    }

    private struct PathMetadataValidation {
        var metadata: StorePathMetadata
        var itemsByteValidated: Int
    }

    private struct ExtraDirectoryPlan {
        var dirMap: [Int32]
        var shouldAppend: [Bool]
        var finalPathLengths: [Int]
        var finalEndsInSlash: [Bool]
        var requiresMappedItemValidation: [Bool]
        var appendedDirCount: Int
        var appendedDirBytes: Int
        var appendedRootCount: Int
    }

    private static func hasConsistentItemArrays(_ store: IndexStore) -> Bool {
        let count = store.count
        return count >= 0
            && store.dirId.count == count && store.nameStart.count == count
            && store.nameLen.count == count && store.displayStart.count == count
            && store.displayLen.count == count && store.mask.count == count
            && store.initials.count == count && store.mtime.count == count
            && store.kind.count == count && store.flags.count == count
            && store.depth.count == count && store.extId.count == count
    }

    /// Validate an operand's original complete paths before any topology is reused. Directory
    /// validation uses the shared forward-pass implementation. Item validation deliberately stays
    /// on UTF-8 bytes so a large unchanged base does not allocate one `String` per item.
    private static func validatedPathMetadata(_ store: IndexStore) -> PathMetadataValidation? {
        guard let pathLengths = IndexStoreLimits.validDirectoryPathLengths(store.dirs,
                                                                           arena: store.dirArena) else {
            return nil
        }
        var endsInSlash = [Bool](repeating: false, count: store.dirs.count)
        for (index, entry) in store.dirs.enumerated() {
            endsInSlash[index] = IndexStoreLimits.directoryEntryEndsInSlash(entry,
                                                                            arena: store.dirArena)
        }
        for item in 0..<store.count {
            let directory = Int(store.dirId[item])
            let start = Int(store.displayStart[item]), length = Int(store.displayLen[item])
            guard directory >= 0, directory < store.dirs.count,
                  start >= 0, start <= store.displayArena.count,
                  length <= store.displayArena.count - start,
                  completeItemPathFitsBytes(
                    directoryPathUTF8Bytes: pathLengths[directory],
                    directoryEndsInSlash: endsInSlash[directory],
                    storedName: store.displayArena[start..<(start + length)],
                    flagsRaw: store.flags[item]
                  ) else { return nil }
        }
        let metadata = StorePathMetadata(pathLengths: pathLengths, endsInSlash: endsInSlash)
        return PathMetadataValidation(metadata: metadata, itemsByteValidated: store.count)
    }

    /// Remap already-validated base path metadata through live-directory compaction without
    /// reconstructing path strings.
    private static func compactPathMetadata(_ source: StorePathMetadata,
                                            plan: DirectoryCompactionPlan) -> StorePathMetadata? {
        guard source.pathLengths.count == plan.live.count,
              source.endsInSlash.count == plan.live.count,
              plan.oldToNew.count == plan.live.count else { return nil }
        var pathLengths = [Int](repeating: 0, count: plan.dirCount)
        var endsInSlash = [Bool](repeating: false, count: plan.dirCount)
        for oldIndex in plan.live.indices where plan.live[oldIndex] {
            let mapped = Int(plan.oldToNew[oldIndex])
            guard mapped >= 0, mapped < plan.dirCount else { return nil }
            pathLengths[mapped] = source.pathLengths[oldIndex]
            endsInSlash[mapped] = source.endsInSlash[oldIndex]
        }
        return StorePathMetadata(pathLengths: pathLengths, endsInSlash: endsInSlash)
    }

    /// Compute final extra directory ids and complete-path metadata. A changed mapped ancestor marks
    /// its entire extra subtree: even when separator arithmetic happens to cancel a trailing-slash
    /// length change, affected items are conservatively rechecked against the final directory.
    private static func planExtraDirectories(
        _ extra: IndexStore,
        originalPaths: StorePathMetadata,
        compactedBasePaths: StorePathMetadata,
        baseRoots: [String: Int32],
        explicitRootMap: [Int32: Int32],
        firstAppendedID: Int
    ) -> ExtraDirectoryPlan? {
        guard originalPaths.pathLengths.count == extra.dirs.count,
              originalPaths.endsInSlash.count == extra.dirs.count,
              compactedBasePaths.pathLengths.count == compactedBasePaths.endsInSlash.count,
              firstAppendedID >= 0 else { return nil }

        var dirMap = [Int32](repeating: -1, count: extra.dirs.count)
        var shouldAppend = [Bool](repeating: false, count: extra.dirs.count)
        var finalPathLengths = [Int](repeating: 0, count: extra.dirs.count)
        var finalEndsInSlash = [Bool](repeating: false, count: extra.dirs.count)
        var requiresMappedItemValidation = [Bool](repeating: false, count: extra.dirs.count)
        var appendedDirCount = 0
        var appendedDirBytes = 0
        var appendedRootCount = 0

        for (index, entry) in extra.dirs.enumerated() {
            let start = Int(entry.nameStart), length = Int(entry.nameLen)
            let finalID: Int32
            let finalLength: Int
            let finalSlash: Bool
            if entry.parent < 0 {
                let name = String(decoding: extra.dirArena[start..<(start + length)], as: UTF8.self)
                if let mapped = explicitRootMap[Int32(index)] ?? baseRoots[name] {
                    let mappedIndex = Int(mapped)
                    guard mappedIndex >= 0,
                          mappedIndex < compactedBasePaths.pathLengths.count else { return nil }
                    finalID = mapped
                    finalLength = compactedBasePaths.pathLengths[mappedIndex]
                    finalSlash = compactedBasePaths.endsInSlash[mappedIndex]
                } else {
                    let mappedValue = IndexStoreLimits.adding(firstAppendedID, appendedDirCount)
                    guard mappedValue <= Int(Int32.max) else { return nil }
                    finalID = Int32(mappedValue)
                    finalLength = originalPaths.pathLengths[index]
                    finalSlash = originalPaths.endsInSlash[index]
                    shouldAppend[index] = true
                    appendedDirCount = IndexStoreLimits.adding(appendedDirCount, 1)
                    appendedDirBytes = IndexStoreLimits.adding(appendedDirBytes, length)
                    appendedRootCount = IndexStoreLimits.adding(appendedRootCount, 1)
                }
            } else {
                let parentIndex = Int(entry.parent)
                guard parentIndex >= 0, parentIndex < index, dirMap[parentIndex] >= 0 else { return nil }
                let mappedValue = IndexStoreLimits.adding(firstAppendedID, appendedDirCount)
                guard mappedValue <= Int(Int32.max) else { return nil }
                finalID = Int32(mappedValue)
                finalLength = IndexStoreLimits.adding(
                    IndexStoreLimits.adding(finalPathLengths[parentIndex],
                                            finalEndsInSlash[parentIndex] ? 0 : 1),
                    length
                )
                finalSlash = false
                shouldAppend[index] = true
                appendedDirCount = IndexStoreLimits.adding(appendedDirCount, 1)
                appendedDirBytes = IndexStoreLimits.adding(appendedDirBytes, length)
            }
            guard finalLength > 0, finalLength <= SafetyLimits.maxPathUTF8Bytes else { return nil }
            dirMap[index] = finalID
            finalPathLengths[index] = finalLength
            finalEndsInSlash[index] = finalSlash
            let parentWasAffected = entry.parent >= 0
                && requiresMappedItemValidation[Int(entry.parent)]
            requiresMappedItemValidation[index] = parentWasAffected
                || finalLength != originalPaths.pathLengths[index]
                || finalSlash != originalPaths.endsInSlash[index]
        }
        return ExtraDirectoryPlan(
            dirMap: dirMap, shouldAppend: shouldAppend,
            finalPathLengths: finalPathLengths, finalEndsInSlash: finalEndsInSlash,
            requiresMappedItemValidation: requiresMappedItemValidation,
            appendedDirCount: appendedDirCount, appendedDirBytes: appendedDirBytes,
            appendedRootCount: appendedRootCount
        )
    }

    /// Only mapped extra subtrees can change complete-path arithmetic. Original extra metadata was
    /// already proved byte-for-byte, so unaffected items require no second String construction.
    private static func validateRemappedExtraItems(
        _ extra: IndexStore, directoryPlan: ExtraDirectoryPlan
    ) -> Int? {
        var decoded = 0
        for item in 0..<extra.count {
            let directory = Int(extra.dirId[item])
            guard directory >= 0, directory < directoryPlan.dirMap.count else { return nil }
            guard directoryPlan.requiresMappedItemValidation[directory] else { continue }
            let start = Int(extra.displayStart[item]), length = Int(extra.displayLen[item])
            guard start >= 0, start <= extra.displayArena.count,
                  length <= extra.displayArena.count - start,
                  let storedName = String(bytes: extra.displayArena[start..<(start + length)],
                                          encoding: .utf8),
                  IndexStoreLimits.completeItemPathFits(
                    directoryPathUTF8Bytes: directoryPlan.finalPathLengths[directory],
                    directoryEndsInSlash: directoryPlan.finalEndsInSlash[directory],
                    storedName: storedName, flagsRaw: extra.flags[item]
                  ) else { return nil }
            decoded += 1
        }
        return decoded
    }

    /// Allocation-free equivalent of the path-component and complete-item checks used by
    /// `IndexStoreLimits.completeItemPathFits`.
    private static func completeItemPathFitsBytes(
        directoryPathUTF8Bytes: Int,
        directoryEndsInSlash: Bool,
        storedName: ArraySlice<UInt8>,
        flagsRaw: UInt8
    ) -> Bool {
        guard directoryPathUTF8Bytes > 0,
              directoryPathUTF8Bytes <= SafetyLimits.maxPathUTF8Bytes,
              isSafePathComponentBytes(storedName,
                                       maxBytes: SafetyLimits.maxNameUTF8Bytes) else { return false }
        let needsAppSuffix = flagsRaw & ItemFlags.appBundle.rawValue != 0
            && !hasASCIICaseInsensitiveAppSuffix(storedName)
        let fileNameBytes = IndexStoreLimits.adding(storedName.count, needsAppSuffix ? 4 : 0)
        guard fileNameBytes <= SafetyLimits.maxNameUTF8Bytes else { return false }
        let completeBytes = IndexStoreLimits.adding(
            IndexStoreLimits.adding(directoryPathUTF8Bytes, directoryEndsInSlash ? 0 : 1),
            fileNameBytes
        )
        return completeBytes <= SafetyLimits.maxPathUTF8Bytes
    }

    private static func isSafePathComponentBytes(_ bytes: ArraySlice<UInt8>,
                                                 maxBytes: Int) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maxBytes, isWellFormedUTF8(bytes) else { return false }
        var onlyDots = true
        for byte in bytes {
            if byte == 0 || byte == 0x2F { return false }
            if byte != 0x2E { onlyDots = false }
        }
        return !(onlyDots && (bytes.count == 1 || bytes.count == 2))
    }

    private static func hasASCIICaseInsensitiveAppSuffix(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 4 else { return false }
        let dot = bytes.index(bytes.endIndex, offsetBy: -4)
        let a = bytes.index(after: dot)
        let firstP = bytes.index(after: a)
        let secondP = bytes.index(after: firstP)
        func lowerASCII(_ byte: UInt8) -> UInt8 {
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        }
        return bytes[dot] == 0x2E && lowerASCII(bytes[a]) == 0x61
            && lowerASCII(bytes[firstP]) == 0x70 && lowerASCII(bytes[secondP]) == 0x70
    }

    /// Strict UTF-8 validation without constructing a `String` or accepting replacement scalars.
    private static func isWellFormedUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
        func isContinuation(_ byte: UInt8) -> Bool { (0x80...0xBF).contains(byte) }
        while let lead = iterator.next() {
            switch lead {
            case 0x00...0x7F:
                continue
            case 0xC2...0xDF:
                guard let second = iterator.next(), isContinuation(second) else { return false }
            case 0xE0:
                guard let second = iterator.next(), (0xA0...0xBF).contains(second),
                      let third = iterator.next(), isContinuation(third) else { return false }
            case 0xE1...0xEC, 0xEE...0xEF:
                guard let second = iterator.next(), isContinuation(second),
                      let third = iterator.next(), isContinuation(third) else { return false }
            case 0xED:
                guard let second = iterator.next(), (0x80...0x9F).contains(second),
                      let third = iterator.next(), isContinuation(third) else { return false }
            case 0xF0:
                guard let second = iterator.next(), (0x90...0xBF).contains(second),
                      let third = iterator.next(), isContinuation(third),
                      let fourth = iterator.next(), isContinuation(fourth) else { return false }
            case 0xF1...0xF3:
                guard let second = iterator.next(), isContinuation(second),
                      let third = iterator.next(), isContinuation(third),
                      let fourth = iterator.next(), isContinuation(fourth) else { return false }
            case 0xF4:
                guard let second = iterator.next(), (0x80...0x8F).contains(second),
                      let third = iterator.next(), isContinuation(third),
                      let fourth = iterator.next(), isContinuation(fourth) else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Build the exact final semantic side tables before arena copying. Base extension ids remain
    /// stable; extra ids are remapped into a distinct union. No clamping is permitted because two
    /// distinct extensions must never alias the same Int16 id.
    private static func planSideTables(base: IndexStore, keep: [Int], extra: IndexStore,
                                       extensionLimit: Int) -> SideTablePlan? {
        guard extensionLimit >= 0, extensionLimit <= Int(Int16.max) + 1,
              base.extensions.count <= extensionLimit,
              extra.extensions.count <= extensionLimit,
              base.appInfo.count <= base.count, base.appItems.count <= base.count,
              extra.appInfo.count <= extra.count, extra.appItems.count <= extra.count else { return nil }

        var extensions: [String] = []
        extensions.reserveCapacity(min(extensionLimit,
                                       IndexStoreLimits.adding(base.extensions.count,
                                                               extra.extensions.count)))
        var extensionIndex: [String: Int16] = [:]
        extensionIndex.reserveCapacity(min(extensionLimit, base.extensions.count + extra.extensions.count))
        for value in base.extensions {
            guard isBoundedExtension(value), extensionIndex[value] == nil,
                  extensions.count < extensionLimit else { return nil }
            let id = Int16(extensions.count)
            extensions.append(value)
            extensionIndex[value] = id
        }
        var extraExtensionMap = [Int16](repeating: -1, count: extra.extensions.count)
        for (index, value) in extra.extensions.enumerated() {
            guard isBoundedExtension(value) else { return nil }
            if let existing = extensionIndex[value] {
                extraExtensionMap[index] = existing
            } else {
                guard extensions.count < extensionLimit else { return nil }
                let id = Int16(extensions.count)
                extensions.append(value)
                extensionIndex[value] = id
                extraExtensionMap[index] = id
            }
        }
        for item in keep {
            let id = base.extId[item]
            guard id == -1 || (id >= 0 && Int(id) < base.extensions.count) else { return nil }
        }
        for id in extra.extId {
            guard id == -1 || (id >= 0 && Int(id) < extra.extensions.count) else { return nil }
        }

        var appSet = Set<Int32>()
        appSet.reserveCapacity(IndexStoreLimits.adding(base.appInfo.count, base.appItems.count))
        for (item, info) in base.appInfo {
            guard item >= 0, Int(item) < base.count,
                  base.kind[Int(item)] == ItemKind.app.rawValue,
                  isBoundedAppInfo(info) else { return nil }
            appSet.insert(item)
        }
        var previous: Int32 = -1
        for item in base.appItems {
            guard item > previous, Int(item) < base.count,
                  base.kind[Int(item)] == ItemKind.app.rawValue else { return nil }
            previous = item
            appSet.insert(item)
        }

        var newIndex: [Int32: Int32] = [:]
        newIndex.reserveCapacity(min(appSet.count, keep.count))
        for (index, item) in keep.enumerated() where appSet.contains(Int32(item)) {
            newIndex[Int32(item)] = Int32(index)
        }
        var appInfo: [Int32: AppInfo] = [:]
        appInfo.reserveCapacity(IndexStoreLimits.adding(base.appInfo.count, extra.appInfo.count))
        for (item, info) in base.appInfo {
            if let mapped = newIndex[item] { appInfo[mapped] = info }
        }

        let offset = Int32(keep.count)
        for (item, info) in extra.appInfo {
            guard item >= 0, Int(item) < extra.count,
                  extra.kind[Int(item)] == ItemKind.app.rawValue,
                  isBoundedAppInfo(info) else { return nil }
            let (mapped, overflow) = item.addingReportingOverflow(offset)
            guard !overflow else { return nil }
            appInfo[mapped] = info
        }
        var appItems = base.appItems.compactMap { newIndex[$0] }
        appItems.reserveCapacity(IndexStoreLimits.adding(appItems.count, extra.appItems.count))
        previous = -1
        for item in extra.appItems {
            guard item > previous, Int(item) < extra.count,
                  extra.kind[Int(item)] == ItemKind.app.rawValue else { return nil }
            previous = item
            let (mapped, overflow) = item.addingReportingOverflow(offset)
            guard !overflow else { return nil }
            appItems.append(mapped)
        }
        return SideTablePlan(extensions: extensions, extraExtensionMap: extraExtensionMap,
                             appInfo: appInfo, appItems: appItems)
    }

    private static func isBoundedExtension(_ value: String) -> Bool {
        value.count <= SafetyLimits.maxExtensionCharacters
            && SafetyLimits.isSafePathComponent(
                value, maxUTF8Bytes: SafetyLimits.maxExtensionUTF8Bytes
            )
    }

    private static func isBoundedAppInfo(_ info: AppInfo) -> Bool {
        !info.displayName.isEmpty && !SafetyLimits.containsNULByte(info.displayName)
            && SafetyLimits.utf8Fits(info.displayName, maxBytes: SafetyLimits.maxNameUTF8Bytes)
            && (info.bundleID.map {
                !SafetyLimits.containsNULByte($0)
                    && SafetyLimits.utf8Fits($0, maxBytes: SafetyLimits.maxSettingUTF8Bytes)
            } ?? true)
            && info.aliases.count <= SafetyLimits.maxSearchAliasesPerApp
            && info.aliases.allSatisfy {
                !$0.folded.isEmpty && $0.folded.count == $0.bonus.count
                    && $0.folded.count <= IndexStoreLimits.maxAnalyzedNameBytes
            }
    }

    /// Validate every slice used by the merge and calculate the exact retained/appended item-arena
    /// footprint. When base compaction is not worthwhile, dead bytes remain part of the final bound.
    private static func planItemArenas(base: IndexStore, keep: [Int],
                                       extra: IndexStore) -> ItemArenaPlan? {
        func validItem(_ store: IndexStore, _ item: Int) -> Bool {
            let start = Int(store.nameStart[item]), length = Int(store.nameLen[item])
            let shownStart = Int(store.displayStart[item]), shownLength = Int(store.displayLen[item])
            return start >= 0 && start <= store.foldedArena.count
                && length <= store.foldedArena.count - start
                && start <= store.bonusArena.count && length <= store.bonusArena.count - start
                && shownStart >= 0 && shownStart <= store.displayArena.count
                && shownLength <= store.displayArena.count - shownStart
        }

        var keptNameBytes = 0
        var keptDisplayBytes = 0
        for item in keep {
            guard validItem(base, item) else { return nil }
            keptNameBytes = IndexStoreLimits.adding(keptNameBytes, Int(base.nameLen[item]))
            keptDisplayBytes = IndexStoreLimits.adding(keptDisplayBytes, Int(base.displayLen[item]))
        }
        for item in 0..<extra.count where !validItem(extra, item) { return nil }

        let compact = keep.count < base.count
            && (keptNameBytes < base.foldedArena.count / 2
                || keptDisplayBytes < base.displayArena.count / 2)
        let retainedFolded = compact ? keptNameBytes : base.foldedArena.count
        let retainedBonus = compact ? keptNameBytes : base.bonusArena.count
        let retainedDisplay = compact ? keptDisplayBytes : base.displayArena.count
        let finalFolded = IndexStoreLimits.adding(retainedFolded, extra.foldedArena.count)
        let finalDisplay = IndexStoreLimits.adding(retainedDisplay, extra.displayArena.count)
        let nonDirectoryBytes = [retainedFolded, retainedBonus, retainedDisplay,
                                 extra.foldedArena.count, extra.bonusArena.count,
                                 extra.displayArena.count].reduce(0, IndexStoreLimits.adding)
        return ItemArenaPlan(compactBase: compact, keptNameBytes: keptNameBytes,
                             keptDisplayBytes: keptDisplayBytes, finalFoldedBytes: finalFolded,
                             finalDisplayBytes: finalDisplay,
                             nonDirectoryBytes: nonDirectoryBytes)
    }

    /// Mark each kept item's directory and ancestor chain, plus explicit incremental-replace targets.
    /// This planning pass computes exact directory counts/bytes without copying the arena, allowing
    /// the aggregate resource preflight to reject an oversized result before materialization.
    private static func planBaseDirectories(_ base: IndexStore, keep: [Int],
                                            explicitTargets: [Int32]) -> DirectoryCompactionPlan? {
        var live = [Bool](repeating: false, count: base.dirs.count)

        func markAncestors(_ initial: Int32) -> Bool {
            guard initial >= 0 else { return false }
            var current = initial
            while current >= 0 {
                let index = Int(current)
                guard index < base.dirs.count else { return false }
                if live[index] { return true }
                let entry = base.dirs[index]
                let start = Int(entry.nameStart), length = Int(entry.nameLen)
                guard entry.parent >= -1, entry.parent < current,
                      start >= 0, start <= base.dirArena.count,
                      length <= base.dirArena.count - start else { return false }
                live[index] = true
                current = entry.parent
            }
            return true
        }

        for item in keep {
            guard item >= 0, item < base.count, markAncestors(base.dirId[item]) else { return nil }
        }
        for target in explicitTargets {
            guard markAncestors(target) else { return nil }
        }

        var oldToNew = [Int32](repeating: -1, count: base.dirs.count)
        var roots: [String: Int32] = [:]
        var dirCount = 0
        var rootCount = 0
        var arenaBytes = 0
        for (index, entry) in base.dirs.enumerated() where live[index] {
            let parent = entry.parent < 0 ? -1 : oldToNew[Int(entry.parent)]
            guard entry.parent < 0 || parent >= 0,
                  dirCount < Int(Int32.max) else { return nil }
            let start = Int(entry.nameStart), length = Int(entry.nameLen)
            arenaBytes = IndexStoreLimits.adding(arenaBytes, length)
            guard arenaBytes <= Int(Int32.max) else { return nil }
            let bytes = base.dirArena[start..<(start + length)]
            let mapped = Int32(dirCount)
            oldToNew[index] = mapped
            dirCount += 1
            if parent < 0 {
                rootCount += 1
                roots[String(decoding: bytes, as: UTF8.self)] = mapped
            }
        }
        return DirectoryCompactionPlan(live: live, oldToNew: oldToNew, roots: roots,
                                       dirCount: dirCount, rootCount: rootCount,
                                       arenaBytes: arenaBytes)
    }

    private static func materializeBaseDirectories(_ base: IndexStore,
                                                   plan: DirectoryCompactionPlan) -> CompactedDirectories? {
        var dirs: [DirEntry] = []
        var arena: [UInt8] = []
        dirs.reserveCapacity(plan.dirCount)
        arena.reserveCapacity(plan.arenaBytes)
        for (index, entry) in base.dirs.enumerated() where plan.live[index] {
            let parent = entry.parent < 0 ? -1 : plan.oldToNew[Int(entry.parent)]
            guard entry.parent < 0 || parent >= 0 else { return nil }
            let start = Int(entry.nameStart), length = Int(entry.nameLen)
            let newStart = Int32(arena.count)
            arena.append(contentsOf: base.dirArena[start..<(start + length)])
            dirs.append(DirEntry(parent: parent, nameStart: newStart, nameLen: entry.nameLen))
        }
        guard dirs.count == plan.dirCount, arena.count == plan.arenaBytes else { return nil }
        return CompactedDirectories(dirs: dirs, arena: arena)
    }

    static func pick<T>(_ a: [T], _ keep: [Int]) -> [T] {
        if keep.count == a.count { return a }
        var out: [T] = []
        out.reserveCapacity(keep.count)
        for i in keep { out.append(a[i]) }
        return out
    }

    static func dirName(_ s: IndexStore, _ i: Int) -> String {
        let e = s.dirs[i]
        return String(decoding: s.dirArena[Int(e.nameStart)..<(Int(e.nameStart) + Int(e.nameLen))], as: UTF8.self)
    }

    /// Root entries of `s` by absolute path (newest id wins).
    static func rootsByPath(_ s: IndexStore) -> [String: Int32] {
        var out: [String: Int32] = [:]
        for (i, e) in s.dirs.enumerated() where e.parent < 0 { out[dirName(s, i)] = Int32(i) }
        return out
    }
}
