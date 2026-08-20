import Foundation
import JBarCore

/// `JBAR_DEMO=1` only. Returns hard-coded rows filtered by case-insensitive substring so the panel,
/// keys, highlighting and launcher can be exercised without an index, config or TCC prompts.
/// Not used in production; kept deliberately tiny.
final class DemoSearchProvider: SearchProviding, @unchecked Sendable {
    struct Item: Sendable, Equatable {
        let name: String
        let path: String
        let kind: ItemKind
    }

    private let lock = NSLock()
    private var nextRequestId: UInt64 = 0
    private let home: String
    private let items: [Item]

    private static var defaultItems: [Item] { [
        Item(name: "Safari", path: "/Applications/Safari.app", kind: .app),
        Item(name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app", kind: .app),
        Item(name: "Xcode", path: "/Applications/Xcode.app", kind: .app),
        Item(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", kind: .app),
        Item(name: "System Settings", path: "/System/Applications/System Settings.app", kind: .app),
        Item(name: "Finder", path: "/System/Library/CoreServices/Finder.app", kind: .app),
        Item(name: "jbar", path: NSHomeDirectory() + "/jbar", kind: .folder),
        Item(name: "DESIGN.md", path: NSHomeDirectory() + "/jbar/docs/DESIGN.md", kind: .document),
        Item(name: "DIAGNOSIS.md", path: NSHomeDirectory() + "/jbar/docs/DIAGNOSIS.md", kind: .document),
        Item(name: "Package.swift", path: NSHomeDirectory() + "/jbar/Package.swift", kind: .code),
        Item(name: "Info.plist", path: NSHomeDirectory() + "/jbar/Resources/Info.plist", kind: .code),
        Item(name: "build-app.sh", path: NSHomeDirectory() + "/jbar/scripts/build-app.sh", kind: .code),
        Item(name: "README.md", path: NSHomeDirectory() + "/jbar/README.md", kind: .document),
        Item(name: "Sources", path: NSHomeDirectory() + "/jbar/Sources", kind: .folder),
    ] }

    /// The injected item list is used only by isolated UI verification. Production demo mode keeps
    /// the same deterministic rows as before, while the AppKit lifecycle smoke can point rows at its
    /// private state root and therefore never hand a real user path to a launcher implementation.
    init(items: [Item]? = nil, home: String = NSHomeDirectory()) {
        self.items = items ?? Self.defaultItems
        self.home = home
    }

    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse {
        let start = Date()
        let id = allocateRequestId()
        let q = raw.trimmingCharacters(in: .whitespaces)
        let folded = TextAnalyzer.fold(q)
        var rows: [ResultRow] = []
        for (i, it) in items.enumerated() {
            let name = TextAnalyzer.fold(it.name)
            guard folded.isEmpty || name.contains(folded) else { continue }
            let offsets = Self.byteOffsets(of: folded, in: name)
            let parent = (it.path as NSString).deletingLastPathComponent
            let disp = SafetyLimits.abbreviatingHome(parent, home: home)
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
