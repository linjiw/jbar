import AppKit
import JBarCore

/// The narrow LaunchServices surface used by `AppLauncher`. Keeping it behind a protocol makes the
/// asynchronous success/failure contract testable without opening applications during the test run.
protocol WorkspaceOpening: AnyObject {
    func open(_ url: URL) -> Bool
    func openApplication(at applicationURL: URL, configuration: NSWorkspace.OpenConfiguration,
                         completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)?)
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

extension NSWorkspace: WorkspaceOpening {}

/// Opens / reveals / copies result rows and records history (DESIGN.md §7.4).
///
/// - App rows → `NSWorkspace.openApplication(at:configuration:)` with `activates = true`.
/// - Files and folders → `NSWorkspace.open(_:)` (folders open in Finder, files in their default app).
/// - Reveal → `activateFileViewerSelecting`.
/// - Copy → `NSPasteboard.general`.
/// Every confirmed successful open is recorded in the `FrecencyStore` (if any) and the store is
/// saved at most once per second (debounced). The completion handler runs on the main thread, and
/// the caller (panel) hides only after it receives `true`.
@MainActor
final class AppLauncher {
    /// History store; nil in demo mode.
    var frecency: FrecencyStore?
    /// Debounce interval for `FrecencyStore.save()` after a recorded open.
    var saveDelay: TimeInterval = 1.0

    private let workspace: WorkspaceOpening
    private let failureFeedback: () -> Void
    private var pendingSave: DispatchWorkItem?

    init(frecency: FrecencyStore? = nil,
         workspace: WorkspaceOpening = NSWorkspace.shared,
         failureFeedback: @escaping () -> Void = { NSSound.beep() }) {
        self.frecency = frecency
        self.workspace = workspace
        self.failureFeedback = failureFeedback
    }

    /// Open `row` (app, file or folder). `query` is the text the user typed (for per-query learning).
    /// Completion is delayed for applications until LaunchServices reports the actual outcome.
    func open(_ row: ResultRow, query: String?,
              completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let url = URL(fileURLWithPath: row.path)
        guard FileManager.default.fileExists(atPath: row.path) else {
            Log.launcher.error("open failed: selected path no longer exists")
            failureFeedback()
            completion(false)
            return
        }
        if row.isApp || row.path.hasSuffix(".app") {
            let path = row.path
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            workspace.openApplication(at: url, configuration: cfg) { [weak self] application, error in
                Task { @MainActor [weak self] in
                    self?.finishApplicationOpen(path: path, query: query, application: application, error: error,
                                                completion: completion)
                }
            }
            Log.launcher.notice("open application requested")
        } else {
            guard workspace.open(url) else {
                Log.launcher.error("open failed for selected item")
                failureFeedback()
                completion(false)
                return
            }
            Log.launcher.notice("open \(row.kind == .folder ? "folder" : "file") requested")
            record(path: row.path, query: query)
            completion(true)
        }
    }

    /// Reveal `row` in Finder. Returns false when the path is missing.
    @discardableResult
    func reveal(_ row: ResultRow) -> Bool {
        guard FileManager.default.fileExists(atPath: row.path) else {
            Log.launcher.error("reveal failed: selected path no longer exists")
            failureFeedback()
            return false
        }
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
        Log.launcher.notice("reveal requested")
        return true
    }

    /// Put the POSIX path of `row` on the general pasteboard.
    func copyPath(_ row: ResultRow) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(row.path, forType: .string)
        Log.launcher.notice("copy path requested")
    }

    /// Flush a pending debounced save immediately (call on quit).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        frecency?.save()
    }

    private func finishApplicationOpen(path: String, query: String?, application: NSRunningApplication?, error: Error?,
                                       completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let error {
            let ns = error as NSError
            Log.launcher.error("open application failed: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
            failureFeedback()
            completion(false)
            return
        }
        guard application != nil else {
            Log.launcher.error("open application failed: LaunchServices returned no application")
            failureFeedback()
            completion(false)
            return
        }
        Log.launcher.notice("open application confirmed")
        record(path: path, query: query)
        completion(true)
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
