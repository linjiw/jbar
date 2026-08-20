import XCTest
@testable import JBarCore

/// Tests for `Crawler` + `IndexUpdater` (DESIGN.md §4.2–4.5): the depth-first walk, exclusion /
/// downrank / hidden / symlink / package rules, the item + depth caps, batching & cancellation,
/// and incremental FSEvents-delta application.
final class CrawlerTests: XCTestCase {
    private var tempDir: URL!
    private var tempHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // Canonicalise (/var → /private/var) so the paths we build match what the OS reports back when
        // enumerating directories; otherwise recorded paths and root prefixes would not compare equal.
        let raw = fm.temporaryDirectory.appendingPathComponent("jbar-crawler-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let canon = (try raw.resourceValues(forKeys: [.canonicalPathKey])).canonicalPath ?? raw.path
        tempDir = URL(fileURLWithPath: canon, isDirectory: true)
        tempHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tempDir { try? fm.removeItem(at: d) }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    private func write(_ url: URL, _ text: String = "x") throws {
        try mkdir(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
    }

    /// Build the sample tree under `root` and return the root URL.
    private func makeTree() throws -> URL {
        let root = tempDir.appendingPathComponent("tree", isDirectory: true)
        try mkdir(root.appendingPathComponent("Desktop"))
        try mkdir(root.appendingPathComponent("Downloads"))
        try write(root.appendingPathComponent("Documents/inside.txt"))
        try write(root.appendingPathComponent("projects/app/src/main.swift"), "import Foundation")
        try write(root.appendingPathComponent("projects/app/node_modules/dep/index.js"), "module")
        try write(root.appendingPathComponent("projects/app/.git/config"), "[core]")
        try write(root.appendingPathComponent("a.pdf"))
        try write(root.appendingPathComponent("b.txt"))
        try write(root.appendingPathComponent("notes.md"))
        try write(root.appendingPathComponent("build/x.o"))
        try write(root.appendingPathComponent(".secret"), "shh")
        // Symlink link -> Documents (must not be followed).
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("Documents"))
        // An .app bundle directory (must be a leaf; Contents not descended).
        try write(root.appendingPathComponent("Foo.app/Contents/Info.plist"), "<plist/>")
        return root
    }

    private func crawl(_ root: URL, exclusions: Exclusions? = nil, maxItems: Int = 1_000_000, maxDepth: Int? = nil,
                       onBatch: ((IndexBuilder) -> Void)? = nil,
                       shouldCancel: () -> Bool = { false }) -> (store: IndexStore, stats: CrawlStats) {
        var ex = exclusions ?? Exclusions.defaults(home: tempHome.path)
        if let md = maxDepth { ex.maxDepth = md }
        let crawler = Crawler(roots: [CrawlRoot(path: root.path)], exclusions: ex, maxItems: maxItems)
        let b = IndexBuilder()
        let stats = crawler.crawl(into: b, onBatch: onBatch, shouldCancel: shouldCancel)
        return (b.build(generation: 1), stats)
    }

    private func indices(of name: String, in store: IndexStore) -> [Int] {
        (0..<store.count).filter { store.name(of: $0) == name }
    }
    private func index(of name: String, in store: IndexStore) -> Int? { indices(of: name, in: store).first }
    private func present(_ name: String, in store: IndexStore) -> Bool { index(of: name, in: store) != nil }

    // MARK: - The sample tree

    func testCrawlSampleTree() throws {
        let root = try makeTree()
        let (store, stats) = crawl(root)

        // Excluded directories are indexed as items but never descended.
        XCTAssertTrue(present("node_modules", in: store))
        XCTAssertFalse(present("dep", in: store))
        XCTAssertFalse(present("index.js", in: store))
        // `.git` is hidden AND excluded: with skipsHiddenFiles it is not even listed.
        XCTAssertFalse(present(".git", in: store))
        XCTAssertFalse(present("config", in: store))

        // Ordinary files carry the right kind + extension.
        let pdf = try XCTUnwrap(index(of: "a.pdf", in: store))
        XCTAssertEqual(store.itemKind(pdf), .document); XCTAssertEqual(store.ext(of: pdf), "pdf")
        let txt = try XCTUnwrap(index(of: "b.txt", in: store))
        XCTAssertEqual(store.itemKind(txt), .document); XCTAssertEqual(store.ext(of: txt), "txt")
        let md = try XCTUnwrap(index(of: "notes.md", in: store))
        XCTAssertEqual(store.itemKind(md), .document); XCTAssertEqual(store.ext(of: md), "md")
        let sw = try XCTUnwrap(index(of: "main.swift", in: store))
        XCTAssertEqual(store.itemKind(sw), .code); XCTAssertEqual(store.ext(of: sw), "swift")

        // Files under a downrank directory (build/) inherit the .junk flag.
        let obj = try XCTUnwrap(index(of: "x.o", in: store))
        XCTAssertTrue(store.itemFlags(obj).contains(.junk), "build/ child should be junk")

        // Hidden files are excluded by default.
        XCTAssertFalse(present(".secret", in: store))

        // The symlink is recorded with .symlink, classified as a folder (target is a dir), and not followed
        // (inside.txt appears exactly once, only under Documents).
        let link = try XCTUnwrap(index(of: "link", in: store))
        XCTAssertTrue(store.itemFlags(link).contains(.symlink))
        XCTAssertEqual(store.itemKind(link), .folder)
        XCTAssertEqual(indices(of: "inside.txt", in: store).count, 1, "symlink must not be followed")

        // Foo.app is an app leaf; its Contents is not descended.
        let foo = try XCTUnwrap(index(of: "Foo", in: store))
        XCTAssertEqual(store.itemKind(foo), .app)
        XCTAssertTrue(store.itemFlags(foo).contains(.appBundle))
        XCTAssertEqual(store.fileName(of: foo), "Foo.app")
        XCTAssertFalse(present("Contents", in: store))
        XCTAssertFalse(present("Info.plist", in: store))

        XCTAssertGreaterThan(stats.items, 0)
        XCTAssertGreaterThan(stats.dirs, 0)
        XCTAssertGreaterThan(stats.skippedExcluded, 0, "node_modules should count as skipped-excluded")
    }

    func testIncludeHiddenSurfacesDotFiles() throws {
        let root = try makeTree()
        var ex = Exclusions.defaults(home: tempHome.path)
        ex.includeHidden = true
        let (store, _) = crawl(root, exclusions: ex)
        XCTAssertTrue(present(".secret", in: store))
        // `.git` is now listed but still excluded-by-name, so it is a leaf item with no `config` child.
        XCTAssertTrue(present(".git", in: store))
        XCTAssertFalse(present("config", in: store))
        // node_modules is still excluded.
        XCTAssertFalse(present("index.js", in: store))
    }

    func testMaxItemsSetsHitItemCap() throws {
        let root = try makeTree()
        let (store, stats) = crawl(root, maxItems: 5)
        XCTAssertTrue(stats.hitItemCap)
        XCTAssertEqual(store.count, 5)
    }

    func testMaxDepthHonored() throws {
        let root = try makeTree()
        let (store, _) = crawl(root, maxDepth: 1)
        // Direct children of the root (depth 1) are present…
        XCTAssertTrue(present("a.pdf", in: store))
        XCTAssertTrue(present("projects", in: store))
        // …but nothing deeper is descended.
        XCTAssertFalse(present("app", in: store))
        XCTAssertFalse(present("main.swift", in: store))
    }

    // MARK: - Batching & cancellation (need enough entries to cross the thresholds)

    private func makeBigDir(_ name: String, count: Int) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try mkdir(dir)
        for i in 0..<count { fm.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: Data()) }
        return dir
    }

    func testOnBatchFiresAcrossBatchSize() throws {
        // > batchSize (5000) items → onBatch is called at least once with a non-empty partial builder.
        let dir = try makeBigDir("big", count: Crawler.batchSize + 200)
        var batchCalls = 0
        var lastPartialCount = 0
        let (store, _) = crawl(dir, onBatch: { b in batchCalls += 1; lastPartialCount = b.count })
        XCTAssertGreaterThanOrEqual(batchCalls, 1, "onBatch should fire past \(Crawler.batchSize) items")
        XCTAssertGreaterThan(lastPartialCount, 0)
        XCTAssertGreaterThan(store.count, Crawler.batchSize)
    }

    func testShouldCancelStopsEarly() throws {
        // > cancelPollInterval (1000) entries so the poll actually fires; cancel immediately.
        let dir = try makeBigDir("cancel", count: 2500)
        let (store, stats) = crawl(dir, shouldCancel: { true })
        XCTAssertTrue(stats.cancelled)
        XCTAssertLessThan(store.count, 2500, "crawl should stop before listing everything")
    }

    // MARK: - crawlDirectory

    func testCrawlDirectoryRecursiveVsDirectEntries() throws {
        // A directory with only files: non-recursive adds exactly those direct entries.
        let flat = tempDir.appendingPathComponent("flat", isDirectory: true)
        try write(flat.appendingPathComponent("one.txt"))
        try write(flat.appendingPathComponent("two.txt"))
        let ex = Exclusions.defaults(home: tempHome.path)
        let crawler = Crawler(roots: [CrawlRoot(path: flat.path)], exclusions: ex)

        let b1 = IndexBuilder()
        let root1 = b1.addRoot(flat.path)
        let added = crawler.crawlDirectory(flat.path, dirId: root1, depth: 0, recursive: false, into: b1)
        let s1 = b1.build(generation: 1)
        XCTAssertEqual(added, 2)
        XCTAssertTrue(present("one.txt", in: s1))
        XCTAssertTrue(present("two.txt", in: s1))

        // With a nested subdir, recursive:true pulls in the whole subtree.
        let nested = tempDir.appendingPathComponent("nested", isDirectory: true)
        try write(nested.appendingPathComponent("top.txt"))
        try write(nested.appendingPathComponent("sub/leaf.txt"))
        let crawler2 = Crawler(roots: [CrawlRoot(path: nested.path)], exclusions: ex)
        let b2 = IndexBuilder()
        let root2 = b2.addRoot(nested.path)
        crawler2.crawlDirectory(nested.path, dirId: root2, depth: 0, recursive: true, into: b2)
        let s2 = b2.build(generation: 1)
        XCTAssertTrue(present("top.txt", in: s2))
        XCTAssertTrue(present("leaf.txt", in: s2), "recursive crawlDirectory should descend subdirs")

        // The `existingSubdirNames` overload leaves a known subdir as a leaf (item, but not descended).
        let b3 = IndexBuilder()
        let root3 = b3.addRoot(nested.path)
        crawler2.crawlDirectory(nested.path, dirId: root3, depth: 0, recursive: false,
                                existingSubdirNames: ["sub"], into: b3)
        let s3 = b3.build(generation: 1)
        XCTAssertTrue(present("top.txt", in: s3))
        XCTAssertFalse(present("leaf.txt", in: s3), "known subdir should not be descended")
    }

    func testPathHasDownrankComponent() throws {
        let root = try makeTree()
        let crawler = Crawler(roots: [CrawlRoot(path: root.path)], exclusions: Exclusions.defaults(home: tempHome.path))
        // Whole-path scan (no root given): any component may be a downrank name.
        XCTAssertTrue(crawler.pathHasDownrankComponent("/a/build/c"))
        XCTAssertFalse(crawler.pathHasDownrankComponent("/a/src/c"))
        // With a root, only components at/below the root count (matching full-crawl junk seeding):
        // a downrank name *above* the root is ignored…
        XCTAssertFalse(crawler.pathHasDownrankComponent("/x/build/root/src/a", belowRoot: "/x/build/root"))
        // …while one at/below the root still flags it.
        XCTAssertTrue(crawler.pathHasDownrankComponent("/x/root/build/a", belowRoot: "/x/root"))
    }

    // MARK: - IndexUpdater.apply

    func testIndexUpdaterAppliesIncrementalChange() throws {
        let root = tempDir.appendingPathComponent("iu", isDirectory: true)
        try write(root.appendingPathComponent("Documents/keep.txt"))
        try write(root.appendingPathComponent("Documents/sub/deep.txt"))

        // Add an app so we can verify apps survive an incremental file change.
        let appsDir = tempDir.appendingPathComponent("iu-apps", isDirectory: true)
        try mkdir(appsDir.appendingPathComponent("Solo.app/Contents"))
        try Data("<plist/>".utf8).write(to: appsDir.appendingPathComponent("Solo.app/Contents/Info.plist"))
        let scanned = AppScanner.scan(roots: [appsDir.path], extraBundles: [], home: tempHome.path)
        XCTAssertGreaterThanOrEqual(scanned.count, 1)

        let ex = Exclusions.defaults(home: tempHome.path)
        let crawler = Crawler(roots: [CrawlRoot(path: root.path)], exclusions: ex)
        let builder = IndexBuilder()
        AppScanner.add(scanned, to: builder)
        crawler.crawl(into: builder)
        let store = builder.build(generation: 1, fsEventId: 100)

        XCTAssertTrue(present("keep.txt", in: store))
        XCTAssertFalse(present("new.txt", in: store))
        let appCount = store.appItems.count
        let dirCount = store.dirs.count
        XCTAssertGreaterThanOrEqual(appCount, 1)

        // A new file with a novel extension, plus a brand-new subdirectory, appear in Documents;
        // apply a non-recursive change on Documents.
        try write(root.appendingPathComponent("Documents/new.log"))            // "log" is a new extension
        try write(root.appendingPathComponent("Documents/fresh/inner.txt"))    // a subdir not seen before
        let docsPath = root.appendingPathComponent("Documents").path
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [.init(path: docsPath, mustScanSubDirs: false)],
                                                       to: store, crawler: crawler, generation: 2, fsEventId: 200))
        let newLog = try XCTUnwrap(index(of: "new.log", in: updated))
        XCTAssertEqual(updated.ext(of: newLog), "log", "new extension should be interned")
        XCTAssertTrue(present("keep.txt", in: updated))
        XCTAssertTrue(present("deep.txt", in: updated), "untouched subdir contents should be preserved")
        XCTAssertTrue(present("inner.txt", in: updated), "a newly-created subdir is descended even in non-recursive mode")
        XCTAssertEqual(updated.appItems.count, appCount, "apps must be preserved")
        XCTAssertGreaterThan(updated.dirs.count, dirCount, "the new subdir adds a dir entry")
        XCTAssertEqual(updated.generation, 2)
        XCTAssertEqual(updated.fsEventId, 200)
    }

    func testIndexUpdaterReturnsNilWhenChangeSetTooLarge() throws {
        let root = tempDir.appendingPathComponent("big-change", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let n = IndexUpdater.fullRecrawlThreshold + 5
        for i in 0..<n { try mkdir(docs.appendingPathComponent("d\(i)")) }

        let ex = Exclusions.defaults(home: tempHome.path)
        let crawler = Crawler(roots: [CrawlRoot(path: root.path)], exclusions: ex)
        let builder = IndexBuilder()
        crawler.crawl(into: builder)
        let store = builder.build(generation: 1, fsEventId: 100)

        let changes = (0..<n).map { IndexUpdater.Change(path: docs.appendingPathComponent("d\($0)").path, mustScanSubDirs: false) }
        XCTAssertNil(IndexUpdater.apply(changes: changes, to: store, crawler: crawler, generation: 2, fsEventId: 200),
                     "a change set above the threshold must signal a full recrawl (nil)")
    }

    private func crawlerAndStore(_ root: URL, exclusions: Exclusions? = nil) -> (Crawler, IndexStore) {
        let ex = exclusions ?? Exclusions.defaults(home: tempHome.path)
        let crawler = Crawler(roots: [CrawlRoot(path: root.path)], exclusions: ex)
        let b = IndexBuilder()
        crawler.crawl(into: b)
        return (crawler, b.build(generation: 1, fsEventId: 100))
    }

    func testIndexUpdaterRecursiveChangePicksUpNestedFiles() throws {
        let root = tempDir.appendingPathComponent("rec", isDirectory: true)
        try write(root.appendingPathComponent("Documents/keep.txt"))
        try write(root.appendingPathComponent("Documents/sub/deep.txt"))
        let (crawler, store) = crawlerAndStore(root)
        try write(root.appendingPathComponent("Documents/sub/nested-new.txt"))
        let docs = root.appendingPathComponent("Documents").path
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [.init(path: docs, mustScanSubDirs: true)],
                                                       to: store, crawler: crawler, generation: 2, fsEventId: 200))
        XCTAssertTrue(present("keep.txt", in: updated))
        XCTAssertTrue(present("deep.txt", in: updated))
        XCTAssertTrue(present("nested-new.txt", in: updated), "recursive change must descend into subdirs")
    }

    func testIndexUpdaterDropsDescendantsOfRecursiveChange() throws {
        let root = tempDir.appendingPathComponent("drop", isDirectory: true)
        try write(root.appendingPathComponent("Documents/keep.txt"))
        try write(root.appendingPathComponent("Documents/sub/deep.txt"))
        let (crawler, store) = crawlerAndStore(root)
        // A recursive change on Documents plus a non-recursive change on its descendant `sub`:
        // the descendant must be dropped from the plan (the ancestor already covers it).
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [
            .init(path: root.appendingPathComponent("Documents").path, mustScanSubDirs: true),
            .init(path: root.appendingPathComponent("Documents/sub").path, mustScanSubDirs: false),
        ], to: store, crawler: crawler, generation: 2, fsEventId: 200))
        XCTAssertTrue(present("keep.txt", in: updated))
        XCTAssertTrue(present("deep.txt", in: updated))
    }

    func testIndexUpdaterEmptyPlanRebrands() throws {
        let root = tempDir.appendingPathComponent("rebrand", isDirectory: true)
        try write(root.appendingPathComponent("Documents/keep.txt"))
        let (crawler, store) = crawlerAndStore(root)
        // A change outside the crawler roots is filtered → empty plan → the store is rebranded (same
        // contents, new generation / fsEventId).
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [.init(path: "/definitely/not/a/root", mustScanSubDirs: false)],
                                                       to: store, crawler: crawler, generation: 9, fsEventId: 900))
        XCTAssertEqual(updated.count, store.count)
        XCTAssertEqual(updated.generation, 9)
        XCTAssertEqual(updated.fsEventId, 900)
        XCTAssertTrue(present("keep.txt", in: updated))
    }

    func testIndexUpdaterInexactResolveToAncestor() throws {
        let root = tempDir.appendingPathComponent("inexact", isDirectory: true)
        try write(root.appendingPathComponent("Documents/keep.txt"))
        let (crawler, store) = crawlerAndStore(root)
        // A change on a path with no dir entry (a file) resolves to its nearest indexed ancestor (Documents).
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [
            .init(path: root.appendingPathComponent("Documents/keep.txt").path, mustScanSubDirs: false),
        ], to: store, crawler: crawler, generation: 3, fsEventId: 300))
        XCTAssertTrue(present("keep.txt", in: updated))
        XCTAssertEqual(updated.generation, 3)
    }

    func testStoreMergeCompactsWhenMostItemsReplaced() throws {
        let root = tempDir.appendingPathComponent("compact", isDirectory: true)
        // Documents dominates the arenas; the root holds one short file.
        for i in 0..<30 { try write(root.appendingPathComponent("Documents/a_very_long_descriptive_file_name_\(i).txt")) }
        try write(root.appendingPathComponent("z.txt"))
        let (crawler, store) = crawlerAndStore(root)
        // A recursive change on Documents means almost every item is replaced → the merge takes its
        // arena-compaction path (keep is a tiny fraction of the base arenas).
        let updated = try XCTUnwrap(IndexUpdater.apply(changes: [
            .init(path: root.appendingPathComponent("Documents").path, mustScanSubDirs: true),
        ], to: store, crawler: crawler, generation: 2, fsEventId: 200))
        XCTAssertEqual(updated.count, store.count)
        XCTAssertTrue(present("z.txt", in: updated))
        XCTAssertTrue(present("a_very_long_descriptive_file_name_0.txt", in: updated))
        XCTAssertTrue(present("a_very_long_descriptive_file_name_29.txt", in: updated))
    }

    // MARK: - defaultRoots

    func testDefaultRoots() throws {
        // An unreadable / missing home directory yields no roots.
        XCTAssertTrue(Crawler.defaultRoots(home: tempDir.appendingPathComponent("nope").path,
                                           exclusions: .defaults(home: tempHome.path)).isEmpty)
        // Priority order (Desktop, Documents, Downloads, projects) then alphabetical; never-root and
        // excluded names are dropped, and non-directories are ignored.
        let home = tempDir.appendingPathComponent("droot", isDirectory: true)
        for d in ["Downloads", "Documents", "Desktop", "projects", "alpha", "Zeta",
                  "Library", "Applications", "Public", "node_modules"] {
            try mkdir(home.appendingPathComponent(d))
        }
        try write(home.appendingPathComponent("loose-file.txt"))
        let roots = Crawler.defaultRoots(home: home.path, exclusions: .defaults(home: home.path))
        let names = roots.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(names, ["Desktop", "Documents", "Downloads", "projects", "alpha", "Zeta"])
    }

    // MARK: - Denied / capped directories, packages, and file symlinks

    func testCappedDirectoryIsNotDescended() throws {
        let dir = tempDir.appendingPathComponent("capped", isDirectory: true)
        for i in 0..<6 { try write(dir.appendingPathComponent("f\(i).txt")) }
        var ex = Exclusions.defaults(home: tempHome.path)
        ex.maxDirEntries = 2 // 6 entries > 2 → the directory is capped and its children skipped
        let (store, stats) = crawl(dir, exclusions: ex)
        XCTAssertTrue(stats.cappedDirs.contains(dir.path), "capped: \(stats.cappedDirs)")
        XCTAssertFalse(present("f0.txt", in: store))
    }

    func testUnreadableFileRootIsRecordedAsDenied() throws {
        let f = tempDir.appendingPathComponent("secret", isDirectory: false)
        try write(f, "x")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }
        let crawler = Crawler(roots: [CrawlRoot(path: f.path)], exclusions: Exclusions.defaults(home: tempHome.path))
        let b = IndexBuilder()
        let stats = crawler.crawl(into: b)
        XCTAssertTrue(stats.deniedPaths.contains(f.path), "denied: \(stats.deniedPaths)")
    }

    func testUnreadableSubdirectoryIsRecordedAsDenied() throws {
        let root = tempDir.appendingPathComponent("denyroot", isDirectory: true)
        try write(root.appendingPathComponent("ok.txt"))
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try mkdir(locked)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (store, stats) = crawl(root)
        XCTAssertTrue(present("ok.txt", in: store))
        XCTAssertTrue(present("locked", in: store), "the locked dir is still indexed as an item")
        XCTAssertTrue(stats.deniedPaths.contains(locked.path), "denied: \(stats.deniedPaths)")
    }

    func testNonAppPackageIsLeafAndFileSymlinkClassifiedByExtension() throws {
        let root = tempDir.appendingPathComponent("pkgroot", isDirectory: true)
        try write(root.appendingPathComponent("Project.xcodeproj/project.pbxproj"), "{}")
        try write(root.appendingPathComponent("target.txt"), "hi")
        try fm.createSymbolicLink(at: root.appendingPathComponent("flink"),
                                  withDestinationURL: root.appendingPathComponent("target.txt"))
        let (store, _) = crawl(root)
        // A non-.app package is a leaf item with the .package flag; its contents are not indexed.
        let proj = try XCTUnwrap(index(of: "Project.xcodeproj", in: store))
        XCTAssertTrue(store.itemFlags(proj).contains(.package))
        XCTAssertFalse(present("project.pbxproj", in: store))
        // A symlink to a file is classified by extension (not folder) and flagged .symlink.
        let fl = try XCTUnwrap(index(of: "flink", in: store))
        XCTAssertTrue(store.itemFlags(fl).contains(.symlink))
        XCTAssertNotEqual(store.itemKind(fl), .folder)
    }

    func testIsPermissionErrorClassification() {
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertTrue(Crawler.isPermissionError(eacces))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertTrue(Crawler.isPermissionError(cocoa))
        // Wrapped underlying error is unwrapped.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: eacces])
        XCTAssertTrue(Crawler.isPermissionError(wrapped))
        // A non-permission error is not misclassified.
        XCTAssertFalse(Crawler.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }
}
