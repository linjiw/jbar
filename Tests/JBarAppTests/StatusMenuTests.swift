import AppKit
import XCTest
import JBarCore
@testable import JBarApp

@MainActor
final class StatusMenuTests: XCTestCase {
    func testMainActorOwnedAppKitResourcesCanBeReleased() {
        weak var releasedMenu: StatusMenu?
        weak var releasedHotkey: CarbonHotkey?

        autoreleasepool {
            let menu = StatusMenu(hotkeyDisplay: "⌥Space")
            let hotkey = CarbonHotkey()
            releasedMenu = menu
            releasedHotkey = hotkey
            XCTAssertFalse(hotkey.isRegistered)
        }

        XCTAssertNil(releasedMenu)
        XCTAssertNil(releasedHotkey)
    }

    func testIndexSafetyWarningsExposeCountsButNeverPrivatePaths() {
        _ = NSApplication.shared
        let menu = StatusMenu(hotkeyDisplay: "⌥Space")
        var status = IndexStatus()
        status.deniedPaths = ["/Users/person/客户/Acquisition-Secret"]
        status.unsafeEntriesSkipped = 2

        menu.update(status: status)

        XCTAssertTrue(menu.itemTitles.contains("⚠ Some folders not accessible — Fix…"))
        XCTAssertTrue(menu.itemTitles.contains("⚠ Skipped 2 unsafe filesystem entries"))
        let renderedMetadata = (menu.itemTitles + menu.itemToolTips).joined(separator: "\n")
        XCTAssertFalse(renderedMetadata.contains("Acquisition-Secret"))
        XCTAssertFalse(renderedMetadata.contains("/Users/person"))
    }

    func testUnsafeEntryWarningUsesSingularGrammar() {
        _ = NSApplication.shared
        let menu = StatusMenu(hotkeyDisplay: "⌥Space")
        var status = IndexStatus()
        status.unsafeEntriesSkipped = 1
        menu.update(status: status)
        XCTAssertTrue(menu.itemTitles.contains("⚠ Skipped 1 unsafe filesystem entry"))
    }
}
