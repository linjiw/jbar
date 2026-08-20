import Foundation
import JBarCore
import ServiceManagement

/// Command-line modes (no NSApplication, no UI). Dispatched from `main.swift` before AppKit starts.
///
/// - `JBar --version`
/// - `JBar --unregister-login-item`          (used by scripts/uninstall.sh)
/// - `JBar --cli "<query>"`                  (headless index + search with timings; the integrator's benchmark)
/// - `JBar --bench-index`                    (headless crawl; prints stats + RSS)
/// - `JBar --help`
enum CLI {
    /// Seconds to wait for the first full crawl before searching anyway.
    static let crawlTimeout: TimeInterval = 120

    /// Returns nil when `args` selects no CLI mode (→ start the app). Otherwise runs the mode and
    /// never returns (exits the process with a status code).
    static func dispatch(_ args: [String]) -> Never? {
        guard args.count > 1 else { return nil }
        switch args[1] {
        case "--version", "-v":
            print("JBar \(Runtime.version)")
            exit(0)
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--unregister-login-item":
            exit(unregisterLoginItem())
        case "--print-hotkey":
            let cfg: Config = { if case let .loaded(c) = Config.load() { return c }; return .default }()
            print(Config.hotkeyDisplay(cfg.hotkey))
            exit(0)
        case "--cli":
            let query = args.dropFirst(2).joined(separator: " ")
            guard !query.isEmpty else {
                FileHandle.standardError.write("usage: JBar --cli \"<query>\"\n".data(using: .utf8)!)
                exit(2)
            }
            runAsync { await search(query: query) }
        case "--bench-index":
            runAsync { await benchIndex() }
        case "--benchmark":
            let iters = args.dropFirst(2).first.flatMap { Int($0) } ?? 200
            runAsync { await Benchmark.run(iterations: iters) }
        default:
            return nil
        }
    }

    static let usage = """
    JBar \(Runtime.version) — keyboard-first launcher for apps and files.
      JBar                        start the menu-bar app (normally launched via JBar.app)
      JBar --version              print the version
      JBar --cli "<query>"        headless: index, search once, print rows + timings
      JBar --bench-index          headless: index, print stats + memory
      JBar --benchmark [iters]    head-to-head: JBar engine vs Spotlight (latency, coverage)
      JBar --unregister-login-item remove the login item (used by uninstall.sh)
      JBar --print-hotkey         print the configured hotkey (e.g. ⌥Space)
    Environment: JBAR_DEMO=1 (UI with demo data), JBAR_SHOW_ON_LAUNCH=1 (show panel at launch)
    """

    // MARK: - Modes

    private static func unregisterLoginItem() -> Int32 {
        let before = LoginItem.status
        print("login item status before: \(LoginItem.describe(before))")
        guard before == .enabled || before == .requiresApproval else { return 0 }
        if let err = LoginItem.unregister() {
            print("unregister failed: \(err)")
            return 1
        }
        print("login item status after: \(LoginItem.describe(LoginItem.status))")
        return 0
    }

    /// `--cli`: Config.load → IndexCoordinator (no FSEvents) → wait for idle → search twice → print.
    private static func search(query: String) async -> Int32 {
        let cfg = loadConfig()
        let (engine, coordinator, waited, status) = await buildIndex(cfg)
        defer { coordinator.stop() }
        print(String(format: "index: %d items, %d apps, phase=%@, ready after %.2f s", status.itemCount, status.appCount, phaseName(status.phase), waited))
        for pass in 1...2 {
            let t0 = Date()
            let r = await engine.search(query, limit: cfg.maxResults, appsFirstCap: cfg.appsFirstCap)
            let wall = Date().timeIntervalSince(t0)
            print(String(format: "pass %d: %d rows (%d matches) mode=%@ engine=%.2f ms wall=%.2f ms", pass, r.rows.count, r.totalMatches,
                         modeName(r.mode), r.elapsed * 1000, wall * 1000))
            if pass == 2 {
                print("score\ttier\tkind\tname\tpath")
                for row in r.rows { print("\(row.score)\t\(row.tier)\t\(row.kind)\t\(row.name)\t\(row.path)") }
            }
        }
        return 0
    }

