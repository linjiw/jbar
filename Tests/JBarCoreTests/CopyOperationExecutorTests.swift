import Darwin
import XCTest
@testable import JBarCore

final class CopyOperationExecutorTests: XCTestCase {
    private var root: URL!
    private var sourceA: URL!
    private var sourceB: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarGlobalCopy-\(UUID().uuidString)", isDirectory: true)
        sourceA = root.appendingPathComponent("Desktop", isDirectory: true)
        sourceB = root.appendingPathComponent("Downloads", isDirectory: true)
        destination = root.appendingPathComponent("Organized Copies", isDirectory: true)
        for directory in [root!, sourceA!, sourceB!, destination!] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: false)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testCopiesAcrossGlobalSourcesWithoutChangingOriginals() throws {
        let august = try write("receipt-august.pdf", "august", in: sourceA)
        let july = try write("receipt-july.pdf", "july", in: sourceB)
        let snapshot = try capture([august, july])
        let preview = try CopyOperationExecutor.preview(scope: snapshot, summary: "By month", operations: [
            ProposedFileOperation(sourceID: try id("receipt-august.pdf", in: snapshot),
                                  destinationFolderName: "2026-08 Receipts", newName: nil),
            ProposedFileOperation(sourceID: try id("receipt-july.pdf", in: snapshot),
                                  destinationFolderName: "2026-07 Receipts", newName: nil),
        ])
        XCTAssertEqual(preview.executableCount, 2)
        XCTAssertEqual(preview.foldersToCreate, ["2026-07 Receipts", "2026-08 Receipts"])

        let result = try CopyOperationExecutor.commit(preview)

        XCTAssertEqual(result.completedCount, 2)
        XCTAssertEqual(try text(august), "august")
        XCTAssertEqual(try text(july), "july")
        let augustCopy = destination.appendingPathComponent("2026-08 Receipts/receipt-august.pdf")
        let julyCopy = destination.appendingPathComponent("2026-07 Receipts/receipt-july.pdf")
        XCTAssertEqual(try text(augustCopy), "august")
        XCTAssertEqual(try text(julyCopy), "july")
        let attributes = try FileManager.default.attributesOfItem(atPath: augustCopy.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingAndRacingDestinationsNeverOverwrite() throws {
        let source = try write("one.pdf", "source", in: sourceA)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("Receipts"), withIntermediateDirectories: false
        )
        let existing = try write("one.pdf", "existing",
                                 in: destination.appendingPathComponent("Receipts"))
        let snapshot = try capture([source])
        let collision = try CopyOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: try id("one.pdf", in: snapshot),
                                  destinationFolderName: "Receipts", newName: nil),
        ])
        XCTAssertEqual(collision.entries.first?.status, .collision)
        XCTAssertEqual(try text(existing), "existing")

        let racedSource = try write("two.pdf", "source-two", in: sourceB)
        let racedSnapshot = try capture([racedSource])
        let raced = try CopyOperationExecutor.preview(scope: racedSnapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: try id("two.pdf", in: racedSnapshot),
                                  destinationFolderName: "Late", newName: nil),
        ])
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("Late"), withIntermediateDirectories: false
        )
        let late = try write("two.pdf", "late-winner",
                             in: destination.appendingPathComponent("Late"))
        let result = try CopyOperationExecutor.commit(raced)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try text(late), "late-winner")
        XCTAssertEqual(try text(racedSource), "source-two")
    }

    func testChangedSourceIsSkippedAndNeverLeavesDestinationFile() throws {
        let source = try write("receipt.pdf", "before", in: sourceA)
        let snapshot = try capture([source])
        let preview = try CopyOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: try id("receipt.pdf", in: snapshot),
                                  destinationFolderName: "Receipts", newName: nil),
        ])
        try Data("after and a different size".utf8).write(to: source, options: .atomic)

        let result = try CopyOperationExecutor.commit(preview)

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try text(source), "after and a different size")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Receipts/receipt.pdf").path
        ))
    }

    func testDuplicateDestinationsAndPlannerOmissionsAreVisibleInCompletePreview() throws {
        let first = try write("same.pdf", "first", in: sourceA)
        let second = try write("same.pdf", "second", in: sourceB)
        let omitted = try write("omitted.pdf", "omitted", in: sourceB)
        let snapshot = try capture([first, second, omitted])
        let sameIDs = snapshot.files.filter { $0.name == "same.pdf" }.map(\.id)
        let preview = try CopyOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: sameIDs[0], destinationFolderName: "Receipts", newName: nil),
            ProposedFileOperation(sourceID: sameIDs[1], destinationFolderName: "Receipts", newName: nil),
        ])

        XCTAssertEqual(preview.entries.count, 3)
        XCTAssertEqual(preview.executableCount, 1)
        XCTAssertEqual(preview.collisionCount, 1)
        XCTAssertTrue(preview.entries.contains {
            $0.source.name == "omitted.pdf" && $0.explanation.contains("did not include")
        })
    }

    func testSymlinksHardLinksAndOversizedBatchesFailClosed() throws {
        let normal = try write("normal.txt", "normal", in: sourceA)
        let symbolic = sourceA.appendingPathComponent("symbolic.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: normal)
        XCTAssertThrowsError(try capture([symbolic])) {
            XCTAssertEqual($0 as? CopyOperationError, .symlinkNotAllowed)
        }

        let hard = sourceB.appendingPathComponent("hard.txt")
        XCTAssertEqual(link(normal.path, hard.path), 0)
        XCTAssertThrowsError(try capture([normal])) {
            XCTAssertEqual($0 as? CopyOperationError, .unsafeSource)
        }

        let inputs = (0...GlobalCopyScopeSnapshot.maximumFiles).map {
            GlobalCopySourceInput(path: "/tmp/not-opened-\($0)", parentDisplay: "/tmp")
        }
        XCTAssertThrowsError(try GlobalCopyScopeSnapshot.capture(inputs: inputs,
                                                                 destinationFolder: destination)) {
            XCTAssertEqual($0 as? CopyOperationError, .tooManyFiles)
        }
    }

    func testSymbolicLinkDestinationIsRejected() throws {
        let source = try write("source.txt", "source", in: sourceA)
        let linkedDestination = root.appendingPathComponent("Linked Destination")
        try FileManager.default.createSymbolicLink(at: linkedDestination,
                                                   withDestinationURL: destination)
        XCTAssertThrowsError(try GlobalCopyScopeSnapshot.capture(
            inputs: [GlobalCopySourceInput(path: source.path, parentDisplay: sourceA.path)],
            destinationFolder: linkedDestination
        )) {
            XCTAssertEqual($0 as? CopyOperationError, .symlinkNotAllowed)
        }
    }

    func testDestinationRootReplacementAndFolderSymlinkRaceFailClosed() throws {
        let source = try write("source.txt", "source", in: sourceA)
        let snapshot = try capture([source])
        let preview = try CopyOperationExecutor.preview(scope: snapshot, summary: "", operations: [
            ProposedFileOperation(sourceID: try id("source.txt", in: snapshot),
                                  destinationFolderName: "Receipts", newName: nil),
        ])

        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("Receipts"), withDestinationURL: external
        )
        let raced = try CopyOperationExecutor.commit(preview)
        XCTAssertEqual(raced.failedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("source.txt").path))
        XCTAssertEqual(try text(source), "source")

        try FileManager.default.removeItem(at: destination.appendingPathComponent("Receipts"))
        let replaced = destination.appendingPathExtension("replaced")
        try FileManager.default.moveItem(at: destination, to: replaced)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try CopyOperationExecutor.commit(preview)) {
            XCTAssertEqual($0 as? CopyOperationError, .destinationChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.txt").path))
        XCTAssertEqual(try text(source), "source")
    }

    private func capture(_ urls: [URL]) throws -> GlobalCopyScopeSnapshot {
        try GlobalCopyScopeSnapshot.capture(
            inputs: urls.map {
                GlobalCopySourceInput(path: $0.path,
                                      parentDisplay: $0.deletingLastPathComponent().lastPathComponent)
            },
            destinationFolder: destination
        )
    }

    private func id(_ name: String, in snapshot: GlobalCopyScopeSnapshot) throws -> UUID {
        try XCTUnwrap(snapshot.files.first { $0.name == name }?.id)
    }

    @discardableResult
    private func write(_ name: String, _ contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
