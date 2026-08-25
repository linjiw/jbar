import Foundation

public enum CodexTransportMode: Equatable, Sendable {
    case chatOnly
    case workspaceAgent
}

/// A bounded JSONL transport for `codex app-server --listen stdio://`. It launches the verified
/// executable directly (never through a shell). Workspace-agent tool activity is received as
/// notifications; approval and other server-to-client requests remain fail-closed.
public actor CodexAppServerTransport {
    private static let maximumLineBytes = 4 * 1_024 * 1_024
    private static let maximumDiagnosticsBytes = 16 * 1_024
    private static let maximumQueuedNotifications = 2_048

    private let binary: VerifiedCodexBinary
    private let paths: CodexStatePaths
    private let mode: CodexTransportMode
    private let workingDirectory: URL
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var diagnostics = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var notifications: [JSONValue] = []
    private var fatalError: Error?
    private var started = false
    private var stopping = false

    public init(binary: VerifiedCodexBinary, paths: CodexStatePaths,
                mode: CodexTransportMode = .chatOnly, workingDirectory: URL? = nil) {
        self.binary = binary
        self.paths = paths
        self.mode = mode
        self.workingDirectory = workingDirectory ?? paths.scratch
    }

    public func start(environment sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard !started else { return }
        started = true

        process.executableURL = binary.url
        process.arguments = Self.arguments(for: mode)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = Self.sanitizedEnvironment(sourceEnvironment, codexHome: paths.codexHome.path)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }

        do { try process.run() }
        catch {
            clearHandlers()
            throw CodexConnectionError.launchFailed
        }
    }

    public func request(method: String, params: JSONValue = .object([:]),
                        timeout: TimeInterval = 15) async throws -> JSONValue {
        try checkHealthy()
        let id = nextRequestID
        nextRequestID += 1
        let message = JSONValue.object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(message)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    await self?.timeOutRequest(id)
                }
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func notify(method: String, params: JSONValue? = nil) throws {
        try checkHealthy()
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params { object["params"] = params }
        try write(.object(object))
    }

    /// Non-blocking notification retrieval. Session code polls this with a short asynchronous delay
    /// so task cancellation remains immediate without leaving an unresumed continuation behind.
    public func pollNotification() throws -> JSONValue? {
        try checkHealthy()
        guard !notifications.isEmpty else { return nil }
        return notifications.removeFirst()
    }

    public func stop() {
        guard !stopping else { return }
        stopping = true
        clearHandlers()
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        failPending(with: CodexConnectionError.turnFailed)
    }

    private func write(_ value: JSONValue) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) }
        catch { throw CodexConnectionError.protocolFailure("write") }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        guard stdoutBuffer.count <= Self.maximumLineBytes else {
            fail(with: CodexConnectionError.protocolFailure("oversized message"))
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                handle(message)
            } catch {
                fail(with: CodexConnectionError.protocolFailure("invalid JSON"))
                return
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty, diagnostics.count < Self.maximumDiagnosticsBytes else { return }
        diagnostics.append(data.prefix(Self.maximumDiagnosticsBytes - diagnostics.count))
    }

    private func handle(_ message: JSONValue) {
        guard let object = message.objectValue else {
            fail(with: CodexConnectionError.protocolFailure("non-object message"))
            return
        }
        if let id = object["id"]?.intValue, object["method"] == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexConnectionError.protocolFailure("rpc error"))
            }
            return
        }
        if object["id"] != nil, let method = object["method"]?.stringValue {
            // Both modes use approvalPolicy=never. Forms, approvals, and user-input requests are
            // intentionally outside this lightweight client's surface.
            if let id = object["id"] {
                try? write(.object([
                    "id": id,
                    "error": .object([
                        "code": .number(-32_601),
                        "message": .string("JBar Codex does not expose server requests"),
                    ]),
                ]))
            }
            fail(with: CodexConnectionError.toolAttempted(method))
            return
        }
        guard object["method"]?.stringValue != nil else {
            fail(with: CodexConnectionError.protocolFailure("unclassified message"))
            return
        }
        guard notifications.count < Self.maximumQueuedNotifications else {
            fail(with: CodexConnectionError.protocolFailure("notification flood"))
            return
        }
        notifications.append(message)
    }

    private func checkHealthy() throws {
        if let fatalError { throw fatalError }
        guard started, process.isRunning, !stopping else { throw CodexConnectionError.launchFailed }
    }

    private func timeOutRequest(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CodexConnectionError.requestTimedOut)
    }

    private func processTerminated(status: Int32) {
        guard !stopping else { return }
        fail(with: CodexConnectionError.protocolFailure("Codex exited with status \(status)"))
    }

    private func fail(with error: Error) {
        guard fatalError == nil else { return }
        fatalError = error
        failPending(with: error)
        if process.isRunning { process.terminate() }
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func clearHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    private static let disabledFeatures = [
        "apps", "browser_use", "code_mode", "computer_use", "goals",
        "hooks", "image_generation", "in_app_browser", "multi_agent", "multi_agent_v2",
        "plugins", "recommended_plugins", "remote_plugin", "skill_search", "tool_suggest",
        "view_image", "workspace_dependencies",
    ]

    static func arguments(for mode: CodexTransportMode) -> [String] {
        var result: [String] = []
        var features = disabledFeatures
        if mode == .chatOnly { features += ["code_mode_host", "shell_tool", "unified_exec"] }
        for feature in features { result += ["--disable", feature] }
        result += [
            "-c", "analytics.enabled=false",
            "-c", "check_for_update_on_startup=false",
            "-c", "allow_login_shell=false",
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "web_search=\"disabled\"",
            "app-server", "--listen", "stdio://",
        ]
        return result
    }

    static func sanitizedEnvironment(_ source: [String: String], codexHome: String) -> [String: String] {
        var result = source
        let removed = [
            "OPENAI_API_KEY", "OPENAI_PROJECT", "OPENAI_ORGANIZATION", "OPENAI_BASE_URL",
            "CODEX_API_KEY", "CODEX_CONFIG", "CODEX_HOME", "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE",
        ]
        removed.forEach { result.removeValue(forKey: $0) }
        result["CODEX_HOME"] = codexHome
        return result
    }
}
