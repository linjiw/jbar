import Foundation
import JBarCore

public struct CLIResult: Codable, Sendable {
    public let name: String
    public let path: String
    public let kind: String
    public let score: Int
    public let tier: Int
    public let modifiedAt: TimeInterval?
    public let flags: UInt8?
}

public struct CLISearchOutput: Codable, Sendable {
    public let type: String
    public let id: String?
    public let query: String
    public let source: String
    public let mode: String
    public let elapsedSeconds: TimeInterval
    public let startupSeconds: TimeInterval
    public let totalMatches: Int
    public let totalMatchesIsComplete: Bool
    public let hasMoreResults: Bool?
    public let returnedCount: Int
    public let index: CLIIndexMetadata
    public let results: [CLIResult]
}

/// Stdio sessions retain this engine, including its incremental candidate cache, across requests.
public actor CLISearchSession {
    public let index: CLIIndex
    private let engine = SearchEngine()
    private var initialized = false
    // Retain only one bounded query path and its matching directory IDs. Expanding every arena
    // directory to an absolute String multiplies a long root prefix by the entire index size.
    private var lastDirectoryLookup: (path: String, ids: Set<Int32>)?

    public init(index: CLIIndex) { self.index = index }

    public func search(query: String, limit: Int, id: String? = nil, now: Date = Date()) async throws -> CLISearchOutput {
        try CLIOptions.validateQuery(query)
        guard SafetyLimits.maxResults.contains(limit) else { throw CLIError("limit must be in 1...\(SafetyLimits.maxResults.upperBound).") }
        guard index.settings.allowStale || now.timeIntervalSince(index.store.builtAt) <= index.settings.maxAge else {
            throw CLIError("Retained index is older than --max-age. Reindex and restart serve, or explicitly use --allow-stale.", code: 3)
        }
        let parsed = QueryParser.parse(query, home: index.settings.home)
        if case .path(let base, let filter) = parsed.mode {
            let start = DispatchTime.now().uptimeNanoseconds
            // Snapshot paths use POSIX lexical components. Foundation URL standardization can
            // change long, nonexistent paths differently across OS versions and may inspect the
            // filesystem. Validate the bounded base directly without resolving an on-disk tree.
            guard Self.isCanonicalSnapshotDirectory(base) else {
                throw CLIError("Use a canonical absolute directory path.")
            }
            guard index.settings.roots.contains(where: { CLIIndexSettings.contains(base, under: $0.path) }) else {
                throw CLIError("Path browsing must stay within an indexed root.")
            }
            // Read the immutable snapshot only; directory replacement cannot expose another tree.
            // Resolve the requested directory through component slices, then stream its item IDs
            // from the existing dirId column. No whole-index path strings or item buckets are built.
            let ids = resolveDirectory(base)
            guard !ids.isEmpty else {
                throw CLIError("Directory was not descended in the index (excluded, hidden, package, depth-limited, or absent).")
            }
            if !index.settings.exclusions.includeHidden && SafetyLimits.hasDotPrefix(filter) {
                throw CLIError("Hidden entries require indexing with --include-hidden.")
            }
            let outcome = directorySearch(directoryIDs: ids, filter: filter, limit: limit)
            return CLISearchOutput(type: "search", id: id, query: query, source: "snapshot", mode: "directory",
                                   elapsedSeconds: CLIIndex.elapsed(since: start), startupSeconds: index.startupSeconds,
                                   totalMatches: outcome.total, totalMatchesIsComplete: true,
                                   hasMoreResults: outcome.total > outcome.results.count,
                                   returnedCount: outcome.results.count, index: index.metadata(now: now), results: outcome.results)
        }
        if !initialized {
            await engine.setHome(index.settings.home)
            await engine.update(store: index.store)
            initialized = true
        }
        let response = await engine.search(query, limit: limit, appsFirstCap: 0, now: now)
        guard !response.cancelled else { throw CLIError("Search was superseded.", code: 1) }
        let results = response.rows.prefix(limit).map { result(item: $0.itemIndex, name: $0.name, score: $0.score, tier: $0.tier) }
        let mode: String
        if case .extensionOnly = parsed.mode { mode = "extension" } else { mode = "filename" }
        return CLISearchOutput(type: "search", id: id, query: response.query, source: "snapshot", mode: mode,
                               elapsedSeconds: response.elapsed, startupSeconds: index.startupSeconds,
                               totalMatches: response.totalMatches, totalMatchesIsComplete: response.totalMatchesIsComplete,
                               hasMoreResults: response.totalMatchesIsComplete ? response.totalMatches > results.count : nil,
                               returnedCount: results.count, index: index.metadata(now: now), results: results)
    }

    private func result(item: Int, name: String, score: Int, tier: Int) -> CLIResult {
        let time = index.store.mtime[item] > 0
            ? Double(index.store.mtime[item]) + Date.timeIntervalBetween1970AndReferenceDate : nil
        return CLIResult(name: name, path: index.store.path(of: item), kind: String(describing: index.store.itemKind(item)),
                         score: score, tier: tier, modifiedAt: time, flags: index.store.flags[item])
    }

    private static func isCanonicalSnapshotDirectory(_ path: String) -> Bool {
        guard SafetyLimits.isSafeAbsolutePath(path) else { return false }
        let bytes = path.utf8
        if bytes.count > 1 && bytes.last == 0x2F { return false }
        var previousWasSlash = false
        for byte in bytes {
            let isSlash = byte == 0x2F
            if isSlash && previousWasSlash { return false }
            previousWasSlash = isSlash
        }
        return true
    }

    private func resolveDirectory(_ path: String) -> Set<Int32> {
        if let cached = lastDirectoryLookup, cached.path == path { return cached.ids }
        let bytes = Array(path.utf8)
        let separators = bytes.indices.filter { bytes[$0] == 0x2F }
        var ids = Set<Int32>()
        for directory in index.store.dirs.indices where directoryMatches(Int32(directory), pathBytes: bytes, separators: separators) {
            ids.insert(Int32(directory))
        }
        lastDirectoryLookup = (path, ids)
        return ids
    }

    /// Compare a directory chain from its leaf toward the root without constructing its absolute
    /// path. Names are slice views into the validated arena. Canonical Unicode spellings fall back
    /// to component String equality, matching the shared POSIX containment contract.
    private func directoryMatches(_ directory: Int32, pathBytes: [UInt8], separators: [Int]) -> Bool {
        let store = index.store
        var current = directory
        var end = pathBytes.count
        var component = separators.count - 1
        while current >= 0 {
            let entry = store.dirs[Int(current)]
            let start = Int(entry.nameStart), length = Int(entry.nameLen)
            let stored = store.dirArena[start..<(start + length)]
            if entry.parent < 0 {
                let requested = pathBytes[..<end]
                if stored.elementsEqual(requested) { return true }
                let root = String(decoding: stored, as: UTF8.self)
                return SafetyLimits.relativePath(String(decoding: requested, as: UTF8.self), within: root) == ""
            }
            guard component >= 0 else { return false }
            let componentStart = separators[component] + 1
            guard componentStart <= end else { return false }
            let requested = pathBytes[componentStart..<end]
            if !stored.elementsEqual(requested) {
                // Ordinary ASCII mismatches need no String allocation. Unicode aliases retain
                // canonical-equivalence support without retaining reconstructed directory paths.
                guard (stored.contains { $0 >= 0x80 } || requested.contains { $0 >= 0x80 }),
                      String(decoding: stored, as: UTF8.self) == String(decoding: requested, as: UTF8.self) else { return false }
            }
            // Keep the slash when the remaining root is `/`; otherwise remove the separator.
            end = componentStart == 1 ? 1 : componentStart - 1
            component -= 1
            current = entry.parent
        }
        return false
    }

    // Deterministic resource-budget observation for tests: production caches only the last lookup.
    func directoryLookupCacheMetrics() -> (pathUTF8Bytes: Int, directoryIDs: Int) {
        (lastDirectoryLookup?.path.utf8.count ?? 0, lastDirectoryLookup?.ids.count ?? 0)
    }

    private func directorySearch(directoryIDs: Set<Int32>, filter: String, limit: Int) -> (results: [CLIResult], total: Int) {
        let store = index.store
        let analyzed = TextAnalyzer.analyze(filter)
        let scratch = ScorerScratch()
        var heap = DirectoryTopK(capacity: limit)
        var total = 0
        let dotFilter = SafetyLimits.hasDotPrefix(filter)
        let onlyDirectory = directoryIDs.count == 1 ? directoryIDs.first : nil
        for item in store.dirId.indices {
            guard onlyDirectory.map({ store.dirId[item] == $0 }) ?? directoryIDs.contains(store.dirId[item]) else { continue }
            let name = store.fileName(of: item)
            guard SafetyLimits.hasDotPrefix(name) == dotFilter else { continue }
            let bytes: ArraySlice<UInt8>
            let bonus: ArraySlice<UInt8>
            if store.itemFlags(item).contains(.appBundle) {
                let app = TextAnalyzer.analyze(name)
                bytes = app.folded[...]; bonus = app.bonus[...]
            } else { bytes = store.foldedName(of: item); bonus = store.bonus(of: item) }
            let score: Int
            let tier: Int
            if filter.isEmpty { score = 0; tier = 0 }
            else {
                guard let scored = Scorer.score(query: analyzed.folded[...], text: bytes, bonus: bonus, scratch: scratch) else { continue }
                score = Int(scored.score)
                tier = bytes.starts(with: analyzed.folded) ? 0 : 1
            }
            total += 1
            heap.insert(DirectoryCandidate(item: item, name: name, tier: tier, score: score, folder: store.itemKind(item) == .folder))
        }
        let results = heap.items.sorted(by: DirectoryCandidate.better).map {
            result(item: $0.item, name: $0.name, score: $0.score, tier: $0.tier)
        }
        return (results, total)
    }

    public func handle(request: CLIServeRequest, defaultLimit: Int) async throws -> CLIServeResponse {
        switch request.command ?? "search" {
        case "search":
            guard let query = request.query else { throw CLIError("search requires query.") }
            return .search(try await search(query: query, limit: request.limit ?? defaultLimit, id: request.id))
        case "status":
            guard request.query == nil, request.limit == nil else { throw CLIError("status accepts only id and command.") }
            return .status(CLIStatusOutput(type: "status", id: request.id, index: index.metadata(), startupSeconds: index.startupSeconds))
        case "quit":
            guard request.query == nil, request.limit == nil else { throw CLIError("quit accepts only id and command.") }
            return .quit
        default: throw CLIError("Serve command must be search, status, or quit.")
        }
    }
}

