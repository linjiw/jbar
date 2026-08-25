import Foundation

/// Pure, side-effect-free intent classification for the palette. A leading sigil is intentional:
/// it prevents action syntax from accidentally entering the existing filename-search pipeline.
public struct IntentRouter: Sendable {
    public init() {}

    public func route(_ raw: String) -> PaletteIntent {
        guard let sigil = raw.first else { return .search(query: raw) }
        let payload = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        switch sigil {
        case "?", "？": return .ask(prompt: payload)
        case "!", "！": return .organize(task: payload)
        case ">", "＞": return .shell(command: payload)
        default: return .search(query: raw)
        }
    }
}
