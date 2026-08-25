import Darwin
import Foundation

public struct OrganizeFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }
}

public struct ScopedFileReference: Codable, Equatable, Sendable {
    public let id: UUID
    public let scopeID: String
    public let canonicalPath: String
    public let name: String
    public let identity: OrganizeFileIdentity
    public let modifiedAt: Date?

    fileprivate init(id: UUID, scopeID: String, canonicalPath: String, name: String,
                     identity: OrganizeFileIdentity, modifiedAt: Date?) {
        self.id = id
        self.scopeID = scopeID
        self.canonicalPath = canonicalPath
        self.name = name
        self.identity = identity
        self.modifiedAt = modifiedAt
    }
}

public struct OrganizeScopeSnapshot: Sendable {
    public static let maximumFiles = 500

    public let scopeID: String
    public let rootPath: String
    public let rootIdentity: OrganizeFileIdentity
    public let files: [ScopedFileReference]
    public let excludedEntries: Int

    public static func capture(folder: URL, maximumFiles: Int = maximumFiles) throws -> Self {
        let boundedMaximum = min(max(1, maximumFiles), Self.maximumFiles)
        guard folder.isFileURL, folder.path.hasPrefix("/"), !folder.path.utf8.contains(0) else {
            throw FileOperationError.unsafeScope
        }
        _ = try FileOperationExecutor.fileInfo(atPath: folder.standardizedFileURL.path)
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let rootInfo = try FileOperationExecutor.fileInfo(atPath: canonical.path)
        guard rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else {
            throw FileOperationError.unsafeScope
        }

        let scopeID = "folder-\(UUID().uuidString.lowercased())"
        let children = try FileManager.default.contentsOfDirectory(
            at: canonical, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var files: [ScopedFileReference] = []
        var excluded = 0
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."),
                  SafetyLimits.isSafePathComponent(name,
                                                   maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes),
                  child.deletingLastPathComponent().standardizedFileURL.path == canonical.path,
                  let info = try? FileOperationExecutor.fileInfo(atPath: child.path),
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1 else {
                excluded += 1
                continue
            }
            guard files.count < boundedMaximum else { throw FileOperationError.tooManyFiles }
            let identity = OrganizeFileIdentity(info)
            let modifiedAt = info.st_mtimespec.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                : nil
            files.append(ScopedFileReference(id: UUID(), scopeID: scopeID,
                                             canonicalPath: child.path, name: name,
                                             identity: identity, modifiedAt: modifiedAt))
        }
        return Self(scopeID: scopeID, rootPath: canonical.path,
                    rootIdentity: OrganizeFileIdentity(rootInfo), files: files,
                    excludedEntries: excluded)
    }
}

public struct ProposedFileOperation: Equatable, Sendable {
    public let sourceID: UUID
    public let destinationFolderName: String?
    public let newName: String?

    public init(sourceID: UUID, destinationFolderName: String?, newName: String?) {
        self.sourceID = sourceID
        self.destinationFolderName = destinationFolderName
        self.newName = newName
    }
}

public enum FileOperationPreviewStatus: String, Codable, Equatable, Sendable {
    case ready
    case collision
    case changedSinceSnapshot
    case invalid
}

public struct FileOperationPreviewEntry: Equatable, Sendable {
    public let source: ScopedFileReference
    public let destinationFolderName: String?
    public let destinationName: String
    public let destinationRelativePath: String
    public let status: FileOperationPreviewStatus
    public let explanation: String

    public var isExecutable: Bool { status == .ready }
}

public struct FileOperationPreview: Sendable {
    public let batchID: UUID
    public let scope: OrganizeScopeSnapshot
    public let summary: String
    public let entries: [FileOperationPreviewEntry]
    public let foldersToCreate: [String]

    public var executableCount: Int { entries.lazy.filter(\.isExecutable).count }
    public var collisionCount: Int { entries.lazy.filter { $0.status == .collision }.count }
    public var skippedCount: Int { entries.count - executableCount }
}

public struct CompletedFileMove: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let originalName: String
    public let destinationFolderName: String?
    public let destinationName: String
    public let destinationIdentity: OrganizeFileIdentity
}

