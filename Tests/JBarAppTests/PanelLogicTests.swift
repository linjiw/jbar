import XCTest
import Carbon.HIToolbox
import JBarActions
import JBarCore
@testable import JBarApp

/// Pure UI logic — panel geometry, row modelling, badges, Tab autocomplete. Everything here runs
/// headless (no window is created), which is what makes the AppKit layer testable at all: `JBarApp`
/// is a library target precisely so these can be reached.
@MainActor
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

    /// Every supported configuration drives height, page movement and overflow from the same value.
    func testLayoutMetricsForSupportedVisibleRowConfigurations() {
        for configured in [1, 8, 12, 20] {
            let full = PanelLayoutMetrics(configuredVisibleRows: configured, rowCount: configured)
            XCTAssertEqual(full.configuredVisibleRows, configured)
            XCTAssertEqual(full.effectiveVisibleRows, configured)
            XCTAssertEqual(full.pageStride, configured)
            XCTAssertEqual(full.visibleRowCount, configured)
            XCTAssertFalse(full.hasOverflow)
            XCTAssertFalse(full.showsPeek)
            XCTAssertEqual(full.panelHeight, SearchPanel.height(forVisibleRows: configured))

            let overflowing = PanelLayoutMetrics(configuredVisibleRows: configured,
                                                 rowCount: configured + 5)
            XCTAssertEqual(overflowing.effectiveVisibleRows, configured)
            XCTAssertEqual(overflowing.pageStride, configured)
            XCTAssertTrue(overflowing.hasOverflow)
            XCTAssertTrue(overflowing.showsPeek)
            XCTAssertEqual(overflowing.panelHeight,
                           SearchPanel.height(forVisibleRows: configured, peeking: true))
        }
    }

    /// A screen that can display 11 full rows plus the peek must override a configured 20 everywhere,
    /// not merely clip the window while the table and Page Down continue believing 20 are visible.
    func testShortScreenCapacityIsTheEffectiveVisibleRowSourceOfTruth() {
        let shortScreenHeight = SearchPanel.height(forVisibleRows: 11, peeking: true)
        let metrics = PanelLayoutMetrics(configuredVisibleRows: 20, rowCount: 40,
                                         maximumPanelHeight: shortScreenHeight)
        XCTAssertEqual(metrics.configuredVisibleRows, 20)
        XCTAssertEqual(metrics.screenCapacity, 11)
        XCTAssertEqual(metrics.effectiveVisibleRows, 11)
        XCTAssertEqual(metrics.pageStride, 11)
        XCTAssertEqual(metrics.visibleRowCount, 11)
        XCTAssertTrue(metrics.hasOverflow)
        XCTAssertTrue(metrics.showsPeek)
        XCTAssertEqual(metrics.panelHeight, shortScreenHeight)
    }

    /// Exercise the real NSTableView selection/scroll path while changing the effective config live.
    func testTablePageMovementAndConfigReflowUseEffectiveRows() {
        _ = NSApplication.shared
        let controller = ResultsController()
        let rows = (0..<40).map { index in
            PanelRow.result(row("item-\(index)", path: "/item-\(index)", kind: .document))
        }
        controller.setRows(rows)

        let eight = PanelLayoutMetrics(configuredVisibleRows: 8, rowCount: rows.count)
        controller.applyLayout(eight)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 500,
                                             height: eight.panelHeight - SearchPanel.inputRowHeight
                                                 - SearchPanel.bottomPadding)
        controller.layout(width: 500)
        controller.moveSelectionByPage(1)
        XCTAssertEqual(controller.maxVisible, 8)
        XCTAssertEqual(controller.pageStride, 8)
        XCTAssertEqual(controller.table.selectedRow, 8)

        let three = PanelLayoutMetrics(configuredVisibleRows: 3, rowCount: rows.count)
        controller.applyLayout(three)
        controller.scrollView.frame.size.height = three.panelHeight - SearchPanel.inputRowHeight
            - SearchPanel.bottomPadding
        controller.layout(width: 500)
        XCTAssertEqual(controller.table.selectedRow, 8, "live reflow must preserve the valid selection")
        XCTAssertEqual(controller.maxVisible, 3)
        XCTAssertEqual(controller.pageStride, 3)

        controller.moveSelectionByPage(1)
        XCTAssertEqual(controller.table.selectedRow, 11, "Page Down must immediately adopt the new stride")
        controller.scrollView.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.table.visibleRect.intersects(controller.table.rect(ofRow: 11)),
                      "the selected row must remain in the real table viewport after reflow")

        for _ in 0..<20 { controller.moveSelectionByPage(1) }
        XCTAssertEqual(controller.table.selectedRow, 39, "page movement clamps at the final row")
        controller.moveSelectionByPage(1)
        XCTAssertEqual(controller.table.selectedRow, 39)
        controller.moveSelectionByPage(-1)
        XCTAssertEqual(controller.table.selectedRow, 36)
    }

    // MARK: Row model

    func testPanelRowsForResults() {
        let r = SearchResponse(query: "x", rows: [row("A", path: "/A", kind: .app)], generation: 1, requestId: 1,
                               elapsed: 0, totalMatches: 1, mode: .search)
        XCTAssertEqual(SearchPanel.panelRows(for: r, hint: "hint").count, 1)
        XCTAssertNotNil(SearchPanel.panelRows(for: r, hint: nil).first?.result)
    }

    func testPathModeMakesBoundedResultCompletenessVisible() {
        let kept = [row("A", path: "/A", kind: .document), row("B", path: "/B", kind: .document)]
        let truncated = SearchResponse(query: "/", rows: kept, generation: 1, requestId: 1,
                                       elapsed: 0, totalMatches: 19_999, mode: .path(base: "/", filter: ""))
        XCTAssertEqual(SearchPanel.pathBadgeText(for: truncated), "PATH · 2/19999")
        XCTAssertEqual(SearchPanel.pathBadgeAccessibilityLabel(for: truncated),
                       "Path mode; showing 2 of 19999 matches")

        let complete = SearchResponse(query: "/", rows: kept, generation: 1, requestId: 2,
                                      elapsed: 0, totalMatches: 2, mode: .path(base: "/", filter: ""))
        XCTAssertEqual(SearchPanel.pathBadgeText(for: complete), "PATH")
        XCTAssertEqual(SearchPanel.pathBadgeAccessibilityLabel(for: complete),
                       "Path mode; all 2 matches shown")
        XCTAssertNil(SearchPanel.pathBadgeText(for: SearchResponse(query: "a", rows: kept,
                                                                    generation: 1, requestId: 3, elapsed: 0,
                                                                    totalMatches: 2, mode: .search)))
    }

    func testUnreadablePathDoesNotMasqueradeAsNoMatches() {
        let unavailable = SearchResponse(query: "/private/locked", rows: [], generation: 1, requestId: 1,
                                         elapsed: 0, totalMatches: 0,
                                         mode: .path(base: "/private/locked", filter: ""),
                                         totalMatchesIsComplete: false)
        XCTAssertEqual(SearchPanel.pathBadgeText(for: unavailable), "PATH · ?")
        XCTAssertEqual(SearchPanel.pathBadgeAccessibilityLabel(for: unavailable),
                       "Path mode; result count unavailable")
        XCTAssertEqual(SearchPanel.panelRows(for: unavailable, hint: nil),
                       [.hint("Folder scan incomplete")])
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

    func testAppliedResultLogSummaryNeverContainsTheRawQuery() {
        let secret = "Acquisition Target – confidential-token-123"
        let response = SearchResponse(query: secret, rows: [row("A", path: "/A", kind: .document)],
                                      generation: 1, requestId: 42, elapsed: 0.0129,
                                      totalMatches: 1, mode: .search)
        let summary = SearchPanel.appliedLogSummary(for: response)
        XCTAssertEqual(summary, "applied 1 rows in 12 ms (id=42)")
        XCTAssertFalse(summary.contains(secret))
        XCTAssertFalse(summary.contains("confidential-token-123"))
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
        XCTAssertEqual(SearchPanel.abbreviateHome("/\u{301}目录", home: "/"), "~/\u{301}目录")
        XCTAssertEqual(SearchPanel.abbreviateHome("/Users/Cafe\u{301}/文件", home: "/Users/Café"), "~/文件")
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

    /// Delete is intentionally owned by AppKit's field editor, not by the panel. Exercise the real
    /// `NSTextInputContext` command path with Latin, Chinese, Korean (NFC and decomposed Jamo), and an
    /// extended emoji grapheme so a key-code regression cannot turn Delete into close/crash logic.
    func testPhysicalDeleteUsesStandardFieldEditorAndRemovesOneGrapheme() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = QueryField()
        field.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: UInt16(kVK_Delete)
        ))

        let cases: [(input: String, expected: String)] = [
            ("abc", "ab"),
            ("中文", "中"),
            ("한글", "한"),
            ("한", ""),
            ("👨‍👩‍👧‍👦", ""),
        ]
        for sample in cases {
            field.setText(sample.input)
            editor.setSelectedRange(NSRange(location: (sample.input as NSString).length, length: 0))
            editor.interpretKeyEvents([delete])
            XCTAssertEqual(editor.string, sample.expected, "Delete must remove one grapheme from \(sample.input)")
            XCTAssertFalse(editor.hasMarkedText())
        }
    }

    func testDeleteDuringChineseMarkedTextStaysInsideInputContext() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = QueryField()
        field.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false,
            keyCode: UInt16(kVK_Delete)
        ))

        editor.interpretKeyEvents([delete])

        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: delete.keyCode,
                                                      hasMarkedText: editor.hasMarkedText()))
        XCTAssertFalse(editor.hasMarkedText(), "the input context may cancel composition, but the panel must not own Delete")
    }

    func testResignAndKeyPoliciesPreserveIMEInput() {
        XCTAssertTrue(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                        hadMarkedText: false, hasMarkedText: false,
                                                        modifiers: []))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hadMarkedText: false, hasMarkedText: true,
                                                         modifiers: []))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hadMarkedText: true, hasMarkedText: false,
                                                         modifiers: []),
                       "marked text observed synchronously must survive disappearing before the deferred check")
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hadMarkedText: false, hasMarkedText: false,
                                                         modifiers: [.control]))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: true,
                                                         hadMarkedText: false, hasMarkedText: false,
                                                         modifiers: []))
        XCTAssertFalse(SearchPanel.shouldHideAfterResign(isVisible: true, isKeyWindow: false,
                                                         hadMarkedText: false, hasMarkedText: false,
                                                         actionSubmissionInFlight: true,
                                                         modifiers: []),
                       "opening the OAuth browser must not hide the panel and kill its localhost callback")

        XCTAssertTrue(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: false))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: true))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Escape), hasMarkedText: false,
                                                     modifiers: [.control]))
        XCTAssertFalse(SearchPanel.shouldCloseForKey(keyCode: UInt16(kVK_Delete), hasMarkedText: false))
    }

    /// The number-row shortcut is based on hardware position, not the character emitted by the
    /// current layout (for example, the physical 1 key can emit `&` on AZERTY).
    func testCommandResultOrdinalsUsePhysicalANSIDigitKeys() {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]
        for (ordinal, key) in keys.enumerated() {
            XCTAssertEqual(SearchPanel.resultOrdinal(forCommandKeyCode: UInt16(key)), ordinal)
        }
        XCTAssertNil(SearchPanel.resultOrdinal(forCommandKeyCode: UInt16(kVK_ANSI_0)))
        XCTAssertNil(SearchPanel.resultOrdinal(forCommandKeyCode: UInt16(kVK_ANSI_9)))
        XCTAssertNil(SearchPanel.resultOrdinal(forCommandKeyCode: UInt16(kVK_ANSI_Keypad1)))
    }

    func testMarkedTextReturnsCommandShortcutsAndDelegateCommandsToAppKit() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let field = QueryField()
        field.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "fixture must model a live Chinese IME composition")
        XCTAssertFalse(SearchPanel.shouldInterceptCommandShortcut(hasMarkedText: editor.hasMarkedText(),
                                                                  modifiers: [.command]))
        XCTAssertFalse(SearchPanel.shouldHandleFieldEditorCommand(hasMarkedText: editor.hasMarkedText()))

        let panel = SearchPanel(provider: DemoSearchProvider(), launcher: AppLauncher(),
                                settings: SearchPanel.Settings())
        let commands = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.scrollPageUp(_:)),
            #selector(NSResponder.pageUp(_:)),
            #selector(NSResponder.scrollPageDown(_:)),
            #selector(NSResponder.pageDown(_:)),
            #selector(NSResponder.cancelOperation(_:)),
        ]
        for command in commands {
            XCTAssertFalse(panel.control(field, textView: editor, doCommandBy: command),
                           "marked composition must retain \(NSStringFromSelector(command))")
        }

        editor.unmarkText()
        XCTAssertTrue(SearchPanel.shouldInterceptCommandShortcut(hasMarkedText: editor.hasMarkedText(),
                                                                 modifiers: [.command]))
        XCTAssertTrue(SearchPanel.shouldHandleFieldEditorCommand(hasMarkedText: editor.hasMarkedText()))
        XCTAssertFalse(SearchPanel.shouldInterceptCommandShortcut(hasMarkedText: false,
                                                                  modifiers: [.command, .control]))
        XCTAssertFalse(SearchPanel.shouldInterceptCommandShortcut(hasMarkedText: false,
                                                                  modifiers: [.command, .option]))
    }
}

