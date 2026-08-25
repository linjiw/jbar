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
