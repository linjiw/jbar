import Foundation

// MARK: - Item classification

/// Coarse type of an indexed item. Stored as one byte per item. Order matters only for
/// `Ranking.typeBoost`; keep it stable because it is persisted in snapshots.
public enum ItemKind: UInt8, Codable, CaseIterable, Sendable {
    case app = 0
    case folder = 1
    case document = 2   // pdf doc docx pages key numbers md txt xlsx pptx rtf epub csv
    case image = 3
    case video = 4
    case audio = 5
    case code = 6       // swift py js ts go rs c h cpp java rb sh json yaml toml …
    case archive = 7    // zip dmg tar gz 7z pkg
    case other = 8
    case packageInternal = 9 // reserved; files inside a non-.app package (not indexed in v1)

    /// Classify a regular file by its lowercase extension (no leading dot).
    public static func forExtension(_ ext: String) -> ItemKind {
        if documentExts.contains(ext) { return .document }
        if imageExts.contains(ext) { return .image }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if codeExts.contains(ext) { return .code }
        if archiveExts.contains(ext) { return .archive }
        return .other
    }

    public static let documentExts: Set<String> = ["pdf","doc","docx","pages","key","numbers","md","txt","xlsx","xls","pptx","ppt","rtf","epub","csv","tex","bib","ipynb","odt","ods","odp"]
    public static let imageExts: Set<String> = ["png","jpg","jpeg","gif","heic","heif","webp","tiff","tif","bmp","svg","psd","ai","raw","cr2","dng","icns","ico"]
    public static let videoExts: Set<String> = ["mp4","mov","mkv","avi","m4v","webm","mpg","mpeg","wmv","flv"]
    public static let audioExts: Set<String> = ["mp3","m4a","wav","aac","flac","ogg","aiff","aif","wma"]
    public static let codeExts: Set<String> = ["swift","py","js","ts","tsx","jsx","go","rs","c","h","cpp","hpp","cc","m","mm","java","kt","rb","sh","zsh","bash","json","yaml","yml","toml","xml","html","css","scss","sql","r","jl","lua","pl","php","cs","dart","vue","svelte","makefile","cmake","gradle","dockerfile","env","lock","cfg","ini","conf","plist"]
    public static let archiveExts: Set<String> = ["zip","dmg","tar","gz","tgz","bz2","xz","7z","rar","pkg","iso","jar","war"]
}

/// Per-item bit flags. Stored as one byte per item.
public struct ItemFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Lives under a DOWNRANK directory (build/, dist/, vendor/ …). See `Exclusions.downrankNames`.
    public static let junk      = ItemFlags(rawValue: 1 << 0)
    /// Lives under a cloud-provider root (names-only crawl).
    public static let cloud     = ItemFlags(rawValue: 1 << 1)
    /// Hidden file (dot-name or hidden attribute).
    public static let hidden    = ItemFlags(rawValue: 1 << 2)
    /// A package directory other than .app (indexed as a leaf).
    public static let package   = ItemFlags(rawValue: 1 << 3)
    /// Symbolic link (never followed).
    public static let symlink   = ItemFlags(rawValue: 1 << 4)
    /// An .app bundle.
    public static let appBundle = ItemFlags(rawValue: 1 << 5)
    /// Name starts with "." or "~$" (extra junk penalty).
    public static let dotName   = ItemFlags(rawValue: 1 << 6)
}

// MARK: - Searchable text

/// A pre-analysed string ready for the scorer: case/diacritic-folded UTF-8 bytes, a per-byte
/// boundary bonus, a 64-bit character-presence mask and packed word initials.
/// Produced by `TextAnalyzer.analyze(_:)`. Used for app aliases (display/localized/pinyin names)
/// and for queries; the per-item equivalents live in the `IndexStore` arenas.
public struct SearchString: Hashable, Codable, Sendable {
    public var folded: [UInt8]
    public var bonus: [UInt8]
    public var mask: UInt64
    public var initials: UInt64
    public init(folded: [UInt8], bonus: [UInt8], mask: UInt64, initials: UInt64) {
        self.folded = folded; self.bonus = bonus; self.mask = mask; self.initials = initials
    }
}

