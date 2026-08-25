import Darwin
import Foundation

/// One local-index hit selected for a copy-only organize batch. Paths never leave JBarCore.
public struct GlobalCopySourceInput: Equatable, Sendable {
    public let path: String
    public let parentDisplay: String

    public init(path: String, parentDisplay: String) {
        self.path = path
        self.parentDisplay = parentDisplay
    }
}

public struct CopySourceReference: Equatable, Sendable {
    public let id: UUID
    public let scopeID: String
    public let canonicalPath: String
    public let parentDisplay: String
    public let name: String
    public let identity: OrganizeFileIdentity
    public let modifiedAt: Date?
}

/// A bounded snapshot of exact files returned by the complete local-index search plus one explicit
/// destination directory. It never enumerates the destination or the wider filesystem.
public struct GlobalCopyScopeSnapshot: Sendable {
    public static let maximumFiles = AssistedSearchRequest.maximumResults

    public let scopeID: String
    public let destinationRootPath: String
    public let destinationRootIdentity: OrganizeFileIdentity
    public let files: [CopySourceReference]

    public static func capture(inputs: [GlobalCopySourceInput], destinationFolder: URL,
                               maximumFiles: Int = maximumFiles) throws -> Self {
        let boundedMaximum = min(max(1, maximumFiles), Self.maximumFiles)
        guard !inputs.isEmpty else { throw CopyOperationError.noEligibleFiles }
        guard inputs.count <= boundedMaximum else { throw CopyOperationError.tooManyFiles }
        let root = try CopyOperationExecutor.canonicalOwnedDirectory(destinationFolder)
        let rootInfo = try CopyOperationExecutor.fileInfo(atPath: root.path)
        let scopeID = "indexed-copy-\(UUID().uuidString.lowercased())"
        var seenPaths = Set<String>()
        var files: [CopySourceReference] = []
        files.reserveCapacity(inputs.count)

        for input in inputs {
            guard input.path.hasPrefix("/"), !input.path.utf8.contains(0) else {
                throw CopyOperationError.unsafeSource
            }
            let standardized = URL(fileURLWithPath: input.path).standardizedFileURL
            _ = try CopyOperationExecutor.fileInfo(atPath: standardized.path)
            let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
            let info = try CopyOperationExecutor.fileInfo(atPath: canonical.path)
            let name = canonical.lastPathComponent
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  CopyOperationExecutor.validName(name), seenPaths.insert(canonical.path).inserted else {
                throw CopyOperationError.unsafeSource
            }
            let modifiedAt = info.st_mtimespec.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                : nil
            files.append(CopySourceReference(id: UUID(), scopeID: scopeID,
                                             canonicalPath: canonical.path,
                                             parentDisplay: input.parentDisplay,
                                             name: name,
                                             identity: OrganizeFileIdentity(info),
                                             modifiedAt: modifiedAt))
        }
        return Self(scopeID: scopeID, destinationRootPath: root.path,
                    destinationRootIdentity: OrganizeFileIdentity(rootInfo), files: files)
    }
}

public enum CopyPreviewStatus: String, Equatable, Sendable {
    case ready
    case collision
    case changedSinceSnapshot
    case invalid
}

public struct CopyPreviewEntry: Equatable, Sendable {
    public let source: CopySourceReference
    public let destinationFolderName: String?
    public let destinationName: String
    public let destinationRelativePath: String
    public let status: CopyPreviewStatus
    public let explanation: String

    public var isExecutable: Bool { status == .ready }
}

public struct CopyOperationPreview: Sendable {
    public let batchID: UUID
    public let scope: GlobalCopyScopeSnapshot
    public let summary: String
    public let entries: [CopyPreviewEntry]
    public let foldersToCreate: [String]

    public var executableCount: Int { entries.lazy.filter(\.isExecutable).count }
    public var collisionCount: Int { entries.lazy.filter { $0.status == .collision }.count }
    public var skippedCount: Int { entries.count - executableCount }
}