final class CLISafetyTests: XCTestCase {
    func testBenchmarkIterationBounds() {
        XCTAssertEqual(CLI.benchmarkIterations(nil), 200)
        XCTAssertEqual(CLI.benchmarkIterations("1"), 1)
        XCTAssertEqual(CLI.benchmarkIterations(String(SafetyLimits.maxBenchmarkIterations)),
                       SafetyLimits.maxBenchmarkIterations)
        for invalid in ["", "0", "-1", "10001", "9223372036854775807", "not-a-number"] {
            XCTAssertNil(CLI.benchmarkIterations(invalid), invalid)
        }
        XCTAssertEqual(Benchmark.boundedIterations(Int.min), 1)
        XCTAssertEqual(Benchmark.boundedIterations(Int.max), SafetyLimits.maxBenchmarkIterations)
    }
}

/// A provider whose non-empty response is released explicitly, so the panel's stale-response policy
/// can be tested without timing sleeps.
private actor GatedSearchProvider: SearchProviding {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse {
        if raw.isEmpty {
            return SearchResponse(query: raw, rows: [], generation: 1, requestId: 2,
                                  elapsed: 0, totalMatches: 0, mode: .empty)
        }
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
        let stale = ResultRow(itemIndex: 0, name: "stale-secret", path: "/stale-secret",
                              parentDisplay: "/", kind: .document, matchedByteOffsets: [],
                              score: 1, tier: Tier.other)
        return SearchResponse(query: raw, rows: [stale], generation: 1, requestId: 1,
                              elapsed: 0, totalMatches: 1, mode: .search)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseStaleResponse() { release?.resume(); release = nil }
}

extension PanelGeometryTests {
    @MainActor
    func testDisablingRecentsCancelsAndRejectsAnOlderSearchResponse() async {
        let provider = GatedSearchProvider()
        var settings = SearchPanel.Settings()
        settings.showRecentsOnEmpty = false
        let panel = SearchPanel(provider: provider, launcher: AppLauncher(), settings: settings)

        panel.setQuery("old secret")
        await provider.waitUntilStarted()
        panel.setQuery("")
        XCTAssertEqual(panel.displayedRows, [.hint(SearchPanel.hintText(hotkeyDisplay: settings.hotkeyDisplay))])

        await provider.releaseStaleResponse()
        // Let the released provider task enqueue and execute its MainActor continuation.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(panel.displayedRows, [.hint(SearchPanel.hintText(hotkeyDisplay: settings.hotkeyDisplay))],
                       "a response superseded by the empty-query policy must never repaint stale results")
    }

    func testActionModeDoesNotSubmitWhileTypingButEnterSubmitsExactlyOnce() async {
        let handler = RecordingActionHandler()
        let panel = SearchPanel(provider: DemoSearchProvider(), launcher: AppLauncher(),
                                settings: SearchPanel.Settings(), actionHandler: handler)

        var prompt = "?"
        for _ in 0..<100 {
            prompt.append("x")
            panel.setQuery(prompt)
        }
        let typedSubmissionCount = await handler.submissionCount()
        XCTAssertEqual(typedSubmissionCount, 0,
                       "editing an Ask prompt must not start an action")
        XCTAssertEqual(panel.displayedRows,
                       SearchPanel.actionDraftRows(for: .ask(prompt: String(repeating: "x", count: 100))))

        panel.submitCurrentIntentForTesting()
        await handler.waitUntilSubmitted()
        for _ in 0..<4 { await Task.yield() }
        let completedSubmissionCount = await handler.submissionCount()
        let submittedIntents = await handler.submissions()
        XCTAssertEqual(completedSubmissionCount, 1)
        XCTAssertEqual(submittedIntents, [.ask(prompt: String(repeating: "x", count: 100))])
        XCTAssertTrue(panel.displayedRows.contains {
            if case .action(let message, _) = $0 { return message.contains("Local test answer") }
            return false
        }, "the completed action must replace the draft with its action result")
    }

    func testFirstEscapeClearsAnActionDraftWithoutSubmittingIt() async {
        let handler = RecordingActionHandler()
        let panel = SearchPanel(provider: DemoSearchProvider(), launcher: AppLauncher(),
                                settings: SearchPanel.Settings(), actionHandler: handler)
        panel.setQuery("? find budget PDFs")

        panel.clearDraftOrHideForTesting()

        XCTAssertEqual(panel.query, "")
        let submissionCount = await handler.submissionCount()
        XCTAssertEqual(submissionCount, 0)
    }

    func testActionAnswerWrapsIntoReadableScrollableRows() {
        let result = PaletteActionResult(kind: .answer,
                                         text: "One short paragraph that is deliberately long enough to wrap into multiple compact answer rows in the launcher panel without losing the remaining words.")
        let rows = SearchPanel.actionResultRows(for: .ask(prompt: "question"), result: result)
        XCTAssertGreaterThan(rows.count, 2)
        XCTAssertEqual(rows.first, .action(message: "ASK · Codex · GPT-5.6 Luna", symbol: "text.bubble"))
        let rendered = rows.dropFirst().compactMap { row -> String? in
            if case .action(let message, _) = row { return message }
            return nil
        }.joined(separator: " ")
        XCTAssertTrue(rendered.contains("remaining words"))
    }

    func testCodexAskOpensReadOnlyAssistantWithTheSubmittedPrompt() async {
        let recorder = ChatPresentationRecorder()
        let handler = CodexActionHandler(presentAssistant: { prompt in
            recorder.prompts.append(prompt)
            return true
        })

        let result = await handler.submit(.ask(prompt: "remember ORBIT"))

        XCTAssertEqual(result.kind, .openedSession)
        XCTAssertEqual(recorder.prompts, ["remember ORBIT"])
    }

    func testDeveloperAgentHasASeparateExplicitPresentationBoundary() async {
        let recorder = ChatPresentationRecorder()
        let handler = CodexActionHandler(presentDeveloperAgent: { prompt in
            recorder.prompts.append(prompt)
            return true
        })

        let result = await handler.submit(.shell(command: "review the dirty worktree"))

        XCTAssertEqual(result.kind, .openedSession)
        XCTAssertEqual(recorder.prompts, ["review the dirty worktree"])
    }

    func testOrganizeHasASeparateGlobalCopyReviewPresentationBoundary() async {
        let recorder = ChatPresentationRecorder()
        let handler = CodexActionHandler(presentOrganize: { instruction in
            recorder.prompts.append(instruction)
            return true
        })

        let result = await handler.submit(.organize(task: "group receipts by month"))

        XCTAssertEqual(result.kind, .openedSession)
        XCTAssertEqual(result.text, "Opened global Copy Organize review.")
        XCTAssertEqual(recorder.prompts, ["group receipts by month"])
    }

    func testOrganizeFailsClosedWhenReviewSurfaceIsUnavailable() async {
        let result = await CodexActionHandler().submit(.organize(task: "move everything"))
        XCTAssertEqual(result.kind, .error)
        XCTAssertTrue(result.text.contains("unavailable"))
    }

    func testAssistantPlanMapsToNativeMetadataRequestWithoutPromptOrScopePath() {
        let plan = SearchPlan(scopeID: .indexedFiles, nameTerms: ["budget"],
                              extensions: ["pdf"], kinds: [.document],
                              modifiedAfter: Date(timeIntervalSinceReferenceDate: 100),
                              modifiedBefore: Date(timeIntervalSinceReferenceDate: 200),
                              minimumSizeBytes: 1_024, maximumSizeBytes: 4_096,
                              sort: .modifiedDescending, limit: 3)

        let request = AssistedSearchRequest(searchPlan: plan)

        XCTAssertEqual(request.nameTerms, ["budget"])
        XCTAssertEqual(request.extensions, ["pdf"])
        XCTAssertEqual(request.kinds, [.document])
        XCTAssertEqual(request.minimumSizeBytes, 1_024)
        XCTAssertEqual(request.maximumSizeBytes, 4_096)
        XCTAssertEqual(request.sort, .modifiedDescending)
        XCTAssertEqual(request.limit, 3)
    }

    func testCopyOrganizeSearchesAllEligibleFileKindsAtTheFullPreviewLimit() throws {
        let plan = SearchPlan(scopeID: .indexedFiles, nameTerms: ["receipt"],
                              extensions: ["pdf"], kinds: [], limit: 2)
        let request = try OrganizeWindowController.copySearchRequest(for: plan)

        XCTAssertEqual(request.limit, AssistedSearchRequest.maximumResults)
        XCTAssertFalse(request.kinds.contains(.app))
        XCTAssertFalse(request.kinds.contains(.folder))
        XCTAssertFalse(request.kinds.contains(.packageInternal))
        XCTAssertEqual(request.kinds,
                       [.document, .image, .video, .audio, .code, .archive, .other])
    }

    func testCopyOrganizeRejectsAnAppsOnlyPlan() {
        let plan = SearchPlan(scopeID: .indexedFiles, nameTerms: ["Safari"],
                              extensions: [], kinds: [.app])
        XCTAssertThrowsError(try OrganizeWindowController.copySearchRequest(for: plan))
    }

    func testCopyOrganizeRejectsIncompleteAndTruncatedGlobalSearches() throws {
        let row = ResultRow(itemIndex: 0, name: "receipt.pdf", path: "/receipt.pdf",
                            parentDisplay: "/", kind: .document,
                            matchedByteOffsets: [], score: 1, tier: 2)
        let complete = AssistedSearchResponse(rows: [row], totalMatches: 1,
                                              totalMatchesIsComplete: true, scannedItems: 100,
                                              inspectedSizes: 0, generation: 1)
        XCTAssertEqual(try OrganizeWindowController.completeCopyRows(from: complete), [row])

        let incomplete = AssistedSearchResponse(rows: [row], totalMatches: 1,
                                                totalMatchesIsComplete: false, scannedItems: 100,
                                                inspectedSizes: 0, generation: 1)
        XCTAssertThrowsError(try OrganizeWindowController.completeCopyRows(from: incomplete))

        let truncated = AssistedSearchResponse(rows: [row], totalMatches: 41,
                                               totalMatchesIsComplete: true, scannedItems: 100,
                                               inspectedSizes: 0, generation: 1)
        XCTAssertThrowsError(try OrganizeWindowController.completeCopyRows(from: truncated))
    }

    func testAssistantCanOptIntoSelectFirstWhileLauncherRetainsSingleClickOpen() {
        let results = ResultsController()
        XCTAssertTrue(results.opensOnSingleClick)
        results.opensOnSingleClick = false
        XCTAssertFalse(results.opensOnSingleClick)
    }

    func testCopyOrganizeUsesReadableSourceTailsAndCorrectCountGrammar() {
        XCTAssertEqual(OrganizeWindowController.sourceDisplay(
            parent: "~/jbar/.build/jbar-e2e/fixture/Desktop", name: "receipt.pdf"
        ), "…/fixture/Desktop/receipt.pdf")
        XCTAssertEqual(OrganizeWindowController.counted(1, singular: "file", plural: "files"),
                       "1 file")
        XCTAssertEqual(OrganizeWindowController.counted(2, singular: "file", plural: "files"),
                       "2 files")
    }

    func testAssistantCopyDescribesPlanningAndLocalCompleteness() {
        XCTAssertEqual(AssistantWindowController.progressText(.generatingAnswer),
                       "Creating a read-only SearchPlan…")
        let row = ResultRow(itemIndex: 0, name: "budget.pdf", path: "/budget.pdf",
                            parentDisplay: "/", kind: .document,
                            matchedByteOffsets: [], score: 1, tier: 2)
        let complete = AssistedSearchResponse(rows: [row], totalMatches: 1,
                                              totalMatchesIsComplete: true, scannedItems: 10,
                                              inspectedSizes: 0, generation: 1)
        XCTAssertEqual(AssistantWindowController.summaryText(for: complete),
                       "Found 1 result in the local index.")
        let capped = AssistedSearchResponse(rows: [row], totalMatches: 12,
                                            totalMatchesIsComplete: true, scannedItems: 20,
                                            inspectedSizes: 0, generation: 1)
        XCTAssertEqual(AssistantWindowController.summaryText(for: capped),
                       "Found 12 results in the local index; showing the first 1.")
        let incomplete = AssistedSearchResponse(rows: [row], totalMatches: 1,
                                                totalMatchesIsComplete: false, scannedItems: 10,
                                                inspectedSizes: 0, generation: 1)
        XCTAssertTrue(AssistantWindowController.summaryText(for: incomplete).contains("incomplete"))
    }

    func testAssistantWaitsForACompleteIndexBeforeStartingCodex() {
        var status = IndexStatus()
        XCTAssertNotNil(IndexReadiness.waitMessage(for: status))

        status.phase = .crawling(progress: 136)
        status.itemCount = 136
        XCTAssertTrue(IndexReadiness.waitMessage(for: status)?.contains("136") == true)

        status.phase = .idle
        XCTAssertNil(IndexReadiness.waitMessage(for: status))

        status.hitItemCap = true
        XCTAssertTrue(IndexReadiness.waitMessage(for: status)?.contains("incomplete") == true)
        status.hitItemCap = false
        status.cappedDirs = ["private path not shown in UI"]
        let capped = IndexReadiness.waitMessage(for: status)
        XCTAssertTrue(capped?.contains("scan limit") == true)
        XCTAssertFalse(capped?.contains("private path") == true)
        status.cappedDirs = []
        status.deniedPaths = ["private path not shown in UI"]
        let denied = IndexReadiness.waitMessage(for: status)
        XCTAssertTrue(denied?.contains("could not read") == true)
        XCTAssertFalse(denied?.contains("private path") == true)
        status.deniedPaths = []

        status.unavailableRoots = ["private root not shown in UI"]
        let unavailable = IndexReadiness.waitMessage(for: status)
        XCTAssertTrue(unavailable?.contains("configured roots") == true)
        XCTAssertFalse(unavailable?.contains("private root") == true)
        status.unavailableRoots = []
        status.unsafeEntriesSkipped = 1
        XCTAssertTrue(IndexReadiness.waitMessage(for: status)?.contains("incomplete") == true)
        status.unsafeEntriesSkipped = 0

        status.phase = .failed("private diagnostic")
        let failed = IndexReadiness.waitMessage(for: status)
        XCTAssertTrue(failed?.contains("rebuild") == true)
        XCTAssertFalse(failed?.contains("private diagnostic") == true)
    }

    func testResultRowDrawingNeverConstructsNegativeGeometry() {
        XCTAssertNil(ResultRowView.selectionRect(in: .zero))
        XCTAssertNil(ResultRowView.selectionRect(in: NSRect(x: 0, y: 0, width: 15, height: 3)))
        XCTAssertNil(ResultRowView.separatorRect(in: .zero, isFlipped: false))
        XCTAssertNil(ResultRowView.separatorRect(in: NSRect(x: 0, y: 0, width: 31, height: 48),
                                                  isFlipped: true))

        XCTAssertEqual(ResultRowView.selectionRect(in: NSRect(x: 0, y: 0, width: 100, height: 48)),
                       NSRect(x: 8, y: 2, width: 84, height: 44))
        XCTAssertEqual(ResultRowView.separatorRect(in: NSRect(x: 0, y: 0, width: 100, height: 48),
                                                    isFlipped: false),
                       NSRect(x: 16, y: 47, width: 68, height: 1))
    }

    func testCodexChatTranscriptKeepsTurnOrderAndRoleLabels() {
        let messages = [
            CodexChatMessage(role: .system, text: "Private chat"),
            CodexChatMessage(role: .user, text: "Remember ORBIT"),
            CodexChatMessage(role: .tool, text: "~/jbar $ pwd\n/Users/example/jbar\n[exit 0]"),
            CodexChatMessage(role: .assistant, text: "ORBIT"),
        ]

        XCTAssertEqual(CodexChatTranscript.plainText(messages),
                       "JBAR\nPrivate chat\n\nYOU\nRemember ORBIT\n\nTERMINAL\n~/jbar $ pwd\n/Users/example/jbar\n[exit 0]\n\nCODEX · LUNA\nORBIT")
    }

    func testEmptyStreamingMessageHasVisibleThinkingState() {
        let message = CodexChatMessage(role: .assistant, text: "", isStreaming: true)
        XCTAssertEqual(CodexChatTranscript.plainText([message]), "CODEX · LUNA\nThinking…")
    }

    func testCodexChatProgressCopyIsBoundedAndNonSensitive() {
        XCTAssertEqual(CodexChatWindowController.progressText(.generatingAnswer),
                       "Codex is responding…")
        XCTAssertFalse(CodexChatWindowController.progressText(.checkingAccountAndSafety).contains("@"))
    }

    func testOAuthProgressExplainsBrowserAndCancellation() {
        let rows = SearchPanel.actionProgressRows(for: .ask(prompt: "question"),
                                                  progress: .waitingForChatGPTSignIn)
        let messages = rows.compactMap { row -> String? in
            if case .action(let message, _) = row { return message }
            return nil
        }
        XCTAssertTrue(messages.contains { $0.contains("browser") })
        XCTAssertTrue(messages.contains { $0.contains("localhost callback") })
        XCTAssertTrue(messages.contains { $0.contains("Esc cancels") })
    }

    func testActionProgressReplacesConnectingStateBeforeFinalResult() async {
        let handler = ProgressActionHandler()
        let panel = SearchPanel(provider: DemoSearchProvider(), launcher: AppLauncher(),
                                settings: SearchPanel.Settings(), actionHandler: handler)
        panel.setQuery("? question")
        panel.submitCurrentIntentForTesting()
        await handler.waitUntilProgressSent()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(panel.displayedRows,
                       SearchPanel.actionProgressRows(for: .ask(prompt: "question"),
                                                      progress: .waitingForChatGPTSignIn))
        await handler.release()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(panel.displayedRows.contains {
            if case .action(let message, _) = $0 { return message.contains("Finished after progress") }
            return false
        })
    }
}