/// Extra searchable data attached to an app item (side table, only ~hundreds of entries).
public struct AppInfo: Hashable, Codable, Sendable {
    public var bundleID: String?
    /// Display name shown in the UI (what Finder shows, `.app` stripped).
    public var displayName: String
    /// All alternative searchable strings: CFBundleName, localized names, pinyin full, pinyin initials.
    /// The primary name is already in the item arenas; these are extras. De-duplicated, folded.
    public var aliases: [SearchString]
    public init(bundleID: String?, displayName: String, aliases: [SearchString]) {
        self.bundleID = bundleID; self.displayName = displayName; self.aliases = aliases
    }
}

// MARK: - Directory table

/// One directory in the `IndexStore` directory table. Roots have `parent == -1` and their `name`
/// is the absolute path. Children store only their own component name.
public struct DirEntry: Hashable, Codable, Sendable {
    public var parent: Int32
    public var nameStart: Int32
    public var nameLen: UInt16
    public init(parent: Int32, nameStart: Int32, nameLen: UInt16) {
        self.parent = parent; self.nameStart = nameStart; self.nameLen = nameLen
    }
}

// MARK: - IndexStore (immutable generation)

/// An immutable, cache-linear snapshot of everything JBar can search.
///
/// Built by `IndexBuilder`; the search engine only ever reads it. Indexer/FSEvents build a *new*
/// store and swap the reference atomically (`IndexStore` is a final class so the swap is one
/// pointer assignment and in-flight searches keep their generation alive).
///
/// Memory: ~60–85 bytes per item plus names. 400k items ≈ 30 MB, 1M ≈ 80 MB.
public final class IndexStore: @unchecked Sendable {
    public let count: Int

    // Per-item parallel arrays (all `count` long).
    public let dirId: [Int32]
    public let nameStart: [Int32]     // into foldedArena / bonusArena
    public let nameLen: [UInt16]
    public let displayStart: [Int32]  // into displayArena (original case, UTF-8)
    public let displayLen: [UInt16]
    public let mask: [UInt64]
    public let initials: [UInt64]
    public let mtime: [UInt32]        // seconds since 2001-01-01 (Foundation reference date), 0 = unknown
    public let kind: [UInt8]          // ItemKind.rawValue
    public let flags: [UInt8]         // ItemFlags.rawValue
    public let depth: [UInt8]
    public let extId: [Int16]         // index into `extensions`, -1 = none

    // Arenas.
    public let foldedArena: [UInt8]
    public let bonusArena: [UInt8]    // parallel to foldedArena
    public let displayArena: [UInt8]

    // Directory table.
    public let dirs: [DirEntry]
    public let dirArena: [UInt8]

    // Side tables.
    public let extensions: [String]              // interned lowercase extensions
    public let appInfo: [Int32: AppInfo]         // item index -> extra app data
    public let appItems: [Int32]                 // all item indices with kind == .app (sorted)

    /// Monotonic generation number (for UI "is this result stale?" checks and snapshot headers).
    public let generation: UInt64
    /// FSEvents last event id the store is consistent with (0 = unknown → full recrawl on next start).
    public let fsEventId: UInt64
    /// Wall-clock time the store was built.
    public let builtAt: Date