public struct CopyOperationBatchResult: Sendable {
    public let outcomes: [FileOperationOutcome]

    public var completedCount: Int { outcomes.lazy.filter { $0.status == .completed }.count }
    public var failedCount: Int { outcomes.lazy.filter { $0.status == .failed }.count }
    public var skippedCount: Int { outcomes.lazy.filter { $0.status == .skipped }.count }
}

public enum CopyOperationError: Error, Equatable, Sendable {
    case unsafeDestination
    case unsafeSource
    case symlinkNotAllowed
    case tooManyFiles
    case noEligibleFiles
    case invalidPlan
    case destinationChanged
    case sourceChanged
    case destinationExists
    case system(operation: String, code: Int32)
}

extension CopyOperationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeDestination:
            return "Choose a destination folder you own. Originals were not changed."
        case .unsafeSource:
            return "A matched item is not a safe, owner-only regular file. Narrow the request and try again."
        case .symlinkNotAllowed:
            return "Symbolic links are not allowed in a copy batch. Originals were not changed."
        case .tooManyFiles:
            return "More than 40 files matched. Narrow the request so JBar can show a complete preview."
        case .noEligibleFiles:
            return "No eligible indexed file matched this request."
        case .invalidPlan:
            return "The copy plan contains an unsafe, duplicate, or unknown operation."
        case .destinationChanged:
            return "The copy destination changed after preview. No copy was started."
        case .sourceChanged:
            return "A source changed after preview and was skipped."
        case .destinationExists:
            return "The destination already exists and was skipped without overwrite."
        case .system(let operation, let code):
            return "\(operation) failed (errno \(code))."
        }
    }
}

