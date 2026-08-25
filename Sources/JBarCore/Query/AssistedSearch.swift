import Foundation

public enum AssistedSearchSort: Sendable, Equatable {
    case relevance
    case modifiedDescending
    case nameAscending
}

/// A native, already-validated metadata request. It deliberately contains no natural-language
/// prompt and grants no filesystem capability beyond searching the immutable local index.
public struct AssistedSearchRequest: Sendable, Equatable {
    public static let maximumNameTerms = 6
    public static let maximumExtensions = 8
    public static let maximumResults = 40
    public static let maximumTermCharacters = 128
    public static let maximumTermUTF8Bytes = 512

    public let nameTerms: [String]
    public let extensions: Set<String>
    public let kinds: Set<ItemKind>
    public let modifiedAfter: Date?
    public let modifiedBefore: Date?
    public let minimumSizeBytes: Int64?
    public let maximumSizeBytes: Int64?
    public let sort: AssistedSearchSort
    public let limit: Int

    public init(nameTerms: [String], extensions: Set<String> = [], kinds: Set<ItemKind> = [],
                modifiedAfter: Date? = nil, modifiedBefore: Date? = nil,
                minimumSizeBytes: Int64? = nil, maximumSizeBytes: Int64? = nil,
                sort: AssistedSearchSort = .relevance, limit: Int = maximumResults) {
        self.nameTerms = nameTerms.prefix(Self.maximumNameTerms).compactMap(Self.boundedTerm)
        self.extensions = Set(extensions.lazy.compactMap(Self.boundedExtension)
            .prefix(Self.maximumExtensions))
        self.kinds = kinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.minimumSizeBytes = minimumSizeBytes
        self.maximumSizeBytes = maximumSizeBytes
        self.sort = sort
        self.limit = min(max(1, limit), Self.maximumResults)
    }

