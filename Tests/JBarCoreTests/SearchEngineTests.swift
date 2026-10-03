import XCTest
@testable import JBarCore

/// Engine tests: golden rankings on a synthetic store, modes (empty/path/extension-only), incremental cache,
/// cancellation/request ids, row building and deterministic semantics on a 300k-item store.
final class SearchEngineTests: XCTestCase {

    // MARK: - Fixture

    /// Deterministic synthetic store: ~40 apps (with aliases), a handful of golden files and ~2,000 generated files
    /// across ~50 directories under a fake home.
    enum Fixture {
        static let home = "/Users/tester"
        /// Fixed "now" so recency boosts are deterministic.
        static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        static let day: TimeInterval = 86_400

        struct Built {
            let store: IndexStore
            /// absolute path → item index
            let index: [String: Int]
            func idx(_ path: String) -> Int { index[path] ?? -1 }
        }

        static let apps: [(name: String, aliases: [String])] = [
            ("Visual Studio Code", ["Code"]), ("Google Chrome", ["Chrome"]), ("Xcode", []), ("WeChat", ["微信", "weixin", "wei xin", "wx"]),
            ("Chromium", []), ("Safari", []), ("Terminal", []), ("iTerm", ["iTerm2"]), ("Slack", []), ("Notes", []),
            ("Calendar", []), ("Mail", []), ("Messages", []), ("Music", []), ("Photos", []), ("Preview", []),
            ("System Settings", []), ("Activity Monitor", []), ("Disk Utility", []), ("Console", []), ("Keychain Access", []),
            ("Screenshot", []), ("Font Book", []), ("Script Editor", []), ("Automator", []), ("TextEdit", []),
            ("QuickTime Player", []), ("Dictionary", []), ("Stickies", []), ("Reminders", []), ("Contacts", []),
            ("FaceTime", []), ("App Store", []), ("Books", []), ("Podcasts", []), ("TV", []), ("Weather", []), ("Stocks", []),
            ("网易云音乐", ["NeteaseMusic", "wangyiyunyinyue", "wang yi yun yin le", "wyyyy"]), ("Zoom", ["zoom.us"]),
        ]

        static let words = ["alpha", "beta", "gamma", "delta", "notes", "budget", "invoice", "photo", "screenshot", "meeting", "plan",
                            "summary", "data", "export", "backup", "draft", "final", "archive", "log", "config", "index", "readme",
                            "todo", "sketch", "design", "mock", "test", "spec", "build", "release"]
        static let exts = ["txt", "md", "pdf", "png", "jpg", "csv", "json", "swift", "py", "zip", "mov"]

        /// Tiny deterministic RNG (xorshift64*).
        struct RNG {
            var s: UInt64
            mutating func next() -> UInt64 { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return s &* 2685821657736338717 }
            mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        }

        static func build(extraFiles: Int = 2_000, seed: UInt64 = 0x9E3779B97F4A7C15, includeVSCode: Bool = true) -> Built {
            let b = IndexBuilder()
            var index: [String: Int] = [:]
            let appsRoot = b.addRoot("/Applications")
            for app in apps where includeVSCode || app.name != "Visual Studio Code" {
                let analyzed = TextAnalyzer.analyze(app.name)
                let info = AppInfo(bundleID: "test.\(app.name)", displayName: app.name, aliases: app.aliases.map { TextAnalyzer.analyze($0) })
                let i = b.addItem(dir: appsRoot, name: app.name, analyzed: analyzed, kind: .app, flags: [.appBundle],
                                  mtime: now.addingTimeInterval(-30 * day), depth: 1, ext: "app", app: info)
                index["/Applications/\(app.name).app"] = Int(i)
            }
            let root = b.addRoot(home)
            let desktop = b.addDir(parent: root, name: "Desktop")
            let documents = b.addDir(parent: root, name: "Documents")
            let downloads = b.addDir(parent: root, name: "Downloads")
            let pictures = b.addDir(parent: root, name: "Pictures")
            let projects = b.addDir(parent: root, name: "Projects")
            let web = b.addDir(parent: projects, name: "web")
            let nodeModules = b.addDir(parent: web, name: "node_modules")
            let lodash = b.addDir(parent: nodeModules, name: "lodash")
            let jbar = b.addDir(parent: root, name: "jbar")
            let srcDir = b.addDir(parent: jbar, name: "Sources")

            func file(_ dir: Int32, _ dirPath: String, _ name: String, mtime: Date?, depth: Int, flags: ItemFlags = [], kind: ItemKind? = nil) {
                let ext = TextAnalyzer.fileExtension(of: name)
                let k = kind ?? (ext.map { ItemKind.forExtension($0) } ?? .other)
                let i = b.addItem(dir: dir, name: name, analyzed: TextAnalyzer.analyze(name), kind: k, flags: flags, mtime: mtime, depth: depth, ext: ext)
                index[dirPath + "/" + name] = Int(i)
            }
            func folder(_ dir: Int32, _ dirPath: String, _ name: String, depth: Int) {
                let i = b.addItem(dir: dir, name: name, analyzed: TextAnalyzer.analyze(name), kind: .folder, flags: [], mtime: now.addingTimeInterval(-5 * day), depth: depth, ext: nil)
                index[dirPath + "/" + name] = Int(i)
            }
            // Golden files.
            file(desktop, "\(home)/Desktop", "report.pdf", mtime: now.addingTimeInterval(-3_600), depth: 2)
            file(desktop, "\(home)/Desktop", "report-old.pdf", mtime: now.addingTimeInterval(-400 * day), depth: 2)
            file(documents, "\(home)/Documents", "Report Draft.docx", mtime: now.addingTimeInterval(-100 * day), depth: 2)
            file(documents, "\(home)/Documents", "code.txt", mtime: now.addingTimeInterval(-50 * day), depth: 2)
            file(lodash, "\(home)/Projects/web/node_modules/lodash", "code.txt", mtime: now.addingTimeInterval(-50 * day), depth: 5, flags: [.junk])
            file(downloads, "\(home)/Downloads", "charts-roadmap-memo.txt", mtime: now.addingTimeInterval(-2 * day), depth: 2)
            file(pictures, "\(home)/Pictures", "holiday.jpeg", mtime: now.addingTimeInterval(-20 * day), depth: 2)
            file(documents, "\(home)/Documents", "memo.htm", mtime: now.addingTimeInterval(-20 * day), depth: 2)
            file(documents, "\(home)/Documents", "screaming-frog.txt", mtime: now.addingTimeInterval(-20 * day), depth: 2)
            file(documents, "\(home)/Documents", "screamingly.txt", mtime: now.addingTimeInterval(-20 * day), depth: 2)
            file(documents, "\(home)/Documents", ".hidden-report.pdf", mtime: now.addingTimeInterval(-1 * day), depth: 2, flags: [.hidden, .dotName])
            file(srcDir, "\(home)/jbar/Sources", "main.swift", mtime: now.addingTimeInterval(-1 * day), depth: 3)
            folder(root, home, "jbar", depth: 1)
            folder(root, home, "Desktop", depth: 1)
            folder(root, home, "Documents", depth: 1)
            folder(root, home, "Downloads", depth: 1)
            // ~50 project dirs with generated files.
            var rng = RNG(s: seed)
            var dirs: [(Int32, String, Int)] = []
            for p in 0..<40 {
                let d = b.addDir(parent: projects, name: "p\(p)")
                dirs.append((d, "\(home)/Projects/p\(p)", 3))
                if p % 4 == 0 {
                    let s = b.addDir(parent: d, name: "src")
                    dirs.append((s, "\(home)/Projects/p\(p)/src", 4))
                }
            }
            for k in 0..<extraFiles {
                let (d, dp, depth) = dirs[rng.below(dirs.count)]
                let name = "\(words[rng.below(words.count)])-\(words[rng.below(words.count)])\(k).\(exts[rng.below(exts.count)])"
                let age = TimeInterval(rng.below(400)) * day
                file(d, dp, name, mtime: now.addingTimeInterval(-age), depth: depth)
            }
            return Built(store: b.build(generation: 1), index: index)
        }

