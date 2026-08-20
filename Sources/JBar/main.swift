import AppKit

// CLI modes run before AppKit starts (they exit the process); otherwise start the menu-bar app.
_ = CLI.dispatch(CommandLine.arguments)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
