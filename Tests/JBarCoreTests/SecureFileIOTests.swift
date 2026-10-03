import Darwin
import Foundation
import XCTest
@testable import JBarCore

final class SecureFileIOTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/core-review-tests", isDirectory: true)
            .appendingPathComponent("jbar-secure-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.path)
        return info.st_mode & 0o777
    }

    func testBorrowedParentDescriptorPinsReadsAndWritesAcrossPathReplacement() throws {
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        let attacker = root.appendingPathComponent("attacker", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        let original = parent.appendingPathComponent("state")
        let attackerFile = attacker.appendingPathComponent("state")
        try Data("original".utf8).write(to: original)
        try Data("attacker".utf8).write(to: attackerFile)
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        try FileManager.default.moveItem(at: parent, to: parked)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: attacker)

        XCTAssertEqual(try SecureFileIO.readRegularFile(at: original, maxBytes: 8,
                                                       parentDirectoryDescriptor: descriptor), Data("original".utf8))
        try SecureFileIO.writeAtomicallyOwnerOnly(Data("new".utf8), to: original,
                                                 parentDirectoryDescriptor: descriptor)
        XCTAssertEqual(try Data(contentsOf: parked.appendingPathComponent("state")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: attackerFile), Data("attacker".utf8))
        XCTAssertEqual(try permissions(parked.appendingPathComponent("state")), 0o600)
    }

    func testBorrowedDescriptorRejectsNonDirectoryAndFinalSymlink() throws {
        let file = root.appendingPathComponent("regular")
        try Data("original".utf8).write(to: file)
        let fileDescriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        defer { _ = Darwin.close(fileDescriptor) }
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: file, maxBytes: 8,
                                                             parentDirectoryDescriptor: fileDescriptor))
        XCTAssertThrowsError(try SecureFileIO.writeAtomicallyOwnerOnly(Data(), to: file,
                                                                       parentDirectoryDescriptor: fileDescriptor))
        let directoryDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { _ = Darwin.close(directoryDescriptor) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: link, maxBytes: 8,
                                                             parentDirectoryDescriptor: directoryDescriptor))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testBorrowedDescriptorPreservesHeaderPreflightAndGrowthLimit() throws {
        let file = root.appendingPathComponent("state")
        try Data("header-body".utf8).write(to: file)
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(
            at: file, maxBytes: 32, parentDirectoryDescriptor: descriptor,
            preflightByteCount: 6, limitAfterPreflight: { header in
                XCTAssertEqual(header, Data("header".utf8))
                return 6
            }
        )) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .tooLarge(maxBytes: 6))
        }
    }

    func testBoundedReadUsesTheOpenedRegularFileAndRejectsSymlinks() throws {
        let file = root.appendingPathComponent("state")
        try Data("1234".utf8).write(to: file)
        XCTAssertEqual(try SecureFileIO.readRegularFile(at: file, maxBytes: 4), Data("1234".utf8))
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: file, maxBytes: 3)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .tooLarge(maxBytes: 3))
        }
        XCTAssertNil(try SecureFileIO.readRegularFile(at: root.appendingPathComponent("missing"), maxBytes: 4))

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: link, maxBytes: 4)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .notRegularFile)
        }
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: root, maxBytes: 4)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .notRegularFile)
        }
    }

    func testReadAndWriteRejectNonFileOrUnsafePathsBeforePOSIXIO() throws {
        let victim = root.appendingPathComponent("victim")
        try Data("original".utf8).write(to: victim)

        let nonFile = URL(string: "https://example.invalid/state")!
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: nonFile, maxBytes: 32)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .invalidPath)
        }
        XCTAssertThrowsError(
            try SecureFileIO.writeAtomicallyOwnerOnly(Data("replacement".utf8), to: nonFile)
        ) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .invalidPath)
        }

        let oversizedName = String(repeating: "x", count: SafetyLimits.maxNameUTF8Bytes + 1)
        let oversized = root.appendingPathComponent(oversizedName)
        XCTAssertThrowsError(
            try SecureFileIO.writeAtomicallyOwnerOnly(Data("replacement".utf8), to: oversized)
        ) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .invalidFileName)
        }

        XCTAssertEqual(try Data(contentsOf: victim), Data("original".utf8),
                       "rejected destinations must never alter a nearby valid file")
    }

    func testSpecialFilesFailFastWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("state.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: fifo, maxBytes: 16)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .notRegularFile)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "opening a FIFO without a writer must not block")

        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: URL(fileURLWithPath: "/dev/null"),
                                                              maxBytes: 16)) { error in
            XCTAssertEqual(error as? SecureFileIO.Failure, .notRegularFile)
        }

        // sockaddr_un.sun_path is only 104 bytes on macOS; XCTest temp paths can exceed it.
        let socketURL = URL(fileURLWithPath: "/tmp/jbar-\(UUID().uuidString.prefix(12)).socket")
        defer { _ = unlink(socketURL.path) }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        defer { if socketFD >= 0 { _ = Darwin.close(socketFD) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketURL.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    strlcpy($0, source, pathCapacity)
                }
            }
        }
        XCTAssertLessThan(copied, pathCapacity)
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + socketURL.path.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, addressLength) }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertThrowsError(try SecureFileIO.readRegularFile(at: socketURL, maxBytes: 16),
                             "a Unix socket is never valid persisted state")
    }

    func testAtomicWriteCreatesOwnerOnlyFileAndCanTightenOwnedDirectory() throws {
        let directory = root.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        let file = directory.appendingPathComponent("history.json")

        try SecureFileIO.writeAtomicallyOwnerOnly(Data("first".utf8), to: file,
                                                  enforcePrivateDirectory: true)
        XCTAssertEqual(try permissions(directory), SecureFileIO.directoryMode)
        XCTAssertEqual(try permissions(file), SecureFileIO.fileMode)
        XCTAssertEqual(try Data(contentsOf: file), Data("first".utf8))

        try SecureFileIO.writeAtomicallyOwnerOnly(Data("replacement".utf8), to: file,
                                                  enforcePrivateDirectory: true)
        XCTAssertEqual(try permissions(file), SecureFileIO.fileMode)
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".jbar-write-") })
    }

    func testCustomSaveDoesNotChmodExistingCallerDirectory() throws {
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(shared.path, 0o755), 0)
        let file = shared.appendingPathComponent("config.json")

        try Config.default.save(to: file)
        XCTAssertEqual(try permissions(shared), 0o755)
        XCTAssertEqual(try permissions(file), SecureFileIO.fileMode)
        guard case .loaded(let loaded) = Config.load(from: file) else {
            return XCTFail("owner-only config must load")
        }
        XCTAssertEqual(loaded, .default)
    }

    func testWriteRefusesASymlinkParentWithoutTouchingTarget() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try SecureFileIO.writeAtomicallyOwnerOnly(Data("secret".utf8),
                                                      to: link.appendingPathComponent("state"),
                                                      enforcePrivateDirectory: true)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("state").path))
    }

    func testFrecencyHistoryIsBoundedAndProductModeUsesPrivateDirectory() throws {
        let directory = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        let file = directory.appendingPathComponent("history.json")
        let store = FrecencyStore(fileURL: file, enforcePrivateDirectory: true)
        store.record(open: "/private/customer-name.txt", query: "confidential")
        store.save()

        XCTAssertEqual(try permissions(directory), SecureFileIO.directoryMode)
        XCTAssertEqual(try permissions(file), SecureFileIO.fileMode)

        try Data(repeating: 0x20, count: SafetyLimits.maxHistoryFileBytes + 1).write(to: file)
        let loaded = FrecencyStore(fileURL: file)
        loaded.load()
        XCTAssertTrue(loaded.recents(limit: 10).isEmpty,
                      "oversized history must fail closed without decoding or retaining stale state")
    }
}
