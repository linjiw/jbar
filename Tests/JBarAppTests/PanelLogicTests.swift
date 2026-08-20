import XCTest
import Carbon.HIToolbox
import JBarCore
@testable import JBarApp

/// Pure UI logic — panel geometry, row modelling, badges, Tab autocomplete. Everything here runs
/// headless (no window is created), which is what makes the AppKit layer testable at all: `JBarApp`
/// is a library target precisely so these can be reached.
final class PanelGeometryTests: XCTestCase {

    private func row(_ name: String, path: String, kind: ItemKind) -> ResultRow {
        ResultRow(itemIndex: 0, name: name, path: path, parentDisplay: (path as NSString).deletingLastPathComponent,
                  kind: kind, matchedByteOffsets: [], score: 1, tier: 2)
    }

    // MARK: Height

    /// The panel is input row + n × 48 + 8, and grows by a peek sliver when rows are hidden below.
    func testHeightMath() {
        let input = SearchPanel.inputRowHeight, pad = SearchPanel.bottomPadding, r = SearchPanel.rowHeight
        XCTAssertEqual(SearchPanel.height(forVisibleRows: 0), input + pad)
        XCTAssertEqual(SearchPanel.height(forVisibleRows: 1), input + r + pad)
        XCTAssertEqual(SearchPanel.height(forVisibleRows: 8), input + r * 8 + pad)
        // Negative row counts cannot produce a negative panel.
        XCTAssertEqual(SearchPanel.height(forVisibleRows: -3), input + pad)
    }

    /// The peek sliver is what tells the user more results exist — overlay scrollers are invisible
    /// until you already scrolled, so without it a full list looks complete.
    func testPeekAddsASliverOnlyWhenRowsAreHidden() {
        let plain = SearchPanel.height(forVisibleRows: 8, peeking: false)
        let peeking = SearchPanel.height(forVisibleRows: 8, peeking: true)
        XCTAssertEqual(peeking - plain, SearchPanel.peekHeight)
        XCTAssertGreaterThan(SearchPanel.peekHeight, 8, "the sliver must be big enough to read as a cut-off row")
        XCTAssertLessThan(SearchPanel.peekHeight, SearchPanel.rowHeight, "a peek is a fraction of a row, not a whole one")
    }

    /// `rowsThatFit` is the inverse of `height` and keeps `visibleRows` honest on short screens.
    func testRowsThatFitInvertsHeight() {
        for n in 0...12 {
            let h = SearchPanel.height(forVisibleRows: n)
            XCTAssertEqual(SearchPanel.rowsThatFit(in: h), n, "round trip failed for \(n) rows")
        }
        XCTAssertEqual(SearchPanel.rowsThatFit(in: 0), 0, "a zero-height screen fits no rows (and must not go negative)")
    }

    // MARK: Row model

    func testPanelRowsForResults() {
        let r = SearchResponse(query: "x", rows: [row("A", path: "/A", kind: .app)], generation: 1, requestId: 1,
                               elapsed: 0, totalMatches: 1, mode: .search)
        XCTAssertEqual(SearchPanel.panelRows(for: r, hint: "hint").count, 1)
        XCTAssertNotNil(SearchPanel.panelRows(for: r, hint: nil).first?.result)
    }

    /// A search that found nothing shows one dimmed, non-selectable "No matches" row.
    func testPanelRowsNoMatches() {
        let r = SearchResponse(query: "zzzq", rows: [], generation: 1, requestId: 1, elapsed: 0, totalMatches: 0, mode: .search)
        let rows = SearchPanel.panelRows(for: r, hint: "hint")
        XCTAssertEqual(rows, [.empty(query: "zzzq")])
        XCTAssertFalse(rows[0].isSelectable, "the empty-state row must not be selectable — Enter must not open it")
        XCTAssertNil(rows[0].result)
    }

    /// A whitespace-only query is not a failed search; it collapses instead of claiming "No matches".
    func testWhitespaceQueryProducesNoEmptyStateRow() {
        let r = SearchResponse(query: "   ", rows: [], generation: 1, requestId: 1, elapsed: 0, totalMatches: 0, mode: .search)
        XCTAssertTrue(SearchPanel.panelRows(for: r, hint: nil).isEmpty)
    }

