import Foundation
import XCTest
@testable import JBarActions

final class CodexSafetyTests: XCTestCase {
    func testCodexVersionParsingAndMinimum() {
        XCTAssertEqual(CodexVersion.parse("codex-cli 0.149.0\n"), CodexVersion(0, 149, 0))
        XCTAssertEqual(CodexVersion.parse("1.2.34"), CodexVersion(1, 2, 34))
        XCTAssertNil(CodexVersion.parse("not codex"))
        XCTAssertLessThan(CodexVersion(0, 136, 0), CodexBinaryLocator.minimumVersion)
        XCTAssertGreaterThanOrEqual(CodexVersion(0, 149, 0), CodexBinaryLocator.minimumVersion)
    }

    func testCodexDiscoveryIncludesOfficialChatGPTBundleWithoutDependingOnShellPath() {
        let candidates = CodexBinaryLocator.candidatePaths(
            environment: ["JBAR_CODEX_PATH": "/chosen/codex", "PATH": "/custom/bin:/usr/bin"],
            homeDirectory: "/Users/example"
        )
        XCTAssertEqual(candidates.first, "/chosen/codex")
        XCTAssertTrue(candidates.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(candidates.contains(
            "/Users/example/Applications/ChatGPT.app/Contents/Resources/codex"
        ))
        XCTAssertTrue(candidates.contains("/custom/bin/codex"))
        XCTAssertLessThan(
            try XCTUnwrap(candidates.firstIndex(of: "/Applications/ChatGPT.app/Contents/Resources/codex")),
            try XCTUnwrap(candidates.firstIndex(of: "/custom/bin/codex")),
            "GUI discovery must not depend on inheriting an interactive shell PATH"
        )
    }

    func testJSONValueRoundTripsWithoutUntypedAny() throws {
        let value = JSONValue.object([
            "ok": .bool(true),
            "items": .array([.string("Luna"), .number(149), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testExpiredLoginExplainsThatTheOldBrowserPageCannotBeReused() throws {
        let message = try XCTUnwrap(CodexConnectionError.loginTimedOut.errorDescription)
        XCTAssertTrue(message.contains("Press Return"))
        XCTAssertTrue(message.contains("old browser page cannot be reused"))
    }

    func testChildEnvironmentRemovesBillingAndProviderCredentials() {
        let source = [
            "PATH": "/usr/bin", "OPENAI_API_KEY": "secret", "OPENAI_BASE_URL": "https://proxy",
            "OPENAI_PROJECT": "project", "AWS_ACCESS_KEY_ID": "aws", "CODEX_HOME": "/shared",
        ]
        let result = CodexAppServerTransport.sanitizedEnvironment(source, codexHome: "/isolated")
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["CODEX_HOME"], "/isolated")
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_PROJECT", "AWS_ACCESS_KEY_ID"] {
            XCTAssertNil(result[key])
        }
    }

    func testWorkspaceAgentEnablesOnlyLocalExecutionFeatures() {
        func isDisabled(_ feature: String, in arguments: [String]) -> Bool {
            arguments.indices.contains { index in
                index + 1 < arguments.count
                    && arguments[index] == "--disable"
                    && arguments[index + 1] == feature
            }
        }

        let chat = CodexAppServerTransport.arguments(for: .chatOnly)
        let agent = CodexAppServerTransport.arguments(for: .workspaceAgent)
        for feature in ["code_mode_host", "shell_tool", "unified_exec"] {
            XCTAssertTrue(isDisabled(feature, in: chat))
            XCTAssertFalse(isDisabled(feature, in: agent))
        }
        for feature in ["apps", "browser_use", "computer_use", "multi_agent", "plugins",
                        "remote_plugin", "skill_search", "view_image"] {
            XCTAssertTrue(isDisabled(feature, in: agent))
        }
        XCTAssertTrue(agent.contains("web_search=\"disabled\""))
        XCTAssertTrue(agent.contains("forced_login_method=\"chatgpt\""))
    }

    func testJBarWorkspaceMustBeOwnedDirectoryAndCannotEscapeThroughSymlink() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarWorkspace-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = temporary.appendingPathComponent("jbar", isDirectory: true)
        let outsideURL = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let workspace = try CodexWorkspace(url: workspaceURL)
        XCTAssertTrue(workspace.contains(workspaceURL.path))
        XCTAssertTrue(workspace.contains("Sources/File.swift"))
        XCTAssertFalse(workspace.contains(outsideURL.path))

        let escape = workspaceURL.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideURL)
        XCTAssertFalse(workspace.contains(escape.appendingPathComponent("file.txt").path))

        let linkedRoot = temporary.appendingPathComponent("linked-jbar", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: workspaceURL)
        XCTAssertThrowsError(try CodexWorkspace(url: linkedRoot)) {
            XCTAssertEqual($0 as? CodexConnectionError, .workspaceUnsafe)
        }

        let movedWorkspace = temporary.appendingPathComponent("moved-jbar", isDirectory: true)
        try FileManager.default.moveItem(at: workspaceURL, to: movedWorkspace)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try workspace.validateCurrent()) {
            XCTAssertEqual($0 as? CodexConnectionError, .workspaceUnsafe)
        }
        XCTAssertFalse(workspace.contains("Sources/New.swift"))
    }

    func testWorkspaceThreadAndToolEventsStayInsideJBar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try CodexWorkspace(url: root)

        func fixture(network: Bool = false, roots: [String]? = nil,
                     writableRoots: [String] = [], instructionSources: [String]? = nil) -> JSONValue {
            .object([
                "thread": .object([
                    "id": .string("agent-thread"), "modelProvider": .string("openai"),
                    "ephemeral": .bool(true), "cwd": .string(root.path),
                ]),
                "model": .string("gpt-5.6-luna"),
                "modelProvider": .string("openai"),
                "cwd": .string(root.path),
                "runtimeWorkspaceRoots": .array((roots ?? [root.path]).map(JSONValue.string)),
                "instructionSources": .array((instructionSources ?? [root.appendingPathComponent("AGENTS.md").path])
                    .map(JSONValue.string)),
                "approvalPolicy": .string("never"),
                "sandbox": .object([
                    "type": .string("workspaceWrite"),
                    "networkAccess": .bool(network),
                    "writableRoots": .array(writableRoots.map(JSONValue.string)),
                ]),
            ])
        }

        XCTAssertEqual(try CodexChatSession.validateWorkspaceThreadStart(fixture(), workspace: workspace),
                       "agent-thread")
        XCTAssertThrowsError(try CodexChatSession.validateWorkspaceThreadStart(
            fixture(network: true), workspace: workspace
        ))
        XCTAssertThrowsError(try CodexChatSession.validateWorkspaceThreadStart(
            fixture(roots: [root.deletingLastPathComponent().path]), workspace: workspace
        ))
        XCTAssertThrowsError(try CodexChatSession.validateWorkspaceThreadStart(
            fixture(writableRoots: [root.deletingLastPathComponent().path]), workspace: workspace
        ))
        XCTAssertThrowsError(try CodexChatSession.validateWorkspaceThreadStart(
            fixture(instructionSources: ["/private/tmp/outside-AGENTS.md"]), workspace: workspace
        ))

        let command = JSONValue.object([
            "id": .string("command-1"), "type": .string("commandExecution"),
            "command": .string("swift test"), "cwd": .string(root.path),
            "source": .string("agent"),
        ])
        XCTAssertEqual(try CodexChatSession.validatedCommand(command, workspace: workspace).command,
                       "swift test")
        var unifiedCommand = command.objectValue ?? [:]
        unifiedCommand["source"] = .string("unifiedExecStartup")
        XCTAssertNoThrow(try CodexChatSession.validatedCommand(.object(unifiedCommand),
                                                               workspace: workspace))
        var userShellCommand = command.objectValue ?? [:]
        userShellCommand["source"] = .string("userShell")
        XCTAssertThrowsError(try CodexChatSession.validatedCommand(.object(userShellCommand),
                                                                   workspace: workspace))
        var escapedCommand = command.objectValue ?? [:]
        escapedCommand["cwd"] = .string("/private/tmp")
        XCTAssertThrowsError(try CodexChatSession.validatedCommand(.object(escapedCommand),
                                                                   workspace: workspace))

        let fileChange = JSONValue.object([
            "id": .string("patch-1"), "type": .string("fileChange"),
            "changes": .array([.object([
                "path": .string(root.appendingPathComponent("Sources/File.swift").path),
                "kind": .object(["type": .string("update")]), "diff": .string(""),
            ])]),
        ])
        XCTAssertEqual(try CodexChatSession.fileChangeSummary(fileChange, workspace: workspace),
                       "UPDATE Sources/File.swift")

        let movedFile = JSONValue.object([
            "id": .string("patch-2"), "type": .string("fileChange"),
            "changes": .array([.object([
                "path": .string(root.appendingPathComponent("old.swift").path),
                "kind": .object([
                    "type": .string("update"),
                    "move_path": .string(root.appendingPathComponent("new.swift").path),
                ]),
                "diff": .string(""),
            ])]),
        ])
        XCTAssertEqual(try CodexChatSession.fileChangeSummary(movedFile, workspace: workspace),
                       "MOVE old.swift → new.swift")

        var escapedMove = movedFile["changes"]?.arrayValue?.first?.objectValue ?? [:]
        escapedMove["kind"] = .object([
            "type": .string("update"), "move_path": .string("/private/tmp/escaped.swift"),
        ])
        XCTAssertThrowsError(try CodexChatSession.fileChangeSummary(.object([
            "id": .string("patch-3"), "type": .string("fileChange"),
            "changes": .array([.object(escapedMove)]),
        ]), workspace: workspace))
    }

