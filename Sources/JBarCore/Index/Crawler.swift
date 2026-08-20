import Foundation

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
}

/// A file-system root to crawl.
public struct CrawlRoot: Sendable, Equatable {
    public var path: String          // absolute
    public var maxDepth: Int?        // overrides Exclusions.maxDepth if set
    public var cloud: Bool           // names-only, background QoS, budgeted (not used in v1 by default)
    public var timeBudget: TimeInterval? // wall-clock cap for this root (cloud roots)
    public init(path: String, maxDepth: Int? = nil, cloud: Bool = false, timeBudget: TimeInterval? = nil) {
        self.path = path; self.maxDepth = maxDepth; self.cloud = cloud; self.timeBudget = timeBudget
    }
}

/// What happened during a crawl (shown in the menu bar status).
public struct CrawlStats: Sendable, Equatable {
    public var items: Int = 0
    public var dirs: Int = 0
    public var skippedExcluded: Int = 0
    public var deniedPaths: [String] = []      // TCC denial / EACCES on a root or subdir
    public var cappedDirs: [String] = []       // > maxDirEntries
    public var hitItemCap: Bool = false
    public var duration: TimeInterval = 0
    public var cancelled: Bool = false
    public init() {}
}

/// Enumerates files/folders under roots into an `IndexBuilder`. DESIGN.md §4.2–4.5. Owner: indexer agent.
///
/// Implementation: an explicit depth-first walk using `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)`
/// per directory (resource values `[.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
/// .contentModificationDateKey]` are prefetched, `.skipsHiddenFiles` unless `includeHidden`). Listing a directory
/// yields its entry count for free, which drives the `maxDirEntries` cap and the `downrankDirEntries` junk rule
/// before any child is visited. Never follows symlinks (records them as items). Directories are items too (kind .folder).
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
public final class Crawler {
    public let roots: [CrawlRoot]
    public let exclusions: Exclusions
    public let maxItems: Int
    public var indexAppBundlesAsApps = true

    /// Items between two `onBatch` calls.
    public static let batchSize = 5_000
    /// Entries between two `shouldCancel` polls.
    public static let cancelPollInterval = 1_000

