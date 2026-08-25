import Darwin
import Foundation

public struct CodexStatePaths: Equatable, Sendable {
    public let root: URL
    public let codexHome: URL
    public let scratch: URL

    public static func prepare(applicationSupportRoot: URL? = nil) throws -> CodexStatePaths {
        let support = applicationSupportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                          in: .userDomainMask).first
        guard let support, support.isFileURL else { throw CodexConnectionError.stateDirectoryUnsafe }
        let root = support.appendingPathComponent("JBar", isDirectory: true).standardizedFileURL
        let codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
        let scratch = root.appendingPathComponent("AgentScratch", isDirectory: true)
        try secureDirectory(root)
        try secureDirectory(codexHome)
        try secureDirectory(scratch)
        return CodexStatePaths(root: root, codexHome: codexHome, scratch: scratch)
    }

    private static func secureDirectory(_ url: URL) throws {
        let path = url.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw CodexConnectionError.stateDirectoryUnsafe }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw CodexConnectionError.stateDirectoryUnsafe }
            guard lstat(path, &info) == 0 else { throw CodexConnectionError.stateDirectoryUnsafe }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & S_IFMT) != S_IFLNK,
              info.st_uid == getuid(),
              chmod(path, 0o700) == 0 else { throw CodexConnectionError.stateDirectoryUnsafe }
    }
}
