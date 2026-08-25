import Foundation

public struct CodexVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func parse(_ output: String) -> CodexVersion? {
        let pattern = #"(?:codex-cli\s+)?(\d+)\.(\d+)\.(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let patchRange = Range(match.range(at: 3), in: output),
              let major = Int(output[majorRange]),
              let minor = Int(output[minorRange]),
              let patch = Int(output[patchRange]) else { return nil }
        return CodexVersion(major, minor, patch)
    }
}

public struct VerifiedCodexBinary: Equatable, Sendable {
    public let url: URL
    public let version: CodexVersion
}

public struct CodexBinaryLocator: Sendable {
    public static let minimumVersion = CodexVersion(0, 149, 0)
    private static let outputLimit = 4_096

    public init() {}

    public func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       homeDirectory: String = NSHomeDirectory()) throws -> VerifiedCodexBinary {
        let candidates = Self.candidatePaths(environment: environment, homeDirectory: homeDirectory)

        var firstOldVersion: CodexVersion?
        var sawInvalidCandidate = false
        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: resolved.path),
                  Self.hasSafeFileMetadata(resolved) else { continue }
            do {
                let output = try versionOutput(from: resolved)
                guard let version = CodexVersion.parse(output) else {
                    sawInvalidCandidate = true
                    continue
                }
                guard version >= Self.minimumVersion else {
                    firstOldVersion = firstOldVersion ?? version
                    continue
                }
                return VerifiedCodexBinary(url: resolved, version: version)
            } catch {
                sawInvalidCandidate = true
            }
        }
        if let old = firstOldVersion {
            throw CodexConnectionError.unsupportedVersion(found: old.description,
                                                          required: Self.minimumVersion.description)
        }
        if sawInvalidCandidate { throw CodexConnectionError.invalidCodexBinary }
        throw CodexConnectionError.codexNotFound
    }

    /// Ordered, deterministic discovery that works from a GUI process without an interactive shell.
    /// The ChatGPT desktop app contains an official Codex executable, so it is a safe user-installed
    /// fallback when an older Homebrew CLI is still present. JBar never installs or bundles Codex.
    static func candidatePaths(environment: [String: String], homeDirectory: String) -> [String] {
        var candidates: [String] = []
        if let explicit = environment["JBAR_CODEX_PATH"], explicit.hasPrefix("/") {
            candidates.append(explicit)
        }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            (homeDirectory as NSString).appendingPathComponent(".local/bin/codex"),
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            (homeDirectory as NSString).appendingPathComponent(
                "Applications/ChatGPT.app/Contents/Resources/codex"
            ),
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").compactMap { component in
                let directory = String(component)
                guard directory.hasPrefix("/") else { return nil }
                return (directory as NSString).appendingPathComponent("codex")
            }
        }

        return candidates.uniqued()
    }

    private func versionOutput(from executable: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw CodexConnectionError.invalidCodexBinary }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { process.terminate() }
            throw CodexConnectionError.invalidCodexBinary
        }
        guard process.terminationStatus == 0 else { throw CodexConnectionError.invalidCodexBinary }
        let data = stdout.fileHandleForReading.readDataToEndOfFile().prefix(Self.outputLimit)
        return String(decoding: data, as: UTF8.self)
    }

    /// A version-shaped executable in a writable shared location is not sufficient evidence. Permit
    /// regular files owned by this user or root, and reject group/world-writable resolved targets.
    private static func hasSafeFileMetadata(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() || owner.uint32Value == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0 else { return false }
        return true
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
