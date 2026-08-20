import Foundation

/// User configuration, `~/.config/jbar/config.json`. DESIGN.md §7.6. Owner: config agent.
/// Unknown keys are ignored; missing keys take defaults; `~` allowed in paths; invalid JSON → caller keeps last-good.
public struct Config: Codable, Equatable, Sendable {
    public var hotkey: String = "option+space"
    public var launchAtLogin: Bool = true
    /// How many results a query returns — i.e. how many you can scroll through. Only `visibleRows`
    /// of them fit on screen at once; the rest are reachable with ↓ / the scroll wheel.
    public var maxResults: Int = 40
    /// How many result rows are visible without scrolling (the panel's height).
    public var visibleRows: Int = 8
    public var appsFirstCap: Int = 5
    /// "mouse" | "main" | "active"
    public var screen: String = "mouse"
    public var restoreQueryOnReopen: Bool = false
    public var showRecentsOnEmpty: Bool = true
    public var appDirectories: [String] = AppScanner.defaultRoots
    public var fileRoots: [String] = ["~"]
    public var excludePaths: [String] = Exclusions.defaultExcludePaths
    public var excludeNames: [String] = Exclusions.defaultExcludeNames
    public var downrankNames: [String] = Exclusions.defaultDownrankNames
    public var includeHidden: Bool = false
    public var maxDepth: Int = 12
    public var maxIndexedItems: Int = 1_000_000

    public init() {}
    public static let `default` = Config()

