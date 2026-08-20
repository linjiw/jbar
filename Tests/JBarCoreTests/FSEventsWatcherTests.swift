import XCTest
import CoreServices
@testable import JBarCore

final class FSEventsWatcherTests: XCTestCase {
    private var tempDir: URL!
    private var tempPath: String { tempDir.path }

    override func setUpWithError() throws {
        // FSEvents reports real paths (/private/var/...). Foundation's resolvingSymlinksInPath strips "/private",
        // so use POSIX realpath(3) to get exactly what FSEvents will report.
        let unresolved = FileManager.default.temporaryDirectory.appendingPathComponent("jbar-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        guard let real = realpath(unresolved.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(real) }
        tempDir = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The stream uses `kFSEventStreamCreateFlagIgnoreSelf`, so changes must come from another process.
    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args)")
    }

    /// Collects batches on a private queue; `expect` fulfils when a batch satisfies `predicate`.
    private final class Collector {
        let queue = DispatchQueue(label: "test.fsevents")
        var batches: [FSEventsBatch] = []
        var predicate: ((FSEventsBatch) -> Bool)?
        var expectation: XCTestExpectation?
        func handle(_ b: FSEventsBatch) {
            batches.append(b)
            if let p = predicate, let e = expectation, p(b) { e.fulfill(); expectation = nil }
        }
        func allChanges() -> [IndexUpdater.Change] { queue.sync { batches.flatMap { $0.changes } } }
    }

    private func makeWatcher(_ c: Collector, paths: [String]? = nil, latency: TimeInterval = 0.2) -> FSEventsWatcher {
        FSEventsWatcher(paths: paths ?? [tempPath], latency: latency, queue: c.queue) { c.handle($0) }
    }