    public init(count: Int, dirId: [Int32], nameStart: [Int32], nameLen: [UInt16], displayStart: [Int32], displayLen: [UInt16],
                mask: [UInt64], initials: [UInt64], mtime: [UInt32], kind: [UInt8], flags: [UInt8], depth: [UInt8], extId: [Int16],
                foldedArena: [UInt8], bonusArena: [UInt8], displayArena: [UInt8], dirs: [DirEntry], dirArena: [UInt8],
                extensions: [String], appInfo: [Int32: AppInfo], appItems: [Int32], generation: UInt64, fsEventId: UInt64, builtAt: Date) {
        precondition(dirId.count == count && nameStart.count == count && nameLen.count == count && displayStart.count == count
                     && displayLen.count == count && mask.count == count && initials.count == count && mtime.count == count
                     && kind.count == count && flags.count == count && depth.count == count && extId.count == count,
                     "IndexStore: parallel arrays must all have `count` elements")
        precondition(foldedArena.count == bonusArena.count, "IndexStore: bonus arena must parallel folded arena")
        self.count = count
        self.dirId = dirId; self.nameStart = nameStart; self.nameLen = nameLen
        self.displayStart = displayStart; self.displayLen = displayLen
        self.mask = mask; self.initials = initials; self.mtime = mtime
        self.kind = kind; self.flags = flags; self.depth = depth; self.extId = extId
        self.foldedArena = foldedArena; self.bonusArena = bonusArena; self.displayArena = displayArena
        self.dirs = dirs; self.dirArena = dirArena
        self.extensions = extensions; self.appInfo = appInfo; self.appItems = appItems
        self.generation = generation; self.fsEventId = fsEventId; self.builtAt = builtAt
    }

    /// An empty store (used before the first crawl / snapshot load).
    public static let empty = IndexStore(count: 0, dirId: [], nameStart: [], nameLen: [], displayStart: [], displayLen: [],
                                         mask: [], initials: [], mtime: [], kind: [], flags: [], depth: [], extId: [],
                                         foldedArena: [], bonusArena: [], displayArena: [], dirs: [], dirArena: [],
                                         extensions: [], appInfo: [:], appItems: [], generation: 0, fsEventId: 0, builtAt: .distantPast)

    // MARK: Accessors

    @inlinable public func itemKind(_ i: Int) -> ItemKind { ItemKind(rawValue: kind[i]) ?? .other }
    @inlinable public func itemFlags(_ i: Int) -> ItemFlags { ItemFlags(rawValue: flags[i]) }

    /// Display (original-case) name of item `i`.
    public func name(of i: Int) -> String {
        let s = Int(displayStart[i]), l = Int(displayLen[i])
        return String(decoding: displayArena[s..<(s + l)], as: UTF8.self)
    }

    /// Folded name bytes of item `i` as an `ArraySlice` (no copy).
    @inlinable public func foldedName(of i: Int) -> ArraySlice<UInt8> {
        let s = Int(nameStart[i]); return foldedArena[s..<(s + Int(nameLen[i]))]
    }

    /// Bonus bytes of item `i`, parallel to `foldedName(of:)`.
    @inlinable public func bonus(of i: Int) -> ArraySlice<UInt8> {
        let s = Int(nameStart[i]); return bonusArena[s..<(s + Int(nameLen[i]))]
    }

    /// Lowercase extension of item `i` or nil.
    public func ext(of i: Int) -> String? {
        let e = extId[i]; return e >= 0 ? extensions[Int(e)] : nil
    }

    /// Absolute path of directory `d` (reconstructed by walking parents; < 1 µs typical).
    public func dirPath(_ d: Int32) -> String {
        var comps: [Substring] = []
        var cur = d
        var guardCount = 0
        while cur >= 0 && guardCount < 4096 {
            let e = dirs[Int(cur)]
            let s = Int(e.nameStart), l = Int(e.nameLen)
            comps.append(Substring(String(decoding: dirArena[s..<(s + l)], as: UTF8.self)))
            cur = e.parent
            guardCount += 1
        }
        // comps = [leaf, ..., root(abs path)]
        var out = String(comps.last ?? "")
        for c in comps.dropLast().reversed() {
            if !out.hasSuffix("/") { out.append("/") }
            out.append(contentsOf: c)
        }
        return out
    }

