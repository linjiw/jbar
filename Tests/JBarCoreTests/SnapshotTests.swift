import XCTest
@testable import JBarCore

/// Tests for the binary `Snapshot` codec (DESIGN.md §3): round-trip fidelity, atomic file I/O,
/// header-hash gating, and graceful `nil` (never a crash) on missing/garbage/truncated input.
final class SnapshotTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
    }

    // A store with roots, a child dir, ~10 items (app + AppInfo/aliases, documents, folder, symlink, hidden),
    // varied flags/mtime/depth and a mix of extensions (including one with no extension).
    private func makeStore(generation: UInt64 = 7, fsEventId: UInt64 = 12345,
                           builtAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> IndexStore {
        let b = IndexBuilder()
        let root = b.addRoot("/tmp/jbar-root")          // dir 0, parent -1
        let docs = b.addDir(parent: root, name: "Documents") // dir 1, parent 0
        func an(_ s: String) -> SearchString { TextAnalyzer.analyze(s) }
        let t0 = Date(timeIntervalSinceReferenceDate: 100_000)

        b.addItem(dir: root, name: "Documents", analyzed: an("Documents"), kind: .folder, flags: [], mtime: t0, depth: 0, ext: nil)
        let appInfo = AppInfo(bundleID: "com.test.app", displayName: "Test App",
                              aliases: [an("测试"), an("test alias"), an("ceshi")])
        b.addItem(dir: root, name: "TestApp", analyzed: an("TestApp"), kind: .app, flags: [.appBundle],
                  mtime: t0.addingTimeInterval(50), depth: 1, ext: "app", app: appInfo)
        b.addItem(dir: docs, name: "report.pdf", analyzed: an("report.pdf"), kind: .document, flags: [.junk],
                  mtime: t0.addingTimeInterval(100), depth: 1, ext: "pdf")
        b.addItem(dir: docs, name: "notes.md", analyzed: an("notes.md"), kind: .document, flags: [],
                  mtime: nil, depth: 1, ext: "md")
        b.addItem(dir: docs, name: "photo.png", analyzed: an("photo.png"), kind: .image, flags: [.cloud],
                  mtime: t0.addingTimeInterval(200), depth: 1, ext: "png")
        b.addItem(dir: docs, name: "main.swift", analyzed: an("main.swift"), kind: .code, flags: [],
                  mtime: t0, depth: 1, ext: "swift")
        b.addItem(dir: docs, name: ".hidden", analyzed: an(".hidden"), kind: .other, flags: [.hidden, .dotName],
                  mtime: t0, depth: 1, ext: nil)
        b.addItem(dir: docs, name: "link", analyzed: an("link"), kind: .folder, flags: [.symlink],
                  mtime: t0, depth: 1, ext: nil)
        b.addItem(dir: docs, name: "Archive.zip", analyzed: an("Archive.zip"), kind: .archive, flags: [.package],
                  mtime: t0, depth: 2, ext: "zip")
        b.addItem(dir: docs, name: "movie.mov", analyzed: an("movie.mov"), kind: .video, flags: [],
                  mtime: t0, depth: 3, ext: "mov")
        return b.build(generation: generation, fsEventId: fsEventId, builtAt: builtAt)
    }

    private func assertStoresEqual(_ a: IndexStore, _ b: IndexStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "count", file: file, line: line)
        XCTAssertEqual(a.dirId, b.dirId, "dirId", file: file, line: line)
        XCTAssertEqual(a.nameStart, b.nameStart, "nameStart", file: file, line: line)
        XCTAssertEqual(a.nameLen, b.nameLen, "nameLen", file: file, line: line)
        XCTAssertEqual(a.displayStart, b.displayStart, "displayStart", file: file, line: line)
        XCTAssertEqual(a.displayLen, b.displayLen, "displayLen", file: file, line: line)
        XCTAssertEqual(a.mask, b.mask, "mask", file: file, line: line)
        XCTAssertEqual(a.initials, b.initials, "initials", file: file, line: line)
        XCTAssertEqual(a.mtime, b.mtime, "mtime", file: file, line: line)
        XCTAssertEqual(a.kind, b.kind, "kind", file: file, line: line)
        XCTAssertEqual(a.flags, b.flags, "flags", file: file, line: line)
        XCTAssertEqual(a.depth, b.depth, "depth", file: file, line: line)
        XCTAssertEqual(a.extId, b.extId, "extId", file: file, line: line)
        XCTAssertEqual(a.foldedArena, b.foldedArena, "foldedArena", file: file, line: line)
        XCTAssertEqual(a.bonusArena, b.bonusArena, "bonusArena", file: file, line: line)
        XCTAssertEqual(a.displayArena, b.displayArena, "displayArena", file: file, line: line)
        XCTAssertEqual(a.dirs, b.dirs, "dirs", file: file, line: line)
        XCTAssertEqual(a.dirArena, b.dirArena, "dirArena", file: file, line: line)
        XCTAssertEqual(a.extensions, b.extensions, "extensions", file: file, line: line)
        XCTAssertEqual(a.appInfo, b.appInfo, "appInfo", file: file, line: line)
        XCTAssertEqual(a.appItems, b.appItems, "appItems", file: file, line: line)
        XCTAssertEqual(a.generation, b.generation, "generation", file: file, line: line)
        XCTAssertEqual(a.fsEventId, b.fsEventId, "fsEventId", file: file, line: line)
        XCTAssertEqual(a.builtAt.timeIntervalSince1970, b.builtAt.timeIntervalSince1970, accuracy: 1e-3, "builtAt", file: file, line: line)
    }

    // MARK: - Round-trips

    func testEncodeDecodeRoundTripsEveryField() throws {
        let store = makeStore()
        let hash: UInt64 = 0xABCD_1234
        let data = try Snapshot.encode(store, headerHash: hash)
        let decoded = try XCTUnwrap(Snapshot.decode(data, expectedHeaderHash: hash))
        assertStoresEqual(store, decoded)
        // Spot-check reconstructed accessors so the arenas/dir table line up.
        let appIdx = Int(try XCTUnwrap(decoded.appItems.first))
        XCTAssertEqual(decoded.fileName(of: appIdx), "TestApp.app")
        XCTAssertEqual(decoded.appInfo[Int32(appIdx)]?.bundleID, "com.test.app")
        XCTAssertEqual(decoded.appInfo[Int32(appIdx)]?.aliases.count, 3)
        // The pdf sits under Documents.
        let pdf = (0..<decoded.count).first { decoded.name(of: $0) == "report.pdf" }!
        XCTAssertEqual(decoded.path(of: pdf), "/tmp/jbar-root/Documents/report.pdf")
        XCTAssertEqual(decoded.ext(of: pdf), "pdf")
    }

    func testWriteReadRoundTripsViaTempFile() throws {
        let store = makeStore()
        let hash: UInt64 = 0x1111_2222_3333_4444
        let url = tempDir.appendingPathComponent("nested/dir/index.bin")
        try Snapshot.write(store, to: url, headerHash: hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "write should create intermediate dirs")
        let decoded = try XCTUnwrap(Snapshot.read(from: url, expectedHeaderHash: hash))
        assertStoresEqual(store, decoded)
    }

    func testEmptyStoreRoundTrips() throws {
        let data = try Snapshot.encode(.empty, headerHash: 99)
        let decoded = try XCTUnwrap(Snapshot.decode(data, expectedHeaderHash: 99))
        XCTAssertEqual(decoded.count, 0)
        XCTAssertEqual(decoded.dirs.count, 0)
    }

    // MARK: - Header-hash gating

    func testHeaderHashMismatchYieldsNil() throws {
        let store = makeStore()
        let data = try Snapshot.encode(store, headerHash: 1000)
        XCTAssertNil(Snapshot.decode(data, expectedHeaderHash: 1001))
        XCTAssertNotNil(Snapshot.decode(data, expectedHeaderHash: 1000))
    }

    func testReadWithMismatchedHashYieldsNil() throws {
        let store = makeStore()
        let url = tempDir.appendingPathComponent("index.bin")
        try Snapshot.write(store, to: url, headerHash: 5)
        XCTAssertNil(Snapshot.read(from: url, expectedHeaderHash: 6))
    }

    // MARK: - Corrupt / missing / truncated input never crashes

    func testMissingFileYieldsNil() {
        let url = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertNil(Snapshot.read(from: url, expectedHeaderHash: 0))
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(Snapshot.decode(Data(), expectedHeaderHash: 0))
        XCTAssertNil(Snapshot.decode(Data(repeating: 0xAB, count: 3), expectedHeaderHash: 0))
        XCTAssertNil(Snapshot.decode(Data(repeating: 0xAB, count: 512), expectedHeaderHash: 0))
        var rng = SystemRandomNumberGenerator()
        let random = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertNil(Snapshot.decode(random, expectedHeaderHash: 0))
    }

    func testTruncatedValidBlobYieldsNilWithoutCrash() throws {
        let store = makeStore()
        let hash: UInt64 = 0xDEAD_BEEF
        let data = try Snapshot.encode(store, headerHash: hash)
        XCTAssertNotNil(Snapshot.decode(data, expectedHeaderHash: hash), "sanity: full blob decodes")
        // Dropping any suffix must fail cleanly (never trap): the trailing magic / bounds checks catch it.
        for drop in [1, 2, 8, 33, 100, data.count / 2, data.count - 1] where drop >= 1 && drop < data.count {
            let truncated = data.prefix(data.count - drop)
            XCTAssertNil(Snapshot.decode(Data(truncated), expectedHeaderHash: hash), "drop=\(drop)")
        }
        // Extra trailing bytes also fail (Reader must be at end).
        var padded = data; padded.append(contentsOf: [0, 0, 0, 0])
        XCTAssertNil(Snapshot.decode(padded, expectedHeaderHash: hash))
    }

    // MARK: - headerHash inputs

    func testHeaderHashChangesWithExclusionsAndRoots() {
        let excl = Exclusions.defaults(home: "/home/u")
        let roots = ["/home/u/Documents", "/home/u/Desktop"]
        let base = Snapshot.headerHash(exclusions: excl, roots: roots)
        // Root order does not matter (roots are sorted).
        XCTAssertEqual(base, Snapshot.headerHash(exclusions: excl, roots: roots.reversed()))
        // A different root set changes the hash.
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, roots: roots + ["/home/u/Downloads"]))
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, roots: ["/home/u/Documents"]))
        // A different exclusions config changes the hash.
        var excl2 = excl; excl2.includeHidden = true
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl2, roots: roots))
        var excl3 = excl; excl3.maxDepth = 3
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl3, roots: roots))
    }
}
