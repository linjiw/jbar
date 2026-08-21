import Foundation

/// Binary on-disk snapshot of an `IndexStore`. DESIGN.md §3. Owner: indexer agent.
///
/// Layout (little-endian, unaligned):
/// ```
/// magic "JBIX" (UInt32) · schemaVersion (UInt32) · headerHash (UInt64) · generation (UInt64) · fsEventId (UInt64)
/// · builtAt (Double, seconds since 1970) · count (UInt64) · dirCount (UInt64)
/// · 19 blobs, each (byteLength: UInt64, raw bytes): dirId nameStart nameLen displayStart displayLen mask initials
///   mtime kind flags depth extId foldedArena bonusArena displayArena dirParents(Int32) dirNameStart(Int32)
///   dirNameLen(UInt16) dirArena
/// · 1 JSON blob (byteLength: UInt64, bytes): { extensions, appInfo: [(item, AppInfo)], appItems }
/// · trailer magic "JBIX" (UInt32)
/// ```
/// `headerHash` domain-separates file roots from app roots and also includes the hard item cap
/// (exclusions.stableHash ⊕ file roots ⊕ app roots ⊕ maxItems ⊕ BonusConstants.hash).
/// Written owner-only through a descriptor-opened parent and atomically replaced. Reads classify and
/// size-check the exact `O_NOFOLLOW` descriptor before consuming at most the cap derived from the
/// configured item/root limits. Every blob, side table, length, and cross-reference is bounded, so a
/// truncated, oversized, or corrupt file yields `nil` instead of allocating from attacker-provided counts.
/// Any mismatch in magic, schema version or headerHash → `nil` (caller recrawls).
public enum Snapshot {
    public static let magic: UInt32 = 0x4A424958 // "JBIX"
    public static let schemaVersion: UInt32 = 2

    /// A snapshot is a rebuildable cache. Even if a pathological but otherwise representable index
    /// could serialize larger arenas, persistence is capped so startup cannot allocate multi-gigabyte
    /// attacker-controlled input. Normal 2M-item stores remain well below this ceiling.
    public static let absoluteMaximumFileBytes = 512 * 1_048_576
    static let maximumSideTableBytes = SafetyLimits.maxAppSideTableBytes
    static let maximumAnalyzedNameBytes = SafetyLimits.maxNameUTF8Bytes * 4
    static let maximumAliasesPerApp = SafetyLimits.maxSearchAliasesPerApp
    static let maximumJSONNestingDepth = 64
    static let headerByteCount = 56

