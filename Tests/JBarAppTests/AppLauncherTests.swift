import AppKit
import XCTest
import JBarCore
@testable import JBarApp

private final class FakeWorkspace: WorkspaceOpening {
    var openURLResult = true
    var openedURLs: [URL] = []
    var applicationURLs: [URL] = []
    var revealedURLs: [URL] = []
    var applicationCompletion: (@Sendable (NSRunningApplication?, Error?) -> Void)?

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openURLResult
    }

    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration,
                         completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?) {
        applicationURLs.append(applicationURL)
        applicationCompletion = completionHandler
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealedURLs.append(contentsOf: fileURLs)
    }
}

/// XCTest invokes synchronous setup/teardown outside the test class's global actor. Keep the one
/// cross-boundary fixture value behind a lock; UI-facing test code still remains MainActor-isolated.
private final class TestDirectoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func store(_ value: URL) {
        lock.withLock { url = value }
    }

    var value: URL? {
        lock.withLock { url }
    }

    func take() -> URL? {
        lock.withLock {
            defer { url = nil }
            return url
        }
    }
}

@MainActor
final class AppLauncherTests: XCTestCase {
    private let directoryState = TestDirectoryState()
    private var tempDirectory: URL { directoryState.value! }

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryState.store(directory)
    }

    override func tearDownWithError() throws {
        if let directory = directoryState.take() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func row(at url: URL, kind: ItemKind = .app) -> ResultRow {
        ResultRow(itemIndex: 0, name: url.deletingPathExtension().lastPathComponent, path: url.path,
                  parentDisplay: url.deletingLastPathComponent().path, kind: kind,
                  matchedByteOffsets: [], score: 1, tier: 0)
    }

    private func history() -> FrecencyStore {
        FrecencyStore(fileURL: tempDirectory.appendingPathComponent("history.json"))
    }

    func testApplicationFailureDoesNotRecordHistoryOrReportSuccess() throws {
        let app = tempDirectory.appendingPathComponent("Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let workspace = FakeWorkspace()
        let history = history()
        var feedbackCount = 0
        let launcher = AppLauncher(frecency: history, workspace: workspace) { feedbackCount += 1 }
        var outcome: Bool?
        let completed = expectation(description: "LaunchServices failure delivered")

        launcher.open(row(at: app), query: "private query") {
            outcome = $0
            completed.fulfill()
        }

        XCTAssertNil(outcome, "an application request is not success until LaunchServices completes")
        XCTAssertEqual(history.count, 0)
        workspace.applicationCompletion?(nil, NSError(domain: NSCocoaErrorDomain,
                                                        code: NSExecutableNotLoadableError))
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcome, false)
        XCTAssertEqual(history.count, 0, "a failed application must never affect frecency")
        XCTAssertEqual(history.queryPickCount, 0)
        XCTAssertEqual(feedbackCount, 1)
    }

    func testApplicationSuccessRecordsOnlyAfterConfirmation() throws {
        let app = tempDirectory.appendingPathComponent("Working.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let workspace = FakeWorkspace()
        let history = history()
        let launcher = AppLauncher(frecency: history, workspace: workspace, failureFeedback: {})
        var outcomes: [Bool] = []
        let completed = expectation(description: "LaunchServices success delivered")

        launcher.open(row(at: app), query: "launch me") {
            outcomes.append($0)
            completed.fulfill()
        }

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(history.count, 0)
        workspace.applicationCompletion?(NSRunningApplication.current, nil)
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcomes, [true])
        XCTAssertEqual(history.count, 1)
        XCTAssertGreaterThan(history.score(for: app.path), 0)
        XCTAssertGreaterThan(history.queryPickBoost(query: "launch me", path: app.path), 0)
    }

    func testSynchronousFileFailureDoesNotRecordHistory() throws {
        let file = tempDirectory.appendingPathComponent("document.txt")
        try Data("test".utf8).write(to: file)
        let workspace = FakeWorkspace()
        workspace.openURLResult = false
        let history = history()
        var feedbackCount = 0
        let launcher = AppLauncher(frecency: history, workspace: workspace) { feedbackCount += 1 }
        var outcome: Bool?

        launcher.open(row(at: file, kind: .document), query: "document") { outcome = $0 }

        XCTAssertEqual(outcome, false)
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(feedbackCount, 1)
    }

    func testMissingPathDoesNotCallWorkspace() {
        let workspace = FakeWorkspace()
        let history = history()
        let launcher = AppLauncher(frecency: history, workspace: workspace, failureFeedback: {})
        let missing = tempDirectory.appendingPathComponent("missing.app")
        var outcome: Bool?

        launcher.open(row(at: missing), query: nil) { outcome = $0 }

        XCTAssertEqual(outcome, false)
        XCTAssertTrue(workspace.applicationURLs.isEmpty)
        XCTAssertTrue(workspace.openedURLs.isEmpty)
        XCTAssertEqual(history.count, 0)
    }

    func testStartupHistoryPruneRemovesDeadPathsAndPersistsResult() throws {
        let historyURL = tempDirectory.appendingPathComponent("pruned-history.json")
        let existing = tempDirectory.appendingPathComponent("existing.txt")
        try Data("present".utf8).write(to: existing)
        let missing = tempDirectory.appendingPathComponent("missing.txt")
        let store = FrecencyStore(fileURL: historyURL)
        store.record(open: existing.path, query: "existing")
        store.record(open: missing.path, query: "missing")
        store.save()

        let removed = AppDelegate.pruneHistory(store) { FileManager.default.fileExists(atPath: $0) }

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.recents(limit: 10), [existing.path])
        XCTAssertEqual(store.queryPickBoost(query: "missing", path: missing.path), 0)
        let reloaded = FrecencyStore(fileURL: historyURL)
        reloaded.load()
        XCTAssertEqual(reloaded.recents(limit: 10), [existing.path],
                       "startup maintenance must persist the pruned history")
    }
}
