import Darwin
import XCTest
@testable import JBarCore

final class FileOperationExecutorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarOrganize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testPreviewCommitManifestAndUndoRoundTripWithoutOverwrite() throws {
        try write("receipt-august.pdf", "august")
        try write("receipt-july.pdf", "july")
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        let august = try reference("receipt-august.pdf", in: snapshot)
        let july = try reference("receipt-july.pdf", in: snapshot)
        let preview = try FileOperationExecutor.preview(scope: snapshot, summary: "By month", operations: [
            ProposedFileOperation(sourceID: august.id, destinationFolderName: "2026-08 Receipts", newName: nil),
            ProposedFileOperation(sourceID: july.id, destinationFolderName: "2026-07 Receipts", newName: nil),
        ])
        XCTAssertEqual(preview.executableCount, 2)
        XCTAssertEqual(preview.foldersToCreate, ["2026-07 Receipts", "2026-08 Receipts"])

        let manifestURL = root.appendingPathComponent(".state/undo.json")
        let applied = try FileOperationExecutor.commit(preview, manifestURL: manifestURL)
        XCTAssertEqual(applied.completedCount, 2)
        XCTAssertFalse(exists("receipt-august.pdf"))
        XCTAssertEqual(try contents("2026-08 Receipts/receipt-august.pdf"), "august")
        XCTAssertEqual(try FileOperationExecutor.loadManifest(from: manifestURL), applied.manifest)
        let manifestAttributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        XCTAssertEqual((manifestAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: manifestURL.deletingLastPathComponent().path
        )
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let undone = try FileOperationExecutor.undo(applied.manifest)
        XCTAssertEqual(undone.completedCount, 2)
        XCTAssertEqual(try contents("receipt-august.pdf"), "august")
        XCTAssertEqual(try contents("receipt-july.pdf"), "july")
        XCTAssertFalse(exists("2026-08 Receipts"))
        XCTAssertFalse(exists("2026-07 Receipts"))
    }

    func testCollisionAtPreviewAndCollisionAppearingAtCommitBothSkip() throws {
        try write("one.pdf", "source")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Receipts"),
                                                withIntermediateDirectories: false)
        try write("Receipts/one.pdf", "existing")
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        let source = try reference("one.pdf", in: snapshot)
        let collision = try FileOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: source.id, destinationFolderName: "Receipts", newName: nil),
        ])
        XCTAssertEqual(collision.entries.first?.status, .collision)
        XCTAssertEqual(collision.executableCount, 0)

        try write("two.pdf", "two")
        let fresh = try OrganizeScopeSnapshot.capture(folder: root)
        let two = try reference("two.pdf", in: fresh)
        let raced = try FileOperationExecutor.preview(scope: fresh, summary: "", operations: [
            ProposedFileOperation(sourceID: two.id, destinationFolderName: "Late", newName: nil),
        ])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Late"),
                                                withIntermediateDirectories: false)
        try write("Late/two.pdf", "late")
        let applied = try FileOperationExecutor.commit(
            raced, manifestURL: root.appendingPathComponent(".state/race.json")
        )
        XCTAssertEqual(applied.skippedCount, 1)
        XCTAssertEqual(try contents("two.pdf"), "two")
        XCTAssertEqual(try contents("Late/two.pdf"), "late")
    }

    func testChangedSourceIsRemovedFromExecutableBatch() throws {
        try write("receipt.pdf", "before")
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        let source = try reference("receipt.pdf", in: snapshot)
        let preview = try FileOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: source.id, destinationFolderName: "Receipts", newName: nil),
        ])
        try write("receipt.pdf", "after and a different size")
        let result = try FileOperationExecutor.commit(
            preview, manifestURL: root.appendingPathComponent(".state/changed.json")
        )
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(exists("receipt.pdf"))
        XCTAssertFalse(exists("Receipts/receipt.pdf"))
    }

    func testUndoRefusesChangedMovedFileAndOccupiedOriginal() throws {
        try write("receipt.pdf", "original")
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        let source = try reference("receipt.pdf", in: snapshot)
        let preview = try FileOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: source.id, destinationFolderName: "Receipts", newName: nil),
        ])
        let applied = try FileOperationExecutor.commit(
            preview, manifestURL: root.appendingPathComponent(".state/undo-changed.json")
        )
        try write("Receipts/receipt.pdf", "changed")
        let changed = try FileOperationExecutor.undo(applied.manifest)
        XCTAssertEqual(changed.failedCount, 1)
        XCTAssertFalse(exists("receipt.pdf"))

        try write("Receipts/receipt.pdf", "original")
        // The manifest identity no longer matches after replacement, so this remains a safe refusal.
        try write("receipt.pdf", "occupied")
        let occupied = try FileOperationExecutor.undo(applied.manifest)
        XCTAssertEqual(occupied.failedCount, 1)
        XCTAssertEqual(try contents("receipt.pdf"), "occupied")
    }

    func testSymlinksHardLinksAndOversizedScopesFailClosed() throws {
        try write("normal.txt", "normal")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: root.appendingPathComponent("normal.txt")
        )
        let hard = root.appendingPathComponent("hard.txt")
        XCTAssertEqual(link(root.appendingPathComponent("normal.txt").path, hard.path), 0)
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        XCTAssertTrue(snapshot.files.isEmpty, "both hard-link names and the symlink must be excluded")
        XCTAssertEqual(snapshot.excludedEntries, 3)

        let parent = root.deletingLastPathComponent()
        let linkedRoot = parent.appendingPathComponent("JBarLinkedRoot-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        XCTAssertThrowsError(try OrganizeScopeSnapshot.capture(folder: linkedRoot)) {
            XCTAssertEqual($0 as? FileOperationError, .symlinkNotAllowed)
        }

        try FileManager.default.removeItem(at: hard)
        try write("second.txt", "2")
        XCTAssertThrowsError(try OrganizeScopeSnapshot.capture(folder: root, maximumFiles: 1)) {
            XCTAssertEqual($0 as? FileOperationError, .tooManyFiles)
        }
    }

    func testUndoRejectsTamperedManifestNamesAndDuplicateMovesBeforeFilesystemAccess() throws {
        try write("receipt.pdf", "original")
        let snapshot = try OrganizeScopeSnapshot.capture(folder: root)
        let source = try reference("receipt.pdf", in: snapshot)

        var escaping = FileOperationManifest(batchID: UUID(), scope: snapshot)
        escaping.completedMoves = [CompletedFileMove(
            sourceID: source.id, originalName: "../escaped.pdf",
            destinationFolderName: nil, destinationName: source.name,
            destinationIdentity: source.identity
        )]
        XCTAssertThrowsError(try FileOperationExecutor.undo(escaping)) {
            XCTAssertEqual($0 as? FileOperationError, .invalidPlan)
        }

        var duplicate = FileOperationManifest(batchID: UUID(), scope: snapshot)
        let move = CompletedFileMove(sourceID: source.id, originalName: source.name,
                                     destinationFolderName: "Receipts",
                                     destinationName: source.name,
                                     destinationIdentity: source.identity)
        duplicate.completedMoves = [move, move]
        XCTAssertThrowsError(try FileOperationExecutor.undo(duplicate)) {
            XCTAssertEqual($0 as? FileOperationError, .invalidPlan)
        }
        XCTAssertEqual(try contents("receipt.pdf"), "original")
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func reference(_ name: String,
                           in snapshot: OrganizeScopeSnapshot) throws -> ScopedFileReference {
        try XCTUnwrap(snapshot.files.first { $0.name == name })
    }
}
