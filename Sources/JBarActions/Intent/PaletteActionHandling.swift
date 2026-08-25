import Foundation

/// The result of an explicitly submitted palette action. This is intentionally presentation-light:
/// action implementations cannot hand a panel arbitrary views or executable work.
public struct PaletteActionResult: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case openedSession
        case answer
        case notice
        case error
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Bounded, non-sensitive milestones for one explicitly submitted action. Implementations must not
/// put prompt text, account identifiers, URLs, paths, or server diagnostics into progress updates.
public enum PaletteActionProgress: Equatable, Sendable {
    case connectingToCodex
    case waitingForChatGPTSignIn
    case checkingAccountAndSafety
    case preparingLuna
    case generatingAnswer
}

/// Progress is rendered by the AppKit client, so updates are delivered on the main actor. Keeping
/// the closure strongly typed prevents action implementations from injecting arbitrary UI.
public typealias PaletteActionProgressHandler = @MainActor @Sendable (PaletteActionProgress) -> Void

/// Future Codex and native action implementations share this narrow boundary. Constructing an
/// intent or rendering its draft must never call this method; only an explicit Enter submission may.
public protocol PaletteActionHandling: Sendable {
    func submit(_ intent: PaletteIntent,
                progress: @escaping PaletteActionProgressHandler) async -> PaletteActionResult
}

public extension PaletteActionHandling {
    /// Convenience for non-UI callers that do not need intermediate milestones.
    func submit(_ intent: PaletteIntent) async -> PaletteActionResult {
        await submit(intent, progress: { _ in })
    }
}
