import Darwin
import Foundation

/// Bounded, symlink-safe persistence for JBar-owned state.
///
/// Reads classify and size-check the exact descriptor that is consumed, then stop after `maxBytes + 1`
/// even if the file grows concurrently. Writes create a mode-0600 temporary file inside an opened,
/// non-symlink parent directory, sync it, and atomically replace the destination with `renameat`.
/// The JBar-owned parent is always tightened to 0700, independent of the caller's umask.
enum SecureFileIO {
    enum Failure: Error, LocalizedError, Equatable {
        case invalidLimit
        case invalidPath
        case invalidFileName
        case invalidContents
        case unsafeDirectory
        case notRegularFile
        case tooLarge(maxBytes: Int)
        case system(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .invalidLimit: return "invalid file-size limit"
            case .invalidPath: return "invalid state-file path"
            case .invalidFileName: return "invalid state-file name"
            case .invalidContents: return "invalid state-file header"
            case .unsafeDirectory: return "state directory is not a regular directory"
            case .notRegularFile: return "state path is not a regular file"
            case .tooLarge(let maxBytes): return "state file is too large (maximum \(maxBytes) bytes)"
            case .system(let operation, let code): return "\(operation) failed (errno \(code))"
            }
        }
    }

    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600
    private static let readChunkBytes = 64 * 1_024

    /// Validate the exact Foundation path string before passing it to a NUL-terminated POSIX API.
    /// `URL` normally percent-encodes embedded NULs, but this boundary is intentionally independent
    /// of that implementation detail because these helpers also back public custom persistence URLs.
    private static func validatedFilePath(_ url: URL) throws -> (path: String, name: String) {
        guard url.isFileURL else { throw Failure.invalidPath }
        let path = url.path
        guard SafetyLimits.isSafeAbsolutePath(path),
              !SafetyLimits.containsNULByte(path) else { throw Failure.invalidPath }
        let fileName = url.lastPathComponent
        guard SafetyLimits.isSafePathComponent(fileName,
                                               maxUTF8Bytes: SafetyLimits.maxNameUTF8Bytes) else {
            throw Failure.invalidFileName
        }
        return (path, fileName)
    }

    /// Return nil only when the path does not exist. Every other unsafe or failed read throws.
    static func readRegularFile(at url: URL, maxBytes: Int) throws -> Data? {
        try readRegularFile(at: url, maxBytes: maxBytes, preflight: nil)
    }

    /// Read relative to a caller-held, validated parent. The descriptor is borrowed synchronously;
    /// replacing the directory path after validation cannot redirect this operation.
    static func readRegularFile(at url: URL, maxBytes: Int,
                                parentDirectoryDescriptor: Int32) throws -> Data? {
        try readRegularFile(at: url, maxBytes: maxBytes, preflight: nil,
                            parentDirectoryDescriptor: parentDirectoryDescriptor)
    }

    /// Variant for self-describing formats. It reads exactly `byteCount` bytes from the same validated
    /// descriptor first; the callback may reject the header or return a tighter whole-file limit.
    /// No capacity proportional to the on-disk size is reserved until this preflight succeeds.
    static func readRegularFile(at url: URL, maxBytes: Int, preflightByteCount: Int,
                                limitAfterPreflight: @escaping (Data) -> Int?) throws -> Data? {
        guard preflightByteCount > 0, preflightByteCount <= maxBytes else { throw Failure.invalidLimit }
        return try readRegularFile(at: url, maxBytes: maxBytes,
                                   preflight: (preflightByteCount, limitAfterPreflight))
    }

    static func readRegularFile(at url: URL, maxBytes: Int, parentDirectoryDescriptor: Int32,
                                preflightByteCount: Int,
                                limitAfterPreflight: @escaping (Data) -> Int?) throws -> Data? {
        guard preflightByteCount > 0, preflightByteCount <= maxBytes else { throw Failure.invalidLimit }
        return try readRegularFile(at: url, maxBytes: maxBytes,
                                   preflight: (preflightByteCount, limitAfterPreflight),
                                   parentDirectoryDescriptor: parentDirectoryDescriptor)
    }

    private static func readRegularFile(at url: URL, maxBytes: Int,
                                        preflight: (byteCount: Int, limit: (Data) -> Int?)?,
                                        parentDirectoryDescriptor: Int32? = nil) throws -> Data? {
        guard maxBytes >= 0 else { throw Failure.invalidLimit }
        let validated = try validatedFilePath(url)
        // O_NONBLOCK is inert for regular files, but makes FIFOs/devices fail classification
        // immediately instead of hanging before the descriptor can be checked with fstat.
        let fd: Int32
        if let parentDirectoryDescriptor {
            try validateDirectoryDescriptor(parentDirectoryDescriptor)
            fd = validated.name.withCString {
                openat(parentDirectoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        } else {
            fd = Darwin.open(validated.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw Failure.notRegularFile }
            throw Failure.system(operation: "open", code: errno)
        }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.system(operation: "fstat", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard info.st_size >= 0, UInt64(info.st_size) <= UInt64(maxBytes) else {
            throw Failure.tooLarge(maxBytes: maxBytes)
        }

        var result = Data()
        if let preflight {
            result.reserveCapacity(preflight.byteCount)
        } else {
            result.reserveCapacity(Int(info.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: min(readChunkBytes, max(1, maxBytes)))
        var effectiveLimit = maxBytes

        if let preflight {
            while result.count < preflight.byteCount {
                let requested = min(buffer.count, preflight.byteCount - result.count)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(fd, bytes.baseAddress, requested)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system(operation: "read", code: errno)
                }
                if count == 0 { break }
                result.append(contentsOf: buffer[..<count])
            }
            guard result.count == preflight.byteCount,
                  let derived = preflight.limit(result), derived >= result.count else {
                throw Failure.invalidContents
            }
            effectiveLimit = min(maxBytes, derived)
            guard UInt64(info.st_size) <= UInt64(effectiveLimit) else {
                throw Failure.tooLarge(maxBytes: effectiveLimit)
            }
            result.reserveCapacity(Int(info.st_size))
        }

        while true {
            let remaining = effectiveLimit - result.count
            let probeCount = remaining == Int.max ? remaining : remaining + 1
            let requested = min(buffer.count, probeCount)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.system(operation: "read", code: errno)
            }
            if count == 0 { return result }
            guard count <= remaining else { throw Failure.tooLarge(maxBytes: maxBytes) }
            result.append(contentsOf: buffer[..<count])
        }
    }

    /// Open the parent for descriptor-relative I/O. A newly created directory is private; an existing
    /// directory is tightened only when the caller explicitly identifies it as JBar-owned. This avoids
    /// a public `save(to:)` call accidentally chmodding an arbitrary shared directory such as `/tmp`.
    private static func openDirectory(_ url: URL, enforcePrivateMode: Bool) throws -> Int32 {
        guard url.isFileURL, SafetyLimits.isSafeAbsolutePath(url.path),
              !SafetyLimits.containsNULByte(url.path) else { throw Failure.invalidPath }
        var existing = stat()
        let existedBefore = lstat(url.path, &existing) == 0
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: directoryMode)])
        } catch {
            let ns = error as NSError
            throw Failure.system(operation: "create directory", code: Int32(ns.code))
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ELOOP || errno == ENOTDIR { throw Failure.unsafeDirectory }
            throw Failure.system(operation: "open directory", code: errno)
        }
        guard (!enforcePrivateMode && existedBefore) || fchmod(fd, directoryMode) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw Failure.system(operation: "chmod directory", code: code)
        }
        return fd
    }

    /// Durable owner-only atomic replacement. The old destination remains intact until `renameat` succeeds.
    static func writeAtomicallyOwnerOnly(_ data: Data, to url: URL,
                                         enforcePrivateDirectory: Bool = false) throws {
        let validated = try validatedFilePath(url)
        let fileName = validated.name
        let dirFD = try openDirectory(url.deletingLastPathComponent(),
                                      enforcePrivateMode: enforcePrivateDirectory)
        defer { _ = Darwin.close(dirFD) }
        try writeAtomicallyOwnerOnly(data, fileName: fileName, directoryDescriptor: dirFD)
    }

    /// Borrow a previously validated parent for the complete atomic write, preserving its identity.
    static func writeAtomicallyOwnerOnly(_ data: Data, to url: URL,
                                         parentDirectoryDescriptor: Int32) throws {
        let validated = try validatedFilePath(url)
        try writeAtomicallyOwnerOnly(data, fileName: validated.name,
                                     directoryDescriptor: parentDirectoryDescriptor)
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw Failure.system(operation: "fstat directory", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeDirectory }
    }

    private static func writeAtomicallyOwnerOnly(_ data: Data, fileName: String,
                                                 directoryDescriptor dirFD: Int32) throws {
        try validateDirectoryDescriptor(dirFD)

        let temporaryName = ".jbar-write-\(getpid())-\(UUID().uuidString)"
        let fd = temporaryName.withCString { name in
            openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, fileMode)
        }
        guard fd >= 0 else { throw Failure.system(operation: "create temporary file", code: errno) }
        var temporaryExists = true
        defer {
            _ = Darwin.close(fd)
            if temporaryExists {
                temporaryName.withCString { _ = unlinkat(dirFD, $0, 0) }
            }
        }

        guard fchmod(fd, fileMode) == 0 else {
            throw Failure.system(operation: "chmod temporary file", code: errno)
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system(operation: "write", code: errno)
                }
                guard written > 0 else { throw Failure.system(operation: "write", code: EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw Failure.system(operation: "sync file", code: errno) }

        let renamed = temporaryName.withCString { temporary in
            fileName.withCString { destination in
                renameat(dirFD, temporary, dirFD, destination)
            }
        }
        guard renamed == 0 else { throw Failure.system(operation: "replace state file", code: errno) }
        temporaryExists = false
        guard fsync(dirFD) == 0 else { throw Failure.system(operation: "sync directory", code: errno) }
    }
}
