import Darwin
import Foundation
import JBarCore

public struct CLIIndexSettings: Sendable {
    public let roots: [CrawlRoot]
    public let exclusions: Exclusions
    public let maxItems: Int
    public let headerHash: UInt64
    public let snapshotURL: URL
    public let home: String
    public let maxAge: TimeInterval
    public let allowStale: Bool
    let ownsCacheDirectory: Bool

    public init(options: CLIOptions, home: String = NSHomeDirectory(),
                workingDirectory: String = FileManager.default.currentDirectoryPath) throws {
        self.home = home
        var config: Config = .default
        let configURL = try options.configPath.map { try Self.pathURL($0, home: home, workingDirectory: workingDirectory) }
        switch Config.loadReadOnly(from: configURL ?? Config.defaultURL()) {
        case .loaded(let loaded): config = loaded
        case .missing:
            if configURL != nil { throw CLIError("Config file does not exist: \(configURL!.path)", code: 1) }
        case .invalid(let message): throw CLIError(message, code: 1)
        }
        if let limit = options.maxItems { config.maxIndexedItems = limit }
        if let depth = options.maxDepth { config.maxDepth = depth }
        if options.includeHidden { config.includeHidden = true }
        try config.validate()
        exclusions = config.exclusions(home: home)
        maxItems = config.maxIndexedItems
        let supplied = options.roots.isEmpty ? config.fileRoots : options.roots
        var candidates: [CrawlRoot] = []
        var discoveredHomeRoots: [CrawlRoot]?
        for path in supplied {
            if path == "~" {
                // The GUI's curated home policy avoids Library, Applications, Public and hidden roots.
                if discoveredHomeRoots == nil {
                    let outcome = Crawler.defaultRootsOutcome(home: home, exclusions: exclusions)
                    guard outcome.isComplete else {
                        throw CLIError("Default home-root discovery is incomplete (truncated=\(outcome.truncated), denied=\(outcome.deniedPaths.count), unsafe=\(outcome.skippedUnsafe)). Select explicit --root paths instead.", code: 4)
                    }
                    discoveredHomeRoots = outcome.roots
                }
                candidates.append(contentsOf: discoveredHomeRoots ?? [])
            } else {
                candidates.append(CrawlRoot(path: try Self.pathURL(path, home: home, workingDirectory: workingDirectory).path))
            }
        }
        var seenPaths = Set<String>()
        let unique = candidates.filter { seenPaths.insert($0.path).inserted }
        guard !unique.isEmpty, unique.count <= SafetyLimits.maxRootEntries else {
            throw CLIError("Select 1...\(SafetyLimits.maxRootEntries) file roots with --root or config.fileRoots.")
        }
        // A depth bound is relative to each explicit root. Dropping an overlapping nested root
        // would lose its independent coverage while claiming a complete parent-only generation.
        // Until the core supports union scopes without duplicated items, reject that ambiguity.
        for candidate in unique {
            if let parent = unique.first(where: {
                $0.path != candidate.path && Self.contains(candidate.path, under: $0.path)
            }) {
                throw CLIError("Overlapping roots are not supported: \(parent.path) contains \(candidate.path). Index scopes separately, or choose one parent root with sufficient --max-depth.")
            }
        }
        roots = unique
        var hasher = FNV1a()
        // v2 requires the tightened unsafe/unavailable-root coverage and scope validation policy;
        // older development caches do not retain enough diagnostics to prove that policy.
        hasher.update("jbar.cli.filename-index.v2")
        hasher.update(Snapshot.headerHash(exclusions: exclusions, fileRoots: roots.map(\.path), appRoots: [], maxItems: maxItems))
        headerHash = hasher.value
        let defaultCache = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Caches/com.linji.jbar.cli", isDirectory: true)
        let cache = try options.cacheDirectory.map { try Self.pathURL($0, home: home, workingDirectory: workingDirectory) } ?? defaultCache
        ownsCacheDirectory = cache.standardizedFileURL == defaultCache.standardizedFileURL
        snapshotURL = cache.appendingPathComponent("index-\(String(headerHash, radix: 16)).bin")
        maxAge = options.maxAge
        allowStale = options.allowStale
    }