        /// Large synthetic store for perf/cancellation tests (no golden files).
        static func buildLarge(count: Int, seed: UInt64 = 42) -> IndexStore {
            let b = IndexBuilder()
            b.reserve(items: count + 64, dirs: 600)
            let appsRoot = b.addRoot("/Applications")
            for app in apps {
                let info = AppInfo(bundleID: nil, displayName: app.name, aliases: app.aliases.map { TextAnalyzer.analyze($0) })
                b.addItem(dir: appsRoot, name: app.name, analyzed: TextAnalyzer.analyze(app.name), kind: .app, flags: [.appBundle],
                          mtime: now, depth: 1, ext: "app", app: info)
            }
            let root = b.addRoot(home)
            var dirs: [Int32] = []
            for p in 0..<500 { dirs.append(b.addDir(parent: root, name: "dir\(p)")) }
            var rng = RNG(s: seed)
            let extra = ["vas", "screaming", "visual", "studio", "chrome", "network", "xray", "report", "pdf", "code", "google", "xcode"]
            let pool = words + extra
            for k in 0..<count {
                let d = dirs[rng.below(dirs.count)]
                let wc = 1 + rng.below(3)
                var name = ""
                for w in 0..<wc { name += (w == 0 ? "" : (rng.below(2) == 0 ? " " : "-")) + pool[rng.below(pool.count)] }
                if rng.below(3) == 0 { name += "\(k)" }
                name += "." + exts[rng.below(exts.count)]
                let ext = TextAnalyzer.fileExtension(of: name)
                b.addItem(dir: d, name: name, analyzed: TextAnalyzer.analyze(name), kind: ext.map { ItemKind.forExtension($0) } ?? .other,
                          flags: rng.below(10) == 0 ? [.junk] : [], mtime: now.addingTimeInterval(-TimeInterval(rng.below(500)) * day),
                          depth: 2 + rng.below(6), ext: ext)
            }
            return b.build(generation: 7)
        }
    }

    static let fixture = Fixture.build()
    static let largeStore = Fixture.buildLarge(count: 60_000)

    var fixture: Fixture.Built { Self.fixture }

    func makeEngine(frecency: FrecencyStore? = nil, store: IndexStore? = nil) async -> SearchEngine {
        let e = SearchEngine(frecency: frecency)
        await e.setHome(Fixture.home)
        await e.update(store: store ?? fixture.store)
        return e
    }

    func names(_ r: SearchResponse) -> [String] { r.rows.map(\.name) }

    func tempDir(_ tag: String) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/search-tests/fixtures", isDirectory: true)
        let dir = base.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Golden rankings (DESIGN.md §6.5)

    func testGoldenApps() async {
        let e = await makeEngine()
        let golden: [(String, String)] = [
            ("vsc", "Visual Studio Code"), ("code", "Visual Studio Code"), ("gc", "Google Chrome"), ("xc", "Xcode"),
            ("wechat", "WeChat"), ("weixin", "WeChat"), ("wx", "WeChat"), ("微信", "WeChat"), ("chrome", "Google Chrome"),
            ("wyyyy", "网易云音乐"), ("visual studio", "Visual Studio Code"), ("CODE", "Visual Studio Code"),
        ]
        for (q, expected) in golden {
            let r = await e.search(q, now: Fixture.now)
            XCTAssertEqual(r.rows.first?.name, expected, "query \(q) → \(names(r))")
            XCTAssertEqual(r.rows.first?.kind, .app, "query \(q)")
            XCTAssertFalse(r.cancelled)
            XCTAssertEqual(r.mode, .search)
        }
        let chrome = await e.search("chrome", now: Fixture.now)
        if let chromium = chrome.rows.firstIndex(where: { $0.name == "Chromium" }) {
            XCTAssertGreaterThan(chromium, 0, "Google Chrome must precede Chromium")
        }
        XCTAssertEqual(chrome.rows.first?.tier, Tier.exactApp) // alias "Chrome" equals the query
        let xc = await e.search("xc", now: Fixture.now)
        XCTAssertEqual(xc.rows.first?.tier, Tier.prefixApp)
    }

