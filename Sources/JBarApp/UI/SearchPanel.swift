import AppKit
import Carbon.HIToolbox
import JBarCore

/// One immutable answer to every question derived from `visibleRows`: how many complete rows the
/// current screen can hold, how many the panel should expose, whether content overflows, how far a
/// page key moves, and the resulting window height. Keeping these values together prevents the table
/// from believing 20 rows are visible while a short screen has clipped the window to (for example) 11.
struct PanelLayoutMetrics: Equatable {
    static let inputRowHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    static let bottomPadding: CGFloat = 8
    static let peekHeight: CGFloat = 16
    static let configuredRowsRange = SafetyLimits.visibleRows

    let configuredVisibleRows: Int
    let screenCapacity: Int
    let effectiveVisibleRows: Int
    let pageStride: Int
    let visibleRowCount: Int
    let hasOverflow: Bool
    let showsPeek: Bool
    let panelHeight: CGFloat

    /// `maximumPanelHeight == nil` means there is no screen constraint (useful for pure sizing and
    /// tests). Capacity always reserves the peek sliver so it remains stable as result counts change.
    init(configuredVisibleRows requestedRows: Int, rowCount requestedRowCount: Int,
         maximumPanelHeight: CGFloat? = nil) {
        let configured = min(max(requestedRows, Self.configuredRowsRange.lowerBound),
                             Self.configuredRowsRange.upperBound)
        let rowCount = max(0, requestedRowCount)
        let heightLimit = max(Self.minimumHeight,
                              maximumPanelHeight ?? Self.height(forVisibleRows: configured, peeking: true))
        let capacity = max(1, Self.rowsThatFit(in: heightLimit, reservingPeek: true))
        let effective = min(configured, capacity)
        let visible = min(rowCount, effective)
        let overflow = rowCount > effective
        let canPeek = overflow && heightLimit >= Self.height(forVisibleRows: effective, peeking: true)

        configuredVisibleRows = configured
        screenCapacity = capacity
        effectiveVisibleRows = effective
        pageStride = effective
        visibleRowCount = visible
        hasOverflow = overflow
        showsPeek = canPeek
        panelHeight = min(heightLimit, Self.height(forVisibleRows: visible, peeking: canPeek))
    }

    static var minimumHeight: CGFloat { inputRowHeight + bottomPadding }

    static func height(forVisibleRows count: Int, peeking: Bool = false) -> CGFloat {
        inputRowHeight + rowHeight * CGFloat(max(0, count)) + (peeking ? peekHeight : 0) + bottomPadding
    }

    static func rowsThatFit(in height: CGFloat, reservingPeek: Bool = false) -> Int {
        let reserved = inputRowHeight + bottomPadding + (reservingPeek ? peekHeight : 0)
        return max(0, Int((height - reserved) / rowHeight))
    }
}

/// The launcher window (DESIGN.md §7.2–7.5): a borderless, non-activating floating panel with the
/// query field and the results table. It never activates JBar; it takes key status on its own.
///
/// Responsibilities: show/hide/toggle + placement, query → `SearchProviding` round trips (newest
/// response wins), all keyboard handling, and dispatching open/reveal/copy to `AppLauncher`.
final class SearchPanel: NSPanel, NSTextFieldDelegate {
    /// The subset of `Config` the panel needs (+ the hotkey's display string for the hint row).
    struct Settings: Equatable {
        /// How many results to fetch — the scrollable pool.
        var maxResults = 40
        /// How many rows are visible without scrolling (the panel height).
        var visibleRows = ResultsController.defaultVisibleRows
        var appsFirstCap = 5
        /// "mouse" | "main" | "active" — which screen the panel appears on.
        var screen = "mouse"
        var restoreQueryOnReopen = false
        /// Show frecency recents when the query is empty (else just the hint row).
        var showRecentsOnEmpty = true
        var hotkeyDisplay = "⌥Space"

        init() {}
        init(config: Config, hotkeyDisplay: String) {
            maxResults = min(max(config.maxResults, SafetyLimits.maxResults.lowerBound),
                             SafetyLimits.maxResults.upperBound)
            visibleRows = min(max(config.visibleRows, SafetyLimits.visibleRows.lowerBound),
                              SafetyLimits.visibleRows.upperBound)
            appsFirstCap = min(max(0, config.appsFirstCap), maxResults)
            screen = config.screen
            restoreQueryOnReopen = config.restoreQueryOnReopen
            showRecentsOnEmpty = config.showRecentsOnEmpty
            self.hotkeyDisplay = hotkeyDisplay
        }
    }

