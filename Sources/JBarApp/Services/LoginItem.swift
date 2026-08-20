import Foundation
import ServiceManagement
import JBarCore

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) — DESIGN.md §5 row 11, §8.
///
/// `SMAppService` only works for an app bundle on disk; registering the bare SwiftPM binary or a
/// bundle outside `/Applications` / `~/Applications` is refused by the app (see `isInstalledInApplications`).
enum LoginItem {
    /// Stable, testable representation of `SMAppService.Status`. Keeping the unknown raw value
    /// makes the CLI fail closed if a future macOS release adds a state we do not understand.
    enum State: Equatable, Sendable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unknown(Int)
    }

    /// Stable diagnostic fields from a thrown ServiceManagement call. Localized descriptions are
    /// deliberately excluded so automation and logs do not depend on the current system language.
    struct ServiceAPIError: Equatable, Sendable {
        let domain: String
        let code: Int

        init(_ error: Error) {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
        }
    }

    /// Exhaustive result of the shared CLI/UI unregistration policy.
    enum UnregisterOutcome: Equatable, Sendable {
        case alreadyNotRegistered
        case unregistered(from: State)
        case refused(State)
        case nonTerminal(from: State, to: State)
        case unregisteredAfterAPIError(from: State, error: ServiceAPIError)
        case apiError(from: State, error: ServiceAPIError, terminal: State)

        var before: State {
            switch self {
            case .alreadyNotRegistered:
                return .notRegistered
            case .unregistered(let before),
                 .nonTerminal(let before, _),
                 .unregisteredAfterAPIError(let before, _),
                 .apiError(let before, _, _):
                return before
            case .refused(let before):
                return before
            }
        }

        var terminal: State {
            switch self {
            case .alreadyNotRegistered, .unregistered, .unregisteredAfterAPIError:
                return .notRegistered
            case .refused(let before):
                return before
            case .nonTerminal(_, let after), .apiError(_, _, let after):
                return after
            }
        }
    }

    /// Exhaustive result of the shared UI registration policy.
    enum RegisterOutcome: Equatable, Sendable {
        case alreadyRegistered(State)
        case registered(from: State, to: State)
        case refused(State)
        case nonTerminal(from: State, to: State)
        case registeredAfterAPIError(from: State, error: ServiceAPIError, terminal: State)
        case apiError(from: State, error: ServiceAPIError, terminal: State)

        var terminal: State {
            switch self {
            case .alreadyRegistered(let state), .refused(let state):
                return state
            case .registered(_, let after),
                 .nonTerminal(_, let after),
                 .registeredAfterAPIError(_, _, let after),
                 .apiError(_, _, let after):
                return after
            }
        }
    }

    /// Current status as reported by the system.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Current status translated into the stable policy representation.
    static var state: State { state(for: SMAppService.mainApp.status) }

    /// True when the system will launch us at login.
    static var isEnabled: Bool { status == .enabled }

    /// True when the running bundle lives in `/Applications` or `~/Applications` (the only places
    /// where registering a login item makes sense for a locally built app).
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return false }
        let home = NSHomeDirectory()
        let systemApplications = "/Applications"
        let userApplications = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true).path
        return (path != systemApplications && SafetyLimits.isPath(path, within: systemApplications))
            || (path != userApplications && SafetyLimits.isPath(path, within: userApplications))
    }

    /// Shared fail-closed registration policy. `.requiresApproval` is registered but awaiting the
    /// user's consent, so it is a valid terminal state alongside `.enabled`.
    static func ensureRegistered(
        status: () -> State,
        performRegister: () throws -> Void
    ) -> RegisterOutcome {
        let before = status()
        switch before {
        case .enabled, .requiresApproval:
            return .alreadyRegistered(before)
        case .notFound, .unknown:
            return .refused(before)
        case .notRegistered:
            break
        }

        do {
            try performRegister()
        } catch {
            let apiError = ServiceAPIError(error)
            let after = status()
            if isRegistered(after) {
                return .registeredAfterAPIError(
                    from: before, error: apiError, terminal: after
                )
            }
            return .apiError(from: before, error: apiError, terminal: after)
        }

        let after = status()
        if isRegistered(after) { return .registered(from: before, to: after) }
        return .nonTerminal(from: before, to: after)
    }

    /// Inert seam for the UI-facing registration API.
    static func register(
        status: () -> State,
        performRegister: () throws -> Void
    ) -> String? {
        userFacingError(for: ensureRegistered(
            status: status, performRegister: performRegister
        ))
    }

    /// Register as a login item. Returns a stable, nonlocalized error on unverified failure.
    @discardableResult
    static func register() -> String? {
        let service = SMAppService.mainApp
        let outcome = ensureRegistered(
            status: { state(for: service.status) },
            performRegister: { try service.register() }
        )
        if let message = userFacingError(for: outcome) {
            Log.app.error("\(message, privacy: .public)")
            return message
        }
        switch outcome {
        case .registeredAfterAPIError(_, let apiError, let terminal):
            Log.app.notice(
                "login item reached \(describe(terminal), privacy: .public) after API error; domain=\(apiError.domain, privacy: .public) code=\(apiError.code)"
            )
        default:
            Log.app.notice("login item registered; status=\(describe(outcome.terminal))")
        }
        return nil
    }

    /// Map registration outcomes to the existing UI API without localized error text.
    static func userFacingError(for outcome: RegisterOutcome) -> String? {
        switch outcome {
        case .alreadyRegistered, .registered, .registeredAfterAPIError:
            return nil
        case .refused(let state):
            return "login item status \(describe(state)) cannot confirm registration"
        case .nonTerminal(_, let after):
            return "login item status remained \(describe(after)) after register"
        case .apiError(_, let apiError, let after):
            return "login item register failed (domain \(apiError.domain), code \(apiError.code)); terminal status is \(describe(after))"
        }
    }

    /// Shared fail-closed policy. A thrown API call is accepted only when one immediate status read
    /// proves another actor completed the same idempotent transition. There is deliberately no
    /// polling or guessed recovery state.
    static func ensureUnregistered(
        status: () -> State,
        performUnregister: () throws -> Void
    ) -> UnregisterOutcome {
        let before = status()
        switch before {
        case .notRegistered:
            return .alreadyNotRegistered
        case .notFound, .unknown:
            return .refused(before)
        case .enabled, .requiresApproval:
            break
        }

        do {
            try performUnregister()
        } catch {
            let apiError = ServiceAPIError(error)
            let after = status()
            if after == .notRegistered {
                return .unregisteredAfterAPIError(from: before, error: apiError)
            }
            return .apiError(from: before, error: apiError, terminal: after)
        }

        let after = status()
        if after == .notRegistered { return .unregistered(from: before) }
        return .nonTerminal(from: before, to: after)
    }

    /// Inert seam used to verify the UI-facing `String?` contract without touching the real login
    /// item. Production and CLI both consume `ensureUnregistered`, so their status policy cannot
    /// drift.
    static func unregister(
        status: () -> State,
        performUnregister: () throws -> Void
    ) -> String? {
        userFacingError(for: ensureUnregistered(
            status: status, performUnregister: performUnregister
        ))
    }

    /// Unregister. Returns a stable, nonlocalized error message on failure, nil on verified success.
    @discardableResult
    static func unregister() -> String? {
        let service = SMAppService.mainApp
        let outcome = ensureUnregistered(
            status: { state(for: service.status) },
            performUnregister: { try service.unregister() }
        )
        if let message = userFacingError(for: outcome) {
            Log.app.error("\(message, privacy: .public)")
            return message
        }
        switch outcome {
        case .unregisteredAfterAPIError(_, let apiError):
            Log.app.notice(
                "login item reached not registered after API error; domain=\(apiError.domain, privacy: .public) code=\(apiError.code)"
            )
        default:
            Log.app.notice("login item unregistered; status=\(describe(outcome.terminal))")
        }
        return nil
    }

    /// Map a policy result to the existing UI API without exposing localized error text.
    static func userFacingError(for outcome: UnregisterOutcome) -> String? {
        switch outcome {
        case .alreadyNotRegistered, .unregistered, .unregisteredAfterAPIError:
            return nil
        case .refused(let state):
            return "login item status \(describe(state)) cannot confirm unregistration"
        case .nonTerminal(_, let after):
            return "login item status remained \(describe(after)) after unregister"
        case .apiError(_, let apiError, let after):
            return "login item unregister failed (domain \(apiError.domain), code \(apiError.code)); terminal status is \(describe(after))"
        }
    }

    private static func isRegistered(_ state: State) -> Bool {
        state == .enabled || state == .requiresApproval
    }

    /// Open System Settings › General › Login Items (for the `.requiresApproval` case).
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Human-readable status for menus / CLI output.
    static func describe(_ s: SMAppService.Status) -> String {
        describe(state(for: s))
    }

    /// Human-readable status for deterministic CLI output and tests.
    static func describe(_ state: State) -> String {
        switch state {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        case .unknown(let rawValue): return "unknown(\(rawValue))"
        }
    }

    /// Translate the SDK enum once at the ServiceManagement boundary.
    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown(status.rawValue)
        }
    }
}