    private static func boundedTerm(_ raw: String) -> String? {
        let bytes = raw.utf8
        let byteLimited: String
        if let end = bytes.index(bytes.startIndex, offsetBy: maximumTermUTF8Bytes,
                                 limitedBy: bytes.endIndex), end < bytes.endIndex {
            byteLimited = String(decoding: bytes[..<end], as: UTF8.self)
        } else {
            byteLimited = raw
        }
        let characterLimited: String
        if let end = byteLimited.index(byteLimited.startIndex, offsetBy: maximumTermCharacters,
                                       limitedBy: byteLimited.endIndex), end < byteLimited.endIndex {
            characterLimited = String(byteLimited[..<end])
        } else {
            characterLimited = byteLimited
        }
        let trimmed = characterLimited.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boundedExtension(_ raw: String) -> String? {
        guard (1...8).contains(raw.utf8.count) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.utf8.count)
        for byte in raw.utf8 {
            switch byte {
            case 0x30...0x39, 0x61...0x7A: bytes.append(byte)
            case 0x41...0x5A: bytes.append(byte + 0x20)
            default: return nil
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct AssistedSearchResponse: Sendable {
    public let rows: [ResultRow]
    public let totalMatches: Int
    public let totalMatchesIsComplete: Bool
    public let scannedItems: Int
    public let inspectedSizes: Int
    public let generation: UInt64
    public let cancelled: Bool

    public init(rows: [ResultRow], totalMatches: Int, totalMatchesIsComplete: Bool,
                scannedItems: Int, inspectedSizes: Int, generation: UInt64,
                cancelled: Bool = false) {
        self.rows = rows
        self.totalMatches = totalMatches
        self.totalMatchesIsComplete = totalMatchesIsComplete
        self.scannedItems = scannedItems
        self.inspectedSizes = inspectedSizes
        self.generation = generation
        self.cancelled = cancelled
    }
}

public extension SearchEngine {
    /// Execute a typed metadata plan away from the actor and MainActor. Structured child-task
    /// cancellation means closing the Assistant window stops the scan at its next bounded poll.
    func assistedSearch(_ request: AssistedSearchRequest) async -> AssistedSearchResponse {
        let snapshot = store
        let searchHome = home
        return await withTaskGroup(of: AssistedSearchResponse.self) { group in
            group.addTask(priority: .userInitiated) {
                AssistedSearchScanner.scan(request, store: snapshot, home: searchHome)
            }
            return await group.next() ?? AssistedSearchResponse(
                rows: [], totalMatches: 0, totalMatchesIsComplete: false,
                scannedItems: 0, inspectedSizes: 0, generation: snapshot.generation,
                cancelled: true
            )
        }
    }
}

private enum AssistedSearchScanner {
    /// Size is absent from today's compact index. Inspect a bounded candidate set and report an
    /// incomplete result instead of turning a broad size-only question into an unbounded stat walk.
    static let maximumSizeInspections = 10_000

    private struct Candidate {
        let index: Int
        let relevance: Int
        let foldedName: [UInt8]
        let modified: UInt32
    }

    static func scan(_ request: AssistedSearchRequest, store: IndexStore,
                     home: String) -> AssistedSearchResponse {
        let terms = request.nameTerms.map(TextAnalyzer.analyze)
        let needsSize = request.minimumSizeBytes != nil || request.maximumSizeBytes != nil
        var best: [Candidate] = []
        best.reserveCapacity(request.limit)
        var totalMatches = 0
        var scannedItems = 0
        var inspectedSizes = 0
        var complete = true
        var cancelled = false

        for index in 0..<store.count {
            if index & 0xFF == 0, Task.isCancelled {
                complete = false
                cancelled = true
                break
            }
            scannedItems += 1
            let kind = store.itemKind(index)
            if !request.kinds.isEmpty, !request.kinds.contains(kind) { continue }
            if !request.extensions.isEmpty {
                guard let ext = store.ext(of: index), request.extensions.contains(ext) else { continue }
            }
            let modified = store.mtime[index]
            if request.modifiedAfter != nil || request.modifiedBefore != nil {
                guard modified != 0 else { continue }
                let date = Date(timeIntervalSinceReferenceDate: TimeInterval(modified))
                if let after = request.modifiedAfter, date < after { continue }
                if let before = request.modifiedBefore, date > before { continue }
            }
            guard let relevance = relevance(of: index, terms: terms, store: store) else { continue }

            if needsSize {
                guard inspectedSizes < maximumSizeInspections else {
                    complete = false
                    break
                }
                inspectedSizes += 1
                guard !store.itemFlags(index).contains(.symlink), kind != .folder,
                      let size = fileSize(atPath: store.path(of: index)) else { continue }
                if let minimum = request.minimumSizeBytes, size < minimum { continue }
                if let maximum = request.maximumSizeBytes, size > maximum { continue }
            }

            totalMatches += 1
            let candidate = Candidate(index: index, relevance: relevance,
                                      foldedName: Array(store.foldedName(of: index)),
                                      modified: modified)
            insert(candidate, into: &best, request: request)
        }

        let rows = best.map { candidate in
            makeRow(candidate, terms: terms, store: store, home: home)
        }
        return AssistedSearchResponse(rows: rows, totalMatches: totalMatches,
                                      totalMatchesIsComplete: complete, scannedItems: scannedItems,
                                      inspectedSizes: inspectedSizes, generation: store.generation,
                                      cancelled: cancelled)
    }

    private static func relevance(of index: Int, terms: [SearchString],
                                  store: IndexStore) -> Int? {
        guard !terms.isEmpty else { return 0 }
        let primary = store.foldedName(of: index)
        let aliases = store.itemKind(index) == .app
            ? (store.appInfo[Int32(index)]?.aliases ?? []) : []
        var total = 0
        for term in terms {
            var quality = matchQuality(query: term.folded[...], text: primary)
            for alias in aliases {
                if let aliasQuality = matchQuality(query: term.folded[...], text: alias.folded[...]),
                   quality == nil || aliasQuality > quality! {
                    quality = aliasQuality
                }
            }
            guard let quality else { return nil }
            total += quality
        }
        return total
    }

    private static func matchQuality(query: ArraySlice<UInt8>,
                                     text: ArraySlice<UInt8>) -> Int? {
        if query.elementsEqual(text) { return 4_000 - text.count }
        if text.starts(with: query) { return 3_000 - text.count }
        if let start = Scorer.substringStart(query: query, text: text) {
            return 2_000 - min(start, 500) - text.count
        }
        if let start = Scorer.subsequenceStart(query: query, text: text) {
            return 1_000 - min(start, 500) - text.count
        }
        return nil
    }

    private static func insert(_ candidate: Candidate, into best: inout [Candidate],
                               request: AssistedSearchRequest) {
        let insertion = best.firstIndex { better(candidate, than: $0, sort: request.sort) }
            ?? best.endIndex
        if insertion < request.limit {
            best.insert(candidate, at: insertion)
            if best.count > request.limit { best.removeLast() }
        } else if best.count < request.limit {
            best.append(candidate)
        }
    }

    private static func better(_ lhs: Candidate, than rhs: Candidate,
                               sort: AssistedSearchSort) -> Bool {
        switch sort {
        case .relevance:
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        case .modifiedDescending:
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        case .nameAscending:
            if lhs.foldedName != rhs.foldedName {
                return lhs.foldedName.lexicographicallyPrecedes(rhs.foldedName)
            }
        }
        return lhs.index < rhs.index
    }

    private static func makeRow(_ candidate: Candidate, terms: [SearchString],
                                store: IndexStore, home: String) -> ResultRow {
        let index = candidate.index
        let storedName = store.name(of: index)
        let displayName = store.itemKind(index) == .app
            ? (store.appInfo[Int32(index)]?.displayName ?? storedName) : storedName
        let analyzed = displayName == storedName ? nil : TextAnalyzer.analyze(displayName)
        let folded = analyzed?.folded[...] ?? store.foldedName(of: index)
        let bonus = analyzed?.bonus[...] ?? store.bonus(of: index)
        let offsets = Set(terms.flatMap {
            Scorer.matchPositions(query: $0.folded[...], text: folded, bonus: bonus)
        }).sorted()
        let kind = store.itemKind(index)
        return ResultRow(itemIndex: index, name: displayName, path: store.path(of: index),
                         parentDisplay: store.parentDisplayPath(of: index, home: home),
                         kind: kind, matchedByteOffsets: offsets, score: candidate.relevance,
                         tier: kind == .app ? 1 : 2)
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }
}