private struct DirectoryCandidate {
    let item: Int
    let name: String
    let tier: Int
    let score: Int
    let folder: Bool
    static func better(_ a: DirectoryCandidate, _ b: DirectoryCandidate) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        if a.score != b.score { return a.score > b.score }
        if a.folder != b.folder { return a.folder }
        if a.name != b.name { return a.name < b.name }
        return a.item < b.item
    }
}

/// Worst-first bounded heap; scanning a directory retains at most the requested 500 rows.
private struct DirectoryTopK {
    let capacity: Int
    var items: [DirectoryCandidate] = []
    init(capacity: Int) { self.capacity = capacity; items.reserveCapacity(capacity) }
    mutating func insert(_ value: DirectoryCandidate) {
        if items.count < capacity {
            items.append(value)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard DirectoryCandidate.better(items[parent], items[child]) else { break }
                items.swapAt(parent, child); child = parent
            }
        } else if DirectoryCandidate.better(value, items[0]) {
            items[0] = value
            var parent = 0
            while parent * 2 + 1 < items.count {
                var child = parent * 2 + 1
                if child + 1 < items.count && DirectoryCandidate.better(items[child], items[child + 1]) { child += 1 }
                guard DirectoryCandidate.better(items[parent], items[child]) else { break }
                items.swapAt(parent, child); parent = child
            }
        }
    }
}

