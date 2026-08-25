import Foundation
import JBarCore
import ServiceManagement

/// Command-line modes (no NSApplication, no UI). Dispatched from `main.swift` before AppKit starts.
///
/// - `JBar --version`
/// - `JBar --unregister-login-item`          (used by scripts/uninstall.sh)
/// - `JBar --cli "<query>"`                  (headless index + search with timings; the integrator's benchmark)
/// - `JBar --bench-index`                    (real configured crawl stats; not the search benchmark)
/// - `JBar --benchmark [samples]`            (isolated search benchmark + non-equivalent Spotlight reference)
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
            // Keep this machine-readable contract stable for the packager and external launchers.
            // The richer local-build fingerprint remains visible in About, the status menu, and logs.
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
            let supplied = args.dropFirst(2).first
            guard let iters = benchmarkIterations(supplied) else {
                FileHandle.standardError.write(
                    "benchmark iterations must be an integer in 1...\(SafetyLimits.maxBenchmarkIterations)\n".data(using: .utf8)!
                )
                exit(2)
            }
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
      JBar --bench-index          real configured crawl: index stats + RSS (not search latency)
      JBar --benchmark [samples]  isolated JBar distributions; non-equivalent Spotlight reference, no speed ratio
      JBar --unregister-login-item remove the login item (used by uninstall.sh)
      JBar --print-hotkey         print the configured hotkey (e.g. ⌥Space)
    Benchmark: JBAR_BENCHMARK_FIXTURE_ITEMS=300000|500000|1000000 selects a deterministic corpus.
    Environment: JBAR_DEMO=1 (UI with demo data), JBAR_SHOW_ON_LAUNCH=1 (show panel at launch)
    """

    /// Parse the optional benchmark sample count without permitting an unbounded allocation/run.
    static func benchmarkIterations(_ value: String?) -> Int? {
        guard let value else { return 200 }
        guard let parsed = Int(value), (1...SafetyLimits.maxBenchmarkIterations).contains(parsed) else { return nil }
        return parsed
    }

    // MARK: - Modes

    struct LoginItemUnregisterResult: Equatable {
        let exitCode: Int32
        let standardOutput: [String]
        let standardError: [String]
    }

    /// Pure policy seam for `--unregister-login-item`. Callers inject status reads and the
    /// unregister operation; production uses `SMAppService.mainApp`, while tests use inert fakes.
    static func unregisterLoginItem(
        status: () -> LoginItem.State,
        unregister: () throws -> Void
    ) -> LoginItemUnregisterResult {
        let outcome = LoginItem.ensureUnregistered(
            status: status, performUnregister: unregister
        )
        var standardOutput = [
            "login item status before: \(LoginItem.describe(outcome.before))",
        ]

        switch outcome {
        case .alreadyNotRegistered:
            return LoginItemUnregisterResult(
                exitCode: 0, standardOutput: standardOutput, standardError: []
            )
        case .unregistered:
            standardOutput.append("login item status after: not registered")
            return LoginItemUnregisterResult(
                exitCode: 0, standardOutput: standardOutput, standardError: []
            )
        case .refused(let before):
            let diagnostic: String
            if before == .notFound {
                diagnostic = "unregister failed: status not found is not proof that the login item is unregistered"
            } else {
                diagnostic = "unregister failed: unsupported login item status \(LoginItem.describe(before))"
            }
            return LoginItemUnregisterResult(
                exitCode: 1,
                standardOutput: standardOutput,
                standardError: [diagnostic]
            )
        case .nonTerminal(_, let after):
            standardOutput.append("login item status after: \(LoginItem.describe(after))")
            return LoginItemUnregisterResult(
                exitCode: 1,
                standardOutput: standardOutput,
                standardError: [
                    "unregister failed: expected not registered after unregister, got \(LoginItem.describe(after))",
                ]
            )
        case .unregisteredAfterAPIError(_, let apiError):
            standardOutput.append("login item status after API error: not registered")
            return LoginItemUnregisterResult(
                exitCode: 0,
                standardOutput: standardOutput,
                standardError: [
                    "unregister warning: API returned domain=\(apiError.domain) code=\(apiError.code), but terminal status is not registered",
                ]
            )
        case .apiError(_, let apiError, let after):
            standardOutput.append(
                "login item status after API error: \(LoginItem.describe(after))"
            )
            return LoginItemUnregisterResult(
                exitCode: 1,
                standardOutput: standardOutput,
                standardError: [
                    "unregister failed: domain=\(apiError.domain) code=\(apiError.code); terminal status is \(LoginItem.describe(after))",
                ]
            )
        }
    }

    private static func unregisterLoginItem() -> Int32 {
        let service = SMAppService.mainApp
        let result = unregisterLoginItem(
            status: { LoginItem.state(for: service.status) },
            unregister: { try service.unregister() }
        )
        result.standardOutput.forEach { print($0) }
        for line in result.standardError {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
        return result.exitCode
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
        print("denied: \(status.deniedPaths.count)  unsafeSkipped: \(status.unsafeEntriesSkipped)  cappedDirs: \(status.cappedDirs.count)  hitItemCap: \(status.hitItemCap)  phase: \(phaseName(status.phase))")
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
    /// Callback and polling paths run on different executors. The lock is the complete
    /// synchronization invariant for the readiness state.
    final class StatusTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var sawBusy = false
        private var ready = false
        private var idleSince: Date?

        var isReady: Bool { lock.withLock { ready } }

        func observe(_ s: IndexStatus) {
            lock.withLock {
                switch s.phase {
                case .idle:
                    if sawBusy { ready = true; return }
                    // Never saw a busy phase: treat a populated store that stays idle for 2 s as ready.
                    if s.itemCount > 0 {
                        if let t = idleSince { if Date().timeIntervalSince(t) > 2 { ready = true } } else { idleSince = Date() }
                    }
                case .failed:
                    ready = true
                default:
                    sawBusy = true
                    idleSince = nil
                }
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
    private static func runAsync(_ body: @escaping @Sendable () async -> Int32) -> Never {
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