    func testLocalizedFinderNameIsDisplayedAndHighlightedWhilePathKeepsBundleName() async {
        let builder = IndexBuilder()
        let apps = builder.addRoot("/Applications")
        let displayName = "微信测试"
        let info = AppInfo(bundleID: "com.test.localized", displayName: displayName,
                           aliases: [TextAnalyzer.analyze(displayName), TextAnalyzer.analyze("weixin")])
        builder.addItem(dir: apps, name: "InternalWeChat", analyzed: TextAnalyzer.analyze("InternalWeChat"),
                        kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: "app", app: info)
        let engine = await makeEngine(store: builder.build(generation: 9))

        let localized = await engine.search("微信", limit: 8, now: Fixture.now)

        XCTAssertEqual(localized.rows.first?.name, displayName,
                       "the label must match Finder's localized display name, not the bundle directory")
        XCTAssertEqual(localized.rows.first?.path, "/Applications/InternalWeChat.app",
                       "launching must still use the real bundle path")
        let row = try? XCTUnwrap(localized.rows.first)
        XCTAssertEqual(row.map {
            TextAnalyzer.characterIndices(display: $0.name, matchedFoldedByteOffsets: $0.matchedByteOffsets)
        }, [0, 1], "highlight offsets must be mapped against the displayed localized string")

        let internalNameMatch = await engine.search("internal", limit: 8, now: Fixture.now)
        XCTAssertEqual(internalNameMatch.rows.first?.name, displayName,
                       "the filesystem name remains searchable but is not exposed as the primary label")
        XCTAssertEqual(internalNameMatch.rows.first?.matchedByteOffsets, [],
                       "a hidden alias must not create invalid highlight offsets in the display label")
    }

    func testReportPdfExtensionTerm() async {
        let e = await makeEngine()
        let r = await e.search("report pdf", now: Fixture.now)
        XCTAssertEqual(r.rows.first?.name, "report.pdf", "\(names(r))")
        XCTAssertEqual(r.rows.first?.path, "\(Fixture.home)/Desktop/report.pdf")
        let pdfRows = r.rows.indices.filter { r.rows[$0].path.hasSuffix(".pdf") }
        let nonPdf = r.rows.indices.filter { !r.rows[$0].path.hasSuffix(".pdf") }
        if let lastPdf = pdfRows.last, let firstNon = nonPdf.first {
            XCTAssertLessThan(lastPdf, firstNon, "no non-pdf above a pdf: \(names(r))")
        }
        XCTAssertTrue(r.rows.contains { $0.name == "report-old.pdf" })
        XCTAssertGreaterThanOrEqual(r.totalMatches, 3)
    }

    func testRecencyBeatsStaleAndPrefixRanking() async {
        let e = await makeEngine()
        let r = await e.search("report", now: Fixture.now)
        let n = names(r)
        XCTAssertEqual(n.first, "report.pdf", "\(n)")
        XCTAssertLessThan(n.firstIndex(of: "report.pdf")!, n.firstIndex(of: "report-old.pdf")!, "\(n)")
        XCTAssertTrue(n.contains("Report Draft.docx"))
        // Hidden dot-file ranks below the regular pdfs.
        if let hidden = n.firstIndex(of: ".hidden-report.pdf") {
            XCTAssertGreaterThan(hidden, n.firstIndex(of: "report-old.pdf")!)
        }
    }

    func testJunkBelowNonJunkOfEqualText() async {
        let e = await makeEngine()
        let r = await e.search("code.txt", now: Fixture.now)
        let paths = r.rows.map(\.path)
        let good = paths.firstIndex(of: "\(Fixture.home)/Documents/code.txt")
        let junk = paths.firstIndex(of: "\(Fixture.home)/Projects/web/node_modules/lodash/code.txt")
        XCTAssertNotNil(good); XCTAssertNotNil(junk)
        if let g = good, let j = junk { XCTAssertLessThan(g, j) }
        // Exact file name: prefixName/exactName facts → wholePrefix bonus; both rows are documents.
        XCTAssertEqual(r.rows.first?.kind, .document)
    }

    func testFolderGoldenJbar() async {
        let e = await makeEngine()
        let r = await e.search("jbar", now: Fixture.now)
        XCTAssertEqual(r.rows.first?.path, "\(Fixture.home)/jbar", "\(names(r))")
        XCTAssertEqual(r.rows.first?.kind, .folder)
        XCTAssertEqual(r.rows.first?.parentDisplay, "~")
    }

    func testTrailingSpaceRequiresSubstring() async {
        let e = await makeEngine()
        let fuzzy = await e.search("chrome", now: Fixture.now)
        XCTAssertTrue(names(fuzzy).contains("charts-roadmap-memo.txt"), "\(names(fuzzy))")
        let complete = await e.search("chrome ", now: Fixture.now)
        XCTAssertEqual(complete.rows.first?.name, "Google Chrome")
        XCTAssertFalse(names(complete).contains("charts-roadmap-memo.txt"), "\(names(complete))")
        // Alias substring also satisfies a complete term ("wx" is an alias of WeChat).
        let wx = await e.search("wx ", now: Fixture.now)
        XCTAssertEqual(wx.rows.first?.name, "WeChat")
    }

    func testMultiTermAnd() async {
        let e = await makeEngine()
        let r1 = await e.search("visual code", now: Fixture.now)
        XCTAssertEqual(r1.rows.first?.name, "Visual Studio Code")
        let r2 = await e.search("visual zzzz", now: Fixture.now)
        XCTAssertTrue(r2.rows.isEmpty); XCTAssertEqual(r2.totalMatches, 0)
        let r3 = await e.search("draft report", now: Fixture.now)   // any order
        XCTAssertEqual(r3.rows.first?.name, "Report Draft.docx", "\(names(r3))")
        let r4 = await e.search("code visual", now: Fixture.now)
        XCTAssertEqual(r4.rows.first?.name, "Visual Studio Code")
        // Offsets: union over terms, sorted, deduped (v,i,s,u,a,l = 0..5 ; c,o,d,e = 14..17).
        XCTAssertEqual(r4.rows.first?.matchedByteOffsets, [0, 1, 2, 3, 4, 5, 14, 15, 16, 17])
    }

