import Darwin
import Foundation

/// The single local workspace exposed to JBar's Codex agent. Keeping selection deterministic makes
/// the window lightweight and makes every sandbox/path check auditable.
public struct CodexWorkspace: Equatable, Sendable {
    public let url: URL
    private let deviceID: UInt64
    private let inode: UInt64

    public init(url: URL) throws {
        let validated = try Self.validated(url)
        self.url = validated.url
        deviceID = validated.deviceID
        inode = validated.inode
    }

    public static func jbar(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        try Self(url: homeDirectory.appendingPathComponent("jbar", isDirectory: true))
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public func contains(_ rawPath: String) -> Bool {
        guard isCurrent else { return false }
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = url.appendingPathComponent(rawPath)
        }
        let rootPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = Self.resolvedPathForContainment(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    public func validateCurrent() throws {
        guard isCurrent else { throw CodexConnectionError.workspaceUnsafe }
    }

    public func relativePath(_ rawPath: String) -> String {
        let candidate = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : url.appendingPathComponent(rawPath)
        let rootPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = Self.resolvedPathForContainment(candidate)
        guard candidatePath.hasPrefix(rootPath + "/") else { return candidatePath }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    /// `resolvingSymlinksInPath` does not reliably resolve an intermediate symlink when the final
    /// file does not exist yet. Resolve the closest existing ancestor, then restore the suffix so
    /// a proposed new file cannot escape through a symlinked directory.
    private static func resolvedPathForContainment(_ candidate: URL) -> String {
        var ancestor = candidate.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path),
              ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    private var isCurrent: Bool {
        guard let identity = Self.identity(of: url) else { return false }
        return identity.deviceID == deviceID && identity.inode == inode
    }

    private static func validated(_ candidate: URL) throws
        -> (url: URL, deviceID: UInt64, inode: UInt64) {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw CodexConnectionError.workspaceUnsafe
        }
        let standardized = candidate.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { throw CodexConnectionError.workspaceUnsafe }
        guard let identity = identity(of: standardized) else {
            throw CodexConnectionError.workspaceUnsafe
        }
        return (standardized, identity.deviceID, identity.inode)
    }

    private static func identity(of url: URL) -> (deviceID: UInt64, inode: UInt64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & S_IFMT) != S_IFLNK,
              info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { return nil }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }
}
