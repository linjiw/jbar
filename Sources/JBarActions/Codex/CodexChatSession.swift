import Foundation

public typealias CodexAnswerUpdateHandler = @MainActor @Sendable (String) -> Void
public typealias CodexAgentEventHandler = @MainActor @Sendable (CodexAgentEvent) -> Void

/// Visible, bounded activity emitted by the local Codex workspace agent.
public enum CodexAgentEvent: Equatable, Sendable {
    case commandStarted(id: String, command: String, cwd: String)
    case commandOutput(id: String, output: String)
    case commandCompleted(id: String, command: String, output: String, exitCode: Int?)
    case filesChanged(id: String, summary: String)
}

/// A reusable Codex workspace conversation. The app server and ephemeral thread live only while
/// the agent window is open; every turn repeats the model, approval, network, and workspace locks.
public actor CodexChatSession {
    public static let model = CodexTaskSession.model
    public static let maximumPromptCharacters = CodexTaskSession.maximumPromptCharacters
    private static let maximumAnswerCharacters = 100_000
    private static let maximumCommandOutputCharacters = 100_000

    private let workspace: CodexWorkspace
    private let locator: CodexBinaryLocator
    private let applicationSupportRoot: URL?
    private var paths: CodexStatePaths?
    private var transport: CodexAppServerTransport?
    private var threadID: String?
    private var effort: String?
    private var activeTurnID: String?
    private var sending = false
    private var closed = false

    public init(workspace: CodexWorkspace, locator: CodexBinaryLocator = CodexBinaryLocator(),
                applicationSupportRoot: URL? = nil) {
        self.workspace = workspace
        self.locator = locator
        self.applicationSupportRoot = applicationSupportRoot
    }

    /// Sends one explicit user turn. The handlers receive only displayable assistant text and
    /// bounded workspace activity, and always run on the main actor.
    public func send(_ prompt: String, openLoginURL: @escaping CodexLoginURLHandler,
                     progress: @escaping PaletteActionProgressHandler = { _ in },
                     onEvent: @escaping CodexAgentEventHandler = { _ in },
                     onUpdate: @escaping CodexAnswerUpdateHandler = { _ in }) async throws -> String {
        guard !closed else { throw CodexConnectionError.sessionClosed }
        guard !sending else { throw CodexConnectionError.sessionBusy }
        try workspace.validateCurrent()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodexConnectionError.emptyAnswer }
        guard trimmed.count <= Self.maximumPromptCharacters else { throw CodexConnectionError.promptTooLong }

        sending = true
        defer { sending = false }
        let connection = try await ensureConnected(openLoginURL: openLoginURL, progress: progress)
        try ensureOpen()
        try workspace.validateCurrent()

        await progress(.generatingAnswer)
        let turnStart = try await connection.transport.request(method: "turn/start", params: .object([
            "threadId": .string(connection.threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(trimmed),
                    "text_elements": .array([]),
                ]),
            ]),
            "cwd": .string(workspace.url.path),
            "runtimeWorkspaceRoots": .array([.string(workspace.url.path)]),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(workspace.url.path)]),
                "networkAccess": .bool(false),
            ]),
            "model": .string(Self.model),
            "effort": .string(connection.effort),
        ]), timeout: 30)
        guard let turnID = turnStart["turn"]?["id"]?.stringValue else {
            throw CodexConnectionError.protocolFailure("turn/start")
        }
        activeTurnID = turnID
        do {
            let answer = try await waitForAnswer(threadID: connection.threadID, turnID: turnID,
                                                 transport: connection.transport, timeout: 180,
                                                 onEvent: onEvent, onUpdate: onUpdate)
            if activeTurnID == turnID { activeTurnID = nil }
            return answer
        } catch {
            if activeTurnID == turnID {
                _ = try? await interrupt(threadID: connection.threadID, turnID: turnID,
                                         transport: connection.transport)
                activeTurnID = nil
            }
            throw error
        }
    }

    /// Stops only the active answer and leaves the private workspace conversation ready.
    public func cancelCurrentTurn() async {
        guard let transport, let threadID, let activeTurnID else { return }
        _ = try? await interrupt(threadID: threadID, turnID: activeTurnID, transport: transport)
    }

    /// Permanently ends this in-memory conversation and its child app-server process.
    public func close() async {
        guard !closed else { return }
        closed = true
        if let transport, let threadID, let activeTurnID {
            _ = try? await interrupt(threadID: threadID, turnID: activeTurnID, transport: transport)
        }
        activeTurnID = nil
        if let transport { await transport.stop() }
        self.transport = nil
        paths = nil
        threadID = nil
        effort = nil
    }

    private struct Connection {
        let transport: CodexAppServerTransport
        let threadID: String
        let effort: String
    }

    private func ensureConnected(openLoginURL: @escaping CodexLoginURLHandler,
                                 progress: @escaping PaletteActionProgressHandler) async throws -> Connection {
        if let transport, let threadID, let effort {
            try workspace.validateCurrent()
            return Connection(transport: transport, threadID: threadID, effort: effort)
        }
        try workspace.validateCurrent()
        try ensureOpen()
        await progress(.connectingToCodex)
        let binary = try locator.locate()
        let preparedPaths = try CodexStatePaths.prepare(applicationSupportRoot: applicationSupportRoot)
        let newTransport = CodexAppServerTransport(binary: binary, paths: preparedPaths,
                                                   mode: .workspaceAgent,
                                                   workingDirectory: workspace.url)
        paths = preparedPaths
        transport = newTransport
        do {
            try await newTransport.start()
            try ensureOpen()
            let initialized = try await newTransport.request(method: "initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("jbar"),
                    "title": .string("JBar"),
                    "version": .string("0.2.0-dev"),
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                    "requestAttestation": .bool(false),
                    "optOutNotificationMethods": .array([]),
                ]),
            ]))
            guard initialized.objectValue != nil else {
                throw CodexConnectionError.protocolFailure("initialize")
            }
            try await newTransport.notify(method: "initialized")
            try ensureOpen()

            await progress(.checkingAccountAndSafety)
            var account = try await readAccount(newTransport)
            if account == nil {
                try await signIn(newTransport, openLoginURL: openLoginURL, progress: progress)
                await progress(.checkingAccountAndSafety)
                account = try await readAccount(newTransport)
            }
            try CodexTaskSession.validateAccount(account)
            try ensureOpen()

            let config = try await newTransport.request(method: "config/read", params: .object([
                "includeLayers": .bool(true),
                "cwd": .string(workspace.url.path),
            ]))
            try CodexTaskSession.validateConfiguration(config)
            try ensureOpen()

            await progress(.preparingLuna)
            let catalog = try await newTransport.request(method: "model/list", params: .object([
                "includeHidden": .bool(false),
                "limit": .number(100),
            ]))
            let selectedEffort = try CodexTaskSession.selectLunaEffort(catalog)
            try ensureOpen()

            let threadStart = try await newTransport.request(method: "thread/start", params: .object([
                "model": .string(Self.model),
                "modelProvider": .string("openai"),
                "allowProviderModelFallback": .bool(false),
                "cwd": .string(workspace.url.path),
                "runtimeWorkspaceRoots": .array([.string(workspace.url.path)]),
                "approvalPolicy": .string("never"),
                "sandbox": .string("workspace-write"),
                "developerInstructions": .string(Self.developerInstructions),
                "personality": .string("pragmatic"),
                "serviceName": .string("jbar"),
                "ephemeral": .bool(true),
                "dynamicTools": .array([]),
            ]), timeout: 30)
            let startedThreadID = try Self.validateWorkspaceThreadStart(threadStart,
                                                                        workspace: workspace)
            try ensureOpen()
            threadID = startedThreadID
            effort = selectedEffort
            return Connection(transport: newTransport, threadID: startedThreadID,
                              effort: selectedEffort)
        } catch {
            await newTransport.stop()
            if transport === newTransport { transport = nil }
            paths = nil
            threadID = nil
            effort = nil
            throw error
        }
    }

    private func readAccount(_ transport: CodexAppServerTransport) async throws -> JSONValue? {
        let result = try await transport.request(method: "account/read", params: .object([
            "refreshToken": .bool(false),
        ]))
        guard result.objectValue != nil else { throw CodexConnectionError.protocolFailure("account/read") }
        if result["account"] == .null { return nil }
        return result["account"]
    }

    private func signIn(_ transport: CodexAppServerTransport,
                        openLoginURL: @escaping CodexLoginURLHandler,
                        progress: @escaping PaletteActionProgressHandler) async throws {
        let result = try await transport.request(method: "account/login/start", params: .object([
            "type": .string("chatgpt"),
            "codexStreamlinedLogin": .bool(true),
            "useHostedLoginSuccessPage": .bool(false),
        ]), timeout: 30)
        guard result["type"]?.stringValue == "chatgpt",
              let loginID = result["loginId"]?.stringValue,
              let rawURL = result["authUrl"]?.stringValue,
              let url = URL(string: rawURL), CodexTaskSession.isApprovedLoginURL(url) else {
            throw CodexConnectionError.protocolFailure("login URL")
        }
        guard await openLoginURL(url) else { throw CodexConnectionError.loginCouldNotOpen }
        await progress(.waitingForChatGPTSignIn)

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try ensureOpen()
            if let notification = try await transport.pollNotification(),
               notification["method"]?.stringValue == "account/login/completed",
               notification["params"]?["loginId"]?.stringValue == loginID {
                guard notification["params"]?["success"]?.boolValue == true else {
                    throw CodexConnectionError.loginFailed
                }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CodexConnectionError.loginTimedOut
    }

    private func waitForAnswer(threadID: String, turnID: String, transport: CodexAppServerTransport,
                               timeout: TimeInterval, onEvent: @escaping CodexAgentEventHandler,
                               onUpdate: @escaping CodexAnswerUpdateHandler) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var finalMessage = ""
        var streamedMessage = ""
        var streamingItemID: String?
        var commands: [String: (command: String, cwd: String, output: String)] = [:]
        while Date() < deadline {
            try ensureOpen()
            guard let notification = try await transport.pollNotification() else {
                try await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            let method = notification["method"]?.stringValue ?? ""
            let params = notification["params"]
            if method == "account/updated" || method == "model/rerouted" {
                try await stopUnsafe(method, threadID: threadID, turnID: turnID, transport: transport)
            }
            if Self.forbiddenNotificationPrefixes.contains(where: { method.hasPrefix($0) }) {
                _ = try? await interrupt(threadID: threadID, turnID: turnID, transport: transport)
                throw CodexConnectionError.toolAttempted(method)
            }
            if method == "item/started" || method == "item/completed" {
                guard Self.belongsToTurn(params, threadID: threadID, turnID: turnID) else { continue }
                let item = params?["item"]
                let type = item?["type"]?.stringValue ?? "unknown"
                guard Self.allowedItemTypes.contains(type) else {
                    _ = try? await interrupt(threadID: threadID, turnID: turnID, transport: transport)
                    throw CodexConnectionError.toolAttempted(type)
                }
                switch (method, type) {
                case ("item/started", "agentMessage"):
                    streamingItemID = item?["id"]?.stringValue
                    streamedMessage = ""
                case ("item/completed", "agentMessage"):
                    if let text = item?["text"]?.stringValue, !text.isEmpty {
                        finalMessage = text
                        await onUpdate(text)
                    }
                case ("item/started", "commandExecution"):
                    let command = try Self.validatedCommand(item, workspace: workspace)
                    commands[command.id] = (command.command, command.cwd, "")
                    await onEvent(.commandStarted(id: command.id, command: command.command,
                                                  cwd: command.cwd))
                case ("item/completed", "commandExecution"):
                    let command = try Self.validatedCommand(item, workspace: workspace)
                    let eventOutput = item?["aggregatedOutput"]?.stringValue
                        ?? commands[command.id]?.output ?? ""
                    guard eventOutput.count <= Self.maximumCommandOutputCharacters else {
                        try await stopUnsafe("oversized command output", threadID: threadID,
                                             turnID: turnID, transport: transport)
                    }
                    commands.removeValue(forKey: command.id)
                    await onEvent(.commandCompleted(id: command.id, command: command.command,
                                                    output: eventOutput,
                                                    exitCode: item?["exitCode"]?.intValue))
                case ("item/completed", "fileChange"):
                    let summary = try Self.fileChangeSummary(item, workspace: workspace)
                    if let id = item?["id"]?.stringValue {
                        await onEvent(.filesChanged(id: id, summary: summary))
                    }
                default:
                    break
                }
            }
            if method == "item/commandExecution/outputDelta",
               Self.belongsToTurn(params, threadID: threadID, turnID: turnID),
               let itemID = params?["itemId"]?.stringValue,
               let delta = params?["delta"]?.stringValue, !delta.isEmpty,
               var command = commands[itemID] {
                command.output += delta
                guard command.output.count <= Self.maximumCommandOutputCharacters else {
                    try await stopUnsafe("oversized command output", threadID: threadID,
                                         turnID: turnID, transport: transport)
                }
                commands[itemID] = command
                await onEvent(.commandOutput(id: itemID, output: command.output))
            }
            if method == "item/agentMessage/delta",
               Self.belongsToTurn(params, threadID: threadID, turnID: turnID),
               Self.belongsToItem(params, itemID: streamingItemID),
               let delta = params?["delta"]?.stringValue, !delta.isEmpty {
                streamedMessage += delta
                guard streamedMessage.count <= Self.maximumAnswerCharacters else {
                    try await stopUnsafe("oversized answer", threadID: threadID,
                                         turnID: turnID, transport: transport)
                }
                await onUpdate(streamedMessage)
            }
            if method == "turn/completed",
               params?["threadId"]?.stringValue == threadID,
               params?["turn"]?["id"]?.stringValue == turnID {
                guard params?["turn"]?["status"]?.stringValue == "completed" else {
                    throw CodexConnectionError.turnFailed
                }
                if finalMessage.isEmpty {
                    finalMessage = Self.lastAgentMessage(in: params?["turn"]?["items"])
                }
                if finalMessage.isEmpty { finalMessage = streamedMessage }
                let trimmed = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw CodexConnectionError.emptyAnswer }
                guard trimmed.count <= Self.maximumAnswerCharacters else {
                    throw CodexConnectionError.protocolFailure("oversized answer")
                }
                await onUpdate(trimmed)
                return trimmed
            }
        }
        _ = try? await interrupt(threadID: threadID, turnID: turnID, transport: transport)
        throw CodexConnectionError.requestTimedOut
    }

    private func stopUnsafe(_ reason: String, threadID: String, turnID: String,
                            transport: CodexAppServerTransport) async throws -> Never {
        _ = try? await interrupt(threadID: threadID, turnID: turnID, transport: transport)
        throw CodexConnectionError.unsafeThread(reason)
    }

    private func interrupt(threadID: String, turnID: String,
                           transport: CodexAppServerTransport) async throws -> JSONValue {
        try await transport.request(method: "turn/interrupt", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID),
        ]), timeout: 2)
    }

    private func ensureOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CodexConnectionError.sessionClosed }
    }

    static func validateWorkspaceThreadStart(_ response: JSONValue,
                                             workspace: CodexWorkspace) throws -> String {
        let expectedPath = workspace.url.resolvingSymlinksInPath().standardizedFileURL.path
        func canonical(_ value: JSONValue?) -> String? {
            value?.stringValue.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
        guard let threadID = response["thread"]?["id"]?.stringValue, !threadID.isEmpty else {
            throw CodexConnectionError.unsafeThread("missing thread id")
        }
        guard response["model"]?.stringValue == Self.model else {
            throw CodexConnectionError.unsafeThread("model mismatch")
        }
        guard response["modelProvider"]?.stringValue == "openai",
              response["thread"]?["modelProvider"]?.stringValue == "openai" else {
            throw CodexConnectionError.unsafeThread("provider mismatch")
        }
        guard response["thread"]?["ephemeral"]?.boolValue == true else {
            throw CodexConnectionError.unsafeThread("thread is not ephemeral")
        }
        guard canonical(response["cwd"]) == expectedPath,
              canonical(response["thread"]?["cwd"]) == expectedPath else {
            throw CodexConnectionError.unsafeThread("working directory mismatch")
        }
        let roots = response["runtimeWorkspaceRoots"]?.arrayValue?.compactMap { canonical($0) }
        guard roots == [expectedPath] else {
            throw CodexConnectionError.unsafeThread("workspace roots mismatch")
        }
        guard let instructionSources = response["instructionSources"]?.arrayValue,
              instructionSources.allSatisfy({ source in
                  source.stringValue.map(workspace.contains) == true
              }) else {
            throw CodexConnectionError.unsafeThread("instruction source escaped workspace")
        }
        guard response["approvalPolicy"]?.stringValue == "never" else {
            throw CodexConnectionError.unsafeThread("approval policy mismatch")
        }
        let sandbox = response["sandbox"]
        let writableValues = sandbox?["writableRoots"]?.arrayValue
        let writableRoots = writableValues?.compactMap { canonical($0) }
        guard sandbox?["type"]?.stringValue == "workspaceWrite",
              sandbox?["networkAccess"]?.boolValue == false,
              let writableValues, let writableRoots,
              writableRoots.count == writableValues.count,
              writableRoots.allSatisfy({ root in
                  root == expectedPath || root.hasPrefix(expectedPath + "/")
              }) else {
            throw CodexConnectionError.unsafeThread("sandbox mismatch")
        }
        return threadID
    }

    static func validatedCommand(_ item: JSONValue?, workspace: CodexWorkspace) throws
        -> (id: String, command: String, cwd: String) {
        guard let id = item?["id"]?.stringValue, !id.isEmpty,
              let command = item?["command"]?.stringValue, !command.isEmpty,
              let cwd = item?["cwd"]?.stringValue, workspace.contains(cwd),
              allowedCommandSources.contains(item?["source"]?.stringValue ?? "agent") else {
            throw CodexConnectionError.unsafeThread("invalid command source or working directory")
        }
        return (id, command, cwd)
    }

    static func fileChangeSummary(_ item: JSONValue?, workspace: CodexWorkspace) throws -> String {
        guard let changes = item?["changes"]?.arrayValue, !changes.isEmpty else {
            throw CodexConnectionError.protocolFailure("file change")
        }
        return try changes.map { change in
            guard let path = change["path"]?.stringValue, workspace.contains(path) else {
                throw CodexConnectionError.unsafeThread("file change escaped workspace")
            }
            guard let kind = change["kind"]?["type"]?.stringValue,
                  ["add", "delete", "update"].contains(kind) else {
                throw CodexConnectionError.protocolFailure("file change kind")
            }
            if let movePath = change["kind"]?["move_path"]?.stringValue {
                guard workspace.contains(movePath) else {
                    throw CodexConnectionError.unsafeThread("file move escaped workspace")
                }
                return "MOVE \(workspace.relativePath(path)) → \(workspace.relativePath(movePath))"
            }
            return "\(kind.uppercased()) \(workspace.relativePath(path))"
        }.joined(separator: "\n")
    }

    private static let developerInstructions = """
        Work as a lightweight coding agent in this JBar repository. Read and follow its AGENTS.md. \
        Treat questions, explanations, reviews, and diagnosis as read-only. Modify files only when \
        the user explicitly asks for a change. Never install, publish, ship, deploy, or discard \
        existing work unless explicitly requested. Network access is unavailable. Keep commands \
        focused, preserve the dirty worktree, and verify requested changes locally.
        """

    private static let allowedCommandSources = Set([
        "agent", "unifiedExecStartup", "unifiedExecInteraction",
    ])

    private static let allowedItemTypes = Set([
        "userMessage", "agentMessage", "reasoning", "plan", "contextCompaction",
        "commandExecution", "fileChange",
    ])

    private static let forbiddenNotificationPrefixes = [
        "command/", "process/", "item/mcpToolCall", "mcpServer/", "fs/", "item/image",
        "item/webSearch", "item/collab", "item/subAgent", "hook/",
    ]

    private static func belongsToTurn(_ params: JSONValue?, threadID: String, turnID: String) -> Bool {
        let notificationThread = params?["threadId"]?.stringValue
        let notificationTurn = params?["turnId"]?.stringValue
        return (notificationThread == nil || notificationThread == threadID)
            && (notificationTurn == nil || notificationTurn == turnID)
    }

    private static func belongsToItem(_ params: JSONValue?, itemID: String?) -> Bool {
        guard let itemID else { return true }
        guard let notificationItem = params?["itemId"]?.stringValue else { return true }
        return notificationItem == itemID
    }

    private static func lastAgentMessage(in items: JSONValue?) -> String {
        items?.arrayValue?.reversed().first(where: {
            $0["type"]?.stringValue == "agentMessage"
        })?["text"]?.stringValue ?? ""
    }
}