    static func pathURL(_ path: String, home: String, workingDirectory: String) throws -> URL {
        guard !path.isEmpty, SafetyLimits.utf8Fits(path, maxBytes: SafetyLimits.maxPathUTF8Bytes),
              !SafetyLimits.containsNULByte(path),
              path.utf8.first != 0x7E || path == "~" || SafetyLimits.hasTildeSlashPrefix(path) else {
            throw CLIError("Invalid path; use an absolute path, a relative path, or ~/path.")
        }
        let expanded = Config.expandTilde(path, home: home)
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL
        guard SafetyLimits.isSafeAbsolutePath(url.path) else { throw CLIError("Invalid absolute path.") }
        return url
    }

    static func contains(_ path: String, under root: String) -> Bool {
        SafetyLimits.isPath(path, within: root)
    }
}

public struct CLIIndexMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let itemCount: Int
    public let generation: UInt64
    public let builtAt: TimeInterval
    public let ageSeconds: TimeInterval
    public let stale: Bool
    /// Coverage within the selected roots, exclusions, depth, hidden-file and package policy.
    public let complete: Bool
    public let freshness: String
    public let watching: Bool
    public let roots: [String]
    public let snapshotPath: String
    public let maximumDepth: Int
    public let maximumItems: Int
    public let includeHidden: Bool
    public let excludedNames: [String]
    public let excludedPaths: [String]
    public let contentIndexed: Bool
    public let applicationAliasesIndexed: Bool
    public let directoryCount: Int
    public let crawlSeconds: TimeInterval?
    public let deniedPaths: [String]
    public let unavailableRoots: [String]
    public let cappedDirectories: [String]
    public let unsafeEntriesSkipped: Int
    public let hitItemCap: Bool
    public let persisted: Bool
}

/// A one-shot CLI never starts watchers. An immutable snapshot is reused until explicitly indexed.
public struct CLIIndex: Sendable {
    public let settings: CLIIndexSettings
    public let store: IndexStore
    public let complete: Bool
    public let stats: CrawlStats?
    public let unavailableRoots: [String]
    public let persisted: Bool
    public let startupSeconds: TimeInterval

    public static func build(settings: CLIIndexSettings) throws -> CLIIndex {
        let start = DispatchTime.now().uptimeNanoseconds
        let builder = IndexBuilder()
        let stats = Crawler(roots: settings.roots, exclusions: settings.exclusions,
                            maxItems: settings.maxItems, indexAppBundlesAsApps: true).crawl(into: builder)
        let generation = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let store = builder.build(generation: generation)
        var representedRoots = Set<String>()
        for item in store.depth.indices where store.depth[item] == 0 && store.itemKind(item) == .folder {
            representedRoots.insert(store.path(of: item))
        }
        if settings.roots.contains(where: { $0.path == "/" }),
           store.dirs.indices.contains(where: { store.dirs[$0].parent < 0 && store.dirPath(Int32($0)) == "/" }) {
            representedRoots.insert("/")
        }
        // Crawler treats ENOENT as a normally vanished entry. For explicit CLI scopes, an absent
        // selected root must be reported rather than persisted as an authoritative empty index.
        let unavailable = settings.roots.map(\.path).filter {
            !representedRoots.contains($0) || stats.unavailableRoots.contains($0)
        }
        let complete = try persistCompleteSnapshot(store, settings: settings, stats: stats, unavailableRoots: unavailable)
        return CLIIndex(settings: settings, store: store, complete: complete, stats: stats, unavailableRoots: unavailable,
                        persisted: complete, startupSeconds: Self.elapsed(since: start))
    }

