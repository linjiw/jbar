import XCTest
@testable import JBarCore

/// `IndexBuilder.append` is the merge primitive behind the parallel crawl. These tests prove a merged
/// store is identical to one built serially, and that duplicate synthetic-parent roots are deduped.
final class IndexBuilderAppendTests: XCTestCase {
    private func addItem(_ b: IndexBuilder, dir: Int32, name: String, kind: ItemKind, depth: Int, ext: String?, app: AppInfo? = nil) -> Int32 {
        b.addItem(dir: dir, name: name, analyzed: TextAnalyzer.analyze(name), kind: kind, flags: kind == .app ? [.appBundle] : [], mtime: Date(timeIntervalSinceReferenceDate: 100), depth: depth, ext: ext, app: app)
    }

    /// Two per-root builders sharing the synthetic parent "/Users/me" merge into one store whose paths,
    /// names, kinds, exts and appItems match, with the shared parent deduped to a single root dir.
    func testMergeMatchesSerialAndDedupesRoots() {
        // Serial reference: one builder, two roots under the same parent.
        let ref = IndexBuilder()
        let p = ref.addRoot("/Users/me")
        let docs = ref.addDir(parent: p, name: "Documents")
        _ = addItem(ref, dir: docs, name: "a.pdf", kind: .document, depth: 2, ext: "pdf")
        let proj = ref.addDir(parent: p, name: "projects")
        let sub = ref.addDir(parent: proj, name: "app")
        _ = addItem(ref, dir: sub, name: "main.swift", kind: .code, depth: 3, ext: "swift")
        _ = addItem(ref, dir: p, name: "Xcode", kind: .app, depth: 1, ext: "app", app: AppInfo(bundleID: "x", displayName: "Xcode", aliases: []))
        let refStore = ref.build(generation: 1)

        // Parallel: two builders, each synthesises its own "/Users/me" parent; merge in order.
        let b1 = IndexBuilder(); let p1 = b1.addRoot("/Users/me"); let d1 = b1.addDir(parent: p1, name: "Documents")
        _ = addItem(b1, dir: d1, name: "a.pdf", kind: .document, depth: 2, ext: "pdf")
        let b2 = IndexBuilder(); let p2 = b2.addRoot("/Users/me"); let pr2 = b2.addDir(parent: p2, name: "projects"); let s2 = b2.addDir(parent: pr2, name: "app")
        _ = addItem(b2, dir: s2, name: "main.swift", kind: .code, depth: 3, ext: "swift")
        let b3 = IndexBuilder(); let p3 = b3.addRoot("/Users/me")
        _ = addItem(b3, dir: p3, name: "Xcode", kind: .app, depth: 1, ext: "app", app: AppInfo(bundleID: "x", displayName: "Xcode", aliases: []))
        let merged = IndexBuilder()
        merged.append(b1); merged.append(b2); merged.append(b3)
        let mStore = merged.build(generation: 1)

        // Same item set (order-independent): compare sorted (path, kind, ext).
        func triples(_ s: IndexStore) -> [String] {
            (0..<s.count).map { "\($0 < 0 ? "" : s.path(of: $0))|\(s.itemKind($0).rawValue)|\(s.ext(of: $0) ?? "-")|\(s.name(of: $0))" }.sorted()
        }
        XCTAssertEqual(mStore.count, refStore.count)
        XCTAssertEqual(triples(mStore), triples(refStore))

        // The shared parent "/Users/me" is a single root dir in the merged store (deduped), like the serial one.
        func rootDirCount(_ s: IndexStore, named: String) -> Int {
            s.dirs.enumerated().filter { $0.element.parent < 0 && s.dirPath(Int32($0.offset)) == named }.count
        }
        XCTAssertEqual(rootDirCount(mStore, named: "/Users/me"), 1, "duplicate synthetic-parent roots must be deduped")
        XCTAssertEqual(rootDirCount(refStore, named: "/Users/me"), 1)

        // App survived the merge with its AppInfo and correct .app path.
        XCTAssertEqual(mStore.appItems.count, 1)
        let ai = mStore.appItems[0]
        XCTAssertEqual(mStore.path(of: Int(ai)), "/Users/me/Xcode.app")
        XCTAssertEqual(mStore.appInfo[ai]?.bundleID, "x")
    }