    /// File-system name of item `i`. For `.app` bundles the stored name is the bundle name WITHOUT the
    /// `.app` suffix (so "code" matches "Visual Studio Code", and the `app` token never matches "app"),
    /// so the suffix is re-attached here. Apps' localized display names live in `appInfo[i].displayName`.
    public func fileName(of i: Int) -> String {
        let n = name(of: i)
        if flags[i] & ItemFlags.appBundle.rawValue != 0 && !n.lowercased().hasSuffix(".app") { return n + ".app" }
        return n
    }

    /// Absolute path of item `i`.
    public func path(of i: Int) -> String {
        let dir = dirPath(dirId[i])
        let n = fileName(of: i)
        if dir.hasSuffix("/") { return dir + n }
        return dir + "/" + n
    }

    /// `~`-abbreviated parent directory for display.
    public func parentDisplayPath(of i: Int, home: String = NSHomeDirectory()) -> String {
        let dir = dirPath(dirId[i])
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }
}

// MARK: - IndexBuilder

/// Mutable builder that accumulates items and produces an `IndexStore`.
///
/// Not thread-safe; use from one queue. Typical use: crawler calls `addRoot`/`addDir`/`addItem`,
/// then `build(generation:fsEventId:)`. The builder can be reused after `build()` to publish
/// partial generations during the first crawl (arrays are copied on build).
public final class IndexBuilder {
    private var dirId: [Int32] = []
    private var nameStart: [Int32] = []
    private var nameLen: [UInt16] = []
    private var displayStart: [Int32] = []
    private var displayLen: [UInt16] = []
    private var mask: [UInt64] = []
    private var initials: [UInt64] = []
    private var mtime: [UInt32] = []
    private var kind: [UInt8] = []
    private var flags: [UInt8] = []
    private var depth: [UInt8] = []
    private var extId: [Int16] = []
    private var foldedArena: [UInt8] = []
    private var bonusArena: [UInt8] = []
    private var displayArena: [UInt8] = []
    private var dirs: [DirEntry] = []
    private var dirArena: [UInt8] = []
    private var extensions: [String] = []
    private var extIndex: [String: Int16] = [:]
    private var appInfo: [Int32: AppInfo] = [:]
    private var appItems: [Int32] = []
    /// Absolute-path → dir id for root entries (parent == -1), so a path is registered as a root only once
    /// even when several per-root builders that each synthesised the same parent are merged via `append`.
    private var rootDirIndex: [String: Int32] = [:]

    public private(set) var count: Int = 0
    public var dirCount: Int { dirs.count }

    public init() {}

    /// Reserve capacity for an expected number of items (avoids re-allocation churn on big crawls).
    public func reserve(items: Int, dirs: Int) {
        dirId.reserveCapacity(items); nameStart.reserveCapacity(items); nameLen.reserveCapacity(items)
        displayStart.reserveCapacity(items); displayLen.reserveCapacity(items); mask.reserveCapacity(items)
        initials.reserveCapacity(items); mtime.reserveCapacity(items); kind.reserveCapacity(items)
        flags.reserveCapacity(items); depth.reserveCapacity(items); extId.reserveCapacity(items)
        foldedArena.reserveCapacity(items * 24); bonusArena.reserveCapacity(items * 24); displayArena.reserveCapacity(items * 24)
        self.dirs.reserveCapacity(dirs); dirArena.reserveCapacity(dirs * 16)
    }

    /// Register a root directory (absolute path). Returns its dir id.
    @discardableResult
    public func addRoot(_ absolutePath: String) -> Int32 {
        if let existing = rootDirIndex[absolutePath] { return existing }
        let id = appendDir(parent: -1, name: absolutePath)
        rootDirIndex[absolutePath] = id
        return id
    }

    /// Register a child directory by component name. Returns its dir id.
    @discardableResult
    public func addDir(parent: Int32, name: String) -> Int32 {
        appendDir(parent: parent, name: name)
    }

