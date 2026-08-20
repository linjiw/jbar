import AppKit
import Carbon.HIToolbox
import JBarCore

/// The launcher window (DESIGN.md §7.2–7.5): a borderless, non-activating floating panel with the
/// query field and the results table. It never activates JBar; it takes key status on its own.
///
/// Responsibilities: show/hide/toggle + placement, query → `SearchProviding` round trips (newest
/// response wins), all keyboard handling, and dispatching open/reveal/copy to `AppLauncher`.
final class SearchPanel: NSPanel, NSTextFieldDelegate {
    /// The subset of `Config` the panel needs (+ the hotkey's display string for the hint row).
    struct Settings: Equatable {
        var maxResults = 8
        var appsFirstCap = 5
        /// "mouse" | "main" | "active" — which screen the panel appears on.
        var screen = "mouse"
        var restoreQueryOnReopen = false
        var hotkeyDisplay = "⌥Space"

        init() {}
        init(config: Config, hotkeyDisplay: String) {
            maxResults = max(1, config.maxResults)
            appsFirstCap = max(0, config.appsFirstCap)
            screen = config.screen
            restoreQueryOnReopen = config.restoreQueryOnReopen
            self.hotkeyDisplay = hotkeyDisplay
        }
    }

    static let panelWidth: CGFloat = 680
    static let inputRowHeight: CGFloat = 60
    static let bottomPadding: CGFloat = 8
    static let rowHeight = ResultsController.rowHeight
    static let maxHeight: CGFloat = 452 // 60 + 8 × 48 + 8
    /// Delay before a "Loading…" row replaces stale content while a slow (path-mode) query runs.
    static let loadingRowDelay: TimeInterval = 0.3

    /// Live settings; changing them re-runs the current query when visible.
    var settings: Settings {
        didSet { if settings != oldValue, isVisible { runSearch() } }
    }
    /// Answers queries (the engine, or the demo provider).
    var provider: SearchProviding
    let launcher: AppLauncher
    /// ⌘, handler (AppDelegate opens the config file).
    var onOpenConfig: (() -> Void)?
    /// Show the shortcuts hint row when the query is empty and there are no recents.
    var showsHintWhenEmpty = true

    private let background = PanelBackgroundView(frame: .zero)
    private let searchIcon = NSImageView()
    private let field = QueryField()
    private let pathBadge = BadgeView()
    private let divider = NSBox()
    private let results = ResultsController()

