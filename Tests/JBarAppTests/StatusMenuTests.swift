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
        status.unavailableRoots = ["/Users/person/Missing-Secret"]
        status.unsafeEntriesSkipped = 2

        menu.update(status: status)

        XCTAssertTrue(menu.itemTitles.contains("⚠ Some folders not accessible — Fix…"))
        XCTAssertTrue(menu.itemTitles.contains("⚠ Skipped 2 unsafe filesystem entries"))
        XCTAssertTrue(menu.itemTitles.contains("⚠ Some configured roots unavailable — Check Config"))
        let renderedMetadata = (menu.itemTitles + menu.itemToolTips).joined(separator: "\n")
        XCTAssertFalse(renderedMetadata.contains("Acquisition-Secret"))
        XCTAssertFalse(renderedMetadata.contains("/Users/person"))
        XCTAssertFalse(renderedMetadata.contains("Missing-Secret"))
    }

    func testUnsafeEntryWarningUsesSingularGrammar() {
        _ = NSApplication.shared
        let menu = StatusMenu(hotkeyDisplay: "⌥Space")
        var status = IndexStatus()
        status.unsafeEntriesSkipped = 1
        menu.update(status: status)
        XCTAssertTrue(menu.itemTitles.contains("⚠ Skipped 1 unsafe filesystem entry"))
    }

    func testBuildIdentityMakesAssistantCapabilityAndBinaryFingerprintVisible() {
        _ = NSApplication.shared
        let menu = StatusMenu(hotkeyDisplay: "⌥Space")
        let buildLine = menu.itemTitles.first { $0.hasPrefix("Build: ") }

        XCTAssertNotNil(buildLine)
        XCTAssertTrue(buildLine?.contains("Assistant") == true)
        XCTAssertTrue(buildLine?.contains("Organize") == true)
        XCTAssertTrue(buildLine?.contains(Runtime.buildChannel) == true)
        XCTAssertEqual(Runtime.buildFingerprint == "unavailable"
                       || Runtime.buildFingerprint.count == 12, true)
        XCTAssertFalse(Runtime.buildIdentity.contains(NSHomeDirectory()))
    }
}