    private func appendDir(parent: Int32, name: String) -> Int32 {
        let bytes = Array(name.utf8)
        let start = Int32(dirArena.count)
        dirArena.append(contentsOf: bytes)
        dirs.append(DirEntry(parent: parent, nameStart: start, nameLen: UInt16(clamping: bytes.count)))
        return Int32(dirs.count - 1)
    }

    /// Add one item. `name` is the display name (for apps: `.app` already stripped).
    /// `analyzed` is the pre-analysed searchable form of `name` (from `TextAnalyzer.analyze`).
    /// Returns the item index.
    @discardableResult
    public func addItem(dir: Int32, name: String, analyzed: SearchString, kind k: ItemKind, flags f: ItemFlags,
                        mtime t: Date?, depth d: Int, ext: String?, app: AppInfo? = nil) -> Int32 {
        let idx = Int32(count)
        dirId.append(dir)
        nameStart.append(Int32(foldedArena.count))
        nameLen.append(UInt16(clamping: analyzed.folded.count))
        foldedArena.append(contentsOf: analyzed.folded)
        bonusArena.append(contentsOf: analyzed.bonus)
        let disp = Array(name.utf8)
        displayStart.append(Int32(displayArena.count))
        displayLen.append(UInt16(clamping: disp.count))
        displayArena.append(contentsOf: disp)
        mask.append(analyzed.mask)
        initials.append(analyzed.initials)
        mtime.append(t.map { UInt32(clamping: Int($0.timeIntervalSinceReferenceDate)) } ?? 0)
        kind.append(k.rawValue)
        flags.append(f.rawValue)
        depth.append(UInt8(clamping: d))
        if let e = ext, !e.isEmpty, e.count <= 8 {
            if let id = extIndex[e] { extId.append(id) } else {
                let id = Int16(clamping: extensions.count); extensions.append(e); extIndex[e] = id; extId.append(id)
            }
        } else { extId.append(-1) }
        if let a = app { appInfo[idx] = a }
        if k == .app { appItems.append(idx) }
        count += 1
        return idx
    }