    private var topEdge: CGFloat = 0
    private var lastAppliedRequestId: UInt64 = 0
    private var currentMode: QueryMode = .empty
    private var keyMonitor: Any?
    private var loadingWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    init(provider: SearchProviding, launcher: AppLauncher, settings: Settings) {
        self.provider = provider
        self.launcher = launcher
        self.settings = settings
        let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.inputRowHeight + Self.bottomPadding)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        configureWindow()
        buildContent()
        installMonitors()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func configureWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
    }

    private func buildContent() {
        background.frame = NSRect(origin: .zero, size: frame.size)
        background.autoresizingMask = [.width, .height]
        contentView = background

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        field.delegate = self
        pathBadge.text = "PATH"
        pathBadge.isHidden = true
        divider.boxType = .separator
        divider.isHidden = true
        results.onOpen = { [weak self] row in self?.open(row) }

        for v in [searchIcon, field, pathBadge, divider, results.scrollView] as [NSView] { background.addSubview(v) }
        layoutContent()
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            self?.hide()
        })
    }

    // MARK: - Show / hide

    /// Show the panel on the configured screen and run the current (usually empty) query.
    func show() {
        placeOnScreen()
        applyHeight()
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
        if settings.restoreQueryOnReopen, !field.stringValue.isEmpty { field.currentEditor()?.selectAll(nil) }
        runSearch()
        Log.panel.notice("panel shown frame=\(NSStringFromRect(self.frame), privacy: .public)")
    }

    /// Hide the panel; clears the query unless `restoreQueryOnReopen`.
    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        loadingWork?.cancel()
        if !settings.restoreQueryOnReopen { clearQuery() }
        Log.panel.notice("panel hidden")
    }

    /// Show when hidden, hide when visible (the hotkey action).
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func clearQuery() {
        field.stringValue = ""
        currentMode = .empty
        pathBadge.isHidden = true
        results.setRows([])
        applyHeight()
    }

    // MARK: - Placement & size

    private func targetScreen() -> NSScreen? {
        switch settings.screen {
        case "main":
            return NSScreen.screens.first ?? NSScreen.main
        case "active":
            return NSScreen.main ?? NSScreen.screens.first
        default:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// Centre horizontally on the target screen, input-row centre 1/3 down the visible frame.
    private func placeOnScreen() {
        guard let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let width = min(Self.panelWidth, max(320, vf.width - 40))
        var top = (vf.maxY - vf.height / 3 + Self.inputRowHeight / 2).rounded()
        top = min(top, vf.maxY - 8)
        if top - Self.maxHeight < vf.minY { top = min(vf.maxY - 8, vf.minY + Self.maxHeight + 8) }
        topEdge = top
        let h = frame.height
        setFrame(NSRect(x: (vf.midX - width / 2).rounded(), y: top - h, width: width, height: h), display: false)
    }

    /// Height for the current row count; the top edge stays where `placeOnScreen()` put it.
    static func height(forVisibleRows n: Int) -> CGFloat {
        min(maxHeight, inputRowHeight + rowHeight * CGFloat(max(0, n)) + bottomPadding)
    }

    private func applyHeight() {
        let h = Self.height(forVisibleRows: results.visibleRowCount)
        var f = frame
        if topEdge == 0 { topEdge = f.maxY }
        f.origin.y = topEdge - h
        f.size.height = h
        if f != frame { setFrame(f, display: true) }
        layoutContent()
        invalidateShadow()
    }

    private func layoutContent() {
        let w = background.bounds.width
        let rowH = Self.inputRowHeight
        searchIcon.frame = NSRect(x: 22, y: (rowH - 24) / 2, width: 24, height: 24)
        var fieldRight = w - 20
        if !pathBadge.isHidden {
            let bs = pathBadge.intrinsicContentSize
            pathBadge.frame = NSRect(x: w - 20 - bs.width, y: (rowH - bs.height) / 2, width: bs.width, height: bs.height)
            fieldRight = pathBadge.frame.minX - 12
        }
        field.frame = NSRect(x: 58, y: (rowH - 32) / 2, width: max(0, fieldRight - 58), height: 32)
        let listH = Self.rowHeight * CGFloat(results.visibleRowCount)
        divider.frame = NSRect(x: 16, y: rowH - 1, width: w - 32, height: 1)
        divider.isHidden = results.rowCount == 0
        results.scrollView.frame = NSRect(x: 0, y: rowH, width: w, height: listH)
        results.layout(width: w)
    }

    // MARK: - Snapshot (debug aid)

    /// Render the panel's content view to a PNG at `url` (2× scale). Returns false on failure.
    /// Draws the app's own view hierarchy, so no Screen Recording permission is needed.
    @discardableResult
    func renderSnapshot(to url: URL) -> Bool {
        guard let view = contentView else { return false }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }

    // MARK: - Search

    /// Current query text.
    var query: String { field.stringValue }

    /// Replace the query text and search again (Tab autocomplete, tests).
    func setQuery(_ text: String) {
        field.setText(text)
        runSearch()
    }

    private func runSearch() {
        let q = field.stringValue
        let limit = settings.maxResults
        let cap = settings.appsFirstCap
        let provider = self.provider
        scheduleLoadingRow()
        Task { @MainActor [weak self] in
            let response = await provider.runSearch(q, limit: limit, appsFirstCap: cap)
            self?.apply(response)
        }
    }

    private func scheduleLoadingRow() {
        loadingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.results.setRows([.loading])
            self.applyHeight()
        }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadingRowDelay, execute: work)
    }

    private func apply(_ r: SearchResponse) {
        // A cancelled response carries no rows and must be ignored (a newer request's real response
        // will arrive with a strictly higher id) — rendering it would flash "No matches" and resize.
        guard !r.cancelled else { return }
        guard r.requestId >= lastAppliedRequestId else {
            Log.panel.debug("dropped stale response id=\(r.requestId) latest=\(self.lastAppliedRequestId)")
            return
        }
        lastAppliedRequestId = r.requestId
        loadingWork?.cancel()
        currentMode = r.mode
        let inPath: Bool = { if case .path = r.mode { return true }; return false }()
        pathBadge.isHidden = !inPath
        results.setRows(Self.panelRows(for: r, hint: showsHintWhenEmpty ? Self.hintText(hotkeyDisplay: settings.hotkeyDisplay) : nil))
        applyHeight()
        Log.panel.debug("applied \(r.rows.count) rows for \"\(r.query, privacy: .public)\" in \(Int(r.elapsed * 1000)) ms (id=\(r.requestId))")
    }

    /// Map a response to table rows, adding the empty-state or hint row when there are no results.
    static func panelRows(for r: SearchResponse, hint: String?) -> [PanelRow] {
        if !r.rows.isEmpty { return r.rows.map(PanelRow.result) }
        switch r.mode {
        case .empty:
            return hint.map { [.hint($0)] } ?? []
        case .search, .path, .extensionOnly:
            let q = r.query.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? [] : [.empty(query: q)]
        }
    }

    /// The first-run / empty-history hint row text.
    static func hintText(hotkeyDisplay: String) -> String {
        "Type to search · ↩ open · ⌘↩ reveal · ⌘C copy path · \(hotkeyDisplay) toggle"
    }

    // MARK: - Actions

    private var actionTarget: ResultRow? { results.selectedResult ?? results.firstResult }

    private func open(_ row: ResultRow) {
        let q = field.stringValue
        if launcher.open(row, query: q) { hide() }
    }

    private func openSelected() {
        guard let row = actionTarget else { NSSound.beep(); return }
        open(row)
    }

    private func revealSelected() {
        guard let row = actionTarget else { NSSound.beep(); return }
        if launcher.reveal(row) { hide() }
    }

    private func copySelectedPath() {
        guard let row = actionTarget else { NSSound.beep(); return }
        launcher.copyPath(row)
        hide()
    }

    /// Tab: path-mode autocomplete. Folder row → its path + "/" (entering path mode); file row in
    /// path mode → its path. `~` abbreviation is kept unless the query is an absolute `/` path.
    private func autocomplete() {
        guard let row = actionTarget else { NSSound.beep(); return }
        let inPath: Bool = { if case .path = currentMode { return true }; return false }()
        guard let target = Self.autocompleteTarget(for: row, query: field.stringValue, inPathMode: inPath) else {
            NSSound.beep()
            return
        }
        setQuery(target)
    }

    /// Pure helper for `autocomplete()`; nil when Tab has nothing to complete.
    static func autocompleteTarget(for row: ResultRow, query: String, inPathMode: Bool, home: String = NSHomeDirectory(),
                                   isDirectory: (String) -> Bool = { p in
                                       var d: ObjCBool = false
                                       return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
                                   }) -> String? {
        let folder = row.kind == .folder || (!row.isApp && !row.path.hasSuffix(".app") && isDirectory(row.path))
        guard folder || inPathMode else { return nil }
        var target = folder ? row.path + "/" : row.path
        if !query.hasPrefix("/") { target = abbreviateHome(target, home: home) }
        return target
    }

    /// `/Users/me/x` → `~/x`.
    static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Keyboard

    /// Local monitor: ⌘-shortcuts that must win over the field editor (⌘1–8, ⌘↩, ⌘C, ⌘,, ⌘Q).
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === self else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return event }
        if Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter {
            revealSelected()
            return nil
        }
        guard !flags.contains(.shift), let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return event }
        switch chars {
        case "q": return nil // ⌘Q is ignored inside the panel
        case ",": onOpenConfig?(); return nil
        case "c":
            if field.hasTextSelection { return event }
            copySelectedPath()
            return nil
        case "1", "2", "3", "4", "5", "6", "7", "8":
            guard let n = Int(chars), let row = results.result(atOrdinal: n - 1) else { NSSound.beep(); return nil }
            open(row)
            return nil
        default:
            return event
        }
    }

    /// Keys reaching the panel when the field editor is not first responder (e.g. after a click on the list).
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: hide()
        case kVK_UpArrow: results.moveSelection(by: -1, wrap: true)
        case kVK_DownArrow: results.moveSelection(by: 1, wrap: true)
        case kVK_Return, kVK_ANSI_KeypadEnter: openSelected()
        default:
            makeFirstResponder(field)
            if let editor = field.currentEditor() { editor.keyDown(with: event) } else { super.keyDown(with: event) }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): results.moveSelection(by: -1, wrap: true)
        case #selector(NSResponder.moveDown(_:)): results.moveSelection(by: 1, wrap: true)
        case #selector(NSResponder.insertBacktab(_:)): results.moveSelection(by: -1, wrap: true)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            results.moveSelection(by: -ResultsController.maxVisibleRows, wrap: false)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            results.moveSelection(by: ResultsController.maxVisibleRows, wrap: false)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): results.selectEdge(first: true)
        case #selector(NSResponder.moveToEndOfDocument(_:)): results.selectEdge(first: false)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.insertTab(_:)): autocomplete()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }
}
