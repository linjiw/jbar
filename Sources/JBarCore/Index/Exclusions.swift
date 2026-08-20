import Foundation
import Darwin

/// What the crawler skips (EXCLUDE) and what it indexes-but-downranks (DOWNRANK). DESIGN.md §4.3–4.4.
/// Owner: indexer agent.
///
/// Name checks are case-insensitive (`excludeNames`/`downrankNames` are stored lowercased by `defaults(home:)`;
/// `isExcludedName`/`isDownrankName` lowercase their argument). Path checks are case-insensitive too, because the
/// default APFS volume is case-insensitive and users type `~/library` as often as `~/Library`.
public struct Exclusions: Sendable, Equatable {
    /// Directory names never descended (case-insensitive, any depth). The directory itself IS still indexed as an item.
    public var excludeNames: Set<String>
    /// Absolute paths never descended (after `~` expansion). A trailing `*` on the last component is a prefix glob
    /// (`~/Creative Cloud Files*`, `~/Pictures/*.photoslibrary` → treat `*` anywhere in the last component as glob).
    public var excludePaths: [String]
    /// Directory names whose descendants get the `junk` flag (−30).
    public var downrankNames: Set<String>
    public var includeHidden: Bool
    public var maxDepth: Int
    /// Stop descending a directory with more direct entries than this (still index the directory itself).
    public var maxDirEntries: Int
    /// Children of directories with more entries than this get the `junk` flag.
    public var downrankDirEntries: Int

    public init(excludeNames: Set<String>, excludePaths: [String], downrankNames: Set<String>, includeHidden: Bool = false,
                maxDepth: Int = 12, maxDirEntries: Int = 20_000, downrankDirEntries: Int = 5_000) {
        self.excludeNames = excludeNames; self.excludePaths = excludePaths; self.downrankNames = downrankNames
        self.includeHidden = includeHidden; self.maxDepth = maxDepth; self.maxDirEntries = maxDirEntries; self.downrankDirEntries = downrankDirEntries
    }

    /// The default lists from DESIGN.md §4.3/4.4, with `~` expanded to `home`.
    public static func defaults(home: String = NSHomeDirectory()) -> Exclusions {
        Exclusions(excludeNames: Set(defaultExcludeNames.map { $0.lowercased() }),
                   excludePaths: defaultExcludePaths.map { expandTilde($0, home: home) },
                   downrankNames: Set(defaultDownrankNames.map { $0.lowercased() }))
    }

