import AppKit
import JBarCore

/// Single-column table that selects on hover and never takes keyboard focus (the query field keeps it).
final class ResultsTableView: NSTableView {
    /// Called with the row index under the mouse whenever the pointer moves over a row.
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    /// Screen point the pointer occupied when hover was last armed, or nil once the pointer has moved.
    ///
    /// Showing the panel — or replacing the rows on every keystroke — happens under a pointer that is
    /// usually sitting still somewhere over the list. AppKit still delivers `mouseMoved` in that case,
    /// which would select whatever row happened to land under the cursor and silently hijack the
    /// keyboard selection, so Return would open the wrong item. Hover therefore stays inert until the
    /// pointer genuinely moves.
    private var armedPoint: NSPoint?
    /// Distance in points the pointer must travel before hover selection takes over.
    private static let hoverSlop: CGFloat = 3

    /// Suppress hover selection until the pointer moves again.
    func armHover() { armedPoint = NSEvent.mouseLocation }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if let armed = armedPoint {
            let now = NSEvent.mouseLocation
            guard abs(now.x - armed.x) > Self.hoverSlop || abs(now.y - armed.y) > Self.hoverSlop else { return }
            armedPoint = nil
        }
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0 { onHover?(r) }
    }
}

/// Owns the scroll view + table and the row model; exposes selection movement and click handling.
/// Rows beyond `maxVisible` are reachable by scrolling (wheel/trackpad) and by moving the selection
/// past the last visible row — a search returns `Config.maxResults` (40) rows but shows 8 at a time.
final class ResultsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 48
    /// Default number of rows visible without scrolling; overridden per-panel from `Config.visibleRows`.
    static let defaultVisibleRows = 8
    /// Rows visible without scrolling. Clamped to a sane range so a bad config cannot produce a
    /// zero-height or screen-swallowing panel.
    var maxVisible: Int = defaultVisibleRows {
        didSet { maxVisible = min(max(1, maxVisible), 20) }
    }

    let scrollView = NSScrollView()
    let table = ResultsTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))

    /// Current rows (results and informational rows).
    private(set) var rows: [PanelRow] = []
    /// Called when the user clicks a result row.
    var onOpen: ((ResultRow) -> Void)?

    override init() {
        super.init()
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked(_:))
        table.onHover = { [weak self] r in self?.hover(r) }

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
    }

    // MARK: - Model

    /// Number of rows of any kind.
    var rowCount: Int { rows.count }
    /// Number of result rows.
    var resultCount: Int { rows.reduce(0) { $0 + ($1.isSelectable ? 1 : 0) } }
    /// Rows that should be visible without scrolling (0…`maxVisible`).
    var visibleRowCount: Int { min(rows.count, maxVisible) }
    /// True when there are more rows than fit on screen (the user can scroll for the rest).
    var hasHiddenRows: Bool { rows.count > maxVisible }

    /// Replace all rows, select the first result and scroll to the top.
    func setRows(_ newRows: [PanelRow]) {
        rows = newRows
        table.reloadData()
        table.armHover()
        if let first = rows.firstIndex(where: { $0.isSelectable }) {
            select(first)
        } else {
            table.deselectAll(nil)
        }
        table.scrollRowToVisible(0)
    }

    /// Currently selected result, if any.
    var selectedResult: ResultRow? {
        let i = table.selectedRow
        guard i >= 0, i < rows.count else { return nil }
        return rows[i].result
    }

    /// First result row (Enter with no selection opens this).
    var firstResult: ResultRow? { rows.lazy.compactMap { $0.result }.first }

    /// The `n`-th result (0-based), for ⌘1…⌘8.
    func result(atOrdinal n: Int) -> ResultRow? {
        var k = 0
        for r in rows {
            guard let res = r.result else { continue }
            if k == n { return res }
            k += 1
        }
        return nil
    }

    /// Move the selection by `delta` result rows. `wrap` = wrap around at the ends (↑/↓);
    /// otherwise clamp (PgUp/PgDn).
    func moveSelection(by delta: Int, wrap: Bool) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let pos = selectable.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : 0)
        var next = pos + delta
        if wrap {
            next = ((next % selectable.count) + selectable.count) % selectable.count
        } else {
            next = min(max(next, 0), selectable.count - 1)
        }
        select(selectable[next])
    }

    /// Select the first / last result row.
    func selectEdge(first: Bool) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard let i = first ? selectable.first : selectable.last else { return }
        select(i)
    }

    /// Suppress hover selection until the pointer moves (called when the panel is shown).
    func armHover() { table.armHover() }

    /// Resize the table to `width` (the scroll view frame is set by the panel).
    func layout(width: CGFloat) {
        column.width = width
        table.frame.size.width = width
        table.sizeLastColumnToFit()
    }

    private func select(_ i: Int) {
        guard i >= 0, i < rows.count, rows[i].isSelectable else { return }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func hover(_ i: Int) {
        guard i >= 0, i < rows.count, rows[i].isSelectable, table.selectedRow != i else { return }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
    }

    @objc private func tableClicked(_ sender: Any?) {
        let i = table.clickedRow
        guard i >= 0, i < rows.count, let r = rows[i].result else { return }
        onOpen?(r)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row >= 0 && row < rows.count && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("JBarRow")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? ResultRowView) ?? {
            let v = ResultRowView()
            v.identifier = id
            return v
        }()
        view.drawsTopSeparator = Self.needsSeparator(rows, at: row)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCellView.identifier, owner: self) as? ResultCellView)
            ?? ResultCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: Self.rowHeight))
        switch rows[row] {
        case .result(let r): cell.configure(with: r)
        case .empty(let q): cell.configure(message: "No matches for “\(q)”", symbol: "magnifyingglass")
        case .hint(let text): cell.configure(message: text, symbol: "keyboard")
        case .loading: cell.configure(message: "Loading…", symbol: "hourglass")
        }
        return cell
    }

    /// A hairline is drawn above the first non-app result that follows an app result.
    static func needsSeparator(_ rows: [PanelRow], at index: Int) -> Bool {
        guard index > 0, index < rows.count, let cur = rows[index].result, let prev = rows[index - 1].result else { return false }
        return prev.isApp && !cur.isApp
    }
}
