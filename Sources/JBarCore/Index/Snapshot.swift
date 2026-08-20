import Foundation

/// Binary on-disk snapshot of an `IndexStore`. DESIGN.md §3. Owner: indexer agent.
///
/// Layout (little-endian, unaligned):
/// ```
/// magic "JBIX" (UInt32) · schemaVersion (UInt32) · headerHash (UInt64) · generation (UInt64) · fsEventId (UInt64)
/// · builtAt (Double, seconds since 1970) · count (UInt64) · dirCount (UInt64)
/// · 17 blobs, each (byteLength: UInt64, raw bytes): dirId nameStart nameLen displayStart displayLen mask initials
///   mtime kind flags depth extId foldedArena bonusArena displayArena dirParents(Int32) dirNameStart(Int32)
///   dirNameLen(UInt16) dirArena
/// · 1 JSON blob (byteLength: UInt64, bytes): { extensions, appInfo: [(item, AppInfo)], appItems }
/// · trailer magic "JBIX" (UInt32)
/// ```
/// `headerHash` = `headerHash(exclusions:roots:)` (exclusions.stableHash ⊕ roots ⊕ BonusConstants.hash).
/// Written atomically (`Data.write(options: .atomic)` = temp file + rename). Loaded with
/// `Data(contentsOf:options:.mappedIfSafe)` and copied into arrays. Every length is bounds-checked and every
/// cross-reference (dir ids, arena ranges, ext ids, dir parents) validated, so a truncated or corrupt file yields
/// `nil` instead of a crash. Any mismatch in magic, schema version or headerHash → `nil` (caller recrawls).
public enum Snapshot {
    public static let magic: UInt32 = 0x4A424958 // "JBIX"
    public static let schemaVersion: UInt32 = 1

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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Serialise `store` into the snapshot format.
    public static func encode(_ store: IndexStore, headerHash: UInt64) throws -> Data {
        var w = Writer()
        w.reserve(store.count * 90 + store.foldedArena.count * 2 + store.displayArena.count + store.dirArena.count + 1024)
        w.put(magic); w.put(schemaVersion); w.put(headerHash); w.put(store.generation); w.put(store.fsEventId)
        w.put(store.builtAt.timeIntervalSince1970); w.put(UInt64(store.count)); w.put(UInt64(store.dirs.count))
        w.blob(store.dirId); w.blob(store.nameStart); w.blob(store.nameLen); w.blob(store.displayStart); w.blob(store.displayLen)
        w.blob(store.mask); w.blob(store.initials); w.blob(store.mtime); w.blob(store.kind); w.blob(store.flags)
        w.blob(store.depth); w.blob(store.extId); w.blob(store.foldedArena); w.blob(store.bonusArena); w.blob(store.displayArena)
        w.blob(store.dirs.map { $0.parent }); w.blob(store.dirs.map { $0.nameStart }); w.blob(store.dirs.map { $0.nameLen }); w.blob(store.dirArena)
        let side = SideTables(extensions: store.extensions,
                              appInfo: store.appInfo.keys.sorted().map { SideTables.AppEntry(item: $0, info: store.appInfo[$0]!) },
                              appItems: store.appItems)
        let json = try JSONEncoder().encode(side)
        w.put(UInt64(json.count)); w.data.append(json)
        w.put(magic)
        return w.data
    }

    // MARK: Read