    /// Expand a leading `~` (alone or `~/…`) to `home`, and drop a trailing `/` (except for "/").
    /// Other paths are returned unchanged apart from the trailing-slash normalisation.
    public static func expandTilde(_ path: String, home: String) -> String {
        let h = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        var p = path
        if p == "~" { p = h } else if p.hasPrefix("~/") { p = h + p.dropFirst(1) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Default exclude names (lowercase) — exposed so Config can show/merge them.
    public static let defaultExcludeNames: [String] = [
        "node_modules", ".git", ".svn", ".hg", "__pycache__", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache",
        "site-packages", "dist-packages", ".npm", ".yarn", ".pnpm-store", ".gradle", ".m2", "pods", "deriveddata", ".build", ".swiftpm",
        "xcuserdata", ".trash", ".cache", "caches", "tmp", "temp", "$recycle.bin", ".spotlight-v100", ".fseventsd", ".documentrevisions-v100",
        ".temporaryitems", ".cargo", ".rustup", ".nvm", ".pyenv", ".conda", "bower_components", ".next", ".nuxt", ".parcel-cache", ".turbo",
    ]
    /// Default exclude paths (with `~`).
    public static let defaultExcludePaths: [String] = [
        "~/Library", "~/miniconda3", "~/anaconda3", "~/go/pkg", "~/Creative Cloud Files*", "~/Pictures/*.photoslibrary",
        "~/Music/Music", "~/Movies/TV", "~/.Trash", "~/Applications", "~/Public",
    ]
    /// Default downrank names (lowercase).
    public static let defaultDownrankNames: [String] = [
        "build", "builds", "out", "dist", "target", "bin", "obj", ".idea", ".vscode", "coverage", "logs", "log", "vendor", "third_party",
        "external", "deps", "backups", "backup", "application support", "containers", "group containers", "generated", "gen", ".angular",
    ]
    /// Package extensions (other than .app) indexed as leaf items, never descended.
    public static let packageExtensions: Set<String> = [
        "photoslibrary", "xcodeproj", "xcworkspace", "playground", "framework", "bundle", "numbers", "pages", "key", "rtfd", "scriptd",
        "fcpbundle", "lproj", "xcarchive", "imovielibrary", "tvlibrary", "musiclibrary", "band", "sparsebundle", "pkg", "mpkg", "prefpane",
    ]

    /// True if a directory with this (last-component) name must not be descended.
    public func isExcludedName(_ name: String) -> Bool { excludeNames.contains(name.lowercased()) }

    /// True if this absolute directory path must not be descended (exact or glob match on excludePaths).
    /// Builds a matcher on every call; hot loops should build one `ExcludedPathMatcher` and reuse it.
    public func isExcludedPath(_ absolutePath: String) -> Bool { ExcludedPathMatcher(patterns: excludePaths).matches(absolutePath) }

    /// True if descendants of a directory with this name should be flagged junk.
    public func isDownrankName(_ name: String) -> Bool { downrankNames.contains(name.lowercased()) }

    /// Stable hash of all fields; stored in snapshot headers so a changed config forces a recrawl.
    /// FNV-1a 64 over a canonical serialisation: every list sorted, fields separated by `\u{1}`/`\u{2}`.
    public var stableHash: UInt64 {
        var h = FNV1a()
        for n in excludeNames.sorted() { h.update(n); h.update("\u{1}") }
        h.update("\u{2}")
        for p in excludePaths.sorted() { h.update(p); h.update("\u{1}") }
        h.update("\u{2}")
        for n in downrankNames.sorted() { h.update(n); h.update("\u{1}") }
        h.update("\u{2}")
        h.update("\(includeHidden ? 1 : 0)|\(maxDepth)|\(maxDirEntries)|\(downrankDirEntries)")
        return h.value
    }
}

/// Pre-split exclude-path patterns for fast repeated matching (one per crawl).
/// Exact patterns go into a lowercase set; glob patterns (`*` in the last component) are matched with `fnmatch(3)`
/// on the last component after comparing the parent directory.
public struct ExcludedPathMatcher: Sendable {
    private let exact: Set<String>
    private let globs: [(parent: String, pattern: String)]

    public init(patterns: [String]) {
        var ex = Set<String>()
        var gl: [(String, String)] = []
        for raw in patterns {
            let p = ExcludedPathMatcher.normalize(raw)
            guard !p.isEmpty else { continue }
            let last = p.lastComponent
            if last.contains("*") {
                gl.append((ExcludedPathMatcher.parent(of: p), last))
            } else {
                ex.insert(p)
            }
        }
        exact = ex; globs = gl
    }

    /// True if `absolutePath` (any case, optional trailing slash) matches one of the patterns.
    public func matches(_ absolutePath: String) -> Bool {
        let p = ExcludedPathMatcher.normalize(absolutePath)
        if exact.contains(p) { return true }
        guard !globs.isEmpty else { return false }
        let parent = ExcludedPathMatcher.parent(of: p)
        let last = p.lastComponent
        for g in globs where g.parent == parent {
            if fnmatch(g.pattern, last, 0) == 0 { return true }
        }
        return false
    }

    /// Lowercase + strip trailing slashes (keep "/").
    static func normalize(_ s: String) -> String {
        var p = s.lowercased()
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Parent directory string of a normalised path ("/" for top-level entries, "" for relative names).
    static func parent(of p: String) -> String {
        guard let slash = p.lastIndex(of: "/") else { return "" }
        return slash == p.startIndex ? "/" : String(p[..<slash])
    }
}

private extension String {
    var lastComponent: String {
        guard let slash = lastIndex(of: "/") else { return self }
        return String(self[index(after: slash)...])
    }
}

/// 64-bit FNV-1a hasher (stable across processes and OS versions, unlike `Hasher`).
public struct FNV1a {
    public private(set) var value: UInt64 = 0xcbf29ce484222325
    public init() {}
    public mutating func update(_ s: String) { for b in s.utf8 { update(byte: b) } }
    public mutating func update(byte b: UInt8) { value ^= UInt64(b); value = value &* 0x100000001b3 }
    public mutating func update(_ bytes: [UInt8]) { for b in bytes { update(byte: b) } }
    public mutating func update(_ v: UInt64) { for i in 0..<8 { update(byte: UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    /// One-shot hash of a string.
    public static func hash(_ s: String) -> UInt64 { var h = FNV1a(); h.update(s); return h.value }
}
