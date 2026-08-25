import Foundation

/// The leading character in the palette deliberately selects a product mode before any work is
/// started. `?`, `!`, and `>` are not search terms, so callers can keep regular filename search
/// responsive while making action submission an explicit Enter-only step.
public enum PaletteIntent: Equatable, Sendable {
    case search(query: String)
    case ask(prompt: String)
    case organize(task: String)
    case shell(command: String)

    /// The text after a mode prefix, suitable for checking whether Enter can submit an action.
    public var payload: String? {
        switch self {
        case .search:
            return nil
        case .ask(let prompt):
            return prompt
        case .organize(let task):
            return task
        case .shell(let command):
            return command
        }
    }

    public var isAction: Bool { payload != nil }
}