public struct FileOperationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let batchID: UUID
    public let scopeID: String
    public let rootPath: String
    public let rootIdentity: OrganizeFileIdentity
    public let createdAt: Date
    public var completedMoves: [CompletedFileMove]
    public var createdFolders: [String]

    public init(batchID: UUID, scope: OrganizeScopeSnapshot) {
        schemaVersion = 1
        self.batchID = batchID
        scopeID = scope.scopeID
        rootPath = scope.rootPath
        rootIdentity = scope.rootIdentity
        createdAt = Date()
        completedMoves = []
        createdFolders = []
    }
}

public enum FileOperationOutcomeStatus: String, Equatable, Sendable {
    case completed
    case skipped
    case failed
}

public struct FileOperationOutcome: Equatable, Sendable {
    public let sourceName: String
    public let destinationRelativePath: String
    public let status: FileOperationOutcomeStatus
    public let explanation: String
}

public struct FileOperationBatchResult: Sendable {
    public let outcomes: [FileOperationOutcome]
    public let manifest: FileOperationManifest
    public let manifestURL: URL

    public var completedCount: Int { outcomes.lazy.filter { $0.status == .completed }.count }
    public var failedCount: Int { outcomes.lazy.filter { $0.status == .failed }.count }
    public var skippedCount: Int { outcomes.lazy.filter { $0.status == .skipped }.count }
}

public struct FileOperationUndoResult: Sendable {
    public let outcomes: [FileOperationOutcome]
    public let removedFolders: [String]

    public var completedCount: Int { outcomes.lazy.filter { $0.status == .completed }.count }
    public var failedCount: Int { outcomes.lazy.filter { $0.status == .failed }.count }
}

public enum FileOperationError: Error, Equatable, Sendable {
    case unsafeScope
    case symlinkNotAllowed
    case tooManyFiles
    case noEligibleFiles
    case invalidPlan
    case scopeChanged
    case manifestUnavailable
    case system(operation: String, code: Int32)
}

extension FileOperationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeScope: return "Choose a folder you own. No file was changed."
        case .symlinkNotAllowed: return "A symbolic-link folder cannot be organized. No file was changed."
        case .tooManyFiles: return "This folder contains more than 500 eligible files. Narrow the scope first."
        case .noEligibleFiles: return "This folder has no eligible top-level files to organize. No file was changed."
        case .invalidPlan: return "The organize plan contains an unsafe or unknown operation."
        case .scopeChanged: return "The selected folder changed after preview. No operation was started."
        case .manifestUnavailable: return "JBar could not save a private Undo manifest. No operation was started."
        case .system(let operation, let code): return "\(operation) failed (errno \(code))."
        }
    }
}

public enum FileOperationExecutor {
    public static func preview(scope: OrganizeScopeSnapshot, summary: String,
                               operations: [ProposedFileOperation]) throws -> FileOperationPreview {
        try validateScope(scope)
        let byID = Dictionary(uniqueKeysWithValues: scope.files.map { ($0.id, $0) })
        guard operations.count <= OrganizeScopeSnapshot.maximumFiles,
              Set(operations.map(\.sourceID)).count == operations.count,
              operations.allSatisfy({ byID[$0.sourceID] != nil }) else {
            throw FileOperationError.invalidPlan
        }

        var entries: [FileOperationPreviewEntry] = []
        var folders = Set<String>()
        for operation in operations {
            guard let source = byID[operation.sourceID],
                  validOptionalName(operation.destinationFolderName),
                  validOptionalName(operation.newName),
                  operation.destinationFolderName != nil || operation.newName != nil else {
                throw FileOperationError.invalidPlan
            }
            let destinationName = operation.newName ?? source.name
            let relative = operation.destinationFolderName.map { "\($0)/\(destinationName)" }
                ?? destinationName
            var status: FileOperationPreviewStatus = .ready
            var explanation = "Ready"
            if !matchesCurrentIdentity(source) {
                status = .changedSinceSnapshot
                explanation = "Source changed since the folder snapshot"
            } else if operation.destinationFolderName == nil, destinationName == source.name {
                status = .invalid
                explanation = "No change proposed"
            } else {
                let folderURL = operation.destinationFolderName.map {
                    URL(fileURLWithPath: scope.rootPath, isDirectory: true)
                        .appendingPathComponent($0, isDirectory: true)
                }
                if let folderURL, FileManager.default.fileExists(atPath: folderURL.path) {
                    if !isSafeDestinationFolder(folderURL, rootIdentity: scope.rootIdentity) {
                        status = .invalid
                        explanation = "Destination folder is unsafe or is on another volume"
                    }
                } else if let folder = operation.destinationFolderName {
                    folders.insert(folder)
                }
                let destination = (folderURL
                    ?? URL(fileURLWithPath: scope.rootPath, isDirectory: true))
                    .appendingPathComponent(destinationName)
                if status == .ready, FileManager.default.fileExists(atPath: destination.path) {
                    status = .collision
                    explanation = "Destination already exists; overwrite is never offered"
                }
            }
            entries.append(FileOperationPreviewEntry(source: source,
                                                     destinationFolderName: operation.destinationFolderName,
                                                     destinationName: destinationName,
                                                     destinationRelativePath: relative,
                                                     status: status, explanation: explanation))
        }
        let created = folders.filter { folder in
            entries.contains { $0.isExecutable && $0.destinationFolderName == folder }
        }.sorted()
        return FileOperationPreview(batchID: UUID(), scope: scope, summary: summary,
                                    entries: entries, foldersToCreate: created)
    }

