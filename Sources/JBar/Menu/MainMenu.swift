import AppKit

/// Programmatic main menu for an `LSUIElement` app. It is never shown, but without it ⌘V/⌘A/⌘X/⌘Z
/// would not reach the query field. There is deliberately NO Quit item, so ⌘Q inside the panel is
/// ignored (DESIGN.md §7.3); quitting is done from the status-bar menu.
enum MainMenu {
    static func install(openConfig: Selector, target: AnyObject) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "JBar")
        appMenu.addItem(withTitle: "About JBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let cfg = NSMenuItem(title: "Open Config File…", action: openConfig, keyEquivalent: ",")
        cfg.target = target
        appMenu.addItem(cfg)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