    /// Load a store from `url`. Returns nil if missing, corrupt, or `headerHash` mismatches.
    public static func read(from url: URL, expectedHeaderHash: UInt64) -> IndexStore? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data, expectedHeaderHash: expectedHeaderHash)
    }

    /// Parse snapshot bytes. nil on any inconsistency.
    public static func decode(_ data: Data, expectedHeaderHash: UInt64) -> IndexStore? {
        var r = Reader(data: data)
        guard r.u32() == magic, r.u32() == schemaVersion, r.u64() == expectedHeaderHash else { return nil }
        guard let generation = r.u64(), let fsEventId = r.u64(), let builtAt = r.f64(),
              let count64 = r.u64(), let dirCount64 = r.u64(), count64 <= UInt64(Int32.max), dirCount64 <= UInt64(Int32.max) else { return nil }
        let count = Int(count64), dirCount = Int(dirCount64)
        guard let dirId: [Int32] = r.blob(count), let nameStart: [Int32] = r.blob(count), let nameLen: [UInt16] = r.blob(count),
              let displayStart: [Int32] = r.blob(count), let displayLen: [UInt16] = r.blob(count), let mask: [UInt64] = r.blob(count),
              let initials: [UInt64] = r.blob(count), let mtime: [UInt32] = r.blob(count), let kind: [UInt8] = r.blob(count),
              let flags: [UInt8] = r.blob(count), let depth: [UInt8] = r.blob(count), let extId: [Int16] = r.blob(count),
              let foldedArena: [UInt8] = r.blob(), let bonusArena: [UInt8] = r.blob(), let displayArena: [UInt8] = r.blob(),
              let dirParents: [Int32] = r.blob(dirCount), let dirNameStart: [Int32] = r.blob(dirCount), let dirNameLen: [UInt16] = r.blob(dirCount),
              let dirArena: [UInt8] = r.blob(), let jsonLen = r.u64(), let json = r.bytes(jsonLen), r.u32() == magic, r.atEnd else { return nil }
        guard let side = try? JSONDecoder().decode(SideTables.self, from: json) else { return nil }
        guard foldedArena.count == bonusArena.count else { return nil }
        var dirs: [DirEntry] = []
        dirs.reserveCapacity(dirCount)
        for i in 0..<dirCount {
            let e = DirEntry(parent: dirParents[i], nameStart: dirNameStart[i], nameLen: dirNameLen[i])
            guard e.parent >= -1, e.parent < Int32(i), Int(e.nameStart) >= 0, Int(e.nameStart) + Int(e.nameLen) <= dirArena.count else { return nil }
            dirs.append(e)
        }
        for i in 0..<count {
            guard dirId[i] >= 0, Int(dirId[i]) < dirCount,
                  nameStart[i] >= 0, Int(nameStart[i]) + Int(nameLen[i]) <= foldedArena.count,
                  displayStart[i] >= 0, Int(displayStart[i]) + Int(displayLen[i]) <= displayArena.count,
                  extId[i] >= -1, Int(extId[i]) < side.extensions.count else { return nil }
        }
        var appInfo: [Int32: AppInfo] = [:]
        for e in side.appInfo { guard e.item >= 0, Int(e.item) < count else { return nil }; appInfo[e.item] = e.info }
        for a in side.appItems { guard a >= 0, Int(a) < count else { return nil } }
        return IndexStore(count: count, dirId: dirId, nameStart: nameStart, nameLen: nameLen, displayStart: displayStart, displayLen: displayLen,
                          mask: mask, initials: initials, mtime: mtime, kind: kind, flags: flags, depth: depth, extId: extId,
                          foldedArena: foldedArena, bonusArena: bonusArena, displayArena: displayArena, dirs: dirs, dirArena: dirArena,
                          extensions: side.extensions, appInfo: appInfo, appItems: side.appItems,
                          generation: generation, fsEventId: fsEventId, builtAt: Date(timeIntervalSince1970: builtAt))
    }

    // MARK: Header hash

    /// Combine the inputs that invalidate a snapshot.
    public static func headerHash(exclusions: Exclusions, roots: [String]) -> UInt64 {
        var h = FNV1a()
        h.update(exclusions.stableHash)
        h.update(UInt64(roots.count))
        for r in roots.sorted() { h.update(r); h.update("\u{1}") }
        h.update(BonusConstants.hash)
        h.update(UInt64(schemaVersion))
        return h.value
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
        mutating func bytes(_ n: UInt64) -> Data? {
            guard n <= UInt64(data.endIndex - pos) else { return nil }
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
            withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: pos..<(pos + n)) }
            pos += n
            return T(littleEndian: v)
        }
        /// Read a blob as `[T]`; if `expectedCount` is given the element count must match.
        mutating func blob<T>(_ expectedCount: Int? = nil) -> [T]? {
            guard let len = u64(), len <= UInt64(data.endIndex - pos) else { return nil }
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