public struct CLIServeRequest: Codable, Sendable {
    public let id: String?
    public let command: String?
    public let query: String?
    public let limit: Int?
    public init(id: String? = nil, command: String? = nil, query: String? = nil, limit: Int? = nil) {
        self.id = id; self.command = command; self.query = query; self.limit = limit
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, command, query, limit }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw CLIError("Unknown serve request field; supported fields are id, command, query, limit.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        query = try values.decodeIfPresent(String.self, forKey: .query)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit)
    }

    /// Strict request decoding can reject an unsupported field or incorrectly typed query while
    /// the correlation ID remains valid. Recover only that bounded string for the error record.
    static func errorCorrelationID(from line: Data) -> String? {
        struct Identifier: Decodable { let id: String? }
        guard line.count <= CLIInputReader.maximumLineBytes else { return nil }
        return (try? JSONDecoder().decode(Identifier.self, from: line))?.id
    }
}

public enum CLIServeResponse: Sendable {
    case search(CLISearchOutput)
    case status(CLIStatusOutput)
    case quit
}

public struct CLIStatusOutput: Codable, Sendable {
    public let type: String
    public let id: String?
    public let index: CLIIndexMetadata
    public let startupSeconds: TimeInterval
}

public struct CLIErrorOutput: Encodable, Sendable {
    public let type = "error"
    public let id: String?
    public let code: Int32
    public let error: String
    public init(id: String? = nil, code: Int32, error: String) { self.id = id; self.code = code; self.error = error }
}