    func testOnlyChatGPTAccountPassesBillingGate() {
        XCTAssertNoThrow(try CodexTaskSession.validateAccount(.object([
            "type": .string("chatgpt"), "planType": .string("pro"),
        ])))
        for type in ["apiKey", "amazonBedrock"] {
            XCTAssertThrowsError(try CodexTaskSession.validateAccount(.object(["type": .string(type)]))) {
                XCTAssertEqual($0 as? CodexConnectionError, .unsupportedAccount)
            }
        }
        XCTAssertThrowsError(try CodexTaskSession.validateAccount(nil))
    }

    func testAccountRefreshRevalidatesWhileModelRerouteStillAborts() {
        XCTAssertEqual(CodexTaskSession.notificationSafetyAction(for: "account/updated"),
                       .revalidateAccount)
        XCTAssertEqual(CodexTaskSession.notificationSafetyAction(for: "model/rerouted"),
                       .abortUnsafeThread)
        XCTAssertEqual(CodexTaskSession.notificationSafetyAction(for: "turn/completed"),
                       .inspectNormally)
    }

    func testEndpointAndProviderOverridesFailClosed() {
        let safe = JSONValue.object([
            "config": .object([
                "model_provider": .null, "openai_base_url": .null,
                "chatgpt_base_url": .string("https://built-in.example"),
            ]),
            "origins": .object([:]),
        ])
        XCTAssertNoThrow(try CodexTaskSession.validateConfiguration(safe))

        let unsafeOpenAI = JSONValue.object([
            "config": .object(["openai_base_url": .string("https://proxy.invalid")]),
            "origins": .object([:]),
        ])
        XCTAssertThrowsError(try CodexTaskSession.validateConfiguration(unsafeOpenAI)) {
            XCTAssertEqual($0 as? CodexConnectionError, .unsafeConfiguration)
        }
        let unsafeChatGPT = JSONValue.object([
            "config": .object(["chatgpt_base_url": .string("https://proxy.invalid")]),
            "origins": .object(["chatgpt_base_url": .object(["source": .string("user")])]),
        ])
        XCTAssertThrowsError(try CodexTaskSession.validateConfiguration(unsafeChatGPT)) {
            XCTAssertEqual($0 as? CodexConnectionError, .unsafeConfiguration)
        }
        XCTAssertThrowsError(try CodexTaskSession.validateConfiguration(.object([
            "config": .object(["model_provider": .string("custom")]),
            "origins": .object([:]),
        ])))
        XCTAssertThrowsError(try CodexTaskSession.validateConfiguration(.object([
            "config": .object(["model_providers": .object(["custom": .object([:])])]),
            "origins": .object([:]),
        ])))
    }

