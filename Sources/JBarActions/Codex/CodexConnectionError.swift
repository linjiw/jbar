import Foundation

public enum CodexConnectionError: Error, Equatable, Sendable {
    case codexNotFound
    case unsupportedVersion(found: String, required: String)
    case invalidCodexBinary
    case stateDirectoryUnsafe
    case workspaceUnsafe
    case launchFailed
    case protocolFailure(String)
    case requestTimedOut
    case loginRequired
    case loginCouldNotOpen
    case loginFailed
    case loginTimedOut
    case unsupportedAccount
    case unsafeConfiguration
    case lunaUnavailable
    case unsafeThread(String)
    case toolAttempted(String)
    case turnFailed
    case sessionBusy
    case sessionClosed
    case emptyAnswer
    case promptTooLong
}

extension CodexConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex was not found. Install or update the official Codex CLI, then try again."
        case .unsupportedVersion(let found, let required):
            return "Codex \(found) is too old for safe Luna Ask. Version \(required) or newer is required."
        case .invalidCodexBinary:
            return "The selected Codex executable could not be verified."
        case .stateDirectoryUnsafe:
            return "JBar refused an unsafe Codex state directory."
        case .workspaceUnsafe:
            return "JBar could not safely open ~/jbar as the Codex workspace. The folder must exist, be owned by you, not be group/world-writable, and not be a symbolic link."
        case .launchFailed:
            return "JBar could not start the local Codex app server."
        case .protocolFailure:
            return "Codex returned an incompatible response. No question was sent."
        case .requestTimedOut:
            return "Codex did not respond in time."
        case .loginRequired:
            return "Sign in with ChatGPT to use your Codex allowance."
        case .loginCouldNotOpen:
            return "JBar could not open the ChatGPT sign-in page."
        case .loginFailed:
            return "ChatGPT sign-in did not complete. Please try again."
        case .loginTimedOut:
            return "ChatGPT sign-in expired. Press Return to start a fresh secure login; an old browser page cannot be reused."
        case .unsupportedAccount:
            return "JBar Ask only permits ChatGPT Codex accounts; API-key and Bedrock billing are blocked."
        case .unsafeConfiguration:
            return "JBar blocked a custom Codex provider or endpoint before sending your question."
        case .lunaUnavailable:
            return "GPT-5.6 Luna is not available for this Codex account. JBar did not fall back to another model."
        case .unsafeThread(let reason):
            return "Codex could not maintain the required private workspace task (\(reason)). JBar stopped it safely."
        case .toolAttempted(let type):
            return "Codex attempted a disabled capability (\(type)); JBar stopped the request."
        case .turnFailed:
            return "Codex could not complete this answer."
        case .sessionBusy:
            return "Wait for the current Codex answer to finish before sending another message."
        case .sessionClosed:
            return "This private Codex chat has ended. Open a new chat from JBar."
        case .emptyAnswer:
            return "Codex completed without returning an answer."
        case .promptTooLong:
            return "This Codex Agent message is too long. Keep it under 16,000 characters."
        }
    }
}