    func testExtensionAliasTerm() async {
        let e = await makeEngine()
        let jpg = await e.search("holiday jpg", now: Fixture.now)
        XCTAssertEqual(jpg.rows.first?.name, "holiday.jpeg", "\(names(jpg))")
        let html = await e.search("memo html", now: Fixture.now)   // "html" satisfied by ext "htm" although the name has no "l"
        XCTAssertEqual(html.rows.first?.name, "memo.htm", "\(names(html))")
    }

    func testHighlightOffsets() async {
        let e = await makeEngine()
        let vsc = await e.search("vsc", now: Fixture.now)
        XCTAssertEqual(vsc.rows.first?.matchedByteOffsets, [0, 7, 14])
        let chrome = await e.search("chrome", now: Fixture.now)
        XCTAssertEqual(chrome.rows.first?.matchedByteOffsets, [7, 8, 9, 10, 11, 12])
        let wx = await e.search("wx", now: Fixture.now)   // alias-only match → no name highlights
        XCTAssertEqual(wx.rows.first?.name, "WeChat")
        XCTAssertEqual(wx.rows.first?.matchedByteOffsets, [])
        let cjk = await e.search("微信", now: Fixture.now)
        XCTAssertEqual(cjk.rows.first?.matchedByteOffsets, [])
    }

    func testWholeTokenFact() {
        let a = TextAnalyzer.analyze("screaming-frog.txt")
        XCTAssertTrue(ChunkWorker.matchesWholeToken(term: Array("screaming".utf8), name: a.folded[...], bonus: a.bonus[...]))
        let b = TextAnalyzer.analyze("screamingly.txt")
        XCTAssertFalse(ChunkWorker.matchesWholeToken(term: Array("screaming".utf8), name: b.folded[...], bonus: b.bonus[...]))
        let c = TextAnalyzer.analyze("Very Screaming Frog")
        XCTAssertTrue(ChunkWorker.matchesWholeToken(term: Array("screaming".utf8), name: c.folded[...], bonus: c.bonus[...]))
        let d = TextAnalyzer.analyze("camelScreamingCase")
        XCTAssertTrue(ChunkWorker.matchesWholeToken(term: Array("screaming".utf8), name: d.folded[...], bonus: d.bonus[...]))
        XCTAssertFalse(ChunkWorker.matchesWholeToken(term: Array("screaming".utf8), name: TextAnalyzer.analyze("x").folded[...], bonus: TextAnalyzer.analyze("x").bonus[...]))
    }

    func testWholeTokenRanksAboveSuperstring() async {
        let e = await makeEngine()
        let r = await e.search("screaming", now: Fixture.now)
        let n = names(r)
        XCTAssertEqual(n.first, "screaming-frog.txt", "\(n)")   // +20 whole token beats the shorter prefix match
    }

    // MARK: - Modes

