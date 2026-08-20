import XCTest
@testable import JBarCore

/// Tests for `IndexCoordinator` (DESIGN.md §2.3/§4): the start → app-scan → crawl → snapshot pipeline,
/// snapshot reuse by a second coordinator, `rebuild()`, `rescanApps()`, `update(options:)` and `stop()`.
///
/// The coordinator does all work on a private serial queue and delivers callbacks on `.main`.
/// `flushSnapshot()` runs a `queue.sync`, so calling it right after an async operation blocks until that
/// operation's queue work has finished — which makes the otherwise-async pipeline deterministic. The
/// `XCTestExpectation`s then only need the main run loop to be pumped (via `wait`) to receive callbacks.
final class IndexCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var tempHome: URL!
    private var appsDir: URL!
    private var snapshotURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // Canonicalise (/var → /private/var) so crawler roots match the paths FSEvents reports; otherwise
        // a watched change would be filtered out as "not under roots".
        let raw = fm.temporaryDirectory.appendingPathComponent("jbar-coord-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        let canon = (try raw.resourceValues(forKeys: [.canonicalPathKey])).canonicalPath ?? raw.path
        tempDir = URL(fileURLWithPath: canon, isDirectory: true)
        tempHome = tempDir.appendingPathComponent("home", isDirectory: true)
        appsDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        snapshotURL = tempDir.appendingPathComponent("snap/index-v1.bin")
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tempDir { try? fm.removeItem(at: d) }
    }

    // MARK: - Fixture helpers

    private func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }

    /// Create/touch a file via a SEPARATE process so FSEvents (IgnoreSelf) reports it.
    private func touch(_ path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        p.arguments = [path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "touch \(path)")
    }

    @discardableResult
    private func makeFiles(in dir: URL, count: Int, prefix: String = "file") throws -> URL {
        try mkdir(dir)
        for i in 0..<count { fm.createFile(atPath: dir.appendingPathComponent("\(prefix)\(i).txt").path, contents: Data()) }
        return dir
    }

    private func makeApp(_ name: String) throws {
        let contents = appsDir.appendingPathComponent("\(name).app/Contents")
        try mkdir(contents)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeOptions(fileRoots: [String] = ["~"]) -> IndexCoordinator.Options {
        var opts = IndexCoordinator.Options(exclusions: .defaults(home: tempHome.path))
        opts.home = tempHome.path
        opts.appRoots = [appsDir.path]
        opts.fileRoots = fileRoots
        opts.watchFileSystem = false
        opts.snapshotURL = snapshotURL
        return opts
    }

    /// Start `coord` and block until its start-queue work (app scan + crawl + snapshot write) is done,
    /// then pump the run loop until an onStoreChanged callback reports `count >= minCount`.
    private func startAndWait(_ coord: IndexCoordinator, minCount: Int, timeout: TimeInterval = 20) {
        let published = expectation(description: "store published (>= \(minCount))")
        published.assertForOverFulfill = false
        coord.onStoreChanged = { store in if store.count >= minCount { published.fulfill() } }
        coord.start()
        coord.flushSnapshot()
        wait(for: [published], timeout: timeout)
    }

    // MARK: - Full lifecycle

    func testStartCrawlPublishSnapshotThenReload() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 4)
        try makeApp("Solo")
        let opts = makeOptions()

        // 1. start(): apps + files published, phase idle, snapshot written.
        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 5)
        XCTAssertGreaterThanOrEqual(coord.store.count, 5)
        XCTAssertGreaterThanOrEqual(coord.status.itemCount, 5)
        XCTAssertGreaterThanOrEqual(coord.status.appCount, 1)
        XCTAssertEqual(coord.status.phase, .idle)
        XCTAssertTrue(fm.fileExists(atPath: snapshotURL.path), "snapshot must be written after the crawl")
        let firstCount = coord.store.count
        XCTAssertTrue(coord.store.appItems.contains { coord.store.name(of: Int($0)) == "Solo" })

        // 2. A second coordinator loads the snapshot and reproduces the count (no crawl needed).
        let coord2 = IndexCoordinator(options: opts)
        let loaded = expectation(description: "coord2 loaded snapshot")
        loaded.assertForOverFulfill = false
        coord2.onStoreChanged = { store in if store.count >= firstCount { loaded.fulfill() } }
        coord2.start()
        coord2.flushSnapshot()
        wait(for: [loaded], timeout: 20)
        XCTAssertEqual(coord2.store.count, firstCount, "snapshot reload should reproduce the item count")
        XCTAssertEqual(coord2.status.phase, .idle)
        coord2.stop()

        // 3. rebuild() re-fires onStoreChanged and keeps the item count.
        let rebuilt = expectation(description: "rebuilt")
        rebuilt.assertForOverFulfill = false
        coord.onStoreChanged = { store in if store.count >= firstCount { rebuilt.fulfill() } }
        coord.rebuild()
        coord.flushSnapshot()
        wait(for: [rebuilt], timeout: 20)
        XCTAssertGreaterThanOrEqual(coord.store.count, firstCount)

        // 4. stop() writes the snapshot and does not crash.
        coord.stop()
        XCTAssertTrue(fm.fileExists(atPath: snapshotURL.path))
    }

    // MARK: - rescanApps

    func testRescanAppsPicksUpNewApp() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 3)
        try makeApp("First")
        let coord = IndexCoordinator(options: makeOptions())
        startAndWait(coord, minCount: 4)
        let beforeApps = coord.store.appItems.count

        try makeApp("Second")
        let grew = expectation(description: "app count grew")
        grew.assertForOverFulfill = false
        coord.onStoreChanged = { store in if store.appItems.count > beforeApps { grew.fulfill() } }
        coord.rescanApps()
        coord.flushSnapshot()
        wait(for: [grew], timeout: 20)
        XCTAssertEqual(coord.store.appItems.count, beforeApps + 1)
        XCTAssertTrue(coord.store.appItems.contains { coord.store.name(of: Int($0)) == "Second" })
        coord.stop()
    }

    // MARK: - update(options:)

    func testUpdateWithChangedRootsRebuilds() throws {
        try makeFiles(in: tempHome.appendingPathComponent("A"), count: 2, prefix: "a")
        try makeFiles(in: tempHome.appendingPathComponent("B"), count: 3, prefix: "b")
        try makeApp("Solo")

        // Start with only "~/A" as a file root.
        let coord = IndexCoordinator(options: makeOptions(fileRoots: ["~/A"]))
        startAndWait(coord, minCount: 3)
        let countA = coord.store.count
        XCTAssertFalse(coord.store.appItems.isEmpty)

        // Add "~/B" → a different index → recrawl with more items.
        let bigger = expectation(description: "recrawled with more items")
        bigger.assertForOverFulfill = false
        coord.onStoreChanged = { store in if store.count > countA { bigger.fulfill() } }
        coord.update(options: makeOptions(fileRoots: ["~/A", "~/B"]))
        coord.flushSnapshot()
        wait(for: [bigger], timeout: 20)
        XCTAssertGreaterThan(coord.store.count, countA)
        XCTAssertEqual(coord.status.phase, .idle)
        coord.stop()
    }

    // MARK: - Pure helpers

    func testIndexInputsDiffer() {
        let base = makeOptions()
        XCTAssertFalse(IndexCoordinator.indexInputsDiffer(base, base))
        func mutated(_ f: (inout IndexCoordinator.Options) -> Void) -> IndexCoordinator.Options {
            var o = base; f(&o); return o
        }
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.home = "/other" }))
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.appRoots = ["/x"] }))
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.fileRoots = ["~/x"] }))
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.maxItems = 42 }))
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.snapshotURL = URL(fileURLWithPath: "/tmp/other.bin") }))
        XCTAssertTrue(IndexCoordinator.indexInputsDiffer(base, mutated { $0.exclusions.includeHidden.toggle() }))
        // watchFileSystem is NOT an index input.
        XCTAssertFalse(IndexCoordinator.indexInputsDiffer(base, mutated { $0.watchFileSystem.toggle() }))
    }

    func testIsUnder() {
        XCTAssertTrue(IndexCoordinator.isUnder("/a/b", root: "/a"))
        XCTAssertTrue(IndexCoordinator.isUnder("/a", root: "/a"))
        XCTAssertTrue(IndexCoordinator.isUnder("/a/b/c", root: "/a/"))
        XCTAssertFalse(IndexCoordinator.isUnder("/ab", root: "/a"))
        XCTAssertFalse(IndexCoordinator.isUnder("/x", root: "/a"))
    }

    func testStopBeforeStartDoesNotCrash() {
        let coord = IndexCoordinator(options: makeOptions())
        coord.stop() // no start(): must be a safe no-op
        XCTAssertEqual(coord.store.count, 0)
    }

    // MARK: - FSEvents watcher integration

    func testWatcherAppliesIncrementalUpdate() throws {
        let docs = tempHome.appendingPathComponent("Documents")
        try makeFiles(in: docs, count: 3)
        try makeApp("Solo")
        var opts = makeOptions()
        opts.watchFileSystem = true
        opts.fsLatency = 0.2

        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 4)
        XCTAssertTrue(coord.status.watcherRunning, "the FSEvents watcher should be running")

        // Creating a file under a watched root drives an incremental update through handle() → apply().
        // The file must be created by a *separate* process: FSEvents' IgnoreSelf flag suppresses changes
        // made by this process itself.
        let picked = expectation(description: "watcher picked up the new file")
        picked.assertForOverFulfill = false
        coord.onStoreChanged = { store in
            if (0..<store.count).contains(where: { store.name(of: $0) == "watched.txt" }) { picked.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.3) // let the stream settle before the change
        try touch(docs.appendingPathComponent("watched.txt").path)
        wait(for: [picked], timeout: 20)
        XCTAssertEqual(coord.status.phase, .idle)
        coord.stop()
    }

    // MARK: - Snapshot write failure surfaces as a failed status

    func testSnapshotWriteFailureSetsFailedPhase() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 3)
        // Point the snapshot at a location that cannot be created: a path *under a regular file*.
        let blocker = tempDir.appendingPathComponent("blocker")
        fm.createFile(atPath: blocker.path, contents: Data())
        var opts = makeOptions()
        opts.snapshotURL = blocker.appendingPathComponent("sub/index.bin")

        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 4)
        if case .failed = coord.status.phase {
            // expected
        } else {
            XCTFail("expected a .failed phase after the snapshot write failed, got \(coord.status.phase)")
        }
        XCTAssertFalse(fm.fileExists(atPath: opts.snapshotURL.path))
        coord.stop()
    }
}
