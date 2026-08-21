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
    /// App originated in the bounded application-catalog scanner rather than a generic file crawl.
    /// Incremental app rescans use this provenance bit to replace only catalog entries even when the
    /// scanner stores a real multi-level directory tree under one shared root.
    public static let appCatalog = ItemFlags(rawValue: 1 << 7)
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
/// Memory: the core arrays use ~60–85 bytes per item plus names. The derived character-mask
/// accelerator adds 38 bits per item (~4.75 bytes; apps are conservatively present in every bitset
/// so aliases cannot be missed). It is rebuilt with each immutable generation and is not persisted
/// in the snapshot.
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

    // Derived search accelerator. There are only 38 meaningful mask bits (a-z, 0-9,
    // punctuation, non-ASCII). Packed bitsets avoid storing the same four-byte item id once per
    // distinct character; cold-query workers enumerate set bits directly without a candidate list.
    let maskBitsets: [[UInt64]]
    let maskBitCounts: [Int]

    /// Fixed-width payload of the derived accelerator (excludes small Swift container overhead).
    public var derivedSearchAcceleratorByteCount: Int {
        maskBitsets.reduce(0) { $0 + $1.count * MemoryLayout<UInt64>.stride }
            + maskBitCounts.count * MemoryLayout<Int>.stride
    }

    /// Monotonic generation number (for UI "is this result stale?" checks and snapshot headers).
    public let generation: UInt64
    /// FSEvents last event id the store is consistent with (0 = unknown → full recrawl on next start).
    public let fsEventId: UInt64
    /// Wall-clock time the store was built.
    public let builtAt: Date

    init(count: Int, dirId: [Int32], nameStart: [Int32], nameLen: [UInt16], displayStart: [Int32], displayLen: [UInt16],
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
        (self.maskBitsets, self.maskBitCounts) = Self.buildMaskBitsets(mask: mask, kind: kind)
        self.generation = generation; self.fsEventId = fsEventId; self.builtAt = builtAt
    }

    /// The least-populated bitset for any bit required by `requiredMask`. Every possible non-app name
    /// match must occur in this set; every app is also included because it may match through an
    /// alias whose characters are absent from the bundle name. nil means no useful mask filter.
    func rarestMaskBitset(requiredMask: UInt64) -> (words: [UInt64], candidateCount: Int)? {
        var bits = requiredMask & Self.searchMaskBits
        guard bits != 0, maskBitsets.count == Self.searchMaskBitCount,
              maskBitCounts.count == Self.searchMaskBitCount else { return nil }
        var bestBit = -1
        var bestCount = Int.max
        while bits != 0 {
            let bit = bits.trailingZeroBitCount
            if maskBitCounts[bit] < bestCount {
                bestBit = bit
                bestCount = maskBitCounts[bit]
            }
            bits &= bits &- 1
        }
        guard bestBit >= 0 else { return nil }
        return (maskBitsets[bestBit], bestCount)
    }

    private static let searchMaskBitCount = 38
    private static let searchMaskBits = (UInt64(1) << UInt64(searchMaskBitCount)) - 1

    /// Build the fixed-size bitsets while an immutable generation is produced/decoded, never in the
    /// per-keystroke search loop. The nested arrays allocate a predictable 38 × ceil(items / 64)
    /// words with no posting-list growth slack.
    private static func buildMaskBitsets(mask: [UInt64], kind: [UInt8]) -> ([[UInt64]], [Int]) {
        guard mask.count == kind.count, mask.count <= Int(Int32.max) else { return ([], []) }
        let wordCount = (mask.count + UInt64.bitWidth - 1) / UInt64.bitWidth
        var bitsets: [[UInt64]] = []
        bitsets.reserveCapacity(searchMaskBitCount)
        for _ in 0..<searchMaskBitCount {
            bitsets.append([UInt64](repeating: 0, count: wordCount))
        }
        var counts = [Int](repeating: 0, count: searchMaskBitCount)
        for i in mask.indices {
            var bits = kind[i] == ItemKind.app.rawValue ? searchMaskBits : (mask[i] & searchMaskBits)
            let word = i / UInt64.bitWidth
            let itemBit = UInt64(1) << UInt64(i & (UInt64.bitWidth - 1))
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                bitsets[bit][word] |= itemBit
                counts[bit] += 1
                bits &= bits &- 1
            }
        }
        return (bitsets, counts)
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
    /// Returns an empty string if an internal/raw store has a broken, cyclic, non-UTF-8, or
    /// over-PATH_MAX topology. Empty is not a valid indexed root, so callers fail closed without
    /// accidentally turning a corrupt relative fragment into an absolute path.
    public func dirPath(_ d: Int32) -> String {
        guard d >= 0, Int(d) < dirs.count else { return "" }
        var comps: [String] = []
        comps.reserveCapacity(16)
        var cur = d
        var hops = 0
        while cur >= 0 {
            guard Int(cur) < dirs.count, hops <= SafetyLimits.maxPathUTF8Bytes else { return "" }
            let e = dirs[Int(cur)]
            let s = Int(e.nameStart), l = Int(e.nameLen)
            guard e.parent >= -1, e.parent < cur, s >= 0, s <= dirArena.count,
                  l <= dirArena.count - s,
                  let component = String(bytes: dirArena[s..<(s + l)], encoding: .utf8),
                  (e.parent < 0
                    ? SafetyLimits.isSafeAbsolutePath(component)
                    : SafetyLimits.isSafePathComponent(
                        component, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
                    )) else { return "" }
            comps.append(component)
            cur = e.parent
            hops += 1
        }
        guard cur == -1, let root = comps.last else { return "" }
        // comps = [leaf, ..., root(abs path)]
        var pathBytes = root.utf8.count
        var parentEndsInSlash = root.utf8.last == 0x2F
        for c in comps.dropLast().reversed() {
            let separatorBytes = parentEndsInSlash ? 0 : 1
            pathBytes = IndexStoreLimits.adding(pathBytes, separatorBytes)
            pathBytes = IndexStoreLimits.adding(pathBytes, c.utf8.count)
            guard pathBytes <= SafetyLimits.maxPathUTF8Bytes else { return "" }
            parentEndsInSlash = false
        }

        // Typical indexed paths are short. Reserving PATH_MAX for every result/candidate caused
        // megabytes of allocator churn per keystroke, so reserve only the already-validated size.
        var out = root
        out.reserveCapacity(pathBytes)
        for c in comps.dropLast().reversed() {
            let separatorBytes = out.utf8.last == 0x2F ? 0 : 1
            if separatorBytes != 0 { out.append("/") }
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
        guard !dir.isEmpty else { return "" }
        let n = fileName(of: i)
        let directoryEndsInSlash = dir.utf8.last == 0x2F
        guard IndexStoreLimits.completeItemPathFits(
            directoryPathUTF8Bytes: dir.utf8.count,
            directoryEndsInSlash: directoryEndsInSlash,
            storedName: name(of: i), flagsRaw: flags[i]
        ) else { return "" }
        if directoryEndsInSlash { return dir + n }
        return dir + "/" + n
    }

    /// `~`-abbreviated parent directory for display.
    public func parentDisplayPath(of i: Int, home: String = NSHomeDirectory()) -> String {
        let dir = dirPath(dirId[i])
        guard !dir.isEmpty else { return "" }
        return SafetyLimits.abbreviatingHome(dir, home: home)
    }
}

