import AppKit
import JBarCore

/// Opens / reveals / copies result rows and records history (DESIGN.md §7.4).
///
/// - App rows → `NSWorkspace.openApplication(at:configuration:)` with `activates = true`.
/// - Files and folders → `NSWorkspace.open(_:)` (folders open in Finder, files in their default app).
/// - Reveal → `activateFileViewerSelecting`.
/// - Copy → `NSPasteboard.general`.
/// Every successful open is recorded in the `FrecencyStore` (if any) and the store is saved
/// at most once per second (debounced). The caller (panel) decides when to hide.
final class AppLauncher {
    /// History store; nil in demo mode.
    var frecency: FrecencyStore?
    /// Debounce interval for `FrecencyStore.save()` after a recorded open.
    var saveDelay: TimeInterval = 1.0

    private var pendingSave: DispatchWorkItem?

    init(frecency: FrecencyStore? = nil) { self.frecency = frecency }

    /// Open `row` (app, file or folder). `query` is the text the user typed (for per-query learning).
    /// Returns false when the path no longer exists or the open failed synchronously.
    @discardableResult
    func open(_ row: ResultRow, query: String?) -> Bool {
        let url = URL(fileURLWithPath: row.path)
        guard FileManager.default.fileExists(atPath: row.path) else {
            Log.launcher.error("open: path missing \(row.path, privacy: .public)")
            NSSound.beep()
            return false
        }
        if row.isApp || row.path.hasSuffix(".app") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
                if let error = error {
                    Log.launcher.error("openApplication failed for \(row.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.launcher.notice("open app \(row.name, privacy: .public)")
        } else {
            guard NSWorkspace.shared.open(url) else {
                Log.launcher.error("NSWorkspace.open failed for \(row.path, privacy: .public)")
                NSSound.beep()
                return false
            }
            Log.launcher.notice("open \(row.kind == .folder ? "folder" : "file") \(row.name, privacy: .public)")
        }
        record(path: row.path, query: query)
        return true
    }

    /// Reveal `row` in Finder. Returns false when the path is missing.
    @discardableResult
    func reveal(_ row: ResultRow) -> Bool {
        guard FileManager.default.fileExists(atPath: row.path) else {
            Log.launcher.error("reveal: path missing \(row.path, privacy: .public)")
            NSSound.beep()
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
        Log.launcher.notice("reveal \(row.name, privacy: .public)")
        return true
    }

    /// Put the POSIX path of `row` on the general pasteboard.
    func copyPath(_ row: ResultRow) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(row.path, forType: .string)
        Log.launcher.notice("copied path \(row.name, privacy: .public)")
    }

    /// Flush a pending debounced save immediately (call on quit).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        frecency?.save()
    }

    private func record(path: String, query: String?) {
        guard let f = frecency else { return }
        let q = query?.trimmingCharacters(in: .whitespaces)
        f.record(open: path, query: (q?.isEmpty ?? true) ? nil : q)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.frecency?.save()
            self?.pendingSave = nil
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }
}