    public static func load(settings: CLIIndexSettings, permitStale: Bool = false, now: Date = Date()) throws -> CLIIndex {
        let start = DispatchTime.now().uptimeNanoseconds
        let loaded = try withValidatedCacheDirectory(settings: settings, create: false) { descriptor in
            Snapshot.read(from: settings.snapshotURL, parentDirectoryDescriptor: descriptor,
                          expectedHeaderHash: settings.headerHash, maxItems: settings.maxItems,
                          rootAllowance: settings.roots.count)
        }
        guard let store = loaded else {
            throw CLIError("No valid index for these settings. Run jbar-cli index with the same scope/config/cache options.", code: 3)
        }
        // A matching cache identity is not an authenticity proof. In particular, a shared custom
        // cache can contain a validly encoded store for another tree with a copied header hash.
        guard validatesScope(store, settings: settings) else {
            throw CLIError("Index contains paths or depth outside the selected scope. Run jbar-cli index.", code: 3)
        }
        let age = now.timeIntervalSince(store.builtAt)
        guard store.builtAt.timeIntervalSince1970 > 0, age >= -300 else {
            throw CLIError("Index timestamp is invalid. Run jbar-cli index.", code: 3)
        }
        guard permitStale || settings.allowStale || age <= settings.maxAge else {
            throw CLIError("Index is older than --max-age. Run jbar-cli index or explicitly use --allow-stale.", code: 3)
        }
        return CLIIndex(settings: settings, store: store, complete: true, stats: nil, unavailableRoots: [],
                        persisted: true, startupSeconds: Self.elapsed(since: start))
    }

    public func metadata(now: Date = Date()) -> CLIIndexMetadata {
        let age = max(0, now.timeIntervalSince(store.builtAt))
        return CLIIndexMetadata(schemaVersion: 1, itemCount: store.count, generation: store.generation,
                                builtAt: store.builtAt.timeIntervalSince1970, ageSeconds: age,
                                stale: age > settings.maxAge, complete: complete,
                                freshness: "snapshot", watching: false, roots: settings.roots.map(\.path),
                                snapshotPath: settings.snapshotURL.path, maximumDepth: settings.exclusions.maxDepth,
                                maximumItems: settings.maxItems, includeHidden: settings.exclusions.includeHidden,
                                excludedNames: settings.exclusions.excludeNames.sorted(),
                                excludedPaths: settings.exclusions.excludePaths.sorted(), contentIndexed: false,
                                applicationAliasesIndexed: false, directoryCount: store.dirs.count, crawlSeconds: stats?.duration,
                                deniedPaths: stats?.deniedPaths ?? [], unavailableRoots: unavailableRoots,
                                cappedDirectories: stats?.cappedDirs ?? [],
                                unsafeEntriesSkipped: stats?.skippedUnsafe ?? 0, hitItemCap: stats?.hitItemCap ?? false,
                                persisted: persisted)
    }

    static func elapsed(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
    }

    /// An unexpected directory identity/boundary failure omitted coverage just as a permission
    /// denial does. Normal symlink leaves and package exclusions never increment skippedUnsafe.
    @discardableResult
    static func persistCompleteSnapshot(_ store: IndexStore, settings: CLIIndexSettings,
                                        stats: CrawlStats, unavailableRoots: [String]) throws -> Bool {
        guard !stats.cancelled, !stats.hitItemCap, stats.deniedPaths.isEmpty,
              stats.cappedDirs.isEmpty, stats.skippedUnsafe == 0, stats.unavailableRoots.isEmpty,
              unavailableRoots.isEmpty else { return false }
        try withValidatedCacheDirectory(settings: settings, create: true) { descriptor in
            try Snapshot.write(store, to: settings.snapshotURL, parentDirectoryDescriptor: descriptor,
                               headerHash: settings.headerHash)
        }
        return true
    }