// MARK: - IndexBuilder

/// Defensive bounds shared by every index producer/consumer. `maxItems` is a hard product
/// invariant; directory metadata has a separate, deliberately generous bound so repeated
/// incremental replacements cannot retain unbounded dead directory entries forever.
enum IndexStoreLimits {
    static let sideTableFixedBytes = 256
    static let maxEagerItemReserve = 100_000
    static let maxEagerDirReserve = 50_000
    static let maxDirectoryArenaBytes = 256 * 1_024 * 1_024
    static let maxCombinedArenaBytes = 256 * 1_024 * 1_024
    static let maxBuilderDirectories = SafetyLimits.maxIndexedItems.upperBound
        + SafetyLimits.maxAppCatalogDirectories + SafetyLimits.maxIndexRoots
    static let maxBuilderRoots = SafetyLimits.maxIndexRoots
    static let maxAnalyzedNameBytes = SafetyLimits.maxNameUTF8Bytes * 4

    /// Conservative JSON upper bound for the snapshot side table. UInt8 arrays can expand to three
    /// decimal digits plus a comma; strings use the shared scalar-aware JSON escape bound.
    static func estimatedAppInfoJSONBytes(_ info: AppInfo) -> Int {
        var total = 128
        total = adding(total, SafetyLimits.jsonEscapedStringByteUpperBound(info.displayName))
        if let bundleID = info.bundleID {
            total = adding(total, SafetyLimits.jsonEscapedStringByteUpperBound(bundleID))
        }
        total = adding(total, multiplying(info.aliases.count, 96))
        for alias in info.aliases {
            total = adding(total, multiplying(adding(alias.folded.count, alias.bonus.count), 4))
        }
        return total
    }

    static func estimatedExtensionJSONBytes(_ value: String) -> Int {
        adding(16, SafetyLimits.jsonEscapedStringByteUpperBound(value))
    }

    /// Conservative side-table estimate shared by builders and store mergers. This composes the
    /// same per-record claims used by `IndexBuilder`; saturating arithmetic makes hostile sizes
    /// fail closed instead of wrapping below the product ceiling.
    static func estimatedSideTableBytes(extensions: [String], appInfo: [Int32: AppInfo],
                                        appItems: [Int32]) -> Int {
        // Match Snapshot's fixed object/field framing claim so a store accepted here cannot fail
        // encoding only because the semantic estimator omitted constant JSON overhead.
        var total = adding(sideTableFixedBytes, multiplying(appItems.count, 16))
        for value in extensions {
            total = adding(total, estimatedExtensionJSONBytes(value))
        }
        for value in appInfo.values {
            total = adding(total, estimatedAppInfoJSONBytes(value))
        }
        return total
    }

    static func normalizedMaxItems(_ value: Int) -> Int {
        min(max(0, value), SafetyLimits.maxIndexedItems.upperBound)
    }

    static func adding(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : value
    }

    static func multiplying(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int.max : value
    }

    /// Fresh file crawls normally have at most one directory per folder item. The app catalog may
    /// additionally retain a bounded absolute-path trie whose budget is independent of app count.
    /// Fixed slack avoids false positives while the builder ceiling still forces compaction after
    /// sustained incremental churn.
    static func directoryLimit(itemCount: Int, rootAllowance: Int) -> Int {
        let liveItems = max(0, itemCount)
        let roots = max(0, rootAllowance)
        var proportional = adding(multiplying(liveItems, 2), multiplying(roots, 2))
        proportional = adding(proportional, SafetyLimits.maxAppCatalogDirectories)
        return min(maxBuilderDirectories, max(256, adding(proportional, 256)))
    }

