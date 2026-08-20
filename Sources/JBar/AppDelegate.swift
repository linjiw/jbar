import AppKit
import Carbon.HIToolbox
import JBarCore

/// Wires the product together (DESIGN.md §2.3, §8): config → frecency → engine → indexer → menu →
/// hotkey → panel → config hot reload → login item → first-run panel.
///
/// `JBAR_DEMO=1` swaps the engine for `DemoSearchProvider` and skips config/indexer/frecency/login
/// item entirely (UI-only smoke testing without folder-access prompts).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo = Runtime.isDemo
    private var config = Config.default
    private var configURL = Config.defaultURL()
    private var firstRun = false

    private var frecency: FrecencyStore?
    private var engine: SearchEngine?
    private var coordinator: IndexCoordinator?
    private var configWatcher: ConfigWatcher?
    private var launcher: AppLauncher!
    private var panel: SearchPanel!
    private var statusMenu: StatusMenu!
    private let hotkey = CarbonHotkey()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.app.notice("JBar \(Runtime.version, privacy: .public) launching (demo=\(self.demo)) bundle=\(Bundle.main.bundlePath, privacy: .public)")
        MainMenu.install(openConfig: #selector(openConfigFile(_:)), target: self)

        if !demo { loadConfig() }
        let provider: SearchProviding = demo ? DemoSearchProvider() : makeEngine()
        launcher = AppLauncher(frecency: frecency)
        panel = SearchPanel(provider: provider, launcher: launcher, settings: SearchPanel.Settings(config: config, hotkeyDisplay: hotkeyDisplay))
        panel.onOpenConfig = { [weak self] in self?.openConfigFile(nil) }

        statusMenu = StatusMenu(hotkeyDisplay: hotkeyDisplay)
        statusMenu.onOpen = { [weak self] in self?.panel.show() }
        statusMenu.onRebuild = { [weak self] in self?.coordinator?.rebuild() }
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

    /// Debug aid (`JBAR_SNAPSHOT_PATH`): wait for the index, run a query, render the panel to PNG, quit.
    private func scheduleSnapshot(to path: String) {
        let query = Runtime.snapshotQuery
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.panel.show()
            self.panel.setQuery(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let ok = self.panel.renderSnapshot(to: URL(fileURLWithPath: path))
                Log.app.notice("snapshot '\(query, privacy: .public)' → \(path, privacy: .public) ok=\(ok)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("terminating")
        hotkey.unregister()
        configWatcher?.stop()
        coordinator?.stop()
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
            Log.app.notice("config created at \(self.configURL.path, privacy: .public) (first run)")
        case .invalid(let message):
            config = .default
            Log.app.error("config invalid: \(message, privacy: .public); using defaults")
            DispatchQueue.main.async { [weak self] in self?.statusMenu?.setConfigError(message) }
        }
    }

    private func startConfigWatcher() {
        let watcher = ConfigWatcher(url: configURL, queue: .main, onChange: { [weak self] newConfig in
            self?.applyConfig(newConfig)
        }, onError: { [weak self] message in
            Log.app.error("config reload failed: \(message, privacy: .public)")
            self?.statusMenu.setConfigError(message)
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
    static func indexOptionsChanged(_ a: Config, _ b: Config) -> Bool {
        a.appDirectories != b.appDirectories || a.fileRoots != b.fileRoots || a.excludePaths != b.excludePaths
            || a.excludeNames != b.excludeNames || a.downrankNames != b.downrankNames || a.includeHidden != b.includeHidden
            || a.maxDepth != b.maxDepth || a.maxIndexedItems != b.maxIndexedItems
    }

    /// Open the config file in the default editor (creating it with defaults first if missing).
    @objc func openConfigFile(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            do { try config.save(to: configURL) } catch {
                Log.app.error("could not write config: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !NSWorkspace.shared.open(configURL) {
            Log.app.error("could not open config file \(self.configURL.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        }
    }

    // MARK: - Engine & indexer

    private func makeEngine() -> SearchEngine {
        let store = FrecencyStore(fileURL: Self.historyURL())
        store.load()
        frecency = store
        let e = SearchEngine(frecency: store)
        engine = e
        return e
    }

    /// ~/Library/Application Support/JBar/history.json
    static func historyURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JBar", isDirectory: true).appendingPathComponent("history.json")
    }

    private func startIndexer() {
        let c = IndexCoordinator(options: config.coordinatorOptions())
        c.onStoreChanged = { [weak self] store in
            guard let engine = self?.engine else { return }
            Task { await engine.update(store: store) }
            Log.index.debug("store generation \(store.generation) with \(store.count) items")
        }
        c.onStatusChanged = { [weak self] status in
            self?.statusMenu.update(status: status)
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
            Log.hotkey.notice("hotkey '\(spec, privacy: .public)' registered (status=\(status))")
        } else {
            let reason = parsed ? "'\(spec)' could not be registered (OSStatus \(status))" : "'\(spec)' is not a valid hotkey"
            let fb = hotkey.register(modifiers: CarbonHotkey.fallbackModifiers, keyCode: CarbonHotkey.fallbackKeyCode)
            let detail = fb == noErr ? "\(reason); using ⌃⌥Space" : "\(reason); fallback ⌃⌥Space failed too (OSStatus \(fb))"
            Log.hotkey.error("\(detail, privacy: .public)")
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
            Log.app.notice("login item skipped: bundle not in /Applications (\(Bundle.main.bundlePath, privacy: .public))")
            return
        }
        statusMenu.setLoginItemNote(nil)
        let status = LoginItem.status
        if enabled, status != .enabled, status != .requiresApproval {
            if let err = LoginItem.register() { statusMenu.setLoginItemNote("Launch at Login failed: \(err)") }
        } else if !enabled, status == .enabled || status == .requiresApproval {
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
            Log.app.error("could not save config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
