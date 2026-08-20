import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import JBarCore

/// A hidden, packaged-app-only AppKit lifecycle smoke.
///
/// This is intentionally not a second product mode. It runs only from a clone whose bundle identity
/// has been rewritten by `scripts/tests/appkit-smoke.sh`, and it writes only beneath a caller-created,
/// empty, owner-only state root. The smoke exercises NSApplication's real event queue, AppDelegate,
/// SearchPanel, the field editor, the results table, and AppLauncher while substituting a recording
/// `WorkspaceOpening` that has no route to NSWorkspace.
enum AppKitSmoke {
    static let argument = "--appkit-smoke"
    static let bundleIdentifier = "com.linji.jbar.appkitsmoke"
    static let executableName = "JBarAppKitSmoke"
    static let markerKey = "JBarAppKitSmokeVersion"
    static let markerVersion = "1"
    static let evidenceName = "evidence.json"
    static let snapshotName = "panel.png"
    static let cleanMarkerName = "clean-termination.marker"
    static let maximumEvidenceBytes = 64 * 1_024
    static let maximumPNGBytes = 16 * 1_024 * 1_024
    static let timeoutNanoseconds: UInt64 = 15 * 1_000_000_000
    private static let inlineArgumentPrefixBytes = Array("--appkit-smoke=".utf8)

    struct Identity: Equatable {
        let bundleIdentifier: String?
        let declaredExecutable: String?
        let actualExecutable: String?
        let markerVersion: String?
    }

    struct RootIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct Request: Equatable {
        let stateRoot: URL
        let rootIdentity: RootIdentity
    }

    enum ParseResult: Equatable {
        case notRequested
        case valid(Request)
        case invalid(String)
    }

