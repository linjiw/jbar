import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) — DESIGN.md §5 row 11, §8.
///
/// `SMAppService` only works for an app bundle on disk; registering the bare SwiftPM binary or a
/// bundle outside `/Applications` / `~/Applications` is refused by the app (see `isInstalledInApplications`).
enum LoginItem {
    /// Current status as reported by the system.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// True when the system will launch us at login.
    static var isEnabled: Bool { status == .enabled }

    /// True when the running bundle lives in `/Applications` or `~/Applications` (the only places
    /// where registering a login item makes sense for a locally built app).
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return false }
        let home = NSHomeDirectory()
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Register as a login item. Returns a user-readable error message on failure, nil on success.
    @discardableResult
    static func register() -> String? {
        do {
            try SMAppService.mainApp.register()
            Log.app.notice("login item registered; status=\(describe(status))")
            return nil
        } catch {
            Log.app.error("login item register failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Unregister. Returns a user-readable error message on failure, nil on success.
    @discardableResult
    static func unregister() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            Log.app.notice("login item unregistered; status=\(describe(status))")
            return nil
        } catch {
            Log.app.error("login item unregister failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Open System Settings › General › Login Items (for the `.requiresApproval` case).
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Human-readable status for menus / CLI output.
    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}