    /// `--bench-index`: headless crawl, print stats + RSS.
    private static func benchIndex() async -> Int32 {
        let cfg = loadConfig()
        let t0 = Date()
        let (_, coordinator, waited, status) = await buildIndex(cfg)
        defer { coordinator.stop() }
        let store = coordinator.store
        print(String(format: "crawl: %.2f s (total %.2f s)", waited, Date().timeIntervalSince(t0)))
        print("items: \(status.itemCount)  apps: \(status.appCount)  dirs: \(store.dirs.count)  generation: \(store.generation)")
        print("arena bytes: folded=\(store.foldedArena.count) display=\(store.displayArena.count) dirs=\(store.dirArena.count)")
        print("denied: \(status.deniedPaths.count)  cappedDirs: \(status.cappedDirs.count)  hitItemCap: \(status.hitItemCap)  phase: \(phaseName(status.phase))")
        if let rss = ProcessMemory.residentBytes() { print(String(format: "rss: %.1f MB", Double(rss) / 1_048_576)) }
        return 0
    }

    // MARK: - Helpers

    private static func loadConfig() -> Config {
        switch Config.load() {
        case .loaded(let c): return c
        case .created(let c): print("config created at \(Config.defaultURL().path)"); return c
        case .invalid(let msg): print("config invalid (\(msg)); using defaults"); return .default
        }
    }

    /// Public wrapper so `Benchmark` can build the same index the `--cli` path uses.
    static func buildIndexPublic(_ cfg: Config) async -> (SearchEngine, IndexCoordinator, TimeInterval, IndexStatus) {
        await buildIndex(cfg)
    }

    /// Start a coordinator without FSEvents, wait until the crawl is idle (or `crawlTimeout`), return the engine.
    private static func buildIndex(_ cfg: Config) async -> (SearchEngine, IndexCoordinator, TimeInterval, IndexStatus) {
        var opts = cfg.coordinatorOptions()
        opts.watchFileSystem = false
        let engine = SearchEngine(frecency: nil)
        let coordinator = IndexCoordinator(options: opts, callbackQueue: .main)
        let tracker = StatusTracker()
        coordinator.onStoreChanged = { store in Task { await engine.update(store: store) } }
        coordinator.onStatusChanged = { status in tracker.observe(status) }
        let t0 = Date()
        coordinator.start()
        while Date().timeIntervalSince(t0) < crawlTimeout {
            tracker.observe(coordinator.status)
            if tracker.isReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let waited = Date().timeIntervalSince(t0)
        if !tracker.isReady { print(String(format: "warning: crawl not idle after %.0f s; searching the partial index", waited)) }
        // Make sure the engine has the latest store even if the last callback is still queued.
        await engine.update(store: coordinator.store)
        return (engine, coordinator, waited, coordinator.status)
    }

    /// Remembers whether the coordinator has been busy and then gone idle (or failed).
    private final class StatusTracker {
        private(set) var sawBusy = false
        private(set) var isReady = false
        private var idleSince: Date?
        func observe(_ s: IndexStatus) {
            switch s.phase {
            case .idle:
                if sawBusy { isReady = true; return }
                // Never saw a busy phase: treat a populated store that stays idle for 2 s as ready.
                if s.itemCount > 0 {
                    if let t = idleSince { if Date().timeIntervalSince(t) > 2 { isReady = true } } else { idleSince = Date() }
                }
            case .failed:
                isReady = true
            default:
                sawBusy = true
                idleSince = nil
            }
        }
    }

    private static func phaseName(_ p: IndexStatus.Phase) -> String {
        switch p {
        case .idle: return "idle"
        case .loadingSnapshot: return "loadingSnapshot"
        case .scanningApps: return "scanningApps"
        case .crawling(let n): return "crawling(\(n))"
        case .updating: return "updating"
        case .failed(let m): return "failed(\(m))"
        }
    }

    private static func modeName(_ m: QueryMode) -> String {
        switch m {
        case .empty: return "empty"
        case .search: return "search"
        case .path(let base, let filter): return "path(\(base), \(filter))"
        case .extensionOnly(let e): return "ext(\(e))"
        }
    }

    /// Run an async body on the main run loop and exit with its status.
    private static func runAsync(_ body: @escaping () async -> Int32) -> Never {
        Task { @MainActor in
            let code = await body()
            exit(code)
        }
        RunLoop.main.run()
        exit(1)
    }
}

/// Resident memory of this process via `task_info` (MACH_TASK_BASIC_INFO).
enum ProcessMemory {
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.resident_size
    }
}
