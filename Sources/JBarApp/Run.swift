import AppKit

/// Entry point for the app bundle. `Sources/JBar/main.swift` is a three-line shim so that everything
/// else lives in a normal library target (`JBarApp`) that unit tests can import — an executable target
/// cannot be `@testable import`ed, which is why the whole UI surface previously had no test coverage.
public func runJBar() -> Never {
    // Swift's top-level executable entry is not annotated as MainActor even though macOS invokes it
    // on the process main thread. Reassert that platform invariant before entering any AppKit code.
    MainActor.assumeIsolated {
        // The packaged AppKit smoke is parsed before ordinary CLI dispatch. Its flag is fail-closed:
        // a malformed root or an unmodified product bundle exits instead of falling through and
        // accidentally starting the real app against user state.
        let smokeRequest: AppKitSmoke.Request?
        switch AppKitSmoke.parse(CommandLine.arguments) {
        case .notRequested:
            smokeRequest = nil
            // CLI modes run before AppKit starts (they exit the process); otherwise start the menu-bar app.
            _ = CLI.dispatch(CommandLine.arguments)
        case .valid(let request):
            smokeRequest = request
        case .invalid(let message):
            AppKitSmoke.writeStandardError("error: \(message)\n")
            exit(64)
        }

        let app = NSApplication.shared
        let delegate = smokeRequest.map { AppDelegate(appKitSmokeRequest: $0) } ?? AppDelegate()
        app.delegate = delegate
        // Keep the delegate alive for the process lifetime (NSApplication holds it weakly).
        objc_setAssociatedObject(app, "jbar.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
        exit(delegate.processExitCode)
    }
}