    func testOAuthURLMustUseAnOfficialHTTPSHost() {
        XCTAssertTrue(CodexTaskSession.isApprovedLoginURL(URL(string: "https://auth.openai.com/authorize")!))
        XCTAssertTrue(CodexTaskSession.isApprovedLoginURL(URL(string: "https://chatgpt.com/auth")!))
        XCTAssertFalse(CodexTaskSession.isApprovedLoginURL(URL(string: "http://auth.openai.com/authorize")!))
        XCTAssertFalse(CodexTaskSession.isApprovedLoginURL(URL(string: "https://openai.com.attacker.invalid/")!))
        XCTAssertFalse(CodexTaskSession.isApprovedLoginURL(URL(string: "https://127.0.0.1/login")!))
    }

    func testLunaMustBeVisibleAndSupportLowEffort() throws {
        let catalog = JSONValue.object(["data": .array([
            .object([
                "model": .string("gpt-5.6-luna"),
                "hidden": .bool(false),
                "supportedReasoningEfforts": .array([
                    .object(["reasoningEffort": .string("low")]),
                ]),
            ]),
        ])])
        XCTAssertEqual(try CodexTaskSession.selectLunaEffort(catalog), "low")

        let fallbackOnly = JSONValue.object(["data": .array([
            .object([
                "model": .string("gpt-5.6-terra"),
                "hidden": .bool(false),
                "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("low")])]),
            ]),
        ])])
        XCTAssertThrowsError(try CodexTaskSession.selectLunaEffort(fallbackOnly)) {
            XCTAssertEqual($0 as? CodexConnectionError, .lunaUnavailable)
        }
    }

