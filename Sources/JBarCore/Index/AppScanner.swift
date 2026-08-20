import Darwin
import Foundation

// Swift does not expose the non-creating `openat` form directly. Supplying the ignored mode argument
// gives this file a fixed POSIX signature, just as the crawler's descriptor walk does.
@_silgen_name("openat")
private func jbarAppOpenAt(_ directoryFD: Int32, _ path: UnsafePointer<CChar>,
                           _ flags: Int32, _ mode: mode_t) -> Int32

private struct AppFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

private struct AppDirectoryEntry: Sendable {
    let cName: [CChar]
    let name: String
    let info: stat

    var identity: AppFileIdentity { AppFileIdentity(info) }
    var isDirectory: Bool { info.st_mode & S_IFMT == S_IFDIR }
    var isSymbolicLink: Bool { info.st_mode & S_IFMT == S_IFLNK }
}

private struct AppDirectoryListing: Sendable {
    let entries: [AppDirectoryEntry]
    let exceededLimit: Bool
}

/// Test-only synchronization point. The hook runs after an entry identity is captured and before its
/// descriptor is opened, which makes rename/symlink substitution tests deterministic.
struct AppScannerTestHooks: Sendable {
    var beforeOpeningComponent: (@Sendable (String) -> Void)?

    init(beforeOpeningComponent: (@Sendable (String) -> Void)? = nil) {
        self.beforeOpeningComponent = beforeOpeningComponent
    }
}

/// One physical directory inside an already-opened bundle. Every descendant is opened relative to
/// this descriptor, refuses symlinks, and must retain the identity observed immediately beforehand.
private final class OpenAppDirectory {
    let fd: Int32
    let info: stat
    let boundary: String
    let relativePath: String

    private init(fd: Int32, info: stat, boundary: String, relativePath: String) {
        self.fd = fd
        self.info = info
        self.boundary = boundary
        self.relativePath = relativePath
    }

    deinit { _ = Darwin.close(fd) }

    static func bundle(at url: URL, hooks: AppScannerTestHooks?) -> OpenAppDirectory? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        var expected = stat()
        guard lstat(target.path, &expected) == 0,
              expected.st_mode & S_IFMT == S_IFDIR else { return nil }
        hooks?.beforeOpeningComponent?(".")
        let fd = Darwin.open(target.path,
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var actual = stat()
        guard fstat(fd, &actual) == 0,
              actual.st_mode & S_IFMT == S_IFDIR,
              AppFileIdentity(actual) == AppFileIdentity(expected),
              let path = descriptorPath(fd) else {
            _ = Darwin.close(fd)
            return nil
        }
        return OpenAppDirectory(fd: fd, info: actual,
                                boundary: normalizedBoundary(path), relativePath: "")
    }

    func child(component: String, hooks: AppScannerTestHooks?) -> OpenAppDirectory? {
        guard Self.safeComponent(component) else { return nil }
        return component.withCString { cName in
            child(cName: cName, expectedName: component, hooks: hooks)
        }
    }

    func child(entry: AppDirectoryEntry, hooks: AppScannerTestHooks?) -> OpenAppDirectory? {
        guard entry.isDirectory, !entry.isSymbolicLink else { return nil }
        return entry.cName.withUnsafeBufferPointer { cName in
            child(cName: cName.baseAddress!, expectedName: entry.name,
                  expectedIdentity: entry.identity, hooks: hooks)
        }
    }

    private func child(cName: UnsafePointer<CChar>, expectedName: String,
                       expectedIdentity suppliedIdentity: AppFileIdentity? = nil,
                       hooks: AppScannerTestHooks?) -> OpenAppDirectory? {
        guard requireInsideBoundary() else { return nil }
        var entryInfo = stat()
        guard fstatat(fd, cName, &entryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              entryInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        let expectedIdentity = suppliedIdentity ?? AppFileIdentity(entryInfo)
        guard expectedIdentity == AppFileIdentity(entryInfo) else { return nil }
        let childRelativePath = relativePath.isEmpty ? expectedName : relativePath + "/" + expectedName
        hooks?.beforeOpeningComponent?(childRelativePath)
        let childFD = jbarAppOpenAt(fd, cName,
                                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                                    mode_t(0))
        guard childFD >= 0 else { return nil }
        var actual = stat()
        guard fstat(childFD, &actual) == 0,
              actual.st_mode & S_IFMT == S_IFDIR,
              AppFileIdentity(actual) == expectedIdentity,
              let path = Self.descriptorPath(childFD),
              Self.path(path, isWithin: boundary) else {
            _ = Darwin.close(childFD)
            return nil
        }
        return OpenAppDirectory(fd: childFD, info: actual, boundary: boundary,
                                relativePath: childRelativePath)
    }

    /// Stream at most `limit + 1` physical names. Oversized directories are rejected as a unit so
    /// retained localization order cannot depend on filesystem enumeration order.
    func entries(limit: Int) -> AppDirectoryListing? {
        guard limit >= 0, requireInsideBoundary() else { return nil }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { return nil }
        guard let stream = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return nil
        }
        defer { closedir(stream) }

        var entries: [AppDirectoryEntry] = []
        entries.reserveCapacity(min(limit, 256))
        var inspected = 0
        while true {
            errno = 0
            guard let pointer = readdir(stream) else {
                guard errno == 0 else { return nil }
                break
            }
            var rawName = pointer.pointee.d_name
            let length = Int(pointer.pointee.d_namlen)
            let cName: [CChar] = withUnsafePointer(to: &rawName) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    var bytes = Array(UnsafeBufferPointer(start: $0, count: length))
                    bytes.append(0)
                    return bytes
                }
            }
            let name = String(decoding: cName.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "." || name == ".." { continue }
            inspected += 1
            guard inspected <= limit else {
                return AppDirectoryListing(entries: [], exceededLimit: true)
            }
            var entryInfo = stat()
            let status = cName.withUnsafeBufferPointer {
                fstatat(fd, $0.baseAddress, &entryInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }
            entries.append(AppDirectoryEntry(cName: cName, name: name, info: entryInfo))
        }
        guard requireInsideBoundary() else { return nil }
        entries.sort {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.cName.lexicographicallyPrecedes($1.cName)
        }
        return AppDirectoryListing(entries: entries, exceededLimit: false)
    }