    /// ~/.config/jbar/config.json (honours $XDG_CONFIG_HOME).
    public static func defaultURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        // Per the XDG Base Directory spec, an empty or relative XDG_CONFIG_HOME is treated as unset
        // (an empty/relative value would otherwise resolve against the process cwd — "/" for a GUI app).
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("jbar", isDirectory: true).appendingPathComponent("config.json")
    }

    public enum LoadResult: Sendable, Equatable {
        case loaded(Config)
        case created(Config)          // file was missing; defaults written
        case invalid(String)          // parse error message; caller keeps last-good
    }

    // MARK: - Codable (every key optional so partial / unknown JSON works)

    /// JSON keys. Declared explicitly so the on-disk format is stable even if property order changes.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey, launchAtLogin, maxResults, visibleRows, appsFirstCap, screen, restoreQueryOnReopen, showRecentsOnEmpty
        case appDirectories, fileRoots, excludePaths, excludeNames, downrankNames, includeHidden, maxDepth
        case maxIndexedItems
    }

    /// Decode leniently: every key is optional and falls back to its default; unknown keys are ignored by `JSONDecoder`.
    /// A key that is present but has the wrong type is still an error (so typos in values are surfaced to the user).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        let legacyMaxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults)
        maxResults = legacyMaxResults ?? d.maxResults
        visibleRows = try c.decodeIfPresent(Int.self, forKey: .visibleRows) ?? d.visibleRows
        // Migration: before `visibleRows` existed, `maxResults` meant "rows shown on screen". A config
        // written then would pin the result pool to the panel height and never have anything to scroll
        // to, so reinterpret it: the old value becomes the visible height, and the pool takes the new
        // default (never smaller than what the user asked to see).
        if !c.contains(.visibleRows), let legacy = legacyMaxResults {
            visibleRows = legacy
            maxResults = max(d.maxResults, legacy)
        }
        appsFirstCap = try c.decodeIfPresent(Int.self, forKey: .appsFirstCap) ?? d.appsFirstCap
        screen = try c.decodeIfPresent(String.self, forKey: .screen) ?? d.screen
        restoreQueryOnReopen = try c.decodeIfPresent(Bool.self, forKey: .restoreQueryOnReopen) ?? d.restoreQueryOnReopen
        showRecentsOnEmpty = try c.decodeIfPresent(Bool.self, forKey: .showRecentsOnEmpty) ?? d.showRecentsOnEmpty
        appDirectories = try c.decodeIfPresent([String].self, forKey: .appDirectories) ?? d.appDirectories
        fileRoots = try c.decodeIfPresent([String].self, forKey: .fileRoots) ?? d.fileRoots
        excludePaths = try c.decodeIfPresent([String].self, forKey: .excludePaths) ?? d.excludePaths
        excludeNames = try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? d.excludeNames
        downrankNames = try c.decodeIfPresent([String].self, forKey: .downrankNames) ?? d.downrankNames
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? d.maxDepth
        maxIndexedItems = try c.decodeIfPresent(Int.self, forKey: .maxIndexedItems) ?? d.maxIndexedItems
    }

    /// Encode every key (so the written file documents all options). Paths are written exactly as stored (`~` kept).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(maxResults, forKey: .maxResults)
        try c.encode(visibleRows, forKey: .visibleRows)
        try c.encode(appsFirstCap, forKey: .appsFirstCap)
        try c.encode(screen, forKey: .screen)
        try c.encode(restoreQueryOnReopen, forKey: .restoreQueryOnReopen)
        try c.encode(showRecentsOnEmpty, forKey: .showRecentsOnEmpty)
        try c.encode(appDirectories, forKey: .appDirectories)
        try c.encode(fileRoots, forKey: .fileRoots)
        try c.encode(excludePaths, forKey: .excludePaths)
        try c.encode(excludeNames, forKey: .excludeNames)
        try c.encode(downrankNames, forKey: .downrankNames)
        try c.encode(includeHidden, forKey: .includeHidden)
        try c.encode(maxDepth, forKey: .maxDepth)
        try c.encode(maxIndexedItems, forKey: .maxIndexedItems)
    }

    // MARK: - Load / save

    /// The JSON encoder used for the config file: pretty-printed, sorted keys, `/` not escaped (paths stay readable).
    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    /// Pretty JSON bytes of this config (what `save` writes).
    public func jsonData() throws -> Data {
        try Config.makeEncoder().encode(self)
    }

    /// Parse JSON bytes. Throws a `DecodingError` / `CocoaError` with a human-readable description on invalid input.
    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    /// Load from `url`; if missing, write defaults (pretty JSON, sorted keys) and return `.created`.
    ///
    /// - missing file → parent directories created, defaults written, `.created(.default)`
    ///   (if the defaults cannot be written, `.invalid(message)` — the caller should still run with defaults)
    /// - unreadable file or invalid / mistyped JSON → `.invalid(message)` (message includes the decoding error)
    /// - otherwise `.loaded(config)`; unknown keys ignored, missing keys defaulted.
    public static func load(from url: URL = defaultURL()) -> LoadResult {
        let path = url.path
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            do {
                try Config.default.save(to: url)
                return .created(.default)
            } catch {
                return .invalid("Could not write default config to \(path): \(error.localizedDescription)")
            }
        }
        if isDir.boolValue {
            return .invalid("Config path \(path) is a directory, not a file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid("Could not read \(path): \(error.localizedDescription)")
        }
        do {
            return .loaded(try decode(data))
        } catch {
            return .invalid("Invalid config \(path): \(describe(error))")
        }
    }

    /// Human-readable description of a JSON decoding error (key path + reason where available).
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            // JSONDecoder wraps JSONSerialization syntax errors in DecodingError.dataCorrupted, but be safe.
            let ns = error as NSError
            let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String
            return debug.map { "\(ns.localizedDescription) (\($0))" } ?? ns.localizedDescription
        }
        func keyPath(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "" : " at '\(p)'"
        }
        func underlying(_ ctx: DecodingError.Context) -> String {
            guard let u = ctx.underlyingError as NSError? else { return "" }
            let debug = (u.userInfo[NSDebugDescriptionErrorKey] as? String) ?? u.localizedDescription
            return debug.isEmpty ? "" : " (\(debug))"
        }
        switch decodingError {
        case .dataCorrupted(let ctx):
            return "\(ctx.debugDescription)\(keyPath(ctx))\(underlying(ctx))"
        case .typeMismatch(let type, let ctx):
            return "wrong type\(keyPath(ctx)): expected \(type) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "missing value\(keyPath(ctx)): expected \(type) — \(ctx.debugDescription)"
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)'\(keyPath(ctx)) — \(ctx.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    /// Write pretty JSON atomically (creates parent dirs).
    public func save(to url: URL = defaultURL()) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    // MARK: - Derived objects

    /// Expand a leading `~` to `home` (`~` → home, `~/x` → home/x); other paths are returned unchanged.
    /// A trailing `/` is dropped (except for `/` itself) so comparisons are canonical.
    public static func expandTilde(_ path: String, home: String) -> String {
        var p = path
        if p == "~" { p = home }
        else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Build `Exclusions` from this config (lowercased names, `~` expanded).
    public func exclusions(home: String = NSHomeDirectory()) -> Exclusions {
        Exclusions(excludeNames: Set(excludeNames.map { $0.lowercased() }),
                   excludePaths: excludePaths.map { Config.expandTilde($0, home: home) },
                   downrankNames: Set(downrankNames.map { $0.lowercased() }),
                   includeHidden: includeHidden,
                   maxDepth: maxDepth)
    }

    /// `IndexCoordinator.Options` derived from this config. App/file roots are passed as written (`~` is expanded by the
    /// scanner/crawler, see `AppScanner.scan` and `IndexCoordinator.Options.fileRoots`).
    public func coordinatorOptions(home: String = NSHomeDirectory()) -> IndexCoordinator.Options {
        var o = IndexCoordinator.Options(exclusions: exclusions(home: home))
        o.home = home
        o.appRoots = appDirectories
        o.fileRoots = fileRoots
        o.maxItems = maxIndexedItems
        return o
    }

    // MARK: - Hotkey

    /// Carbon modifier masks (`Carbon.HIToolbox/Events.h`: `cmdKey = 1 << 8`, `shiftKey = 1 << 9`, `optionKey = 1 << 11`,
    /// `controlKey = 1 << 12`). Defined numerically so `JBarCore` does not link Carbon.
    public enum CarbonModifier {
        public static let cmd: UInt32 = 1 << 8
        public static let shift: UInt32 = 1 << 9
        public static let option: UInt32 = 1 << 11
        public static let control: UInt32 = 1 << 12
    }

    /// Modifier names accepted in the config → Carbon mask.
    static let modifierNames: [String: UInt32] = [
        "cmd": CarbonModifier.cmd, "command": CarbonModifier.cmd,
        "ctrl": CarbonModifier.control, "control": CarbonModifier.control,
        "option": CarbonModifier.option, "alt": CarbonModifier.option,
        "shift": CarbonModifier.shift,
    ]

    /// Key names accepted in the config → virtual key code (`kVK_*` from `Carbon.HIToolbox/Events.h`, ANSI layout).
    static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
            "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
            "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
            "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65,
            "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40,
            "f18": 0x4F, "f19": 0x50,
        ]
        // Aliases for punctuation that is awkward inside JSON strings.
        m["minus"] = m["-"]; m["equal"] = m["="]; m["equals"] = m["="]
        m["comma"] = m[","]; m["period"] = m["."]; m["slash"] = m["/"]
        m["backslash"] = m["\\"]; m["grave"] = m["`"]; m["backtick"] = m["`"]
        m["semicolon"] = m[";"]; m["quote"] = m["'"]; m["leftbracket"] = m["["]; m["rightbracket"] = m["]"]
        return m
    }()

    /// Lowercased, trimmed `+`-separated tokens of a hotkey string; nil if any token is empty.
    static func hotkeyTokens(_ s: String) -> [String]? {
        let tokens = s.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty, !tokens.contains(where: { $0.isEmpty }) else { return nil }
        return tokens
    }

    /// Parse `hotkey` ("option+space", "cmd+shift+k", "ctrl+option+space") into Carbon modifiers + virtual key code.
    /// Returns nil for unknown keys/modifiers. Modifier names: cmd|command, ctrl|control, option|alt, shift. Keys: space, a–z, 0–9,
    /// f1–f19, return, tab, escape, `-`, `=`, `[`, `]`, `;`, `'`, `,`, `.`, `/`, `` ` ``, `\`.
    /// Tokens are case-insensitive and may be padded with spaces. Exactly one key and at least one modifier are required.
    public static func parseHotkey(_ s: String) -> (carbonModifiers: UInt32, keyCode: UInt32)? {
        guard let tokens = hotkeyTokens(s) else { return nil }
        var mods: UInt32 = 0
        var key: UInt32?
        for t in tokens {
            if let m = modifierNames[t] {
                mods |= m
            } else if let k = keyCodes[t] {
                if key != nil { return nil }          // two keys
                key = k
            } else {
                return nil                            // unknown token
            }
        }
        guard let keyCode = key, mods != 0 else { return nil }
        return (mods, keyCode)
    }

    /// Display glyphs for special keys; letters are uppercased, f-keys become "F1", punctuation is shown as-is.
    static let keyDisplay: [String: String] = [
        "space": "Space", "return": "↩", "enter": "↩", "tab": "⇥", "escape": "⎋", "esc": "⎋", "delete": "⌫", "backspace": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "minus": "-", "equal": "=", "equals": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "grave": "`", "backtick": "`", "semicolon": ";", "quote": "'", "leftbracket": "[", "rightbracket": "]",
    ]

    /// Human-readable form of a hotkey string for menus ("⌥Space"). Modifiers in the standard ⌃⌥⇧⌘ order.
    /// An unparseable string is returned unchanged.
    public static func hotkeyDisplay(_ s: String) -> String {
        guard let parsed = parseHotkey(s), let tokens = hotkeyTokens(s) else { return s }
        var out = ""
        if parsed.carbonModifiers & CarbonModifier.control != 0 { out += "⌃" }
        if parsed.carbonModifiers & CarbonModifier.option != 0 { out += "⌥" }
        if parsed.carbonModifiers & CarbonModifier.shift != 0 { out += "⇧" }
        if parsed.carbonModifiers & CarbonModifier.cmd != 0 { out += "⌘" }
        let keyToken = tokens.first { modifierNames[$0] == nil } ?? ""
        out += keyDisplay[keyToken] ?? keyToken.uppercased()
        return out
    }
}

