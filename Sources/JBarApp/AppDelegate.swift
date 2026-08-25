import AppKit
import Carbon.HIToolbox
import Darwin
import JBarActions
import JBarCore

/// Wires the product together (DESIGN.md §2.3, §8): config → frecency → engine → indexer → menu →
/// hotkey → panel → config hot reload → login item → first-run panel.
///
/// `JBAR_DEMO=1` swaps the engine for `DemoSearchProvider` and skips config/indexer/frecency/login
/// item entirely (UI-only smoke testing without folder-access prompts).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let historyMaintenanceQueue = DispatchQueue(label: "com.linji.jbar.history-maintenance",
                                                               qos: .utility)
    private let appKitSmokeRequest: AppKitSmoke.Request?
    private var appKitSmokeSession: AppKitSmoke.Session?
    private let demo = Runtime.isDemo
    private var config = Config.default
    private lazy var configURL = Config.defaultURL()
    private var firstRun = false

    private var frecency: FrecencyStore?
    private var engine: SearchEngine?
    private var coordinator: IndexCoordinator?
    private var configWatcher: ConfigWatcher?
    private var launcher: AppLauncher!
    private var panel: SearchPanel!
    private var assistant: AssistantCoordinator!
    private var organize: OrganizeCoordinator!
    private var codexChat: CodexChatCoordinator!
    private var statusMenu: StatusMenu!
    private let hotkey = CarbonHotkey()

    /// Normal launches return zero. Smoke launches remain fail-closed until a PASS evidence record
    /// and the `applicationWillTerminate` marker have both been durably written.
    var processExitCode: Int32 {
        guard appKitSmokeRequest != nil else { return 0 }
        return appKitSmokeSession?.exitCode ?? 1
    }

    override init() {
        appKitSmokeRequest = nil
        super.init()
    }

    init(appKitSmokeRequest: AppKitSmoke.Request) {
        self.appKitSmokeRequest = appKitSmokeRequest
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appKitSmokeRequest {
            let session = AppKitSmoke.Session(request: appKitSmokeRequest)
            appKitSmokeSession = session
            session.start()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Log.app.notice("JBar \(Runtime.buildIdentity, privacy: .public) launching (demo=\(self.demo))")
        MainMenu.install(openConfig: #selector(openConfigFile(_:)), target: self)

        if !demo { loadConfig() }
        let provider: SearchProviding = demo ? DemoSearchProvider() : makeEngine()
        launcher = AppLauncher(frecency: frecency)
        let chat = CodexChatCoordinator(applicationSupportRoot: Runtime.testStateRoot)
        codexChat = chat
        let planner = CodexTaskSession(applicationSupportRoot: Runtime.testStateRoot)
        let assistedSearch = AssistantCoordinator(provider: provider, launcher: launcher,
                                                   planner: planner,
                                                   indexStatus: { [weak self] in
                                                       self?.coordinator?.status ?? IndexStatus()
                                                   })
        assistant = assistedSearch
        let organizer = OrganizeCoordinator(
            provider: provider, searchPlanner: planner, organizePlanner: planner,
            indexStatus: { [weak self] in
                self?.coordinator?.status ?? IndexStatus()
            }
        )
        organize = organizer
        let actionHandler = CodexActionHandler(
            presentAssistant: { [weak assistedSearch] prompt in
                assistedSearch?.present(prompt: prompt) ?? false
            },
            presentOrganize: { [weak organizer] instruction in
                organizer?.present(instruction: instruction) ?? false
            },
            presentDeveloperAgent: { [weak chat] prompt in
                chat?.present(prompt: prompt) ?? false
            }
        )
        panel = SearchPanel(provider: provider, launcher: launcher,
                            settings: SearchPanel.Settings(config: config, hotkeyDisplay: hotkeyDisplay),
                            actionHandler: actionHandler)
        panel.onOpenConfig = { [weak self] in self?.openConfigFile(nil) }

        statusMenu = StatusMenu(hotkeyDisplay: hotkeyDisplay)
        statusMenu.onOpen = { [weak self] in self?.panel.show() }
        statusMenu.onRebuild = { [weak self] in self?.coordinator?.rebuild() }
        statusMenu.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        statusMenu.onToggleLoginItem = { [weak self] in self?.toggleLoginItem() }
        statusMenu.onOpenConfig = { [weak self] in self?.openConfigFile(nil) }
        statusMenu.onQuit = { NSApp.terminate(nil) }

        registerHotkey(config.hotkey)
        if !demo {
            startIndexer()
            startConfigWatcher()
            applyLoginItem(enabled: config.launchAtLogin)
        }
        if firstRun || Runtime.showOnLaunch {
            Log.app.notice("showing panel on launch (firstRun=\(self.firstRun))")
            panel.show()
        }
        if let path = Runtime.snapshotPath { scheduleSnapshot(to: path) }
    }

    /// Text for the panel while the index is still being built, or nil once it is ready.
    /// Shown in place of "No matches", which during the first crawl is misleading.
    nonisolated static func indexingNote(for status: IndexStatus) -> String? {
        switch status.phase {
        case .idle:
            return nil
        case .failed(let message):
            return "⚠ Index unavailable — \(message)"
        case .scanningApps, .loadingSnapshot:
            return "Indexing… apps are searchable now"
        case .crawling(let n):
            return n > 0 ? "Indexing… \(n.formatted()) files so far — results will fill in"
                         : "Indexing… results will fill in shortly"
        case .updating:
            return status.itemCount > 0 ? nil : "Updating index…"
        }
    }

    /// Debug aid (`JBAR_SNAPSHOT_PATH`): wait for the index, run a query, render the panel to PNG, quit.
    private func scheduleSnapshot(to path: String) {
        let query = Runtime.snapshotQuery
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.panel.show()
            self.panel.setQuery(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                for _ in 0..<Runtime.snapshotDown { self.panel.moveSelectionDownForSnapshot() }
                let ok = self.panel.renderSnapshot(to: URL(fileURLWithPath: path))
                Log.app.notice("snapshot completed ok=\(ok)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appKitSmokeSession {
            appKitSmokeSession.applicationWillTerminate()
            // NSApplication's terminate path exits the process itself instead of returning from
            // `run()`. Override that fixed success status if the clean marker could not be written,
            // or if an unexpected termination arrived before the smoke reached PASS.
            if appKitSmokeSession.exitCode != 0 { Darwin.exit(appKitSmokeSession.exitCode) }
            return
        }
        Log.app.notice("terminating")
        hotkey.unregister()
        configWatcher?.stop()
        coordinator?.stop()
        assistant?.close()
        organize?.close()
        codexChat?.close()
        launcher?.flush()
        frecency?.save()
    }

    // MARK: - Config

    private func loadConfig() {
        switch Config.load(from: configURL) {
        case .loaded(let c):
            config = c
        case .created(let c):
            config = c
            firstRun = true
            Log.app.notice("config created (first run)")
        case .invalid(let message):
            config = .default
            Log.app.error("config invalid; using defaults")
            DispatchQueue.main.async { [weak self] in self?.statusMenu?.setConfigError(message) }
        }
    }

    private func startConfigWatcher() {
        let watcher = ConfigWatcher(url: configURL, queue: .main, onChange: { [weak self] newConfig in
            Task { @MainActor [weak self] in self?.applyConfig(newConfig) }
        }, onError: { [weak self] message in
            Task { @MainActor [weak self] in
                Log.app.error("config reload failed; keeping last valid configuration")
                self?.statusMenu.setConfigError(message)
            }
        })
        watcher.start()
        configWatcher = watcher
    }

    /// Apply a hot-reloaded config: hotkey, panel settings, indexer options, login item.
    private func applyConfig(_ newConfig: Config) {
        let old = config
        config = newConfig
        statusMenu.setConfigError(nil)
        if old.hotkey != newConfig.hotkey { registerHotkey(newConfig.hotkey) }
        panel.settings = SearchPanel.Settings(config: newConfig, hotkeyDisplay: hotkeyDisplay)
        statusMenu.hotkeyDisplay = hotkeyDisplay
        if Self.indexOptionsChanged(old, newConfig) { coordinator?.update(options: newConfig.coordinatorOptions()) }
        if old.launchAtLogin != newConfig.launchAtLogin { applyLoginItem(enabled: newConfig.launchAtLogin) }
        Log.app.notice("config reloaded")
    }

    /// True when a config change affects the indexer (roots, exclusions, caps, depth, hidden files).
    nonisolated static func indexOptionsChanged(_ a: Config, _ b: Config) -> Bool {
        a.appDirectories != b.appDirectories || a.fileRoots != b.fileRoots || a.excludePaths != b.excludePaths
            || a.excludeNames != b.excludeNames || a.downrankNames != b.downrankNames || a.includeHidden != b.includeHidden
            || a.maxDepth != b.maxDepth || a.maxIndexedItems != b.maxIndexedItems
    }

    /// Open the config file in the default editor (creating it with defaults first if missing).
    @objc func openConfigFile(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            do { try config.save(to: configURL) } catch {
                let ns = error as NSError
                Log.app.error("could not write config: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
            }
        }
        if !NSWorkspace.shared.open(configURL) {
            Log.app.error("could not open config file")
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        }
    }

    // MARK: - Engine & indexer

    private func makeEngine() -> SearchEngine {
        let store = FrecencyStore(fileURL: Self.historyURL(), enforcePrivateDirectory: true)
        store.load()
        Self.historyMaintenanceQueue.async {
            let fileManager = FileManager()
            Self.pruneHistory(store) { fileManager.fileExists(atPath: $0) }
        }
        frecency = store
        let e = SearchEngine(frecency: store)
        engine = e
        return e
    }

    /// Remove history entries whose targets no longer exist, off the UI/search path. Persist only
    /// when something changed so a normal launch does not rewrite state unnecessarily.
    @discardableResult
    nonisolated static func pruneHistory(_ store: FrecencyStore, exists: (String) -> Bool) -> Int {
        let removed = store.prune(exists: exists)
        if removed > 0 { store.save() }
        return removed
    }

    /// Explicit user-facing privacy control. We only report durable success after the empty store is
    /// written; otherwise the current session is cleared but the user is warned that old on-disk
    /// history may return after a restart.
    private func confirmClearHistory() {
        guard let frecency else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear JBar Search History?"
        alert.informativeText = "This removes remembered opened paths and query choices. Your files, configuration, and index are not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = frecency.clear()
        let persisted = frecency.save()
        panel.refreshResults()
        if persisted {
            Log.app.notice("search history cleared (entries=\(removed))")
        } else {
            Log.app.error("search history cleared in memory but could not be persisted")
            let failure = NSAlert()
            failure.messageText = "Search History Could Not Be Saved"
            failure.informativeText = "JBar cleared history for this session, but could not replace its history file. The previous history may return after JBar restarts. Check the permissions of JBar's Application Support folder and try again."
            failure.alertStyle = .critical
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    /// ~/Library/Application Support/JBar/history.json
    nonisolated static func historyURL() -> URL {
        if let root = Runtime.testStateRoot {
            return root.appendingPathComponent("history.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JBar", isDirectory: true).appendingPathComponent("history.json")
    }

    private func startIndexer() {
        var options = config.coordinatorOptions()
        if let root = Runtime.testStateRoot {
            options.snapshotURL = root.appendingPathComponent("index.bin")
            options.watchFileSystem = false
        }
        let c = IndexCoordinator(options: options)
        c.onStoreChanged = { [weak self] store in
            Task { @MainActor [weak self] in
                guard let engine = self?.engine else { return }
                await engine.update(store: store)
                Log.index.debug("store generation \(store.generation) with \(store.count) items")
            }
        }
        c.onStatusChanged = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                statusMenu.update(status: status)
                // While the first crawl runs, an empty result set means "not indexed yet", not "no such file".
                panel.indexingNote = AppDelegate.indexingNote(for: status)
            }
        }
        coordinator = c
        c.start()
        Log.app.notice("indexer started")
    }

    // MARK: - Hotkey

    private var hotkeyDisplay: String {
        if hotkey.isRegistered, hotkey.modifiers == CarbonHotkey.fallbackModifiers, hotkey.keyCode == CarbonHotkey.fallbackKeyCode,
           config.hotkey != "ctrl+option+space" {
            return "⌃⌥Space"
        }
        return demo ? "⌥Space" : Config.hotkeyDisplay(config.hotkey)
    }

    /// Register `spec`; on failure fall back to ⌃⌥Space and show a menu warning.
    private func registerHotkey(_ spec: String) {
        hotkey.handler = { [weak self] in self?.panel.toggle() }
        var status: OSStatus = -1
        var parsed = false
        if demo {
            status = hotkey.register(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_Space))
            parsed = true
        } else if let p = Config.parseHotkey(spec) {
            status = hotkey.register(modifiers: p.carbonModifiers, keyCode: p.keyCode)
            parsed = true
        }
        if status == noErr {
            statusMenu?.setHotkeyWarning(nil)
            Log.hotkey.notice("hotkey registered (status=\(status))")
        } else {
            let reason = parsed ? "'\(spec)' could not be registered (OSStatus \(status))" : "'\(spec)' is not a valid hotkey"
            let fb = hotkey.register(modifiers: CarbonHotkey.fallbackModifiers, keyCode: CarbonHotkey.fallbackKeyCode)
            let detail = fb == noErr ? "\(reason); using ⌃⌥Space" : "\(reason); fallback ⌃⌥Space failed too (OSStatus \(fb))"
            Log.hotkey.error("hotkey registration failed (status=\(status)); fallback status=\(fb)")
            statusMenu?.setHotkeyWarning(detail)
        }
        statusMenu?.hotkeyDisplay = hotkeyDisplay
        panel?.settings.hotkeyDisplay = hotkeyDisplay
    }

    // MARK: - Login item

    private func applyLoginItem(enabled: Bool) {
        guard LoginItem.isInstalledInApplications else {
            statusMenu.setLoginItemNote("Launch at Login needs JBar in /Applications (run make install)")
            statusMenu.setLoginItem(enabled: false, requiresApproval: false)
            Log.app.notice("login item skipped: bundle not in an Applications directory")
            return
        }
        statusMenu.setLoginItemNote(nil)
        if enabled {
            // Always enter the shared fail-closed policy. It is a no-op for
            // `.enabled` / `.requiresApproval`, while ambiguous states remain visible as errors.
            if let err = LoginItem.register() {
                statusMenu.setLoginItemNote("Launch at Login failed: \(err)")
            }
        } else {
            // Always enter the shared fail-closed policy. It is a no-op for
            // `.notRegistered`, while `.notFound` and future states must remain
            // visible as errors rather than being silently presented as off.
            if let err = LoginItem.unregister() { statusMenu.setLoginItemNote("Launch at Login failed: \(err)") }
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        let s = LoginItem.status
        statusMenu.setLoginItem(enabled: s == .enabled, requiresApproval: s == .requiresApproval)
    }

    /// Menu toggle: flips the desired `launchAtLogin` state (persisted) and applies it.
    private func toggleLoginItem() {
        guard !demo else { return }
        // Desired state is the negation of the CURRENTLY DESIRED state, not of the live SMAppService
        // status: when the item is registered-but-.requiresApproval the status is not `.enabled`, so
        // keying off status would compute `true` and leave the toggle a no-op that can never turn it off.
        let currentlyOn = LoginItem.status == .enabled || (LoginItem.status == .requiresApproval && config.launchAtLogin)
        let desired = !currentlyOn
        config.launchAtLogin = desired
        applyLoginItem(enabled: desired)
        // If the user is turning it ON but macOS needs approval, send them to Login Items settings.
        if desired, LoginItem.status == .requiresApproval { LoginItem.openSettings() }
        do { try config.save(to: configURL) } catch {
            let ns = error as NSError
            Log.app.error("could not save config: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
        }
    }
}