    static func directoryArenaLimit(itemCount: Int, rootAllowance: Int) -> Int {
        let dirs = directoryLimit(itemCount: itemCount, rootAllowance: rootAllowance)
        let nonCatalogDirs = max(0, dirs - SafetyLimits.maxAppCatalogDirectories)
        let rootBytes = multiplying(max(0, rootAllowance), 4_096)
        var proportional = adding(multiplying(nonCatalogDirs, 256), rootBytes)
        proportional = adding(proportional, SafetyLimits.maxAppCatalogDirectoryBytes)
        return min(maxDirectoryArenaBytes, max(64 * 1_024, proportional))
    }

    static func acceptsDirectoryMetadata(itemCount: Int, dirCount: Int, dirArenaBytes: Int,
                                         rootAllowance: Int) -> Bool {
        guard itemCount >= 0, dirCount >= 0, dirArenaBytes >= 0 else { return false }
        return dirCount <= directoryLimit(itemCount: itemCount, rootAllowance: rootAllowance)
            && dirArenaBytes <= directoryArenaLimit(itemCount: itemCount, rootAllowance: rootAllowance)
    }

    /// Validate directory slices, parent ordering, lexical components, and the reconstructed
    /// absolute UTF-8 length in one forward pass. Parent ids always precede children, so the
    /// cumulative path length is available in O(1) per entry and no path strings are concatenated.
    static func validDirectoryPathLengths(_ dirs: [DirEntry], arena: [UInt8]) -> [Int]? {
        var pathLengths: [Int] = []
        pathLengths.reserveCapacity(min(dirs.count, maxEagerDirReserve))
        for (index, entry) in dirs.enumerated() {
            let start = Int(entry.nameStart)
            let length = Int(entry.nameLen)
            guard entry.parent >= -1, entry.parent < Int32(index), start >= 0,
                  start <= arena.count, length <= arena.count - start else { return nil }
            let bytes = arena[start..<(start + length)]
            guard let name = String(bytes: bytes, encoding: .utf8) else { return nil }

            let fullLength: Int
            if entry.parent < 0 {
                guard length <= SafetyLimits.maxPathUTF8Bytes,
                      SafetyLimits.isSafeAbsolutePath(name) else { return nil }
                fullLength = length
            } else {
                guard length <= SafetyLimits.maxNameUTF8Bytes,
                      SafetyLimits.isSafePathComponent(
                        name, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
                      ) else { return nil }
                let parentIndex = Int(entry.parent)
                let parentEntry = dirs[parentIndex]
                let parentEndsInSlash = directoryEntryEndsInSlash(parentEntry, arena: arena)
                fullLength = adding(
                    adding(pathLengths[parentIndex], parentEndsInSlash ? 0 : 1), length
                )
                guard fullLength <= SafetyLimits.maxPathUTF8Bytes else { return nil }
            }
            pathLengths.append(fullLength)
        }
        return pathLengths
    }

    static func hasValidDirectoryTopology(_ dirs: [DirEntry], arena: [UInt8]) -> Bool {
        validDirectoryPathLengths(dirs, arena: arena) != nil
    }

    static func directoryEntryEndsInSlash(_ entry: DirEntry, arena: [UInt8]) -> Bool {
        guard entry.parent < 0 else { return false }
        let start = Int(entry.nameStart), length = Int(entry.nameLen)
        guard start >= 0, start <= arena.count, length > 0,
              length <= arena.count - start else { return false }
        return arena[start + length - 1] == 0x2F
    }

