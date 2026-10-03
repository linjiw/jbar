import AppKit
import JBarCore

/// The menu-bar item (DESIGN.md §8): Open JBar | status + warning lines | Rebuild Index |
/// Launch at Login | Open Config File… | About | Quit. Every user-visible failure gets a line here.
///
/// The menu is rebuilt from the current state each time it opens (`menuNeedsUpdate`) and whenever
/// state changes, so the status line is always fresh. The status item is retained by this object.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let settingsFilesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    // Actions wired by AppDelegate.
    var onOpen: (() -> Void)?
    var onRebuild: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Display string of the active hotkey ("⌥Space").
    var hotkeyDisplay: String { didSet { if oldValue != hotkeyDisplay { rebuild() } } }

    private(set) var status = IndexStatus()
    private var hotkeyWarning: String?
    private var configError: String?
    private var loginItemNote: String?
    private var loginItemState: (enabled: Bool, requiresApproval: Bool) = (false, false)

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    init(hotkeyDisplay: String) {
        self.hotkeyDisplay = hotkeyDisplay
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "JBar")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "JBar"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
        Log.menu.notice("status item installed")
    }

    deinit {
        // StatusMenu is created and released by main-actor UI owners. Keep Swift 6.1 compatibility
        // while preserving the required AppKit-thread cleanup.
        MainActor.assumeIsolated { NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - State updates

    /// New index status from `IndexCoordinator.onStatusChanged`.
    func update(status: IndexStatus) {
        self.status = status
        rebuild()
    }

    /// "⚠ Hotkey unavailable" line (nil clears). `detail` is appended, e.g. the fallback combo.
    func setHotkeyWarning(_ detail: String?) {
        hotkeyWarning = detail
        rebuild()
    }

    /// "⚠ Config error" line (nil clears).
    func setConfigError(_ message: String?) {
        configError = message
        rebuild()
    }

    /// Extra note under Launch at Login (e.g. "needs JBar in /Applications"); nil clears.
    func setLoginItemNote(_ note: String?) {
        loginItemNote = note
        rebuild()
    }

    /// Current login-item state for the checkmark / approval hint.
    func setLoginItem(enabled: Bool, requiresApproval: Bool) {
        loginItemState = (enabled, requiresApproval)
        rebuild()
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(action(title: "Open JBar", keyHint: hotkeyDisplay, selector: #selector(openAction)))
        menu.addItem(.separator())
        for line in statusLines() { menu.addItem(line) }
        menu.addItem(.separator())
        menu.addItem(action(title: "Rebuild Index", selector: #selector(rebuildAction)))
        menu.addItem(action(title: "Clear Search History…", selector: #selector(clearHistoryAction)))
        let login = action(title: "Launch at Login", selector: #selector(toggleLoginAction))
        login.state = loginItemState.enabled ? .on : (loginItemState.requiresApproval ? .mixed : .off)
        menu.addItem(login)
        if loginItemState.requiresApproval {
            menu.addItem(action(title: "Open Login Items Settings…", selector: #selector(openLoginSettingsAction)))
        }
        if let note = loginItemNote { menu.addItem(disabled("   " + note)) }
        let cfg = action(title: "Open Config File…", selector: #selector(openConfigAction))
        cfg.keyEquivalent = ","
        cfg.keyEquivalentModifierMask = [.command]
        menu.addItem(cfg)
        menu.addItem(.separator())
        menu.addItem(disabled("Build: " + Runtime.buildIdentity))
        menu.addItem(action(title: "About JBar", selector: #selector(aboutAction)))
        menu.addItem(action(title: "Quit JBar", selector: #selector(quitAction)))
    }

    /// Status + warning lines (DESIGN.md §8). Exposed for tests via `statusTexts`.
    private func statusLines() -> [NSMenuItem] {
        var items: [NSMenuItem] = [disabled(statusText())]
        if !status.deniedPaths.isEmpty {
            // Keep this actionable without copying private folder names into menu metadata (which
            // accessibility tools and diagnostics may inspect). `deniedPaths` is intentionally a
            // bounded sample rather than a total, so its size must not be presented as exact.
            let fix = action(title: "⚠ Some folders not accessible — Fix…",
                             selector: #selector(openFilesAndFoldersAction))
            items.append(fix)
        }
        if status.unsafeEntriesSkipped > 0 {
            let count = status.unsafeEntriesSkipped
            items.append(disabled("⚠ Skipped \(format(count)) unsafe filesystem entr\(count == 1 ? "y" : "ies")"))
        }
        if !status.unavailableRoots.isEmpty {
            items.append(disabled("⚠ Some configured roots unavailable — Check Config"))
        }
        if status.hitItemCap { items.append(disabled("⚠ Index cap reached (\(format(status.itemCount)) items)")) }
        if !status.cappedDirs.isEmpty { items.append(disabled("⚠ Skipped \(status.cappedDirs.count) very large folder\(status.cappedDirs.count == 1 ? "" : "s")")) }
        if let w = hotkeyWarning { items.append(disabled("⚠ Hotkey unavailable — \(w)")) }
        if let e = configError { items.append(disabled("⚠ Config error — \(e)")) }
        return items
    }

    /// The one-line index summary for the current phase.
    func statusText(now: Date = Date()) -> String {
        switch status.phase {
        case .loadingSnapshot: return "Loading index…"
        case .scanningApps: return "Scanning apps…"
        case .crawling(let n): return "Indexing… \(format(n)) items"
        case .updating: return "Updating index… \(format(status.itemCount)) items"
        case .failed(let msg): return "⚠ Index failed — \(msg)"
        case .idle:
            var s = "Index: \(format(status.itemCount)) items · \(format(status.appCount)) apps"
            if let t = status.lastBuilt { s += " · updated \(relative.localizedString(for: t, relativeTo: now))" }
            return s
        }
    }

    /// Titles of all current menu items (for tests / debugging).
    var itemTitles: [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    /// Tooltips are exposed only to prove that private index paths never leak into menu metadata.
    var itemToolTips: [String] { menu.items.compactMap(\.toolTip) }

    private func format(_ n: Int) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? String(n) }

    private func action(title: String, keyHint: String? = nil, selector: Selector) -> NSMenuItem {
        let t = keyHint.map { "\(title)  \($0)" } ?? title
        let it = NSMenuItem(title: t, action: selector, keyEquivalent: "")
        it.target = self
        it.isEnabled = true
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Actions

    @objc private func openAction() { onOpen?() }
    @objc private func rebuildAction() { onRebuild?() }
    @objc private func clearHistoryAction() { onClearHistory?() }
    @objc private func toggleLoginAction() { onToggleLoginItem?() }
    @objc private func openLoginSettingsAction() { LoginItem.openSettings() }
    @objc private func openConfigAction() { onOpenConfig?() }
    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Runtime.buildIdentity,
        ])
    }
    @objc private func quitAction() {
        if let q = onQuit { q() } else { NSApp.terminate(nil) }
    }
    @objc private func openFilesAndFoldersAction() {
        if !NSWorkspace.shared.open(Self.settingsFilesAndFoldersURL) {
            Log.menu.error("could not open Files and Folders settings")
        }
    }
}