// MARK: - ConfigWatcher

/// Watches the config file and re-loads on change (handles editors that atomically replace the file by watching
/// the parent directory as well). Owner: config agent. Uses `DispatchSource.makeFileSystemObjectSource`.
///
/// Two sources are armed: one on the file (`.write .delete .rename .extend .attrib`) and one on the parent directory
/// (`.write`, fired when entries are added/removed/renamed — i.e. when an editor writes a temp file and renames it over
/// the config). Every event is debounced 300 ms, then `Config.load(from:)` runs: a valid file → `onChange`, a missing
/// file → defaults are re-created and `onChange(default)`, invalid JSON → `onError(message)` (the caller keeps its
/// last-good config). If the file was deleted or replaced the file source is re-armed on a fresh descriptor.
/// `start()`/`stop()` are idempotent and thread-safe; descriptors are closed in the sources' cancel handlers.
public final class ConfigWatcher {
    public let url: URL
    /// Debounce interval between the last file-system event and the reload.
    public static let debounce: DispatchTimeInterval = .milliseconds(300)

    private let queue: DispatchQueue
    private let onChange: (Config) -> Void
    private let onError: (String) -> Void
    /// Serial queue owning all mutable state below (sources, pending reload, started flag).
    private let workQueue = DispatchQueue(label: "com.linji.jbar.configwatcher", qos: .utility)
    private static let workQueueKey = DispatchSpecificKey<Void>()
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var started = false