    /// Validate the path the filesystem will actually receive. App names are stored without their
    /// `.app` suffix, so both the component ceiling and complete path must include that suffix.
    static func completeItemPathFits(directoryPathUTF8Bytes: Int,
                                     directoryEndsInSlash: Bool,
                                     storedName: String, flagsRaw: UInt8) -> Bool {
        guard directoryPathUTF8Bytes > 0,
              directoryPathUTF8Bytes <= SafetyLimits.maxPathUTF8Bytes,
              SafetyLimits.isSafePathComponent(
                storedName, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
              ) else { return false }
        var fileName = storedName
        if flagsRaw & ItemFlags.appBundle.rawValue != 0,
           !storedName.lowercased().hasSuffix(".app") {
            fileName += ".app"
        }
        guard SafetyLimits.isSafePathComponent(
            fileName, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
        ) else { return false }
        let fullLength = adding(
            adding(directoryPathUTF8Bytes, directoryEndsInSlash ? 0 : 1),
            fileName.utf8.count
        )
        return fullLength <= SafetyLimits.maxPathUTF8Bytes
    }
}

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
    /// Reconstructed absolute UTF-8 byte length for each directory. Kept parallel to `dirs` so a
    /// deep chain is rejected in O(1) at append time instead of repeatedly rebuilding its prefix.
    private var dirPathUTF8Bytes: [Int] = []
    private var extensions: [String] = []
    private var extIndex: [String: Int16] = [:]
    private var appInfo: [Int32: AppInfo] = [:]
    private var appItems: [Int32] = []
    /// Conservative encoded side-table budget accumulated incrementally. This prevents a public
    /// builder caller from retaining an unbounded AppInfo graph or making Snapshot.encode allocate a
    /// huge JSON value before it can enforce the on-disk limit.
    private var estimatedSideTableBytes = IndexStoreLimits.sideTableFixedBytes
    /// Absolute-path → dir id for root entries (parent == -1), so a path is registered as a root only once
    /// even when several per-root builders that each synthesised the same parent are merged via `append`.
    private var rootDirIndex: [String: Int32] = [:]
    /// AppScanner catalog ingestion is one-shot per builder so its topology budgets cannot reset
    /// across repeated public calls that target the same mutable store.
    private var appCatalogIngested = false

    public private(set) var count: Int = 0
    public var dirCount: Int { dirs.count }

    public init() {}

    func beginAppCatalogIngest() -> Bool {
        guard !appCatalogIngested else { return false }
        appCatalogIngested = true
        return true
    }

    /// Read-only catalog planning seam. AppScanner uses this to avoid charging its local topology
    /// budget for the shared `/` root when another producer already interned that exact root.
    func hasRoot(_ absolutePath: String) -> Bool {
        rootDirIndex[absolutePath] != nil
    }

    /// Reserve capacity for an expected number of items (avoids re-allocation churn on big crawls).
    public func reserve(items: Int, dirs: Int) {
        // Capacity is only a hint. Clamp hostile/programmatic values so `Int.max * 24` cannot
        // overflow and a tiny crawl cannot force a multi-gigabyte eager allocation.
        let itemCapacity = min(max(0, items), IndexStoreLimits.maxEagerItemReserve)
        let dirCapacity = min(max(0, dirs), IndexStoreLimits.maxEagerDirReserve)
        dirId.reserveCapacity(itemCapacity); nameStart.reserveCapacity(itemCapacity); nameLen.reserveCapacity(itemCapacity)
        displayStart.reserveCapacity(itemCapacity); displayLen.reserveCapacity(itemCapacity); mask.reserveCapacity(itemCapacity)
        initials.reserveCapacity(itemCapacity); mtime.reserveCapacity(itemCapacity); kind.reserveCapacity(itemCapacity)
        flags.reserveCapacity(itemCapacity); depth.reserveCapacity(itemCapacity); extId.reserveCapacity(itemCapacity)
        let itemArenaCapacity = itemCapacity * 24
        foldedArena.reserveCapacity(itemArenaCapacity); bonusArena.reserveCapacity(itemArenaCapacity); displayArena.reserveCapacity(itemArenaCapacity)
        self.dirs.reserveCapacity(dirCapacity); dirArena.reserveCapacity(dirCapacity * 16)
        dirPathUTF8Bytes.reserveCapacity(dirCapacity)
    }

    /// Register a root directory (absolute path). Returns its dir id.
    @discardableResult
    public func addRoot(_ absolutePath: String) -> Int32 {
        guard SafetyLimits.isSafeAbsolutePath(absolutePath) else { return -1 }
        if let existing = rootDirIndex[absolutePath] { return existing }
        guard rootDirIndex.count < IndexStoreLimits.maxBuilderRoots else { return -1 }
        let id = appendDir(parent: -1, name: absolutePath,
                           byteLimit: SafetyLimits.maxPathUTF8Bytes)
        guard id >= 0 else { return -1 }
        rootDirIndex[absolutePath] = id
        return id
    }

    /// Register a child directory by component name. Returns its dir id.
    @discardableResult
    public func addDir(parent: Int32, name: String) -> Int32 {
        guard parent >= 0, Int(parent) < dirs.count else { return -1 }
        return appendDir(parent: parent, name: name, byteLimit: SafetyLimits.maxNameUTF8Bytes)
    }

    private func appendDir(parent: Int32, name: String, byteLimit: Int) -> Int32 {
        guard (parent < 0 || SafetyLimits.isSafePathComponent(name, maxUTF8Bytes: byteLimit)),
              (parent >= 0 || SafetyLimits.isSafeAbsolutePath(name, maxUTF8Bytes: byteLimit)),
              dirs.count < IndexStoreLimits.maxBuilderDirectories else { return -1 }
        let bytes = Array(name.utf8)
        let fullPathBytes: Int
        if parent < 0 {
            fullPathBytes = bytes.count
        } else {
            let parentIndex = Int(parent)
            guard parentIndex < dirPathUTF8Bytes.count else { return -1 }
            let parentEntry = dirs[parentIndex]
            let parentEnd = Int(parentEntry.nameStart) + Int(parentEntry.nameLen)
            let parentEndsInSlash = parentEnd > Int(parentEntry.nameStart)
                && dirArena[parentEnd - 1] == 0x2F
            fullPathBytes = IndexStoreLimits.adding(
                IndexStoreLimits.adding(dirPathUTF8Bytes[parentIndex], parentEndsInSlash ? 0 : 1),
                bytes.count
            )
        }
        let projected = IndexStoreLimits.adding(
            IndexStoreLimits.adding(foldedArena.count, bonusArena.count),
            IndexStoreLimits.adding(displayArena.count,
                                    IndexStoreLimits.adding(dirArena.count, bytes.count))
        )
        guard fullPathBytes <= SafetyLimits.maxPathUTF8Bytes,
              projected <= IndexStoreLimits.maxCombinedArenaBytes,
              dirArena.count <= Int(Int32.max) - bytes.count else { return -1 }
        let start = Int32(dirArena.count)
        dirArena.append(contentsOf: bytes)
        dirs.append(DirEntry(parent: parent, nameStart: start, nameLen: UInt16(bytes.count)))
        dirPathUTF8Bytes.append(fullPathBytes)
        return Int32(dirs.count - 1)
    }

    /// Add one item. `name` is the display name (for apps: `.app` already stripped).
    /// `analyzed` is the pre-analysed searchable form of `name` (from `TextAnalyzer.analyze`).
    /// Returns the item index.
    @discardableResult
    public func addItem(dir: Int32, name: String, analyzed: SearchString, kind k: ItemKind, flags f: ItemFlags,
                        mtime t: Date?, depth d: Int, ext: String?, app: AppInfo? = nil) -> Int32 {
        guard dir >= 0, Int(dir) < dirs.count, Int(dir) < dirPathUTF8Bytes.count,
              let prepared = prepareItem(
                name: name, analyzed: analyzed, kind: k, flags: f, app: app,
                directoryPathUTF8Bytes: dirPathUTF8Bytes[Int(dir)],
                directoryEndsInSlash: IndexStoreLimits.directoryEntryEndsInSlash(
                    dirs[Int(dir)], arena: dirArena
                ),
                projectedDirectoryArenaBytes: dirArena.count
              ) else { return -1 }
        let idx = Int32(count)
        dirId.append(dir)
        nameStart.append(Int32(foldedArena.count))
        nameLen.append(UInt16(clamping: analyzed.folded.count))
        foldedArena.append(contentsOf: analyzed.folded)
        bonusArena.append(contentsOf: analyzed.bonus)
        displayStart.append(Int32(displayArena.count))
        displayLen.append(UInt16(prepared.displayBytes.count))
        displayArena.append(contentsOf: prepared.displayBytes)
        mask.append(analyzed.mask)
        initials.append(analyzed.initials)
        mtime.append(safeTimestamp(t))
        kind.append(k.rawValue)
        flags.append(f.rawValue)
        depth.append(UInt8(min(max(d, SafetyLimits.maxDepth.lowerBound), SafetyLimits.maxDepth.upperBound)))
        let itemSideBytes = IndexStoreLimits.adding(prepared.appInfoBytes, k == .app ? 16 : 0)
        estimatedSideTableBytes = IndexStoreLimits.adding(estimatedSideTableBytes, itemSideBytes)
        if let raw = ext,
           SafetyLimits.isSafePathComponent(raw, maxUTF8Bytes: SafetyLimits.maxExtensionUTF8Bytes),
           raw.count <= SafetyLimits.maxExtensionCharacters {
            let e = raw.lowercased()
            if let id = extIndex[e] { extId.append(id) }
            else if SafetyLimits.isSafePathComponent(e, maxUTF8Bytes: SafetyLimits.maxExtensionUTF8Bytes),
                    e.count <= SafetyLimits.maxExtensionCharacters,
                    extensions.count <= Int(Int16.max),
                    IndexStoreLimits.adding(estimatedSideTableBytes,
                                            IndexStoreLimits.estimatedExtensionJSONBytes(e))
                        <= SafetyLimits.maxAppSideTableBytes {
                let id = Int16(extensions.count)
                extensions.append(e)
                extIndex[e] = id
                extId.append(id)
                estimatedSideTableBytes = IndexStoreLimits.adding(
                    estimatedSideTableBytes, IndexStoreLimits.estimatedExtensionJSONBytes(e)
                )
            } else { extId.append(-1) }
        } else { extId.append(-1) }
        if let a = app { appInfo[idx] = a }
        if k == .app { appItems.append(idx) }
        count += 1
        return idx
    }

    private struct PreparedItem {
        var displayBytes: [UInt8]
        var appInfoBytes: Int
    }

    /// Dry-run the exact failure conditions shared by `addItem` and AppScanner's atomic
    /// directory+item transaction. Extensions deliberately are not included: an unsafe or
    /// over-budget extension is represented as unknown (`extId == -1`) and never rejects the item.
    private func prepareItem(name: String, analyzed: SearchString, kind: ItemKind,
                             flags: ItemFlags, app: AppInfo?,
                             directoryPathUTF8Bytes: Int,
                             directoryEndsInSlash: Bool,
                             projectedDirectoryArenaBytes: Int) -> PreparedItem? {
        guard count < SafetyLimits.maxIndexedItems.upperBound,
              SafetyLimits.isSafePathComponent(
                name, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
              ),
              IndexStoreLimits.completeItemPathFits(
                directoryPathUTF8Bytes: directoryPathUTF8Bytes,
                directoryEndsInSlash: directoryEndsInSlash,
                storedName: name, flagsRaw: flags.rawValue
              ),
              analyzed.folded.count == analyzed.bonus.count,
              !analyzed.folded.isEmpty,
              analyzed.folded.count <= IndexStoreLimits.maxAnalyzedNameBytes,
              let appInfoBytes = safeAppInfoJSONBytes(app, kind: kind),
              IndexStoreLimits.adding(
                estimatedSideTableBytes,
                IndexStoreLimits.adding(appInfoBytes, kind == .app ? 16 : 0)
              ) <= SafetyLimits.maxAppSideTableBytes,
              projectedDirectoryArenaBytes >= 0 else { return nil }
        let displayBytes = Array(name.utf8)
        let projected = IndexStoreLimits.adding(
            IndexStoreLimits.adding(foldedArena.count, analyzed.folded.count),
            IndexStoreLimits.adding(
                IndexStoreLimits.adding(bonusArena.count, analyzed.bonus.count),
                IndexStoreLimits.adding(
                    displayArena.count,
                    IndexStoreLimits.adding(displayBytes.count, projectedDirectoryArenaBytes)
                )
            )
        )
        guard projected <= IndexStoreLimits.maxCombinedArenaBytes,
              foldedArena.count <= Int(Int32.max) - analyzed.folded.count,
              displayArena.count <= Int(Int32.max) - displayBytes.count else { return nil }
        return PreparedItem(displayBytes: displayBytes, appInfoBytes: appInfoBytes)
    }

    /// Preflight an AppScanner catalog path and its item as one transaction. `newDirectoryCount`
    /// and `newDirectoryBytes` include `rootPath` when non-nil; an already-interned canonical root
    /// is subtracted here so the projection matches the subsequent `addRoot` deduplication.
    func canAddItemAfterAddingDirectories(newDirectoryCount: Int, newDirectoryBytes: Int,
                                          rootPath: String?, directoryPathUTF8Bytes: Int,
                                          directoryEndsInSlash: Bool, name: String,
                                          analyzed: SearchString, kind: ItemKind,
                                          flags: ItemFlags, app: AppInfo?) -> Bool {
        guard newDirectoryCount >= 0, newDirectoryBytes >= 0 else { return false }
        var addedDirectories = newDirectoryCount
        var addedDirectoryBytes = newDirectoryBytes
        var addedRoots = 0
        if let rootPath {
            guard SafetyLimits.isSafeAbsolutePath(rootPath), newDirectoryCount > 0 else {
                return false
            }
            let rootBytes = rootPath.utf8.count
            guard rootBytes <= newDirectoryBytes else { return false }
            if rootDirIndex[rootPath] != nil {
                addedDirectories -= 1
                addedDirectoryBytes -= rootBytes
            } else {
                addedRoots = 1
            }
        }
        let projectedItems = IndexStoreLimits.adding(count, 1)
        let projectedDirectories = IndexStoreLimits.adding(dirs.count, addedDirectories)
        let projectedDirectoryBytes = IndexStoreLimits.adding(dirArena.count,
                                                               addedDirectoryBytes)
        let projectedRoots = IndexStoreLimits.adding(rootDirIndex.count, addedRoots)
        guard projectedItems <= SafetyLimits.maxIndexedItems.upperBound,
              projectedDirectories <= IndexStoreLimits.maxBuilderDirectories,
              projectedRoots <= IndexStoreLimits.maxBuilderRoots,
              dirArena.count <= Int(Int32.max) - addedDirectoryBytes,
              IndexStoreLimits.acceptsDirectoryMetadata(
                itemCount: projectedItems, dirCount: projectedDirectories,
                dirArenaBytes: projectedDirectoryBytes, rootAllowance: projectedRoots
              ) else { return false }
        return prepareItem(
            name: name, analyzed: analyzed, kind: kind, flags: flags, app: app,
            directoryPathUTF8Bytes: directoryPathUTF8Bytes,
            directoryEndsInSlash: directoryEndsInSlash,
            projectedDirectoryArenaBytes: projectedDirectoryBytes
        ) != nil
    }

    private func safeTimestamp(_ date: Date?) -> UInt32 {
        guard let value = date?.timeIntervalSinceReferenceDate,
              value.isFinite, value > 0 else { return 0 }
        guard value < Double(UInt32.max) else { return UInt32.max }
        return UInt32(value)
    }

    private func safeAppInfoJSONBytes(_ info: AppInfo?, kind: ItemKind) -> Int? {
        guard let info else { return 0 }
        guard kind == .app,
              SafetyLimits.utf8Fits(info.displayName, maxBytes: SafetyLimits.maxNameUTF8Bytes),
              !info.displayName.isEmpty, !SafetyLimits.containsNULByte(info.displayName),
              (info.bundleID.map {
                  SafetyLimits.utf8Fits($0, maxBytes: SafetyLimits.maxSettingUTF8Bytes)
                      && !SafetyLimits.containsNULByte($0)
              } ?? true),
              info.aliases.count <= SafetyLimits.maxSearchAliasesPerApp,
              info.aliases.allSatisfy({
            !$0.folded.isEmpty && $0.folded.count == $0.bonus.count
                && $0.folded.count <= IndexStoreLimits.maxAnalyzedNameBytes
              }) else { return nil }
        let estimated = IndexStoreLimits.estimatedAppInfoJSONBytes(info)
        return estimated <= SafetyLimits.maxAppSideTableBytes ? estimated : nil
    }

    /// Append every directory and item of `other` into this builder, remapping directory ids, arena
    /// offsets and interned extension ids so the result is identical to having crawled `other`'s work
    /// directly into `self`. Used to merge per-root builders produced by a parallel crawl (each root is
    /// crawled into its own builder off-thread, then merged here in root order on one thread).
    ///
    /// `other`'s roots keep `parent == -1`; all other dir parents and every item's `dirId` shift by the
    /// current directory count. Item order within `other` is preserved and appended after `self`'s items,
    /// so `appItems` stays sorted.
    @discardableResult
    public func append(_ other: IndexBuilder) -> Bool {
        append(other, maxItems: SafetyLimits.maxIndexedItems.upperBound)
    }

    /// Injectable item ceiling and observation seam for deterministic early-rejection tests. The
    /// production entry point always supplies the process-wide hard limit.
    @discardableResult
    func append(_ other: IndexBuilder, maxItems: Int,
                beforeDirectoryPlanning: (() -> Void)? = nil) -> Bool {
        guard self !== other,
              dirPathUTF8Bytes.count == dirs.count,
              other.dirPathUTF8Bytes.count == other.dirs.count else { return false }
        let combinedItems = IndexStoreLimits.adding(count, other.count)
        let itemLimit = IndexStoreLimits.normalizedMaxItems(maxItems)
        guard combinedItems <= itemLimit else { return false }
        beforeDirectoryPlanning?()

        // Plan the directory remap before mutating any builder state. `String` dictionary keys use
        // canonical Unicode equality, so an NFC root can dedupe with an NFD root whose UTF-8 byte
        // length differs. Every child length must therefore be recomputed from the *mapped* parent,
        // not copied from `other`; otherwise a later addDir could cross the complete-path ceiling.
        var dirRemap = [Int32](repeating: -1, count: other.dirs.count)
        var shouldAppendDir = [Bool](repeating: false, count: other.dirs.count)
        var plannedPathLengths = [Int](repeating: 0, count: other.dirs.count)
        var requiresMappedItemValidation = [Bool](repeating: false, count: other.dirs.count)
        var plannedRootIndex = rootDirIndex
        var appendedPathLengths: [Int] = []
        var appendedEndsInSlash: [Bool] = []
        appendedPathLengths.reserveCapacity(other.dirs.count)
        appendedEndsInSlash.reserveCapacity(other.dirs.count)
        var appendedDirectoryArenaBytes = 0

        func pathLength(for id: Int32) -> Int? {
            guard id >= 0 else { return nil }
            let index = Int(id)
            if index < dirPathUTF8Bytes.count { return dirPathUTF8Bytes[index] }
            let appendedIndex = index - dirs.count
            guard appendedIndex >= 0, appendedIndex < appendedPathLengths.count else { return nil }
            return appendedPathLengths[appendedIndex]
        }

        func endsInSlash(_ id: Int32) -> Bool? {
            guard id >= 0 else { return nil }
            let index = Int(id)
            if index < dirs.count {
                let entry = dirs[index]
                let start = Int(entry.nameStart), length = Int(entry.nameLen)
                guard start >= 0, start <= dirArena.count,
                      length <= dirArena.count - start else { return nil }
                return length > 0 && dirArena[start + length - 1] == 0x2F
            }
            let appendedIndex = index - dirs.count
            guard appendedIndex >= 0, appendedIndex < appendedEndsInSlash.count else { return nil }
            return appendedEndsInSlash[appendedIndex]
        }

        for (i, entry) in other.dirs.enumerated() {
            let start = Int(entry.nameStart), length = Int(entry.nameLen)
            guard entry.parent >= -1, entry.parent < Int32(i), start >= 0,
                  start <= other.dirArena.count, length <= other.dirArena.count - start,
                  let name = String(bytes: other.dirArena[start..<(start + length)],
                                    encoding: .utf8) else { return false }

            if entry.parent < 0, let existing = plannedRootIndex[name] {
                guard let mappedLength = pathLength(for: existing),
                      let mappedEndsInSlash = endsInSlash(existing) else { return false }
                dirRemap[i] = existing
                plannedPathLengths[i] = mappedLength
                requiresMappedItemValidation[i] = mappedLength != other.dirPathUTF8Bytes[i]
                    || mappedEndsInSlash != IndexStoreLimits.directoryEntryEndsInSlash(
                        entry, arena: other.dirArena
                    )
                continue
            }

            let mappedIDValue = IndexStoreLimits.adding(dirs.count, appendedPathLengths.count)
            guard mappedIDValue <= Int(Int32.max) else { return false }
            let mappedID = Int32(mappedIDValue)
            let fullPathLength: Int
            let nodeEndsInSlash: Bool
            if entry.parent < 0 {
                fullPathLength = length
                nodeEndsInSlash = length > 0
                    && other.dirArena[start + length - 1] == 0x2F
                plannedRootIndex[name] = mappedID
            } else {
                let parentID = dirRemap[Int(entry.parent)]
                guard let parentLength = pathLength(for: parentID),
                      let parentEndsInSlash = endsInSlash(parentID) else { return false }
                fullPathLength = IndexStoreLimits.adding(
                    IndexStoreLimits.adding(parentLength, parentEndsInSlash ? 0 : 1), length
                )
                nodeEndsInSlash = false
            }
            guard fullPathLength <= SafetyLimits.maxPathUTF8Bytes else { return false }
            dirRemap[i] = mappedID
            shouldAppendDir[i] = true
            plannedPathLengths[i] = fullPathLength
            requiresMappedItemValidation[i] = fullPathLength != other.dirPathUTF8Bytes[i]
                || nodeEndsInSlash != IndexStoreLimits.directoryEntryEndsInSlash(
                    entry, arena: other.dirArena
                )
            appendedPathLengths.append(fullPathLength)
            appendedEndsInSlash.append(nodeEndsInSlash)
            appendedDirectoryArenaBytes = IndexStoreLimits.adding(appendedDirectoryArenaBytes,
                                                                   length)
        }

        // Items share the same canonical-root remap. A directory can remain within 4,096 bytes
        // while an item that was exact under a shorter NFC spelling becomes overlong under an
        // existing, canonically-equal NFD spelling (and apps add an implicit `.app`). Revalidate
        // every affected final item path before any directory, arena, or side-table mutation.
        for i in 0..<other.count {
            let sourceDir = other.dirId[i]
            guard sourceDir >= 0, Int(sourceDir) < dirRemap.count else { return false }
            guard requiresMappedItemValidation[Int(sourceDir)] else { continue }
            let mappedDir = dirRemap[Int(sourceDir)]
            let displayStart = Int(other.displayStart[i])
            let displayLength = Int(other.displayLen[i])
            guard displayStart >= 0, displayStart <= other.displayArena.count,
                  displayLength <= other.displayArena.count - displayStart,
                  let storedName = String(
                    bytes: other.displayArena[displayStart..<(displayStart + displayLength)],
                    encoding: .utf8
                  ),
                  let mappedDirectoryLength = pathLength(for: mappedDir),
                  let mappedDirectoryEndsInSlash = endsInSlash(mappedDir),
                  IndexStoreLimits.completeItemPathFits(
                    directoryPathUTF8Bytes: mappedDirectoryLength,
                    directoryEndsInSlash: mappedDirectoryEndsInSlash,
                    storedName: storedName, flagsRaw: other.flags[i]
                  ) else { return false }
        }
        let combinedDirs = IndexStoreLimits.adding(dirs.count, appendedPathLengths.count)
        let combinedRoots = plannedRootIndex.count
        let combinedDirectoryArenaBytes = IndexStoreLimits.adding(dirArena.count,
                                                                   appendedDirectoryArenaBytes)
        // Each standalone builder carries the fixed JSON framing claim. A merged side table has
        // that framing only once, so add only the other builder's semantic payload.
        let otherSideTablePayload = max(0, other.estimatedSideTableBytes
            - IndexStoreLimits.sideTableFixedBytes)
        let combinedSideTableBytes = IndexStoreLimits.adding(estimatedSideTableBytes,
                                                              otherSideTablePayload)
        let combinedArenas = [foldedArena.count, bonusArena.count, displayArena.count,
                              other.foldedArena.count, other.bonusArena.count,
                              other.displayArena.count, combinedDirectoryArenaBytes]
            .reduce(0, IndexStoreLimits.adding)
        guard combinedItems <= SafetyLimits.maxIndexedItems.upperBound,
              combinedDirs <= IndexStoreLimits.maxBuilderDirectories,
              combinedRoots <= IndexStoreLimits.maxBuilderRoots,
              combinedSideTableBytes <= SafetyLimits.maxAppSideTableBytes,
              combinedArenas <= IndexStoreLimits.maxCombinedArenaBytes,
              IndexStoreLimits.acceptsDirectoryMetadata(
                  itemCount: combinedItems, dirCount: combinedDirs,
                  dirArenaBytes: combinedDirectoryArenaBytes,
                  rootAllowance: SafetyLimits.maxIndexRoots
              ),
              foldedArena.count <= Int(Int32.max) - other.foldedArena.count,
              displayArena.count <= Int(Int32.max) - other.displayArena.count,
              dirArena.count <= Int(Int32.max) - appendedDirectoryArenaBytes else { return false }
        let itemOffset = Int32(count)
        let foldedOffset = Int32(foldedArena.count)
        let displayOffset = Int32(displayArena.count)

        // Directories: remap each of other's dir ids into self, deduping ROOT entries (parent == -1) by
        // their absolute-path name so merged per-root builders share one synthetic parent — matching the
        // serial crawl and keeping `DirIndex` (used by incremental FSEvents updates) able to resolve paths.
        // Parents always precede their children in build order, so `dirRemap[parent]` is set before use.
        dirs.reserveCapacity(combinedDirs)
        dirPathUTF8Bytes.reserveCapacity(combinedDirs)
        for (i, e) in other.dirs.enumerated() {
            guard shouldAppendDir[i] else { continue }
            let s = Int(e.nameStart), l = Int(e.nameLen)
            let nameBytes = other.dirArena[s..<(s + l)]
            assert(dirRemap[i] == Int32(dirs.count))
            let start = Int32(dirArena.count)
            dirArena.append(contentsOf: nameBytes)
            if e.parent < 0 {
                let name = String(decoding: nameBytes, as: UTF8.self)
                dirs.append(DirEntry(parent: -1, nameStart: start, nameLen: e.nameLen))
                rootDirIndex[name] = dirRemap[i]
            } else {
                dirs.append(DirEntry(parent: dirRemap[Int(e.parent)], nameStart: start, nameLen: e.nameLen))
            }
            dirPathUTF8Bytes.append(plannedPathLengths[i])
        }

        // Extension id remap: intern each of other's extensions into self, build old→new table.
        var extRemap = [Int16](repeating: -1, count: other.extensions.count)
        for (oldId, name) in other.extensions.enumerated() {
            if let id = extIndex[name] { extRemap[oldId] = id }
            else if name.count <= SafetyLimits.maxExtensionCharacters,
                    SafetyLimits.utf8Fits(name, maxBytes: SafetyLimits.maxExtensionUTF8Bytes),
                    extensions.count <= Int(Int16.max) {
                let id = Int16(extensions.count)
                extensions.append(name)
                extIndex[name] = id
                extRemap[oldId] = id
            }
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
        estimatedSideTableBytes = combinedSideTableBytes
        appCatalogIngested = appCatalogIngested || other.appCatalogIngested
        return true
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