    public enum EncodingFailure: Error, LocalizedError, Equatable {
        case invalidStore
        case tooLarge(maxBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidStore: return "index snapshot contains invalid or unsafe metadata"
            case .tooLarge(let maxBytes): return "index snapshot exceeds the \(maxBytes)-byte cache limit"
            }
        }
    }

    /// Default location: ~/Library/Caches/com.linji.jbar/index-v1.bin
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.linji.jbar", isDirectory: true).appendingPathComponent("index-v1.bin")
    }

    /// Side tables serialised as JSON (small: a few hundred apps).
    struct SideTables: Codable {
        struct AppEntry: Codable { var item: Int32; var info: AppInfo }
        var extensions: [String]
        var appInfo: [AppEntry]
        var appItems: [Int32]
    }

    // MARK: Write

    /// Write `store` to `url`. Throws on I/O error.
    public static func write(_ store: IndexStore, to url: URL, headerHash: UInt64) throws {
        let data = try encode(store, headerHash: headerHash)
        let isDefaultDirectory = url.standardizedFileURL.deletingLastPathComponent()
            == defaultURL().standardizedFileURL.deletingLastPathComponent()
        try SecureFileIO.writeAtomicallyOwnerOnly(data, to: url,
                                                  enforcePrivateDirectory: isDefaultDirectory)
    }

    /// Serialise `store` into the snapshot format.
    public static func encode(_ store: IndexStore, headerHash: UInt64) throws -> Data {
        let rootAllowance = store.dirs.reduce(into: 0) { if $1.parent < 0 { $0 += 1 } }
        guard validateStore(store, rootAllowance: rootAllowance) else { throw EncodingFailure.invalidStore }
        let sideLimit = sideTableByteLimit(itemCount: store.count)
        try preflightSideTableInputs(store, maxBytes: sideLimit)
        let side = SideTables(extensions: store.extensions,
                              appInfo: store.appInfo.keys.sorted().map { SideTables.AppEntry(item: $0, info: store.appInfo[$0]!) },
                              appItems: store.appItems)
        guard validateSideTables(side, count: store.count, kinds: store.kind) else {
            throw EncodingFailure.invalidStore
        }
        let json = try JSONEncoder().encode(side)
        guard json.count <= sideLimit else {
            throw EncodingFailure.tooLarge(maxBytes: sideLimit)
        }

        let encodedBytes = exactEncodedByteCount(store: store, jsonBytes: json.count)
        let fileLimit = maximumFileBytes(maxItems: store.count, rootAllowance: rootAllowance)
        guard encodedBytes != Int.max, encodedBytes <= fileLimit else {
            throw EncodingFailure.tooLarge(maxBytes: fileLimit)
        }
        var w = Writer()
        w.reserve(encodedBytes)
        w.put(magic); w.put(schemaVersion); w.put(headerHash); w.put(store.generation); w.put(store.fsEventId)
        w.put(store.builtAt.timeIntervalSince1970); w.put(UInt64(store.count)); w.put(UInt64(store.dirs.count))
        w.blob(store.dirId); w.blob(store.nameStart); w.blob(store.nameLen); w.blob(store.displayStart); w.blob(store.displayLen)
        w.blob(store.mask); w.blob(store.initials); w.blob(store.mtime); w.blob(store.kind); w.blob(store.flags)
        w.blob(store.depth); w.blob(store.extId); w.blob(store.foldedArena); w.blob(store.bonusArena); w.blob(store.displayArena)
        w.blob(store.dirs.map { $0.parent }); w.blob(store.dirs.map { $0.nameStart }); w.blob(store.dirs.map { $0.nameLen }); w.blob(store.dirArena)
        w.put(UInt64(json.count)); w.data.append(json)
        w.put(magic)
        guard w.data.count == encodedBytes else { throw EncodingFailure.invalidStore }
        return w.data
    }

    // MARK: Read

    /// Load a store from `url`. Returns nil if missing, corrupt, or `headerHash` mismatches.
    public static func read(from url: URL, expectedHeaderHash: UInt64,
                            maxItems: Int = SafetyLimits.maxIndexedItems.upperBound,
                            rootAllowance: Int = 0) -> IndexStore? {
        let fileLimit = maximumFileBytes(maxItems: maxItems, rootAllowance: rootAllowance)
        guard let data = try? SecureFileIO.readRegularFile(
            at: url, maxBytes: fileLimit, preflightByteCount: headerByteCount,
            limitAfterPreflight: {
                preflightFileLimit($0, expectedHeaderHash: expectedHeaderHash,
                                   maxItems: maxItems, rootAllowance: rootAllowance)
            }
        ) else { return nil }
        return decode(data, expectedHeaderHash: expectedHeaderHash, maxItems: maxItems,
                      rootAllowance: rootAllowance)
    }

    /// Parse snapshot bytes. nil on any inconsistency.
    public static func decode(_ data: Data, expectedHeaderHash: UInt64,
                              maxItems: Int = SafetyLimits.maxIndexedItems.upperBound,
                              rootAllowance: Int = 0) -> IndexStore? {
        let configuredFileLimit = maximumFileBytes(maxItems: maxItems, rootAllowance: rootAllowance)
        guard data.count <= configuredFileLimit else { return nil }
        var r = Reader(data: data)
        guard r.u32() == magic, r.u32() == schemaVersion, r.u64() == expectedHeaderHash else { return nil }
        let itemLimit = IndexStoreLimits.normalizedMaxItems(maxItems)
        guard let generation = r.u64(), let fsEventId = r.u64(), let builtAt = r.f64(), builtAt.isFinite,
              let count64 = r.u64(), let dirCount64 = r.u64(), count64 <= UInt64(itemLimit),
              count64 <= UInt64(Int32.max), dirCount64 <= UInt64(Int32.max) else { return nil }
        let count = Int(count64), dirCount = Int(dirCount64)
        let allowedRoots = normalizedRootAllowance(rootAllowance)
        guard data.count <= maximumFileBytes(maxItems: count, rootAllowance: rootAllowance) else { return nil }
        guard dirCount <= IndexStoreLimits.directoryLimit(itemCount: count, rootAllowance: allowedRoots) else { return nil }
        let dirArenaLimit = IndexStoreLimits.directoryArenaLimit(itemCount: count, rootAllowance: allowedRoots)
        let analyzedArenaLimit = itemArenaByteLimit(itemCount: count, bytesPerItem: maximumAnalyzedNameBytes)
        let displayArenaLimit = itemArenaByteLimit(itemCount: count, bytesPerItem: SafetyLimits.maxNameUTF8Bytes)
        guard let dirId: [Int32] = r.blob(count), let nameStart: [Int32] = r.blob(count), let nameLen: [UInt16] = r.blob(count),
              let displayStart: [Int32] = r.blob(count), let displayLen: [UInt16] = r.blob(count), let mask: [UInt64] = r.blob(count),
              let initials: [UInt64] = r.blob(count), let mtime: [UInt32] = r.blob(count), let kind: [UInt8] = r.blob(count),
              let flags: [UInt8] = r.blob(count), let depth: [UInt8] = r.blob(count), let extId: [Int16] = r.blob(count),
              let foldedArena: [UInt8] = r.blob(maxBytes: analyzedArenaLimit),
              let bonusArena: [UInt8] = r.blob(maxBytes: analyzedArenaLimit),
              let displayArena: [UInt8] = r.blob(maxBytes: displayArenaLimit),
              let dirParents: [Int32] = r.blob(dirCount), let dirNameStart: [Int32] = r.blob(dirCount), let dirNameLen: [UInt16] = r.blob(dirCount),
              let dirArena: [UInt8] = r.blob(maxBytes: dirArenaLimit), let jsonLen = r.u64(),
              let json = r.bytes(jsonLen, maxBytes: sideTableByteLimit(itemCount: count)),
              r.u32() == magic, r.atEnd else { return nil }
        guard hasSafeJSONStructure(json) else { return nil }
        guard let side = try? JSONDecoder().decode(SideTables.self, from: json) else { return nil }
        guard foldedArena.count == bonusArena.count,
              validateSideTables(side, count: count, kinds: kind) else { return nil }
        var dirs: [DirEntry] = []
        dirs.reserveCapacity(dirCount)
        var rootCount = 0
        for i in 0..<dirCount {
            let e = DirEntry(parent: dirParents[i], nameStart: dirNameStart[i], nameLen: dirNameLen[i])
            if e.parent < 0 {
                rootCount += 1
                guard rootCount <= SafetyLimits.maxIndexRoots else { return nil }
            }
            dirs.append(e)
        }
        guard let directoryPathLengths = IndexStoreLimits.validDirectoryPathLengths(
            dirs, arena: dirArena
        ) else { return nil }
        for i in 0..<count {
            let foldedStart = Int(nameStart[i]), foldedLength = Int(nameLen[i])
            let shownStart = Int(displayStart[i]), shownLength = Int(displayLen[i])
            let shownBytes: ArraySlice<UInt8>
            let shownName: String
            guard dirId[i] >= 0, Int(dirId[i]) < dirCount,
                  foldedStart >= 0, foldedLength <= maximumAnalyzedNameBytes,
                  foldedStart <= foldedArena.count, foldedLength <= foldedArena.count - foldedStart,
                  shownStart >= 0, shownLength <= SafetyLimits.maxNameUTF8Bytes,
                  shownStart <= displayArena.count,
                  shownLength <= displayArena.count - shownStart else { return nil }
            shownBytes = displayArena[shownStart..<(shownStart + shownLength)]
            guard let decodedName = String(bytes: shownBytes, encoding: .utf8) else { return nil }
            shownName = decodedName
            let directoryIndex = Int(dirId[i])
            guard SafetyLimits.isSafePathComponent(
                    shownName, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
                  ),
                  IndexStoreLimits.completeItemPathFits(
                    directoryPathUTF8Bytes: directoryPathLengths[directoryIndex],
                    directoryEndsInSlash: IndexStoreLimits.directoryEntryEndsInSlash(
                        dirs[directoryIndex], arena: dirArena
                    ),
                    storedName: shownName, flagsRaw: flags[i]
                  ),
                  ItemKind(rawValue: kind[i]) != nil,
                  depth[i] <= UInt8(SafetyLimits.maxDepth.upperBound),
                  extId[i] >= -1, Int(extId[i]) < side.extensions.count else { return nil }
        }
        var appInfo: [Int32: AppInfo] = [:]
        for e in side.appInfo {
            guard appInfo[e.item] == nil else { return nil }
            appInfo[e.item] = e.info
        }
        return IndexStore(count: count, dirId: dirId, nameStart: nameStart, nameLen: nameLen, displayStart: displayStart, displayLen: displayLen,
                          mask: mask, initials: initials, mtime: mtime, kind: kind, flags: flags, depth: depth, extId: extId,
                          foldedArena: foldedArena, bonusArena: bonusArena, displayArena: displayArena, dirs: dirs, dirArena: dirArena,
                          extensions: side.extensions, appInfo: appInfo, appItems: side.appItems,
                          generation: generation, fsEventId: fsEventId, builtAt: Date(timeIntervalSince1970: builtAt))
    }

    // MARK: Resource bounds + structural validation

    /// Validate the fixed header before reading any attacker-sized body and return the tighter cap
    /// implied by its already-bounded item count. Full decoding repeats these checks defensively.
    private static func preflightFileLimit(_ header: Data, expectedHeaderHash: UInt64,
                                           maxItems: Int, rootAllowance: Int) -> Int? {
        guard header.count == headerByteCount else { return nil }
        var reader = Reader(data: header)
        guard reader.u32() == magic, reader.u32() == schemaVersion,
              reader.u64() == expectedHeaderHash,
              reader.u64() != nil, reader.u64() != nil,
              let builtAt = reader.f64(), builtAt.isFinite,
              let itemCount = reader.u64(), let directoryCount = reader.u64(), reader.atEnd else { return nil }
        let itemLimit = IndexStoreLimits.normalizedMaxItems(maxItems)
        guard itemCount <= UInt64(itemLimit), itemCount <= UInt64(Int32.max),
              directoryCount <= UInt64(Int32.max) else { return nil }
        let count = Int(itemCount)
        guard directoryCount <= UInt64(IndexStoreLimits.directoryLimit(itemCount: count,
                                                                        rootAllowance: normalizedRootAllowance(rootAllowance))) else {
            return nil
        }
        return maximumFileBytes(maxItems: count, rootAllowance: rootAllowance)
    }

    /// Maximum bytes accepted before opening/decoding a snapshot for the caller's configured cap.
    /// The calculation accounts for the exact fixed-width arrays, bounded directory topology,
    /// bounded names/analysis arenas, and bounded JSON side table, then applies the rebuildable-cache
    /// ceiling. Saturating arithmetic prevents hostile programmatic arguments from wrapping smaller.
    public static func maximumFileBytes(maxItems: Int, rootAllowance: Int) -> Int {
        let items = IndexStoreLimits.normalizedMaxItems(maxItems)
        let roots = normalizedRootAllowance(rootAllowance)
        let directories = IndexStoreLimits.directoryLimit(itemCount: items, rootAllowance: roots)
        var total = 220 // 56-byte header + 19 blob lengths + JSON length + 4-byte trailer
        total = IndexStoreLimits.adding(total, IndexStoreLimits.multiplying(items, 41))
        total = IndexStoreLimits.adding(total, IndexStoreLimits.multiplying(directories, 10))
        total = IndexStoreLimits.adding(total, IndexStoreLimits.directoryArenaLimit(itemCount: items,
                                                                                     rootAllowance: roots))
        total = IndexStoreLimits.adding(total, itemArenaByteLimit(itemCount: items,
                                                                  bytesPerItem: maximumAnalyzedNameBytes))
        total = IndexStoreLimits.adding(total, itemArenaByteLimit(itemCount: items,
                                                                  bytesPerItem: maximumAnalyzedNameBytes))
        total = IndexStoreLimits.adding(total, itemArenaByteLimit(itemCount: items,
                                                                  bytesPerItem: SafetyLimits.maxNameUTF8Bytes))
        total = IndexStoreLimits.adding(total, sideTableByteLimit(itemCount: items))
        return min(absoluteMaximumFileBytes, max(4_096, total))
    }

    private static func normalizedRootAllowance(_ value: Int) -> Int {
        min(max(0, value), SafetyLimits.maxIndexRoots)
    }

    private static func itemArenaByteLimit(itemCount: Int, bytesPerItem: Int) -> Int {
        min(absoluteMaximumFileBytes,
            IndexStoreLimits.multiplying(max(0, itemCount), max(0, bytesPerItem)))
    }

    private static func sideTableByteLimit(itemCount _: Int) -> Int {
        // The builder incrementally enforces this same absolute semantic budget. A proportional
        // small-store cap would make the accepted state space non-monotonic: one app with a few
        // legal maximum-length aliases could build successfully yet fail persistence, while merely
        // adding unrelated items would raise the snapshot allowance. The fixed ceiling preserves
        // `IndexBuilder` acceptance => Snapshot round-trip and remains a hard allocation bound.
        maximumSideTableBytes
    }

    private static func exactEncodedByteCount(store: IndexStore, jsonBytes: Int) -> Int {
        var total = 220
        total = IndexStoreLimits.adding(total, IndexStoreLimits.multiplying(store.count, 41))
        total = IndexStoreLimits.adding(total, store.foldedArena.count)
        total = IndexStoreLimits.adding(total, store.bonusArena.count)
        total = IndexStoreLimits.adding(total, store.displayArena.count)
        total = IndexStoreLimits.adding(total, IndexStoreLimits.multiplying(store.dirs.count, 10))
        total = IndexStoreLimits.adding(total, store.dirArena.count)
        total = IndexStoreLimits.adding(total, jsonBytes)
        return total
    }

    private static func validateStore(_ store: IndexStore, rootAllowance: Int) -> Bool {
        guard store.count >= 0, store.count <= SafetyLimits.maxIndexedItems.upperBound,
              rootAllowance >= 0, rootAllowance <= SafetyLimits.maxIndexRoots,
              store.builtAt.timeIntervalSince1970.isFinite,
              IndexStoreLimits.acceptsDirectoryMetadata(itemCount: store.count,
                                                        dirCount: store.dirs.count,
                                                        dirArenaBytes: store.dirArena.count,
                                                        rootAllowance: rootAllowance),
              store.foldedArena.count == store.bonusArena.count,
              store.foldedArena.count <= itemArenaByteLimit(itemCount: store.count,
                                                             bytesPerItem: maximumAnalyzedNameBytes),
              store.displayArena.count <= itemArenaByteLimit(itemCount: store.count,
                                                              bytesPerItem: SafetyLimits.maxNameUTF8Bytes),
              let directoryPathLengths = IndexStoreLimits.validDirectoryPathLengths(
                store.dirs, arena: store.dirArena
              ) else { return false }
        for i in 0..<store.count {
            let foldedStart = Int(store.nameStart[i]), foldedLength = Int(store.nameLen[i])
            let shownStart = Int(store.displayStart[i]), shownLength = Int(store.displayLen[i])
            let shownBytes: ArraySlice<UInt8>
            let shownName: String
            guard store.dirId[i] >= 0, Int(store.dirId[i]) < store.dirs.count,
                  foldedStart >= 0, foldedLength <= maximumAnalyzedNameBytes,
                  foldedStart <= store.foldedArena.count, foldedLength <= store.foldedArena.count - foldedStart,
                  shownStart >= 0, shownLength <= SafetyLimits.maxNameUTF8Bytes,
                  shownStart <= store.displayArena.count,
                  shownLength <= store.displayArena.count - shownStart else { return false }
            shownBytes = store.displayArena[shownStart..<(shownStart + shownLength)]
            guard let decodedName = String(bytes: shownBytes, encoding: .utf8) else { return false }
            shownName = decodedName
            let directoryIndex = Int(store.dirId[i])
            guard SafetyLimits.isSafePathComponent(
                    shownName, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
                  ),
                  IndexStoreLimits.completeItemPathFits(
                    directoryPathUTF8Bytes: directoryPathLengths[directoryIndex],
                    directoryEndsInSlash: IndexStoreLimits.directoryEntryEndsInSlash(
                        store.dirs[directoryIndex], arena: store.dirArena
                    ),
                    storedName: shownName, flagsRaw: store.flags[i]
                  ),
                  ItemKind(rawValue: store.kind[i]) != nil,
                  store.depth[i] <= UInt8(SafetyLimits.maxDepth.upperBound),
                  store.extId[i] >= -1, Int(store.extId[i]) < store.extensions.count else { return false }
        }
        return true
    }

    private static func validateSideTables(_ side: SideTables, count: Int, kinds: [UInt8]) -> Bool {
        guard kinds.count == count,
              side.extensions.count <= min(count, Int(Int16.max) + 1),
              side.appInfo.count <= count, side.appItems.count <= count else { return false }
        var extensions = Set<String>()
        for ext in side.extensions {
            guard SafetyLimits.utf8Fits(ext, maxBytes: SafetyLimits.maxExtensionUTF8Bytes),
                  SafetyLimits.isSafePathComponent(
                    ext, maxUTF8Bytes: SafetyLimits.maxExtensionUTF8Bytes
                  ),
                  ext.count <= SafetyLimits.maxExtensionCharacters,
                  extensions.insert(ext).inserted else { return false }
        }

        var infoItems = Set<Int32>()
        for entry in side.appInfo {
            guard entry.item >= 0, Int(entry.item) < count,
                  kinds[Int(entry.item)] == ItemKind.app.rawValue,
                  infoItems.insert(entry.item).inserted,
                  !entry.info.displayName.isEmpty,
                  !entry.info.displayName.utf8.contains(0),
                  SafetyLimits.utf8Fits(entry.info.displayName,
                                        maxBytes: SafetyLimits.maxNameUTF8Bytes),
                  (entry.info.bundleID.map {
                      !$0.utf8.contains(0)
                          && SafetyLimits.utf8Fits($0, maxBytes: SafetyLimits.maxSettingUTF8Bytes)
                  } ?? true),
                  entry.info.aliases.count <= maximumAliasesPerApp else { return false }
            for alias in entry.info.aliases {
                guard !alias.folded.isEmpty,
                      alias.folded.count == alias.bonus.count,
                      alias.folded.count <= maximumAnalyzedNameBytes else { return false }
            }
        }

        var previous: Int32 = -1
        for item in side.appItems {
            guard item > previous, Int(item) < count,
                  kinds[Int(item)] == ItemKind.app.rawValue else { return false }
            previous = item
        }
        return containsEveryAppItem(side.appItems, kinds: kinds)
    }

    /// `appItems` is documented as the complete sorted index of `.app` kinds, not merely an
    /// arbitrary valid subset. Enforcing completeness prevents a syntactically valid hostile cache
    /// from making apps disappear from app-only merge/search paths until the next full crawl.
    private static func containsEveryAppItem(_ appItems: [Int32], kinds: [UInt8]) -> Bool {
        var cursor = 0
        for (index, kind) in kinds.enumerated() where kind == ItemKind.app.rawValue {
            guard cursor < appItems.count, appItems[cursor] == Int32(index) else { return false }
            cursor += 1
        }
        return cursor == appItems.count
    }

    /// Validate and budget every semantic side-table field before sorting keys, constructing
    /// `SideTables`, or invoking `JSONEncoder`. JSON expands byte arrays to decimal tokens and may
    /// escape strings, so the claims use the shared scalar-aware escape upper bound plus per-record
    /// overhead. The fixed 32 MiB product ceiling therefore bounds encoder input and its output
    /// allocation even for a programmatically constructed `IndexStore`.
    private static func preflightSideTableInputs(_ store: IndexStore, maxBytes: Int) throws {
        guard maxBytes >= 0, store.kind.count == store.count,
              store.extensions.count <= min(store.count, Int(Int16.max) + 1),
              store.appInfo.count <= store.count, store.appItems.count <= store.count else {
            throw EncodingFailure.invalidStore
        }
        var claimed = 256
        func claim(_ bytes: Int) throws {
            guard bytes >= 0 else { throw EncodingFailure.invalidStore }
            guard claimed <= maxBytes, bytes <= maxBytes - claimed else {
                throw EncodingFailure.tooLarge(maxBytes: maxBytes)
            }
            claimed += bytes
        }

        // Fail from counts before walking attacker-sized collections. The multiplications saturate,
        // and `claim` rejects saturation without overflow.
        try claim(IndexStoreLimits.multiplying(store.extensions.count, 16))
        try claim(IndexStoreLimits.multiplying(store.appItems.count, 16))
        try claim(IndexStoreLimits.multiplying(store.appInfo.count, 128))

        var extensions = Set<String>()
        extensions.reserveCapacity(min(store.extensions.count, 4_096))
        for ext in store.extensions {
            guard SafetyLimits.utf8Fits(ext, maxBytes: SafetyLimits.maxExtensionUTF8Bytes),
                  SafetyLimits.isSafePathComponent(
                    ext, maxUTF8Bytes: SafetyLimits.maxExtensionUTF8Bytes
                  ),
                  ext.count <= SafetyLimits.maxExtensionCharacters,
                  extensions.insert(ext).inserted else { throw EncodingFailure.invalidStore }
            try claim(SafetyLimits.jsonEscapedStringByteUpperBound(ext))
        }

        var previous: Int32 = -1
        for item in store.appItems {
            guard item > previous, Int(item) < store.count,
                  store.kind[Int(item)] == ItemKind.app.rawValue else {
                throw EncodingFailure.invalidStore
            }
            previous = item
        }
        guard containsEveryAppItem(store.appItems, kinds: store.kind) else {
            throw EncodingFailure.invalidStore
        }

        for (item, info) in store.appInfo {
            guard item >= 0, Int(item) < store.count,
                  store.kind[Int(item)] == ItemKind.app.rawValue,
                  !info.displayName.isEmpty,
                  !info.displayName.utf8.contains(0),
                  SafetyLimits.utf8Fits(info.displayName, maxBytes: SafetyLimits.maxNameUTF8Bytes),
                  info.aliases.count <= maximumAliasesPerApp else {
                throw EncodingFailure.invalidStore
            }
            try claim(SafetyLimits.jsonEscapedStringByteUpperBound(info.displayName))
            if let bundleID = info.bundleID {
                guard !bundleID.utf8.contains(0),
                      SafetyLimits.utf8Fits(bundleID,
                                            maxBytes: SafetyLimits.maxSettingUTF8Bytes) else {
                    throw EncodingFailure.invalidStore
                }
                try claim(SafetyLimits.jsonEscapedStringByteUpperBound(bundleID))
            }
            try claim(IndexStoreLimits.multiplying(info.aliases.count, 96))
            for alias in info.aliases {
                guard !alias.folded.isEmpty,
                      alias.folded.count == alias.bonus.count,
                      alias.folded.count <= maximumAnalyzedNameBytes else {
                    throw EncodingFailure.invalidStore
                }
                let arrays = IndexStoreLimits.adding(alias.folded.count, alias.bonus.count)
                try claim(IndexStoreLimits.multiplying(arrays, 4))
            }
        }
    }

    /// `JSONDecoder` is only reached after a linear, allocation-free nesting scan. This prevents a
    /// bounded-bytes but pathologically deep side table from turning parser recursion into a stack or
    /// CPU denial of service. Matching delimiters are checked while quoted/escaped bytes are ignored.
    static func hasSafeJSONStructure(_ data: Data) -> Bool {
        var delimiters: [UInt8] = []
        delimiters.reserveCapacity(maximumJSONNestingDepth)
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C { // backslash
                    escaped = true
                } else if byte == 0x22 { // quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22: // quote
                inString = true
            case 0x7B, 0x5B: // { [
                guard delimiters.count < maximumJSONNestingDepth else { return false }
                delimiters.append(byte)
            case 0x7D: // }
                guard delimiters.popLast() == 0x7B else { return false }
            case 0x5D: // ]
                guard delimiters.popLast() == 0x5B else { return false }
            default:
                break
            }
        }
        return !inString && !escaped && delimiters.isEmpty
    }

    // MARK: Header hash

    /// Combine the inputs that invalidate a snapshot.
    public static func headerHash(exclusions: Exclusions, fileRoots: [String], appRoots: [String],
                                  maxItems: Int) -> UInt64 {
        var h = FNV1a()
        h.update(exclusions.stableHash)
        h.update("jbar.snapshot.file-roots.v1")
        h.update(UInt64(fileRoots.count))
        for r in fileRoots.sorted() { h.update(r); h.update("\u{1}") }
        h.update("jbar.snapshot.app-roots.v1")
        h.update(UInt64(appRoots.count))
        for r in appRoots.sorted() { h.update(r); h.update("\u{1}") }
        h.update("jbar.snapshot.max-items.v1")
        h.update(UInt64(IndexStoreLimits.normalizedMaxItems(maxItems)))
        h.update(BonusConstants.hash)
        h.update(UInt64(schemaVersion))
        return h.value
    }

    /// Source-compatible entry point for embedding clients that only index file roots. New code
    /// should pass both root domains and the effective cap explicitly.
    @available(*, deprecated, message: "Use headerHash(exclusions:fileRoots:appRoots:maxItems:)")
    public static func headerHash(exclusions: Exclusions, roots: [String]) -> UInt64 {
        headerHash(exclusions: exclusions, fileRoots: roots, appRoots: [], maxItems: 1_000_000)
    }

    // MARK: Byte helpers

    struct Writer {
        var data = Data()
        mutating func reserve(_ n: Int) { data.reserveCapacity(n) }
        mutating func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        mutating func put(_ v: Double) { put(v.bitPattern) }
        mutating func blob<T>(_ a: [T]) {
            let byteCount = a.count * MemoryLayout<T>.stride
            put(UInt64(byteCount))
            a.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    struct Reader {
        let data: Data
        var pos: Int
        init(data: Data) { self.data = data; pos = data.startIndex }
        var atEnd: Bool { pos == data.endIndex }
        mutating func bytes(_ n: UInt64, maxBytes: Int? = nil) -> Data? {
            guard n <= UInt64(data.endIndex - pos) else { return nil }
            if let maxBytes, n > UInt64(max(0, maxBytes)) { return nil }
            let out = data.subdata(in: pos..<(pos + Int(n)))
            pos += Int(n)
            return out
        }
        mutating func u32() -> UInt32? { load(UInt32.self) }
        mutating func u64() -> UInt64? { load(UInt64.self) }
        mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
        private mutating func load<T: FixedWidthInteger>(_: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard n <= data.endIndex - pos else { return nil }
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: pos..<(pos + n)) }
            pos += n
            return T(littleEndian: v)
        }
        /// Read a blob as `[T]`; if `expectedCount` is given the element count must match.
        mutating func blob<T>(_ expectedCount: Int? = nil, maxBytes: Int? = nil) -> [T]? {
            guard let len = u64(), len <= UInt64(data.endIndex - pos) else { return nil }
            if let maxBytes, len > UInt64(max(0, maxBytes)) { return nil }
            let stride = MemoryLayout<T>.stride
            guard Int(len) % stride == 0 else { return nil }
            let n = Int(len) / stride
            if let e = expectedCount, e != n { return nil }
            let start = pos
            pos += Int(len)
            return [T](unsafeUninitializedCapacity: n) { buf, initialized in
                if n > 0 { data.copyBytes(to: buf, from: start..<(start + Int(len))) }
                initialized = n
            }
        }
    }
}