    /// Append every directory and item of `other` into this builder, remapping directory ids, arena
    /// offsets and interned extension ids so the result is identical to having crawled `other`'s work
    /// directly into `self`. Used to merge per-root builders produced by a parallel crawl (each root is
    /// crawled into its own builder off-thread, then merged here in root order on one thread).
    ///
    /// `other`'s roots keep `parent == -1`; all other dir parents and every item's `dirId` shift by the
    /// current directory count. Item order within `other` is preserved and appended after `self`'s items,
    /// so `appItems` stays sorted.
    public func append(_ other: IndexBuilder) {
        let itemOffset = Int32(count)
        let foldedOffset = Int32(foldedArena.count)
        let displayOffset = Int32(displayArena.count)

        // Directories: remap each of other's dir ids into self, deduping ROOT entries (parent == -1) by
        // their absolute-path name so merged per-root builders share one synthetic parent — matching the
        // serial crawl and keeping `DirIndex` (used by incremental FSEvents updates) able to resolve paths.
        // Parents always precede their children in build order, so `dirRemap[parent]` is set before use.
        var dirRemap = [Int32](repeating: 0, count: other.dirs.count)
        dirs.reserveCapacity(dirs.count + other.dirs.count)
        for (i, e) in other.dirs.enumerated() {
            let s = Int(e.nameStart), l = Int(e.nameLen)
            let nameBytes = other.dirArena[s..<(s + l)]
            if e.parent < 0 {
                let name = String(decoding: nameBytes, as: UTF8.self)
                if let existing = rootDirIndex[name] { dirRemap[i] = existing; continue }
                let start = Int32(dirArena.count)
                dirArena.append(contentsOf: nameBytes)
                dirs.append(DirEntry(parent: -1, nameStart: start, nameLen: e.nameLen))
                let id = Int32(dirs.count - 1); dirRemap[i] = id; rootDirIndex[name] = id
            } else {
                let start = Int32(dirArena.count)
                dirArena.append(contentsOf: nameBytes)
                dirs.append(DirEntry(parent: dirRemap[Int(e.parent)], nameStart: start, nameLen: e.nameLen))
                dirRemap[i] = Int32(dirs.count - 1)
            }
        }

        // Extension id remap: intern each of other's extensions into self, build old→new table.
        var extRemap = [Int16](repeating: -1, count: other.extensions.count)
        for (oldId, name) in other.extensions.enumerated() {
            if let id = extIndex[name] { extRemap[oldId] = id }
            else { let id = Int16(clamping: extensions.count); extensions.append(name); extIndex[name] = id; extRemap[oldId] = id }
        }

        // Arenas (shared offsets for every item).
        foldedArena.append(contentsOf: other.foldedArena)
        bonusArena.append(contentsOf: other.bonusArena)
        displayArena.append(contentsOf: other.displayArena)

        // Items (parallel arrays).
        let n = other.count
        dirId.reserveCapacity(count + n)
        for i in 0..<n { dirId.append(dirRemap[Int(other.dirId[i])]) }
        for i in 0..<n { nameStart.append(other.nameStart[i] + foldedOffset) }
        nameLen.append(contentsOf: other.nameLen)
        for i in 0..<n { displayStart.append(other.displayStart[i] + displayOffset) }
        displayLen.append(contentsOf: other.displayLen)
        mask.append(contentsOf: other.mask)
        initials.append(contentsOf: other.initials)
        mtime.append(contentsOf: other.mtime)
        kind.append(contentsOf: other.kind)
        flags.append(contentsOf: other.flags)
        depth.append(contentsOf: other.depth)
        for i in 0..<n { let e = other.extId[i]; extId.append(e < 0 ? -1 : extRemap[Int(e)]) }

        // Side tables.
        for (k, v) in other.appInfo { appInfo[k + itemOffset] = v }
        for a in other.appItems { appItems.append(a + itemOffset) }

        count += n
    }

    /// Produce an immutable store. The builder keeps its contents (so partial publishing works).
    public func build(generation: UInt64, fsEventId: UInt64 = 0, builtAt: Date = Date()) -> IndexStore {
        IndexStore(count: count, dirId: dirId, nameStart: nameStart, nameLen: nameLen, displayStart: displayStart, displayLen: displayLen,
                   mask: mask, initials: initials, mtime: mtime, kind: kind, flags: flags, depth: depth, extId: extId,
                   foldedArena: foldedArena, bonusArena: bonusArena, displayArena: displayArena, dirs: dirs, dirArena: dirArena,
                   extensions: extensions, appInfo: appInfo, appItems: appItems, generation: generation, fsEventId: fsEventId, builtAt: builtAt)
    }
}

// MARK: - Search results

/// One row shown in the panel. Produced by `SearchEngine`, consumed by the UI.
public struct ResultRow: Hashable, Sendable {
    public var itemIndex: Int
    public var name: String
    public var path: String
    public var parentDisplay: String
    public var kind: ItemKind
    public var isApp: Bool { kind == .app }
    /// Byte offsets (into the folded name) of matched characters, for highlighting. Converted to
    /// character ranges by the UI via `TextAnalyzer.characterOffsets`.
    public var matchedByteOffsets: [Int]
    public var score: Int
    public var tier: Int
    public init(itemIndex: Int, name: String, path: String, parentDisplay: String, kind: ItemKind, matchedByteOffsets: [Int], score: Int, tier: Int) {
        self.itemIndex = itemIndex; self.name = name; self.path = path; self.parentDisplay = parentDisplay
        self.kind = kind; self.matchedByteOffsets = matchedByteOffsets; self.score = score; self.tier = tier
    }
}