    /// Validate containment using the already validated topological directory table. Retain two
    /// small columns rather than reconstructing every absolute path or retaining another item map.
    /// Tag zero denotes a synthetic parent of one or more selected roots; positive tags identify a
    /// selected root. Only its matching depth-zero folder items are allowed in a synthetic parent.
    private static func validatesScope(_ store: IndexStore, settings: CLIIndexSettings) -> Bool {
        var selected: [String: Int] = [:]
        var childrenByParent: [String: [String: Int]] = [:]
        for (index, root) in settings.roots.enumerated() {
            selected[root.path] = index + 1
            let url = URL(fileURLWithPath: root.path)
            if root.path != "/" {
                childrenByParent[url.deletingLastPathComponent().path, default: [:]][url.lastPathComponent] = index + 1
            }
        }
        var tags = [Int16](repeating: -1, count: store.dirs.count)
        var depths = [UInt8](repeating: 0, count: store.dirs.count)
        var syntheticChildren: [Int: [String: Int]] = [:]
        var represented = Set<Int>()
        for (index, entry) in store.dirs.enumerated() {
            if entry.parent < 0 {
                let start = Int(entry.nameStart), length = Int(entry.nameLen)
                let path = String(decoding: store.dirArena[start..<(start + length)], as: UTF8.self)
                if let tag = selected[path] {
                    tags[index] = Int16(tag)
                    represented.insert(tag)
                } else if let children = childrenByParent[path] {
                    tags[index] = 0
                    syntheticChildren[index] = children
                } else { return false }
            } else {
                let parent = Int(entry.parent)
                let parentTag = tags[parent]
                if parentTag == 0 {
                    let start = Int(entry.nameStart), length = Int(entry.nameLen)
                    let name = String(decoding: store.dirArena[start..<(start + length)], as: UTF8.self)
                    guard let tag = syntheticChildren[parent]?[name] else { return false }
                    tags[index] = Int16(tag)
                    represented.insert(tag)
                } else {
                    guard parentTag > 0 else { return false }
                    let depth = Int(depths[parent]) + 1
                    guard depth < settings.exclusions.maxDepth else { return false }
                    tags[index] = parentTag
                    depths[index] = UInt8(depth)
                }
            }
        }
        guard represented.count == settings.roots.count else { return false }
        let maximumItemDepth = max(1, settings.exclusions.maxDepth)
        for item in store.dirId.indices {
            let directory = Int(store.dirId[item])
            if tags[directory] == 0 {
                guard store.depth[item] == 0, store.itemKind(item) == .folder,
                      !store.itemFlags(item).contains(.appBundle),
                      syntheticChildren[directory]?[store.fileName(of: item)] != nil else { return false }
            } else {
                let expectedDepth = Int(depths[directory]) + 1
                guard tags[directory] > 0, Int(store.depth[item]) == expectedDepth,
                      expectedDepth <= maximumItemDepth else { return false }
            }
        }
        return true
    }

    /// A custom shared directory is never chmodded. JBar's own CLI directory must be private and
    /// owned by this user; read-only search/status never create or repair it. Snapshot itself retains
    /// the core's bounded no-follow file reader and durable 0600 atomic writer. Keep the validated
    /// parent descriptor open throughout I/O so a renamed/replaced cache path cannot redirect it.
    static func withValidatedCacheDirectory<T>(settings: CLIIndexSettings, create: Bool,
                                               _ body: (Int32) throws -> T) throws -> T {
        let directory = settings.snapshotURL.deletingLastPathComponent()
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw CLIError("No index cache exists. Run jbar-cli index with the same options.", code: 3) }
            throw CLIError("Cache directory is unsafe or cannot be opened (errno \(errno)).", code: 1)
        }
        defer { _ = Darwin.close(fd) }
        if settings.ownsCacheDirectory {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid() else {
                throw CLIError("CLI cache directory must be owned by the current user.", code: 1)
            }
            if create {
                guard fchmod(fd, 0o700) == 0 else { throw CLIError("Could not make CLI cache directory private.", code: 1) }
            } else if info.st_mode & 0o077 != 0 {
                throw CLIError("CLI cache directory must have mode 0700. Run jbar-cli index to repair it.", code: 1)
            }
        }
        return try body(fd)
    }
}
