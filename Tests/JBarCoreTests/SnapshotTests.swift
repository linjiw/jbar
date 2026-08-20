import Darwin
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

    private func blobPayloadRange(_ target: Int, in data: Data) -> Range<Int>? {
        var cursor = Snapshot.headerByteCount
        for index in 0..<19 {
            guard cursor >= 0, cursor <= data.count,
                  MemoryLayout<UInt64>.size <= data.count - cursor else { return nil }
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) {
                data.copyBytes(to: $0, from: cursor..<(cursor + MemoryLayout<UInt64>.size))
            }
            let length64 = UInt64(littleEndian: raw)
            guard length64 <= UInt64(Int.max) else { return nil }
            cursor += MemoryLayout<UInt64>.size
            let length = Int(length64)
            guard cursor <= data.count, length <= data.count - cursor else { return nil }
            let range = cursor..<(cursor + length)
            if index == target { return range }
            cursor = range.upperBound
        }
        return nil
    }

    private func replacingSideTables(
        in data: Data,
        mutate: (inout Snapshot.SideTables) -> Void
    ) throws -> Data {
        var cursor = Snapshot.headerByteCount
        for _ in 0..<19 {
            guard cursor <= data.count - MemoryLayout<UInt64>.size else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) {
                data.copyBytes(to: $0, from: cursor..<(cursor + MemoryLayout<UInt64>.size))
            }
            let length = Int(UInt64(littleEndian: raw))
            cursor += MemoryLayout<UInt64>.size
            guard length >= 0, cursor <= data.count, length <= data.count - cursor else {
                throw CocoaError(.fileReadCorruptFile)
            }
            cursor += length
        }
        guard cursor <= data.count - MemoryLayout<UInt64>.size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var rawLength: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &rawLength) {
            data.copyBytes(to: $0, from: cursor..<(cursor + MemoryLayout<UInt64>.size))
        }
        let oldLength = Int(UInt64(littleEndian: rawLength))
        let lengthOffset = cursor
        cursor += MemoryLayout<UInt64>.size
        guard oldLength >= 0, cursor <= data.count, oldLength <= data.count - cursor,
              data.count - (cursor + oldLength) == MemoryLayout<UInt32>.size else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var side = try JSONDecoder().decode(Snapshot.SideTables.self,
                                            from: data[cursor..<(cursor + oldLength)])
        mutate(&side)
        let replacement = try JSONEncoder().encode(side)
        var result = Data(data.prefix(lengthOffset))
        var littleLength = UInt64(replacement.count).littleEndian
        withUnsafeBytes(of: &littleLength) { result.append(contentsOf: $0) }
        result.append(replacement)
        var trailer = Snapshot.magic.littleEndian
        withUnsafeBytes(of: &trailer) { result.append(contentsOf: $0) }
        return result
    }

    private func makeRootOnlyStore(rootCount: Int) -> IndexStore {
        var dirs: [DirEntry] = []
        var arena: [UInt8] = []
        dirs.reserveCapacity(rootCount)
        for index in 0..<rootCount {
            let bytes = Array("/root-\(index)".utf8)
            dirs.append(DirEntry(parent: -1, nameStart: Int32(arena.count),
                                 nameLen: UInt16(bytes.count)))
            arena.append(contentsOf: bytes)
        }
        return IndexStore(
            count: 0, dirId: [], nameStart: [], nameLen: [], displayStart: [], displayLen: [],
            mask: [], initials: [], mtime: [], kind: [], flags: [], depth: [], extId: [],
            foldedArena: [], bonusArena: [], displayArena: [], dirs: dirs, dirArena: arena,
            extensions: [], appInfo: [:], appItems: [], generation: 1, fsEventId: 0,
            builtAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeDirectoryOnlyStore(dirs: [DirEntry], arena: [UInt8]) -> IndexStore {
        IndexStore(
            count: 0, dirId: [], nameStart: [], nameLen: [], displayStart: [], displayLen: [],
            mask: [], initials: [], mtime: [], kind: [], flags: [], depth: [], extId: [],
            foldedArena: [], bonusArena: [], displayArena: [], dirs: dirs, dirArena: arena,
            extensions: [], appInfo: [:], appItems: [], generation: 1, fsEventId: 0,
            builtAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeSingleItemStore(root: String, name: String, kind: ItemKind = .other,
                                     flags: ItemFlags = []) -> IndexStore {
        let analyzed = TextAnalyzer.analyze(name)
        let rootBytes = Array(root.utf8)
        let displayBytes = Array(name.utf8)
        return IndexStore(
            count: 1, dirId: [0], nameStart: [0], nameLen: [UInt16(analyzed.folded.count)],
            displayStart: [0], displayLen: [UInt16(displayBytes.count)], mask: [analyzed.mask],
            initials: [analyzed.initials], mtime: [0], kind: [kind.rawValue],
            flags: [flags.rawValue], depth: [1], extId: [-1], foldedArena: analyzed.folded,
            bonusArena: analyzed.bonus, displayArena: displayBytes,
            dirs: [DirEntry(parent: -1, nameStart: 0, nameLen: UInt16(rootBytes.count))],
            dirArena: rootBytes, extensions: [], appInfo: [:],
            appItems: kind == .app ? [0] : [], generation: 1, fsEventId: 0,
            builtAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func copy(_ store: IndexStore, extensions: [String]) -> IndexStore {
        IndexStore(
            count: store.count, dirId: store.dirId, nameStart: store.nameStart,
            nameLen: store.nameLen, displayStart: store.displayStart,
            displayLen: store.displayLen, mask: store.mask, initials: store.initials,
            mtime: store.mtime, kind: store.kind, flags: store.flags, depth: store.depth,
            extId: store.extId, foldedArena: store.foldedArena, bonusArena: store.bonusArena,
            displayArena: store.displayArena, dirs: store.dirs, dirArena: store.dirArena,
            extensions: extensions, appInfo: store.appInfo, appItems: store.appItems,
            generation: store.generation, fsEventId: store.fsEventId, builtAt: store.builtAt
        )
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

    func testSnapshotPersistenceIsOwnerOnlyAndRefusesSymlinkReads() throws {
        let store = makeStore()
        let hash: UInt64 = 0x5151
        let target = tempDir.appendingPathComponent("private/index.bin")
        try Snapshot.write(store, to: target, headerHash: hash)

        var info = stat()
        XCTAssertEqual(lstat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, SecureFileIO.fileMode)

        let link = tempDir.appendingPathComponent("linked-index.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(Snapshot.read(from: link, expectedHeaderHash: hash),
                     "snapshot reads must classify the exact O_NOFOLLOW descriptor")
    }

    func testOversizedSparseSnapshotFailsBeforeReadingContents() throws {
        let limit = Snapshot.maximumFileBytes(maxItems: 0, rootAllowance: 0)
        XCTAssertGreaterThanOrEqual(limit, 4_096)
        XCTAssertLessThanOrEqual(limit, Snapshot.absoluteMaximumFileBytes)
        XCTAssertEqual(Snapshot.maximumFileBytes(maxItems: Int.max, rootAllowance: Int.max),
                       Snapshot.absoluteMaximumFileBytes)

        let url = tempDir.appendingPathComponent("oversized-sparse.bin")
        try Snapshot.encode(.empty, headerHash: 0).write(to: url)
        let fd = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { _ = Darwin.close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(limit + 1)), 0)

        let started = Date()
        XCTAssertNil(Snapshot.read(from: url, expectedHeaderHash: 0,
                                   maxItems: SafetyLimits.maxIndexedItems.upperBound, rootAllowance: 0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "a sparse oversized cache should fail from fstat without reading its payload")
    }

    func testEmptyStoreRoundTrips() throws {
        let data = try Snapshot.encode(.empty, headerHash: 99)
        let decoded = try XCTUnwrap(Snapshot.decode(data, expectedHeaderHash: 99))
        XCTAssertEqual(decoded.count, 0)
        XCTAssertEqual(decoded.dirs.count, 0)
    }

    func testTwoHundredFiftySevenDistinctAppParentsUseOneCatalogRootAndRoundTrip() throws {
        let appBase = tempDir.appendingPathComponent("ManyAppParents", isDirectory: true)
        let apps = (0..<257).map { index in
            ScannedApp(
                url: appBase.appendingPathComponent("Vendor-\(index)/App-\(index).app"),
                displayName: "App \(index)", bundleID: "test.app.\(index)", aliases: [], mtime: nil
            )
        }
        let builder = IndexBuilder()
        XCTAssertFalse(AppScanner.add(apps, to: builder, maxItems: apps.count))
        let store = builder.build(generation: 42)

        XCTAssertEqual(store.count, 257)
        XCTAssertEqual(store.dirs.filter { $0.parent < 0 }.count, 1,
                       "absolute app parents must share the '/' catalog tree")
        XCTAssertTrue(store.flags.allSatisfy { $0 & ItemFlags.appCatalog.rawValue != 0 })
        let hash: UInt64 = 0x257
        let data = try Snapshot.encode(store, headerHash: hash)
        let decoded = try XCTUnwrap(Snapshot.decode(data, expectedHeaderHash: hash,
                                                    maxItems: apps.count, rootAllowance: 1))
        XCTAssertEqual(decoded.count, store.count)
        XCTAssertEqual(decoded.dirs.filter { $0.parent < 0 }.count, 1)
        XCTAssertTrue(decoded.flags.allSatisfy { $0 & ItemFlags.appCatalog.rawValue != 0 })
        XCTAssertEqual(Set((0..<decoded.count).map { decoded.path(of: $0) }),
                       Set(apps.map { $0.url.path }))
    }

    func testExactlyMaximumIndexRootsRoundTripsAndOneMoreIsRejected() throws {
        XCTAssertEqual(SafetyLimits.maxIndexRoots, 257)
        let hash: UInt64 = 0x2570
        let maximum = makeRootOnlyStore(rootCount: SafetyLimits.maxIndexRoots)
        let encoded = try Snapshot.encode(maximum, headerHash: hash)
        let decoded = try XCTUnwrap(Snapshot.decode(encoded, expectedHeaderHash: hash,
                                                    rootAllowance: SafetyLimits.maxIndexRoots))
        XCTAssertEqual(decoded.dirs.count, SafetyLimits.maxIndexRoots)
        XCTAssertTrue(decoded.dirs.allSatisfy { $0.parent < 0 })

        let excessive = makeRootOnlyStore(rootCount: SafetyLimits.maxIndexRoots + 1)
        XCTAssertThrowsError(try Snapshot.encode(excessive, headerHash: hash)) {
            XCTAssertEqual($0 as? Snapshot.EncodingFailure, .invalidStore)
        }
    }

    func testDeepApplicationCatalogParentRoundTripsWithinSharedDirectoryBudget() throws {
        let components = (0..<300).map { String(format: "level-%03d", $0) }
        let parent = "/" + components.joined(separator: "/")
        XCTAssertLessThanOrEqual(parent.utf8.count, SafetyLimits.maxPathUTF8Bytes)
        let app = ScannedApp(url: URL(fileURLWithPath: parent + "/Deep.app"),
                             displayName: "Deep", bundleID: "test.deep",
                             aliases: [], mtime: nil)
        let builder = IndexBuilder()
        XCTAssertFalse(AppScanner.add([app], to: builder))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, components.count + 1)

        let hash: UInt64 = 0xD33_300
        let encoded = try Snapshot.encode(store, headerHash: hash)
        let decoded = try XCTUnwrap(Snapshot.decode(encoded, expectedHeaderHash: hash,
                                                    maxItems: 1, rootAllowance: 1))
        XCTAssertEqual(decoded.path(of: 0), app.url.path)
    }

    func testDirectoryTopologyAcceptsExactCompletePathLimitAndRejectsOneOver() throws {
        let maxBytes = SafetyLimits.maxPathUTF8Bytes
        let exactRoot = "/" + String(repeating: "r", count: maxBytes - 1)
        let oneOverRoot = exactRoot + "r"
        let roots = IndexBuilder()
        XCTAssertGreaterThanOrEqual(roots.addRoot(exactRoot), 0)
        XCTAssertEqual(roots.addRoot(oneOverRoot), -1)

        // A trailing root slash contributes no extra separator before its first child.
        let trailingRoot = "/" + String(repeating: "r", count: maxBytes - 3) + "/"
        XCTAssertEqual(trailingRoot.utf8.count, maxBytes - 1)
        let builder = IndexBuilder()
        let root = builder.addRoot(trailingRoot)
        let exactChild = builder.addDir(parent: root, name: "x")
        XCTAssertGreaterThanOrEqual(exactChild, 0)
        XCTAssertEqual(builder.addDir(parent: exactChild, name: "y"), -1,
                       "the next separator+component would exceed the complete path ceiling")
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.dirPath(exactChild).utf8.count, maxBytes)

        let hash: UInt64 = 0x4096
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(store, headerHash: hash),
                                                    expectedHeaderHash: hash, rootAllowance: 1))
        XCTAssertEqual(decoded.dirPath(exactChild), trailingRoot + "x")
    }

    func testThousandsOfTinyComponentsStopAtCompletePathLimit() throws {
        let builder = IndexBuilder()
        var current = builder.addRoot("/")
        for _ in 0..<2_048 {
            current = builder.addDir(parent: current, name: "a")
            XCTAssertGreaterThanOrEqual(current, 0)
        }
        XCTAssertEqual(builder.build(generation: 1).dirPath(current).utf8.count,
                       SafetyLimits.maxPathUTF8Bytes)
        XCTAssertEqual(builder.addDir(parent: current, name: "a"), -1)

        let store = builder.build(generation: 2)
        let hash: UInt64 = 0x2048
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(store, headerHash: hash),
                                                    expectedHeaderHash: hash, rootAllowance: 1))
        XCTAssertEqual(decoded.dirPath(current).utf8.count, SafetyLimits.maxPathUTF8Bytes)
    }

    func testSnapshotRejectsCumulativePathOverflowAndDirPathFailsClosed() throws {
        let maxBytes = SafetyLimits.maxPathUTF8Bytes
        let validRoot = "/" + String(repeating: "r", count: maxBytes - 3) + "/"
        let builder = IndexBuilder()
        let root = builder.addRoot(validRoot)
        let child = builder.addDir(parent: root, name: "x")
        XCTAssertGreaterThanOrEqual(child, 0)
        let hash: UInt64 = 0xBAD4_096
        let valid = try Snapshot.encode(builder.build(generation: 1), headerHash: hash)
        let dirArena = try XCTUnwrap(blobPayloadRange(18, in: valid))

        // Removing the trailing slash keeps the root individually valid and the blob length fixed,
        // but reconstruction now inserts a separator and becomes 4,097 bytes.
        var hostile = valid
        hostile[dirArena.lowerBound + validRoot.utf8.count - 1] = UInt8(ascii: "r")
        XCTAssertNil(Snapshot.decode(hostile, expectedHeaderHash: hash, rootAllowance: 1))

        let hostileRoot = "/" + String(repeating: "r", count: maxBytes - 2)
        var arena = Array(hostileRoot.utf8)
        let childStart = Int32(arena.count)
        arena.append(UInt8(ascii: "x"))
        let overlong = makeDirectoryOnlyStore(
            dirs: [
                DirEntry(parent: -1, nameStart: 0, nameLen: UInt16(hostileRoot.utf8.count)),
                DirEntry(parent: 0, nameStart: childStart, nameLen: 1),
            ],
            arena: arena
        )
        XCTAssertEqual(overlong.dirPath(1), "")
        XCTAssertThrowsError(try Snapshot.encode(overlong, headerHash: hash)) {
            XCTAssertEqual($0 as? Snapshot.EncodingFailure, .invalidStore)
        }

        let broken = makeDirectoryOnlyStore(
            dirs: [DirEntry(parent: 0, nameStart: 0, nameLen: 1)], arena: [UInt8(ascii: "/")]
        )
        XCTAssertEqual(broken.dirPath(0), "", "cycles/broken parents must never yield a relative path")
    }

    func testAppendRecomputesCanonicalEquivalentRootPathLengthsAtomically() throws {
        let maxBytes = SafetyLimits.maxPathUTF8Bytes
        let stem = "/" + String(repeating: "r", count: maxBytes - 110) + "/caf"
        let nfcRoot = stem + "é"
        let nfdRoot = stem + "e\u{301}"
        XCTAssertEqual(nfcRoot, nfdRoot, "Swift root keys intentionally use canonical equality")
        XCTAssertEqual(nfdRoot.utf8.count, nfcRoot.utf8.count + 1)

        // The incoming child is exactly 4,096 bytes under its shorter NFC root, but would be
        // 4,097 bytes after that root maps to the already-present longer NFD spelling.
        let rejecting = IndexBuilder()
        XCTAssertGreaterThanOrEqual(rejecting.addRoot(nfdRoot), 0)
        let incomingExact = IndexBuilder()
        let incomingExactRoot = incomingExact.addRoot(nfcRoot)
        let exactName = String(repeating: "x",
                               count: maxBytes - nfcRoot.utf8.count - 1)
        XCTAssertGreaterThanOrEqual(incomingExact.addDir(parent: incomingExactRoot,
                                                         name: exactName), 0)
        let before = rejecting.build(generation: 1)
        XCTAssertFalse(rejecting.append(incomingExact))
        let after = rejecting.build(generation: 2)
        XCTAssertEqual(after.dirs, before.dirs)
        XCTAssertEqual(after.dirArena, before.dirArena,
                       "a remapped overflow must be rejected before any append mutation")

        // Directory topology alone is not enough: an exact item under the shorter source root
        // becomes one byte over after the canonical root maps to the longer spelling.
        let normalItemTarget = IndexBuilder()
        XCTAssertGreaterThanOrEqual(normalItemTarget.addRoot(nfdRoot), 0)
        let normalItemSource = IndexBuilder()
        let normalItemRoot = normalItemSource.addRoot(nfcRoot)
        let exactItemName = String(repeating: "i",
                                   count: maxBytes - nfcRoot.utf8.count - 1)
        XCTAssertGreaterThanOrEqual(
            normalItemSource.addItem(
                dir: normalItemRoot, name: exactItemName,
                analyzed: TextAnalyzer.analyze(exactItemName), kind: .other, flags: [],
                mtime: nil, depth: 1, ext: nil
            ),
            0
        )
        let normalTargetBefore = normalItemTarget.build(generation: 1)
        XCTAssertFalse(normalItemTarget.append(normalItemSource))
        let normalTargetAfter = normalItemTarget.build(generation: 2)
        XCTAssertEqual(normalTargetAfter.count, normalTargetBefore.count)
        XCTAssertEqual(normalTargetAfter.dirs, normalTargetBefore.dirs)
        XCTAssertEqual(normalTargetAfter.dirArena, normalTargetBefore.dirArena)

        // AppScanner stores the base name, but the mapped path budget must include `.app` before
        // append mutates the target builder.
        let appItemTarget = IndexBuilder()
        XCTAssertGreaterThanOrEqual(appItemTarget.addRoot(nfdRoot), 0)
        let appItemSource = IndexBuilder()
        let appItemRoot = appItemSource.addRoot(nfcRoot)
        let exactAppName = String(repeating: "a",
                                  count: maxBytes - nfcRoot.utf8.count - 5)
        XCTAssertGreaterThanOrEqual(
            appItemSource.addItem(
                dir: appItemRoot, name: exactAppName,
                analyzed: TextAnalyzer.analyze(exactAppName), kind: .app,
                flags: [.appBundle], mtime: nil, depth: 1, ext: nil
            ),
            0
        )
        let appTargetBefore = appItemTarget.build(generation: 1)
        XCTAssertFalse(appItemTarget.append(appItemSource))
        let appTargetAfter = appItemTarget.build(generation: 2)
        XCTAssertEqual(appTargetAfter.count, appTargetBefore.count)
        XCTAssertEqual(appTargetAfter.dirs, appTargetBefore.dirs)
        XCTAssertEqual(appTargetAfter.dirArena, appTargetBefore.dirArena)

        // A child that remains valid after NFC -> NFD remapping must retain the recomputed longer
        // value, so a later append cannot exploit the shorter source-builder cache.
        let longerMapped = IndexBuilder()
        XCTAssertGreaterThanOrEqual(longerMapped.addRoot(nfdRoot), 0)
        let shorterSource = IndexBuilder()
        let shorterRoot = shorterSource.addRoot(nfcRoot)
        let shorterChildName = String(repeating: "y",
                                      count: maxBytes - nfcRoot.utf8.count - 3)
        XCTAssertGreaterThanOrEqual(shorterSource.addDir(parent: shorterRoot,
                                                         name: shorterChildName), 0)
        XCTAssertTrue(longerMapped.append(shorterSource))
        let mappedChild = Int32(longerMapped.dirCount - 1)
        XCTAssertEqual(longerMapped.build(generation: 1).dirPath(mappedChild).utf8.count,
                       maxBytes - 1)
        XCTAssertEqual(longerMapped.addDir(parent: mappedChild, name: "z"), -1)

        // The reverse mapping must shrink the cached length as well. The grandchild lands exactly
        // on 4,096 bytes and remains persistable.
        let shorterMapped = IndexBuilder()
        XCTAssertGreaterThanOrEqual(shorterMapped.addRoot(nfcRoot), 0)
        let longerSource = IndexBuilder()
        let longerRoot = longerSource.addRoot(nfdRoot)
        let longerChildName = String(repeating: "q",
                                     count: maxBytes - nfdRoot.utf8.count - 2)
        XCTAssertGreaterThanOrEqual(longerSource.addDir(parent: longerRoot,
                                                        name: longerChildName), 0)
        XCTAssertTrue(shorterMapped.append(longerSource))
        let shorterMappedChild = Int32(shorterMapped.dirCount - 1)
        let exactGrandchild = shorterMapped.addDir(parent: shorterMappedChild, name: "z")
        XCTAssertGreaterThanOrEqual(exactGrandchild, 0)
        let exactStore = shorterMapped.build(generation: 1)
        XCTAssertEqual(exactStore.dirPath(exactGrandchild).utf8.count, maxBytes)
        let hash: UInt64 = 0xCAFE_0301
        XCTAssertNotNil(Snapshot.decode(try Snapshot.encode(exactStore, headerHash: hash),
                                        expectedHeaderHash: hash, rootAllowance: 1))
    }

    func testAppendRejectsCombinedItemCapBeforeDirectoryPlanning() {
        func oneItemBuilder(root: String, name: String) -> IndexBuilder {
            let builder = IndexBuilder()
            let rootID = builder.addRoot(root)
            XCTAssertGreaterThanOrEqual(
                builder.addItem(dir: rootID, name: name, analyzed: TextAnalyzer.analyze(name),
                                kind: .other, flags: [], mtime: nil, depth: 1, ext: nil),
                0
            )
            return builder
        }

        let target = oneItemBuilder(root: "/target", name: "first")
        let source = oneItemBuilder(root: "/source", name: "second")
        let before = target.build(generation: 1)
        var planningCalls = 0
        XCTAssertFalse(target.append(source, maxItems: 1, beforeDirectoryPlanning: {
            planningCalls += 1
        }))
        XCTAssertEqual(planningCalls, 0,
                       "known item-cap overflow must return before directory planning or name decode")
        let after = target.build(generation: 2)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.dirs, before.dirs)
        XCTAssertEqual(after.dirArena, before.dirArena)
    }

    func testCompleteNormalAndAppItemPathsEnforceExactLimit() throws {
        let maxBytes = SafetyLimits.maxPathUTF8Bytes

        let normalRoot = "/" + String(repeating: "r", count: maxBytes - 3) + "/"
        XCTAssertEqual(normalRoot.utf8.count, maxBytes - 1)
        let normal = IndexBuilder()
        let normalRootID = normal.addRoot(normalRoot)
        XCTAssertGreaterThanOrEqual(
            normal.addItem(dir: normalRootID, name: "x", analyzed: TextAnalyzer.analyze("x"),
                           kind: .other, flags: [], mtime: nil, depth: 1, ext: nil),
            0
        )
        XCTAssertEqual(
            normal.addItem(dir: normalRootID, name: "xx", analyzed: TextAnalyzer.analyze("xx"),
                           kind: .other, flags: [], mtime: nil, depth: 1, ext: nil),
            -1
        )
        let normalStore = normal.build(generation: 1)
        XCTAssertEqual(normalStore.path(of: 0).utf8.count, maxBytes)
        let normalHash: UInt64 = 0xF11E_4096
        let normalData = try Snapshot.encode(normalStore, headerHash: normalHash)
        XCTAssertNotNil(Snapshot.decode(normalData, expectedHeaderHash: normalHash,
                                        rootAllowance: 1))
        let normalDirArena = try XCTUnwrap(blobPayloadRange(18, in: normalData))
        var hostileNormal = normalData
        hostileNormal[normalDirArena.upperBound - 1] = UInt8(ascii: "r")
        XCTAssertNil(Snapshot.decode(hostileNormal, expectedHeaderHash: normalHash,
                                     rootAllowance: 1),
                     "adding the missing separator must push the item path over 4,096 bytes")

        let appRoot = "/" + String(repeating: "a", count: maxBytes - 7) + "/"
        XCTAssertEqual(appRoot.utf8.count, maxBytes - 5)
        let apps = IndexBuilder()
        let appRootID = apps.addRoot(appRoot)
        XCTAssertGreaterThanOrEqual(
            apps.addItem(dir: appRootID, name: "A", analyzed: TextAnalyzer.analyze("A"),
                         kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: nil),
            0
        )
        XCTAssertEqual(
            apps.addItem(dir: appRootID, name: "AB", analyzed: TextAnalyzer.analyze("AB"),
                         kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: nil),
            -1,
            "the reconstructed .app suffix is part of the complete path budget"
        )
        let appStore = apps.build(generation: 1)
        XCTAssertEqual(appStore.path(of: 0).utf8.count, maxBytes)
        let appHash: UInt64 = 0xA990_4096
        let appData = try Snapshot.encode(appStore, headerHash: appHash)
        XCTAssertNotNil(Snapshot.decode(appData, expectedHeaderHash: appHash,
                                        rootAllowance: 1))
        let appDirArena = try XCTUnwrap(blobPayloadRange(18, in: appData))
        var hostileApp = appData
        hostileApp[appDirArena.upperBound - 1] = UInt8(ascii: "a")
        XCTAssertNil(Snapshot.decode(hostileApp, expectedHeaderHash: appHash,
                                     rootAllowance: 1))

        let rawNormal = makeSingleItemStore(
            root: "/" + String(repeating: "r", count: maxBytes - 2), name: "x"
        )
        XCTAssertEqual(rawNormal.path(of: 0), "")
        XCTAssertThrowsError(try Snapshot.encode(rawNormal, headerHash: normalHash))

        let rawApp = makeSingleItemStore(
            root: "/" + String(repeating: "a", count: maxBytes - 6) + "/",
            name: "A", kind: .app, flags: [.appBundle]
        )
        XCTAssertEqual(rawApp.path(of: 0), "")
        XCTAssertThrowsError(try Snapshot.encode(rawApp, headerHash: appHash))
    }

    func testSnapshotRejectsSlashByteHiddenByCombiningExtension() throws {
        let store = makeStore()
        let hash: UInt64 = 0xE87_0301
        let valid = try Snapshot.encode(store, headerHash: hash)
        let hostileExtension = "bad/\u{301}ext"
        XCTAssertFalse(hostileExtension.contains("/"),
                       "this regression requires Swift Character matching to miss the POSIX slash")

        let hostileDecode = try replacingSideTables(in: valid) {
            $0.extensions[0] = hostileExtension
        }
        XCTAssertNil(Snapshot.decode(hostileDecode, expectedHeaderHash: hash))

        var hostileExtensions = store.extensions
        hostileExtensions[0] = hostileExtension
        XCTAssertThrowsError(try Snapshot.encode(copy(store, extensions: hostileExtensions),
                                                 headerHash: hash)) {
            XCTAssertEqual($0 as? Snapshot.EncodingFailure, .invalidStore)
        }
    }

    func testUnicodeExtensionWithinCharacterAndByteLimitsRoundTrips() throws {
        let builder = IndexBuilder()
        let root = builder.addRoot("/tmp/extensions")
        let ext = "扩展一二三四五六" // 8 user-visible characters, 24 UTF-8 bytes.
        XCTAssertEqual(ext.count, SafetyLimits.maxExtensionCharacters)
        XCTAssertLessThanOrEqual(ext.utf8.count, SafetyLimits.maxExtensionUTF8Bytes)
        XCTAssertGreaterThanOrEqual(
            builder.addItem(dir: root, name: "文档.\(ext)", analyzed: TextAnalyzer.analyze("文档.\(ext)"),
                            kind: .document, flags: [], mtime: nil, depth: 1, ext: ext),
            0
        )
        let hash: UInt64 = 0xE8
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(builder.build(generation: 1),
                                                                         headerHash: hash),
                                                    expectedHeaderHash: hash))
        XCTAssertEqual(decoded.ext(of: 0), ext)
    }

    func testDecodeRejectsUnsafeRootChildAndItemPathBytes() throws {
        let store = makeStore()
        let hash: UInt64 = 0x5AFE
        let valid = try Snapshot.encode(store, headerHash: hash)
        let dirArena = try XCTUnwrap(blobPayloadRange(18, in: valid))
        let displayArena = try XCTUnwrap(blobPayloadRange(14, in: valid))
        XCTAssertFalse(dirArena.isEmpty)
        XCTAssertFalse(displayArena.isEmpty)

        var relativeRoot = valid
        relativeRoot[dirArena.lowerBound] = UInt8(ascii: "x")
        XCTAssertNil(Snapshot.decode(relativeRoot, expectedHeaderHash: hash),
                     "snapshot roots must remain absolute")

        var nulRoot = valid
        nulRoot[dirArena.lowerBound + 1] = 0
        XCTAssertNil(Snapshot.decode(nulRoot, expectedHeaderHash: hash),
                     "snapshot roots must reject embedded NUL")

        for unsafeRoot in ["/tmp/../escape", "/tmp/./escapeX"] {
            let raw = Array(unsafeRoot.utf8)
            XCTAssertEqual(raw.count, Int(store.dirs[0].nameLen))
            var traversalRoot = valid
            traversalRoot.replaceSubrange(dirArena.lowerBound..<(dirArena.lowerBound + raw.count),
                                          with: raw)
            XCTAssertNil(Snapshot.decode(traversalRoot, expectedHeaderHash: hash),
                         "snapshot roots must reject lexical traversal components")

            let unsafeStore = IndexStore(
                count: 0, dirId: [], nameStart: [], nameLen: [], displayStart: [], displayLen: [],
                mask: [], initials: [], mtime: [], kind: [], flags: [], depth: [], extId: [],
                foldedArena: [], bonusArena: [], displayArena: [],
                dirs: [DirEntry(parent: -1, nameStart: 0, nameLen: UInt16(raw.count))],
                dirArena: raw, extensions: [], appInfo: [:], appItems: [], generation: 1,
                fsEventId: 0, builtAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertThrowsError(try Snapshot.encode(unsafeStore, headerHash: hash)) {
                XCTAssertEqual($0 as? Snapshot.EncodingFailure, .invalidStore)
            }
        }

        let rootLength = Int(store.dirs[0].nameLen)
        var slashChild = valid
        slashChild[dirArena.lowerBound + rootLength] = UInt8(ascii: "/")
        XCTAssertNil(Snapshot.decode(slashChild, expectedHeaderHash: hash),
                     "child directory entries must be one physical path component")

        var slashItem = valid
        slashItem[displayArena.lowerBound] = UInt8(ascii: "/")
        XCTAssertNil(Snapshot.decode(slashItem, expectedHeaderHash: hash),
                     "item display names must be one physical path component")
    }

    func testDecodeRejectsMaliciousAppInfoStrings() throws {
        let hash: UInt64 = 0xA991
        let valid = try Snapshot.encode(makeStore(), headerHash: hash)

        let emptyDisplayName = try replacingSideTables(in: valid) {
            $0.appInfo[0].info.displayName = ""
        }
        XCTAssertNil(Snapshot.decode(emptyDisplayName, expectedHeaderHash: hash))

        let nulDisplayName = try replacingSideTables(in: valid) {
            $0.appInfo[0].info.displayName = "Bad\0Name"
        }
        XCTAssertNil(Snapshot.decode(nulDisplayName, expectedHeaderHash: hash))

        let nulBundleID = try replacingSideTables(in: valid) {
            $0.appInfo[0].info.bundleID = "bad\0.bundle"
        }
        XCTAssertNil(Snapshot.decode(nulBundleID, expectedHeaderHash: hash))

        let missingAppIndex = try replacingSideTables(in: valid) {
            $0.appItems.removeAll()
        }
        XCTAssertNil(Snapshot.decode(missingAppIndex, expectedHeaderHash: hash),
                     "appItems must enumerate every app kind, not merely a valid subset")
    }

    func testDecodeEnforcesConfiguredItemCapBeforePublishing() throws {
        let store = makeStore()
        let hash: UInt64 = 0xCAFE
        let data = try Snapshot.encode(store, headerHash: hash)
        XCTAssertNil(Snapshot.decode(data, expectedHeaderHash: hash, maxItems: store.count - 1))
        XCTAssertNotNil(Snapshot.decode(data, expectedHeaderHash: hash, maxItems: store.count))
        XCTAssertNil(Snapshot.decode(data, expectedHeaderHash: hash, maxItems: Int.min))
    }

    func testBuilderCapsRootsAndRejectsOversizedRootMetadata() throws {
        let b = IndexBuilder()
        for i in 0..<300 { _ = b.addRoot("/unused/\(i)") }
        let bounded = b.build(generation: 1)
        XCTAssertEqual(bounded.dirs.count, SafetyLimits.maxIndexRoots)
        XCTAssertNoThrow(try Snapshot.encode(bounded, headerHash: 77),
                         "the builder's exact shared root cap remains persistable")

        let arenaBuilder = IndexBuilder()
        XCTAssertEqual(arenaBuilder.addRoot("/" + String(repeating: "x", count: 70_000)), -1,
                       "the builder must reject an oversized root before it can create an invalid store")
        XCTAssertNoThrow(try Snapshot.encode(arenaBuilder.build(generation: 1), headerHash: 78))
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

    func testHostileCountAndBlobLengthsFailBeforeAllocation() throws {
        let hash: UInt64 = 0xBAD0
        let original = try Snapshot.encode(makeStore(), headerHash: hash)

        var hostileCount = original
        var count = UInt64.max.littleEndian
        withUnsafeBytes(of: &count) { hostileCount.replaceSubrange(40..<48, with: $0) }
        XCTAssertNil(Snapshot.decode(hostileCount, expectedHeaderHash: hash, maxItems: 10))

        var hostileBlob = original
        var length = UInt64.max.littleEndian
        withUnsafeBytes(of: &length) { hostileBlob.replaceSubrange(56..<64, with: $0) }
        XCTAssertNil(Snapshot.decode(hostileBlob, expectedHeaderHash: hash),
                     "a corrupt length prefix must be rejected before constructing an array")
    }

    func testBuilderAcceptedLargeSmallStoreSideTableRoundTripsSnapshot() throws {
        let builder = IndexBuilder()
        let root = builder.addRoot("/Applications")
        let bytes = [UInt8](repeating: 0x61, count: Snapshot.maximumAnalyzedNameBytes)
        let alias = SearchString(folded: bytes, bonus: [UInt8](repeating: 0, count: bytes.count),
                                 mask: 1, initials: 1)
        let info = AppInfo(bundleID: "test.large-side-table", displayName: "Large",
                           aliases: [SearchString](repeating: alias, count: 4))
        XCTAssertGreaterThanOrEqual(
            builder.addItem(dir: root, name: "Large", analyzed: TextAnalyzer.analyze("Large"),
                            kind: .app, flags: [.appBundle, .appCatalog], mtime: nil,
                            depth: 1, ext: "app", app: info),
            0
        )

        let store = builder.build(generation: 1)
        let hash: UInt64 = 0x51DE
        let encoded = try Snapshot.encode(store, headerHash: hash)
        XCTAssertGreaterThan(encoded.count, 64 * 1_024,
                             "the regression requires a legal one-item side table over the old cap")
        let decoded = try XCTUnwrap(Snapshot.decode(encoded, expectedHeaderHash: hash,
                                                    maxItems: 1, rootAllowance: 1))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.appInfo[0]?.aliases.count, info.aliases.count)
    }

    func testDeepOrStructurallyInvalidSideTableJSONFailsBeforeDecoderRecursion() throws {
        let hash: UInt64 = 0xD33F
        let encoded = try Snapshot.encode(.empty, headerHash: hash)
        let jsonLengthOffset = Snapshot.headerByteCount + 19 * MemoryLayout<UInt64>.size
        XCTAssertGreaterThan(encoded.count, jsonLengthOffset + MemoryLayout<UInt64>.size)

        let openings = String(repeating: "[", count: Snapshot.maximumJSONNestingDepth)
        let closings = String(repeating: "]", count: Snapshot.maximumJSONNestingDepth)
        let deepJSON = Data(("{\"extensions\":[],\"appInfo\":[],\"appItems\":[],\"ignored\":"
                             + openings + "0" + closings + "}").utf8)
        XCTAssertFalse(Snapshot.hasSafeJSONStructure(deepJSON))

        var hostile = Data(encoded.prefix(jsonLengthOffset))
        var jsonLength = UInt64(deepJSON.count).littleEndian
        withUnsafeBytes(of: &jsonLength) { hostile.append(contentsOf: $0) }
        hostile.append(deepJSON)
        var trailer = Snapshot.magic.littleEndian
        withUnsafeBytes(of: &trailer) { hostile.append(contentsOf: $0) }
        XCTAssertNil(Snapshot.decode(hostile, expectedHeaderHash: hash))

        XCTAssertFalse(Snapshot.hasSafeJSONStructure(Data("{\"extensions\":[}".utf8)),
                       "mismatched delimiters must fail before JSONDecoder")
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

    func testHeaderHashChangesWithExclusionsRootRolesAndCap() {
        let excl = Exclusions.defaults(home: "/home/u")
        let fileRoots = ["/home/u/Documents", "/home/u/Desktop"]
        let appRoots = ["/Applications", "/System/Applications"]
        let base = Snapshot.headerHash(exclusions: excl, fileRoots: fileRoots, appRoots: appRoots, maxItems: 500)
        // Order within each root domain does not matter.
        XCTAssertEqual(base, Snapshot.headerHash(exclusions: excl, fileRoots: fileRoots.reversed(),
                                                 appRoots: appRoots.reversed(), maxItems: 500))
        // A different root set changes the hash.
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, fileRoots: fileRoots + ["/home/u/Downloads"],
                                                    appRoots: appRoots, maxItems: 500))
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, fileRoots: ["/home/u/Documents"],
                                                    appRoots: appRoots, maxItems: 500))
        // Swapping a path between file and app roles invalidates the snapshot even when the union is unchanged.
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, fileRoots: appRoots,
                                                    appRoots: fileRoots, maxItems: 500))
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl, fileRoots: fileRoots,
                                                    appRoots: appRoots, maxItems: 499))
        // A different exclusions config changes the hash.
        var excl2 = excl; excl2.includeHidden = true
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl2, fileRoots: fileRoots,
                                                    appRoots: appRoots, maxItems: 500))
        var excl3 = excl; excl3.maxDepth = 3
        XCTAssertNotEqual(base, Snapshot.headerHash(exclusions: excl3, fileRoots: fileRoots,
                                                    appRoots: appRoots, maxItems: 500))
    }
}
