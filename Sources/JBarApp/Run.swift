import AppKit

/// Entry point for the app bundle. `Sources/JBar/main.swift` is a three-line shim so that everything
/// else lives in a normal library target (`JBarApp`) that unit tests can import — an executable target
/// cannot be `@testable import`ed, which is why the whole UI surface previously had no test coverage.
public func runJBar() -> Never {
    // CLI modes run before AppKit starts (they exit the process); otherwise start the menu-bar app.
    _ = CLI.dispatch(CommandLine.arguments)

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Keep the delegate alive for the process lifetime (NSApplication holds it weakly).
    objc_setAssociatedObject(app, "jbar.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
    exit(0)
}