    func readRegularFile(component: String, maxBytes: Int,
                         hooks: AppScannerTestHooks?) -> AppMetadataFileRead {
        guard maxBytes >= 0, Self.safeComponent(component), requireInsideBoundary() else { return .unsafe }
        return component.withCString { cName in
            var expected = stat()
            guard fstatat(fd, cName, &expected, AT_SYMLINK_NOFOLLOW) == 0 else { return .missing }
            guard expected.st_mode & S_IFMT == S_IFREG else { return .unsafe }
            let expectedIdentity = AppFileIdentity(expected)
            let relative = relativePath.isEmpty ? component : relativePath + "/" + component
            hooks?.beforeOpeningComponent?(relative)
            let fileFD = jbarAppOpenAt(fd, cName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                                       mode_t(0))
            guard fileFD >= 0 else { return .unsafe }
            defer { _ = Darwin.close(fileFD) }
            var actual = stat()
            guard fstat(fileFD, &actual) == 0,
                  actual.st_mode & S_IFMT == S_IFREG,
                  AppFileIdentity(actual) == expectedIdentity,
                  actual.st_size >= 0 else { return .unsafe }
            guard UInt64(actual.st_size) <= UInt64(maxBytes) else { return .limitExceeded }

            var data = Data()
            data.reserveCapacity(Int(actual.st_size))
            var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, max(1, maxBytes)))
            while true {
                let remaining = maxBytes - data.count
                let requested = min(buffer.count, remaining + 1)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(fileFD, $0.baseAddress, requested)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    return .unsafe
                }
                if count == 0 {
                    guard requireInsideBoundary() else { return .unsafe }
                    return .data(data)
                }
                guard count <= remaining else { return .limitExceeded }
                data.append(contentsOf: buffer[..<count])
            }
        }
    }

    private func requireInsideBoundary() -> Bool {
        guard let current = Self.descriptorPath(fd) else { return false }
        return Self.path(current, isWithin: boundary)
    }

    private static func safeComponent(_ component: String) -> Bool {
        SafetyLimits.isSafePathComponent(component,
                                         maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes)
    }

    private static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func normalizedBoundary(_ path: String) -> String {
        SafetyLimits.trimmingTrailingPathSlashes(path)
    }

    private static func path(_ candidate: String, isWithin root: String) -> Bool {
        SafetyLimits.isPath(candidate, within: root)
    }
}

private enum AppMetadataFileRead {
    case data(Data)
    case missing
    case unsafe
    case limitExceeded
}

/// One discovered application bundle.
public struct ScannedApp: Sendable, Equatable {
    public var url: URL                 // bundle URL as found under its root (symlinks kept; deduped by resolved target)
    public var displayName: String      // what Finder shows, ".app" stripped
    public var bundleID: String?
    public var aliases: [String]        // CFBundleName, CFBundleDisplayName, localized names (raw strings, deduped, != displayName)
    public var mtime: Date?
    public init(url: URL, displayName: String, bundleID: String?, aliases: [String], mtime: Date?) {
        self.url = url; self.displayName = displayName; self.bundleID = bundleID; self.aliases = aliases; self.mtime = mtime
    }

    /// The bundle's file name without the `.app` extension (e.g. `WeChat` for `/Applications/WeChat.app`).
    /// This is the item name stored in the index so that `store.path(of:) + ".app"` is always the real bundle path.
    public var fileName: String { AppScanner.stripAppExtension(url.lastPathComponent) }
}

/// Application discovery result. `truncated` is true only when a configured resource ceiling
/// prevented one or more candidates from being considered; ordinary missing/unreadable roots retain
/// the long-standing best-effort behavior.
public struct AppScanOutcome: Sendable, Equatable {
    public var apps: [ScannedApp]
    public var truncated: Bool

    public init(apps: [ScannedApp], truncated: Bool) {
        self.apps = apps
        self.truncated = truncated
    }
}