    /// Empty query with no recents → the hint row; with `hint: nil` (recents disabled) → nothing.
    func testPanelRowsEmptyQuery() {
        let r = SearchResponse(query: "", rows: [], generation: 1, requestId: 1, elapsed: 0, totalMatches: 0, mode: .empty)
        XCTAssertEqual(SearchPanel.panelRows(for: r, hint: "H"), [.hint("H")])
        XCTAssertTrue(SearchPanel.panelRows(for: r, hint: nil).isEmpty)
        XCTAssertFalse(PanelRow.hint("H").isSelectable)
    }

    func testHintMentionsTheConfiguredHotkey() {
        let t = SearchPanel.hintText(hotkeyDisplay: "⌃⌥Space")
        XCTAssertTrue(t.contains("⌃⌥Space"), "the hint must advertise the hotkey actually in use: \(t)")
        XCTAssertTrue(t.contains("↩"))
    }

    // MARK: Badges

    func testBadgeText() {
        XCTAssertEqual(ResultCellView.badgeText(for: row("Safari", path: "/Applications/Safari.app", kind: .app)), "APP")
        XCTAssertEqual(ResultCellView.badgeText(for: row("docs", path: "/x/docs", kind: .folder)), "FOLDER")
        XCTAssertEqual(ResultCellView.badgeText(for: row("a.pdf", path: "/x/a.pdf", kind: .document)), "PDF")
        XCTAssertEqual(ResultCellView.badgeText(for: row("Makefile", path: "/x/Makefile", kind: .other)), "")
    }

    /// A dot in the middle of a name is not a file type — an unbounded badge would swallow the row.
    func testBadgeIgnoresLongPseudoExtensions() {
        XCTAssertEqual(ResultCellView.badgeText(for: row("report.final draft", path: "/x/y", kind: .document)), "")
        XCTAssertEqual(ResultCellView.badgeText(for: row("v1.2.3-candidate", path: "/x/y", kind: .other)), "")
        // Real extensions of a sane length still show.
        XCTAssertEqual(ResultCellView.badgeText(for: row("x.swift", path: "/x/x.swift", kind: .code)), "SWIFT")
    }

    // MARK: Tab autocomplete

    func testAutocompleteCompletesAFolderWithATrailingSlash() {
        let r = row("docs", path: "/Users/me/docs", kind: .folder)
        let t = SearchPanel.autocompleteTarget(for: r, query: "doc", inPathMode: false, home: "/Users/me", isDirectory: { _ in true })
        XCTAssertEqual(t, "~/docs/", "Tab on a folder enters it, abbreviating $HOME")
    }

    /// Tab on a plain file in normal mode has nothing to complete.
    func testAutocompleteIgnoresFilesOutsidePathMode() {
        let r = row("a.pdf", path: "/Users/me/a.pdf", kind: .document)
        XCTAssertNil(SearchPanel.autocompleteTarget(for: r, query: "a.p", inPathMode: false, home: "/Users/me", isDirectory: { _ in false }))
    }

    /// An absolute query keeps absolute paths — only a `~`-style query gets the abbreviation.
    func testAutocompleteKeepsAbsoluteQueriesAbsolute() {
        let r = row("docs", path: "/Users/me/docs", kind: .folder)
        XCTAssertEqual(SearchPanel.autocompleteTarget(for: r, query: "/Users/me/do", inPathMode: true, home: "/Users/me", isDirectory: { _ in true }),
                       "/Users/me/docs/")
    }

