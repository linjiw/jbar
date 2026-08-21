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

    /// A precise validation failure suitable for the menu-bar config warning and CLI diagnostics.
    public struct ValidationError: Error, LocalizedError, Equatable, Sendable {
        public let key: String
        public let value: String
        public let requirement: String

        public init(key: String, value: String, requirement: String) {
            self.key = key
            self.value = value
            self.requirement = requirement
        }

        public var errorDescription: String? {
            "invalid value for '\(key)': \(value); expected \(requirement)"
        }
    }

    /// ~/.config/jbar/config.json (honours $XDG_CONFIG_HOME).
    public static func defaultURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        // Per the XDG Base Directory spec, an empty or relative XDG_CONFIG_HOME is treated as unset
        // (an empty/relative value would otherwise resolve against the process cwd — "/" for a GUI app).
        let base = env["XDG_CONFIG_HOME"].flatMap {
            SafetyLimits.isSafeAbsolutePath($0) ? URL(fileURLWithPath: $0) : nil
        }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("jbar", isDirectory: true).appendingPathComponent("config.json")
    }

    public enum LoadResult: Sendable, Equatable {
        case loaded(Config)
        case created(Config)          // file was missing; defaults written
        case invalid(String)          // parse error message; caller keeps last-good
    }

    /// Non-mutating load result for diagnostics and benchmarks. Unlike `LoadResult`, a missing file
    /// is represented explicitly and never causes the default config to be written.
    public enum ReadOnlyLoadResult: Sendable, Equatable {
        case loaded(Config)
        case missing
        case invalid(String)
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
            visibleRows = min(max(legacy, SafetyLimits.visibleRows.lowerBound), SafetyLimits.visibleRows.upperBound)
            maxResults = max(d.maxResults, legacy)
        }
        appsFirstCap = try c.decodeIfPresent(Int.self, forKey: .appsFirstCap) ?? min(d.appsFirstCap, maxResults)
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
        if !c.contains(.visibleRows), let legacy = legacyMaxResults, legacy < SafetyLimits.maxResults.lowerBound {
            throw ValidationError(key: "maxResults", value: String(legacy),
                                  requirement: "a positive legacy row count")
        }
        try validate()
    }

    /// Encode every key (so the written file documents all options). Paths are written exactly as stored (`~` kept).
    public func encode(to encoder: Encoder) throws {
        // `Config` is publicly Encodable, so protect callers that bypass `jsonData()` too. Validation
        // uses only bounded linear scans and rejects an oversized aggregate before JSONEncoder builds
        // a potentially much larger escaped Data value.
        try validate()
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
        try validate()
        let data = try Config.makeEncoder().encode(self)
        guard data.count <= SafetyLimits.maxConfigFileBytes else {
            throw ValidationError(key: "configFile", value: "\(data.count) bytes",
                                  requirement: "at most \(SafetyLimits.maxConfigFileBytes) bytes after encoding")
        }
        return data
    }

    /// Parse JSON bytes. Throws a `DecodingError` / `CocoaError` with a human-readable description on invalid input.
    public static func decode(_ data: Data) throws -> Config {
        guard data.count <= SafetyLimits.maxConfigFileBytes else {
            throw ValidationError(key: "configFile", value: "\(data.count) bytes",
                                  requirement: "at most \(SafetyLimits.maxConfigFileBytes) bytes")
        }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Validate every setting that can drive allocation, traversal, or UI geometry.
    /// Decoding and saving both use this single policy; hot reload therefore reports an error and keeps
    /// the last-known-good config instead of applying a partially clamped configuration.
    public func validate() throws {
        var estimatedJSONBytes = 4_096 // keys, numbers, booleans, indentation, and structural slack
        func require(_ condition: @autoclosure () -> Bool, key: String, value: String, expected: String) throws {
            guard condition() else { throw ValidationError(key: key, value: value, requirement: expected) }
        }
        func accountJSONString(_ value: String, key: String) throws {
            // Keep ordinary ASCII configurations close to their actual encoded size while still
            // costing controls and Unicode at their longest legal JSON escape. Thirty-two bytes
            // covers quotes, comma, indentation, and array structure per value.
            let escaped = SafetyLimits.jsonEscapedStringByteUpperBound(value)
            let (withOverhead, addOverflow) = escaped.addingReportingOverflow(32)
            let (next, totalOverflow) = estimatedJSONBytes.addingReportingOverflow(withOverhead)
            guard !addOverflow, !totalOverflow,
                  next <= SafetyLimits.maxConfigFileBytes else {
                throw ValidationError(key: "configFile", value: "aggregate text is too large (at \(key))",
                                      requirement: "a JSON encoding no larger than \(SafetyLimits.maxConfigFileBytes) bytes")
            }
            estimatedJSONBytes = next
        }
        func requireRange(_ value: Int, _ range: ClosedRange<Int>, key: String) throws {
            try require(range.contains(value), key: key, value: String(value),
                        expected: "an integer in \(range.lowerBound)...\(range.upperBound)")
        }
        func requireArray(_ values: [String], key: String, maxCount: Int, maxBytes: Int,
                          kind: String, absoluteOrTildePath: Bool = false) throws {
            try require(values.count <= maxCount, key: key, value: "\(values.count) entries",
                        expected: "at most \(maxCount) entries")
            for (index, value) in values.enumerated() {
                guard SafetyLimits.utf8Fits(value, maxBytes: maxBytes) else {
                    throw ValidationError(key: "\(key)[\(index)]", value: "more than \(maxBytes) UTF-8 bytes",
                                          requirement: "a \(kind) no longer than \(maxBytes) UTF-8 bytes")
                }
                try require(!SafetyLimits.containsNULByte(value), key: "\(key)[\(index)]", value: "contains NUL",
                            expected: "a \(kind) without U+0000")
                try accountJSONString(value, key: "\(key)[\(index)]")
                if absoluteOrTildePath {
                    let validPath = SafetyLimits.isSafeAbsoluteOrTildePath(value)
                    try require(validPath, key: "\(key)[\(index)]", value: value,
                                expected: "an absolute path or a path beginning with ~/ (wildcards allowed)")
                }
            }
        }

        try requireRange(maxResults, SafetyLimits.maxResults, key: "maxResults")
        try requireRange(visibleRows, SafetyLimits.visibleRows, key: "visibleRows")
        try require(visibleRows <= maxResults,
                    key: "visibleRows", value: String(visibleRows),
                    expected: "an integer no greater than maxResults (\(maxResults))")
        try require(appsFirstCap >= 0 && appsFirstCap <= maxResults,
                    key: "appsFirstCap", value: String(appsFirstCap),
                    expected: "an integer in 0...maxResults (\(maxResults))")
        try requireRange(maxDepth, SafetyLimits.maxDepth, key: "maxDepth")
        try requireRange(maxIndexedItems, SafetyLimits.maxIndexedItems, key: "maxIndexedItems")

        try require(SafetyLimits.utf8Fits(hotkey, maxBytes: SafetyLimits.maxHotkeyUTF8Bytes),
                    key: "hotkey", value: "more than \(SafetyLimits.maxHotkeyUTF8Bytes) UTF-8 bytes",
                    expected: "at most \(SafetyLimits.maxHotkeyUTF8Bytes) UTF-8 bytes")
        try require(!SafetyLimits.containsNULByte(hotkey), key: "hotkey", value: "contains NUL",
                    expected: "text without U+0000")
        try accountJSONString(hotkey, key: "hotkey")
        // Invalid hotkey syntax deliberately remains a recoverable runtime condition: CarbonHotkey
        // falls back to Ctrl+Option+Space and presents a warning. Unknown screen values likewise keep
        // the established "mouse" fallback. Bound their sizes without changing those product semantics.
        try require(SafetyLimits.utf8Fits(screen, maxBytes: SafetyLimits.maxSettingUTF8Bytes),
                    key: "screen", value: "more than \(SafetyLimits.maxSettingUTF8Bytes) UTF-8 bytes",
                    expected: "at most \(SafetyLimits.maxSettingUTF8Bytes) UTF-8 bytes")
        try require(!SafetyLimits.containsNULByte(screen), key: "screen", value: "contains NUL",
                    expected: "text without U+0000")
        try accountJSONString(screen, key: "screen")

        try requireArray(appDirectories, key: "appDirectories", maxCount: SafetyLimits.maxRootEntries,
                         maxBytes: SafetyLimits.maxPathUTF8Bytes, kind: "path", absoluteOrTildePath: true)
        try requireArray(fileRoots, key: "fileRoots", maxCount: SafetyLimits.maxRootEntries,
                         maxBytes: SafetyLimits.maxPathUTF8Bytes, kind: "path", absoluteOrTildePath: true)
        try requireArray(excludePaths, key: "excludePaths", maxCount: SafetyLimits.maxExcludedPathEntries,
                         maxBytes: SafetyLimits.maxPathUTF8Bytes, kind: "path", absoluteOrTildePath: true)
        try requireArray(excludeNames, key: "excludeNames", maxCount: SafetyLimits.maxNameEntries,
                         maxBytes: SafetyLimits.maxNameUTF8Bytes, kind: "name")
        try requireArray(downrankNames, key: "downrankNames", maxCount: SafetyLimits.maxNameEntries,
                         maxBytes: SafetyLimits.maxNameUTF8Bytes, kind: "name")
    }

    /// Load from `url`; if missing, write defaults (pretty JSON, sorted keys) and return `.created`.
    ///
    /// - missing file → parent directories created, defaults written, `.created(.default)`
    ///   (if the defaults cannot be written, `.invalid(message)` — the caller should still run with defaults)
    /// - unreadable file or invalid / mistyped JSON → `.invalid(message)` (message includes the decoding error)
    /// - otherwise `.loaded(config)`; unknown keys ignored, missing keys defaulted.
    public static func load(from url: URL = defaultURL()) -> LoadResult {
        switch loadReadOnly(from: url) {
        case .loaded(let config):
            return .loaded(config)
        case .invalid(let message):
            return .invalid(message)
        case .missing:
            do {
                try Config.default.save(to: url)
                return .created(.default)
            } catch {
                return .invalid("Could not write default config to \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Load without creating or changing any file. The same descriptor-based, bounded, no-symlink
    /// reader as normal config loading is used, so read-only tooling cannot block on a FIFO or follow
    /// a replaced symbolic link.
    public static func loadReadOnly(from url: URL = defaultURL()) -> ReadOnlyLoadResult {
        let path = url.path
        let data: Data?
        do {
            data = try SecureFileIO.readRegularFile(at: url, maxBytes: SafetyLimits.maxConfigFileBytes)
        } catch {
            if (error as? SecureFileIO.Failure) == .notRegularFile {
                return .invalid("Config path \(path) is not a regular file (directory or symbolic link)")
            }
            return .invalid("Could not read config \(path): \(describe(error))")
        }
        guard let data else {
            return .missing
        }
        do {
            return .loaded(try decode(data))
        } catch {
            return .invalid("Invalid config \(path): \(describe(error))")
        }
    }

    /// Human-readable description of a JSON decoding error (key path + reason where available).
    static func describe(_ error: Error) -> String {
        if let validation = error as? ValidationError {
            return validation.errorDescription ?? "invalid configuration"
        }
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
        let data = try jsonData()
        let ownsDirectory = url.standardizedFileURL.deletingLastPathComponent()
            == Config.defaultURL().standardizedFileURL.deletingLastPathComponent()
        try SecureFileIO.writeAtomicallyOwnerOnly(data, to: url,
                                                  enforcePrivateDirectory: ownsDirectory)
    }

    // MARK: - Derived objects

    /// Expand a leading `~` to `home` (`~` → home, `~/x` → home/x); other paths are returned unchanged.
    /// A trailing `/` is dropped (except for `/` itself) so comparisons are canonical.
    public static func expandTilde(_ path: String, home: String) -> String {
        Exclusions.expandTilde(path, home: home)
    }

    /// Build `Exclusions` from this config (lowercased names, `~` expanded).
    public func exclusions(home: String = NSHomeDirectory()) -> Exclusions {
        Exclusions(excludeNames: Set(excludeNames.map { $0.lowercased() }),
                   excludePaths: excludePaths.map { Config.expandTilde($0, home: home) },
                   downrankNames: Set(downrankNames.map { $0.lowercased() }),
                   includeHidden: includeHidden,
                   maxDepth: min(max(maxDepth, SafetyLimits.maxDepth.lowerBound), SafetyLimits.maxDepth.upperBound))
    }

    /// `IndexCoordinator.Options` derived from this config. App/file roots are passed as written (`~` is expanded by the
    /// scanner/crawler, see `AppScanner.scan` and `IndexCoordinator.Options.fileRoots`).
    public func coordinatorOptions(home: String = NSHomeDirectory()) -> IndexCoordinator.Options {
        var o = IndexCoordinator.Options(exclusions: exclusions(home: home))
        o.home = home
        o.appRoots = appDirectories
        o.fileRoots = fileRoots
        o.maxItems = min(max(maxIndexedItems, SafetyLimits.maxIndexedItems.lowerBound), SafetyLimits.maxIndexedItems.upperBound)
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
    /// Key tokens name fixed US-ANSI physical key positions, not the character produced by the active
    /// keyboard layout. The binding therefore remains stable when the user switches input sources.
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
///
/// Concurrency invariant: `workQueue` owns every mutable field (sources, pending work, lifecycle
/// generation, and `started`). `sync` is the only cross-thread entry and uses a per-instance queue
/// key, so two watchers cannot accidentally treat each other's queue as their own. Callback closures
/// are `@Sendable`, serialized on `callbackQueue`, and re-check the lifecycle generation while
/// synchronized with `stop()`. This queue confinement is the narrow basis for `@unchecked Sendable`.
public final class ConfigWatcher: @unchecked Sendable {
    public let url: URL
    /// Debounce interval between the last file-system event and the reload.
    public static let debounce: DispatchTimeInterval = .milliseconds(300)

    private let callbackQueue: DispatchQueue
    private let onChange: @Sendable (Config) -> Void
    private let onError: @Sendable (String) -> Void
    /// Serial queue owning all mutable state below (sources, pending reload, started flag).
    private let workQueue = DispatchQueue(label: "com.linji.jbar.configwatcher", qos: .utility)
    private let workQueueKey = DispatchSpecificKey<Void>()
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var started = false
    private var generation: UInt64 = 0

    /// Called on `queue` with each successful reload (debounced ~300 ms); invalid JSON → `onError(message)`.
    public init(url: URL = Config.defaultURL(), queue: DispatchQueue = .main,
                onChange: @escaping @Sendable (Config) -> Void,
                onError: @escaping @Sendable (String) -> Void) {
        self.url = url
        // Even if callers provide a concurrent target, configuration callbacks never overlap.
        self.callbackQueue = DispatchQueue(label: "com.linji.jbar.configwatcher.callbacks", target: queue)
        self.onChange = onChange
        self.onError = onError
        workQueue.setSpecific(key: workQueueKey, value: ())
    }

    deinit {
        // `stop()` is safe from any thread; if we are somehow on the work queue it runs inline.
        stop()
    }

    /// Run `body` on the work queue synchronously (inline if already there, to avoid self-deadlock).
    private func sync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil { body() } else { workQueue.sync(execute: body) }
    }

    /// Begin watching. Idempotent. If the parent directory does not exist it is created (so the first save can be
    /// observed); if it still cannot be watched, `onError` is called once and the watcher stays stopped.
    public func start() {
        sync {
            guard !started else { return }
            generation &+= 1
            let attemptGeneration = generation
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let ds = makeSource(path: dir.path, events: ConfigWatcher.dirEvents(), isFile: false) else {
                let msg = "Cannot watch config directory \(dir.path): \(String(cString: strerror(errno)))"
                deliver(generation: attemptGeneration, whenStarted: false) { [onError] in onError(msg) }
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
            // Also invalidates an asynchronous error from a failed start attempt.
            generation &+= 1
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
    private static func fileEvents() -> DispatchSource.FileSystemEvent { [.write, .delete, .rename, .extend, .attrib] }
    /// Events watched on the parent directory (`.write` = entries added/removed/renamed; delete/rename = the directory
    /// itself went away, e.g. `rm -rf ~/.config/jbar`, after which it is re-created and re-armed).
    private static func dirEvents() -> DispatchSource.FileSystemEvent { [.write, .delete, .rename] }

    /// (Re)open the file source if the file exists and we are not already watching a live descriptor.
    private func armFileSource() {
        guard started, fileSource == nil else { return }
        fileSource = makeSource(path: url.path, events: ConfigWatcher.fileEvents(), isFile: true)
    }

    /// (Re)open the directory source after the directory was deleted/renamed (re-created by `Config.load`).
    private func armDirSource() {
        guard started, dirSource == nil else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirSource = makeSource(path: dir.path, events: ConfigWatcher.dirEvents(), isFile: false)
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
        let expectedGeneration = generation
        let result = Config.load(from: url)
        armDirSource()
        armFileSource()
        switch result {
        case .loaded(let c), .created(let c):
            deliver(generation: expectedGeneration, whenStarted: true) { [onChange] in onChange(c) }
        case .invalid(let message):
            deliver(generation: expectedGeneration, whenStarted: true) { [onError] in onError(message) }
        }
    }

    /// Enqueue one callback in order, but suppress it if `stop()` completed or the watcher restarted
    /// before delivery. The callback runs while synchronized with lifecycle changes, so once `stop()`
    /// returns no callback from the stopped generation can still begin or remain in flight.
    private func deliver(generation expectedGeneration: UInt64, whenStarted expectedStarted: Bool,
                         body: @escaping @Sendable () -> Void) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.sync {
                guard self.started == expectedStarted, self.generation == expectedGeneration else { return }
                body()
            }
        }
    }
}
