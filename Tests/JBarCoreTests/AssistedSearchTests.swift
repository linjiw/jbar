import XCTest
@testable import JBarCore

final class AssistedSearchTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testTypedMetadataPlanFiltersAndSortsTheLocalIndex() async {
        let engine = SearchEngine()
        await engine.setHome("/Users/tester")
        await engine.update(store: makeStore())
        let request = AssistedSearchRequest(
            nameTerms: ["budget"], extensions: ["pdf"], kinds: [.document],
            modifiedAfter: now.addingTimeInterval(-4 * 86_400),
            sort: .modifiedDescending, limit: 40
        )

        let response = await engine.assistedSearch(request)

        XCTAssertTrue(response.totalMatchesIsComplete)
        XCTAssertFalse(response.cancelled)
        XCTAssertEqual(response.totalMatches, 1)
        XCTAssertEqual(response.rows.map(\.name), ["budget-new.pdf"])
        XCTAssertEqual(response.rows.first?.path, "/Users/tester/Documents/budget-new.pdf")
        XCTAssertEqual(response.scannedItems, 4)
    }

    func testMetadataSearchUsesAndSemanticsAndKeepsResultsBounded() async {
        let engine = SearchEngine()
        await engine.setHome("/Users/tester")
        await engine.update(store: makeStore())
        let request = AssistedSearchRequest(nameTerms: ["budget", "old"],
                                            sort: .nameAscending, limit: 1)

        let response = await engine.assistedSearch(request)

        XCTAssertEqual(response.totalMatches, 1)
        XCTAssertEqual(response.rows.count, 1)
        XCTAssertEqual(response.rows.first?.name, "budget-old.pdf")
        XCTAssertFalse(response.rows.first?.matchedByteOffsets.isEmpty ?? true)
    }

    func testPublicRequestClampsEveryCollectionAndResultLimit() {
        let request = AssistedSearchRequest(
            nameTerms: (0..<20).map { "term\($0)" },
            extensions: Set((0..<20).map { "e\($0)" }),
            limit: Int.max
        )

        XCTAssertEqual(request.nameTerms.count, AssistedSearchRequest.maximumNameTerms)
        XCTAssertEqual(request.extensions.count, AssistedSearchRequest.maximumExtensions)
        XCTAssertEqual(request.limit, AssistedSearchRequest.maximumResults)
    }

    func testPublicRequestBoundsTermsAndRejectsUnsafeExtensions() {
        let longTerm = String(repeating: "a", count: 600)
        let request = AssistedSearchRequest(
            nameTerms: ["  \n", longTerm],
            extensions: ["PDF", "JpG", "", "123456789", "bad.ext"],
            limit: 0
        )

        XCTAssertEqual(request.nameTerms, [String(repeating: "a", count: 128)])
        XCTAssertEqual(request.extensions, ["jpg", "pdf"])
        XCTAssertEqual(request.limit, 1)
    }

    func testSizeFiltersInspectOnlyBoundedRegularFileMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarAssistedSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let sizes = ["small.bin": 2, "eligible.bin": 10, "large.bin": 20]
        for (name, size) in sizes {
            try Data(repeating: 0x61, count: size).write(to: root.appendingPathComponent(name))
        }

        let builder = IndexBuilder()
        let rootIndex = builder.addRoot(root.path)
        for name in sizes.keys.sorted() {
            builder.addItem(dir: rootIndex, name: name, analyzed: TextAnalyzer.analyze(name),
                            kind: .document, flags: [], mtime: nil, depth: 1, ext: "bin")
        }
        builder.addItem(dir: rootIndex, name: "missing.bin",
                        analyzed: TextAnalyzer.analyze("missing.bin"), kind: .document,
                        flags: [], mtime: nil, depth: 1, ext: "bin")
        builder.addItem(dir: rootIndex, name: "linked.bin",
                        analyzed: TextAnalyzer.analyze("linked.bin"), kind: .document,
                        flags: [.symlink], mtime: nil, depth: 1, ext: "bin")
        builder.addItem(dir: rootIndex, name: "Folder",
                        analyzed: TextAnalyzer.analyze("Folder"), kind: .folder,
                        flags: [], mtime: nil, depth: 1, ext: nil)

        let engine = SearchEngine()
        await engine.setHome(root.path)
        await engine.update(store: builder.build(generation: 12))
        let response = await engine.assistedSearch(AssistedSearchRequest(
            nameTerms: [], minimumSizeBytes: 5, maximumSizeBytes: 15, sort: .nameAscending
        ))

        XCTAssertTrue(response.totalMatchesIsComplete)
        XCTAssertEqual(response.inspectedSizes, 6)
        XCTAssertEqual(response.totalMatches, 1)
        XCTAssertEqual(response.rows.map(\.name), ["eligible.bin"])
    }

    func testAppAliasesDisplayNamesAndEverySortModeStayNative() async {
        let builder = IndexBuilder()
        let root = builder.addRoot("/Applications")
        builder.addItem(
            dir: root, name: "ChatGPT", analyzed: TextAnalyzer.analyze("ChatGPT"), kind: .app,
            flags: [.appBundle], mtime: now, depth: 1, ext: "app",
            app: AppInfo(bundleID: "com.openai.chat", displayName: "OpenAI Assistant",
                         aliases: [TextAnalyzer.analyze("codex")])
        )
        add("cd", kind: .document, modified: now.addingTimeInterval(-100),
            directory: root, builder: builder)
        add("cd-prefix", kind: .document, modified: now,
            directory: root, builder: builder)
        add("xxcd", kind: .document, modified: now,
            directory: root, builder: builder)
        add("c-x-d", kind: .document, modified: now.addingTimeInterval(-50),
            directory: root, builder: builder)

        let engine = SearchEngine()
        await engine.setHome("/Users/tester")
        await engine.update(store: builder.build(generation: 13))

        let aliasResponse = await engine.assistedSearch(AssistedSearchRequest(nameTerms: ["codex"]))
        XCTAssertEqual(aliasResponse.rows.map(\.name), ["OpenAI Assistant"])
        XCTAssertEqual(aliasResponse.rows.first?.tier, 1)

        let modifiedResponse = await engine.assistedSearch(AssistedSearchRequest(
            nameTerms: ["cd"], sort: .modifiedDescending
        ))
        XCTAssertEqual(modifiedResponse.totalMatches, 5)
        XCTAssertEqual(Set(modifiedResponse.rows.prefix(2).map(\.name)), ["cd-prefix", "xxcd"])

        let nameResponse = await engine.assistedSearch(AssistedSearchRequest(
            nameTerms: ["cd"], sort: .nameAscending
        ))
        XCTAssertEqual(nameResponse.rows.map(\.name),
                       ["c-x-d", "cd", "cd-prefix", "OpenAI Assistant", "xxcd"])
    }

    func testSizeOnlySearchStopsBeforeUnboundedMetadataWalk() async {
        let builder = IndexBuilder()
        let root = builder.addRoot("/Users/tester")
        for index in 0...10_000 {
            let name = "Folder-\(index)"
            builder.addItem(dir: root, name: name, analyzed: TextAnalyzer.analyze(name),
                            kind: .folder, flags: [], mtime: nil, depth: 1, ext: nil)
        }
        let engine = SearchEngine()
        await engine.update(store: builder.build(generation: 14))

        let response = await engine.assistedSearch(AssistedSearchRequest(
            nameTerms: [], minimumSizeBytes: 0
        ))

        XCTAssertFalse(response.totalMatchesIsComplete)
        XCTAssertEqual(response.inspectedSizes, 10_000)
        XCTAssertEqual(response.scannedItems, 10_001)
        XCTAssertTrue(response.rows.isEmpty)
    }

    func testLargeGlobalScanKeepsOnlyFortyRowsWhileCountingEveryMatch() async {
        let builder = IndexBuilder()
        let root = builder.addRoot("/Users/tester")
        let documents = builder.addDir(parent: root, name: "Documents")
        for index in 0..<100_000 {
            let name = "receipt-global-\(index).pdf"
            builder.addItem(dir: documents, name: name, analyzed: TextAnalyzer.analyze(name),
                            kind: .document, flags: [], mtime: nil, depth: 2, ext: "pdf")
        }
        let engine = SearchEngine()
        await engine.setHome("/Users/tester")
        await engine.update(store: builder.build(generation: 9))

        let response = await engine.assistedSearch(AssistedSearchRequest(
            nameTerms: ["receipt-global"], extensions: ["pdf"], kinds: [.document], limit: 40
        ))

        XCTAssertTrue(response.totalMatchesIsComplete)
        XCTAssertEqual(response.scannedItems, 100_000)
        XCTAssertEqual(response.totalMatches, 100_000)
        XCTAssertEqual(response.rows.count, 40)
    }

    private func makeStore() -> IndexStore {
        let builder = IndexBuilder()
        let root = builder.addRoot("/Users/tester")
        let documents = builder.addDir(parent: root, name: "Documents")
        add("budget-old.pdf", kind: .document, modified: now.addingTimeInterval(-8 * 86_400),
            directory: documents, builder: builder)
        add("budget-new.pdf", kind: .document, modified: now.addingTimeInterval(-1 * 86_400),
            directory: documents, builder: builder)
        add("budget-cover.png", kind: .image, modified: now,
            directory: documents, builder: builder)
        add("meeting-notes.pdf", kind: .document, modified: now,
            directory: documents, builder: builder)
        return builder.build(generation: 7)
    }

    private func add(_ name: String, kind: ItemKind, modified: Date, directory: Int32,
                     builder: IndexBuilder) {
        builder.addItem(dir: directory, name: name, analyzed: TextAnalyzer.analyze(name),
                        kind: kind, flags: [], mtime: modified, depth: 2,
                        ext: TextAnalyzer.fileExtension(of: name))
    }
}
