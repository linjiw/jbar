import Foundation
import JBarCore

/// `JBAR_DEMO=1` only. Returns hard-coded rows filtered by case-insensitive substring so the panel,
/// keys, highlighting and launcher can be exercised without an index, config or TCC prompts.
/// Not used in production; kept deliberately tiny.
final class DemoSearchProvider: SearchProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRequestId: UInt64 = 0
    private let home = NSHomeDirectory()

    private static let items: [(name: String, path: String, kind: ItemKind)] = [
        ("Safari", "/Applications/Safari.app", .app),
        ("Visual Studio Code", "/Applications/Visual Studio Code.app", .app),
        ("Xcode", "/Applications/Xcode.app", .app),
        ("Terminal", "/System/Applications/Utilities/Terminal.app", .app),
        ("System Settings", "/System/Applications/System Settings.app", .app),
        ("Finder", "/System/Library/CoreServices/Finder.app", .app),
        ("jbar", NSHomeDirectory() + "/jbar", .folder),
        ("DESIGN.md", NSHomeDirectory() + "/jbar/docs/DESIGN.md", .document),
        ("DIAGNOSIS.md", NSHomeDirectory() + "/jbar/docs/DIAGNOSIS.md", .document),
        ("Package.swift", NSHomeDirectory() + "/jbar/Package.swift", .code),
        ("Info.plist", NSHomeDirectory() + "/jbar/Resources/Info.plist", .code),
        ("build-app.sh", NSHomeDirectory() + "/jbar/scripts/build-app.sh", .code),
        ("README.md", NSHomeDirectory() + "/jbar/README.md", .document),
        ("Sources", NSHomeDirectory() + "/jbar/Sources", .folder),
    ]

    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse {
        let start = Date()
        let id = allocateRequestId()
        let q = raw.trimmingCharacters(in: .whitespaces)
        let folded = TextAnalyzer.fold(q)
        var rows: [ResultRow] = []
        for (i, it) in Self.items.enumerated() {
            let name = TextAnalyzer.fold(it.name)
            guard folded.isEmpty || name.contains(folded) else { continue }
            let offsets = Self.byteOffsets(of: folded, in: name)
            let parent = (it.path as NSString).deletingLastPathComponent
            let disp = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
            rows.append(ResultRow(itemIndex: i, name: it.name, path: it.path, parentDisplay: disp, kind: it.kind,
                                  matchedByteOffsets: offsets, score: 100 - i, tier: it.kind == .app ? 1 : 2))
        }
        let apps = rows.filter { $0.isApp }.prefix(rows.contains { !$0.isApp } ? appsFirstCap : limit)
        let files = rows.filter { !$0.isApp }
        let out = Array((Array(apps) + files).prefix(limit))
        let mode: QueryMode = q.isEmpty ? .empty : .search
        return SearchResponse(query: raw, rows: out, generation: 1, requestId: id,
                              elapsed: Date().timeIntervalSince(start), totalMatches: rows.count, mode: mode)
    }

    private func allocateRequestId() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextRequestId += 1
        return nextRequestId
    }

    /// Byte offsets (in the folded name) of the first occurrence of `needle`.
    private static func byteOffsets(of needle: String, in hay: String) -> [Int] {
        guard !needle.isEmpty, let r = hay.range(of: needle) else { return [] }
        let start = hay.utf8.distance(from: hay.utf8.startIndex, to: r.lowerBound)
        return Array(start..<(start + needle.utf8.count))
    }
}