/// Finds every launchable .app bundle. DESIGN.md §4.1. Owner: indexer agent.
///
/// Roots (default): /Applications (+/Utilities if present), /System/Applications, /System/Applications/Utilities,
/// ~/Applications (incl. `Chrome Apps.localized`), /System/Library/CoreServices/Applications,
/// /System/Library/CoreServices/Finder.app, /Applications/Xcode.app/Contents/Applications.
/// Depth ≤ 2 under each root (so /Applications/Adobe X/Adobe X.app and Cisco/… are found).
/// Resolves symlinks, drops dangling ones, dedupes by realpath, skips CoreServices bundles with LSUIElement=true.
/// Reads Info.plist (CFBundleDisplayName/CFBundleName/CFBundleIdentifier) and
/// Contents/Resources/*.lproj/InfoPlist.strings for localized names (PropertyListSerialization handles binary/UTF-16).
/// `FileManager.default.displayName(atPath:)` is the primary display string. Must finish in < 1 s for ~150 apps.
///
/// Item naming (see `ScannedApp.fileName`): the item name in the store is the bundle's file name without `.app`
/// (`WeChat`), so `store.path(of:) + ".app"` is the bundle path. `AppInfo.displayName` carries the Finder display
/// name; when the two differ (localized Finder name) the display name is also added as a searchable alias.
public enum AppScanner {
    public static let defaultRoots: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "~/Applications", "/System/Library/CoreServices/Applications", "/Applications/Xcode.app/Contents/Applications",
    ]
    public static let extraBundles: [String] = ["/System/Library/CoreServices/Finder.app"]

    /// Maximum number of aliases kept per app.
    public static let maxAliases = 12

    /// Scan the given roots (with `~` expanded). Never throws; unreadable roots are skipped.
    public static func scan(roots: [String] = defaultRoots, extraBundles: [String] = extraBundles) -> [ScannedApp] {
        scanOutcome(roots: roots, extraBundles: extraBundles, home: NSHomeDirectory()).apps
    }

    /// `scan` with an explicit home directory for `~` expansion (tests).
    public static func scan(roots: [String], extraBundles: [String], home: String) -> [ScannedApp] {
        scanOutcome(roots: roots, extraBundles: extraBundles, home: home).apps
    }

    /// Full discovery result used by `IndexCoordinator` so a safety ceiling cannot silently omit
    /// applications. Existing callers that only need best-effort apps can continue using `scan`.
    public static func scanOutcome(roots: [String] = defaultRoots,
                                   extraBundles: [String] = extraBundles,
                                   home: String = NSHomeDirectory()) -> AppScanOutcome {
        scanOutcome(roots: roots, extraBundles: extraBundles, home: home,
                    candidateLimit: SafetyLimits.maxAppCandidates,
                    directoryEntryLimit: SafetyLimits.maxAppDirectoryEntries,
                    inspectedEntryLimit: SafetyLimits.maxAppInspectedEntries)
    }

    /// Injectable ceilings keep truncation semantics testable without creating tens of thousands of
    /// bundles. Internal only; production always uses the process-wide limits above.
    static func scanOutcome(roots: [String], extraBundles: [String], home: String,
                            candidateLimit: Int, directoryEntryLimit: Int,
                            inspectedEntryLimit: Int = SafetyLimits.maxAppInspectedEntries) -> AppScanOutcome {
        let candidateLimit = max(0, min(candidateLimit, SafetyLimits.maxAppCandidates))
        let directoryEntryLimit = max(1, min(directoryEntryLimit, SafetyLimits.maxAppDirectoryEntries))
        let inspectedEntryLimit = max(0, min(inspectedEntryLimit, SafetyLimits.maxAppInspectedEntries))
        var candidates: [Candidate] = []
        var truncated = roots.count > SafetyLimits.maxRootEntries
            || extraBundles.count > SafetyLimits.maxRootEntries
        var inspectionBudget = InspectionBudget(limit: inspectedEntryLimit)
        for root in roots.prefix(SafetyLimits.maxRootEntries) {
            guard !inspectionBudget.exhausted else { truncated = true; break }
            guard candidates.count < candidateLimit else { truncated = true; break }
            guard let path = safeExpandedPath(root, home: home) else {
                truncated = true
                continue
            }
            collectCandidates(root: path, into: &candidates, candidateLimit: candidateLimit,
                              directoryEntryLimit: directoryEntryLimit,
                              inspectionBudget: &inspectionBudget, truncated: &truncated)
        }
        for extra in extraBundles.prefix(SafetyLimits.maxRootEntries) {
            guard candidates.count < candidateLimit else { truncated = true; break }
            guard let path = safeExpandedPath(extra, home: home) else {
                truncated = true
                continue
            }
            candidates.append(Candidate(url: URL(fileURLWithPath: path), skipUIElements: isCoreServicesPath(path)))
        }
        return AppScanOutcome(apps: resolveAndRead(candidates), truncated: truncated)
    }

    /// Validate public root text before tilde expansion or URL construction. Both the raw input and
    /// the expanded absolute result are bounded, so a huge `home` or root cannot force proportional
    /// concatenation/allocation work. An invalid home matters only for a root that actually uses `~`.
    private static func safeExpandedPath(_ raw: String, home: String) -> String? {
        guard SafetyLimits.utf8Fits(raw, maxBytes: SafetyLimits.maxPathUTF8Bytes) else { return nil }
        if raw == "~" || SafetyLimits.hasTildeSlashPrefix(raw) {
            return SafetyLimits.expandingLeadingTilde(raw, home: home)
        }
        return SafetyLimits.isSafeAbsolutePath(raw) ? raw : nil
    }

    // MARK: Candidate discovery

    private struct Candidate: Sendable {
        var url: URL
        var skipUIElements: Bool
    }

    private struct InspectionBudget {
        private(set) var remaining: Int
        private(set) var exhausted = false

        init(limit: Int) { remaining = max(0, limit) }

        mutating func consume() -> Bool {
            guard remaining > 0 else { exhausted = true; return false }
            remaining -= 1
            return true
        }
    }

    private struct BundleReadOutcome: Sendable {
        var app: ScannedApp?
    }

    /// Parallel bundle readers publish into fixed source-order slots. The lock is held only for the
    /// final assignment (all filesystem/plist work happens before it), so this removes the unsafe
    /// shared buffer capture without serializing the expensive part of scanning. All access to
    /// `values` is lock-protected, which is the complete invariant behind `@unchecked Sendable`.
    private final class ScannedAppSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ScannedApp?]

        init(count: Int) { values = [ScannedApp?](repeating: nil, count: count) }

        func store(_ value: ScannedApp?, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            values[index] = value
        }

        func compacted() -> [ScannedApp] {
            lock.lock()
            defer { lock.unlock() }
            return values.compactMap { $0 }
        }
    }

    private static let listKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]

    private static func isCoreServicesPath(_ p: String) -> Bool { p.hasPrefix("/System/Library/CoreServices") }

    /// Depth ≤ 2: `root/X.app` and `root/Sub/X.app` (Sub = any non-hidden, non-.app directory).
    private static func collectCandidates(root: String, into out: inout [Candidate],
                                          candidateLimit: Int, directoryEntryLimit: Int,
                                          inspectionBudget: inout InspectionBudget,
                                          truncated: inout Bool) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let entries = list(rootURL, maxEntries: directoryEntryLimit,
                                 inspectionBudget: &inspectionBudget,
                                 didExceedLimit: &truncated) else { return }
        let skipUI = isCoreServicesPath(root)
        for e in entries {
            guard !inspectionBudget.exhausted else { truncated = true; return }
            guard out.count < candidateLimit else { truncated = true; return }
            if e.lastPathComponent.lowercased().hasSuffix(".app") {
                out.append(Candidate(url: e, skipUIElements: skipUI))
            } else if isPlainDirectory(e),
                      let sub = list(e, maxEntries: directoryEntryLimit,
                                     inspectionBudget: &inspectionBudget,
                                     didExceedLimit: &truncated) {
                for s in sub where s.lastPathComponent.lowercased().hasSuffix(".app") {
                    guard out.count < candidateLimit else { truncated = true; return }
                    out.append(Candidate(url: s, skipUIElements: skipUI))
                }
            }
        }
    }

    /// List a directory WITHOUT `.skipsHiddenFiles`: on macOS 26 the `/Applications/Safari.app` symlink into the
    /// Cryptex carries the hidden flag and would otherwise be skipped. Dot-names are filtered manually instead.
    private static func list(_ dir: URL, maxEntries: Int,
                             inspectionBudget: inout InspectionBudget,
                             didExceedLimit: inout Bool) -> [URL]? {
        guard maxEntries > 0,
              let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(listKeys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: nil
              ) else { return nil }
        var entries: [URL] = []
        entries.reserveCapacity(min(maxEntries, 256))
        var inspected = 0
        for case let entry as URL in enumerator {
            guard inspectionBudget.consume() else {
                didExceedLimit = true
                return nil
            }
            inspected += 1
            guard inspected <= maxEntries else {
                // Returning a partial, filesystem-order-dependent directory would make discovery
                // nondeterministic. Reject the oversized directory as a unit instead.
                didExceedLimit = true
                return nil
            }
            // Hidden names still consume the traversal budget; otherwise an attacker could create
            // arbitrarily many dot entries and bypass the CPU ceiling while retaining no results.
            guard !SafetyLimits.hasDotPrefix(entry.lastPathComponent) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// A real (non-symlink) directory.
    private static func isPlainDirectory(_ url: URL) -> Bool {
        guard let rv = try? url.resourceValues(forKeys: listKeys) else { return false }
        return (rv.isDirectory ?? false) && !(rv.isSymbolicLink ?? false)
    }

    // MARK: Resolution + reading

    /// Resolve symlinks, drop dangling/non-directory targets, dedupe by resolved path, read bundle metadata in parallel.
    private static func resolveAndRead(_ candidates: [Candidate]) -> [ScannedApp] {
        var seen = Set<String>()
        var resolved: [Candidate] = []
        for c in candidates {
            let target = c.url.resolvingSymlinksInPath().standardizedFileURL
            var info = stat()
            guard lstat(target.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { continue }
            if seen.insert(target.path).inserted {
                // Keep the path the user knows (e.g. /Applications/Safari.app, a symlink into the Cryptex on
                // macOS 26) for display + launch; the resolved target is only used for de-duplication.
                resolved.append(Candidate(url: c.url.standardizedFileURL, skipUIElements: c.skipUIElements))
            }
        }
        // Reading ~700 InfoPlist.strings files serially costs ~0.5 s on this Mac; do bundles in parallel.
        // Freeze discovery before entering the @Sendable closure and write through synchronized slots.
        let work = resolved
        let results = ScannedAppSlots(count: work.count)
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let candidate = work[i]
            let outcome = readBundleOutcome(candidate.url, skipUIElements: candidate.skipUIElements,
                                            hooks: nil)
            results.store(outcome.app, at: i)
        }
        return results.compacted()
    }

    /// Read one bundle. Returns nil for LSUIElement helpers when `skipUIElements` is set.
    static func readBundle(_ url: URL, skipUIElements: Bool,
                           hooks: AppScannerTestHooks? = nil) -> ScannedApp? {
        readBundleOutcome(url, skipUIElements: skipUIElements, hooks: hooks).app
    }

    private struct BundleMetadataBudget {
        var remainingBytes = SafetyLimits.maxBundleMetadataTotalBytes
        var remainingLocalizationFiles = SafetyLimits.maxBundleLocalizationFiles

        mutating func consume(bytes: Int) {
            remainingBytes = max(0, remainingBytes - max(0, bytes))
        }
    }

    private static func readBundleOutcome(_ url: URL, skipUIElements: Bool,
                                          hooks: AppScannerTestHooks?) -> BundleReadOutcome {
        guard let bundle = OpenAppDirectory.bundle(at: url, hooks: hooks) else {
            return BundleReadOutcome(app: nil)
        }
        let contents = bundle.child(component: "Contents", hooks: hooks)
        var budget = BundleMetadataBudget()
        var metadataTruncated = false
        var info: [String: Any] = [:]
        if let contents {
            let readLimit = min(SafetyLimits.maxBundleMetadataFileBytes, budget.remainingBytes)
            switch contents.readRegularFile(component: "Info.plist", maxBytes: readLimit, hooks: hooks) {
            case .data(let data):
                budget.consume(bytes: data.count)
                info = parsePropertyListDictionary(data)
            case .limitExceeded:
                metadataTruncated = true
            case .missing, .unsafe:
                break
            }
        }
        if skipUIElements && isUIElement(info["LSUIElement"]) {
            return BundleReadOutcome(app: nil)
        }
        guard let component = boundedString(url.lastPathComponent,
                                            maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes) else {
            return BundleReadOutcome(app: nil)
        }
        let fileName = stripAppExtension(component)
        let finderName = boundedString(FileManager.default.displayName(atPath: url.path),
                                       maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes)
            .map(stripAppExtension)
        let displayName = finderName
            ?? nonEmptyString(info["CFBundleDisplayName"])
            ?? nonEmptyString(info["CFBundleName"])
            ?? fileName
        var aliases: [String] = []
        var seenFolded = Set<String>([TextAnalyzer.fold(displayName), TextAnalyzer.fold(fileName)])
        func addAlias(_ s: String?) {
            guard aliases.count < maxAliases,
                  let raw = s,
                  SafetyLimits.utf8Fits(raw, maxBytes: SafetyLimits.maxNameUTF8Bytes) else { return }
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            if seenFolded.insert(TextAnalyzer.fold(s)).inserted { aliases.append(s) }
        }
        addAlias(nonEmptyString(info["CFBundleDisplayName"]))
        addAlias(nonEmptyString(info["CFBundleName"]))
        if let contents, !metadataTruncated, aliases.count < maxAliases {
            let localized = localizedNames(in: contents, maxNames: maxAliases - aliases.count,
                                           budget: &budget, hooks: hooks)
            for name in localized {
                guard aliases.count < maxAliases else { break }
                addAlias(name)
            }
        }
        let mtime = Date(timeIntervalSince1970: TimeInterval(bundle.info.st_mtimespec.tv_sec)
                         + TimeInterval(bundle.info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let app = ScannedApp(url: url, displayName: displayName,
                            bundleID: nonEmptyString(info["CFBundleIdentifier"],
                                                     maxUTF8Bytes: SafetyLimits.maxSettingUTF8Bytes),
                            aliases: aliases, mtime: mtime)
        return BundleReadOutcome(app: app)
    }

    /// `Contents/Info.plist` as a dictionary (empty on any failure).
    static func readInfoPlist(_ bundle: URL) -> [String: Any] {
        guard let root = OpenAppDirectory.bundle(at: bundle, hooks: nil),
              let contents = root.child(component: "Contents", hooks: nil) else { return [:] }
        let limit = min(SafetyLimits.maxBundleMetadataFileBytes,
                        SafetyLimits.maxBundleMetadataTotalBytes)
        guard case .data(let data) = contents.readRegularFile(component: "Info.plist",
                                                               maxBytes: limit, hooks: nil) else { return [:] }
        return parsePropertyListDictionary(data)
    }

    private static func parsePropertyListDictionary(_ data: Data) -> [String: Any] {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any] ?? [:]
    }

    /// LSUIElement may be a Bool, a Number or the string "1"/"YES"/"true".
    static func isUIElement(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            guard SafetyLimits.utf8Fits(s, maxBytes: 16) else { return false }
            return ["1", "yes", "true"].contains(s.lowercased())
        default: return false
        }
    }

    static func nonEmptyString(_ v: Any?,
                               maxUTF8Bytes: Int = SafetyLimits.maxNameUTF8Bytes) -> String? {
        guard let s = v as? String,
              let s = boundedString(s, maxUTF8Bytes: maxUTF8Bytes) else { return nil }
        return s
    }

    private static func boundedString(_ value: String, maxUTF8Bytes: Int) -> String? {
        guard SafetyLimits.utf8Fits(value, maxBytes: maxUTF8Bytes),
              !value.isEmpty, !value.utf8.contains(0) else { return nil }
        return value
    }

    /// Every CFBundleDisplayName/CFBundleName value in `Contents/Resources/*.lproj/InfoPlist.strings`.
    /// `PropertyListSerialization` parses binary, XML and old-style (`"key" = "value";`, UTF-8/UTF-16) formats.
    static func localizedNames(_ bundle: URL, maxNames: Int = maxAliases) -> [String] {
        let limit = min(max(0, maxNames), maxAliases)
        guard limit > 0 else { return [] }
        guard let root = OpenAppDirectory.bundle(at: bundle, hooks: nil),
              let contents = root.child(component: "Contents", hooks: nil) else { return [] }
        var budget = BundleMetadataBudget()
        return localizedNames(in: contents, maxNames: limit, budget: &budget, hooks: nil)
    }

    private static func localizedNames(in contents: OpenAppDirectory, maxNames: Int,
                                       budget: inout BundleMetadataBudget,
                                       hooks: AppScannerTestHooks?) -> [String] {
        let limit = min(max(0, maxNames), maxAliases)
        guard limit > 0,
              let resources = contents.child(component: "Resources", hooks: hooks),
              let listing = resources.entries(limit: SafetyLimits.maxLocalizedResourceDirectories) else {
            return []
        }
        guard !listing.exceededLimit else { return [] }
        var out: [String] = []
        localizations: for lproj in listing.entries where lproj.name.hasSuffix(".lproj") {
            guard out.count < limit else { break }
            guard budget.remainingLocalizationFiles > 0,
                  budget.remainingBytes > 0 else { break }
            budget.remainingLocalizationFiles -= 1
            guard let directory = resources.child(entry: lproj, hooks: hooks) else { continue }
            let readLimit = min(SafetyLimits.maxBundleMetadataFileBytes, budget.remainingBytes)
            switch directory.readRegularFile(component: "InfoPlist.strings",
                                              maxBytes: readLimit, hooks: hooks) {
            case .data(let read):
                budget.consume(bytes: read.count)
                guard !read.isEmpty else { continue }
                let dict = parsePropertyListDictionary(read)
                if let s = nonEmptyString(dict["CFBundleDisplayName"]) { out.append(s) }
                if let s = nonEmptyString(dict["CFBundleName"]) {
                    if out.count < limit { out.append(s) } else { break localizations }
                }
            case .limitExceeded:
                break localizations
            case .missing, .unsafe:
                continue
            }
        }
        return out
    }

    /// "Foo.app" → "Foo" (case-insensitive extension match); other names unchanged.
    static func stripAppExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Builder paths always reconstruct the lower-case `.app` suffix. Require that exact POSIX byte
    /// spelling at the public ScannedApp boundary so case-sensitive volumes never launch a different
    /// path than the caller supplied.
    private static func hasExactAppExtension(_ name: String) -> Bool {
        name.utf8.suffix(4).elementsEqual([0x2E, 0x61, 0x70, 0x70])
    }

    // MARK: Adding to a builder

    /// Add apps to a builder: one item per app (kind .app, flags .appBundle + .appCatalog, depth 1,
    /// ext "app") with an `AppInfo` carrying folded aliases + pinyin aliases (`Pinyin.aliases`) for
    /// CJK names. Absolute parents share a component tree rooted at `/`; thousands of different app
    /// parents therefore remain complete without becoming thousands of snapshot roots. The explicit
    /// `.appCatalog` provenance bit lets later rescans remove only scanner-owned app items.
    /// Returns true when one or more apps were omitted because a shared resource budget was full.
    @discardableResult
    public static func add(_ apps: [ScannedApp], to builder: IndexBuilder, maxItems: Int = Int.max) -> Bool {
        add(apps, to: builder, maxItems: maxItems,
            catalogDirectoryLimit: SafetyLimits.maxAppCatalogDirectories,
            catalogDirectoryByteLimit: SafetyLimits.maxAppCatalogDirectoryBytes)
    }

    /// Injectable catalog topology ceiling for deterministic boundary tests. Missing parent
    /// components are claimed as a group before mutating the builder, so an over-budget path never
    /// leaves an order-dependent partial prefix behind.
    @discardableResult
    static func add(_ apps: [ScannedApp], to builder: IndexBuilder, maxItems: Int,
                    catalogDirectoryLimit: Int,
                    catalogDirectoryByteLimit: Int = SafetyLimits.maxAppCatalogDirectoryBytes) -> Bool {
        let limit = IndexStoreLimits.normalizedMaxItems(maxItems)
        var directoryIds: [CatalogNodeKey: CatalogNode] = [:]
        var catalogRootID: Int32?
        var directoryBudget = CatalogDirectoryBudget(directoryLimit: catalogDirectoryLimit,
                                                     byteLimit: catalogDirectoryByteLimit)
        var omitted = apps.count > SafetyLimits.maxAppCandidates
        var claimedIngest = false
        for app in apps.prefix(SafetyLimits.maxAppCandidates) {
            guard builder.count < limit else { return true }
            guard app.url.isFileURL else { continue }
            let component = app.url.lastPathComponent
            guard SafetyLimits.isSafePathComponent(
                component, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
            ), hasExactAppExtension(component) else { continue }
            let parent = app.url.deletingLastPathComponent().path
            guard SafetyLimits.isSafeAbsolutePath(parent) else { continue }
            let name = stripAppExtension(component)
            guard !name.isEmpty else { continue }
            guard let directoryPlan = planAppDirectory(parent: parent,
                                                       directoryIds: directoryIds,
                                                       rootID: catalogRootID) else { continue }
            let inputParentEndsInSlash = directoryPlan.standardizedParent.utf8.last == 0x2F
            guard IndexStoreLimits.completeItemPathFits(
                directoryPathUTF8Bytes: directoryPlan.standardizedParent.utf8.count,
                directoryEndsInSlash: inputParentEndsInSlash,
                storedName: name, flagsRaw: ItemFlags.appBundle.rawValue
            ), IndexStoreLimits.completeItemPathFits(
                directoryPathUTF8Bytes: directoryPlan.projectedParentPathUTF8Bytes,
                directoryEndsInSlash: directoryPlan.projectedParentEndsInSlash,
                storedName: name, flagsRaw: ItemFlags.appBundle.rawValue
            ) else { continue }
            let displayName = boundedString(app.displayName,
                                            maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes) ?? name
            let bundleID = app.bundleID.flatMap {
                boundedString($0, maxUTF8Bytes: SafetyLimits.maxSettingUTF8Bytes)
            }
            // Bound raw inspection before filtering: `compactMap(...).prefix(...)` would scan an
            // arbitrary public array when every early value is invalid.
            let aliases = app.aliases.prefix(maxAliases).compactMap {
                boundedString($0, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes)
            }
            let safeApp = ScannedApp(url: app.url, displayName: displayName, bundleID: bundleID,
                                     aliases: aliases, mtime: app.mtime)
            let analyzed = TextAnalyzer.analyze(name)
            let info = AppInfo(bundleID: safeApp.bundleID, displayName: safeApp.displayName,
                               aliases: searchAliases(for: safeApp, primary: analyzed))
            let appFlags: ItemFlags = [.appBundle, .appCatalog]
            let sharedRootAlreadyInterned = directoryPlan.needsRoot && builder.hasRoot("/")
            let claimedDirectoryCount = directoryPlan.missingDirectoryCount
                - (sharedRootAlreadyInterned ? 1 : 0)
            let claimedDirectoryBytes = directoryPlan.missingDirectoryBytes
                - (sharedRootAlreadyInterned ? 1 : 0)
            guard builder.canAddItemAfterAddingDirectories(
                newDirectoryCount: directoryPlan.missingDirectoryCount,
                newDirectoryBytes: directoryPlan.missingDirectoryBytes,
                rootPath: directoryPlan.needsRoot ? "/" : nil,
                directoryPathUTF8Bytes: directoryPlan.projectedParentPathUTF8Bytes,
                directoryEndsInSlash: directoryPlan.projectedParentEndsInSlash,
                name: name, analyzed: analyzed, kind: .app, flags: appFlags, app: info
            ) else {
                omitted = true
                continue
            }
            guard directoryBudget.claim(
                directories: claimedDirectoryCount,
                bytes: claimedDirectoryBytes
            ) else { return true }
            if !claimedIngest {
                guard builder.beginAppCatalogIngest() else { return true }
                claimedIngest = true
            }
            guard let dirId = commitAppDirectory(directoryPlan, builder: builder,
                                                 directoryIds: &directoryIds,
                                                 rootID: &catalogRootID) else {
                directoryBudget.stop()
                return true
            }
            // The builder is single-threaded. `canAddItemAfterAddingDirectories` called the same
            // item preflight as `addItem`, and commit changes only the exactly-planned directory
            // count/arena (or less when `/` dedupes), so this call cannot introduce a new failure.
            if builder.addItem(dir: dirId, name: name, analyzed: analyzed, kind: .app,
                               flags: appFlags, mtime: app.mtime,
                               depth: 1, ext: "app", app: info) < 0 {
                directoryBudget.stop()
                return true
            }
        }
        return omitted
    }

    private struct CatalogDirectoryBudget {
        private(set) var remainingDirectories: Int
        private(set) var remainingBytes: Int
        private(set) var stopped = false

        init(directoryLimit: Int, byteLimit: Int) {
            remainingDirectories = min(max(0, directoryLimit),
                                       SafetyLimits.maxAppCatalogDirectories)
            remainingBytes = min(max(0, byteLimit), SafetyLimits.maxAppCatalogDirectoryBytes)
        }

        /// Claims both topology dimensions together. On failure neither counter changes and the
        /// caller stops, so no later app can make results depend on a half-consumed path budget.
        mutating func claim(directories: Int, bytes: Int) -> Bool {
            guard directories >= 0, bytes >= 0,
                  directories <= remainingDirectories, bytes <= remainingBytes else {
                stopped = true
                return false
            }
            remainingDirectories -= directories
            remainingBytes -= bytes
            return true
        }

        mutating func stop() { stopped = true }
    }

    /// A catalog trie node is identified by its physical parent id plus one bounded component.
    /// Unlike a full-prefix String key, retained key bytes are linear in `dirArena` and a deep path
    /// does not repeatedly copy/hash every ancestor prefix.
    private struct CatalogNodeKey: Hashable {
        var parent: Int32
        var component: String
    }

    private struct CatalogNode {
        var id: Int32
        var pathUTF8Bytes: Int
        var endsInSlash: Bool
    }

    private struct CatalogDirectoryPlan {
        var standardizedParent: String
        var components: [String]
        var needsRoot: Bool
        var missingDirectoryCount: Int
        var missingDirectoryBytes: Int
        var projectedParentPathUTF8Bytes: Int
        var projectedParentEndsInSlash: Bool
    }

    /// Pure catalog planning: validate every parent component and calculate the exact missing
    /// topology before one-shot state, catalog budgets, or the builder are mutated.
    private static func planAppDirectory(parent: String,
                                         directoryIds: [CatalogNodeKey: CatalogNode],
                                         rootID: Int32?) -> CatalogDirectoryPlan? {
        let standardized = URL(fileURLWithPath: parent, isDirectory: true).standardizedFileURL.path
        guard SafetyLimits.isSafeAbsolutePath(standardized) else { return nil }

        let components = standardized == "/"
            ? []
            : Array(URL(fileURLWithPath: standardized, isDirectory: true).pathComponents.dropFirst())
        var missingDirectories = rootID == nil ? 1 : 0
        var missingDirectoryBytes = rootID == nil ? 1 : 0 // `/` root arena bytes
        var firstMissing = 0
        var existingParent = rootID
        var projectedPathBytes = 1 // the catalog root is always `/`
        var projectedEndsInSlash = true
        for component in components {
            guard SafetyLimits.isSafePathComponent(
                component, maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes
            ) else { return nil }
        }
        for component in components {
            guard let parentID = existingParent,
                  let existing = directoryIds[
                    CatalogNodeKey(parent: parentID, component: component)
                  ] else { break }
            existingParent = existing.id
            projectedPathBytes = existing.pathUTF8Bytes
            projectedEndsInSlash = existing.endsInSlash
            firstMissing += 1
        }
        for component in components.dropFirst(firstMissing) {
            missingDirectories = IndexStoreLimits.adding(missingDirectories, 1)
            missingDirectoryBytes = IndexStoreLimits.adding(missingDirectoryBytes,
                                                             component.utf8.count)
            projectedPathBytes = IndexStoreLimits.adding(
                IndexStoreLimits.adding(projectedPathBytes, projectedEndsInSlash ? 0 : 1),
                component.utf8.count
            )
            projectedEndsInSlash = false
        }
        guard projectedPathBytes <= SafetyLimits.maxPathUTF8Bytes else { return nil }
        return CatalogDirectoryPlan(standardizedParent: standardized, components: components,
                                    needsRoot: rootID == nil,
                                    missingDirectoryCount: missingDirectories,
                                    missingDirectoryBytes: missingDirectoryBytes,
                                    projectedParentPathUTF8Bytes: projectedPathBytes,
                                    projectedParentEndsInSlash: projectedEndsInSlash)
    }

    private static func commitAppDirectory(_ plan: CatalogDirectoryPlan,
                                           builder: IndexBuilder,
                                           directoryIds: inout [CatalogNodeKey: CatalogNode],
                                           rootID: inout Int32?) -> Int32? {
        let resolvedRootID: Int32
        if let existing = rootID {
            resolvedRootID = existing
        } else {
            resolvedRootID = builder.addRoot("/")
            guard resolvedRootID >= 0 else { return nil }
            rootID = resolvedRootID
        }
        if plan.standardizedParent == "/" { return resolvedRootID }

        var currentID = resolvedRootID
        var currentPathBytes = 1
        var currentEndsInSlash = true
        for component in plan.components {
            let key = CatalogNodeKey(parent: currentID, component: component)
            if let existing = directoryIds[key] {
                currentID = existing.id
                currentPathBytes = existing.pathUTF8Bytes
                currentEndsInSlash = existing.endsInSlash
            } else {
                currentID = builder.addDir(parent: currentID, name: component)
                guard currentID >= 0 else { return nil }
                currentPathBytes = IndexStoreLimits.adding(
                    IndexStoreLimits.adding(currentPathBytes, currentEndsInSlash ? 0 : 1),
                    component.utf8.count
                )
                currentEndsInSlash = false
                directoryIds[key] = CatalogNode(id: currentID,
                                                pathUTF8Bytes: currentPathBytes,
                                                endsInSlash: currentEndsInSlash)
            }
        }
        return currentID
    }

    /// Folded aliases for an app: display name (if ≠ file name), every raw alias, pinyin for the display name and for every
    /// CJK alias. De-duplicated; never contains `primary` (the analysed item name).
    static func searchAliases(for app: ScannedApp, primary: SearchString) -> [SearchString] {
        var out: [SearchString] = []
        var seen = Set<[UInt8]>([primary.folded])
        func push(_ s: SearchString) {
            guard out.count < SafetyLimits.maxSearchAliasesPerApp else { return }
            if !s.folded.isEmpty && seen.insert(s.folded).inserted { out.append(s) }
        }
        func process(_ t: String) {
            guard out.count < SafetyLimits.maxSearchAliasesPerApp,
                  SafetyLimits.utf8Fits(t, maxBytes: SafetyLimits.maxNameUTF8Bytes) else { return }
            push(TextAnalyzer.analyze(t))
            if containsCJK(t) {
                for p in Pinyin.aliases(for: t) {
                    guard out.count < SafetyLimits.maxSearchAliasesPerApp else { break }
                    push(p)
                }
            }
        }
        process(app.displayName)
        for text in app.aliases.prefix(maxAliases) {
            guard out.count < SafetyLimits.maxSearchAliasesPerApp else { break }
            process(text)
        }
        return out
    }

    /// CJK Unified Ideograph check (own copy so the scanner does not depend on the pinyin module's stubs).
    static func containsCJK(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
            default: continue
            }
        }
        return false
    }
}
