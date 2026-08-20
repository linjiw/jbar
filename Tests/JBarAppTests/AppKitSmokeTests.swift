import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import JBarCore
import XCTest
@testable import JBarApp

@MainActor
final class AppKitSmokeTests: XCTestCase {
    private var validIdentity: AppKitSmoke.Identity {
        AppKitSmoke.Identity(bundleIdentifier: AppKitSmoke.bundleIdentifier,
                             declaredExecutable: AppKitSmoke.executableName,
                             actualExecutable: AppKitSmoke.executableName,
                             markerVersion: AppKitSmoke.markerVersion)
    }

    private func makePrivateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-appkit-smoke-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func removePrivateRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    func testParserHasThreeStatesAndNeverFallsThroughMalformedSmokeRequest() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }

        XCTAssertEqual(AppKitSmoke.parse(["tool"], identity: validIdentity), .notRequested)
        XCTAssertEqual(AppKitSmoke.parse(["tool", "--version"], identity: validIdentity), .notRequested)

        guard case .valid(let request) = AppKitSmoke.parse(
            ["tool", AppKitSmoke.argument, root.path], identity: validIdentity
        ) else {
            return XCTFail("exact smoke request should parse")
        }
        XCTAssertEqual(request.stateRoot, root)

        for arguments in [
            ["tool", AppKitSmoke.argument],
            ["tool", AppKitSmoke.argument, root.path, "extra"],
            ["tool", "--version", AppKitSmoke.argument, root.path],
            ["tool", AppKitSmoke.argument, AppKitSmoke.argument],
        ] {
            guard case .invalid = AppKitSmoke.parse(arguments, identity: validIdentity) else {
                return XCTFail("malformed smoke flag must be invalid: \(arguments)")
            }
        }
    }

    func testParserRejectsEveryIncorrectDerivedBundleIdentityField() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let arguments = ["tool", AppKitSmoke.argument, root.path]

        let invalid: [AppKitSmoke.Identity] = [
            .init(bundleIdentifier: "com.linji.jbar", declaredExecutable: AppKitSmoke.executableName,
                  actualExecutable: AppKitSmoke.executableName, markerVersion: AppKitSmoke.markerVersion),
            .init(bundleIdentifier: AppKitSmoke.bundleIdentifier, declaredExecutable: "JBar",
                  actualExecutable: AppKitSmoke.executableName, markerVersion: AppKitSmoke.markerVersion),
            .init(bundleIdentifier: AppKitSmoke.bundleIdentifier, declaredExecutable: AppKitSmoke.executableName,
                  actualExecutable: "JBar", markerVersion: AppKitSmoke.markerVersion),
            .init(bundleIdentifier: AppKitSmoke.bundleIdentifier, declaredExecutable: AppKitSmoke.executableName,
                  actualExecutable: AppKitSmoke.executableName, markerVersion: nil),
            .init(bundleIdentifier: AppKitSmoke.bundleIdentifier, declaredExecutable: AppKitSmoke.executableName,
                  actualExecutable: AppKitSmoke.executableName, markerVersion: "2"),
        ]
        for identity in invalid {
            guard case .invalid = AppKitSmoke.parse(arguments, identity: identity) else {
                return XCTFail("incorrect derived identity must fail closed: \(identity)")
            }
        }
        XCTAssertNil(AppKitSmoke.identityError(validIdentity))
    }

    func testParserRejectsInlineSmokeBytePrefixIncludingCombiningSuffix() {
        for suffix in ["", "/private/state", "e\u{301}", "\u{301}--version"] {
            let inline = "\(AppKitSmoke.argument)=\(suffix)"
            XCTAssertTrue(inline.utf8.starts(with: Array("--appkit-smoke=".utf8)))
            guard case .invalid = AppKitSmoke.parse(["tool", inline], identity: validIdentity) else {
                return XCTFail("inline smoke byte prefix must fail closed: \(inline.debugDescription)")
            }
            guard case .invalid = AppKitSmoke.parse(
                ["tool", "--version", inline], identity: validIdentity
            ) else {
                return XCTFail("misplaced inline smoke byte prefix must fail closed")
            }
        }
    }

    func testAppDelegateExitCodeFailsClosedBeforeSmokeSessionExists() throws {
        XCTAssertEqual(AppDelegate().processExitCode, 0, "a normal app delegate keeps the product exit status")

        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let request = try AppKitSmoke.makeRequest(path: root.path)
        let smokeDelegate = AppDelegate(appKitSmokeRequest: request)

        XCTAssertEqual(smokeDelegate.processExitCode, 1,
                       "a requested smoke must fail closed until its Session has been created")
    }

    func testStateRootRequiresAbsoluteEmptyOwned0700NonSymlinkDirectory() throws {
        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: "relative/state"))

        let wrongMode = try makePrivateRoot()
        defer { removePrivateRoot(wrongMode) }
        XCTAssertEqual(chmod(wrongMode.path, 0o755), 0)
        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: wrongMode.path))

        let nonempty = try makePrivateRoot()
        defer { removePrivateRoot(nonempty) }
        try Data("occupied".utf8).write(to: nonempty.appendingPathComponent("existing"))
        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: nonempty.path))

        let target = try makePrivateRoot()
        defer { removePrivateRoot(target) }
        let link = target.deletingLastPathComponent().appendingPathComponent("jbar-smoke-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: link.path))

        let regularFile = target.deletingLastPathComponent().appendingPathComponent("jbar-smoke-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: regularFile) }
        try Data().write(to: regularFile)
        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: regularFile.path))
    }

    func testStateRootRejectsExtendedACL() throws {
        let root = try makePrivateRoot()
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/bin/chmod")
            cleanup.arguments = ["-N", root.path]
            try? cleanup.run()
            cleanup.waitUntilExit()
            removePrivateRoot(root)
        }

        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clear.arguments = ["-N", root.path]
        try clear.run()
        clear.waitUntilExit()
        XCTAssertEqual(clear.terminationStatus, 0, "ACL-free fixture setup must succeed")
        XCTAssertNoThrow(try AppKitSmoke.makeRequest(path: root.path),
                         "a normal owner-only 0700 directory without an ACL must remain valid")

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone deny delete", root.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0, "ACL fixture setup must succeed")

        XCTAssertThrowsError(try AppKitSmoke.makeRequest(path: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("extended ACLs are not allowed"),
                          "unexpected ACL rejection: \(error)")
        }
    }

    func testValidatedStateRootCannotBeReplacedAfterParsing() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let request = try AppKitSmoke.makeRequest(path: root.path)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertThrowsError(try AppKitSmoke.ensureRootMatches(request)) { error in
            XCTAssertEqual(error as? AppKitSmoke.SmokeError, .stateRootChanged)
        }
    }

    func testRecordingWorkspaceCapturesSelectionWithoutOpeningAnythingExternally() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let target = root.appendingPathComponent("second-row", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let workspace = AppKitSmoke.RecordingWorkspace()
        let launcher = AppLauncher(frecency: nil, workspace: workspace, failureFeedback: {
            XCTFail("recording workspace should accept an existing folder")
        })
        let row = ResultRow(itemIndex: 1, name: "兼容测试・乙", path: target.path,
                            parentDisplay: root.path, kind: .folder, matchedByteOffsets: [], score: 1, tier: 2)
        var completion: Bool?

        launcher.open(row, query: "兼容测试") { completion = $0 }

        XCTAssertEqual(completion, true)
        XCTAssertEqual(workspace.snapshot.opened, [target.standardizedFileURL])
        XCTAssertTrue(workspace.snapshot.applications.isEmpty)
        XCTAssertTrue(workspace.snapshot.reveals.isEmpty)
    }

    func testControlEventsUseFlagsChangedAndTrackerRequiresDownThenUp() throws {
        let tracker = AppKitSmoke.ControlDispatchTracker()
        let down = try XCTUnwrap(AppKitSmoke.makeControlEvent(isDown: true, windowNumber: 0, timestamp: 1))
        let up = try XCTUnwrap(AppKitSmoke.makeControlEvent(isDown: false, windowNumber: 0, timestamp: 2))
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                     modifierFlags: [.control], timestamp: 3,
                                                     windowNumber: 0, context: nil, characters: "",
                                                     charactersIgnoringModifiers: "", isARepeat: false,
                                                     keyCode: UInt16(kVK_Control)))

        XCTAssertEqual(down.type, .flagsChanged)
        XCTAssertTrue(down.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control))
        XCTAssertEqual(up.type, .flagsChanged)
        XCTAssertFalse(up.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control))
        XCTAssertFalse(tracker.observe(up), "an up event before a down transition is not a complete dispatch")
        XCTAssertFalse(tracker.isComplete)
        XCTAssertFalse(tracker.observe(keyDown), "ordinary keyDown must not masquerade as flagsChanged")
        XCTAssertFalse(tracker.isComplete)
        XCTAssertTrue(tracker.observe(down))
        XCTAssertTrue(tracker.observedDown)
        XCTAssertFalse(tracker.isComplete)
        XCTAssertTrue(tracker.observe(up))
        XCTAssertTrue(tracker.isComplete)
    }

    func testControlTrackerObservesLocalNSApplicationDispatch() throws {
        let app = NSApplication.shared
        let tracker = AppKitSmoke.ControlDispatchTracker()
        var dispatchedEvents = 0
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                if tracker.observe(event) { dispatchedEvents += 1 }
            }
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        let down = try XCTUnwrap(AppKitSmoke.makeControlEvent(isDown: true, windowNumber: 0, timestamp: 1))
        let up = try XCTUnwrap(AppKitSmoke.makeControlEvent(isDown: false, windowNumber: 0, timestamp: 2))

        app.sendEvent(down)
        app.sendEvent(up)

        XCTAssertEqual(dispatchedEvents, 2)
        XCTAssertTrue(tracker.isComplete)
    }

    func testEvidenceIsBoundedExclusivePrivateAndDoesNotCreateTerminationMarker() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let request = try AppKitSmoke.makeRequest(path: root.path)
        let writer = AppKitSmoke.EvidenceWriter(request: request)
        let evidence = makeEvidence()

        try writer.writeEvidence(evidence)

        let evidenceURL = root.appendingPathComponent(AppKitSmoke.evidenceName)
        let decoded = try JSONDecoder().decode(AppKitSmoke.Evidence.self, from: Data(contentsOf: evidenceURL))
        XCTAssertEqual(decoded, evidence)
        XCTAssertLessThanOrEqual((try Data(contentsOf: evidenceURL)).count, AppKitSmoke.maximumEvidenceBytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: evidenceURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(AppKitSmoke.cleanMarkerName).path
        ), "PASS JSON alone must not masquerade as clean AppKit termination")
        XCTAssertThrowsError(try writer.writeEvidence(evidence),
                             "evidence publication must be exclusive, not overwrite existing proof")
    }

    func testOversizedEvidenceFailsWithoutLeavingAPartialFile() throws {
        let root = try makePrivateRoot()
        defer { removePrivateRoot(root) }
        let request = try AppKitSmoke.makeRequest(path: root.path)
        let writer = AppKitSmoke.EvidenceWriter(request: request)
        let evidence = makeEvidence(limitations: [String(repeating: "x", count: AppKitSmoke.maximumEvidenceBytes)])

        XCTAssertThrowsError(try writer.writeEvidence(evidence)) { error in
            guard let smokeError = error as? AppKitSmoke.SmokeError,
                  case .evidenceTooLarge = smokeError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(AppKitSmoke.evidenceName).path
        ))
    }

    private func makeEvidence(limitations: [String] = ["synthetic events are not a real IME"]) -> AppKitSmoke.Evidence {
        AppKitSmoke.Evidence(schemaVersion: 1, status: "PASS",
                             bundleIdentifier: AppKitSmoke.bundleIdentifier,
                             executable: AppKitSmoke.executableName,
                             markerVersion: AppKitSmoke.markerVersion,
                             operatingSystemVersion: "test", processArchitecture: "test",
                             localeIdentifier: "zh_CN", eventPath: "test",
                             exercisedControlKey: true, exercisedDeleteKey: true,
                             panelStayedVisibleUntilOpen: true,
                             committedQuery: "兼容测试", unicodeRows: ["甲", "乙"],
                             recordedOpenPath: "/private/test/second",
                             expectedSecondPath: "/private/test/second", panelHidden: true,
                             elapsedMilliseconds: 1, scopeLimitations: limitations)
    }
}