    private let pathMatcher: ExcludedPathMatcher
    private let fm = FileManager.default
    private let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey]
    private let keySet: Set<URLResourceKey>

    public init(roots: [CrawlRoot], exclusions: Exclusions, maxItems: Int = 1_000_000) {
        self.roots = roots; self.exclusions = exclusions; self.maxItems = maxItems
        self.pathMatcher = ExcludedPathMatcher(patterns: exclusions.excludePaths)
        self.keySet = Set(keys)
    }

    // MARK: Default roots

    /// Names under `~` that are never crawled as roots (case-insensitive).
    public static let neverRootNames: Set<String> = ["library", "applications", "public"]
    /// Root priority order (then alphabetical, case-insensitive).
    public static let rootPriority: [String] = ["Desktop", "Documents", "Downloads", "projects"]

    /// Build the default file roots for a home directory: every non-hidden top-level dir under `home` except
    /// Library/Applications/Public (and anything in `exclusions`), ordered Desktop, Documents, Downloads, projects, then alphabetical.
    public static func defaultRoots(home: String = NSHomeDirectory(), exclusions: Exclusions) -> [CrawlRoot] {
        let homeURL = URL(fileURLWithPath: Exclusions.expandTilde(home, home: home), isDirectory: true)
        let rkeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: Array(rkeys), options: [.skipsHiddenFiles]) else {
            return []
        }
        let matcher = ExcludedPathMatcher(patterns: exclusions.excludePaths)
        var names: [String] = []
        for e in entries {
            let name = e.lastPathComponent
            guard let rv = try? e.resourceValues(forKeys: rkeys), rv.isDirectory == true, rv.isSymbolicLink != true else { continue }
            if name.hasPrefix(".") || neverRootNames.contains(name.lowercased()) { continue }
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
        let onBatch: ((IndexBuilder) -> Void)?
        let shouldCancel: () -> Bool
        var stats = CrawlStats()
        var stopped = false                 // cap hit or cancelled
        var entriesSincePoll = 0
        var itemsAtLastBatch: Int
        var rootDirIds: [String: Int32] = [:]
        var cloud = false
        /// Shared global item budget for the parallel path (nil → serial path uses the local builder count).
        let sharedCount: AtomicInt?
        init(builder: IndexBuilder, onBatch: ((IndexBuilder) -> Void)?, shouldCancel: @escaping () -> Bool, sharedCount: AtomicInt? = nil) {
            self.builder = builder; self.onBatch = onBatch; self.shouldCancel = shouldCancel; self.itemsAtLastBatch = builder.count; self.sharedCount = sharedCount
        }
    }

    // MARK: Public entry points

    /// Crawl all roots into `builder`. `onBatch(builder)` is called every ~5000 items (caller may `build()` a partial
    /// store). `shouldCancel()` is polled every ~1000 entries. Returns stats. Runs synchronously on the caller's queue
    /// (caller uses a utility-QoS queue).
    @discardableResult
    public func crawl(into builder: IndexBuilder, onBatch: ((IndexBuilder) -> Void)? = nil, shouldCancel: () -> Bool = { false }) -> CrawlStats {
        let start = Date()
        // A single root (or a tiny cap, used by tests) is crawled serially, streaming partial results as
        // each ~5k items land. Multiple real roots are crawled concurrently — each into its own thread-local
        // builder, merged on one serial queue as it finishes (see `crawlParallel`) — because on this Mac the
        // home crawl is dominated by one large root (`~/projects`), so overlapping it with the others cuts
        // wall-clock roughly in half. Both paths produce an identical store (item order across roots aside).
        var s: CrawlStats
        if roots.count <= 1 {
            s = withoutActuallyEscaping(shouldCancel) { cancel -> CrawlStats in
                let ctx = Context(builder: builder, onBatch: onBatch, shouldCancel: cancel)
                for root in roots { if ctx.stopped { break }; crawlRoot(root, ctx: ctx) }
                return ctx.stats
            }
        } else {
            s = crawlParallel(into: builder, onBatch: onBatch, shouldCancel: shouldCancel)
        }
        s.duration = Date().timeIntervalSince(start)
        return s
    }

    /// Crawl every root concurrently, each into a private builder, merging on a serial queue as each root
    /// finishes. `onBatch` is invoked from the merge queue after each root is merged (completion order, so
    /// small roots publish first). Concurrency is capped at the active core count. Determinism note: the
    /// only cross-root nondeterminism is item index order, which ranking uses solely as a final tie-break.
    private func crawlParallel(into builder: IndexBuilder, onBatch: ((IndexBuilder) -> Void)?, shouldCancel: () -> Bool) -> CrawlStats {
        let debugTiming = ProcessInfo.processInfo.environment["JBAR_CRAWL_TIMING"] != nil
        return withoutActuallyEscaping(shouldCancel) { cancel in
            withoutActuallyEscaping(onBatch ?? { _ in }) { batch -> CrawlStats in
                let cancelled = AtomicFlag()
                // Seed with items already in the shared builder (e.g. AppScanner apps) so the global cap counts them.
                let globalCount = AtomicInt(builder.count)
                let group = DispatchGroup()
                let crawlQ = DispatchQueue(label: "com.linji.jbar.crawl", attributes: .concurrent)
                let mergeQ = DispatchQueue(label: "com.linji.jbar.crawl.merge")
                let sem = DispatchSemaphore(value: max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
                var merged = CrawlStats()
                for root in roots {
                    group.enter()
                    crawlQ.async {
                        sem.wait()
                        defer { sem.signal(); group.leave() }
                        if cancelled.value { return }
                        let t0 = Date()
                        let b = IndexBuilder()
                        let ctx = Context(builder: b, onBatch: nil, shouldCancel: { cancelled.value || cancel() }, sharedCount: globalCount)
                        self.crawlRoot(root, ctx: ctx)
                        let st = ctx.stats
                        if debugTiming {
                            FileHandle.standardError.write("  root \(root.path): \(b.count) items in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
                        }
                        mergeQ.sync {
                            // Every item in `b` already claimed a global slot, so appending them all keeps the
                            // merged store within maxItems; no items are dropped at merge time.
                            builder.append(b)
                            merged.items += st.items
                            merged.dirs += st.dirs
                            merged.skippedExcluded += st.skippedExcluded
                            merged.deniedPaths.append(contentsOf: st.deniedPaths)
                            merged.cappedDirs.append(contentsOf: st.cappedDirs)
                            if st.cancelled { merged.cancelled = true; cancelled.set(true) }
                            if st.hitItemCap { merged.hitItemCap = true }   // authoritative per-root flag
                            batch(builder)
                        }
                    }
                }
                group.wait()
                return merged
            }
        }
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
        let ctx = Context(builder: builder, onBatch: nil, shouldCancel: { false })
        let root = roots.first { absolutePath == $0.path || absolutePath.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
        ctx.cloud = root?.cloud ?? false
        let before = builder.count
        let url = URL(fileURLWithPath: absolutePath, isDirectory: true)
        listDirectory(url, dirId: dirId, childDepth: depth + 1, maxDepth: root?.maxDepth ?? exclusions.maxDepth,
                      inheritedJunk: pathHasDownrankComponent(absolutePath, belowRoot: root?.path), recursive: recursive,
                      existingSubdirNames: existingSubdirNames, ctx: ctx)
        return builder.count - before
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
            if target == rp || target.hasPrefix(rp == "/" ? "/" : rp + "/") {
                bestRootComps = max(bestRootComps, Crawler.pathComponentCount(rp))
            }
        }
        let comps = Crawler.pathComponentCount(target)
        return bestRootComps < 0 ? 0 : max(0, comps - bestRootComps)
    }

    /// Number of non-empty "/"-separated components ("/" → 0, "/opt" → 1, "/Users/me/x" → 3).
    static func pathComponentCount(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    /// True if any path component AT OR BELOW the crawl root is a downrank name (used to seed junk for
    /// partial re-lists). Components above the root are ignored, matching the full crawl, which seeds junk
    /// only from the root's own name and downrank names encountered below it.
    func pathHasDownrankComponent(_ absolutePath: String, belowRoot rootPath: String? = nil) -> Bool {
        var pathToScan = absolutePath
        if let rp = rootPath {
            let expanded = Exclusions.expandTilde(rp, home: NSHomeDirectory())
            let rootParent = (expanded as NSString).deletingLastPathComponent   // path above the root's own name
            if rootParent != "/" && !rootParent.isEmpty && absolutePath.hasPrefix(rootParent) {
                pathToScan = String(absolutePath.dropFirst(rootParent.count))
            }
        }
        return pathToScan.split(separator: "/").contains { exclusions.isDownrankName(String($0)) }
    }

    // MARK: Roots

    private func crawlRoot(_ root: CrawlRoot, ctx: Context) {
        let path = Exclusions.expandTilde(root.path, home: NSHomeDirectory())
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let rv = try? url.resourceValues(forKeys: keySet), rv.isDirectory == true || (rv.isSymbolicLink == true && IndexUpdater.directoryExists(path)) else {
            recordMissingOrDenied(path, ctx: ctx); return
        }
        ctx.cloud = root.cloud
        let rootDirId: Int32
        if path == "/" {
            rootDirId = ctx.builder.addRoot("/")
        } else {
            let parentPath = url.deletingLastPathComponent().path
            let parentId: Int32
            if let id = ctx.rootDirIds[parentPath] { parentId = id } else { parentId = ctx.builder.addRoot(parentPath); ctx.rootDirIds[parentPath] = parentId }
            let name = url.lastPathComponent
            let flags = itemFlags(name: name, rv: rv, junk: false, cloud: root.cloud)
            addItem(ctx, dir: parentId, name: name, kind: .folder, flags: flags, mtime: rv.contentModificationDate, depth: 0, ext: nil)
            rootDirId = ctx.builder.addDir(parent: parentId, name: name)
        }
        ctx.stats.dirs += 1
        listDirectory(url, dirId: rootDirId, childDepth: 1, maxDepth: root.maxDepth ?? exclusions.maxDepth,
                      inheritedJunk: exclusions.isDownrankName(url.lastPathComponent), recursive: true, existingSubdirNames: [], ctx: ctx)
    }

    /// A root that cannot be read: permission problems are reported, missing roots are silently skipped.
    private func recordMissingOrDenied(_ path: String, ctx: Context) {
        if !fm.isReadableFile(atPath: path) && fm.fileExists(atPath: path) { recordDenied(path, ctx: ctx) }
    }

    // MARK: Directory listing

    /// List `url` (whose builder id is `dirId`); its entries get depth `childDepth`.
    /// A subdirectory queued for descent after the current directory's transient objects are freed.
    /// Holds the child's PATH (not its URL) so the URL — and the resource values cached on it — are
    /// released when the directory's autoreleasepool drains; the URL is rebuilt cheaply at descent time.
    private struct Descent { let path: String; let id: Int32; let junk: Bool }

    private func listDirectory(_ url: URL, dirId: Int32, childDepth: Int, maxDepth: Int, inheritedJunk: Bool,
                               recursive: Bool, existingSubdirNames: Set<String>, ctx: Context) {
        // Add this directory's items INSIDE an autoreleasepool so the entries array and every
        // resource-value dictionary it created are released here — before we recurse. Descending
        // inline (as the DFS naturally would) keeps every ancestor's entries alive for the whole
        // subtree, which is what pushed cold-crawl RSS to ~300 MB. Draining per directory bounds
        // transient memory to O(depth × directory size).
        var toDescend: [Descent] = []
        autoreleasepool {
            let entries: [URL]
            do {
                let opts: FileManager.DirectoryEnumerationOptions = exclusions.includeHidden ? [] : [.skipsHiddenFiles]
                entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)
            } catch {
                handleListError(error, path: url.path, ctx: ctx); return
            }
            if entries.count > exclusions.maxDirEntries {
                ctx.stats.cappedDirs.append(url.path); return
            }
            let junk = inheritedJunk || entries.count > exclusions.downrankDirEntries
            for entry in entries {
                if ctx.stopped { break }
                pollCancel(ctx)
                if let d = processEntry(entry, parentId: dirId, depth: childDepth, maxDepth: maxDepth, junk: junk,
                                        recursive: recursive, existingSubdirNames: existingSubdirNames, ctx: ctx) {
                    toDescend.append(d)
                }
            }
        }
        for d in toDescend {
            if ctx.stopped { return }
            listDirectory(URL(fileURLWithPath: d.path, isDirectory: true), dirId: d.id, childDepth: childDepth + 1,
                          maxDepth: maxDepth, inheritedJunk: d.junk, recursive: true, existingSubdirNames: [], ctx: ctx)
        }
    }

    private func pollCancel(_ ctx: Context) {
        ctx.entriesSincePoll += 1
        if ctx.entriesSincePoll >= Crawler.cancelPollInterval {
            ctx.entriesSincePoll = 0
            if ctx.shouldCancel() { ctx.stats.cancelled = true; ctx.stopped = true }
        }
    }

    private func handleListError(_ error: Error, path: String, ctx: Context) {
        if Crawler.isPermissionError(error) { recordDenied(path, ctx: ctx) }
        // Anything else (vanished directory, I/O error) is skipped silently.
    }

    private func recordDenied(_ path: String, ctx: Context) {
        if !ctx.stats.deniedPaths.contains(path) { ctx.stats.deniedPaths.append(path) }
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
    /// plain directory that should be recursed into; nil otherwise. The caller descends AFTER this
    /// directory's autoreleasepool drains, so a subtree never holds its ancestors' entry arrays alive.
    private func processEntry(_ entry: URL, parentId: Int32, depth: Int, maxDepth: Int, junk: Bool,
                              recursive: Bool, existingSubdirNames: Set<String>, ctx: Context) -> Descent? {
        guard let rv = try? entry.resourceValues(forKeys: keySet) else { return nil }
        let name = entry.lastPathComponent
        let flags = itemFlags(name: name, rv: rv, junk: junk, cloud: ctx.cloud)
        let ext = TextAnalyzer.fileExtension(of: name)
        if rv.isSymbolicLink == true {
            addItem(ctx, dir: parentId, name: name, kind: symlinkKind(entry, ext: ext), flags: flags, mtime: rv.contentModificationDate, depth: depth, ext: ext)
            return nil
        }
        guard rv.isDirectory == true else {
            addItem(ctx, dir: parentId, name: name, kind: ItemKind.forExtension(ext ?? ""), flags: flags, mtime: rv.contentModificationDate, depth: depth, ext: ext)
            return nil
        }
        if rv.isPackage == true || ext == "app" || (ext.map { Exclusions.packageExtensions.contains($0) } ?? false) {
            addPackage(entry, name: name, ext: ext, parentId: parentId, depth: depth, flags: flags, mtime: rv.contentModificationDate, ctx: ctx)
            return nil
        }
        addItem(ctx, dir: parentId, name: name, kind: .folder, flags: flags, mtime: rv.contentModificationDate, depth: depth, ext: nil)
        // Should this plain directory be descended?
        if !recursive && existingSubdirNames.contains(name) { return nil }
        if exclusions.isExcludedName(name) || pathMatcher.matches(entry.path) { ctx.stats.skippedExcluded += 1; return nil }
        guard depth < maxDepth else { return nil }
        let newId = ctx.builder.addDir(parent: parentId, name: name)
        ctx.stats.dirs += 1
        return Descent(path: entry.path, id: newId, junk: junk || exclusions.isDownrankName(name))
    }

    /// .app → app item (if enabled); other packages → leaf item with `.package`.
    private func addPackage(_ entry: URL, name: String, ext: String?, parentId: Int32, depth: Int, flags: ItemFlags, mtime: Date?, ctx: Context) {
        if ext == "app" {
            guard indexAppBundlesAsApps else { return }
            let itemName = AppScanner.stripAppExtension(name)
            let display = AppScanner.stripAppExtension(fm.displayName(atPath: entry.path))
            let info = AppInfo(bundleID: nil, displayName: display.isEmpty ? itemName : display, aliases: [])
            addItem(ctx, dir: parentId, name: itemName, kind: .app, flags: flags.union(.appBundle), mtime: mtime, depth: depth, ext: "app", app: info)
            return
        }
        addItem(ctx, dir: parentId, name: name, kind: ItemKind.forExtension(ext ?? ""), flags: flags.union(.package), mtime: mtime, depth: depth, ext: ext)
    }

    /// A symlink pointing at a directory is shown as a folder; otherwise classify by extension.
    private func symlinkKind(_ entry: URL, ext: String?) -> ItemKind {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue { return .folder }
        return ItemKind.forExtension(ext ?? "")
    }

    private func itemFlags(name: String, rv: URLResourceValues, junk: Bool, cloud: Bool) -> ItemFlags {
        var f: ItemFlags = []
        if junk { f.insert(.junk) }
        if cloud { f.insert(.cloud) }
        if rv.isHidden == true || name.hasPrefix(".") { f.insert(.hidden) }
        if name.hasPrefix(".") || name.hasPrefix("~$") { f.insert(.dotName) }
        if rv.isSymbolicLink == true { f.insert(.symlink) }
        return f
    }

    /// Add one item, enforcing the item cap and firing `onBatch`.
    private func addItem(_ ctx: Context, dir: Int32, name: String, kind: ItemKind, flags: ItemFlags, mtime: Date?, depth: Int, ext: String?, app: AppInfo? = nil) {
        // Cap check: a shared global counter under parallelism (exact global bound), else the local count.
        let underCap = ctx.sharedCount.map { $0.reserve(max: maxItems) } ?? (ctx.builder.count < maxItems)
        if !underCap { ctx.stats.hitItemCap = true; ctx.stopped = true; return }
        ctx.builder.addItem(dir: dir, name: name, analyzed: TextAnalyzer.analyze(name), kind: kind, flags: flags, mtime: mtime, depth: depth, ext: ext, app: app)
        ctx.stats.items += 1
        if ctx.builder.count - ctx.itemsAtLastBatch >= Crawler.batchSize {
            ctx.itemsAtLastBatch = ctx.builder.count
            ctx.onBatch?(ctx.builder)
        }
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
///    for child dirs that no longer exist on disk. Items in affected dirs are not copied. Dir entries are never removed
///    (ids stay stable; unreferenced entries are harmless and vanish at the next full crawl — path lookups prefer the
///    newest entry for a path).
/// 3. Re-list every surviving changed dir into a temporary builder (one temp root per dir), then append the temp
///    store's items/dirs to the kept arrays with ids/offsets rebased.
public enum IndexUpdater {
    public struct Change: Sendable, Equatable {
        public var path: String
        public var mustScanSubDirs: Bool
        public init(path: String, mustScanSubDirs: Bool) { self.path = path; self.mustScanSubDirs = mustScanSubDirs }
    }
    public static let fullRecrawlThreshold = 200

    /// Returns the updated store, or nil if the change set is too large / not applicable (caller should recrawl).
    /// Apps (kind .app under app roots) are preserved untouched; app-root changes are handled by rescanning apps.
    public static func apply(changes: [Change], to store: IndexStore, crawler: Crawler, generation: UInt64, fsEventId: UInt64) -> IndexStore? {
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

        let temp = IndexBuilder()
        var rootMap: [Int32: Int32] = [:]
        for w in work {
            let tmpRoot = temp.addRoot(w.path)
            rootMap[tmpRoot] = w.dirId
            crawler.crawlDirectory(w.path, dirId: tmpRoot, depth: crawler.depthOf(path: w.path), recursive: w.recursive,
                                   existingSubdirNames: w.existing, into: temp)
        }
        let keep = (0..<store.count).filter { !affected[Int(store.dirId[$0])] }
        return StoreMerge.merge(base: store, keep: keep, extra: temp.build(generation: 0), rootMap: rootMap,
                                generation: generation, fsEventId: fsEventId)
    }

    // MARK: Normalisation

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
            if path == rp || rp == "/" || path.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") { return true }
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
            let prefix = rp.hasSuffix("/") ? rp : rp + "/"
            if path == rp || path.hasPrefix(prefix) {
                if best == nil || rp.count > best!.0.count || (rp.count == best!.0.count && id > best!.1) { best = (rp, id) }
            }
        }
        guard let (rootPath, rootId) = best else { return nil }
        var rest = path.dropFirst(rootPath.count)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        var cur = rootId
        var depthBelowRoot = 0
        for comp in rest.split(separator: "/") {
            guard let next = child(of: cur, named: comp) else {
                return depthBelowRoot == 0 ? nil : (cur, false)
            }
            cur = next
            depthBelowRoot += 1
        }
        return depthBelowRoot == 0 ? nil : (cur, true)
    }

    private func child(of d: Int32, named comp: Substring) -> Int32? {
        let bytes = Array(comp.utf8)
        var found: Int32?
        for c in children[Int(d)] {
            let e = store.dirs[Int(c)]
            let s = Int(e.nameStart), l = Int(e.nameLen)
            if l == bytes.count && store.dirArena[s..<(s + l)].elementsEqual(bytes) { found = c }  // newest wins
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
    /// Same contents, new generation/fsEventId (arrays are shared copy-on-write).
    static func rebrand(_ s: IndexStore, generation: UInt64, fsEventId: UInt64, builtAt: Date = Date()) -> IndexStore {
        IndexStore(count: s.count, dirId: s.dirId, nameStart: s.nameStart, nameLen: s.nameLen, displayStart: s.displayStart, displayLen: s.displayLen,
                   mask: s.mask, initials: s.initials, mtime: s.mtime, kind: s.kind, flags: s.flags, depth: s.depth, extId: s.extId,
                   foldedArena: s.foldedArena, bonusArena: s.bonusArena, displayArena: s.displayArena, dirs: s.dirs, dirArena: s.dirArena,
                   extensions: s.extensions, appInfo: s.appInfo, appItems: s.appItems, generation: generation, fsEventId: fsEventId, builtAt: builtAt)
    }

    /// Items of `base` whose dir entry is a root (parent == -1), kind .app, depth 1 — i.e. added by `AppScanner.add`.
    static func isScannerApp(_ s: IndexStore, _ i: Int) -> Bool {
        guard s.kind[i] == ItemKind.app.rawValue, s.depth[i] == 1 else { return false }
        let d = Int(s.dirId[i])
        return d >= 0 && d < s.dirs.count && s.dirs[d].parent < 0
    }

    /// Build `base[keep] + extra`. `rootMap` maps root entries (parent == -1) of `extra` onto existing base dir ids;
    /// unmapped extra roots are matched by absolute path to a base root (newest wins) or appended as new roots.
    /// `keep` must be ascending.
    static func merge(base: IndexStore, keep: [Int], extra: IndexStore, rootMap explicitRootMap: [Int32: Int32],
                      generation: UInt64, fsEventId: UInt64) -> IndexStore {
        // 1. Dir table: base dirs unchanged, extra dirs appended with remapped parents.
        var dirMap = [Int32](repeating: -1, count: extra.dirs.count)
        var dirs = base.dirs
        var dirArena = base.dirArena
        let baseRoots = rootsByPath(base)
        for (i, e) in extra.dirs.enumerated() {
            if e.parent < 0 {
                let name = dirName(extra, i)
                if let m = explicitRootMap[Int32(i)] ?? baseRoots[name] { dirMap[i] = m; continue }
            }
            let start = Int32(dirArena.count)
            dirArena.append(contentsOf: extra.dirArena[Int(e.nameStart)..<(Int(e.nameStart) + Int(e.nameLen))])
            let parent: Int32 = e.parent < 0 ? -1 : dirMap[Int(e.parent)]
            dirs.append(DirEntry(parent: parent, nameStart: start, nameLen: e.nameLen))
            dirMap[i] = Int32(dirs.count - 1)
        }
        // 2. Extensions.
        var extensions = base.extensions
        var extIndex: [String: Int16] = [:]
        for (i, e) in extensions.enumerated() { extIndex[e] = Int16(clamping: i) }
        var extMap = [Int16](repeating: -1, count: extra.extensions.count)
        for (i, e) in extra.extensions.enumerated() {
            if let id = extIndex[e] { extMap[i] = id } else {
                let id = Int16(clamping: extensions.count); extensions.append(e); extIndex[e] = id; extMap[i] = id
            }
        }
        // 3. Arenas: kept arenas are compacted only when more than half is dead.
        let keptNameBytes = keep.reduce(0) { $0 + Int(base.nameLen[$1]) }
        let keptDisplayBytes = keep.reduce(0) { $0 + Int(base.displayLen[$1]) }
        let compact = keep.count < base.count && (keptNameBytes < base.foldedArena.count / 2 || keptDisplayBytes < base.displayArena.count / 2)
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
        var dirId = pick(base.dirId, keep); dirId.append(contentsOf: extra.dirId.map { dirMap[Int($0)] })
        var nameLen = pick(base.nameLen, keep); nameLen.append(contentsOf: extra.nameLen)
        var displayLen = pick(base.displayLen, keep); displayLen.append(contentsOf: extra.displayLen)
        var mask = pick(base.mask, keep); mask.append(contentsOf: extra.mask)
        var initials = pick(base.initials, keep); initials.append(contentsOf: extra.initials)
        var mtime = pick(base.mtime, keep); mtime.append(contentsOf: extra.mtime)
        var kind = pick(base.kind, keep); kind.append(contentsOf: extra.kind)
        var flags = pick(base.flags, keep); flags.append(contentsOf: extra.flags)
        var depth = pick(base.depth, keep); depth.append(contentsOf: extra.depth)
        var extId = pick(base.extId, keep); extId.append(contentsOf: extra.extId.map { $0 >= 0 ? extMap[Int($0)] : -1 })
        // 5. Side tables.
        var newIndex: [Int32: Int32] = [:]
        if !base.appInfo.isEmpty || !base.appItems.isEmpty {
            newIndex.reserveCapacity(base.appInfo.count)
            let appSet = Set(base.appInfo.keys).union(base.appItems)
            for (n, i) in keep.enumerated() where appSet.contains(Int32(i)) { newIndex[Int32(i)] = Int32(n) }
        }
        var appInfo: [Int32: AppInfo] = [:]
        for (k, v) in base.appInfo { if let n = newIndex[k] { appInfo[n] = v } }
        let offset = Int32(keep.count)
        for (k, v) in extra.appInfo { appInfo[k + offset] = v }
        var appItems = base.appItems.compactMap { newIndex[$0] }
        appItems.append(contentsOf: extra.appItems.map { $0 + offset })
        return IndexStore(count: keep.count + extra.count, dirId: dirId, nameStart: nameStart, nameLen: nameLen, displayStart: displayStart,
                          displayLen: displayLen, mask: mask, initials: initials, mtime: mtime, kind: kind, flags: flags, depth: depth, extId: extId,
                          foldedArena: foldedArena, bonusArena: bonusArena, displayArena: displayArena, dirs: dirs, dirArena: dirArena,
                          extensions: extensions, appInfo: appInfo, appItems: appItems, generation: generation, fsEventId: fsEventId, builtAt: Date())
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