/// Copy-only native execution. Source files are opened read-only; destinations are created with
/// O_EXCL, so a pre-existing or racing destination can never be replaced.
public enum CopyOperationExecutor {
    public static func preview(scope: GlobalCopyScopeSnapshot, summary: String,
                               operations: [ProposedFileOperation]) throws -> CopyOperationPreview {
        try validateDestination(scope)
        let byID = Dictionary(uniqueKeysWithValues: scope.files.map { ($0.id, $0) })
        guard operations.count <= GlobalCopyScopeSnapshot.maximumFiles,
              Set(operations.map(\.sourceID)).count == operations.count,
              operations.allSatisfy({ byID[$0.sourceID] != nil }) else {
            throw CopyOperationError.invalidPlan
        }

        var entries: [CopyPreviewEntry] = []
        var folders = Set<String>()
        var plannedDestinations = Set<String>()
        let plannedSourceIDs = Set(operations.map(\.sourceID))
        for operation in operations {
            guard let source = byID[operation.sourceID],
                  validOptionalName(operation.destinationFolderName),
                  validOptionalName(operation.newName),
                  operation.destinationFolderName != nil || operation.newName != nil else {
                throw CopyOperationError.invalidPlan
            }
            let destinationName = operation.newName ?? source.name
            let relative = operation.destinationFolderName.map { "\($0)/\(destinationName)" }
                ?? destinationName
            var status: CopyPreviewStatus = .ready
            var explanation = "Ready to copy; original stays unchanged"

            if !matchesCurrentIdentity(source) {
                status = .changedSinceSnapshot
                explanation = "Source changed since the local-index result was captured"
            } else if !plannedDestinations.insert(relative).inserted {
                status = .collision
                explanation = "Another planned copy uses this destination"
            } else if let folder = operation.destinationFolderName {
                let folderURL = URL(fileURLWithPath: scope.destinationRootPath, isDirectory: true)
                    .appendingPathComponent(folder, isDirectory: true)
                if pathExists(folderURL.path) {
                    if !isOwnedDirectory(folderURL) {
                        status = .invalid
                        explanation = "Destination folder is unsafe or is a symbolic link"
                    }
                } else {
                    folders.insert(folder)
                }
            }

            let destinationRoot = operation.destinationFolderName.map {
                URL(fileURLWithPath: scope.destinationRootPath, isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
            } ?? URL(fileURLWithPath: scope.destinationRootPath, isDirectory: true)
            let destination = destinationRoot.appendingPathComponent(destinationName)
            if status == .ready, pathExists(destination.path) {
                status = .collision
                explanation = "Destination already exists; overwrite is never offered"
            }
            entries.append(CopyPreviewEntry(source: source,
                                            destinationFolderName: operation.destinationFolderName,
                                            destinationName: destinationName,
                                            destinationRelativePath: relative,
                                            status: status, explanation: explanation))
        }
        for source in scope.files where !plannedSourceIDs.contains(source.id) {
            entries.append(CopyPreviewEntry(source: source, destinationFolderName: nil,
                                            destinationName: source.name,
                                            destinationRelativePath: "Not copied",
                                            status: .invalid,
                                            explanation: "Planner did not include this matched file"))
        }
        let created = folders.filter { folder in
            entries.contains { $0.isExecutable && $0.destinationFolderName == folder }
        }.sorted()
        return CopyOperationPreview(batchID: UUID(), scope: scope, summary: summary,
                                    entries: entries, foldersToCreate: created)
    }

    public static func commit(_ preview: CopyOperationPreview) throws -> CopyOperationBatchResult {
        try validateDestination(preview.scope)
        let rootFD = try openDestinationRoot(preview.scope)
        defer { _ = Darwin.close(rootFD) }
        var destinationFDs: [String: Int32] = [:]
        defer { destinationFDs.values.forEach { _ = Darwin.close($0) } }
        var outcomes: [FileOperationOutcome] = []
        outcomes.reserveCapacity(preview.entries.count)

        for entry in preview.entries {
            guard entry.isExecutable else {
                outcomes.append(outcome(entry, status: .skipped, explanation: entry.explanation))
                continue
            }
            guard matchesCurrentIdentity(entry.source) else {
                outcomes.append(outcome(entry, status: .skipped,
                                        explanation: "Source changed since preview"))
                continue
            }
            do {
                let destinationFD = try destinationDirectoryFD(for: entry, rootFD: rootFD,
                                                               cached: &destinationFDs)
                try copy(entry.source, toDirectoryFD: destinationFD, name: entry.destinationName)
                outcomes.append(outcome(entry, status: .completed,
                                        explanation: "Copied; original unchanged"))
            } catch CopyOperationError.destinationExists {
                outcomes.append(outcome(entry, status: .skipped,
                                        explanation: "Destination appeared after preview; skipped without overwrite"))
            } catch CopyOperationError.sourceChanged {
                outcomes.append(outcome(entry, status: .skipped,
                                        explanation: "Source changed during copy; incomplete copy was removed"))
            } catch {
                outcomes.append(outcome(entry, status: .failed,
                                        explanation: (error as? LocalizedError)?.errorDescription
                                            ?? "Copy failed safely"))
            }
        }
        return CopyOperationBatchResult(outcomes: outcomes)
    }

    private static func copy(_ source: CopySourceReference, toDirectoryFD destinationDirectoryFD: Int32,
                             name: String) throws {
        let sourceFD = Darwin.open(source.canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw CopyOperationError.system(operation: "open source", code: errno)
        }
        defer { _ = Darwin.close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0,
              sourceInfo.st_mode & S_IFMT == S_IFREG, sourceInfo.st_uid == getuid(),
              sourceInfo.st_nlink == 1, OrganizeFileIdentity(sourceInfo) == source.identity else {
            throw CopyOperationError.sourceChanged
        }

        let destinationFD = name.withCString {
            openat(destinationDirectoryFD, $0,
                   O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard destinationFD >= 0 else {
            if errno == EEXIST { throw CopyOperationError.destinationExists }
            throw CopyOperationError.system(operation: "create destination", code: errno)
        }
        var keepDestination = false
        defer {
            _ = Darwin.close(destinationFD)
            if !keepDestination {
                _ = name.withCString { unlinkat(destinationDirectoryFD, $0, 0) }
            }
        }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1_048_576,
                                                             alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }
        while true {
            let amount = Darwin.read(sourceFD, buffer.baseAddress, buffer.count)
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw CopyOperationError.system(operation: "read source", code: errno)
            }
            var written = 0
            while written < amount {
                let count = Darwin.write(destinationFD, buffer.baseAddress?.advanced(by: written),
                                         amount - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CopyOperationError.system(operation: "write destination", code: errno)
                }
                if count == 0 {
                    throw CopyOperationError.system(operation: "write destination", code: EIO)
                }
                written += count
            }
        }
        var finalSourceInfo = stat()
        guard fstat(sourceFD, &finalSourceInfo) == 0,
              OrganizeFileIdentity(finalSourceInfo) == source.identity,
              matchesCurrentIdentity(source) else {
            throw CopyOperationError.sourceChanged
        }
        guard fsync(destinationFD) == 0 else {
            throw CopyOperationError.system(operation: "sync destination", code: errno)
        }
        keepDestination = true
    }

    private static func destinationDirectoryFD(for entry: CopyPreviewEntry, rootFD: Int32,
                                               cached: inout [String: Int32]) throws -> Int32 {
        guard let folder = entry.destinationFolderName else { return rootFD }
        if let existing = cached[folder] { return existing }
        let made = folder.withCString { mkdirat(rootFD, $0, 0o700) }
        if made != 0, errno != EEXIST {
            throw CopyOperationError.system(operation: "create destination folder", code: errno)
        }
        let fd = folder.withCString {
            openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw CopyOperationError.system(operation: "open destination folder", code: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            _ = Darwin.close(fd)
            throw CopyOperationError.unsafeDestination
        }
        cached[folder] = fd
        return fd
    }

    private static func outcome(_ entry: CopyPreviewEntry, status: FileOperationOutcomeStatus,
                                explanation: String) -> FileOperationOutcome {
        FileOperationOutcome(sourceName: entry.source.name,
                             destinationRelativePath: entry.destinationRelativePath,
                             status: status, explanation: explanation)
    }

    fileprivate static func canonicalOwnedDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw CopyOperationError.unsafeDestination
        }
        let standardized = url.standardizedFileURL
        _ = try fileInfo(atPath: standardized.path)
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        let info = try fileInfo(atPath: canonical.path)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CopyOperationError.unsafeDestination
        }
        return canonical
    }

