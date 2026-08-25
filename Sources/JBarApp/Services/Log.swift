import Foundation
import CryptoKit
import os

/// Process-wide loggers. Read with:
/// `log show --last 2m --predicate 'subsystem == "com.linji.jbar"'` or
/// `log stream --predicate 'subsystem == "com.linji.jbar"'`.
enum Log {
    static let subsystem = "com.linji.jbar"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let menu = Logger(subsystem: subsystem, category: "menu")
    static let launcher = Logger(subsystem: subsystem, category: "launcher")
    static let index = Logger(subsystem: subsystem, category: "index")
    static let cli = Logger(subsystem: subsystem, category: "cli")
}

/// Process-level runtime facts (environment switches, version) shared by the app and the CLI modes.
enum Runtime {
    /// `JBAR_DEMO=1` → the panel uses `DemoSearchProvider` (hard-coded rows) and no indexer/config/frecency is touched.
    /// Used to exercise the UI without the engine and without triggering folder-access (TCC) prompts.
    static var isDemo: Bool { flag("JBAR_DEMO") }
    /// `JBAR_SHOW_ON_LAUNCH=1` → show the panel immediately after launch (for verification without a hotkey press).
    static var showOnLaunch: Bool { flag("JBAR_SHOW_ON_LAUNCH") }
    /// `JBAR_SNAPSHOT_PATH=/path/out.png` (+ optional `JBAR_SNAPSHOT_QUERY`, default "code") → show the panel, run the
    /// query, render the panel's own view hierarchy to a PNG (no Screen Recording permission needed) and quit.
    /// Used for visual verification in headless sessions.
    static var snapshotPath: String? { ProcessInfo.processInfo.environment["JBAR_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } }
    static var snapshotQuery: String { ProcessInfo.processInfo.environment["JBAR_SNAPSHOT_QUERY"] ?? "code" }
    /// `JBAR_SNAPSHOT_DOWN=n` → move the selection down n rows before rendering, so a snapshot can show
    /// the list scrolled past the visible window.
    static var snapshotDown: Int { Int(ProcessInfo.processInfo.environment["JBAR_SNAPSHOT_DOWN"] ?? "") ?? 0 }
    /// Source-build acceptance runs can isolate all mutable app state inside an explicit directory.
    /// Production launches leave this unset and retain the normal macOS locations.
    static var testStateRoot: URL? {
        guard let raw = ProcessInfo.processInfo.environment["JBAR_TEST_STATE_ROOT"],
              raw.hasPrefix("/"), !raw.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
    /// Keeps the transient launcher panel visible while an accessibility test driver inspects it.
    /// It is never enabled by a normal launch and does not change Return/action behavior.
    static var keepPanelOpenForUITesting: Bool { flag("JBAR_UI_TEST_KEEP_PANEL_OPEN") }

    /// Marketing version from the bundle's Info.plist, or a dev marker when run from the SwiftPM binary.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0-dev"
    }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "swiftpm"
    }

    static var buildChannel: String {
        if let provenance = Bundle.main.infoDictionary?["JBarBuildProvenance"] as? String,
           !provenance.isEmpty { return "local bundle" }
        return Bundle.main.bundleIdentifier == "com.linji.jbar" ? "bundle" : "SwiftPM source"
    }

    /// Short exact-executable hash, useful when an old installed app and a current source build are
    /// both present. It is calculated once and never includes a user path in UI or logs.
    static let buildFingerprint: String = {
        guard let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else {
            return "unavailable"
        }
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }()

    static var buildIdentity: String {
        "\(version) (\(buildNumber)) · \(buildChannel) · \(buildFingerprint) · Assistant + Organize"
    }

    private static func flag(_ name: String) -> Bool {
        guard let v = ProcessInfo.processInfo.environment[name] else { return false }
        return !(v.isEmpty || v == "0" || v.lowercased() == "false" || v.lowercased() == "no")
    }
}
