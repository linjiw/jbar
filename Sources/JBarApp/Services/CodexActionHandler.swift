import JBarActions

typealias AssistantPresentationHandler = @MainActor @Sendable (String) -> Bool
typealias OrganizePresentationHandler = @MainActor @Sendable (String) -> Bool
typealias DeveloperAgentPresentationHandler = @MainActor @Sendable (String) -> Bool

/// The palette-to-window boundary. Assistant and Developer Agent are intentionally separate
/// presentation handlers so a consumer file question cannot inherit repository tool access.
actor CodexActionHandler: PaletteActionHandling {
    private let presentAssistant: AssistantPresentationHandler?
    private let presentOrganize: OrganizePresentationHandler?
    private let presentDeveloperAgent: DeveloperAgentPresentationHandler?

    init(presentAssistant: AssistantPresentationHandler? = nil,
         presentOrganize: OrganizePresentationHandler? = nil,
         presentDeveloperAgent: DeveloperAgentPresentationHandler? = nil) {
        self.presentAssistant = presentAssistant
        self.presentOrganize = presentOrganize
        self.presentDeveloperAgent = presentDeveloperAgent
    }

    func submit(_ intent: PaletteIntent,
                progress: @escaping PaletteActionProgressHandler) async -> PaletteActionResult {
        switch intent {
        case .ask(let prompt):
            guard let presentAssistant else {
                return PaletteActionResult(kind: .error, text: "The Assistant window is unavailable in this build.")
            }
            guard await presentAssistant(prompt) else {
                return PaletteActionResult(kind: .error, text: "JBar could not open Assistant.")
            }
            return PaletteActionResult(kind: .openedSession, text: "Opened read-only Assistant.")
        case .organize(let instruction):
            guard let presentOrganize else {
                return PaletteActionResult(kind: .error,
                                           text: "Organize is unavailable in this build.")
            }
            guard await presentOrganize(instruction) else {
                return PaletteActionResult(kind: .error,
                                           text: "JBar could not open Organize review.")
            }
            return PaletteActionResult(kind: .openedSession,
                                       text: "Opened global Copy Organize review.")
        case .shell(let prompt):
            guard let presentDeveloperAgent else {
                return PaletteActionResult(kind: .error,
                                           text: "Developer Agent is unavailable in this build.")
            }
            guard await presentDeveloperAgent(prompt) else {
                return PaletteActionResult(kind: .error,
                                           text: "JBar could not open Developer Agent for ~/jbar.")
            }
            return PaletteActionResult(kind: .openedSession, text: "Opened Developer Agent in ~/jbar.")
        case .search:
            return PaletteActionResult(kind: .notice, text: "Search is handled locally by JBar.")
        }
    }
}