    private static func validateDestination(_ scope: GlobalCopyScopeSnapshot) throws {
        let info = try fileInfo(atPath: scope.destinationRootPath)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              OrganizeFileIdentity(info).device == scope.destinationRootIdentity.device,
              OrganizeFileIdentity(info).inode == scope.destinationRootIdentity.inode else {
            throw CopyOperationError.destinationChanged
        }
    }

    private static func openDestinationRoot(_ scope: GlobalCopyScopeSnapshot) throws -> Int32 {
        let fd = Darwin.open(scope.destinationRootPath,
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw CopyOperationError.system(operation: "open copy destination", code: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              UInt64(info.st_dev) == scope.destinationRootIdentity.device,
              UInt64(info.st_ino) == scope.destinationRootIdentity.inode else {
            _ = Darwin.close(fd)
            throw CopyOperationError.destinationChanged
        }
        return fd
    }

    private static func matchesCurrentIdentity(_ reference: CopySourceReference) -> Bool {
        guard let info = try? fileInfo(atPath: reference.canonicalPath),
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            return false
        }
        return OrganizeFileIdentity(info) == reference.identity
    }

    fileprivate static func fileInfo(atPath path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw CopyOperationError.system(operation: "inspect file", code: errno)
        }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw CopyOperationError.symlinkNotAllowed }
        return info
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        guard let info = try? fileInfo(atPath: url.path) else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    private static func validOptionalName(_ value: String?) -> Bool {
        value == nil || validName(value!)
    }

    fileprivate static func validName(_ value: String) -> Bool {
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
}