    /// Extensions interned in different builders remap correctly on merge.
    func testExtensionRemap() {
        let b1 = IndexBuilder(); let r1 = b1.addRoot("/r")
        _ = addItem(b1, dir: r1, name: "a.pdf", kind: .document, depth: 1, ext: "pdf")
        _ = addItem(b1, dir: r1, name: "b.txt", kind: .document, depth: 1, ext: "txt")
        let b2 = IndexBuilder(); let r2 = b2.addRoot("/r2")
        _ = addItem(b2, dir: r2, name: "c.swift", kind: .code, depth: 1, ext: "swift")
        _ = addItem(b2, dir: r2, name: "d.pdf", kind: .document, depth: 1, ext: "pdf")   // "pdf" already interned in b1
        let m = IndexBuilder(); m.append(b1); m.append(b2)
        let s = m.build(generation: 1)
        let exts = (0..<s.count).compactMap { s.ext(of: $0) }.sorted()
        XCTAssertEqual(exts, ["pdf", "pdf", "swift", "txt"])
        // Each item's ext id points at the right string.
        for i in 0..<s.count { XCTAssertEqual(s.ext(of: i), TextAnalyzer.fileExtension(of: s.name(of: i))) }
    }

    func testExtensionTableStopsBeforeInt16IdentifiersAlias() throws {
        let builder = IndexBuilder()
        let root = builder.addRoot("/extensions")
        let analyzed = TextAnalyzer.analyze("item")
        for index in 0...(Int(Int16.max) + 1) {
            builder.addItem(dir: root, name: "item", analyzed: analyzed, kind: .other,
                            flags: [], mtime: nil, depth: 1,
                            ext: "e" + String(index, radix: 36))
        }
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.extensions.count, Int(Int16.max) + 1)
        XCTAssertEqual(store.extId[Int(Int16.max)], Int16.max)
        XCTAssertEqual(store.extId[Int(Int16.max) + 1], -1,
                       "a new extension must become unknown instead of aliasing Int16.max")
        XCTAssertNoThrow(try Snapshot.encode(store, headerHash: 1))
    }

    func testBuilderRejectsUnsafePublicInputsWithoutMutatingItsStore() {
        let builder = IndexBuilder()
        let oversizedRoot = "/" + String(repeating: "r", count: SafetyLimits.maxPathUTF8Bytes)
        XCTAssertEqual(builder.addRoot(oversizedRoot), -1)
        XCTAssertEqual(builder.addRoot("/" + String(repeating: "/", count: 1_000_000)), -1,
                       "the byte guard must reject before splitting an attacker-sized path")
        XCTAssertEqual(builder.addRoot("/safe/../escape"), -1)
        XCTAssertEqual(builder.addRoot("/safe/./child"), -1)
        XCTAssertEqual(builder.addRoot("/safe/\u{301}/../escape"), -1)
        XCTAssertEqual(builder.addDir(parent: Int32.max, name: "child"), -1)
        XCTAssertEqual(builder.dirCount, 0)

        let root = builder.addRoot("/safe")
        for unsafeComponent in [".", "..", "a/b", "bad\0name"] {
            XCTAssertEqual(builder.addDir(parent: root, name: unsafeComponent), -1)
            XCTAssertEqual(builder.addItem(dir: root, name: unsafeComponent,
                                           analyzed: TextAnalyzer.analyze("safe"), kind: .other,
                                           flags: [], mtime: nil, depth: 1, ext: nil), -1)
        }
        let decoratedSlash = "nested/\u{301}child"
        XCTAssertEqual(builder.addDir(parent: root, name: decoratedSlash), -1)
        XCTAssertEqual(builder.addItem(dir: root, name: decoratedSlash,
                                       analyzed: TextAnalyzer.analyze("safe"), kind: .other,
                                       flags: [], mtime: nil, depth: 1, ext: nil), -1)
        let oversizedName = String(repeating: "n", count: SafetyLimits.maxNameUTF8Bytes + 1)
        XCTAssertEqual(builder.addItem(dir: root, name: oversizedName,
                                       analyzed: TextAnalyzer.analyze("safe"), kind: .other,
                                       flags: [], mtime: nil, depth: 1, ext: nil), -1)
        let malformed = SearchString(folded: [1, 2], bonus: [1], mask: 0, initials: 0)
        XCTAssertEqual(builder.addItem(dir: root, name: "safe", analyzed: malformed,
                                       kind: .other, flags: [], mtime: nil, depth: 1,
                                       ext: nil), -1)
        let unsafeApp = AppInfo(bundleID: nil,
                                displayName: String(repeating: "d", count: SafetyLimits.maxNameUTF8Bytes + 1),
                                aliases: [])
        XCTAssertEqual(builder.addItem(dir: root, name: "Safe", analyzed: TextAnalyzer.analyze("Safe"),
                                       kind: .app, flags: [.appBundle], mtime: nil, depth: 1,
                                       ext: "app", app: unsafeApp), -1)
        XCTAssertEqual(builder.count, 0)
    }

    func testBuilderTreatsUnsafePublicExtensionsAsUnknown() throws {
        for unsafeExtension in ["bad/\u{301}ext", "bad\0ext", ".", ".."] {
            let builder = IndexBuilder()
            let root = builder.addRoot("/safe")
            XCTAssertGreaterThanOrEqual(builder.addItem(dir: root, name: "item",
                                                         analyzed: TextAnalyzer.analyze("item"),
                                                         kind: .document, flags: [], mtime: nil,
                                                         depth: 1, ext: unsafeExtension), 0)
            let store = builder.build(generation: 1)
            XCTAssertEqual(store.extId, [-1], unsafeExtension)
            XCTAssertNoThrow(try Snapshot.encode(store, headerHash: 1))
        }
    }

    func testBuilderBoundsCumulativeAppSideTableAndAppendRootCount() {
        let builder = IndexBuilder()
        let root = builder.addRoot("/apps")
        let largeAlias = SearchString(folded: [UInt8](repeating: 1, count: 4_096),
                                      bonus: [UInt8](repeating: 0, count: 4_096),
                                      mask: 1, initials: 0)
        let info = AppInfo(bundleID: "com.example.large", displayName: "Large",
                           aliases: [SearchString](repeating: largeAlias,
                                                   count: SafetyLimits.maxSearchAliasesPerApp))
        var accepted = 0
        for index in 0..<100 {
            let result = builder.addItem(dir: root, name: "App\(index)", analyzed: TextAnalyzer.analyze("App\(index)"),
                                         kind: .app, flags: [.appBundle, .appCatalog], mtime: nil,
                                         depth: 1, ext: "app", app: info)
            if result < 0 { break }
            accepted += 1
        }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertLessThan(accepted, 100, "cumulative AppInfo payload must hit a hard side-table budget")
        XCTAssertEqual(builder.count, accepted)

        let roots = IndexBuilder()
        for index in 0..<IndexStoreLimits.maxBuilderRoots {
            XCTAssertGreaterThanOrEqual(roots.addRoot("/root-\(index)"), 0)
        }
        let overflow = IndexBuilder()
        XCTAssertGreaterThanOrEqual(overflow.addRoot("/overflow"), 0)
        let before = roots.dirCount
        roots.append(overflow)
        XCTAssertEqual(roots.dirCount, before, "append must not bypass the unique-root limit")
    }

    func testBuilderClampsNonFiniteDatesAndDepthToPersistableValues() throws {
        let builder = IndexBuilder()
        let root = builder.addRoot("/safe")
        let analyzed = TextAnalyzer.analyze("item")
        builder.addItem(dir: root, name: "nan", analyzed: analyzed, kind: .other,
                        flags: [], mtime: Date(timeIntervalSinceReferenceDate: .nan),
                        depth: Int.max, ext: nil)
        builder.addItem(dir: root, name: "future", analyzed: analyzed, kind: .other,
                        flags: [], mtime: Date(timeIntervalSinceReferenceDate: .infinity),
                        depth: Int.min, ext: nil)
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.mtime, [0, 0])
        XCTAssertEqual(store.depth, [UInt8(SafetyLimits.maxDepth.upperBound), 0])
        XCTAssertNoThrow(try Snapshot.encode(store, headerHash: 1))
    }
}
