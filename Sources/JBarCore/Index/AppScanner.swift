import Foundation

/// One discovered application bundle.
public struct ScannedApp: Sendable, Equatable {
    public var url: URL                 // bundle URL as found under its root (symlinks kept; deduped by resolved target)
    public var displayName: String      // what Finder shows, ".app" stripped
    public var bundleID: String?
    public var aliases: [String]        // CFBundleName, CFBundleDisplayName, localized names (raw strings, deduped, != displayName)
    public var mtime: Date?
    public init(url: URL, displayName: String, bundleID: String?, aliases: [String], mtime: Date?) {
        self.url = url; self.displayName = displayName; self.bundleID = bundleID; self.aliases = aliases; self.mtime = mtime
    }

    /// The bundle's file name without the `.app` extension (e.g. `WeChat` for `/Applications/WeChat.app`).
    /// This is the item name stored in the index so that `store.path(of:) + ".app"` is always the real bundle path.
    public var fileName: String { AppScanner.stripAppExtension(url.lastPathComponent) }
}

/// Finds every launchable .app bundle. DESIGN.md §4.1. Owner: indexer agent.
///
/// Roots (default): /Applications (+/Utilities if present), /System/Applications, /System/Applications/Utilities,
/// ~/Applications (incl. `Chrome Apps.localized`), /System/Library/CoreServices/Applications,
/// /System/Library/CoreServices/Finder.app, /Applications/Xcode.app/Contents/Applications.
/// Depth ≤ 2 under each root (so /Applications/Adobe X/Adobe X.app and Cisco/… are found).
/// Resolves symlinks, drops dangling ones, dedupes by realpath, skips CoreServices bundles with LSUIElement=true.
/// Reads Info.plist (CFBundleDisplayName/CFBundleName/CFBundleIdentifier) and
/// Contents/Resources/*.lproj/InfoPlist.strings for localized names (PropertyListSerialization handles binary/UTF-16).
/// `FileManager.default.displayName(atPath:)` is the primary display string. Must finish in < 1 s for ~150 apps.
///
/// Item naming (see `ScannedApp.fileName`): the item name in the store is the bundle's file name without `.app`
/// (`WeChat`), so `store.path(of:) + ".app"` is the bundle path. `AppInfo.displayName` carries the Finder display
/// name; when the two differ (localized Finder name) the display name is also added as a searchable alias.
public enum AppScanner {
    public static let defaultRoots: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "~/Applications", "/System/Library/CoreServices/Applications", "/Applications/Xcode.app/Contents/Applications",
    ]
    public static let extraBundles: [String] = ["/System/Library/CoreServices/Finder.app"]

    /// Maximum number of aliases kept per app.
    public static let maxAliases = 12

    /// Hook for pinyin alias generation (so tests can run before/without the pinyin module).
    /// Default: `Pinyin.aliases(for:)`.
    static var pinyinAliases: (String) -> [SearchString] = { Pinyin.aliases(for: $0) }

    /// Scan the given roots (with `~` expanded). Never throws; unreadable roots are skipped.
    public static func scan(roots: [String] = defaultRoots, extraBundles: [String] = extraBundles) -> [ScannedApp] {
        scan(roots: roots, extraBundles: extraBundles, home: NSHomeDirectory())
    }

    /// `scan` with an explicit home directory for `~` expansion (tests).
    public static func scan(roots: [String], extraBundles: [String], home: String) -> [ScannedApp] {
        var candidates: [Candidate] = []
        for root in roots {
            let path = Exclusions.expandTilde(root, home: home)
            collectCandidates(root: path, into: &candidates)
        }
        for extra in extraBundles {
            let path = Exclusions.expandTilde(extra, home: home)
            candidates.append(Candidate(url: URL(fileURLWithPath: path), skipUIElements: isCoreServicesPath(path)))
        }
        return resolveAndRead(candidates)
    }

    // MARK: Candidate discovery

    private struct Candidate {
        var url: URL
        var skipUIElements: Bool
    }

    private static let listKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]

    private static func isCoreServicesPath(_ p: String) -> Bool { p.hasPrefix("/System/Library/CoreServices") }

    /// Depth ≤ 2: `root/X.app` and `root/Sub/X.app` (Sub = any non-hidden, non-.app directory).
    private static func collectCandidates(root: String, into out: inout [Candidate]) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let entries = list(rootURL) else { return }
        let skipUI = isCoreServicesPath(root)
        for e in entries {
            if e.lastPathComponent.lowercased().hasSuffix(".app") {
                out.append(Candidate(url: e, skipUIElements: skipUI))
            } else if isPlainDirectory(e), let sub = list(e) {
                for s in sub where s.lastPathComponent.lowercased().hasSuffix(".app") {
                    out.append(Candidate(url: s, skipUIElements: skipUI))
                }
            }
        }
    }

    /// List a directory WITHOUT `.skipsHiddenFiles`: on macOS 26 the `/Applications/Safari.app` symlink into the
    /// Cryptex carries the hidden flag and would otherwise be skipped. Dot-names are filtered manually instead.
    private static func list(_ dir: URL) -> [URL]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(listKeys), options: []) else { return nil }
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// A real (non-symlink) directory.
    private static func isPlainDirectory(_ url: URL) -> Bool {
        guard let rv = try? url.resourceValues(forKeys: listKeys) else { return false }
        return (rv.isDirectory ?? false) && !(rv.isSymbolicLink ?? false)
    }

    // MARK: Resolution + reading

    /// Resolve symlinks, drop dangling/non-directory targets, dedupe by resolved path, read bundle metadata in parallel.
    private static func resolveAndRead(_ candidates: [Candidate]) -> [ScannedApp] {
        var seen = Set<String>()
        var resolved: [Candidate] = []
        for c in candidates {
            let target = c.url.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if seen.insert(target.path).inserted {
                // Keep the path the user knows (e.g. /Applications/Safari.app, a symlink into the Cryptex on
                // macOS 26) for display + launch; the resolved target is only used for de-duplication.
                resolved.append(Candidate(url: c.url.standardizedFileURL, skipUIElements: c.skipUIElements))
            }
        }
        // Reading ~700 InfoPlist.strings files serially costs ~0.5 s on this Mac; do bundles in parallel.
        var results = [ScannedApp?](repeating: nil, count: resolved.count)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: resolved.count) { i in
                buf[i] = readBundle(resolved[i].url, skipUIElements: resolved[i].skipUIElements)
            }
        }
        return results.compactMap { $0 }
    }

    /// Read one bundle. Returns nil for LSUIElement helpers when `skipUIElements` is set.
    static func readBundle(_ url: URL, skipUIElements: Bool) -> ScannedApp? {
        let info = readInfoPlist(url)
        if skipUIElements && isUIElement(info["LSUIElement"]) { return nil }
        let fileName = stripAppExtension(url.lastPathComponent)
        var displayName = stripAppExtension(FileManager.default.displayName(atPath: url.path))
        if displayName.isEmpty {
            displayName = nonEmptyString(info["CFBundleDisplayName"]) ?? nonEmptyString(info["CFBundleName"]) ?? fileName
        }
        var aliases: [String] = []
        var seenFolded = Set<String>([TextAnalyzer.fold(displayName), TextAnalyzer.fold(fileName)])
        func addAlias(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, aliases.count < maxAliases else { return }
            if seenFolded.insert(TextAnalyzer.fold(s)).inserted { aliases.append(s) }
        }
        addAlias(nonEmptyString(info["CFBundleDisplayName"]))
        addAlias(nonEmptyString(info["CFBundleName"]))
        for name in localizedNames(url) { addAlias(name) }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ScannedApp(url: url, displayName: displayName, bundleID: nonEmptyString(info["CFBundleIdentifier"]),
                          aliases: aliases, mtime: mtime)
    }

    /// `Contents/Info.plist` as a dictionary (empty on any failure).
    static func readInfoPlist(_ bundle: URL) -> [String: Any] {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistURL.path) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] ?? [:]
    }

    /// LSUIElement may be a Bool, a Number or the string "1"/"YES"/"true".
    static func isUIElement(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "yes", "true"].contains(s.lowercased())
        default: return false
        }
    }

    static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Every CFBundleDisplayName/CFBundleName value in `Contents/Resources/*.lproj/InfoPlist.strings`.
    /// `PropertyListSerialization` parses binary, XML and old-style (`"key" = "value";`, UTF-8/UTF-16) formats.
    static func localizedNames(_ bundle: URL) -> [String] {
        let res = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let lprojs = try? FileManager.default.contentsOfDirectory(atPath: res.path) else { return [] }
        var out: [String] = []
        for l in lprojs where l.hasSuffix(".lproj") {
            let f = res.appendingPathComponent(l).appendingPathComponent("InfoPlist.strings")
            guard let data = FileManager.default.contents(atPath: f.path), !data.isEmpty else { continue }
            guard let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
            if let s = nonEmptyString(dict["CFBundleDisplayName"]) { out.append(s) }
            if let s = nonEmptyString(dict["CFBundleName"]) { out.append(s) }
        }
        return out
    }

    /// "Foo.app" → "Foo" (case-insensitive extension match); other names unchanged.
    static func stripAppExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: Adding to a builder

    /// Add apps to a builder: one item per app (kind .app, flags .appBundle, dir = the app's parent directory root,
    /// depth 1, ext "app") with an `AppInfo` carrying folded aliases + pinyin aliases (`Pinyin.aliases`) for CJK names.
    public static func add(_ apps: [ScannedApp], to builder: IndexBuilder) {
        var rootIds: [String: Int32] = [:]
        for app in apps {
            let parent = app.url.deletingLastPathComponent().path
            let dirId: Int32
            if let id = rootIds[parent] { dirId = id } else { dirId = builder.addRoot(parent); rootIds[parent] = dirId }
            let name = app.fileName
            let analyzed = TextAnalyzer.analyze(name)
            let info = AppInfo(bundleID: app.bundleID, displayName: app.displayName, aliases: searchAliases(for: app, primary: analyzed))
            builder.addItem(dir: dirId, name: name, analyzed: analyzed, kind: .app, flags: [.appBundle], mtime: app.mtime,
                            depth: 1, ext: "app", app: info)
        }
    }

    /// Folded aliases for an app: display name (if ≠ file name), every raw alias, pinyin for the display name and for every
    /// CJK alias. De-duplicated; never contains `primary` (the analysed item name).
    static func searchAliases(for app: ScannedApp, primary: SearchString) -> [SearchString] {
        var out: [SearchString] = []
        var seen = Set<[UInt8]>([primary.folded])
        func push(_ s: SearchString) { if !s.folded.isEmpty && seen.insert(s.folded).inserted { out.append(s) } }
        var texts = [app.displayName]
        texts.append(contentsOf: app.aliases)
        for t in texts {
            push(TextAnalyzer.analyze(t))
            if containsCJK(t) { for p in pinyinAliases(t) { push(p) } }
        }
        return out
    }

    /// CJK Unified Ideograph check (own copy so the scanner does not depend on the pinyin module's stubs).
    static func containsCJK(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
            default: continue
            }
        }
        return false
    }
}