    public static func commit(_ preview: FileOperationPreview,
                              manifestURL: URL) throws -> FileOperationBatchResult {
        try validateScope(preview.scope)
        var manifest = FileOperationManifest(batchID: preview.batchID, scope: preview.scope)
        do {
            try persist(manifest, to: manifestURL)
        } catch {
            throw FileOperationError.manifestUnavailable
        }

        let rootFD = try openRoot(preview.scope)
        defer { _ = Darwin.close(rootFD) }
        var destinationFDs: [String: Int32] = [:]
        defer { destinationFDs.values.forEach { _ = Darwin.close($0) } }
        var outcomes: [FileOperationOutcome] = []

        for entry in preview.entries {
            guard entry.isExecutable else {
                outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                      destinationRelativePath: entry.destinationRelativePath,
                                                      status: .skipped,
                                                      explanation: entry.explanation))
                continue
            }
            guard matchesCurrentIdentity(entry.source) else {
                outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                      destinationRelativePath: entry.destinationRelativePath,
                                                      status: .skipped,
                                                      explanation: "Source changed since preview"))
                continue
            }
            do {
                let destinationFD: Int32
                if let folder = entry.destinationFolderName {
                    if let existing = destinationFDs[folder] {
                        destinationFD = existing
                    } else {
                        let made = folder.withCString { mkdirat(rootFD, $0, 0o700) }
                        if made == 0 {
                            manifest.createdFolders.append(folder)
                            do {
                                try persist(manifest, to: manifestURL)
                            } catch {
                                manifest.createdFolders.removeLast()
                                _ = folder.withCString { unlinkat(rootFD, $0, AT_REMOVEDIR) }
                                throw error
                            }
                        } else if errno != EEXIST {
                            throw FileOperationError.system(operation: "create destination folder", code: errno)
                        }
                        let fd = folder.withCString {
                            openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                        }
                        guard fd >= 0 else {
                            throw FileOperationError.system(operation: "open destination folder", code: errno)
                        }
                        var folderInfo = stat()
                        guard fstat(fd, &folderInfo) == 0,
                              folderInfo.st_uid == getuid(),
                              UInt64(folderInfo.st_dev) == preview.scope.rootIdentity.device else {
                            _ = Darwin.close(fd)
                            throw FileOperationError.unsafeScope
                        }
                        destinationFDs[folder] = fd
                        destinationFD = fd
                    }
                } else {
                    destinationFD = rootFD
                }

                let completedMove = CompletedFileMove(
                    sourceID: entry.source.id, originalName: entry.source.name,
                    destinationFolderName: entry.destinationFolderName,
                    destinationName: entry.destinationName,
                    destinationIdentity: entry.source.identity
                )
                manifest.completedMoves.append(completedMove)
                do {
                    try persist(manifest, to: manifestURL)
                } catch {
                    manifest.completedMoves.removeLast()
                    throw error
                }
                let renamed = entry.source.name.withCString { sourceName in
                    entry.destinationName.withCString { destinationName in
                        renameatx_np(rootFD, sourceName, destinationFD, destinationName,
                                     UInt32(RENAME_EXCL))
                    }
                }
                guard renamed == 0 else {
                    let code = errno
                    manifest.completedMoves.removeLast()
                    try? persist(manifest, to: manifestURL)
                    let explanation = code == EEXIST
                        ? "Destination appeared after preview; skipped without overwrite"
                        : "Move failed (errno \(code))"
                    outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                          destinationRelativePath: entry.destinationRelativePath,
                                                          status: code == EEXIST ? .skipped : .failed,
                                                          explanation: explanation))
                    continue
                }
                var destinationInfo = stat()
                guard entry.destinationName.withCString({
                    fstatat(destinationFD, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
                }) == 0 else {
                    outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                          destinationRelativePath: entry.destinationRelativePath,
                                                          status: .failed,
                                                          explanation: "Moved file could not be revalidated"))
                    continue
                }
                guard OrganizeFileIdentity(destinationInfo) == entry.source.identity else {
                    outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                          destinationRelativePath: entry.destinationRelativePath,
                                                          status: .failed,
                                                          explanation: "Moved file identity changed unexpectedly; Undo remains available"))
                    continue
                }
                outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                      destinationRelativePath: entry.destinationRelativePath,
                                                      status: .completed,
                                                      explanation: "Moved"))
            } catch {
                outcomes.append(FileOperationOutcome(sourceName: entry.source.name,
                                                      destinationRelativePath: entry.destinationRelativePath,
                                                      status: .failed,
                                                      explanation: (error as? LocalizedError)?.errorDescription
                                                        ?? "Move failed"))
            }
        }
        return FileOperationBatchResult(outcomes: outcomes, manifest: manifest,
                                        manifestURL: manifestURL)
    }

    public static func undo(_ manifest: FileOperationManifest) throws -> FileOperationUndoResult {
        try validateManifest(manifest)
        let scope = OrganizeScopeSnapshot(scopeID: manifest.scopeID, rootPath: manifest.rootPath,
                                          rootIdentity: manifest.rootIdentity, files: [],
                                          excludedEntries: 0)
        try validateScope(scope)
        let rootFD = try openRoot(scope)
        defer { _ = Darwin.close(rootFD) }
        var destinationFDs: [String: Int32] = [:]
        defer { destinationFDs.values.forEach { _ = Darwin.close($0) } }
        var outcomes: [FileOperationOutcome] = []

        for move in manifest.completedMoves.reversed() {
            let sourceFD: Int32
            if let folder = move.destinationFolderName {
                if let existing = destinationFDs[folder] {
                    sourceFD = existing
                } else {
                    let fd = folder.withCString {
                        openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                    guard fd >= 0 else {
                        outcomes.append(FileOperationOutcome(sourceName: move.destinationName,
                                                              destinationRelativePath: move.originalName,
                                                              status: .failed,
                                                              explanation: "Destination folder is missing or unsafe"))
                        continue
                    }
                    destinationFDs[folder] = fd
                    sourceFD = fd
                }
            } else {
                sourceFD = rootFD
            }
            var current = stat()
            guard move.destinationName.withCString({
                fstatat(sourceFD, $0, &current, AT_SYMLINK_NOFOLLOW)
            }) == 0, OrganizeFileIdentity(current) == move.destinationIdentity else {
                outcomes.append(FileOperationOutcome(sourceName: move.destinationName,
                                                      destinationRelativePath: move.originalName,
                                                      status: .failed,
                                                      explanation: "Moved file changed after apply"))
                continue
            }
            let result = move.destinationName.withCString { currentName in
                move.originalName.withCString { originalName in
                    renameatx_np(sourceFD, currentName, rootFD, originalName, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                outcomes.append(FileOperationOutcome(sourceName: move.destinationName,
                                                      destinationRelativePath: move.originalName,
                                                      status: .completed, explanation: "Restored"))
            } else {
                outcomes.append(FileOperationOutcome(sourceName: move.destinationName,
                                                      destinationRelativePath: move.originalName,
                                                      status: .failed,
                                                      explanation: errno == EEXIST
                                                        ? "Original path is occupied; nothing was overwritten"
                                                        : "Undo failed (errno \(errno))"))
            }
        }
        destinationFDs.values.forEach { _ = Darwin.close($0) }
        destinationFDs.removeAll()
        var removedFolders: [String] = []
        for folder in manifest.createdFolders.reversed() {
            if folder.withCString({ unlinkat(rootFD, $0, AT_REMOVEDIR) }) == 0 {
                removedFolders.append(folder)
            }
        }
        return FileOperationUndoResult(outcomes: outcomes, removedFolders: removedFolders)
    }

    public static func loadManifest(from url: URL) throws -> FileOperationManifest {
        let decoder = JSONDecoder()
        guard let data = try SecureFileIO.readRegularFile(at: url, maxBytes: 2 * 1_024 * 1_024),
              let manifest = try? decoder.decode(FileOperationManifest.self, from: data) else {
            throw FileOperationError.manifestUnavailable
        }
        try validateManifest(manifest)
        return manifest
    }

    private static func persist(_ manifest: FileOperationManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= 2 * 1_024 * 1_024 else { throw FileOperationError.manifestUnavailable }
        try SecureFileIO.writeAtomicallyOwnerOnly(data, to: url, enforcePrivateDirectory: true)
    }

    fileprivate static func fileInfo(atPath path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw FileOperationError.system(operation: "inspect file", code: errno)
        }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw FileOperationError.symlinkNotAllowed }
        return info
    }

    private static func validateScope(_ scope: OrganizeScopeSnapshot) throws {
        let info = try fileInfo(atPath: scope.rootPath)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              OrganizeFileIdentity(info).device == scope.rootIdentity.device,
              OrganizeFileIdentity(info).inode == scope.rootIdentity.inode else {
            throw FileOperationError.scopeChanged
        }
    }

    private static func validateManifest(_ manifest: FileOperationManifest) throws {
        guard manifest.schemaVersion == 1,
              manifest.completedMoves.count <= OrganizeScopeSnapshot.maximumFiles,
              manifest.createdFolders.count <= OrganizeScopeSnapshot.maximumFiles,
              Set(manifest.completedMoves.map(\.sourceID)).count == manifest.completedMoves.count,
              Set(manifest.completedMoves.map(\.originalName)).count == manifest.completedMoves.count,
              Set(manifest.createdFolders).count == manifest.createdFolders.count,
              manifest.createdFolders.allSatisfy({ validOptionalName($0) }),
              manifest.completedMoves.allSatisfy({ move in
                  validOptionalName(move.originalName)
                      && validOptionalName(move.destinationFolderName)
                      && validOptionalName(move.destinationName)
              }) else {
            throw FileOperationError.invalidPlan
        }
        let destinations = manifest.completedMoves.map { move in
            "\(move.destinationFolderName ?? "\u{0}")/\(move.destinationName)"
        }
        guard Set(destinations).count == destinations.count else {
            throw FileOperationError.invalidPlan
        }
    }

    private static func openRoot(_ scope: OrganizeScopeSnapshot) throws -> Int32 {
        let fd = Darwin.open(scope.rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw FileOperationError.system(operation: "open scope", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              UInt64(info.st_dev) == scope.rootIdentity.device,
              UInt64(info.st_ino) == scope.rootIdentity.inode,
              info.st_uid == getuid() else {
            let code = errno
            _ = Darwin.close(fd)
            throw FileOperationError.system(operation: "validate scope", code: code)
        }
        return fd
    }

    private static func matchesCurrentIdentity(_ reference: ScopedFileReference) -> Bool {
        guard let current = try? fileInfo(atPath: reference.canonicalPath),
              current.st_mode & S_IFMT == S_IFREG, current.st_uid == getuid(), current.st_nlink == 1 else {
            return false
        }
        return OrganizeFileIdentity(current) == reference.identity
    }

    private static func validOptionalName(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              SafetyLimits.isSafePathComponent(value,
                                               maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes),
              !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.properties.isDefaultIgnorableCodePoint }) else {
            return false
        }
        return true
    }

    private static func isSafeDestinationFolder(_ url: URL,
                                                rootIdentity: OrganizeFileIdentity) -> Bool {
        guard let info = try? fileInfo(atPath: url.path) else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && UInt64(info.st_dev) == rootIdentity.device
    }
}