    func testThreadResponseMustMatchEveryPrivacyBoundary() throws {
        let scratch = URL(fileURLWithPath: "/private/tmp/JBarSafetyScratch", isDirectory: true)
        func fixture(instructionSources: [JSONValue] = [], network: Bool = false,
                     reasoningEffort: String = "low") -> JSONValue {
            .object([
                "thread": .object([
                    "id": .string("thread-1"), "modelProvider": .string("openai"),
                    "ephemeral": .bool(true), "cwd": .string(scratch.path),
                ]),
                "model": .string("gpt-5.6-luna"),
                "modelProvider": .string("openai"),
                "cwd": .string(scratch.path),
                "runtimeWorkspaceRoots": .array([]),
                "instructionSources": .array(instructionSources),
                "approvalPolicy": .string("never"),
                "sandbox": .object(["type": .string("readOnly"), "networkAccess": .bool(network)]),
                "reasoningEffort": .string(reasoningEffort),
            ])
        }
        XCTAssertEqual(try CodexTaskSession.validateThreadStart(fixture(), scratch: scratch),
                       "thread-1")
        XCTAssertThrowsError(try CodexTaskSession.validateThreadStart(
            fixture(instructionSources: [.string("AGENTS.md")]), scratch: scratch
        ))
        XCTAssertThrowsError(try CodexTaskSession.validateThreadStart(
            fixture(network: true), scratch: scratch
        ))

        // Reasoning effort is a turn/start override in the app-server protocol, not an
        // authoritative thread/start response field. The session sends "low" explicitly later.
        XCTAssertEqual(try CodexTaskSession.validateThreadStart(
            fixture(reasoningEffort: "medium"), scratch: scratch
        ),
                       "thread-1")
    }

