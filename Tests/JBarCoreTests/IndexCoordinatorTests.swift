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
    /// Minimal Sendable callback probe; every access to `values` is lock-protected.
    private final class LockedValues<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var snapshot: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// Deterministic Sendable sequence for injected callbacks; after exhaustion it repeats the last value.
    private final class LockedSequence<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [Value]
        private var index = 0

        init(_ values: [Value]) {
            precondition(!values.isEmpty)
            self.values = values
        }

        func next() -> Value {
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }

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
        try fm.removeItem(at: snapshotURL)
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

    func testUnsafeSkipCountPropagatesAndResetsOnNextFullCrawl() throws {
        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try makeFiles(in: outside, count: 1, prefix: "secret")
        let linkedRoot = tempDir.appendingPathComponent("linked-root", isDirectory: true)
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        var opts = makeOptions(fileRoots: [linkedRoot.path])
        opts.appRoots = []
        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 0)
        XCTAssertGreaterThanOrEqual(coord.status.unsafeEntriesSkipped, 1)
        XCTAssertTrue(coord.status.deniedPaths.isEmpty,
                      "unsafe identity/boundary failures expose only a count, never their path")

        try fm.removeItem(at: linkedRoot)
        try makeFiles(in: linkedRoot, count: 1, prefix: "safe")
        coord.rebuild()
        coord.flushSnapshot()
        XCTAssertEqual(coord.status.phase, .idle)
        XCTAssertEqual(coord.status.unsafeEntriesSkipped, 0,
                       "each full crawl starts a fresh unsafe-entry diagnostic window")
        coord.stop()
    }

    func testAppScanTruncationStaysVisibleUntilACompleteFullCrawl() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 2)
        let outcomes = LockedSequence([
            AppScanOutcome(apps: [], truncated: true),
            AppScanOutcome(apps: [], truncated: false),
            AppScanOutcome(apps: [], truncated: false),
        ])
        let coord = IndexCoordinator(
            options: makeOptions(fileRoots: ["~/Documents"]),
            snapshotRemover: { try IndexCoordinator.removeSnapshotIfPresent($0) },
            appScanner: { _, _, _ in outcomes.next() }
        )

        startAndWait(coord, minCount: 2)
        XCTAssertTrue(coord.status.hitItemCap,
                      "a candidate-ceiling truncation must remain visible after the initial full crawl")

        coord.rescanApps()
        coord.flushSnapshot()
        XCTAssertTrue(coord.status.hitItemCap,
                      "an app-only rescan cannot prove that an earlier incomplete overall index is complete")

        coord.rebuild()
        coord.flushSnapshot()
        XCTAssertFalse(coord.status.hitItemCap,
                       "a later untruncated app scan plus successful full crawl proves completeness")
        coord.stop()
    }

    func testRebuildFailsClosedWhenSnapshotCannotBeRemoved() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 3)
        let failureDomain = "JBarTests.SnapshotRemoval"
        let coord = IndexCoordinator(options: makeOptions(), snapshotRemover: { _ in
            throw NSError(domain: failureDomain, code: 73)
        })
        startAndWait(coord, minCount: 3)
        let generationBefore = coord.store.generation

        coord.rebuild()
        coord.flushSnapshot()

        XCTAssertEqual(coord.store.generation, generationBefore,
                       "a rebuild must not publish after its old snapshot could not be removed")
        XCTAssertEqual(coord.status.phase, .failed("snapshot removal failed (\(failureDomain):73)"))
        if case .failed(let message) = coord.status.phase {
            XCTAssertFalse(message.contains(tempDir.path), "failure diagnostics must not expose the snapshot path")
        }
        coord.stop()
    }

    func testOptionsUpdateDoesNotSwitchOrRebuildWhenOldSnapshotCannotBeRemoved() throws {
        try makeFiles(in: tempHome.appendingPathComponent("A"), count: 2, prefix: "a")
        try makeFiles(in: tempHome.appendingPathComponent("B"), count: 4, prefix: "b")
        let failureDomain = "JBarTests.SnapshotRemoval"
        let initial = makeOptions(fileRoots: ["~/A"])
        let coord = IndexCoordinator(options: initial, snapshotRemover: { _ in
            throw NSError(domain: failureDomain, code: 91)
        })
        startAndWait(coord, minCount: 2)
        let generationBefore = coord.store.generation
        let pathsBefore = (0..<coord.store.count).map { coord.store.path(of: $0) }

        var replacement = initial
        replacement.fileRoots = ["~/B"]
        coord.update(options: replacement)
        coord.flushSnapshot()

        XCTAssertEqual(coord.store.generation, generationBefore)
        XCTAssertEqual((0..<coord.store.count).map { coord.store.path(of: $0) }, pathsBefore)
        XCTAssertEqual(coord.status.phase, .failed("snapshot removal failed (\(failureDomain):91)"))
        coord.stop()
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

    func testRepeatedAppRescanDoesNotAccumulateCatalogItems() throws {
        try makeApp("Only")
        let coord = IndexCoordinator(options: makeOptions(fileRoots: []))
        startAndWait(coord, minCount: 1)
        let initialDirectoryCount = coord.store.dirs.count

        for _ in 0..<4 {
            coord.rescanApps()
            coord.flushSnapshot()
            let names = coord.store.appItems.map { coord.store.name(of: Int($0)) }
            XCTAssertEqual(names.filter { $0 == "Only" }.count, 1,
                           "each rescan must replace, not retain, scanner-owned catalog items")
            XCTAssertEqual(coord.store.dirs.count, initialDirectoryCount,
                           "dead catalog directory chains must not accumulate across rescans")
        }
        coord.stop()
    }

    func testAppRescanPreservesGenericCrawlerAppBundle() throws {
        try makeApp("Catalog")
        let fileRoot = tempHome.appendingPathComponent("Documents", isDirectory: true)
        try mkdir(fileRoot.appendingPathComponent("Tool.app/Contents"))
        try Data("<plist/>".utf8).write(to: fileRoot.appendingPathComponent("Tool.app/Contents/Info.plist"))
        let coord = IndexCoordinator(options: makeOptions(fileRoots: [fileRoot.path]))
        startAndWait(coord, minCount: 2)
        let initialDirectoryCount = coord.store.dirs.count

        func appNames() -> [String] {
            coord.store.appItems.map { coord.store.name(of: Int($0)) }
        }
        XCTAssertEqual(appNames().filter { $0 == "Catalog" }.count, 1)
        XCTAssertEqual(appNames().filter { $0 == "Tool" }.count, 1)
        let tool = try XCTUnwrap((0..<coord.store.count).first { coord.store.name(of: $0) == "Tool" })
        XCTAssertFalse(coord.store.itemFlags(tool).contains(.appCatalog),
                       "generic crawler apps must not claim scanner provenance")

        coord.rescanApps()
        coord.flushSnapshot()
        XCTAssertEqual(appNames().filter { $0 == "Catalog" }.count, 1)
        XCTAssertEqual(appNames().filter { $0 == "Tool" }.count, 1,
                       "catalog replacement must not delete generic crawler app bundles")
        XCTAssertEqual(coord.store.dirs.count, initialDirectoryCount,
                       "shared generic/catalog paths must keep directory metadata bounded")
        coord.stop()
    }

    func testAppsOnlyAndFullCrawlNeverPublishAboveHardCap() throws {
        for i in 0..<6 { try makeApp("App\(i)") }
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 12)

        for fileRoots in [[], ["~/Documents"]] {
            var opts = makeOptions(fileRoots: fileRoots)
            opts.maxItems = 3
            let coord = IndexCoordinator(options: opts)
            let completed = expectation(description: "capped crawl \(fileRoots)")
            completed.assertForOverFulfill = false
            let publishedCounts = LockedValues<Int>()
            coord.onStoreChanged = { store in
                publishedCounts.append(store.count)
                if coord.status.phase == .idle || store.count == 3 { completed.fulfill() }
            }
            coord.start()
            coord.flushSnapshot()
            wait(for: [completed], timeout: 20)
            let counts = publishedCounts.snapshot
            XCTAssertFalse(counts.isEmpty)
            XCTAssertTrue(counts.allSatisfy { $0 <= 3 }, "published counts: \(counts)")
            XCTAssertLessThanOrEqual(coord.store.count, 3)
            XCTAssertTrue(coord.status.hitItemCap)
            XCTAssertLessThanOrEqual(coord.status.appCount, 3)
            coord.stop()
        }
    }

    func testTruncatedFullCrawlIsNotPersistedAsCompleteSnapshot() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 12)
        var opts = makeOptions(fileRoots: ["~/Documents"])
        opts.maxItems = 3
        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 3)
        coord.flushSnapshot()

        XCTAssertTrue(coord.status.hitItemCap)
        XCTAssertFalse(fm.fileExists(atPath: snapshotURL.path),
                       "a capped generation is useful for UI but must not become a complete snapshot")
        coord.stop()
    }

    func testCappedDirectoryGenerationIsNotPersistedAsCompleteSnapshot() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 6)
        var opts = makeOptions(fileRoots: ["~/Documents"])
        opts.exclusions.maxDirEntries = 2
        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 1)
        coord.flushSnapshot()

        XCTAssertFalse(coord.status.cappedDirs.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: snapshotURL.path),
                       "a directory-capped generation must not masquerade as a complete snapshot")
        coord.stop()
    }

    func testAppRescanKeepsStoreCappedAndReportsOmission() throws {
        try makeApp("First")
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 8)
        var opts = makeOptions(fileRoots: ["~/Documents"])
        opts.maxItems = 4
        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 4)

        for i in 0..<8 { try makeApp("Later\(i)") }
        let rescanned = expectation(description: "capped app rescan")
        rescanned.assertForOverFulfill = false
        coord.onStoreChanged = { store in
            XCTAssertLessThanOrEqual(store.count, 4)
            if store.appItems.count == 4 { rescanned.fulfill() }
        }
        coord.rescanApps()
        coord.flushSnapshot()
        wait(for: [rescanned], timeout: 20)
        XCTAssertEqual(coord.store.count, 4)
        XCTAssertEqual(coord.store.appItems.count, 4)
        XCTAssertTrue(coord.status.hitItemCap)
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

    func testReducingMaxItemsRebuildsBeforePublishingNewCap() throws {
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 12)
        var initial = makeOptions(fileRoots: ["~/Documents"])
        initial.maxItems = 100
        let coord = IndexCoordinator(options: initial)
        startAndWait(coord, minCount: 10)
        XCTAssertGreaterThan(coord.store.count, 3)

        var reduced = initial
        reduced.maxItems = 3
        let capped = expectation(description: "cap reduction rebuild")
        capped.assertForOverFulfill = false
        let postUpdateCounts = LockedValues<Int>()
        coord.onStoreChanged = { store in
            postUpdateCounts.append(store.count)
            if store.count == 3 { capped.fulfill() }
        }
        coord.update(options: reduced)
        coord.flushSnapshot()
        wait(for: [capped], timeout: 20)
        let counts = postUpdateCounts.snapshot
        XCTAssertTrue(counts.allSatisfy { $0 <= 3 }, "post-update publishes: \(counts)")
        XCTAssertEqual(coord.store.count, 3)
        XCTAssertTrue(coord.status.hitItemCap)
        coord.stop()
    }

    func testOversizedMatchingSnapshotIsRejectedAndRecrawledWithinCap() throws {
        let docs = try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 10)
        var opts = makeOptions(fileRoots: [docs.path])
        opts.maxItems = 3
        let hash = Snapshot.headerHash(exclusions: opts.exclusions, fileRoots: [docs.path],
                                       appRoots: [appsDir.path], maxItems: 3)
        let b = IndexBuilder()
        let root = b.addRoot(docs.path)
        for i in 0..<8 {
            let name = "snapshot-\(i).txt"
            b.addItem(dir: root, name: name, analyzed: TextAnalyzer.analyze(name), kind: .document,
                      flags: [], mtime: nil, depth: 1, ext: "txt")
        }
        try Snapshot.write(b.build(generation: 1, fsEventId: 0), to: snapshotURL, headerHash: hash)

        let coord = IndexCoordinator(options: opts)
        startAndWait(coord, minCount: 3)
        XCTAssertEqual(coord.store.count, 3)
        XCTAssertFalse((0..<coord.store.count).contains { coord.store.name(of: $0).hasPrefix("snapshot-") },
                       "oversized snapshot contents must never be published")
        XCTAssertTrue(coord.status.hitItemCap)
        coord.stop()
    }

    func testNegativeProgrammaticMaxNormalizesToZero() throws {
        try makeApp("Blocked")
        try makeFiles(in: tempHome.appendingPathComponent("Documents"), count: 2)
        var opts = makeOptions(fileRoots: ["~/Documents"])
        opts.maxItems = Int.min
        let coord = IndexCoordinator(options: opts)
        let published = expectation(description: "zero-sized store")
        published.assertForOverFulfill = false
        coord.onStoreChanged = { store in
            XCTAssertEqual(store.count, 0)
            published.fulfill()
        }
        coord.start()
        coord.flushSnapshot()
        wait(for: [published], timeout: 20)
        XCTAssertEqual(coord.store.count, 0)
        XCTAssertEqual(coord.status.itemCount, 0)
        XCTAssertTrue(coord.status.hitItemCap)
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

    func testProgrammaticOptionsNormalizeNonFiniteTimerAndWatcherValues() {
        var opts = makeOptions(fileRoots: [])
        opts.snapshotWriteInterval = .nan
        opts.fsLatency = .infinity
        opts.fullRecrawlInterval = -.infinity
        var normalized = IndexCoordinator.normalized(opts)
        XCTAssertEqual(normalized.snapshotWriteInterval, 0)
        XCTAssertEqual(normalized.fsLatency, 1.0)
        XCTAssertEqual(normalized.fullRecrawlInterval, 7 * 86_400)

        opts.snapshotWriteInterval = -1
        opts.fsLatency = -1
        opts.fullRecrawlInterval = -1
        normalized = IndexCoordinator.normalized(opts)
        XCTAssertEqual(normalized.snapshotWriteInterval, 0)
        XCTAssertEqual(normalized.fsLatency, 0)
        XCTAssertEqual(normalized.fullRecrawlInterval, 0)

        opts.snapshotWriteInterval = .greatestFiniteMagnitude
        opts.fsLatency = .greatestFiniteMagnitude
        normalized = IndexCoordinator.normalized(opts)
        XCTAssertEqual(normalized.snapshotWriteInterval, IndexCoordinator.maximumSnapshotWriteInterval)
        XCTAssertEqual(normalized.fsLatency, IndexCoordinator.maximumFSEventsLatency)
    }

    func testProgrammaticOptionsBoundRootAndExclusionInputs() {
        var opts = makeOptions(fileRoots: [])
        let overlongPath = "/" + String(repeating: "p", count: SafetyLimits.maxPathUTF8Bytes)
        opts.home = overlongPath
        opts.appRoots = [overlongPath, "~/Applications", "~/Applications"]
            + (0...SafetyLimits.maxRootEntries).map { "/Applications/\($0)" }
        opts.fileRoots = [overlongPath, "~/Documents", "~/Documents"]
            + (0...SafetyLimits.maxRootEntries).map { "/tmp/files-\($0)" }
        opts.exclusions.excludePaths = Array(repeating: "/tmp/x",
                                             count: SafetyLimits.maxExcludedPathEntries + 1)
        opts.exclusions.excludeNames = Set((0...SafetyLimits.maxNameEntries).map { "excluded-\($0)" })
        opts.exclusions.downrankNames = [String(repeating: "n", count: SafetyLimits.maxNameUTF8Bytes + 1), "BUILD"]
        opts.exclusions.maxDepth = Int.max
        opts.exclusions.maxDirEntries = Int.max
        opts.exclusions.downrankDirEntries = Int.min

        let normalized = IndexCoordinator.normalized(opts)
        XCTAssertEqual(normalized.home, NSHomeDirectory())
        XCTAssertLessThanOrEqual(normalized.appRoots.count, SafetyLimits.maxRootEntries)
        XCTAssertLessThanOrEqual(normalized.fileRoots.count, SafetyLimits.maxRootEntries)
        XCTAssertTrue((normalized.appRoots + normalized.fileRoots).allSatisfy {
            SafetyLimits.utf8Fits($0, maxBytes: SafetyLimits.maxPathUTF8Bytes)
        })
        XCTAssertEqual(Set(normalized.appRoots).count, normalized.appRoots.count)
        XCTAssertEqual(Set(normalized.fileRoots).count, normalized.fileRoots.count)
        XCTAssertEqual(normalized.exclusions.excludePaths, Exclusions.defaults(home: normalized.home).excludePaths,
                       "oversized security exclusions must fail back to the safe defaults")
        XCTAssertEqual(normalized.exclusions.excludeNames, Exclusions.defaults(home: normalized.home).excludeNames)
        XCTAssertEqual(normalized.exclusions.downrankNames, ["build"])
        XCTAssertEqual(normalized.exclusions.maxDepth, SafetyLimits.maxDepth.upperBound)
        XCTAssertEqual(normalized.exclusions.maxDirEntries, Crawler.hardMaxDirectoryEntries)
        XCTAssertEqual(normalized.exclusions.downrankDirEntries, 0)
    }

    func testProgrammaticRootNormalizationHonorsSharedIndexRootCeiling() {
        var opts = makeOptions(fileRoots: [])
        opts.appRoots = (0...SafetyLimits.maxRootEntries).map { "/Applications/app-\($0)" }
        opts.fileRoots = (0...SafetyLimits.maxRootEntries).map { "/files/root-\($0)" }

        let normalized = IndexCoordinator.normalized(opts)
        XCTAssertEqual(normalized.appRoots.count, SafetyLimits.maxRootEntries)
        XCTAssertEqual(normalized.fileRoots.count, SafetyLimits.maxRootEntries)
        XCTAssertEqual(normalized.appRoots.count + normalized.fileRoots.count
            + AppScanner.extraBundles.count, SafetyLimits.maxIndexRoots)
    }

    func testInvalidTimerOptionsCanStartAndStopWithoutDispatchTrap() {
        var opts = makeOptions(fileRoots: [])
        opts.appRoots = []
        opts.snapshotWriteInterval = .nan
        opts.fsLatency = .nan
        let coord = IndexCoordinator(options: opts)
        coord.start()
        coord.flushSnapshot()
        coord.stop()
        XCTAssertEqual(coord.status.phase, .idle)
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