    enum SmokeError: LocalizedError, Equatable {
        case invalidStateRoot(String)
        case stateRootChanged
        case unsafeOutput(String)
        case evidenceTooLarge(Int)
        case invalidPNG
        case eventCreationFailed(String)
        case assertionFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .invalidStateRoot(let detail): return "invalid AppKit smoke state root: \(detail)"
            case .stateRootChanged: return "AppKit smoke state root changed after validation"
            case .unsafeOutput(let detail): return "unsafe AppKit smoke output: \(detail)"
            case .evidenceTooLarge(let count): return "AppKit smoke evidence exceeds \(maximumEvidenceBytes) bytes (got \(count))"
            case .invalidPNG: return "AppKit smoke snapshot is not a bounded PNG"
            case .eventCreationFailed(let key): return "could not create synthetic \(key) NSEvent"
            case .assertionFailed(let detail): return "AppKit smoke assertion failed: \(detail)"
            case .timeout(let state): return "AppKit smoke timed out while \(state)"
            }
        }
    }

    static func runtimeIdentity(bundle: Bundle = .main) -> Identity {
        Identity(bundleIdentifier: bundle.bundleIdentifier,
                 declaredExecutable: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                 actualExecutable: bundle.executableURL?.lastPathComponent,
                 markerVersion: bundle.object(forInfoDictionaryKey: markerKey) as? String)
    }

    static func identityError(_ identity: Identity) -> String? {
        guard identity.bundleIdentifier == bundleIdentifier else {
            return "bundle identifier must be \(bundleIdentifier)"
        }
        guard identity.declaredExecutable == executableName else {
            return "CFBundleExecutable must be \(executableName)"
        }
        guard identity.actualExecutable == executableName else {
            return "running executable must be \(executableName)"
        }
        guard identity.markerVersion == markerVersion else {
            return "\(markerKey) must be \(markerVersion)"
        }
        return nil
    }

    /// Parse before normal CLI dispatch. Any occurrence of the hidden flag is either an exact,
    /// validated request or a hard error; a malformed request can never fall through to the product.
    static func parse(_ args: [String], identity: Identity = runtimeIdentity()) -> ParseResult {
        let positions = args.indices.filter { args[$0] == argument }
        // Compare the ASCII prefix as UTF-8 bytes. Swift String comparisons may apply Unicode
        // equivalence, while CLI fail-closed recognition must not depend on suffix normalization.
        let hasInlineForm = args.contains { $0.utf8.starts(with: inlineArgumentPrefixBytes) }
        guard !positions.isEmpty || hasInlineForm else { return .notRequested }
        guard !hasInlineForm, positions == [1], args.count == 3 else {
            return .invalid("usage: \(executableName) \(argument) <empty-0700-absolute-state-root>")
        }
        if let error = identityError(identity) { return .invalid(error) }
        do {
            return .valid(try makeRequest(path: args[2]))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    static func makeRequest(path: String) throws -> Request {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            throw SmokeError.invalidStateRoot("path must be absolute")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let identity = try inspectStateRoot(root, requireEmpty: true)
        return Request(stateRoot: root, rootIdentity: identity)
    }

    @discardableResult
    static func inspectStateRoot(_ root: URL, requireEmpty: Bool) throws -> RootIdentity {
        let path = root.path
        guard (path as NSString).isAbsolutePath, root.standardizedFileURL.path == path else {
            throw SmokeError.invalidStateRoot("path is not absolute and standardized")
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == path else {
            throw SmokeError.invalidStateRoot("root or one of its path components is a symbolic link")
        }

        let descriptor = root.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return Darwin.open(representation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SmokeError.invalidStateRoot("could not safely open directory (errno \(errno))")
        }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw SmokeError.invalidStateRoot("fstat failed (errno \(errno))")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw SmokeError.invalidStateRoot("root is not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw SmokeError.invalidStateRoot("root is not owned by the current effective user")
        }
        guard (info.st_mode & 0o7777) == 0o700 else {
            throw SmokeError.invalidStateRoot("permissions must be exactly 0700")
        }
        try requireNoExtendedACL(descriptor)
        if requireEmpty {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: path)
            } catch {
                throw SmokeError.invalidStateRoot("directory cannot be enumerated")
            }
            guard entries.isEmpty else { throw SmokeError.invalidStateRoot("directory must be empty") }
        }
        let identity = RootIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        var pathInfo = stat()
        let pathStatus = root.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return lstat(representation, &pathInfo)
        }
        guard pathStatus == 0,
              RootIdentity(device: UInt64(pathInfo.st_dev), inode: UInt64(pathInfo.st_ino)) == identity else {
            throw SmokeError.stateRootChanged
        }
        return identity
    }

    /// Query the ACL through the already-open directory descriptor so a concurrent pathname swap
    /// cannot cause the ACL check and the uid/mode/device/inode checks to describe different objects.
    private static func requireNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            _ = acl_free(UnsafeMutableRawPointer(acl))
            throw SmokeError.invalidStateRoot("extended ACLs are not allowed")
        }
        guard errno == ENOENT else {
            throw SmokeError.invalidStateRoot("extended ACL inspection failed (errno \(errno))")
        }
    }

    static func ensureRootMatches(_ request: Request) throws {
        guard try inspectStateRoot(request.stateRoot, requireEmpty: false) == request.rootIdentity else {
            throw SmokeError.stateRootChanged
        }
    }

    /// Records a complete Control modifier transition only after the events have travelled
    /// back through NSApplication's local-event-monitor dispatch path. Posting an event is not proof
    /// that AppKit dispatched it, so Session never mutates these flags at the posting call site.
    @MainActor
    final class ControlDispatchTracker {
        private(set) var observedDown = false
        private(set) var observedUp = false
        var isComplete: Bool { observedDown && observedUp }

        @discardableResult
        func observe(_ event: NSEvent) -> Bool {
            guard event.type == .flagsChanged, Int(event.keyCode) == kVK_Control else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.control) {
                observedDown = true
                return true
            }
            guard observedDown else { return false }
            observedUp = true
            return true
        }
    }

    static func makeControlEvent(isDown: Bool, windowNumber: Int,
                                 timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent? {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                         modifierFlags: isDown ? [.control] : [], timestamp: timestamp,
                         windowNumber: windowNumber, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: UInt16(kVK_Control))
    }

    /// A workspace substitute with no NSWorkspace property or fallback. Every protocol method records
    /// intent only; the smoke accepts exactly one ordinary `open` and treats app/reveal calls as errors.
    final class RecordingWorkspace: WorkspaceOpening, @unchecked Sendable {
        struct Snapshot: Equatable {
            let opened: [URL]
            let applications: [URL]
            let reveals: [[URL]]
        }

        private let lock = NSLock()
        private var opened: [URL] = []
        private var applications: [URL] = []
        private var reveals: [[URL]] = []

        func open(_ url: URL) -> Bool {
            lock.withLock { opened.append(url.standardizedFileURL) }
            return true
        }

        func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration,
                             completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?) {
            lock.withLock { applications.append(applicationURL.standardizedFileURL) }
            completionHandler?(nil, NSError(domain: "com.linji.jbar.appkitsmoke", code: 1))
        }

        func activateFileViewerSelecting(_ fileURLs: [URL]) {
            lock.withLock { reveals.append(fileURLs.map(\.standardizedFileURL)) }
        }

        var snapshot: Snapshot {
            lock.withLock { Snapshot(opened: opened, applications: applications, reveals: reveals) }
        }
    }

    struct Evidence: Codable, Equatable {
        let schemaVersion: Int
        let status: String
        let bundleIdentifier: String
        let executable: String
        let markerVersion: String
        let operatingSystemVersion: String
        let processArchitecture: String
        let localeIdentifier: String
        let eventPath: String
        let exercisedControlKey: Bool
        let exercisedDeleteKey: Bool
        let panelStayedVisibleUntilOpen: Bool
        let committedQuery: String
        let unicodeRows: [String]
        let recordedOpenPath: String
        let expectedSecondPath: String
        let panelHidden: Bool
        let elapsedMilliseconds: Double
        let scopeLimitations: [String]
    }

    struct EvidenceWriter {
        let request: Request

        func writeEvidence(_ evidence: Evidence) throws {
            try AppKitSmoke.ensureRootMatches(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(evidence)
            guard data.count <= maximumEvidenceBytes else { throw SmokeError.evidenceTooLarge(data.count) }
            try writeExclusive(data, named: evidenceName)
        }

        @MainActor
        func writeSnapshot(of panel: SearchPanel) throws {
            try AppKitSmoke.ensureRootMatches(request)
            let temporaryName = ".panel-\(UUID().uuidString.lowercased()).png"
            let temporaryURL = request.stateRoot.appendingPathComponent(temporaryName, isDirectory: false)
            let finalURL = request.stateRoot.appendingPathComponent(snapshotName, isDirectory: false)
            guard !pathExists(finalURL) else { throw SmokeError.unsafeOutput("\(snapshotName) already exists") }
            guard panel.renderSnapshot(to: temporaryURL) else { throw SmokeError.invalidPNG }
            var keepTemporary = true
            defer {
                if keepTemporary {
                    temporaryURL.withUnsafeFileSystemRepresentation { representation in
                        if let representation { _ = unlink(representation) }
                    }
                }
            }

            var info = stat()
            let status = temporaryURL.withUnsafeFileSystemRepresentation { representation -> Int32 in
                guard let representation else { return -1 }
                return lstat(representation, &info)
            }
            guard status == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
                  info.st_size >= 8, info.st_size <= off_t(maximumPNGBytes) else {
                throw SmokeError.invalidPNG
            }
            let data = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
            guard data.count <= maximumPNGBytes,
                  data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw SmokeError.invalidPNG
            }
            guard chmod(temporaryURL.path, 0o600) == 0 else {
                throw SmokeError.unsafeOutput("could not set snapshot mode 0600")
            }
            let linked = temporaryURL.withUnsafeFileSystemRepresentation { source -> Int32 in
                finalURL.withUnsafeFileSystemRepresentation { destination -> Int32 in
                    guard let source, let destination else { return -1 }
                    return Darwin.link(source, destination)
                }
            }
            guard linked == 0 else { throw SmokeError.unsafeOutput("could not publish snapshot exclusively (errno \(errno))") }
            let removed = temporaryURL.withUnsafeFileSystemRepresentation { representation -> Int32 in
                guard let representation else { return -1 }
                return unlink(representation)
            }
            guard removed == 0 else {
                throw SmokeError.unsafeOutput("could not remove temporary snapshot")
            }
            keepTemporary = false
            var finalInfo = stat()
            let finalStatus = finalURL.withUnsafeFileSystemRepresentation { representation -> Int32 in
                guard let representation else { return -1 }
                return lstat(representation, &finalInfo)
            }
            guard finalStatus == 0, (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  finalInfo.st_nlink == 1, finalInfo.st_dev == info.st_dev, finalInfo.st_ino == info.st_ino else {
                throw SmokeError.unsafeOutput("published snapshot identity changed")
            }
            try AppKitSmoke.ensureRootMatches(request)
        }

        /// Called only from AppDelegate.applicationWillTerminate for a completed PASS run.
        func writeCleanTerminationMarker() throws {
            try writeExclusive(Data("PASS\n".utf8), named: cleanMarkerName)
        }

        private func writeExclusive(_ data: Data, named name: String) throws {
            try AppKitSmoke.ensureRootMatches(request)
            guard !name.isEmpty, !name.contains("/"), data.count <= maximumEvidenceBytes else {
                throw SmokeError.unsafeOutput("invalid bounded output request")
            }
            let url = request.stateRoot.appendingPathComponent(name, isDirectory: false)
            guard url.deletingLastPathComponent().standardizedFileURL == request.stateRoot else {
                throw SmokeError.unsafeOutput("output escaped state root")
            }
            let descriptor = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
                guard let representation else { return -1 }
                return Darwin.open(representation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard descriptor >= 0 else {
                throw SmokeError.unsafeOutput("could not create \(name) exclusively (errno \(errno))")
            }
            var succeeded = false
            defer {
                _ = Darwin.close(descriptor)
                if !succeeded {
                    url.withUnsafeFileSystemRepresentation { representation in
                        if let representation { _ = unlink(representation) }
                    }
                }
            }
            try data.withUnsafeBytes { rawBuffer in
                guard var cursor = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let count = Darwin.write(descriptor, cursor, remaining)
                    guard count > 0 else {
                        throw SmokeError.unsafeOutput("write failed for \(name) (errno \(errno))")
                    }
                    remaining -= count
                    cursor = cursor.advanced(by: count)
                }
            }
            guard fsync(descriptor) == 0 else {
                throw SmokeError.unsafeOutput("fsync failed for \(name) (errno \(errno))")
            }
            succeeded = true
        }

        private func pathExists(_ url: URL) -> Bool {
            var info = stat()
            return url.withUnsafeFileSystemRepresentation { representation in
                guard let representation else { return false }
                return lstat(representation, &info) == 0 || errno != ENOENT
            }
        }
    }

    @MainActor
    final class Session {
        private enum State: String {
            case awaitingFocus = "waiting for the panel field editor to become first responder"
            case awaitingControlDispatch = "waiting for Control flagsChanged down/up dispatch"
            case awaitingInitialQuery = "waiting for the key-by-key query NSEvents"
            case awaitingDeletedQuery = "waiting for the Delete NSEvent"
            case awaitingRows = "waiting for two Unicode result rows"
            case awaitingDown = "waiting for Down to select the second row"
            case awaitingOpen = "waiting for Down and Return through AppKit"
            case passed = "finished"
            case failed = "failed"
        }

        private static let initialQuery = "abx"
        private static let committedQuery = "ab"
        private static let rowNames = ["ab・兼容测试甲", "ab・兼容测试乙"]

        private let request: Request
        private let writer: EvidenceWriter
        private let workspace = RecordingWorkspace()
        private let controlDispatch = ControlDispatchTracker()
        private let startedAt = ProcessInfo.processInfo.systemUptime
        private let deadline: UInt64
        private var state: State = .awaitingFocus
        private var timer: DispatchSourceTimer?
        private var controlMonitor: Any?
        private var launcher: AppLauncher?
        private var panel: SearchPanel?
        private var expectedPaths: [URL] = []
        private var deleteKeyExercised = false
        private var panelStayedVisibleUntilOpen = true
        private var passReadyForTermination = false
        private(set) var exitCode: Int32 = 1

        init(request: Request) {
            self.request = request
            writer = EvidenceWriter(request: request)
            let now = DispatchTime.now().uptimeNanoseconds
            deadline = now > UInt64.max - timeoutNanoseconds ? UInt64.max : now + timeoutNanoseconds
        }

        func start() {
            do {
                try AppKitSmoke.ensureRootMatches(request)
                expectedPaths = try createFixtureDirectories()
                let items = zip(Self.rowNames, expectedPaths).map {
                    DemoSearchProvider.Item(name: $0.0, path: $0.1.path, kind: .folder)
                }
                let provider = DemoSearchProvider(items: items, home: request.stateRoot.path)
                let launcher = AppLauncher(frecency: nil, workspace: workspace, failureFeedback: {})
                var settings = SearchPanel.Settings()
                settings.maxResults = 2
                settings.visibleRows = 2
                settings.appsFirstCap = 0
                settings.screen = "main"
                settings.restoreQueryOnReopen = false
                settings.showRecentsOnEmpty = false
                settings.hotkeyDisplay = "Smoke"
                let panel = SearchPanel(provider: provider, launcher: launcher, settings: settings)
                panel.showsHintWhenEmpty = false
                self.launcher = launcher
                self.panel = panel

                NSApp.setActivationPolicy(.accessory)
                installControlMonitor()
                panel.show()
                startDeadlineTimer()
            } catch {
                fail(error.localizedDescription)
            }
        }

        /// The clean marker is deliberately impossible to create during the normal state machine.
        /// AppDelegate calls this from `applicationWillTerminate` after NSApplication has committed to
        /// termination, which distinguishes a completed lifecycle from a process that merely wrote JSON.
        func applicationWillTerminate() {
            timer?.cancel()
            timer = nil
            removeControlMonitor()
            guard passReadyForTermination else { return }
            do {
                try writer.writeCleanTerminationMarker()
                exitCode = 0
            } catch {
                exitCode = 1
                writeStandardError("AppKit smoke clean-termination marker failed: \(error.localizedDescription)\n")
            }
        }

        private func startDeadlineTimer() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.advance() }
            }
            self.timer = timer
            timer.resume()
        }

        private func advance() {
            guard state != .passed, state != .failed else { return }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                fail(SmokeError.timeout(state.rawValue).localizedDescription)
                return
            }
            guard let panel else {
                fail(SmokeError.assertionFailed("panel was released").localizedDescription)
                return
            }
            do {
                switch state {
                case .awaitingFocus:
                    guard panel.isVisible, panel.isKeyWindow, panel.firstResponder is NSTextView else { return }
                    try postControlTransition(to: panel)
                    state = .awaitingControlDispatch

                case .awaitingControlDispatch:
                    guard controlDispatch.isComplete else { return }
                    try requireKeyboardFocus(panel, checkpoint: "after Control down/up dispatch")
                    try postQueryText(to: panel)
                    state = .awaitingInitialQuery

                case .awaitingInitialQuery:
                    guard panel.query == Self.initialQuery else { return }
                    try requireKeyboardFocus(panel, checkpoint: "after the initial query")
                    try postKey(type: .keyDown, keyCode: UInt16(kVK_Delete), characters: "\u{7f}",
                                modifiers: [], to: panel, label: "Delete")
                    deleteKeyExercised = true
                    state = .awaitingDeletedQuery

                case .awaitingDeletedQuery:
                    guard panel.query == Self.committedQuery else { return }
                    try requireKeyboardFocus(panel, checkpoint: "after Delete")
                    state = .awaitingRows

                case .awaitingRows:
                    let rows = panel.displayedRows.compactMap(\.result)
                    guard rows.map(\.name) == Self.rowNames else { return }
                    guard rows.allSatisfy({ $0.name.unicodeScalars.contains(where: { $0.value > 127 }) }) else {
                        throw SmokeError.assertionFailed("result rows were not Unicode")
                    }
                    guard expectedPaths.count == 2,
                          selectedResultPath(in: panel) == expectedPaths[0].standardizedFileURL.path else {
                        throw SmokeError.assertionFailed("first row was not selected before Down")
                    }
                    try requireKeyboardFocus(panel, checkpoint: "before Down")
                    try postKey(type: .keyDown, keyCode: UInt16(kVK_DownArrow), characters: "",
                                modifiers: [], to: panel, label: "Down")
                    state = .awaitingDown

                case .awaitingDown:
                    guard expectedPaths.count == 2,
                          selectedResultPath(in: panel) == expectedPaths[1].standardizedFileURL.path else { return }
                    try requireKeyboardFocus(panel, checkpoint: "after Down and before Return")
                    try writer.writeSnapshot(of: panel)
                    try requireKeyboardFocus(panel, checkpoint: "after the selected-row snapshot and before Return")
                    try postKey(type: .keyDown, keyCode: UInt16(kVK_Return), characters: "\r",
                                modifiers: [], to: panel, label: "Return")
                    state = .awaitingOpen

                case .awaitingOpen:
                    let recorded = workspace.snapshot
                    guard recorded.opened.count <= 1 else {
                        throw SmokeError.assertionFailed("more than one workspace open was recorded")
                    }
                    guard recorded.applications.isEmpty, recorded.reveals.isEmpty else {
                        throw SmokeError.assertionFailed("app or reveal workspace operation was attempted")
                    }
                    guard recorded.opened.count == 1, !panel.isVisible else { return }
                    guard expectedPaths.count == 2,
                          recorded.opened[0].standardizedFileURL == expectedPaths[1].standardizedFileURL else {
                        throw SmokeError.assertionFailed("Down+Return did not choose exactly the second row")
                    }
                    try finishSuccess(panel: panel, recordedPath: recorded.opened[0].path)

                case .passed, .failed:
                    break
                }
            } catch {
                fail(error.localizedDescription)
            }
        }

        private func postControlTransition(to panel: SearchPanel) throws {
            guard let down = AppKitSmoke.makeControlEvent(isDown: true, windowNumber: panel.windowNumber),
                  let up = AppKitSmoke.makeControlEvent(isDown: false, windowNumber: panel.windowNumber) else {
                throw SmokeError.eventCreationFailed("Control flagsChanged")
            }
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }

        private func postQueryText(to panel: SearchPanel) throws {
            for (keyCode, character) in [(kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_X, "x")] {
                try postKey(type: .keyDown, keyCode: UInt16(keyCode), characters: character,
                            modifiers: [], to: panel, label: "query-\(character)")
            }
        }

        private func postKey(type: NSEvent.EventType, keyCode: UInt16, characters: String,
                             modifiers: NSEvent.ModifierFlags, to panel: SearchPanel,
                             label: String) throws {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else {
                throw SmokeError.eventCreationFailed(label)
            }
            NSApp.postEvent(event, atStart: false)
        }

        private func finishSuccess(panel: SearchPanel, recordedPath: String) throws {
            guard controlDispatch.isComplete, deleteKeyExercised else {
                throw SmokeError.assertionFailed("Control or Delete was not exercised")
            }
            let evidence = Evidence(
                schemaVersion: 1,
                status: "PASS",
                bundleIdentifier: bundleIdentifier,
                executable: executableName,
                markerVersion: markerVersion,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                processArchitecture: Self.processArchitecture,
                localeIdentifier: Locale.current.identifier,
                eventPath: "NSApplication.postEvent → SearchPanel local monitor/field editor → ResultsController → AppLauncher",
                exercisedControlKey: true,
                exercisedDeleteKey: true,
                panelStayedVisibleUntilOpen: panelStayedVisibleUntilOpen,
                committedQuery: Self.committedQuery,
                unicodeRows: Self.rowNames,
                recordedOpenPath: recordedPath,
                expectedSecondPath: expectedPaths[1].path,
                panelHidden: !panel.isVisible,
                elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                scopeLimitations: [
                    "Synthetic NSEvents do not prove a physical keyboard layout or hardware key path.",
                    "In-memory Unicode rows do not prove a real IME or macOS system-language workflow.",
                    "RecordingWorkspace proves selection dispatch without invoking NSWorkspace or LaunchServices.",
                    "An ad-hoc-signed derived clone run by its executable does not prove Gatekeeper assessment, notarization, quarantine handling, or a LaunchServices launch.",
                ]
            )
            try writer.writeEvidence(evidence)
            state = .passed
            passReadyForTermination = true
            timer?.cancel()
            timer = nil
            removeControlMonitor()
            NSApp.terminate(nil)
        }

        private func requireKeyboardFocus(_ panel: SearchPanel, checkpoint: String) throws {
            guard panel.isVisible, panel.isKeyWindow, panel.firstResponder is NSTextView else {
                panelStayedVisibleUntilOpen = false
                throw SmokeError.assertionFailed(
                    "panel lost visibility, key-window status, or text-field focus \(checkpoint)"
                )
            }
        }

        /// Reading the table selection after a queued Down event proves AppKit dispatched that event;
        /// posting it is not itself sufficient evidence. SearchPanel intentionally exposes row data but
        /// not its table, so locate the sole NSTableView in this private smoke panel hierarchy.
        private func selectedResultPath(in panel: SearchPanel) -> String? {
            guard let contentView = panel.contentView,
                  let table = firstTableView(in: contentView),
                  panel.displayedRows.indices.contains(table.selectedRow) else { return nil }
            return panel.displayedRows[table.selectedRow].result?.path
        }

        private func firstTableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = firstTableView(in: subview) { return table }
            }
            return nil
        }

        private func fail(_ message: String) {
            guard state != .failed else { return }
            state = .failed
            exitCode = 1
            timer?.cancel()
            timer = nil
            removeControlMonitor()
            writeStandardError("AppKit smoke FAIL: \(message)\n")
            // `terminate(_:)` exits the process with zero after delivering applicationWillTerminate,
            // which would turn a timed-out smoke into a false PASS at the process boundary. Stop the
            // run loop instead, then enqueue a wake-up event so `runJBar` can exit with `exitCode == 1`.
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }

        private func createFixtureDirectories() throws -> [URL] {
            try AppKitSmoke.ensureRootMatches(request)
            var output: [URL] = []
            for name in ["fixture-first", "fixture-second"] {
                let url = request.stateRoot.appendingPathComponent(name, isDirectory: true)
                let result = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
                    guard let representation else { return -1 }
                    return Darwin.mkdir(representation, 0o700)
                }
                guard result == 0 else {
                    throw SmokeError.unsafeOutput("could not create \(name) exclusively (errno \(errno))")
                }
                output.append(url)
            }
            try AppKitSmoke.ensureRootMatches(request)
            return output
        }

        private func installControlMonitor() {
            guard controlMonitor == nil else { return }
            controlMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { _ = self?.controlDispatch.observe(event) }
                return event
            }
        }

        private func removeControlMonitor() {
            guard let controlMonitor else { return }
            NSEvent.removeMonitor(controlMonitor)
            self.controlMonitor = nil
        }

        private static var processArchitecture: String {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }
    }

    static func writeStandardError(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