    func testStateDirectoriesAreOwnerOnlyAndSymlinksAreRejected() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarCodexSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let paths = try CodexStatePaths.prepare(applicationSupportRoot: temporary)
        for url in [paths.root, paths.codexHome, paths.scratch] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }

        let unsafeSupport = temporary.appendingPathComponent("unsafe", isDirectory: true)
        let target = temporary.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeSupport, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: unsafeSupport.appendingPathComponent("JBar"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try CodexStatePaths.prepare(applicationSupportRoot: unsafeSupport)) {
            XCTAssertEqual($0 as? CodexConnectionError, .stateDirectoryUnsafe)
        }
    }

    /// Opt-in because it starts the locally installed Codex process. It does not open a browser or
    /// send a turn; it verifies initialize, isolated account state, and ChatGPT OAuth URL generation.
    func testIsolatedCodexAppServerAndOAuthHandshake() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JBAR_CODEX_INTEGRATION_TEST"] == "1",
              let rawBinary = environment["JBAR_CODEX_PATH"] else {
            throw XCTSkip("Set JBAR_CODEX_INTEGRATION_TEST=1 and JBAR_CODEX_PATH to run")
        }
        let url = URL(fileURLWithPath: rawBinary).resolvingSymlinksInPath()
        let output = try runVersion(url)
        let version = try XCTUnwrap(CodexVersion.parse(output))
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("JBarCodexIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let paths = try CodexStatePaths.prepare(applicationSupportRoot: temporary)
        let transport = CodexAppServerTransport(binary: VerifiedCodexBinary(url: url, version: version), paths: paths)
        try await transport.start()
        defer { Task { await transport.stop() } }

        let initialized = try await transport.request(method: "initialize", params: .object([
            "clientInfo": .object([
                "name": .string("jbar-test"), "title": .string("JBar Test"), "version": .string("0"),
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true), "requestAttestation": .bool(false),
            ]),
        ]))
        XCTAssertNotNil(initialized.objectValue)
        try await transport.notify(method: "initialized")
        let account = try await transport.request(method: "account/read", params: .object([
            "refreshToken": .bool(false),
        ]))
        XCTAssertEqual(account["account"], .null, "the temporary JBar Codex Home must start isolated")
        let config = try await transport.request(method: "config/read", params: .object([
            "includeLayers": .bool(true), "cwd": .string(paths.scratch.path),
        ]))
        XCTAssertNoThrow(try CodexTaskSession.validateConfiguration(config))

        let login = try await transport.request(method: "account/login/start", params: .object([
            "type": .string("chatgpt"), "codexStreamlinedLogin": .bool(true),
            "useHostedLoginSuccessPage": .bool(false),
        ]), timeout: 30)
        let loginID = try XCTUnwrap(login["loginId"]?.stringValue)
        let loginURL = try XCTUnwrap(login["authUrl"]?.stringValue.flatMap(URL.init(string:)))
        XCTAssertTrue(CodexTaskSession.isApprovedLoginURL(loginURL))
        let queryItems = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = queryItems.first(where: { $0.name == "redirect_uri" })?.value
            .flatMap(URL.init(string:))
        XCTAssertEqual(redirect?.scheme, "http")
        XCTAssertEqual(redirect?.host, "localhost")

        // Mimic the browser taking focus while OAuth remains pending. The app-server (and therefore
        // its temporary localhost callback listener) must still be alive and answering requests.
        try await Task.sleep(nanoseconds: 750_000_000)
        let pendingAccount = try await transport.request(method: "account/read", params: .object([
            "refreshToken": .bool(false),
        ]))
        XCTAssertEqual(pendingAccount["account"], .null)
        _ = try await transport.request(method: "account/login/cancel", params: .object([
            "loginId": .string(loginID),
        ]))
        await transport.stop()
    }

    private func runVersion(_ executable: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