    static let panelWidth: CGFloat = 680
    static let inputRowHeight = PanelLayoutMetrics.inputRowHeight
    static let bottomPadding = PanelLayoutMetrics.bottomPadding
    static let rowHeight = PanelLayoutMetrics.rowHeight
    /// Delay before a "Loading…" row replaces stale content while a slow (path-mode) query runs.
    static let loadingRowDelay: TimeInterval = 0.3

    /// Live settings; changing them re-runs the current query when visible.
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if isVisible { applyHeight(); runSearch() }
        }
    }
    /// Answers queries (the engine, or the demo provider).
    var provider: SearchProviding
    let launcher: AppLauncher
    /// ⌘, handler (AppDelegate opens the config file).
    var onOpenConfig: (() -> Void)?
    /// Show the shortcuts hint row when the query is empty and there are no recents.
    var showsHintWhenEmpty = true
    /// Non-nil while the index is still being built — shown instead of "No matches", which during the
    /// first crawl is both wrong and indistinguishable from a broken app.
    var indexingNote: String?

    private let background = PanelBackgroundView(frame: .zero)
    private let searchIcon = NSImageView()
    private let field = QueryField()
    private let pathBadge = BadgeView()
    private let divider = NSBox()
    private let results = ResultsController()

    private var topEdge: CGFloat = 0
    private var lastAppliedRequestId: UInt64 = 0
    /// UI-side epoch, independent of a provider's request ids. Some product policies (notably
    /// `showRecentsOnEmpty: false`) intentionally do not display the provider's next response, but
    /// they still supersede an in-flight query and must make its eventual rows ineligible to render.
    private var searchEpoch: UInt64 = 0
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
        // The panel and its monitors are main-actor owned. Swift 6.1 requires this explicit
        // assertion because isolated deinitializers are not enabled there by default.
        MainActor.assumeIsolated {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
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
            // `queue: .main` is the runtime guarantee behind this assertion. Keep the read synchronous:
            // an IME candidate window can take key status and clear its marked range before a deferred
            // task runs, which would make a normal input-source transition look like an app crash.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleResignKey(hadMarkedText: self.field.hasMarkedText,
                                     modifiers: NSEvent.modifierFlags)
            }
        })
    }

    /// Input-source switchers can briefly take key status while Control is held. Defer the decision so a
    /// responder transition back to this panel does not look like a crash, and never tear down active IME
    /// marked text merely because its candidate/input-source UI appeared.
    private func handleResignKey(hadMarkedText: Bool, modifiers: NSEvent.ModifierFlags) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Self.shouldHideAfterResign(isVisible: isVisible, isKeyWindow: isKeyWindow,
                                          hadMarkedText: hadMarkedText,
                                          hasMarkedText: field.hasMarkedText,
                                          modifiers: modifiers) {
                hide()
            }
        }
    }

    static func shouldHideAfterResign(isVisible: Bool, isKeyWindow: Bool, hadMarkedText: Bool,
                                      hasMarkedText: Bool,
                                      modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return isVisible && !isKeyWindow && !hadMarkedText && !hasMarkedText && !flags.contains(.control)
    }

    // MARK: - Show / hide

    /// Show the panel on the configured screen and run the current (usually empty) query.
    func show() {
        results.armHover()   // the panel may appear under a stationary pointer
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
        if settings.restoreQueryOnReopen {
            field.commitMarkedText()
        } else {
            // Discard composition while the field editor is still attached to a visible window. Clearing
            // after `orderOut` lets older AppKit/IME versions re-enter with a stale marked range.
            _ = field.abortEditing()
            clearQuery()
        }
        // Ending/committing composition may synchronously send a text-change notification. Cancel after
        // that transition too so no newly queued search keeps running for a panel that is about to hide.
        loadingWork?.cancel()
        searchEpoch &+= 1
        let provider = self.provider
        Task { _ = await provider.runSearch("", limit: 0, appsFirstCap: 0) }
        orderOut(nil)
        Log.panel.notice("panel hidden")
    }

    /// Show when hidden, hide when visible (the hotkey action).
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func clearQuery() {
        // Keep the NSTextField and its field editor in sync, and safely terminate any active IME marked
        // text before clearing. This matters when Ctrl+Space changes input source while the panel resigns.
        field.setText("")
        currentMode = .empty
        pathBadge.text = "PATH"
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

    /// Height available after a 16pt safety inset at both screen edges. The layout metrics convert
    /// this into an effective row capacity while reserving space for the overflow peek.
    private func availablePanelHeight(on screen: NSScreen?) -> CGFloat? {
        screen.map { max(PanelLayoutMetrics.minimumHeight, $0.visibleFrame.height - 32) }
    }

    private func layoutMetrics(on screen: NSScreen?, rowCount: Int? = nil) -> PanelLayoutMetrics {
        PanelLayoutMetrics(configuredVisibleRows: settings.visibleRows,
                           rowCount: rowCount ?? results.rowCount,
                           maximumPanelHeight: availablePanelHeight(on: screen))
    }

    /// Centre horizontally on the target screen, input-row centre 1/3 down the visible frame.
    private func placeOnScreen() {
        guard let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let width = min(Self.panelWidth, max(320, vf.width - 40))
        // Reserve room for a fully populated result list even when the panel is currently empty, so
        // later search responses can grow it downward without crossing the screen's safe edge.
        let maxH = layoutMetrics(on: screen, rowCount: Int.max).panelHeight
        var top = (vf.maxY - vf.height / 3 + Self.inputRowHeight / 2).rounded()
        top = min(top, vf.maxY - 8)
        if top - maxH < vf.minY { top = min(vf.maxY - 8, vf.minY + maxH + 8) }
        topEdge = top
        let h = frame.height
        setFrame(NSRect(x: (vf.midX - width / 2).rounded(), y: top - h, width: width, height: h), display: false)
    }

    /// Sliver of the next row left showing when more results exist below the fold. Without it the list
    /// looks complete — overlay scrollers are invisible until you already started scrolling — so nobody
    /// discovers that there is anything to scroll to.
    static let peekHeight = PanelLayoutMetrics.peekHeight

    /// Height needed for `n` rows, ignoring any cap. `peeking` adds the sliver that reveals there are
    /// more rows below; `PanelLayoutMetrics` applies the real screen limit.
    static func height(forVisibleRows n: Int, peeking: Bool = false) -> CGFloat {
        PanelLayoutMetrics.height(forVisibleRows: n, peeking: peeking)
    }

    /// How many rows actually fit in `height` (used to keep `visibleRows` honest on small screens).
    static func rowsThatFit(in height: CGFloat) -> Int {
        PanelLayoutMetrics.rowsThatFit(in: height)
    }

    private func applyHeight() {
        let metrics = layoutMetrics(on: targetScreen())
        results.applyLayout(metrics)
        let h = metrics.panelHeight
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
        // The list gets the whole area between the input row and the bottom padding, so when the panel is
        // peeking the extra sliver belongs to the list and cuts the next row in half.
        let listH = max(0, background.bounds.height - rowH - Self.bottomPadding)
        divider.frame = NSRect(x: 16, y: rowH - 1, width: w - 32, height: 1)
        divider.isHidden = results.rowCount == 0
        results.scrollView.frame = NSRect(x: 0, y: rowH, width: w, height: listH)
        results.layout(width: w)
    }

    // MARK: - Snapshot (debug aid)

    /// Move the selection down one result (`JBAR_SNAPSHOT_DOWN`), exercising the same call the ↓ key makes.
    func moveSelectionDownForSnapshot() { results.moveSelection(by: 1, wrap: false) }

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

    /// Re-run the current query after state outside the panel changes (for example history clear).
    func refreshResults() {
        if isVisible { runSearch() }
    }

    private func runSearch() {
        searchEpoch &+= 1
        let epoch = searchEpoch
        let q = field.stringValue
        // `showRecentsOnEmpty: false` means an empty query shows nothing but the hint row.
        if !settings.showRecentsOnEmpty, q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadingWork?.cancel()
            let hint = indexingNote ?? (showsHintWhenEmpty ? Self.hintText(hotkeyDisplay: settings.hotkeyDisplay) : nil)
            results.setRows(hint.map { [PanelRow.hint($0)] } ?? [])
            applyHeight()
            // Issue a zero-result empty request solely to advance SearchEngine's cancellation counter.
            // The UI epoch above is still the authority: this response is never rendered.
            let provider = self.provider
            Task { _ = await provider.runSearch(q, limit: 0, appsFirstCap: 0) }
            return
        }
        let limit = settings.maxResults
        let cap = settings.appsFirstCap
        let provider = self.provider
        scheduleLoadingRow()
        Task { @MainActor [weak self] in
            let response = await provider.runSearch(q, limit: limit, appsFirstCap: cap)
            guard let self, self.searchEpoch == epoch else { return }
            self.apply(response)
        }
    }

    /// Current rows exposed for AppKit integration tests and accessibility diagnostics.
    var displayedRows: [PanelRow] { results.rows }

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
        let pathStatus = Self.pathBadgeText(for: r)
        pathBadge.text = pathStatus ?? "PATH"
        pathBadge.isHidden = pathStatus == nil
        pathBadge.setAccessibilityLabel(Self.pathBadgeAccessibilityLabel(for: r))
        results.setRows(Self.panelRows(for: r,
                                       hint: showsHintWhenEmpty ? Self.hintText(hotkeyDisplay: settings.hotkeyDisplay) : nil,
                                       indexing: indexingNote))
        applyHeight()
        Log.panel.debug("\(Self.appliedLogSummary(for: r), privacy: .public)")
    }

    /// Query-independent operational metadata. Queries can contain filenames, client names, or pasted
    /// secrets, so the raw string is deliberately unavailable to the logging call site.
    static func appliedLogSummary(for response: SearchResponse) -> String {
        "applied \(response.rows.count) rows in \(Int(response.elapsed * 1000)) ms (id=\(response.requestId))"
    }

    /// Compact, always-visible path-mode completeness signal. The result table deliberately keeps
    /// only a bounded page; showing `kept/total` prevents that page from looking like the whole folder.
    static func pathBadgeText(for response: SearchResponse) -> String? {
        guard case .path = response.mode else { return nil }
        guard response.totalMatchesIsComplete else { return "PATH · ?" }
        guard response.hasMoreResults == true else { return "PATH" }
        return "PATH · \(response.rows.count)/\(response.totalMatches)"
    }

    static func pathBadgeAccessibilityLabel(for response: SearchResponse) -> String? {
        guard case .path = response.mode else { return nil }
        guard response.totalMatchesIsComplete else { return "Path mode; result count unavailable" }
        if response.hasMoreResults == true {
            return "Path mode; showing \(response.rows.count) of \(response.totalMatches) matches"
        }
        return "Path mode; all \(response.totalMatches) matches shown"
    }

    /// Map a response to table rows, adding the empty-state or hint row when there are no results.
    nonisolated static func panelRows(for r: SearchResponse, hint: String?,
                                      indexing: String? = nil) -> [PanelRow] {
        if !r.rows.isEmpty { return r.rows.map(PanelRow.result) }
        switch r.mode {
        case .empty:
            return indexing.map { [.hint($0)] } ?? hint.map { [.hint($0)] } ?? []
        case .path where !r.totalMatchesIsComplete:
            return [.hint("Folder scan incomplete")]
        case .search, .path, .extensionOnly:
            let q = r.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return [] }
            // Still indexing → say so; "No matches" here would be a lie the user cannot act on.
            if let indexing { return [.hint(indexing)] }
            return [.empty(query: q)]
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
        launcher.open(row, query: q) { [weak self] succeeded in
            if succeeded { self?.hide() }
        }
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
        if query.utf8.first != 0x2F { target = abbreviateHome(target, home: home) }
        return target
    }

    /// `/Users/me/x` → `~/x`.
    static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        SafetyLimits.abbreviatingHome(path, home: home)
    }

    // MARK: - Keyboard

    /// Local monitor: ⌘-shortcuts that must win over the field editor (⌘1–8, ⌘↩, ⌘C, ⌘,, ⌘Q).
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === self else { return event }
        let hasMarkedText = field.hasMarkedText
        if Self.shouldCloseForKey(keyCode: event.keyCode, hasMarkedText: hasMarkedText,
                                  modifiers: event.modifierFlags) {
            hide()
            return nil
        }
        guard Self.shouldInterceptCommandShortcut(hasMarkedText: hasMarkedText,
                                                  modifiers: event.modifierFlags) else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter {
            revealSelected()
            return nil
        }
        // Key codes identify the physical number row independently of the active keyboard layout.
        // `charactersIgnoringModifiers` can be "&", "é", etc. for the same keys on non-US layouts.
        if !flags.contains(.shift), let ordinal = Self.resultOrdinal(forCommandKeyCode: event.keyCode) {
            guard let row = results.result(atOrdinal: ordinal) else { NSSound.beep(); return nil }
            open(row)
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
        default:
            return event
        }
    }

    /// Whether the panel may consume a Command shortcut before the field editor sees it. Marked
    /// text always wins: candidate selection and input-method bindings commonly use Command keys.
    static func shouldInterceptCommandShortcut(hasMarkedText: Bool,
                                               modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return !hasMarkedText && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
    }

    /// Zero-based result ordinal for the physical ANSI 1…8 keys. This deliberately does not inspect
    /// characters, so AZERTY and other non-US layouts get the same ⌘1…8 behavior as US keyboards.
    static func resultOrdinal(forCommandKeyCode keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        default: return nil
        }
    }

    /// Only a physical Escape closes the panel. Delete (key code 51) and an IME's logical
    /// `cancelOperation:` must remain owned by the standard field editor.
    static func shouldCloseForKey(keyCode: UInt16, hasMarkedText: Bool,
                                  modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        return Int(keyCode) == kVK_Escape && !hasMarkedText && flags.intersection(commandModifiers).isEmpty
    }

    /// Keys reaching the panel when the field editor is not first responder (e.g. after a click on the list).
    override func keyDown(with event: NSEvent) {
        if field.hasMarkedText {
            makeFirstResponder(field)
            // Preserve the text-input context even if a transient responder change delivered the key
            // to the panel. The IME, not result navigation, owns every key while text is marked.
            if let editor = field.currentEditor() {
                editor.interpretKeyEvents([event])
            } else {
                super.keyDown(with: event)
            }
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if Self.shouldCloseForKey(keyCode: event.keyCode, hasMarkedText: field.hasMarkedText,
                                      modifiers: event.modifierFlags) {
                hide()
            } else {
                super.keyDown(with: event)
            }
        case kVK_UpArrow: results.moveSelection(by: -1, wrap: true)
        case kVK_DownArrow: results.moveSelection(by: 1, wrap: true)
        case kVK_Return, kVK_ANSI_KeypadEnter: openSelected()
        default:
            makeFirstResponder(field)
            // `interpretKeyEvents` routes through NSTextInputContext; invoking the field editor's
            // `keyDown` directly can bypass marked-text handling for Korean and other IMEs.
            if let editor = field.currentEditor() { editor.interpretKeyEvents([event]) } else { super.keyDown(with: event) }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Returning false hands the command back to AppKit/NSTextInputContext. This covers Return,
        // Tab, arrows, Page Up/Down and Escape as well as input-method-specific command selectors.
        guard Self.shouldHandleFieldEditorCommand(hasMarkedText: textView.hasMarkedText()) else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): results.moveSelection(by: -1, wrap: true)
        case #selector(NSResponder.moveDown(_:)): results.moveSelection(by: 1, wrap: true)
        case #selector(NSResponder.insertBacktab(_:)): results.moveSelection(by: -1, wrap: true)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            results.moveSelectionByPage(-1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            results.moveSelectionByPage(1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): results.selectEdge(first: true)
        case #selector(NSResponder.moveToEndOfDocument(_:)): results.selectEdge(first: false)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.insertTab(_:)): autocomplete()
        // `cancelOperation:` is also emitted by input methods and bindings such as Ctrl-G; a physical
        // Escape with no active composition is handled by the local key monitor above.
        case #selector(NSResponder.cancelOperation(_:)): return false
        default: return false
        }
        return true
    }

    /// The launcher only owns field-editor commands after composition has committed.
    static func shouldHandleFieldEditorCommand(hasMarkedText: Bool) -> Bool { !hasMarkedText }
}