    func testAbbreviateHome() {
        XCTAssertEqual(SearchPanel.abbreviateHome("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(SearchPanel.abbreviateHome("/Users/me/x/y", home: "/Users/me"), "~/x/y")
        XCTAssertEqual(SearchPanel.abbreviateHome("/opt/local", home: "/Users/me"), "/opt/local")
        // A different user's home must not be rewritten.
        XCTAssertEqual(SearchPanel.abbreviateHome("/Users/meredith/x", home: "/Users/me"), "/Users/meredith/x")
    }

    // MARK: Group separator

    /// The hairline marks every app↔file boundary, including the one where `Ranking.group` backfills
    /// leftover apps after the file group (much more likely now that the pool is 40 rows).
    func testSeparatorMarksBothGroupBoundaries() {
        let app = PanelRow.result(row("A", path: "/A.app", kind: .app))
        let file = PanelRow.result(row("f", path: "/f", kind: .document))
        let rows = [app, app, file, file, app]
        XCTAssertFalse(ResultsController.needsSeparator(rows, at: 0))
        XCTAssertFalse(ResultsController.needsSeparator(rows, at: 1))
        XCTAssertTrue(ResultsController.needsSeparator(rows, at: 2), "app → file boundary")
        XCTAssertFalse(ResultsController.needsSeparator(rows, at: 3))
        XCTAssertTrue(ResultsController.needsSeparator(rows, at: 4), "file → backfilled app boundary")
    }

    func testSeparatorAbsentInSingleGroupLists(){
        let app = PanelRow.result(row("A", path: "/A.app", kind: .app))
        let file = PanelRow.result(row("f", path: "/f", kind: .document))
        for rows in [[app, app, app], [file, file, file]] {
            for i in rows.indices { XCTAssertFalse(ResultsController.needsSeparator(rows, at: i)) }
        }
    }

    // MARK: Empty model / input methods

    /// Clearing the panel installs an empty table model. Scrolling row zero in that state is an invalid
    /// AppKit operation on some older macOS releases, so this must remain a safe, repeatable no-op.
    func testEmptyResultsCanBeInstalledRepeatedly() {
        let controller = ResultsController()
        controller.setRows([])
        controller.setRows([])
        XCTAssertEqual(controller.rowCount, 0)
        XCTAssertEqual(controller.table.numberOfRows, 0)
        XCTAssertEqual(controller.table.selectedRow, -1)
    }

    /// Korean and other input methods temporarily keep "marked" composition text in the shared field
    /// editor. Programmatic clearing (panel hide, autocomplete) must unmark it before replacing the string.
    func testSetTextEndsMarkedKoreanCompositionBeforeClearing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = QueryField()
        field.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        field.setText("")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(field.stringValue, "")
    }

    func testResignAndKeyPoliciesPreserveIMEInput() {
        XCTAssertTrue(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                        hasMarkedText: false, modifiers: []))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hasMarkedText: true, modifiers: []))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hasMarkedText: false, modifiers: [.control]))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: true,
                                                         hasMarkedText: false, modifiers: []))

        XCTAssertTrue(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: false))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: true))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: false,
                                                     modifiers: [.control]))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Delete), hasMarkedText: false))
    }
}

/// The states the panel shows when it has no results to show: indexing, no-matches, hint.
final class EmptyStateTests: XCTestCase {
    private func response(_ q: String, mode: QueryMode) -> SearchResponse {
        SearchResponse(query: q, rows: [], generation: 1, requestId: 1, elapsed: 0, totalMatches: 0, mode: mode)
    }

    /// During the first crawl, an empty result set means "not indexed yet" — saying "No matches" is a
    /// lie the user cannot act on, and makes a working app look broken.
    func testIndexingNoteReplacesNoMatches() {
        let r = response("budget", mode: .search)
        let rows = SearchPanel.panelRows(for: r, hint: "hint", indexing: "Indexing… 12,000 files so far")
        XCTAssertEqual(rows, [.hint("Indexing… 12,000 files so far")])
        // Once indexing finishes, the honest empty state comes back.
        XCTAssertEqual(SearchPanel.panelRows(for: r, hint: "hint", indexing: nil), [.empty(query: "budget")])
    }

    func testIndexingNoteAlsoWinsOnTheEmptyQuery() {
        let r = response("", mode: .empty)
        XCTAssertEqual(SearchPanel.panelRows(for: r, hint: "hint", indexing: "Indexing…"), [.hint("Indexing…")])
    }

    /// The note is derived from the coordinator's phase and disappears when the index is ready.
    func testIndexingNoteForEachPhase() {
        var s = IndexStatus()
        s.phase = .idle
        XCTAssertNil(AppDelegate.indexingNote(for: s), "a ready index must not nag")
        s.phase = .scanningApps
        XCTAssertNotNil(AppDelegate.indexingNote(for: s))
        s.phase = .crawling(progress: 12_000)
        let crawling = AppDelegate.indexingNote(for: s)
        XCTAssertNotNil(crawling)
        XCTAssertTrue(crawling!.contains("12,000"), "show real progress, not a spinner: \(crawling!)")
        s.phase = .crawling(progress: 0)
        XCTAssertNotNil(AppDelegate.indexingNote(for: s))
        s.phase = .failed("disk full")
        XCTAssertTrue(AppDelegate.indexingNote(for: s)?.contains("disk full") == true,
                      "a failure must surface its reason, not pretend to still be indexing")
    }
}