@MainActor
private final class ChatPresentationRecorder {
    var prompts: [String] = []
}

private actor RecordingActionHandler: PaletteActionHandling {
    private var submitted: [PaletteIntent] = []
    private var submittedWaiters: [CheckedContinuation<Void, Never>] = []

    func submit(_ intent: PaletteIntent,
                progress: @escaping PaletteActionProgressHandler) async -> PaletteActionResult {
        submitted.append(intent)
        let waiters = submittedWaiters
        submittedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return PaletteActionResult(kind: .answer, text: "Local test answer")
    }

    func submissionCount() -> Int { submitted.count }
    func submissions() -> [PaletteIntent] { submitted }

    func waitUntilSubmitted() async {
        if !submitted.isEmpty { return }
        await withCheckedContinuation { submittedWaiters.append($0) }
    }
}

private actor ProgressActionHandler: PaletteActionHandling {
    private var progressSent = false
    private var progressWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func submit(_ intent: PaletteIntent,
                progress: @escaping PaletteActionProgressHandler) async -> PaletteActionResult {
        await progress(.waitingForChatGPTSignIn)
        progressSent = true
        let waiters = progressWaiters
        progressWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return PaletteActionResult(kind: .answer, text: "Finished after progress")
    }

    func waitUntilProgressSent() async {
        if progressSent { return }
        await withCheckedContinuation { progressWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