    /// Called on `queue` with each successful reload (debounced ~300 ms); invalid JSON → `onError(message)`.
    public init(url: URL = Config.defaultURL(), queue: DispatchQueue = .main, onChange: @escaping (Config) -> Void, onError: @escaping (String) -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        self.onError = onError
        workQueue.setSpecific(key: ConfigWatcher.workQueueKey, value: ())
    }

    deinit {
        // `stop()` is safe from any thread; if we are somehow on the work queue it runs inline.
        stop()
    }

    /// Run `body` on the work queue synchronously (inline if already there, to avoid self-deadlock).
    private func sync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: ConfigWatcher.workQueueKey) != nil { body() } else { workQueue.sync(execute: body) }
    }

    /// Begin watching. Idempotent. If the parent directory does not exist it is created (so the first save can be
    /// observed); if it still cannot be watched, `onError` is called once and the watcher stays stopped.
    public func start() {
        sync {
            guard !started else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let ds = makeSource(path: dir.path, events: ConfigWatcher.dirEvents, isFile: false) else {
                let msg = "Cannot watch config directory \(dir.path): \(String(cString: strerror(errno)))"
                queue.async { [onError] in onError(msg) }
                return
            }
            started = true
            dirSource = ds
            armFileSource()
        }
    }

    /// Stop watching and drop any pending reload. Idempotent.
    public func stop() {
        sync {
            guard started else { return }
            started = false
            pendingReload?.cancel()
            pendingReload = nil
            fileSource?.cancel(); fileSource = nil
            dirSource?.cancel(); dirSource = nil
        }
    }

    /// Create + resume a file-system object source on `path` (opened `O_EVTONLY`), delivering on `workQueue`.
    /// The descriptor is closed in the cancel handler. Returns nil if the path cannot be opened.
    private func makeSource(path: String, events: DispatchSource.FileSystemEvent, isFile: Bool) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: workQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            self.handleEvent(source?.data ?? [], isFileSource: isFile)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Events watched on the config file itself.
    static let fileEvents: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .extend, .attrib]
    /// Events watched on the parent directory (`.write` = entries added/removed/renamed; delete/rename = the directory
    /// itself went away, e.g. `rm -rf ~/.config/jbar`, after which it is re-created and re-armed).
    static let dirEvents: DispatchSource.FileSystemEvent = [.write, .delete, .rename]

    /// (Re)open the file source if the file exists and we are not already watching a live descriptor.
    private func armFileSource() {
        guard started, fileSource == nil else { return }
        fileSource = makeSource(path: url.path, events: ConfigWatcher.fileEvents, isFile: true)
    }

    /// (Re)open the directory source after the directory was deleted/renamed (re-created by `Config.load`).
    private func armDirSource() {
        guard started, dirSource == nil else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirSource = makeSource(path: dir.path, events: ConfigWatcher.dirEvents, isFile: false)
    }

    /// Handle one source event on `workQueue`: drop a source whose inode went away (delete/rename) and debounce a reload.
    private func handleEvent(_ data: DispatchSource.FileSystemEvent, isFileSource: Bool) {
        guard started else { return }
        if !data.intersection([.delete, .rename]).isEmpty {
            if isFileSource { fileSource?.cancel(); fileSource = nil } else { dirSource?.cancel(); dirSource = nil }
        }
        scheduleReload()
    }

    /// Debounce: (re)schedule the reload `debounce` after the latest event.
    private func scheduleReload() {
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = item
        workQueue.asyncAfter(deadline: .now() + ConfigWatcher.debounce, execute: item)
    }

    /// Load the file and report on `queue`; re-arm the file source if it was replaced. Runs on `workQueue`.
    private func reload() {
        guard started else { return }
        pendingReload = nil
        let result = Config.load(from: url)
        armDirSource()
        armFileSource()
        switch result {
        case .loaded(let c), .created(let c):
            queue.async { [onChange] in onChange(c) }
        case .invalid(let message):
            queue.async { [onError] in onError(message) }
        }
    }
}