    func testEmptyQueryRecents() async throws {
        let dir = try tempDir("recents")
        let f1 = dir.appendingPathComponent("one.txt"); try "1".write(to: f1, atomically: true, encoding: .utf8)
        let f2 = dir.appendingPathComponent("two.pdf"); try "2".write(to: f2, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("Folder", isDirectory: true); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fre = FrecencyStore(fileURL: dir.appendingPathComponent("history.json"))
        let t0 = Date()
        fre.record(open: f1.path, query: nil, at: t0)
        fre.record(open: f2.path, query: "two", at: t0)
        fre.record(open: f2.path, query: "two", at: t0)
        fre.record(open: sub.path, query: nil, at: t0)
        fre.record(open: dir.appendingPathComponent("gone.txt").path, query: "gone", at: t0)  // does not exist → pruned from rows
        let e = await makeEngine(frecency: fre)
        let r = await e.search("", now: t0)
        XCTAssertEqual(r.mode, .empty)
        XCTAssertEqual(r.rows.first?.path, f2.path)   // highest frecency
        XCTAssertEqual(r.rows.first?.kind, .document)
        XCTAssertTrue(r.rows.allSatisfy { $0.itemIndex == -1 })
        XCTAssertFalse(r.rows.contains { $0.path.hasSuffix("gone.txt") })
        XCTAssertEqual(Set(r.rows.map(\.path)), [f1.path, f2.path, sub.path])
        XCTAssertEqual(r.rows.first { $0.path == sub.path }?.kind, .folder)
        let limited = await e.search("   ", limit: 2, now: t0)
        XCTAssertEqual(limited.rows.count, 2)
        // No frecency store → no recents.
        let bare = await makeEngine()
        let none = await bare.search("", now: t0)
        XCTAssertTrue(none.rows.isEmpty)
        let zeroRecents = await bare.recents(limit: 0)
        XCTAssertTrue(zeroRecents.isEmpty)
    }

    func testFrecencyAndQueryPickReorderTopWindow() async throws {
        let dir = try tempDir("frecency")
        let fre = FrecencyStore(fileURL: dir.appendingPathComponent("history.json"))
        let oldPath = "\(Fixture.home)/Desktop/report-old.pdf"
        fre.record(open: oldPath, query: "report", at: Fixture.now.addingTimeInterval(-60))
        let e = await makeEngine(frecency: fre)
        let r = await e.search("report", now: Fixture.now)
        XCTAssertEqual(r.rows.first?.name, "report-old.pdf", "\(names(r))")
        let base = await makeEngine()
        let r0 = await base.search("report", now: Fixture.now)
        let boosted = r.rows.first { $0.path == oldPath }!.score
        let plain = r0.rows.first { $0.path == oldPath }!.score
        XCTAssertGreaterThan(boosted, plain + RankingWeights.default.queryPick)   // queryPick + frecency
    }

    func testExtensionOnlyMode() async {
        let e = await makeEngine()
        let r = await e.search(".pdf", now: Fixture.now)
        XCTAssertEqual(r.mode, .extensionOnly("pdf"))
        XCTAssertFalse(r.rows.isEmpty)
        XCTAssertTrue(r.rows.allSatisfy { $0.path.hasSuffix(".pdf") }, "\(r.rows.map(\.path))")
        XCTAssertEqual(r.rows.first?.name, "report.pdf")   // most recent
        XCTAssertTrue(r.rows.allSatisfy { $0.matchedByteOffsets.isEmpty })
        XCTAssertGreaterThanOrEqual(r.totalMatches, r.rows.count)
        let apps = await e.search(".app", now: Fixture.now)
        XCTAssertTrue(apps.rows.allSatisfy { $0.kind == .app })
        let jpeg = await e.search(".jpg", now: Fixture.now)   // alias jpg ~ jpeg
        XCTAssertTrue(jpeg.rows.contains { $0.name == "holiday.jpeg" })
        let none = await e.search(".zzz", now: Fixture.now)
        XCTAssertTrue(none.rows.isEmpty); XCTAssertEqual(none.totalMatches, 0)
    }

    func testPathModeListing() async throws {
        let dir = try tempDir("pathmode")
        let fm = FileManager.default
        for d in ["Zeta", "alpha", "Beta", ".hiddenDir", ".\u{0301}decoratedHidden"] {
            try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for f in ["b.txt", "a.pdf", "Archive.zip", ".secret", "Demo.app"] {
            if f.hasSuffix(".app") { try fm.createDirectory(at: dir.appendingPathComponent(f), withIntermediateDirectories: true) }
            else { try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        }
        let e = await makeEngine()
        let all = await e.search(dir.path + "/", now: Fixture.now)
        XCTAssertEqual(all.mode, .path(base: dir.path, filter: ""))
        XCTAssertEqual(names(all), ["alpha", "Beta", "Zeta", "a.pdf", "Archive.zip", "b.txt", "Demo"], "\(names(all))")
        XCTAssertEqual(all.totalMatches, 7)
        XCTAssertEqual(all.rows.first?.kind, .folder)
        XCTAssertEqual(all.rows.last?.kind, .app)
        XCTAssertEqual(all.rows.last?.path, dir.appendingPathComponent("Demo.app").path)
        XCTAssertTrue(all.rows.allSatisfy { $0.itemIndex == -1 && $0.matchedByteOffsets.isEmpty })
        // Hidden only when the filter starts with ".".
        let hidden = await e.search(dir.path + "/.", now: Fixture.now)
        XCTAssertEqual(Set(names(hidden)), Set([".hiddenDir", ".secret", ".\u{0301}decoratedHidden"]))
        // Prefix filter (case-insensitive) with highlight of the prefix.
        let pre = await e.search(dir.path + "/a", now: Fixture.now)
        XCTAssertEqual(names(pre).prefix(2), ["alpha", "a.pdf"], "\(names(pre))")   // prefix group: folder first, then file
        XCTAssertEqual(pre.rows.first?.matchedByteOffsets, [0])
        XCTAssertTrue(names(pre).contains("Archive.zip"))
        // Fuzzy filter: "bt" → b.txt and Beta (subsequence), not alpha.
        let fuzzy = await e.search(dir.path + "/bt", now: Fixture.now)
        XCTAssertEqual(Set(names(fuzzy)), ["b.txt", "Beta"])
        XCTAssertFalse(fuzzy.rows.first!.matchedByteOffsets.isEmpty)
        // Missing directory → empty.
        let missing = await e.search(dir.path + "/nope/", now: Fixture.now)
        XCTAssertTrue(missing.rows.isEmpty); XCTAssertEqual(missing.totalMatches, 0)
        // Cap at limit × multiplier.
        let capped = await e.search(dir.path + "/", limit: 1, now: Fixture.now)
        XCTAssertEqual(capped.rows.count, min(7, SearchEngine.pathModeRowMultiplier))
        XCTAssertEqual(capped.totalMatches, 7)
    }

    func testPathModeHomeExpansion() async throws {
        let dir = try tempDir("home")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let e = SearchEngine()
        await e.setHome(dir.path)
        let r = await e.search("~/Desk", now: Fixture.now)
        XCTAssertEqual(names(r), ["Desktop"])
        XCTAssertEqual(r.rows.first?.parentDisplay, "~")
        XCTAssertEqual(r.rows.first?.path, dir.appendingPathComponent("Desktop").path)
    }

    func testSetHomeRejectsOversizedAndUnsafePublicValues() async {
        let engine = SearchEngine()
        let fallback = QueryParser.normalizedHome(NSHomeDirectory())
        let hostileHomes = [String(repeating: "h", count: 1_000_000),
                            "relative", "/a/../b", "/bad\0\u{301}home"]
        for hostile in hostileHomes {
            await engine.setHome(hostile)
            let stored = await engine.home
            XCTAssertEqual(stored, fallback)
            XCTAssertTrue(SafetyLimits.isSafeAbsolutePath(stored))
        }
    }

    func testExtremePublicLimitsNeverOverflowOrAllocateUnboundedCapacity() async throws {
        let e = await makeEngine()
        let negative = await e.search("report", limit: Int.min, appsFirstCap: Int.max, now: Fixture.now)
        XCTAssertTrue(negative.rows.isEmpty)
        XCTAssertFalse(negative.totalMatchesIsComplete,
                       "a zero-row request must return before scanning, not claim an exact zero")

        let positive = await e.search("a", limit: Int.max, appsFirstCap: Int.max, now: Fixture.now)
        XCTAssertLessThanOrEqual(positive.rows.count, SafetyLimits.maxResults.upperBound)

        let dir = try tempDir("extreme-limit-path")
        try "x".write(to: dir.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        let path = await e.search(dir.path + "/", limit: Int.max, appsFirstCap: Int.min, now: Fixture.now)
        XCTAssertEqual(path.rows.map(\.name), ["one.txt"])
        XCTAssertEqual(path.totalMatches, 1)

        let emptyPath = await e.search(dir.path + "/", limit: Int.min, now: Fixture.now)
        XCTAssertTrue(emptyPath.rows.isEmpty)
        XCTAssertFalse(emptyPath.totalMatchesIsComplete)

        let hugeQuery = String(repeating: "a", count: SafetyLimits.maxQueryCharacters + 100_000)
        let bounded = await e.search(hugeQuery, limit: 8, now: Fixture.now)
        XCTAssertEqual(bounded.query.count, SafetyLimits.maxQueryCharacters)
    }

    func testRowForPath() throws {
        let dir = try tempDir("rows")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let app = SearchEngine.row(forPath: dir.appendingPathComponent("Thing.app").path, home: dir.path)
        XCTAssertEqual(app.kind, .app); XCTAssertEqual(app.name, "Thing"); XCTAssertEqual(app.parentDisplay, "~"); XCTAssertTrue(app.isApp)
        let folder = SearchEngine.row(forPath: dir.appendingPathComponent("Folder").path + "/", home: dir.path)
        XCTAssertEqual(folder.kind, .folder); XCTAssertEqual(folder.name, "Folder")
        XCTAssertFalse(folder.path.hasSuffix("/"))
        let md = SearchEngine.row(forPath: dir.appendingPathComponent("notes.md").path, home: "/nonexistent-home")
        XCTAssertEqual(md.kind, .document); XCTAssertEqual(md.parentDisplay, dir.path); XCTAssertEqual(md.itemIndex, -1)
        let missing = SearchEngine.row(forPath: dir.appendingPathComponent("ghost.png").path, home: dir.path)
        XCTAssertEqual(missing.kind, .image)   // inferred from extension even when absent
        let noExt = SearchEngine.row(forPath: "/usr/bin/true", home: dir.path)
        XCTAssertEqual(noExt.kind, .other); XCTAssertEqual(noExt.parentDisplay, "/usr/bin")
        let root = SearchEngine.row(forPath: "/", home: dir.path)
        XCTAssertEqual(root.kind, .folder); XCTAssertEqual(root.path, "/")
        XCTAssertEqual(SearchEngine.abbreviate(dir.path + "/Sub", home: dir.path), "~/Sub")
        XCTAssertEqual(SearchEngine.abbreviate(dir.path + "x", home: dir.path), dir.path + "x")
        XCTAssertEqual(SearchEngine.abbreviate("/\u{301}目录", home: "/"), "~/\u{301}目录")
        XCTAssertEqual(SearchEngine.abbreviate("/Users/Cafe\u{301}/文件", home: "/Users/Café"), "~/文件")
    }

    // MARK: - Incremental cache, request ids, cancellation, store swaps

    func rowKeys(_ r: SearchResponse) -> [String] { r.rows.map { "\($0.path)|\($0.score)|\($0.tier)|\($0.matchedByteOffsets)" } }

    func testIncrementalCacheMatchesFreshScan() async {
        let e = await makeEngine()
        let fresh = await makeEngine()
        let sequences: [[String]] = [
            ["v", "vs", "vsc"],
            ["r", "re", "rep", "report", "report ", "report p", "report pd", "report pdf", "report pdf "],
            ["c", "ch", "chr", "chrome", "chrome ", "chrome c"],
            ["m", "me", "memo", "memo h", "memo ht", "memo htm", "memo html"],
            ["vsc", "vs", "v"],            // deletions → cache-cold accelerated scans
            ["holiday j", "holiday jp", "holiday jpg", "holiday jpgx"],
        ]
        for seq in sequences {
            for q in seq {
                let inc = await e.search(q, now: Fixture.now)
                let ref = await fresh.search(q, now: Fixture.now)   // also incremental? no: alternate engine gets the same sequence…
                // `fresh` sees the same sequence, so compare against a brand-new engine too.
                let brandNew = await makeEngine()
                let cold = await brandNew.search(q, now: Fixture.now)
                XCTAssertEqual(rowKeys(inc), rowKeys(cold), "query \(q) in \(seq)")
                XCTAssertEqual(rowKeys(ref), rowKeys(cold), "query \(q) in \(seq)")
                XCTAssertEqual(inc.totalMatches, cold.totalMatches, "query \(q) in \(seq)")
            }
        }
    }

    func testRequestIdsMonotonicAndResponseMetadata() async {
        let e = await makeEngine()
        var last: UInt64 = 0
        for q in ["a", "", "~/", ".pdf", "vsc", "b c d"] {
            let r = await e.search(q, now: Fixture.now)
            XCTAssertGreaterThan(r.requestId, last)
            last = r.requestId
            let latest = await e.latestRequestId
            XCTAssertEqual(latest, last)
            XCTAssertEqual(r.generation, fixture.store.generation)
            XCTAssertEqual(r.query, q)
            XCTAssertGreaterThanOrEqual(r.elapsed, 0)
        }
    }

    func testUpdateStoreClearsCacheAndGeneration() async {
        let e = await makeEngine()
        let r1 = await e.search("vs", now: Fixture.now)
        XCTAssertEqual(r1.rows.first?.name, "Visual Studio Code")
        let without = Fixture.build(extraFiles: 50, includeVSCode: false)
        await e.update(store: without.store)
        let r2 = await e.search("vsc", now: Fixture.now)   // would hit the cache if it were not cleared
        XCTAssertFalse(names(r2).contains("Visual Studio Code"))
        XCTAssertEqual(r2.generation, without.store.generation)
        await e.update(store: fixture.store)
        let r3 = await e.search("vsc", now: Fixture.now)
        XCTAssertEqual(r3.rows.first?.name, "Visual Studio Code")
        // Empty store: nothing matches, nothing crashes.
        let empty = SearchEngine()
        let r4 = await empty.search("anything", now: Fixture.now)
        XCTAssertTrue(r4.rows.isEmpty); XCTAssertEqual(r4.totalMatches, 0)
        let r5 = await empty.search(".pdf", now: Fixture.now)
        XCTAssertTrue(r5.rows.isEmpty)
    }

    func testConcurrentRequestsOnlyLatestSurvives() async {
        let e = await makeEngine(store: Self.largeStore)
        // Fire many searches without awaiting in between; the actor is re-entrant so the later requests bump the
        // counter while earlier scans are still running. The last one must complete; earlier ones either complete
        // or are marked cancelled (never half results).
        let queries = ["x", "xr", "xra", "xray", "xray r", "xray re", "xray rep", "xray repo", "xray repor", "xray report"]
        var responses: [SearchResponse] = []
        await withTaskGroup(of: SearchResponse.self) { group in
            for q in queries { group.addTask { await e.search(q, now: Fixture.now) } }
            for await r in group { responses.append(r) }
        }
        let maxId = responses.map(\.requestId).max()!
        let latest = responses.first { $0.requestId == maxId }!
        XCTAssertFalse(latest.cancelled)
        XCTAssertFalse(latest.rows.isEmpty)
        for r in responses where r.cancelled { XCTAssertTrue(r.rows.isEmpty); XCTAssertEqual(r.totalMatches, 0) }
        XCTAssertEqual(Set(responses.map(\.requestId)).count, queries.count)
        // A cancelled scan must not poison the cache: the next query equals a cold scan.
        let after = await e.search("xray report", now: Fixture.now)
        let cold = await makeEngine(store: Self.largeStore)
        let ref = await cold.search("xray report", now: Fixture.now)
        XCTAssertEqual(rowKeys(after), rowKeys(ref))
        XCTAssertEqual(after.totalMatches, ref.totalMatches)
    }

    func testParallelScanEqualsSerialScan() async {
        // The common 'e' posting still exceeds the parallel threshold; extending "eee" to "eeee"
        // reuses a much smaller matched set and therefore takes the serial path.
        let e = await makeEngine(store: Self.largeStore)
        let coldCandidates = try! XCTUnwrap(
            Self.largeStore.rarestMaskBitset(requiredMask: Mask.of(Array("eeee".utf8)))
        )
        XCTAssertGreaterThan(coldCandidates.candidateCount, SearchEngine.parallelThreshold)
        let parallelWork = SearchScanWorkObserver()
        await e.setScanWorkObserver(parallelWork)
        let parallel = await e.search("eeee", now: Fixture.now)
        let parallelSnapshot = parallelWork.snapshot
        XCTAssertEqual(parallelSnapshot.chunkScansStarted,
                       SearchEngine.chunkRanges(candidates: .bitset(
                        words: coldCandidates.words, upperBound: Self.largeStore.count,
                        candidateCount: coldCandidates.candidateCount
                       )).count)
        XCTAssertEqual(parallelSnapshot.visitedCandidates, coldCandidates.candidateCount)
        let cold = await makeEngine(store: Self.largeStore)
        _ = await cold.search("eee", now: Fixture.now)
        let serialWork = SearchScanWorkObserver()
        await cold.setScanWorkObserver(serialWork)
        let serial = await cold.search("eeee", now: Fixture.now)
        let serialSnapshot = serialWork.snapshot
        XCTAssertEqual(serialSnapshot.chunkScansStarted, 1,
                       "a small incremental candidate set must run as one chunk")
        XCTAssertGreaterThan(serialSnapshot.visitedCandidates, 0)
        XCTAssertLessThanOrEqual(serialSnapshot.visitedCandidates, SearchEngine.parallelThreshold)
        XCTAssertEqual(rowKeys(parallel), rowKeys(serial))
        XCTAssertEqual(parallel.totalMatches, serial.totalMatches)
        XCTAssertGreaterThan(parallel.totalMatches, 0)
        // Small counts stay one chunk; larger counts split into a contiguous partition of [0, count).
        XCTAssertEqual(SearchEngine.chunkRanges(count: 10).count, 1)
        XCTAssertEqual(SearchEngine.chunkRanges(count: SearchEngine.parallelThreshold).count, 1)
        for count in [SearchEngine.parallelThreshold + 1, 60_000, 100_000, 182_000] {
            let ranges = SearchEngine.chunkRanges(count: count)
            XCTAssertGreaterThan(ranges.count, 1, "count \(count) should be chunked")
            XCTAssertEqual(ranges.first?.lowerBound, 0)
            XCTAssertEqual(ranges.last?.upperBound, count)
            // Contiguous, non-overlapping, exhaustive.
            for i in 1..<ranges.count { XCTAssertEqual(ranges[i].lowerBound, ranges[i-1].upperBound) }
            XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, count)
        }
    }

    func testStaleChunkReturnsBeforeFirstCandidateAndNextWorkMatchesFresh() {
        let store = Self.largeStore
        let parsed = QueryParser.parse("vas screaming", home: Fixture.home)
        let terms = parsed.terms.map {
            PreparedTerm(folded: $0.folded, mask: $0.mask, extIds: [])
        }
        func context(counter: RequestCounter, requestId: UInt64,
                     observer: SearchScanWorkObserver? = nil) -> ScanContext {
            ScanContext(store: store, parsed: parsed, terms: terms, weights: .default,
                        frecency: nil, now: Fixture.now, limit: 8, appsFirstCap: 5,
                        home: Fixture.home, requestId: requestId, counter: counter,
                        candidates: .all(store.count), workObserver: observer)
        }

        let sharedCounter = RequestCounter()
        let staleRequestId = sharedCounter.next()
        _ = sharedCounter.next()
        let staleObserver = SearchScanWorkObserver()
        var stale = ChunkWorker(ctx: context(counter: sharedCounter, requestId: staleRequestId,
                                             observer: staleObserver))
        stale.run(range: 0..<store.count)
        XCTAssertTrue(stale.cancelled)
        XCTAssertEqual(stale.total, 0)
        XCTAssertTrue(stale.matched.isEmpty)
        XCTAssertTrue(stale.top.items.isEmpty)
        XCTAssertEqual(staleObserver.snapshot,
                       SearchScanWork(chunkScansStarted: 1, visitedCandidates: 0),
                       "a stale chunk must stop at its first cancellation poll, before candidate access")

        var live = ChunkWorker(ctx: context(counter: sharedCounter, requestId: sharedCounter.current))
        live.run(range: 0..<store.count)
        XCTAssertFalse(live.cancelled)

        let freshCounter = RequestCounter()
        let freshRequestId = freshCounter.next()
        var fresh = ChunkWorker(ctx: context(counter: freshCounter, requestId: freshRequestId))
        fresh.run(range: 0..<store.count)
        XCTAssertFalse(fresh.cancelled)
        XCTAssertEqual(live.total, fresh.total)
        XCTAssertEqual(live.matched, fresh.matched)
        XCTAssertEqual(live.top.items.map(\.item), fresh.top.items.map(\.item))
        XCTAssertEqual(live.top.items.map(\.facts), fresh.top.items.map(\.facts))
        XCTAssertEqual(live.top.items.map(\.kind), fresh.top.items.map(\.kind))
    }

    func testTopKKeepsBestByRankingKey() {
        var heap = TopK(capacity: 5)
        var rng = Fixture.RNG(s: 99)
        var all: [RankedItem] = []
        for i in 0..<500 {
            let item = RankedItem(itemIndex: i, tier: rng.below(3), finalScore: rng.below(100), nameLength: rng.below(30), firstMatch: rng.below(5))
            all.append(item)
            heap.insert(Scored(item: item, facts: MatchFacts(textScore: 0), kind: .other))
        }
        let expected = all.sorted(by: SearchEngine.better).prefix(5).map(\.itemIndex)
        XCTAssertEqual(Set(heap.items.map(\.item.itemIndex)), Set(expected))
        XCTAssertEqual(Ranking.order(all).prefix(5).map(\.itemIndex), expected)   // same key as Ranking.order
        var small = TopK(capacity: 0)   // clamps to 1
        small.insert(Scored(item: all[0], facts: MatchFacts(textScore: 0), kind: .other))
        XCTAssertEqual(small.items.count, 1)
    }

    func testGroupingAppsFirstCap() async {
        let e = await makeEngine()
        // "a" matches many apps and many files: ≤ 5 apps first, then files, 8 total.
        let r = await e.search("a", limit: 8, appsFirstCap: 5, now: Fixture.now)
        XCTAssertEqual(r.rows.count, 8)
        let appCount = r.rows.prefix { $0.isApp }.count
        XCTAssertEqual(appCount, 5)
        XCTAssertTrue(r.rows.dropFirst(5).allSatisfy { !$0.isApp })
        let two = await e.search("a", limit: 8, appsFirstCap: 2, now: Fixture.now)
        XCTAssertEqual(two.rows.prefix { $0.isApp }.count, 2)
        let zero = await e.search("a", limit: 0, now: Fixture.now)
        XCTAssertTrue(zero.rows.isEmpty)
        XCTAssertFalse(zero.totalMatchesIsComplete)
    }

    func testPinyinInitialsHeuristic() {
        let wechat = AppInfo(bundleID: nil, displayName: "WeChat", aliases: ["微信", "weixin", "wx"].map { TextAnalyzer.analyze($0) })
        let nameF = TextAnalyzer.analyze("WeChat").folded[...]
        XCTAssertTrue(ChunkWorker.isPinyinInitialsExact(term: Array("wx".utf8), app: wechat, nameF: nameF, displayName: { "WeChat" }))
        XCTAssertFalse(ChunkWorker.isPinyinInitialsExact(term: Array("weixi".utf8), app: wechat, nameF: nameF, displayName: { "WeChat" }))
        let vsc = AppInfo(bundleID: nil, displayName: "Visual Studio Code", aliases: [TextAnalyzer.analyze("Code")])
        XCTAssertFalse(ChunkWorker.isPinyinInitialsExact(term: Array("code".utf8), app: vsc, nameF: TextAnalyzer.analyze("Visual Studio Code").folded[...], displayName: { "Visual Studio Code" }))
        XCTAssertTrue(ChunkWorker.containsCJK("网易云音乐")); XCTAssertFalse(ChunkWorker.containsCJK("WeChat"))
    }

    func testRequestCounter() {
        let c = RequestCounter()
        XCTAssertEqual(c.current, 0)
        XCTAssertEqual(c.next(), 1); XCTAssertEqual(c.next(), 2); XCTAssertEqual(c.current, 2)
    }

    // MARK: - Large-store semantics (performance budgets belong to the versioned benchmark gate)

    func testScale300kFullAndIncrementalSearchSemantics() async {
        let store = Fixture.buildLarge(count: 300_000)
        let e = await makeEngine(store: store)
        let fullObserver = SearchScanWorkObserver()
        await e.setScanWorkObserver(fullObserver)
        let broad = await e.search("x", now: Fixture.now)
        XCTAssertFalse(broad.cancelled)
        XCTAssertTrue(broad.totalMatchesIsComplete)
        XCTAssertGreaterThan(broad.totalMatches, broad.rows.count)
        XCTAssertLessThanOrEqual(broad.rows.count, 8)
        let xCandidates = try! XCTUnwrap(store.rarestMaskBitset(requiredMask: Mask.of(Array("x".utf8))))
        XCTAssertLessThan(xCandidates.candidateCount, store.count,
                          "a selective first character should avoid a full-store scan")
        XCTAssertEqual(fullObserver.snapshot.visitedCandidates, xCandidates.candidateCount,
                       "the initial query must scan exactly its smallest safe posting")
        XCTAssertEqual(fullObserver.snapshot.chunkScansStarted,
                       SearchEngine.chunkRanges(candidates: .bitset(
                        words: xCandidates.words, upperBound: store.count,
                        candidateCount: xCandidates.candidateCount
                       )).count)

        let incrementalObserver = SearchScanWorkObserver()
        await e.setScanWorkObserver(incrementalObserver)
        let incremental = await e.search("xr", now: Fixture.now)
        XCTAssertFalse(incremental.cancelled)
        XCTAssertTrue(incremental.totalMatchesIsComplete)
        XCTAssertEqual(incrementalObserver.snapshot.visitedCandidates, broad.totalMatches,
                       "an extended query must rescan exactly the prior query's matching candidates")

        let cold = await makeEngine(store: store)
        let reference = await cold.search("xr", now: Fixture.now)
        XCTAssertFalse(reference.cancelled)
        XCTAssertEqual(rowKeys(incremental), rowKeys(reference))
        XCTAssertEqual(incremental.totalMatches, reference.totalMatches)
        XCTAssertEqual(incremental.totalMatchesIsComplete, reference.totalMatchesIsComplete)
    }
}