    private func waitFor(_ c: Collector, _ description: String, timeout: TimeInterval = 3, _ predicate: @escaping (FSEventsBatch) -> Bool) {
        let exp = expectation(description: description)
        c.queue.sync {
            if c.batches.contains(where: predicate) { exp.fulfill(); return }
            c.predicate = predicate
            c.expectation = exp
        }
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - Live stream

    func testFileCreationReportsParentDirectory() throws {
        let c = Collector()
        let w = makeWatcher(c)
        XCTAssertTrue(w.start())
        XCTAssertTrue(w.isRunning)
        defer { w.stop() }
        XCTAssertGreaterThan(w.currentEventId(), 0, "sinceNow is turned into a concrete id at start()")
        Thread.sleep(forTimeInterval: 0.2)
        try run("/usr/bin/touch", [tempPath + "/hello.txt"])
        waitFor(c, "batch containing temp dir") { b in b.changes.contains { $0.path == self.tempPath } }
        let changes = c.allChanges()
        XCTAssertTrue(changes.contains { $0.path == tempPath && !$0.mustScanSubDirs })
        XCTAssertGreaterThan(w.currentEventId(), 0)
        XCTAssertGreaterThan(w.latestEventId, 0)
        c.queue.sync {
            XCTAssertFalse(c.batches.contains { $0.needsFullRescan })
            XCTAssertTrue(c.batches.allSatisfy { $0.latestEventId > 0 })
        }
    }

    func testSubdirectoryCreationReportsParentAndDir() throws {
        let c = Collector()
        let w = makeWatcher(c)
        XCTAssertTrue(w.start())
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        let sub = tempPath + "/sub"
        try run("/bin/mkdir", [sub])
        try run("/usr/bin/touch", [sub + "/inner.txt"])
        waitFor(c, "sub dir reported") { b in b.changes.contains { $0.path == sub } }
        let paths = Set(c.allChanges().map { $0.path })
        XCTAssertTrue(paths.contains(tempPath), "parent of the new dir is re-listed")
        XCTAssertTrue(paths.contains(sub), "parent of inner.txt (and the created dir itself) is re-listed")
    }

    func testMovedInDirectoryIsScannedRecursively() throws {
        // Build a tree outside the watched root, then move it in: FSEvents reports only the dir rename,
        // so the watcher must flag it mustScanSubDirs.
        let outside = tempDir.deletingLastPathComponent().appendingPathComponent("jbar-fsevents-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("tree/deep"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("tree/deep/file.txt"))
        defer { try? FileManager.default.removeItem(at: outside) }
        let c = Collector()
        let w = makeWatcher(c)
        XCTAssertTrue(w.start())
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        let dest = tempPath + "/tree"
        try run("/bin/mv", [outside.appendingPathComponent("tree").path, dest])
        waitFor(c, "moved dir reported recursively") { b in b.changes.contains { $0.path == dest && $0.mustScanSubDirs } }
        XCTAssertTrue(c.allChanges().contains { $0.path == tempPath })
    }

    func testTouchingRootReportsRootNotItsParent() throws {
        let c = Collector()
        let w = makeWatcher(c)
        XCTAssertTrue(w.start())
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        try run("/usr/bin/touch", [tempPath])
        waitFor(c, "root reported") { b in b.changes.contains { $0.path == self.tempPath } }
        let parent = (tempPath as NSString).deletingLastPathComponent
        XCTAssertFalse(c.allChanges().contains { $0.path == parent }, "never report a directory outside the watched roots")
    }

    func testRestartReplaysGap() throws {
        let c = Collector()
        let w = makeWatcher(c)
        XCTAssertTrue(w.start())
        Thread.sleep(forTimeInterval: 0.2)
        w.stop()
        let idAtStop = w.currentEventId()
        XCTAssertGreaterThan(idAtStop, 0)
        try run("/usr/bin/touch", [tempPath + "/while-stopped.txt"])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(c.allChanges().isEmpty)
        XCTAssertTrue(w.start(), "restart resumes from the last seen id")
        defer { w.stop() }
        waitFor(c, "gap replayed") { b in b.changes.contains { $0.path == self.tempPath } }
        XCTAssertGreaterThan(w.currentEventId(), idAtStop)
    }

    func testStopTwiceAndRestart() throws {
        let c = Collector()
        let w = makeWatcher(c)
        w.stop() // before start
        XCTAssertTrue(w.start())
        XCTAssertTrue(w.start(), "second start is a no-op returning true")
        w.stop()
        w.stop()
        XCTAssertFalse(w.isRunning)
        // No events after stop.
        try run("/usr/bin/touch", [tempPath + "/after-stop.txt"])
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(c.allChanges().isEmpty)
        // Restart works and event ids survive.
        let before = w.currentEventId()
        XCTAssertGreaterThan(before, 0)
        XCTAssertTrue(w.start())
        Thread.sleep(forTimeInterval: 0.2)
        try run("/usr/bin/touch", [tempPath + "/after-restart.txt"])
        waitFor(c, "after restart") { b in b.changes.contains { $0.path == self.tempPath } }
        XCTAssertGreaterThanOrEqual(w.currentEventId(), before)
        w.stop()
    }

    func testStopFromInsideHandlerDoesNotDeadlock() throws {
        // The handler runs on `queue`; stopping the watcher from there must complete.
        let c = Collector()
        var w: FSEventsWatcher!
        let stopped = expectation(description: "stopped from handler")
        w = FSEventsWatcher(paths: [tempPath], latency: 0.2, queue: c.queue) { b in
            c.handle(b)
            if w.isRunning { w.stop(); stopped.fulfill() }
        }
        XCTAssertTrue(w.start())
        Thread.sleep(forTimeInterval: 0.2)
        try run("/usr/bin/touch", [tempPath + "/x.txt"])
        wait(for: [stopped], timeout: 3)
        XCTAssertFalse(w.isRunning)
        XCTAssertFalse(c.allChanges().isEmpty)
    }

    func testStartWithoutPathsFails() {
        let c = Collector()
        let w = makeWatcher(c, paths: [])
        XCTAssertFalse(w.start())
        XCTAssertFalse(w.isRunning)
        w.stop()
    }

    func testDeallocWhileRunningDoesNotCrash() throws {
        let c = Collector()
        var w: FSEventsWatcher? = makeWatcher(c)
        XCTAssertTrue(w?.start() ?? false)
        w = nil
        try run("/usr/bin/touch", [tempPath + "/after-dealloc.txt"])
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(c.allChanges().isEmpty)
    }

    func testSinceWhenReplaysHistory() throws {
        // Record an id, make a change with no stream running, then start a stream from that id: the change is replayed.
        let since = FSEventsGetCurrentEventId()
        XCTAssertGreaterThan(since, 0)
        try run("/usr/bin/touch", [tempPath + "/offline.txt"])
        Thread.sleep(forTimeInterval: 0.3)
        let c = Collector()
        let w = FSEventsWatcher(paths: [tempPath], sinceWhen: since, latency: 0.2, queue: c.queue) { c.handle($0) }
        XCTAssertEqual(w.latestEventId, since)
        XCTAssertTrue(w.start())
        defer { w.stop() }
        waitFor(c, "replayed") { b in b.changes.contains { $0.path == self.tempPath } }
        XCTAssertGreaterThan(w.currentEventId(), since)
    }

    // MARK: - Pure event mapping

    private func map(_ events: [(String, Int)], exists: @escaping (String) -> Bool = { _ in true }) -> (changes: [IndexUpdater.Change], full: Bool) {
        let r = FSEventsWatcher.mapEvents(paths: events.map { $0.0 }, flags: events.map { FSEventStreamEventFlags($0.1) }, exists: exists)
        return (r.changes, r.needsFullRescan)
    }

    func testMapFileEventsReportParentDeduped() {
        let r = map([("/a/b/one.txt", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
                     ("/a/b/two.txt", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
                     ("/a/c/three.txt", kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)])
        XCTAssertEqual(r.changes, [IndexUpdater.Change(path: "/a/b", mustScanSubDirs: false),
                                   IndexUpdater.Change(path: "/a/c", mustScanSubDirs: false)])
        XCTAssertFalse(r.full)
    }

    func testMapMustScanSubDirs() {
        let r = map([("/a/b/", kFSEventStreamEventFlagMustScanSubDirs),
                     ("/a/b/x.txt", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)])
        // "/a/b" appears once, recursive wins over the later non-recursive parent report.
        XCTAssertEqual(r.changes, [IndexUpdater.Change(path: "/a/b", mustScanSubDirs: true)])
        XCTAssertFalse(r.full)
    }

    func testMapRecursiveWinsRegardlessOfOrder() {
        let r = map([("/a/b/x.txt", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
                     ("/a/b", kFSEventStreamEventFlagMustScanSubDirs)])
        XCTAssertEqual(r.changes, [IndexUpdater.Change(path: "/a/b", mustScanSubDirs: true)])
    }

    func testMapDirectoryCreatedRemovedRenamed() {
        let created = map([("/a/newdir", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)])
        XCTAssertEqual(created.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false),
                                         IndexUpdater.Change(path: "/a/newdir", mustScanSubDirs: false)])
        let removed = map([("/a/gone", kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)], exists: { _ in false })
        XCTAssertEqual(removed.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false)])
        let renamedAway = map([("/a/old", kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)], exists: { _ in false })
        XCTAssertEqual(renamedAway.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false)])
        let renamedIn = map([("/a/new", kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)], exists: { $0 == "/a/new" })
        XCTAssertEqual(renamedIn.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false),
                                           IndexUpdater.Change(path: "/a/new", mustScanSubDirs: true)])
        // A modified directory (metadata) only re-lists its parent.
        let modified = map([("/a/dir", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir)])
        XCTAssertEqual(modified.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false)])
    }

    func testMapFullRescanFlags() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(map([("/a", flag)]).full, "flag \(flag)")
        }
        XCTAssertFalse(map([("/a/x", kFSEventStreamEventFlagItemCreated)]).full)
        // HistoryDone is ignored (no change, no rescan).
        let h = map([("/a", kFSEventStreamEventFlagHistoryDone)])
        XCTAssertTrue(h.changes.isEmpty)
        XCTAssertFalse(h.full)
        // Mixed: still maps the regular events.
        let mixed = map([("/a", kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs),
                         ("/a/b/f.txt", kFSEventStreamEventFlagItemCreated)])
        XCTAssertTrue(mixed.full)
        XCTAssertEqual(mixed.changes.first, IndexUpdater.Change(path: "/a", mustScanSubDirs: true))
    }

    func testMapEdgePaths() {
        XCTAssertEqual(map([("/top.txt", kFSEventStreamEventFlagItemCreated)]).changes, [IndexUpdater.Change(path: "/", mustScanSubDirs: false)])
        XCTAssertTrue(map([("", kFSEventStreamEventFlagItemCreated)]).changes.isEmpty)
        XCTAssertEqual(map([("/a/b///", kFSEventStreamEventFlagItemCreated)]).changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false)])
        // Fewer flags than paths → missing flags treated as 0.
        let r = FSEventsWatcher.mapEvents(paths: ["/a/x", "/a/y"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)], exists: { _ in true })
        XCTAssertEqual(r.changes, [IndexUpdater.Change(path: "/a", mustScanSubDirs: false)])
    }

    func testMapRootEventsStayInsideRoots() {
        let roots = ["/Users/me/", "/Volumes/Data"]
        let r = FSEventsWatcher.mapEvents(paths: ["/Users/me", "/Volumes/Data/", "/Users/me/Desktop/a.txt"],
                                          flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemInodeMetaMod),
                                                  FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified),
                                                  FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)],
                                          roots: roots, exists: { _ in true })
        XCTAssertEqual(r.changes, [IndexUpdater.Change(path: "/Users/me", mustScanSubDirs: false),
                                   IndexUpdater.Change(path: "/Volumes/Data", mustScanSubDirs: false),
                                   IndexUpdater.Change(path: "/Users/me/Desktop", mustScanSubDirs: false)])
        XCTAssertFalse(r.needsFullRescan)
    }

    func testDirnameAndStrip() {
        XCTAssertEqual(FSEventsWatcher.dirname("/a/b/c"), "/a/b")
        XCTAssertEqual(FSEventsWatcher.dirname("/a"), "/")
        XCTAssertEqual(FSEventsWatcher.dirname("/"), "/")
        XCTAssertEqual(FSEventsWatcher.dirname("rel"), ".")
        XCTAssertEqual(FSEventsWatcher.stripTrailingSlash("/a/"), "/a")
        XCTAssertEqual(FSEventsWatcher.stripTrailingSlash("/"), "/")
        XCTAssertEqual(FSEventsWatcher.stripTrailingSlash("///"), "/")
    }

    func testCreateFlags() {
        let f = Int(FSEventsWatcher.createFlags)
        for expected in [kFSEventStreamCreateFlagFileEvents, kFSEventStreamCreateFlagUseCFTypes, kFSEventStreamCreateFlagNoDefer,
                         kFSEventStreamCreateFlagIgnoreSelf, kFSEventStreamCreateFlagWatchRoot] {
            XCTAssertNotEqual(f & expected, 0)
        }
    }
}
