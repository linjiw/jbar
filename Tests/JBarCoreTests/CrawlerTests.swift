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
        let raw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/core-review-tests/jbar-crawler-\(UUID().uuidString)", isDirectory: true)
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
        try write(root.appendingPathComponent(".\u{0301}decorated-secret"), "still hidden")
        // Symlink link -> Documents (must not be followed).
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("Documents"))
        // An .app bundle directory (must be a leaf; Contents not descended).
        try write(root.appendingPathComponent("Foo.app/Contents/Info.plist"), "<plist/>")
        return root
    }

    private func crawl(_ root: URL, exclusions: Exclusions? = nil, maxItems: Int = 1_000_000, maxDepth: Int? = nil,
                       onBatch: (@Sendable (IndexBuilder) -> Void)? = nil,
                       shouldCancel: @escaping @Sendable () -> Bool = { false }) -> (store: IndexStore, stats: CrawlStats) {
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
        XCTAssertFalse(present(".\u{0301}decorated-secret", in: store),
                       "a POSIX dot byte remains hidden when followed by a combining scalar")

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

    func testCoordinatedDirectoryToSymlinkSwapCannotEscapeRoot() throws {
        let root = tempDir.appendingPathComponent("swap-root", isDirectory: true)
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try write(victim.appendingPathComponent("inside.txt"))
        try write(outside.appendingPathComponent("outside-secret.txt"))

        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path))
        let fixture = LockedBox(RaceOutcome())
        crawler.beforeOpeningDirectoryForTesting = { path in
            let shouldSwap = fixture.withValue { outcome in
                guard path == victim.path, !outcome.fired else { return false }
                outcome.fired = true
                return true
            }
            guard shouldSwap else { return }
            do {
                let fileManager = FileManager()
                try fileManager.removeItem(at: victim)
                try fileManager.createSymbolicLink(at: victim, withDestinationURL: outside)
            } catch { fixture.withValue { $0.error = error } }
        }
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)
        let store = builder.build(generation: 1)

        let outcome = fixture.value
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.fired, "fixture must swap exactly between classification and openat")
        XCTAssertTrue(present("victim", in: store), "the safely classified directory item remains visible")
        XCTAssertFalse(present("outside-secret.txt", in: store))
        XCTAssertGreaterThanOrEqual(stats.skippedUnsafe, 1)
    }

    func testCoordinatedDirectoryReplacementFailsIdentityCheck() throws {
        let root = tempDir.appendingPathComponent("replace-root", isDirectory: true)
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let parked = tempDir.appendingPathComponent("parked", isDirectory: true)
        try write(victim.appendingPathComponent("original.txt"))

        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path))
        let fixture = LockedBox(RaceOutcome())
        crawler.beforeOpeningDirectoryForTesting = { path in
            let shouldReplace = fixture.withValue { outcome in
                guard path == victim.path, !outcome.fired else { return false }
                outcome.fired = true
                return true
            }
            guard shouldReplace else { return }
            do {
                let fileManager = FileManager()
                try fileManager.moveItem(at: victim, to: parked)
                try fileManager.createDirectory(at: victim, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: victim.appendingPathComponent("replacement-secret.txt"))
            } catch { fixture.withValue { $0.error = error } }
        }
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)
        let store = builder.build(generation: 1)

        let outcome = fixture.value
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.fired)
        XCTAssertFalse(present("replacement-secret.txt", in: store),
                       "a same-name replacement must not inherit the queued descent")
        XCTAssertGreaterThanOrEqual(stats.skippedUnsafe, 1)
    }

    func testOpenedDirectoryMovedOutsideRootIsRejectedBeforeEnumeration() throws {
        let root = tempDir.appendingPathComponent("move-root", isDirectory: true)
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let parked = tempDir.appendingPathComponent("moved-outside", isDirectory: true)
        try write(victim.appendingPathComponent("original.txt"))

        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path))
        let fixture = LockedBox(RaceOutcome())
        crawler.afterOpeningDirectoryForTesting = { path in
            let shouldMove = fixture.withValue { outcome in
                guard path == victim.path, !outcome.fired else { return false }
                outcome.fired = true
                return true
            }
            guard shouldMove else { return }
            do {
                let fileManager = FileManager()
                try fileManager.moveItem(at: victim, to: parked)
                try Data("x".utf8).write(to: parked.appendingPathComponent("late-secret.txt"))
            } catch { fixture.withValue { $0.error = error } }
        }
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)
        let store = builder.build(generation: 1)

        let outcome = fixture.value
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.fired)
        XCTAssertFalse(present("original.txt", in: store))
        XCTAssertFalse(present("late-secret.txt", in: store))
        XCTAssertGreaterThanOrEqual(stats.skippedUnsafe, 1)
        XCTAssertTrue(stats.deniedPaths.isEmpty, "unsafe paths must be counted, not retained as diagnostics")
    }

    func testSymlinkRootAndIncrementalIntermediateSymlinkAreRejected() throws {
        let root = tempDir.appendingPathComponent("physical-root", isDirectory: true)
        let outside = tempDir.appendingPathComponent("physical-outside", isDirectory: true)
        try mkdir(root)
        try write(outside.appendingPathComponent("secret.txt"))
        let linkedRoot = tempDir.appendingPathComponent("linked-root", isDirectory: true)
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        let linkedCrawler = Crawler(roots: [.init(path: linkedRoot.path)],
                                    exclusions: .defaults(home: tempHome.path))
        let linkedBuilder = IndexBuilder()
        let linkedStats = linkedCrawler.crawl(into: linkedBuilder)
        XCTAssertEqual(linkedBuilder.count, 0)
        XCTAssertGreaterThanOrEqual(linkedStats.skippedUnsafe, 1)

        let safe = root.appendingPathComponent("safe", isDirectory: true)
        try mkdir(safe)
        let escape = safe.appendingPathComponent("escape", isDirectory: true)
        try fm.createSymbolicLink(at: escape, withDestinationURL: outside)
        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path))
        let incremental = IndexBuilder()
        let rootID = incremental.addRoot(root.path)
        let stats = crawler.crawlDirectoryReporting(escape.path, dirId: rootID, depth: 2,
                                                    recursive: true, existingSubdirNames: [],
                                                    into: incremental, itemLimit: 100)
        XCTAssertEqual(incremental.count, 0)
        XCTAssertGreaterThanOrEqual(stats.skippedUnsafe, 1)
    }

    func testSymlinkLoopIsIndexedOnceAndNeverDescended() throws {
        let root = tempDir.appendingPathComponent("loop-root", isDirectory: true)
        let branch = root.appendingPathComponent("branch", isDirectory: true)
        try write(branch.appendingPathComponent("leaf.txt"))
        try fm.createSymbolicLink(at: branch.appendingPathComponent("back"),
                                  withDestinationURL: branch)

        let (store, stats) = crawl(root)
        XCTAssertEqual(indices(of: "leaf.txt", in: store).count, 1)
        XCTAssertEqual(indices(of: "back", in: store).count, 1)
        let back = try XCTUnwrap(index(of: "back", in: store))
        XCTAssertTrue(store.itemFlags(back).contains(.symlink))
        XCTAssertEqual(store.itemKind(back), .folder)
        XCTAssertFalse(stats.hitItemCap)
    }

    func testExcludedDirectoryRemainsExcludedDuringConcurrentSwap() throws {
        let root = tempDir.appendingPathComponent("excluded-churn-root", isDirectory: true)
        let excluded = root.appendingPathComponent("node_modules", isDirectory: true)
        let trigger = root.appendingPathComponent("trigger", isDirectory: true)
        let outside = tempDir.appendingPathComponent("excluded-churn-outside", isDirectory: true)
        try write(excluded.appendingPathComponent("ignored-local.txt"))
        try write(trigger.appendingPathComponent("safe.txt"))
        try write(outside.appendingPathComponent("ignored-outside.txt"))

        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path))
        let fixture = LockedBox(RaceOutcome())
        crawler.beforeOpeningDirectoryForTesting = { path in
            let shouldSwap = fixture.withValue { outcome in
                guard path == trigger.path, !outcome.fired else { return false }
                outcome.fired = true
                return true
            }
            guard shouldSwap else { return }
            do {
                let fileManager = FileManager()
                try fileManager.removeItem(at: excluded)
                try fileManager.createSymbolicLink(at: excluded, withDestinationURL: outside)
            } catch { fixture.withValue { $0.error = error } }
        }
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)
        let store = builder.build(generation: 1)

        let outcome = fixture.value
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.fired)
        XCTAssertTrue(present("node_modules", in: store))
        XCTAssertTrue(present("safe.txt", in: store))
        XCTAssertFalse(present("ignored-local.txt", in: store))
        XCTAssertFalse(present("ignored-outside.txt", in: store))
        XCTAssertGreaterThanOrEqual(stats.skippedExcluded, 1)
    }

    func testIncludeHiddenSurfacesDotFiles() throws {
        let root = try makeTree()
        var ex = Exclusions.defaults(home: tempHome.path)
        ex.includeHidden = true
        let (store, _) = crawl(root, exclusions: ex)
        XCTAssertTrue(present(".secret", in: store))
        XCTAssertTrue(present(".\u{0301}decorated-secret", in: store))
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

    func testParallelCrawlCountsPreexistingAppsAgainstHardCap() throws {
        let a = try makeBigDir("cap-a", count: 10)
        let b = try makeBigDir("cap-b", count: 10)
        let builder = IndexBuilder()
        let appRoot = builder.addRoot("/Applications")
        for name in ["One", "Two"] {
            builder.addItem(dir: appRoot, name: name, analyzed: TextAnalyzer.analyze(name), kind: .app,
                            flags: [.appBundle], mtime: nil, depth: 1, ext: "app")
        }
        let crawler = Crawler(roots: [.init(path: a.path), .init(path: b.path)],
                              exclusions: .defaults(home: tempHome.path), maxItems: 5)
        let stats = crawler.crawl(into: builder)
        XCTAssertEqual(builder.count, 5)
        XCTAssertTrue(stats.hitItemCap)
    }

    func testParallelBuilderAppendFailureIsReportedAsTruncation() throws {
        let first = tempDir.appendingPathComponent("append-failure-a", isDirectory: true)
        let second = tempDir.appendingPathComponent("append-failure-b", isDirectory: true)
        try write(first.appendingPathComponent("one.txt"))
        try write(second.appendingPathComponent("two.txt"))

        let destination = IndexBuilder()
        for index in 0..<SafetyLimits.maxIndexRoots {
            XCTAssertGreaterThanOrEqual(destination.addRoot("/seed-\(index)"), 0)
        }
        let callbacks = LockedBox(0)
        let crawler = Crawler(roots: [.init(path: first.path), .init(path: second.path)],
                              exclusions: .defaults(home: tempHome.path), maxItems: 100)
        let stats = crawler.crawl(into: destination, onBatch: { _ in
            callbacks.withValue { $0 += 1 }
        })

        XCTAssertTrue(stats.hitItemCap, "an unmergeable root result makes the crawl incomplete")
        XCTAssertEqual(stats.items, 0, "rejected root builders must not be reported as published items")
        XCTAssertEqual(stats.dirs, 0, "rejected root builders must not be reported as published dirs")
        XCTAssertEqual(destination.count, 0)
        XCTAssertEqual(destination.dirCount, SafetyLimits.maxIndexRoots)
        XCTAssertEqual(callbacks.value, 0, "no partial publication callback may claim a rejected append")
    }

    func testExtremeProgrammaticCapsAndReserveHintsAreSafe() throws {
        let root = tempDir.appendingPathComponent("extreme", isDirectory: true)
        try write(root.appendingPathComponent("one.txt"))
        let builder = IndexBuilder()
        builder.reserve(items: Int.min, dirs: Int.max)
        let crawler = Crawler(roots: [.init(path: root.path)],
                              exclusions: .defaults(home: tempHome.path), maxItems: Int.min)
        let stats = crawler.crawl(into: builder)
        XCTAssertEqual(crawler.maxItems, 0)
        XCTAssertEqual(builder.count, 0)
        XCTAssertTrue(stats.hitItemCap)

        let large = Crawler(roots: [.init(path: root.path)],
                            exclusions: .defaults(home: tempHome.path), maxItems: Int.max)
        XCTAssertEqual(large.maxItems, SafetyLimits.maxIndexedItems.upperBound)
        XCTAssertEqual(IndexStoreLimits.directoryLimit(itemCount: Int.max, rootAllowance: Int.max),
                       IndexStoreLimits.maxBuilderDirectories)
        XCTAssertEqual(IndexStoreLimits.directoryArenaLimit(itemCount: Int.max, rootAllowance: Int.max),
                       IndexStoreLimits.maxDirectoryArenaBytes)

        let catalogDirs = IndexStoreLimits.directoryLimit(itemCount: 0, rootAllowance: 0)
        let expectedCatalogArena = min(
            IndexStoreLimits.maxDirectoryArenaBytes,
            max(64 * 1_024, IndexStoreLimits.adding(
                IndexStoreLimits.multiplying(
                    max(0, catalogDirs - SafetyLimits.maxAppCatalogDirectories), 256
                ),
                SafetyLimits.maxAppCatalogDirectoryBytes
            ))
        )
        XCTAssertEqual(IndexStoreLimits.directoryArenaLimit(itemCount: 0, rootAllowance: 0),
                       expectedCatalogArena)
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
        let observations = LockedBox((calls: 0, lastCount: 0))
        let (store, _) = crawl(dir, onBatch: { b in
            observations.withValue { $0 = ($0.calls + 1, b.count) }
        })
        let observed = observations.value
        XCTAssertGreaterThanOrEqual(observed.calls, 1, "onBatch should fire past \(Crawler.batchSize) items")
        XCTAssertGreaterThan(observed.lastCount, 0)
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
        XCTAssertTrue(crawler.pathHasDownrankComponent("/x/root/\u{301}目录/build/a", belowRoot: "/x/root"))
        XCTAssertEqual(Crawler.pathComponentCount("/x/root/\u{301}目录/file"), 4)
        XCTAssertTrue(Crawler.path("/x/Cafe\u{301}/\u{301}目录", isWithin: "/x/Café"))
    }

    // MARK: - IndexUpdater.apply

    func testDirIndexChoosesCanonicalEquivalentMostSpecificRoot() throws {
        let decomposed = String(repeating: "e\u{301}", count: 24)
        let composed = String(repeating: "é", count: 24)
        let ancestorPath = "/x/\(decomposed)"
        let nestedRootPath = "/x/\(composed)/a"

        let builder = IndexBuilder()
        let ancestor = builder.addRoot(ancestorPath)
        XCTAssertGreaterThanOrEqual(ancestor, 0)
        XCTAssertGreaterThanOrEqual(builder.addDir(parent: ancestor, name: "a"), 0)
        let nestedRoot = builder.addRoot(nestedRootPath)
        let target = builder.addDir(parent: nestedRoot, name: "target")
        let index = DirIndex(store: builder.build(generation: 1))

        let resolved = index.resolve("/x/\(decomposed)/a/target")
        XCTAssertEqual(resolved?.0, target,
                       "root specificity is component depth, not normalization-dependent UTF-8 length")
        XCTAssertEqual(resolved?.1, true)
    }

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

    func testIndexUpdaterRawInputBudgetsFailBeforeNormalization() {
        let two = [IndexUpdater.Change(path: "/a", mustScanSubDirs: false),
                   IndexUpdater.Change(path: "/b", mustScanSubDirs: false)]
        XCTAssertTrue(IndexUpdater.rawChangesAreBounded(two, countLimit: 2, pathByteLimit: 4))
        XCTAssertFalse(IndexUpdater.rawChangesAreBounded(two + [.init(path: "/c", mustScanSubDirs: false)],
                                                         countLimit: 2, pathByteLimit: 100))
        XCTAssertFalse(IndexUpdater.rawChangesAreBounded(two, countLimit: 2, pathByteLimit: 3))
        XCTAssertFalse(IndexUpdater.rawChangesAreBounded([
            .init(path: String(repeating: "x", count: SafetyLimits.maxPathUTF8Bytes + 1),
                  mustScanSubDirs: false),
        ]))

        let maximumPath = "/" + String(repeating: "p", count: SafetyLimits.maxPathUTF8Bytes - 1)
        let aggregateStorm = Array(repeating: IndexUpdater.Change(path: maximumPath,
                                                                  mustScanSubDirs: false),
                                   count: 65)
        XCTAssertFalse(IndexUpdater.rawChangesAreBounded(aggregateStorm),
                       "aggregate raw bytes must be bounded even below the count ceiling")
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
        XCTAssertEqual(updated.builtAt, store.builtAt,
                       "no-op updates must not postpone the next full crawl")
        XCTAssertEqual(updated.maskBitsets, store.maskBitsets)
        XCTAssertEqual(updated.maskBitCounts, store.maskBitCounts)
        store.maskBitsets[0].withUnsafeBufferPointer { original in
            updated.maskBitsets[0].withUnsafeBufferPointer { copied in
                XCTAssertEqual(copied.baseAddress, original.baseAddress,
                               "metadata-only updates must share accelerator storage instead of rebuilding it")
            }
        }
        XCTAssertTrue(present("keep.txt", in: updated))
    }

    func testIncrementalMergePreservesFullCrawlTime() throws {
        let root = tempDir.appendingPathComponent("incremental-age", isDirectory: true)
        try write(root.appendingPathComponent("Documents/old.txt"))
        let (crawler, original) = crawlerAndStore(root)
        let fullCrawlTime = Date(timeIntervalSince1970: 1_700_000_000)
        let store = StoreMerge.rebrand(original, generation: 1, fsEventId: 100, builtAt: fullCrawlTime)
        try write(root.appendingPathComponent("Documents/new.txt"))
        let updated = try XCTUnwrap(IndexUpdater.apply(
            changes: [.init(path: root.appendingPathComponent("Documents").path, mustScanSubDirs: false)],
            to: store, crawler: crawler, generation: 2, fsEventId: 200
        ))
        XCTAssertTrue(present("new.txt", in: updated))
        XCTAssertEqual(updated.builtAt, fullCrawlTime,
                       "incremental deltas do not prove the complete index was recrawled")
    }

    func testIncrementalUpdateRejectsCappedDirectoryReplacement() throws {
        let root = tempDir.appendingPathComponent("incremental-capped", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        for item in 0..<4 { try write(docs.appendingPathComponent("file-\(item).txt")) }
        let (initial, store) = crawlerAndStore(root)
        var exclusions = initial.exclusions
        exclusions.maxDirEntries = 2
        let limited = Crawler(roots: initial.roots, exclusions: exclusions)
        XCTAssertNil(IndexUpdater.apply(changes: [.init(path: docs.path, mustScanSubDirs: false)],
                                         to: store, crawler: limited, generation: 2, fsEventId: 200),
                     "a truncated delta must trigger full-crawl diagnostics instead of deleting cached files")
    }

    func testIncrementalUpdateRejectsDeniedDirectoryReplacement() throws {
        let root = tempDir.appendingPathComponent("incremental-denied", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try write(docs.appendingPathComponent("file.txt"))
        let (crawler, store) = crawlerAndStore(root)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: docs.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docs.path) }
        XCTAssertNil(IndexUpdater.apply(changes: [.init(path: docs.path, mustScanSubDirs: false)],
                                         to: store, crawler: crawler, generation: 2, fsEventId: 200),
                     "a denied replacement is incomplete and must not persist as a complete index")
    }

    func testIncrementalUpdateRejectsUnsafeDescendantReplacement() throws {
        let root = tempDir.appendingPathComponent("incremental-unsafe", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let victim = docs.appendingPathComponent("new-child", isDirectory: true)
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try write(docs.appendingPathComponent("known.txt"))
        try write(outside.appendingPathComponent("secret.txt"))
        let (crawler, store) = crawlerAndStore(root)
        try write(victim.appendingPathComponent("new.txt"))
        let fixture = LockedBox(RaceOutcome())
        crawler.beforeOpeningDirectoryForTesting = { path in
            let shouldSwap = fixture.withValue { outcome in
                guard path == victim.path, !outcome.fired else { return false }
                outcome.fired = true
                return true
            }
            guard shouldSwap else { return }
            do {
                let manager = FileManager()
                try manager.removeItem(at: victim)
                try manager.createSymbolicLink(at: victim, withDestinationURL: outside)
            } catch { fixture.withValue { $0.error = error } }
        }
        XCTAssertNil(IndexUpdater.apply(changes: [.init(path: docs.path, mustScanSubDirs: false)],
                                         to: store, crawler: crawler, generation: 2, fsEventId: 200),
                     "unsafe omitted subtree coverage must force a full crawl")
        XCTAssertTrue(fixture.value.fired)
        XCTAssertNil(fixture.value.error)
    }

    func testUnavailableSelectedRootsAreReportedForSerialAndParallelCrawls() throws {
        let missing = tempDir.appendingPathComponent("missing", isDirectory: true)
        let available = tempDir.appendingPathComponent("available", isDirectory: true)
        try write(available.appendingPathComponent("safe.txt"))
        for roots in [[CrawlRoot(path: missing.path)], [CrawlRoot(path: available.path), CrawlRoot(path: missing.path)]] {
            let crawler = Crawler(roots: roots, exclusions: .defaults(home: tempHome.path))
            let stats = crawler.crawl(into: IndexBuilder())
            XCTAssertEqual(stats.unavailableRoots, [missing.path])
            XCTAssertFalse(stats.cancelled)
        }
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

    func testIncrementalReplacementAtExactBudgetSucceedsButTruncationReturnsNil() throws {
        let root = tempDir.appendingPathComponent("incremental-cap", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try write(docs.appendingPathComponent("one.txt"))
        try write(docs.appendingPathComponent("two.txt"))
        let (initialCrawler, store) = crawlerAndStore(root)
        let cappedCrawler = Crawler(roots: initialCrawler.roots, exclusions: initialCrawler.exclusions,
                                    maxItems: store.count)

        let exact = try XCTUnwrap(IndexUpdater.apply(changes: [.init(path: docs.path, mustScanSubDirs: false)],
                                                     to: store, crawler: cappedCrawler,
                                                     generation: 2, fsEventId: 200))
        XCTAssertEqual(exact.count, store.count)

        try write(docs.appendingPathComponent("three.txt"))
        XCTAssertNil(IndexUpdater.apply(changes: [.init(path: docs.path, mustScanSubDirs: false)],
                                        to: exact, crawler: cappedCrawler,
                                        generation: 3, fsEventId: 300),
                     "a partially scanned replacement must be discarded, never silently truncated")
    }

    func testIncrementalChangedDirectoriesShareOneRemainingBudget() throws {
        let root = tempDir.appendingPathComponent("shared-budget", isDirectory: true)
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try write(a.appendingPathComponent("old-a.txt"))
        try write(b.appendingPathComponent("old-b.txt"))
        let (initialCrawler, store) = crawlerAndStore(root)
        let capped = Crawler(roots: initialCrawler.roots, exclusions: initialCrawler.exclusions,
                             maxItems: store.count + 1)
        try write(a.appendingPathComponent("new-a.txt"))
        try write(b.appendingPathComponent("new-b.txt"))

        XCTAssertNil(IndexUpdater.apply(changes: [
            .init(path: a.path, mustScanSubDirs: false),
            .init(path: b.path, mustScanSubDirs: false),
        ], to: store, crawler: capped, generation: 2, fsEventId: 200),
        "each directory must not receive a fresh copy of the same remaining budget")
    }

    func testSequentialIncrementalAdditionsNeverPublishAboveCap() throws {
        let root = tempDir.appendingPathComponent("sequential-cap", isDirectory: true)
        var dirs: [URL] = []
        for i in 0..<6 {
            let dir = root.appendingPathComponent("D\(i)", isDirectory: true)
            try write(dir.appendingPathComponent("old.txt"))
            dirs.append(dir)
        }
        let (initialCrawler, initial) = crawlerAndStore(root)
        let limit = initial.count + 3
        let capped = Crawler(roots: initialCrawler.roots, exclusions: initialCrawler.exclusions, maxItems: limit)
        var current = initial
        var rejected = false
        for (i, dir) in dirs.enumerated() {
            try write(dir.appendingPathComponent("new-\(i).txt"))
            if let next = IndexUpdater.apply(changes: [.init(path: dir.path, mustScanSubDirs: false)],
                                             to: current, crawler: capped,
                                             generation: UInt64(i + 2), fsEventId: UInt64(i + 200)) {
                XCTAssertLessThanOrEqual(next.count, limit)
                current = next
            } else {
                rejected = true
                break
            }
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(current.count, limit)
    }

    func testIndexUpdaterRejectsAlreadyOverCapStoreEvenForEmptyPlan() throws {
        let root = tempDir.appendingPathComponent("over-cap", isDirectory: true)
        try write(root.appendingPathComponent("one.txt"))
        let (crawler, store) = crawlerAndStore(root)
        let tooSmall = Crawler(roots: crawler.roots, exclusions: crawler.exclusions,
                               maxItems: max(0, store.count - 1))
        XCTAssertNil(IndexUpdater.apply(changes: [.init(path: "/outside", mustScanSubDirs: false)],
                                        to: store, crawler: tooSmall, generation: 2, fsEventId: 2))
    }

    func testStoreMergeFailsClosedOnItemOrDirectoryOverflow() {
        let baseBuilder = IndexBuilder()
        let root = baseBuilder.addRoot("/base")
        baseBuilder.addItem(dir: root, name: "one", analyzed: TextAnalyzer.analyze("one"),
                            kind: .other, flags: [], mtime: nil, depth: 1, ext: nil)
        let base = baseBuilder.build(generation: 1)
        let extraBuilder = IndexBuilder()
        let extraRoot = extraBuilder.addRoot("/extra")
        extraBuilder.addItem(dir: extraRoot, name: "two", analyzed: TextAnalyzer.analyze("two"),
                             kind: .other, flags: [], mtime: nil, depth: 1, ext: nil)
        XCTAssertNil(StoreMerge.merge(base: base, keep: [0], extra: extraBuilder.build(generation: 1),
                                      rootMap: [:], generation: 2, fsEventId: 0,
                                      maxItems: 1, rootAllowance: 0))

        let churnedBuilder = IndexBuilder()
        for i in 0..<300 { _ = churnedBuilder.addRoot("/dead/\(i)") }
        let churned = churnedBuilder.build(generation: 1)
        let compacted = StoreMerge.merge(base: churned, keep: [], extra: .empty, rootMap: [:],
                                         generation: 2, fsEventId: 0, maxItems: 0, rootAllowance: 0)
        XCTAssertEqual(compacted?.dirs.count, 0, "unreferenced directory metadata is safely compacted")

        let allowedDirectories = IndexStoreLimits.directoryLimit(itemCount: 1, rootAllowance: 0)
        let liveDirectoryCount = allowedDirectories + 1
        var liveDirs: [DirEntry] = []
        liveDirs.reserveCapacity(liveDirectoryCount)
        for index in 0..<liveDirectoryCount {
            liveDirs.append(DirEntry(parent: index == 0 ? -1 : Int32(index - 1),
                                     nameStart: Int32(index), nameLen: 1))
        }
        var liveDirArena = [UInt8](repeating: 0x64, count: liveDirectoryCount)
        liveDirArena[0] = 0x2F
        let live = IndexStore(
            count: 1, dirId: [Int32(liveDirectoryCount - 1)], nameStart: [0], nameLen: [1],
            displayStart: [0], displayLen: [1], mask: [0], initials: [0], mtime: [0],
            kind: [ItemKind.other.rawValue], flags: [0], depth: [0], extId: [-1],
            foldedArena: [1], bonusArena: [1], displayArena: [0x78],
            dirs: liveDirs, dirArena: liveDirArena, extensions: [], appInfo: [:], appItems: [],
            generation: 1, fsEventId: 0, builtAt: .distantPast
        )
        XCTAssertNil(StoreMerge.merge(base: live, keep: [0], extra: .empty, rootMap: [:],
                                      generation: 2, fsEventId: 0, maxItems: 1, rootAllowance: 0),
                     "live topology above the proportional directory bound must still fail closed")
    }

    func testStoreMergeRejectsCanonicalRootRemapThatOverflowsCompletePath() {
        let decomposed = String(repeating: "e\u{301}", count: 1_364)
        let composed = String(repeating: "é", count: 1_364)

        let baseBuilder = IndexBuilder()
        let baseRoot = baseBuilder.addRoot("/" + decomposed)
        XCTAssertGreaterThanOrEqual(baseBuilder.addItem(
            dir: baseRoot, name: "b", analyzed: TextAnalyzer.analyze("b"),
            kind: .other, flags: [], mtime: nil, depth: 0, ext: nil
        ), 0)
        let base = baseBuilder.build(generation: 1)

        let extraBuilder = IndexBuilder()
        let extraRoot = extraBuilder.addRoot("/" + composed)
        XCTAssertGreaterThanOrEqual(extraRoot, 0)
        XCTAssertGreaterThanOrEqual(extraBuilder.addDir(
            parent: extraRoot,
            name: String(repeating: "x", count: SafetyLimits.maxNameUTF8Bytes)
        ), 0, "the shorter NFC root keeps the standalone extra store valid")
        let extra = extraBuilder.build(generation: 1)

        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: extra, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 1, rootAllowance: 1
        ), "implicit canonical root dedup must recompute the mapped full path")
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: extra, rootMap: [extraRoot: baseRoot], generation: 2,
            fsEventId: 0, maxItems: 1, rootAllowance: 1
        ), "explicit incremental root maps must enforce the same complete-path invariant")
    }

    func testStoreMergeCanonicalRootRemapAcceptsExactItemAndRejectsOneOver() throws {
        let maxBytes = SafetyLimits.maxPathUTF8Bytes
        let stem = "/" + String(repeating: "r", count: maxBytes - 110) + "/caf"
        let shorterNFC = stem + "é"
        let longerNFD = stem + "e\u{301}"
        XCTAssertEqual(shorterNFC, longerNFD,
                       "Swift dictionary keys intentionally use canonical Unicode equality")
        XCTAssertEqual(longerNFD.utf8.count, shorterNFC.utf8.count + 1)

        let baseBuilder = IndexBuilder()
        let baseRoot = baseBuilder.addRoot(longerNFD)
        XCTAssertGreaterThanOrEqual(baseBuilder.addItem(
            dir: baseRoot, name: "anchor", analyzed: TextAnalyzer.analyze("anchor"),
            kind: .other, flags: [], mtime: nil, depth: 0, ext: nil
        ), 0)
        let base = baseBuilder.build(generation: 1)

        func incoming(nameBytes: Int) -> (IndexStore, Int32) {
            let builder = IndexBuilder()
            let root = builder.addRoot(shorterNFC)
            let name = String(repeating: "i", count: nameBytes)
            XCTAssertGreaterThanOrEqual(builder.addItem(
                dir: root, name: name, analyzed: TextAnalyzer.analyze(name),
                kind: .other, flags: [], mtime: nil, depth: 0, ext: nil
            ), 0)
            return (builder.build(generation: 1), root)
        }

        let exactNameBytes = maxBytes - longerNFD.utf8.count - 1
        let (exactExtra, _) = incoming(nameBytes: exactNameBytes)
        var exactWork: StoreMerge.PathValidationWork?
        let exact = try XCTUnwrap(StoreMerge.merge(
            base: base, keep: [0], extra: exactExtra, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 2, rootAllowance: 1,
            pathValidationObserver: { exactWork = $0 }
        ))
        XCTAssertEqual(exact.path(of: 1).utf8.count, maxBytes)
        XCTAssertEqual(exactWork?.remappedExtraItemStringDecodes, 1)

        let (oneOverExtra, oneOverRoot) = incoming(nameBytes: exactNameBytes + 1)
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: oneOverExtra, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 2, rootAllowance: 1
        ))
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: oneOverExtra,
            rootMap: [oneOverRoot: baseRoot], generation: 2,
            fsEventId: 0, maxItems: 2, rootAllowance: 1
        ))

        let appBuilder = IndexBuilder()
        let appRoot = appBuilder.addRoot(shorterNFC)
        let exactSourceAppBytes = maxBytes - shorterNFC.utf8.count - 1 - 4
        let appName = String(repeating: "a", count: exactSourceAppBytes)
        XCTAssertGreaterThanOrEqual(appBuilder.addItem(
            dir: appRoot, name: appName, analyzed: TextAnalyzer.analyze(appName),
            kind: .app, flags: [.appBundle], mtime: nil, depth: 0, ext: nil
        ), 0)
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: appBuilder.build(generation: 1), rootMap: [:],
            generation: 2, fsEventId: 0, maxItems: 2, rootAllowance: 1
        ), "the remapped item budget must include the implicit .app suffix")
    }

    func testStoreMergeTrailingSlashRemapRevalidatesOnlyAffectedExtraSubtree() throws {
        let baseBuilder = IndexBuilder()
        let baseRoot = baseBuilder.addRoot("/base")
        let baseDirectory = baseBuilder.addDir(parent: baseRoot, name: "docs")
        XCTAssertGreaterThanOrEqual(baseBuilder.addItem(
            dir: baseDirectory, name: "anchor", analyzed: TextAnalyzer.analyze("anchor"),
            kind: .other, flags: [], mtime: nil, depth: 1, ext: nil
        ), 0)
        let base = baseBuilder.build(generation: 1)

        let extraBuilder = IndexBuilder()
        let extraRoot = extraBuilder.addRoot("/base/docs/")
        XCTAssertGreaterThanOrEqual(extraBuilder.addItem(
            dir: extraRoot, name: "direct", analyzed: TextAnalyzer.analyze("direct"),
            kind: .other, flags: [], mtime: nil, depth: 0, ext: nil
        ), 0)
        let extraChild = extraBuilder.addDir(parent: extraRoot, name: "sub")
        XCTAssertGreaterThanOrEqual(extraBuilder.addItem(
            dir: extraChild, name: "nested", analyzed: TextAnalyzer.analyze("nested"),
            kind: .other, flags: [], mtime: nil, depth: 1, ext: nil
        ), 0)

        var work: StoreMerge.PathValidationWork?
        let merged = try XCTUnwrap(StoreMerge.merge(
            base: base, keep: [0], extra: extraBuilder.build(generation: 1),
            rootMap: [extraRoot: baseDirectory], generation: 2, fsEventId: 0,
            maxItems: 3, rootAllowance: 1,
            pathValidationObserver: { work = $0 }
        ))
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(work?.remappedExtraItemStringDecodes, 2,
                       "a mapped slash change conservatively covers its extra descendants")
    }

    func testStoreMergeRejectsMaliciousRawPathTopologyAtEntrance() {
        func rawStore(rootBytes: [UInt8] = [0x2F], displayBytes: [UInt8]) -> IndexStore {
            IndexStore(
                count: 1, dirId: [0], nameStart: [0], nameLen: [1],
                displayStart: [0], displayLen: [UInt16(displayBytes.count)],
                mask: [0], initials: [0], mtime: [0], kind: [ItemKind.other.rawValue],
                flags: [0], depth: [0], extId: [-1], foldedArena: [0x78], bonusArena: [0],
                displayArena: displayBytes,
                dirs: [DirEntry(parent: -1, nameStart: 0, nameLen: UInt16(rootBytes.count))],
                dirArena: rootBytes, extensions: [], appInfo: [:], appItems: [],
                generation: 1, fsEventId: 0, builtAt: .distantPast
            )
        }

        let invalidItem = rawStore(displayBytes: [0xFF])
        XCTAssertNil(StoreMerge.merge(
            base: invalidItem, keep: [0], extra: .empty, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 1, rootAllowance: 1
        ))
        XCTAssertNil(StoreMerge.merge(
            base: .empty, keep: [], extra: invalidItem, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 1, rootAllowance: 1
        ))
        for hiddenSeparator in [[0x2F, 0xCC, 0x81], [0x00, 0xCC, 0x81]] as [[UInt8]] {
            XCTAssertNil(StoreMerge.merge(
                base: rawStore(displayBytes: hiddenSeparator), keep: [], extra: .empty,
                rootMap: [:], generation: 2, fsEventId: 0, maxItems: 0, rootAllowance: 1
            ))
        }

        let invalidRoot = rawStore(rootBytes: [0xFF], displayBytes: [0x78])
        XCTAssertNil(StoreMerge.merge(
            base: invalidRoot, keep: [0], extra: .empty, rootMap: [:], generation: 2,
            fsEventId: 0, maxItems: 1, rootAllowance: 1
        ))
    }

    func testStoreMergeLargeUnchangedIncrementalAvoidsItemStringDecodes() throws {
        let itemCount = 20_000
        let baseBuilder = IndexBuilder()
        let baseRoot = baseBuilder.addRoot("/base")
        let baseDirectory = baseBuilder.addDir(parent: baseRoot, name: "docs")
        let analyzed = TextAnalyzer.analyze("item")
        for _ in 0..<itemCount {
            XCTAssertGreaterThanOrEqual(baseBuilder.addItem(
                dir: baseDirectory, name: "item", analyzed: analyzed,
                kind: .other, flags: [], mtime: nil, depth: 1, ext: nil
            ), 0)
        }
        let base = baseBuilder.build(generation: 1)

        let extraBuilder = IndexBuilder()
        let extraRoot = extraBuilder.addRoot("/base/docs")
        let unicodeName = "新😀"
        XCTAssertGreaterThanOrEqual(extraBuilder.addItem(
            dir: extraRoot, name: unicodeName, analyzed: TextAnalyzer.analyze(unicodeName),
            kind: .other, flags: [], mtime: nil, depth: 1, ext: nil
        ), 0)

        var work: StoreMerge.PathValidationWork?
        let merged = try XCTUnwrap(StoreMerge.merge(
            base: base, keep: Array(0..<base.count), extra: extraBuilder.build(generation: 1),
            rootMap: [extraRoot: baseDirectory], generation: 2, fsEventId: 0,
            maxItems: itemCount + 1, rootAllowance: 1,
            pathValidationObserver: { work = $0 }
        ))
        XCTAssertEqual(merged.count, itemCount + 1)
        XCTAssertEqual(work, StoreMerge.PathValidationWork(
            baseItemsByteValidated: itemCount,
            extraItemsByteValidated: 1,
            remappedExtraItemStringDecodes: 0
        ), "an exact unchanged root map must not construct Strings for the large base or extra item")

        let secondExtraBuilder = IndexBuilder()
        let secondExtraRoot = secondExtraBuilder.addRoot("/base/docs")
        XCTAssertGreaterThanOrEqual(secondExtraBuilder.addItem(
            dir: secondExtraRoot, name: "again", analyzed: TextAnalyzer.analyze("again"),
            kind: .other, flags: [], mtime: nil, depth: 1, ext: nil
        ), 0)
        let mergedDirectory = try XCTUnwrap(DirIndex(store: merged).resolve("/base/docs")?.0)
        var secondWork: StoreMerge.PathValidationWork?
        let second = try XCTUnwrap(StoreMerge.merge(
            base: merged, keep: Array(0..<merged.count),
            extra: secondExtraBuilder.build(generation: 1),
            rootMap: [secondExtraRoot: mergedDirectory], generation: 3, fsEventId: 0,
            maxItems: itemCount + 2, rootAllowance: 1,
            pathValidationObserver: { secondWork = $0 }
        ))
        XCTAssertEqual(second.count, itemCount + 2)
        XCTAssertEqual(secondWork, StoreMerge.PathValidationWork(
            baseItemsByteValidated: itemCount + 1,
            extraItemsByteValidated: 1,
            remappedExtraItemStringDecodes: 0
        ), "each safety pass remains allocation-free for unchanged base and extra item paths")
    }

    func testStoreMergePreflightsExactSideTableAndCombinedArenaBudgets() throws {
        let baseBuilder = IndexBuilder()
        let baseRoot = baseBuilder.addRoot("/base")
        let baseInfo = AppInfo(bundleID: "test.base", displayName: "Base", aliases: [])
        XCTAssertGreaterThanOrEqual(baseBuilder.addItem(
            dir: baseRoot, name: "Base", analyzed: TextAnalyzer.analyze("Base"),
            kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: "base", app: baseInfo
        ), 0)
        let base = baseBuilder.build(generation: 1)

        let extraBuilder = IndexBuilder()
        let extraRoot = extraBuilder.addRoot("/extra")
        let extraInfo = AppInfo(bundleID: "test.extra", displayName: "Extra", aliases: [])
        XCTAssertGreaterThanOrEqual(extraBuilder.addItem(
            dir: extraRoot, name: "Extra", analyzed: TextAnalyzer.analyze("Extra"),
            kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: "extra", app: extraInfo
        ), 0)
        let extra = extraBuilder.build(generation: 1)

        let expectedInfo: [Int32: AppInfo] = [0: baseInfo, 1: extraInfo]
        let exactSideBytes = IndexStoreLimits.estimatedSideTableBytes(
            extensions: ["base", "extra"], appInfo: expectedInfo, appItems: [0, 1]
        )
        let exactCombinedArenaBytes = [
            base.foldedArena.count, base.bonusArena.count, base.displayArena.count,
            base.dirArena.count, extra.foldedArena.count, extra.bonusArena.count,
            extra.displayArena.count, extra.dirArena.count,
        ].reduce(0, +)

        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: extra, rootMap: [:], generation: 2, fsEventId: 0,
            maxItems: 2, rootAllowance: 2, sideTableByteLimit: exactSideBytes - 1
        ))
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [0], extra: extra, rootMap: [:], generation: 2, fsEventId: 0,
            maxItems: 2, rootAllowance: 2,
            combinedArenaByteLimit: exactCombinedArenaBytes - 1
        ))

        let merged = try XCTUnwrap(StoreMerge.merge(
            base: base, keep: [0], extra: extra, rootMap: [:], generation: 2, fsEventId: 0,
            maxItems: 2, rootAllowance: 2, sideTableByteLimit: exactSideBytes,
            combinedArenaByteLimit: exactCombinedArenaBytes
        ))
        XCTAssertEqual(merged.extensions, ["base", "extra"])
        XCTAssertEqual(merged.extId, [0, 1])
        XCTAssertEqual(merged.appInfo, expectedInfo)
        XCTAssertEqual(merged.appItems, [0, 1])
    }

    func testStoreMergeExtensionUnionAccepts32768AndRejects32769() throws {
        func emptyStore(extensions: [String]) -> IndexStore {
            IndexStore(count: 0, dirId: [], nameStart: [], nameLen: [],
                       displayStart: [], displayLen: [], mask: [], initials: [],
                       mtime: [], kind: [], flags: [], depth: [], extId: [],
                       foldedArena: [], bonusArena: [], displayArena: [], dirs: [], dirArena: [],
                       extensions: extensions, appInfo: [:], appItems: [], generation: 1,
                       fsEventId: 0, builtAt: .distantPast)
        }

        let values = (0...Int(Int16.max) + 1).map { String(format: "e%05x", $0) }
        let midpoint = values.count / 2
        let base = emptyStore(extensions: Array(values[..<midpoint]))
        let exactExtra = emptyStore(extensions: Array(values[midpoint..<(Int(Int16.max) + 1)]))
        let exact = try XCTUnwrap(StoreMerge.merge(
            base: base, keep: [], extra: exactExtra, rootMap: [:], generation: 2, fsEventId: 0,
            maxItems: 0, rootAllowance: 0
        ))
        XCTAssertEqual(exact.extensions.count, Int(Int16.max) + 1)
        XCTAssertEqual(Set(exact.extensions).count, exact.extensions.count)

        let overExtra = emptyStore(extensions: Array(values[midpoint...]))
        XCTAssertNil(StoreMerge.merge(
            base: base, keep: [], extra: overExtra, rootMap: [:], generation: 2, fsEventId: 0,
            maxItems: 0, rootAllowance: 0
        ))

        for unsafe in ["/\u{0301}", "\0\u{0301}"] {
            XCTAssertNil(StoreMerge.merge(
                base: .empty, keep: [], extra: emptyStore(extensions: [unsafe]), rootMap: [:],
                generation: 2, fsEventId: 0, maxItems: 0, rootAllowance: 0
            ), "POSIX separator/NUL bytes must not hide inside a combined grapheme")
        }
    }

    func testDirectoryChurnCompactsDeadMetadataWithoutFullRebuild() throws {
        let root = tempDir.appendingPathComponent("dir-churn", isDirectory: true)
        let watched = root.appendingPathComponent("watched", isDirectory: true)
        try mkdir(watched)
        let (crawler, initial) = crawlerAndStore(root)
        var current = initial
        for i in 0..<400 {
            let ephemeral = watched.appendingPathComponent("ephemeral-\(i)", isDirectory: true)
            try write(ephemeral.appendingPathComponent("leaf.txt"))
            let added = try XCTUnwrap(IndexUpdater.apply(
                changes: [.init(path: watched.path, mustScanSubDirs: false)],
                to: current, crawler: crawler,
                generation: UInt64(i * 2 + 2), fsEventId: UInt64(i * 2 + 2)
            ))
            current = added
            try fm.removeItem(at: ephemeral)
            let removed = try XCTUnwrap(IndexUpdater.apply(
                changes: [.init(path: watched.path, mustScanSubDirs: false)],
                to: current, crawler: crawler,
                generation: UInt64(i * 2 + 3), fsEventId: UInt64(i * 2 + 3)
            ))
            current = removed
            XCTAssertEqual(current.dirs.count, initial.dirs.count,
                           "the removed subtree's dead dir entry must be compacted each cycle")
        }

        let freshBuilder = IndexBuilder()
        crawler.crawl(into: freshBuilder)
        let fresh = freshBuilder.build(generation: 999)
        XCTAssertEqual(fresh.dirs.count, current.dirs.count)
        XCTAssertTrue(IndexStoreLimits.acceptsDirectoryMetadata(itemCount: fresh.count,
                                                                dirCount: fresh.dirs.count,
                                                                dirArenaBytes: fresh.dirArena.count,
                                                                rootAllowance: crawler.roots.count))
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
        let outcome = Crawler.defaultRootsOutcome(home: home.path, exclusions: .defaults(home: home.path))
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.roots, roots)
    }

    func testDefaultRootDiscoveryFilesAndHiddenNamesDoNotConsumeRootAllowance() throws {
        let home = tempDir.appendingPathComponent("root-discovery-noise", isDirectory: true)
        for file in 0..<(SafetyLimits.maxRootEntries + 40) {
            try write(home.appendingPathComponent("loose-\(file).txt"))
            try write(home.appendingPathComponent(".hidden-\(file)"))
        }
        try mkdir(home.appendingPathComponent("Documents"))
        try mkdir(home.appendingPathComponent("later-visible-root"))
        let outcome = Crawler.defaultRootsOutcome(home: home.path, exclusions: .defaults(home: home.path))
        XCTAssertTrue(outcome.isComplete)
        XCTAssertFalse(outcome.truncated)
        XCTAssertGreaterThan(outcome.inspectedNames, SafetyLimits.maxRootEntries)
        XCTAssertEqual(outcome.roots.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                       ["Documents", "later-visible-root"])
    }

    func testDefaultRootDiscoveryReportsExcessQualifiedDirectories() throws {
        let home = tempDir.appendingPathComponent("root-discovery-overflow", isDirectory: true)
        for directory in 0...SafetyLimits.maxRootEntries {
            try mkdir(home.appendingPathComponent("root-\(directory)"))
        }
        try mkdir(home.appendingPathComponent("Desktop"))
        let outcome = Crawler.defaultRootsOutcome(home: home.path, exclusions: .defaults(home: home.path))
        XCTAssertFalse(outcome.isComplete)
        XCTAssertTrue(outcome.truncated)
        XCTAssertEqual(outcome.roots.count, SafetyLimits.maxRootEntries)
        XCTAssertEqual(URL(fileURLWithPath: outcome.roots[0].path).lastPathComponent, "Desktop",
                       "discovery retains the same root-priority policy when capped")
    }

    func testDefaultRootDiscoveryReportsBoundedPhysicalNameInspection() throws {
        let home = tempDir.appendingPathComponent("root-discovery-list-cap", isDirectory: true)
        for file in 0..<8 { try write(home.appendingPathComponent("file-\(file)")) }
        var exclusions = Exclusions.defaults(home: home.path)
        exclusions.maxDirEntries = 3
        let outcome = Crawler.defaultRootsOutcome(home: home.path, exclusions: exclusions)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertTrue(outcome.truncated)
        XCTAssertEqual(outcome.inspectedNames, 4,
                       "inspect only the configured cap plus one overflow probe")
    }

    func testDefaultRootDiscoveryReportsDeniedAndUnsafeHome() throws {
        let home = tempDir.appendingPathComponent("root-discovery-denied", isDirectory: true)
        try mkdir(home)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: home.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path) }
        let denied = Crawler.defaultRootsOutcome(home: home.path, exclusions: .defaults(home: home.path))
        XCTAssertFalse(denied.isComplete)
        XCTAssertEqual(denied.deniedPaths, [home.path])
        XCTAssertTrue(denied.roots.isEmpty)

        let link = tempDir.appendingPathComponent("root-discovery-link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: tempHome)
        let unsafe = Crawler.defaultRootsOutcome(home: link.path, exclusions: .defaults(home: tempHome.path))
        XCTAssertFalse(unsafe.isComplete)
        XCTAssertEqual(unsafe.skippedUnsafe, 1)
        XCTAssertTrue(unsafe.deniedPaths.isEmpty, "unsafe paths are counted instead of retained")
        XCTAssertTrue(unsafe.roots.isEmpty)
    }

    func testPublicTildeRootIsStoredAbsoluteForIncrementalContainment() {
        let root = CrawlRoot(path: "~/Documents", maxDepth: 3, cloud: true, timeBudget: 0.5)
        let crawler = Crawler(roots: [root], exclusions: .defaults(home: NSHomeDirectory()))
        let expanded = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true).path
        XCTAssertEqual(crawler.roots.first?.path, expanded)
        XCTAssertEqual(crawler.roots.first?.maxDepth, 3)
        XCTAssertEqual(crawler.roots.first?.cloud, true)
        XCTAssertEqual(crawler.roots.first?.timeBudget, 0.5)
        XCTAssertTrue(IndexUpdater.isUnderRoots(expanded + "/\u{301}目录/file", crawler: crawler))
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

    func testLargeDirectoryCapStreamsToBoundWithoutPartialItems() throws {
        let dir = try makeBigDir("large-capped", count: 2_000)
        var ex = Exclusions.defaults(home: tempHome.path)
        ex.maxDirEntries = 64
        let (store, stats) = crawl(dir, exclusions: ex)

        XCTAssertEqual(store.count, 1, "only the configured root item may be published")
        XCTAssertEqual(stats.cappedDirs, [dir.path])
        XCTAssertFalse(present("f0.txt", in: store))
        XCTAssertFalse(present("f1999.txt", in: store))
    }

    func testHiddenHeavyDirectoryCannotBypassTraversalCap() throws {
        let dir = tempDir.appendingPathComponent("hidden-capped", isDirectory: true)
        for i in 0..<100 { try write(dir.appendingPathComponent(".hidden-\(i)")) }
        try write(dir.appendingPathComponent("visible.txt"))
        var ex = Exclusions.defaults(home: tempHome.path)
        ex.maxDirEntries = 32
        ex.includeHidden = false

        let (store, stats) = crawl(dir, exclusions: ex)
        XCTAssertEqual(store.count, 1, "the root item is published, but a capped listing is atomic")
        XCTAssertEqual(stats.cappedDirs, [dir.path])
        XCTAssertFalse(present("visible.txt", in: store))
    }

    func testInspectedNameBudgetIsGlobalAcrossDirectories() throws {
        let root = tempDir.appendingPathComponent("global-inspection", isDirectory: true)
        for directory in ["a", "b"] {
            for index in 0..<4 {
                try write(root.appendingPathComponent("\(directory)/f\(index).txt"))
            }
        }
        var exclusions = Exclusions.defaults(home: tempHome.path)
        exclusions.maxDirEntries = 100
        let crawler = Crawler(roots: [.init(path: root.path)], exclusions: exclusions,
                              inspectedNameLimit: 5,
                              monotonicNow: { DispatchTime.now().uptimeNanoseconds })
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)
        let store = builder.build(generation: 1)

        XCTAssertTrue(stats.hitItemCap, "cross-directory work exhaustion must mark the store incomplete")
        XCTAssertEqual(stats.inspectedNames, 5)
        XCTAssertEqual(store.count, 3, "root plus both folder items; the truncated child listing is atomic")
        XCTAssertFalse((0..<store.count).contains { store.name(of: $0).hasPrefix("f") })
    }

    func testHiddenNamesConsumeGlobalInspectionBudget() throws {
        let root = tempDir.appendingPathComponent("global-hidden", isDirectory: true)
        for index in 0..<12 { try write(root.appendingPathComponent(".hidden-\(index)")) }
        try write(root.appendingPathComponent("visible.txt"))
        var exclusions = Exclusions.defaults(home: tempHome.path)
        exclusions.includeHidden = false
        exclusions.maxDirEntries = 100
        let crawler = Crawler(roots: [.init(path: root.path)], exclusions: exclusions,
                              inspectedNameLimit: 3,
                              monotonicNow: { DispatchTime.now().uptimeNanoseconds })
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)

        XCTAssertTrue(stats.hitItemCap)
        XCTAssertEqual(stats.inspectedNames, 3)
        XCTAssertEqual(builder.count, 1, "a globally truncated listing must not publish a misleading prefix")
    }

    func testInspectedNameBudgetIsSharedAcrossParallelRoots() throws {
        let first = tempDir.appendingPathComponent("budget-root-a", isDirectory: true)
        let second = tempDir.appendingPathComponent("budget-root-b", isDirectory: true)
        for index in 0..<2 {
            try write(first.appendingPathComponent("a\(index).txt"))
            try write(second.appendingPathComponent("b\(index).txt"))
        }
        let crawler = Crawler(roots: [.init(path: first.path), .init(path: second.path)],
                              exclusions: .defaults(home: tempHome.path),
                              inspectedNameLimit: 3,
                              monotonicNow: { DispatchTime.now().uptimeNanoseconds })
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)

        XCTAssertTrue(stats.hitItemCap)
        XCTAssertEqual(stats.inspectedNames, 3, "workers must reserve from one all-root budget")
        XCTAssertEqual(builder.count, 4, "both root items plus one complete two-file listing")
    }

    func testRootTimeBudgetUsesInjectedMonotonicDeadline() throws {
        let root = tempDir.appendingPathComponent("deadline", isDirectory: true)
        try write(root.appendingPathComponent("late.txt"))
        let clock = TestMonotonicClock([100, 100, 1_100_000_000])
        let crawler = Crawler(roots: [.init(path: root.path, timeBudget: 1.0)],
                              exclusions: .defaults(home: tempHome.path),
                              inspectedNameLimit: 100, monotonicNow: { clock.now() })
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder)

        XCTAssertTrue(stats.hitItemCap)
        XCTAssertFalse(stats.cancelled, "deadline exhaustion is truncation, not user cancellation")
        XCTAssertEqual(stats.inspectedNames, 0)
        XCTAssertEqual(builder.count, 1, "the expired directory listing is discarded atomically")
        XCTAssertGreaterThanOrEqual(clock.callCount, 3)
    }

    func testMalformedRootTimeBudgetsFailClosedWithoutNumericTrap() throws {
        let root = tempDir.appendingPathComponent("invalid-deadline", isDirectory: true)
        try write(root.appendingPathComponent("never.txt"))
        for budget in [TimeInterval.nan, .infinity, -1, 0] {
            let crawler = Crawler(roots: [.init(path: root.path, timeBudget: budget)],
                                  exclusions: .defaults(home: tempHome.path),
                                  inspectedNameLimit: 100, monotonicNow: { 100 })
            let builder = IndexBuilder()
            let stats = crawler.crawl(into: builder)
            XCTAssertTrue(stats.hitItemCap, "explicit invalid budget \(budget) must truncate")
            XCTAssertEqual(builder.count, 0)
        }
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

    func testParallelMergeIsRootOrderedAndBatchCallbacksAreSerialized() throws {
        let first = tempDir.appendingPathComponent("ordered-first", isDirectory: true)
        let second = tempDir.appendingPathComponent("ordered-second", isDirectory: true)
        let held = first.appendingPathComponent("hold", isDirectory: true)
        try write(held.appendingPathComponent("zero.txt"))
        try write(second.appendingPathComponent("fast/one.txt"))

        let crawler = Crawler(roots: [.init(path: first.path), .init(path: second.path)],
                              exclusions: .defaults(home: tempHome.path))
        let secondSubmitted = DispatchSemaphore(value: 0)
        let synchronizationSucceeded = LockedBox(true)
        crawler.beforeOpeningDirectoryForTesting = { path in
            guard path == held.path else { return }
            if secondSubmitted.wait(timeout: .now() + 5) != .success {
                synchronizationSucceeded.withValue { $0 = false }
            }
        }
        crawler.afterSubmittingRootForTesting = { path in
            if path == second.path { secondSubmitted.signal() }
        }

        let observations = LockedBox([[String]]())
        let callbackActivity = LockedBox((active: 0, maximum: 0))
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder, onBatch: { partial in
            callbackActivity.withValue {
                $0.active += 1
                $0.maximum = max($0.maximum, $0.active)
            }
            Thread.sleep(forTimeInterval: 0.01) // widen any accidental callback overlap
            let snapshot = partial.build(generation: 0)
            observations.withValue { names in
                names.append((0..<snapshot.count).map { snapshot.name(of: $0) })
            }
            callbackActivity.withValue { $0.active -= 1 }
        })

        XCTAssertTrue(synchronizationSucceeded.value, "second root must submit while the first is held")
        let batches = observations.value
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches[0].contains("zero.txt"))
        XCTAssertFalse(batches[0].contains("one.txt"), "first batch must contain only the first configured root")
        XCTAssertTrue(batches[1].contains("zero.txt"))
        XCTAssertTrue(batches[1].contains("one.txt"))
        XCTAssertEqual(callbackActivity.value.maximum, 1)
        XCTAssertEqual(stats.items, builder.count)
    }

    func testParallelCancellationAcrossManyRootsCompletesWithoutMergeGap() throws {
        var roots: [CrawlRoot] = []
        let entriesPerRoot = Crawler.cancelPollInterval + 50
        for i in 0..<6 {
            roots.append(.init(path: try makeBigDir("cancel-many-\(i)", count: entriesPerRoot).path))
        }
        let crawler = Crawler(roots: roots, exclusions: .defaults(home: tempHome.path))
        let result = LockedBox((stats: Optional<CrawlStats>.none, count: 0))
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let builder = IndexBuilder()
            let stats = crawler.crawl(into: builder, shouldCancel: { true })
            result.withValue { $0 = (stats, builder.count) }
            completed.signal()
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 15), .success,
                       "cancelled roots must still submit placeholders so ordered merging cannot deadlock")
        let outcome = result.value
        let stats = try XCTUnwrap(outcome.stats)
        XCTAssertTrue(stats.cancelled)
        XCTAssertEqual(stats.items, outcome.count)
        XCTAssertLessThan(outcome.count, roots.count * (entriesPerRoot + 1))
    }

    /// Regression: the multi-root (parallel) crawl hands `shouldCancel` and `onBatch` to
    /// `DispatchQueue.async`. Wrapping them in `withoutActuallyEscaping` trapped at runtime
    /// ("closure argument was escaped in withoutActuallyEscaping block", SIGTRAP) because the async
    /// block could still hold the closure when the enclosing scope exited — crashing the very first
    /// crawl on launch. It passed intermittently before it failed every time, so pin it.
    func testParallelCrawlAcceptsEscapingCallbacks() throws {
        let a = tempDir.appendingPathComponent("par-a", isDirectory: true)
        let b = tempDir.appendingPathComponent("par-b", isDirectory: true)
        for i in 0..<40 {
            try write(a.appendingPathComponent("a\(i).txt"))
            try write(b.appendingPathComponent("b\(i).txt"))
        }
        let crawler = Crawler(roots: [CrawlRoot(path: a.path), CrawlRoot(path: b.path)],
                              exclusions: Exclusions.defaults(home: tempHome.path))
        let builder = IndexBuilder()
        let batches = Counter()
        let cancels = Counter()
        let stats = crawler.crawl(into: builder,
                                  onBatch: { _ in batches.bump() },
                                  shouldCancel: { cancels.bump(); return false })
        let store = builder.build(generation: 1)
        XCTAssertEqual(stats.items, store.count)
        XCTAssertGreaterThanOrEqual(store.count, 80, "both roots must be merged")
        XCTAssertFalse(stats.cancelled)
        XCTAssertGreaterThan(batches.value, 0, "onBatch fires once per merged root")
    }

    /// Cancelling from another thread stops the parallel crawl without tripping the escaping check.
    func testParallelCrawlHonoursCancellation() throws {
        let a = tempDir.appendingPathComponent("cancel-a", isDirectory: true)
        let b = tempDir.appendingPathComponent("cancel-b", isDirectory: true)
        let filesPerRoot = Crawler.cancelPollInterval + 200
        for i in 0..<filesPerRoot {
            try write(a.appendingPathComponent("a\(i).txt"))
            try write(b.appendingPathComponent("b\(i).txt"))
        }
        let crawler = Crawler(roots: [CrawlRoot(path: a.path), CrawlRoot(path: b.path)],
                              exclusions: Exclusions.defaults(home: tempHome.path))
        let builder = IndexBuilder()
        let stats = crawler.crawl(into: builder, onBatch: nil, shouldCancel: { true })
        XCTAssertTrue(stats.cancelled)
        XCTAssertLessThan(builder.count, filesPerRoot * 2 + 2,
                          "an always-true cancel must cut the crawl short")
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var calls = 0

    init(_ values: [UInt64]) { self.values = values }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !values.isEmpty else { return UInt64.max }
        return values.removeFirst()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Thread-safe counter for callbacks invoked from the crawl's worker queues.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private struct RaceOutcome {
    var fired = false
    var error: Error?
}

/// Narrow lock-backed state for values captured by `@Sendable` crawler callbacks.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
