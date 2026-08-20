import XCTest
@testable import JBarCore

/// Tests for `AppScanner` (DESIGN.md §4.1): bundle discovery under roots (depth ≤ 2), symlink
/// resolution/dedup, Info.plist + localized-name reading, and `add(_:to:)` builder integration.
/// Synthetic `.app` bundles are written into temp directories so nothing depends on installed apps
/// (except the explicitly guarded real-system smoke test).
final class AppScannerTests: XCTestCase {
    private var tempDir: URL!
    private var tempHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("jbar-appscanner-\(UUID().uuidString)", isDirectory: true)
        tempHome = tempDir.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tempDir { try? fm.removeItem(at: d) }
    }

    /// Create a synthetic `.app` bundle. `name` includes the `.app` extension.
    @discardableResult
    private func makeApp(dir: URL, name: String, bundleID: String? = nil, displayName: String? = nil,
                         bundleName: String? = nil, lsuiElement: Bool = false,
                         localized: [String: String] = [:]) throws -> URL {
        let app = dir.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        if let b = bundleID { plist["CFBundleIdentifier"] = b }
        if let d = displayName { plist["CFBundleDisplayName"] = d }
        if let n = bundleName { plist["CFBundleName"] = n }
        if lsuiElement { plist["LSUIElement"] = true }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        for (lang, locName) in localized {
            let lproj = contents.appendingPathComponent("Resources").appendingPathComponent("\(lang).lproj")
            try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
            // Old-style ASCII strings file (UTF-8): `"CFBundleDisplayName" = "名字";`
            let text = "\"CFBundleDisplayName\" = \"\(locName)\";\n"
            try Data(text.utf8).write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        }
        return app
    }

    private func scan(_ roots: [URL], extra: [String] = []) -> [ScannedApp] {
        AppScanner.scan(roots: roots.map { $0.path }, extraBundles: extra, home: tempHome.path)
    }

    // MARK: - scan

    func testScanFindsAppsWithCorrectFileNameDisplayNameBundleID() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Alpha.app", bundleID: "com.test.alpha", displayName: "Alpha Display", bundleName: "AlphaName")
        try makeApp(dir: apps, name: "Beta Tool.app", bundleID: "com.test.beta")

        let found = scan([apps])
        let alpha = try XCTUnwrap(found.first { $0.fileName == "Alpha" }, "Alpha.app not found")
        // fileName is the bundle file name minus ".app".
        XCTAssertEqual(alpha.fileName, "Alpha")
        XCTAssertEqual(alpha.url.lastPathComponent, "Alpha.app")
        // Unregistered temp bundles: FileManager.displayName returns the file name, so displayName == fileName.
        XCTAssertEqual(alpha.displayName, "Alpha")
        XCTAssertEqual(alpha.bundleID, "com.test.alpha")
        // The plist display/name strings become raw aliases (deduped, != displayName/fileName).
        XCTAssertTrue(alpha.aliases.contains("Alpha Display"), "aliases: \(alpha.aliases)")
        XCTAssertTrue(alpha.aliases.contains("AlphaName"), "aliases: \(alpha.aliases)")

        let beta = try XCTUnwrap(found.first { $0.fileName == "Beta Tool" })
        XCTAssertEqual(beta.bundleID, "com.test.beta")
        XCTAssertEqual(beta.displayName, "Beta Tool")
    }

    func testScanSkipsDotAppWhoseDotSharesAUnicodeGrapheme() throws {
        let apps = tempDir.appendingPathComponent("HiddenApplications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: ".\u{0301}Hidden.app", bundleID: "hidden.decorated")
        try makeApp(dir: apps, name: "Visible.app", bundleID: "visible.bundle")

        let found = scan([apps])
        XCTAssertEqual(found.map(\.bundleID), ["visible.bundle"])
    }

    func testScanFindsDepthTwoBundles() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        let vendor = apps.appendingPathComponent("Vendor", isDirectory: true)
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Top.app", bundleID: "com.top")
        try makeApp(dir: vendor, name: "Deep.app", bundleID: "com.deep")

        let found = scan([apps])
        XCTAssertTrue(found.contains { $0.fileName == "Top" })
        XCTAssertTrue(found.contains { $0.fileName == "Deep" }, "depth-2 bundle not found: \(found.map { $0.fileName })")
    }

    func testScanDropsDanglingSymlink() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Real.app", bundleID: "com.real")
        try fm.createSymbolicLink(at: apps.appendingPathComponent("Dangling.app"),
                                  withDestinationURL: URL(fileURLWithPath: "/nonexistent/path/Ghost.app"))
        let found = scan([apps])
        XCTAssertTrue(found.contains { $0.fileName == "Real" })
        XCTAssertFalse(found.contains { $0.fileName == "Dangling" }, "dangling symlink should be dropped")
    }

    func testScanDedupesSymlinkToSameBundle() throws {
        let root = tempDir.appendingPathComponent("Dedup", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let real = try makeApp(dir: root, name: "Real.app", bundleID: "com.real")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: real)
        let found = scan([root])
        // Both candidates resolve to the same bundle → exactly one ScannedApp.
        XCTAssertEqual(found.count, 1, "expected dedup to one app, got \(found.map { $0.fileName })")
        XCTAssertEqual(found.first?.url.lastPathComponent, "Alias.app",
                       "a valid top-level app symlink stays launchable at its user-visible path")
    }

    func testScanExposesCJKLocalizedAlias() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Messenger.app", bundleID: "com.msg",
                    localized: ["zh-Hans": "微信测试"])
        let found = scan([apps])
        let app = try XCTUnwrap(found.first { $0.fileName == "Messenger" })
        XCTAssertTrue(app.aliases.contains("微信测试"), "CJK localized alias not exposed: \(app.aliases)")
    }

    func testBundleMetadataSymlinksAndOversizedFilesAreRejectedWithoutDroppingApp() throws {
        let apps = tempDir.appendingPathComponent("UntrustedMetadata", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)

        let linked = try makeApp(dir: apps, name: "Linked.app", bundleID: "before.link")
        let linkedInfo = linked.appendingPathComponent("Contents/Info.plist")
        try fm.removeItem(at: linkedInfo)
        let outside = tempDir.appendingPathComponent("outside.plist")
        let outsideData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "must.not.be.followed"],
            format: .xml,
            options: 0
        )
        try outsideData.write(to: outside)
        try fm.createSymbolicLink(at: linkedInfo, withDestinationURL: outside)

        let oversized = try makeApp(dir: apps, name: "Huge.app", bundleID: "before.huge")
        try Data(repeating: 0x20, count: SafetyLimits.maxBundleMetadataFileBytes + 1)
            .write(to: oversized.appendingPathComponent("Contents/Info.plist"))

        let found = scan([apps])
        XCTAssertEqual(Set(found.map(\.fileName)), ["Huge", "Linked"])
        XCTAssertNil(found.first { $0.fileName == "Linked" }?.bundleID,
                     "a symlinked plist must not be followed")
        XCTAssertNil(found.first { $0.fileName == "Huge" }?.bundleID,
                     "oversized metadata must be ignored before parsing")
    }

    func testLocalizedMetadataSymlinkIsNotReadAsAnAlias() throws {
        let apps = tempDir.appendingPathComponent("LocalizedSymlink", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = try makeApp(dir: apps, name: "Safe.app", bundleID: "com.safe",
                              localized: ["zh-Hans": "原始名称"])
        let strings = app.appendingPathComponent("Contents/Resources/zh-Hans.lproj/InfoPlist.strings")
        try fm.removeItem(at: strings)
        let outside = tempDir.appendingPathComponent("sensitive.strings")
        try Data("\"CFBundleDisplayName\" = \"不应读取\";\n".utf8).write(to: outside)
        try fm.createSymbolicLink(at: strings, withDestinationURL: outside)

        let found = try XCTUnwrap(scan([apps]).first)
        XCTAssertFalse(found.aliases.contains("不应读取"))
    }

    func testIntermediateContentsAndResourcesSymlinksCannotEscapeBundle() throws {
        let apps = tempDir.appendingPathComponent("IntermediateSymlinks", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)

        let contentsLinked = try makeApp(dir: apps, name: "ContentsLinked.app", bundleID: "before.contents")
        let outsideContents = tempDir.appendingPathComponent("outside-contents", isDirectory: true)
        try fm.createDirectory(at: outsideContents, withIntermediateDirectories: true)
        let maliciousInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "must.not.escape.contents"],
            format: .xml, options: 0
        )
        try maliciousInfo.write(to: outsideContents.appendingPathComponent("Info.plist"))
        try fm.removeItem(at: contentsLinked.appendingPathComponent("Contents"))
        try fm.createSymbolicLink(at: contentsLinked.appendingPathComponent("Contents"),
                                  withDestinationURL: outsideContents)

        let resourcesLinked = try makeApp(dir: apps, name: "ResourcesLinked.app", bundleID: "safe.resources")
        let outsideResources = tempDir.appendingPathComponent("outside-resources", isDirectory: true)
        let outsideLproj = outsideResources.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        try fm.createDirectory(at: outsideLproj, withIntermediateDirectories: true)
        try Data("\"CFBundleDisplayName\" = \"不得越界\";\n".utf8)
            .write(to: outsideLproj.appendingPathComponent("InfoPlist.strings"))
        let resources = resourcesLinked.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: resources)
        try fm.createSymbolicLink(at: resources, withDestinationURL: outsideResources)

        let found = scan([apps])
        let first = try XCTUnwrap(found.first { $0.fileName == "ContentsLinked" })
        let second = try XCTUnwrap(found.first { $0.fileName == "ResourcesLinked" })
        XCTAssertNil(first.bundleID, "a symlinked Contents directory must not be traversed")
        XCTAssertEqual(second.bundleID, "safe.resources")
        XCTAssertFalse(second.aliases.contains("不得越界"),
                       "a symlinked Resources directory must not escape the opened bundle")
    }

    func testResourceDirectorySwapBetweenIdentityCheckAndOpenIsRejected() throws {
        let apps = tempDir.appendingPathComponent("ResourceSwap", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = try makeApp(dir: apps, name: "Swap.app", bundleID: "safe.swap",
                              localized: ["en": "Original Safe Name"])
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let saved = app.appendingPathComponent("Contents/Resources.original", isDirectory: true)
        let replacement = tempDir.appendingPathComponent("replacement-resources", isDirectory: true)
        let replacementLproj = replacement.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        try fm.createDirectory(at: replacementLproj, withIntermediateDirectories: true)
        try Data("\"CFBundleDisplayName\" = \"替换后恶意名称\";\n".utf8)
            .write(to: replacementLproj.appendingPathComponent("InfoPlist.strings"))

        let hooks = AppScannerTestHooks { component in
            guard component == "Contents/Resources" else { return }
            let manager = FileManager.default
            try? manager.moveItem(at: resources, to: saved)
            try? manager.moveItem(at: replacement, to: resources)
        }
        let scanned = try XCTUnwrap(AppScanner.readBundle(app, skipUIElements: false, hooks: hooks))

        XCTAssertTrue(fm.fileExists(atPath: saved.path), "the deterministic swap hook did not run")
        XCTAssertEqual(scanned.bundleID, "safe.swap", "Info.plist came from the already-opened Contents descriptor")
        XCTAssertFalse(scanned.aliases.contains("替换后恶意名称"),
                       "the replacement directory's identity must not match the entry inspected before the swap")
    }

    func testInfoPlistSwapToOutsideSymlinkBetweenIdentityCheckAndOpenIsRejected() throws {
        let apps = tempDir.appendingPathComponent("FileSwap", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = try makeApp(dir: apps, name: "Swap.app", bundleID: "safe.before.swap")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let saved = app.appendingPathComponent("Contents/Info.original.plist")
        let outside = tempDir.appendingPathComponent("outside-swap.plist")
        let malicious = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "must.not.escape.after.swap"],
            format: .xml, options: 0
        )
        try malicious.write(to: outside)

        let hooks = AppScannerTestHooks { component in
            guard component == "Contents/Info.plist" else { return }
            let manager = FileManager.default
            try? manager.moveItem(at: info, to: saved)
            try? manager.createSymbolicLink(at: info, withDestinationURL: outside)
        }
        let scanned = try XCTUnwrap(AppScanner.readBundle(app, skipUIElements: false, hooks: hooks))

        XCTAssertTrue(fm.fileExists(atPath: saved.path), "the deterministic file swap hook did not run")
        XCTAssertNil(scanned.bundleID,
                     "O_NOFOLLOW plus descriptor identity must reject a post-check outside symlink")
    }

    func testLocalizedResourceBudgetCountsHiddenEntries() throws {
        let apps = tempDir.appendingPathComponent("LocalizedBudget", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = try makeApp(dir: apps, name: "Bounded.app", bundleID: "com.bounded")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0...SafetyLimits.maxLocalizedResourceDirectories {
            try fm.createDirectory(at: resources.appendingPathComponent(".hidden-\(index)", isDirectory: true),
                                   withIntermediateDirectories: false)
        }
        let zh = resources.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        try fm.createDirectory(at: zh, withIntermediateDirectories: true)
        try Data("\"CFBundleDisplayName\" = \"不能越过上限\";\n".utf8)
            .write(to: zh.appendingPathComponent("InfoPlist.strings"))

        let found = try XCTUnwrap(scan([apps]).first)
        XCTAssertFalse(found.aliases.contains("不能越过上限"),
                       "dot entries must consume the same traversal budget as visible resources")
    }

    func testMetadataFieldsAreBoundedBeforeAliasAnalysis() throws {
        let apps = tempDir.appendingPathComponent("BoundedMetadata", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let oversizedName = String(repeating: "名", count: SafetyLimits.maxNameUTF8Bytes)
        let oversizedBundleID = String(repeating: "b", count: SafetyLimits.maxSettingUTF8Bytes + 1)
        try makeApp(dir: apps, name: "Safe.app", bundleID: oversizedBundleID,
                    displayName: oversizedName, bundleName: "Safe Alias",
                    localized: ["zh-Hans": oversizedName])

        let found = try XCTUnwrap(scan([apps]).first)
        XCTAssertNil(found.bundleID)
        XCTAssertTrue(found.aliases.contains("Safe Alias"))
        XCTAssertFalse(found.aliases.contains(oversizedName))
        XCTAssertTrue(found.aliases.allSatisfy {
            SafetyLimits.utf8Fits($0, maxBytes: SafetyLimits.maxNameUTF8Bytes)
        })
    }

    func testLocalizedNamesStopAtTheRetainedAliasBudget() throws {
        let apps = tempDir.appendingPathComponent("ManyLocalizations", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let app = try makeApp(dir: apps, name: "Localized.app", bundleID: "com.localized")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        for index in 0..<40 {
            let lproj = resources.appendingPathComponent(String(format: "%03d.lproj", index),
                                                         isDirectory: true)
            try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
            let values = ["CFBundleDisplayName": "Localized \(index)",
                          "CFBundleName": "Name \(index)"]
            let data = try PropertyListSerialization.data(fromPropertyList: values,
                                                          format: .binary, options: 0)
            try data.write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        }

        let names = AppScanner.localizedNames(app, maxNames: 5)
        XCTAssertEqual(names.count, 5)
        XCTAssertEqual(names, ["Localized 0", "Name 0", "Localized 1", "Name 1", "Localized 2"])
        let outcome = AppScanner.scanOutcome(roots: [apps.path], extraBundles: [], home: tempHome.path)
        XCTAssertLessThanOrEqual(try XCTUnwrap(outcome.apps.first).aliases.count, AppScanner.maxAliases)
        XCTAssertFalse(outcome.truncated,
                       "bounded per-bundle aliases must not masquerade as omitted application candidates")
    }

    func testLocalizationFileAndTotalByteBudgetsStopMetadataWork() throws {
        let apps = tempDir.appendingPathComponent("MetadataBudgets", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)

        let fileLimited = try makeApp(dir: apps, name: "FileLimited.app", bundleID: "file.limited")
        let fileResources = fileLimited.appendingPathComponent("Contents/Resources", isDirectory: true)
        for index in 0...SafetyLimits.maxBundleLocalizationFiles {
            let lproj = fileResources.appendingPathComponent(String(format: "%03d.lproj", index),
                                                              isDirectory: true)
            try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = index == SafetyLimits.maxBundleLocalizationFiles
                ? Data("\"CFBundleDisplayName\" = \"超过文件预算\";\n".utf8) : Data()
            try data.write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        }

        let byteLimited = try makeApp(dir: apps, name: "ByteLimited.app", bundleID: "byte.limited")
        let byteResources = byteLimited.appendingPathComponent("Contents/Resources", isDirectory: true)
        let oneMiB = Data(repeating: 0x20, count: SafetyLimits.maxBundleMetadataFileBytes)
        for index in 0..<4 {
            let lproj = byteResources.appendingPathComponent(String(format: "%03d.lproj", index),
                                                              isDirectory: true)
            try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
            if index == 3 {
                var beyondBudget = Data("\"CFBundleDisplayName\" = \"超过总字节预算\";\n".utf8)
                beyondBudget.append(Data(repeating: 0x20,
                                         count: SafetyLimits.maxBundleMetadataFileBytes - beyondBudget.count))
                try beyondBudget.write(to: lproj.appendingPathComponent("InfoPlist.strings"))
            } else {
                try oneMiB.write(to: lproj.appendingPathComponent("InfoPlist.strings"))
            }
        }

        let outcome = AppScanner.scanOutcome(roots: [apps.path], extraBundles: [], home: tempHome.path)
        XCTAssertEqual(outcome.apps.count, 2)
        XCTAssertFalse(outcome.truncated,
                       "per-bundle metadata ceilings do not mean an application candidate was omitted")
        XCTAssertFalse(try XCTUnwrap(outcome.apps.first { $0.fileName == "FileLimited" })
            .aliases.contains("超过文件预算"))
        XCTAssertFalse(try XCTUnwrap(outcome.apps.first { $0.fileName == "ByteLimited" })
            .aliases.contains("超过总字节预算"))
    }

    func testParallelBundleReadsPreserveDeterministicCandidateOrder() throws {
        let apps = tempDir.appendingPathComponent("DeterministicApps", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        for i in (0..<48).reversed() {
            try makeApp(dir: apps, name: String(format: "App-%03d.app", i), bundleID: "com.test.\(i)",
                        localized: i.isMultiple(of: 3)
                            ? ["zh-Hans": "应用\(i)", "ko": "앱\(i)", "fr": "Application \(i)"] : [:])
        }

        let expectedNames = (0..<48).map { String(format: "App-%03d", $0) }
        let expectedScan = scan([apps])
        XCTAssertEqual(expectedScan.map(\.fileName), expectedNames)
        for _ in 0..<11 {
            XCTAssertEqual(scan([apps]), expectedScan,
                           "parallel completion and localized-resource enumeration must be deterministic")
        }
    }

    func testCandidateAndDirectoryCeilingsReportTruncationInsteadOfSilentlyOmittingApps() throws {
        let apps = tempDir.appendingPathComponent("TruncatedApps", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        for index in 0..<4 {
            try makeApp(dir: apps, name: "App-\(index).app", bundleID: "com.limit.\(index)")
        }

        let candidateBound = AppScanner.scanOutcome(roots: [apps.path], extraBundles: [], home: tempHome.path,
                                                    candidateLimit: 2, directoryEntryLimit: 20)
        XCTAssertEqual(candidateBound.apps.count, 2)
        XCTAssertTrue(candidateBound.truncated)

        let directoryBound = AppScanner.scanOutcome(roots: [apps.path], extraBundles: [], home: tempHome.path,
                                                    candidateLimit: 20, directoryEntryLimit: 3)
        XCTAssertTrue(directoryBound.apps.isEmpty,
                      "oversized directories are rejected as a unit, not filesystem-order partials")
        XCTAssertTrue(directoryBound.truncated)

        let complete = AppScanner.scanOutcome(roots: [apps.path], extraBundles: [], home: tempHome.path,
                                              candidateLimit: 20, directoryEntryLimit: 20)
        XCTAssertEqual(complete.apps.count, 4)
        XCTAssertFalse(complete.truncated)
    }

    func testInspectedEntryBudgetIsSharedAcrossRootsAndSubdirectories() throws {
        let first = tempDir.appendingPathComponent("BudgetRootOne", isDirectory: true)
        let vendor = first.appendingPathComponent("Vendor", isDirectory: true)
        let second = tempDir.appendingPathComponent("BudgetRootTwo", isDirectory: true)
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try makeApp(dir: vendor, name: "First.app", bundleID: "first.app")
        try makeApp(dir: second, name: "Second.app", bundleID: "second.app")

        let bounded = AppScanner.scanOutcome(
            roots: [first.path, second.path], extraBundles: [], home: tempHome.path,
            candidateLimit: 20, directoryEntryLimit: 20, inspectedEntryLimit: 2
        )
        XCTAssertEqual(bounded.apps.map(\.fileName), ["First"])
        XCTAssertTrue(bounded.truncated,
                      "the third physical name must exhaust one budget shared by the root and subdirectory walks")

        let zero = AppScanner.scanOutcome(
            roots: [first.path], extraBundles: [], home: tempHome.path,
            candidateLimit: 20, directoryEntryLimit: 20, inspectedEntryLimit: 0
        )
        XCTAssertTrue(zero.apps.isEmpty)
        XCTAssertTrue(zero.truncated)
    }

    func testScanBoundsPublicRootExtraAndHomeStringsBeforeExpansion() throws {
        let huge = String(repeating: "x", count: 2 * 1_048_576)
        let rejected = AppScanner.scanOutcome(
            roots: [huge, "~/Applications", "/tmp/../escape"],
            extraBundles: [huge], home: "/" + huge
        )
        XCTAssertTrue(rejected.apps.isEmpty)
        XCTAssertTrue(rejected.truncated)

        let apps = tempDir.appendingPathComponent("BoundedRoot", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Valid.app", bundleID: "valid.absolute")
        let absoluteDoesNotNeedHome = AppScanner.scanOutcome(
            roots: [apps.path], extraBundles: [], home: "/" + huge
        )
        XCTAssertEqual(absoluteDoesNotNeedHome.apps.map(\.fileName), ["Valid"])
        XCTAssertFalse(absoluteDoesNotNeedHome.truncated)
    }

    func testTildeRootWithCombiningLeadingComponentUsesPOSIXSlashByte() throws {
        let relative = "\u{0301}组合目录"
        let root = tempHome.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(dir: root, name: "Combined.app", bundleID: "combined.root")

        let outcome = AppScanner.scanOutcome(roots: ["~/\(relative)"], extraBundles: [],
                                             home: tempHome.path)
        XCTAssertEqual(outcome.apps.map(\.fileName), ["Combined"])
        XCTAssertFalse(outcome.truncated)
    }

    func testLSUIElementNotSkippedOutsideCoreServices() throws {
        // skipUIElements is only set for /System/Library/CoreServices paths; a temp root keeps LSUIElement apps.
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Helper.app", bundleID: "com.helper", lsuiElement: true)
        let found = scan([apps])
        XCTAssertTrue(found.contains { $0.fileName == "Helper" }, "LSUIElement app should NOT be skipped outside CoreServices")
    }

    func testScanReadsExtraBundlesAndUnreadableRootsAreSkipped() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let extra = try makeApp(dir: tempDir, name: "Extra.app", bundleID: "com.extra")
        // A missing root path is skipped silently; the extra bundle is still read.
        let found = AppScanner.scan(roots: [apps.path, tempDir.appendingPathComponent("missing").path],
                                    extraBundles: [extra.path], home: tempHome.path)
        XCTAssertTrue(found.contains { $0.fileName == "Extra" })
    }

    // MARK: - add(_:to:)

    func testAddProducesAppItemsWithFlagsExtAndAppInfo() throws {
        let apps = tempDir.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try makeApp(dir: apps, name: "Alpha.app", bundleID: "com.test.alpha", displayName: "Alpha Display",
                    bundleName: "AlphaName", localized: ["zh-Hans": "阿尔法测试"])
        let scanned = scan([apps])
        let alpha = try XCTUnwrap(scanned.first { $0.fileName == "Alpha" })

        let builder = IndexBuilder()
        AppScanner.add(scanned, to: builder)
        let store = builder.build(generation: 1)

        XCTAssertEqual(store.appItems.count, scanned.count)
        let idx = Int(try XCTUnwrap(store.appItems.first { store.name(of: Int($0)) == "Alpha" }))
        XCTAssertEqual(store.itemKind(idx), .app)
        XCTAssertTrue(store.itemFlags(idx).contains(.appBundle))
        XCTAssertTrue(store.itemFlags(idx).contains(.appCatalog))
        XCTAssertEqual(store.ext(of: idx), "app")
        XCTAssertTrue(store.path(of: idx).hasSuffix("Alpha.app"), "path was \(store.path(of: idx))")
        XCTAssertEqual(store.fileName(of: idx), "Alpha.app")

        let info = try XCTUnwrap(store.appInfo[Int32(idx)])
        XCTAssertEqual(info.displayName, "Alpha")
        XCTAssertEqual(info.bundleID, "com.test.alpha")
        // Each raw alias yields at least one SearchString; CJK aliases add pinyin variants on top.
        XCTAssertGreaterThanOrEqual(info.aliases.count, alpha.aliases.count,
                                    "aliases \(info.aliases.count) < raw \(alpha.aliases.count)")
        XCTAssertGreaterThan(info.aliases.count, 0)
    }

    func testAddSharesHardBudgetWithPreexistingItems() {
        let builder = IndexBuilder()
        let files = builder.addRoot("/files")
        builder.addItem(dir: files, name: "kept.txt", analyzed: TextAnalyzer.analyze("kept.txt"),
                        kind: .document, flags: [], mtime: nil, depth: 1, ext: "txt")
        let appRoot = tempDir.appendingPathComponent("Applications", isDirectory: true)
        let scanned = (0..<3).map { i in
            ScannedApp(url: appRoot.appendingPathComponent("App\(i).app"), displayName: "App\(i)",
                       bundleID: "test.\(i)", aliases: [], mtime: nil)
        }

        XCTAssertTrue(AppScanner.add(scanned, to: builder, maxItems: 3))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.appItems.count, 2)
        XCTAssertTrue((0..<store.count).contains { store.name(of: $0) == "kept.txt" })
    }

    func testAddWithZeroOrNegativeBudgetCreatesNoItemsOrDirectories() {
        let app = ScannedApp(url: tempDir.appendingPathComponent("Applications/Blocked.app"), displayName: "Blocked",
                             bundleID: nil, aliases: [], mtime: nil)
        for limit in [0, Int.min] {
            let builder = IndexBuilder()
            XCTAssertTrue(AppScanner.add([app], to: builder, maxItems: limit))
            let store = builder.build(generation: 1)
            XCTAssertEqual(store.count, 0)
            XCTAssertEqual(store.dirs.count, 0)
        }
    }

    func testCatalogDirectoryBudgetStopsBeforeAddingAPartialParentPath() {
        let apps = [
            ScannedApp(url: URL(fileURLWithPath: "/Catalog/A/First.app"),
                       displayName: "First", bundleID: nil, aliases: [], mtime: nil),
            ScannedApp(url: URL(fileURLWithPath: "/Other/B/Blocked.app"),
                       displayName: "Blocked", bundleID: nil, aliases: [], mtime: nil),
            ScannedApp(url: URL(fileURLWithPath: "/Catalog/A/Later.app"),
                       displayName: "Later", bundleID: nil, aliases: [], mtime: nil),
        ]
        let builder = IndexBuilder()
        XCTAssertTrue(AppScanner.add(apps, to: builder, maxItems: apps.count,
                                     catalogDirectoryLimit: 3))
        let store = builder.build(generation: 1)

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, 3, "'/', Catalog, and A consume the exact injected budget")
        XCTAssertEqual(store.path(of: 0), "/Catalog/A/First.app")
        XCTAssertFalse(store.dirs.indices.contains { store.dirPath(Int32($0)).contains("Other") },
                       "an over-budget parent must be rejected atomically, without a partial prefix")
    }

    func testDeepCatalogUsesLinearComponentNodeTopology() throws {
        let components = [String](repeating: "a", count: 1_800)
        let parent = "/" + components.joined(separator: "/")
        XCTAssertLessThan(parent.utf8.count, SafetyLimits.maxPathUTF8Bytes)
        let app = ScannedApp(url: URL(fileURLWithPath: parent + "/Linear.app"),
                             displayName: "Linear", bundleID: nil, aliases: [], mtime: nil)
        let builder = IndexBuilder()

        XCTAssertFalse(AppScanner.add([app], to: builder))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, components.count + 1)
        XCTAssertEqual(store.dirArena.count, components.count + 1,
                       "retained topology stores each component once, not every full prefix")
        XCTAssertEqual(store.path(of: 0), app.url.path)
    }

    func testCatalogDirectoryByteBudgetAcceptsExactLimitRejectsOneOverAndRoundTrips() throws {
        let apps = [
            ScannedApp(url: URL(fileURLWithPath: "/A/First.app"),
                       displayName: "First", bundleID: nil, aliases: [], mtime: nil),
            ScannedApp(url: URL(fileURLWithPath: "/BBBB/Blocked.app"),
                       displayName: "Blocked", bundleID: nil, aliases: [], mtime: nil),
        ]
        let builder = IndexBuilder()
        XCTAssertTrue(AppScanner.add(apps, to: builder, maxItems: apps.count,
                                     catalogDirectoryLimit: 10,
                                     catalogDirectoryByteLimit: 2))
        let store = builder.build(generation: 1)

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, 2)
        XCTAssertEqual(store.path(of: 0), "/A/First.app")
        XCTAssertFalse(store.dirs.indices.contains { store.dirPath(Int32($0)).contains("BBBB") },
                       "the byte ceiling must reject the whole new path before builder mutation")

        let hash: UInt64 = 0xCA7A
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(store, headerHash: hash),
                                                    expectedHeaderHash: hash,
                                                    maxItems: store.count, rootAllowance: 1))
        XCTAssertEqual(decoded.path(of: 0), "/A/First.app")

        let oneByteShort = IndexBuilder()
        XCTAssertTrue(AppScanner.add([apps[0]], to: oneByteShort, maxItems: 1,
                                     catalogDirectoryLimit: 10,
                                     catalogDirectoryByteLimit: 1))
        XCTAssertEqual(oneByteShort.count, 0)
        XCTAssertEqual(oneByteShort.dirCount, 0,
                       "one byte over the injected ceiling must leave the builder untouched")
    }

    func testCatalogIngestIsOneShotPerBuilderAndSecondCallDoesNotMutateStore() throws {
        let first = ScannedApp(url: URL(fileURLWithPath: "/Catalog/First.app"),
                               displayName: "First", bundleID: nil, aliases: [], mtime: nil)
        let second = ScannedApp(url: URL(fileURLWithPath: "/Other/Second.app"),
                                displayName: "Second", bundleID: nil, aliases: [], mtime: nil)
        let builder = IndexBuilder()
        XCTAssertFalse(AppScanner.add([], to: builder), "an empty call must not consume the ingest")
        XCTAssertFalse(AppScanner.add([first], to: builder))
        let before = builder.build(generation: 1)

        XCTAssertTrue(AppScanner.add([second], to: builder),
                      "a second non-empty ingest reports deterministic omission")
        let after = builder.build(generation: 2)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.dirs, before.dirs)
        XCTAssertEqual(after.dirArena, before.dirArena)
        XCTAssertEqual(after.path(of: 0), first.url.path)

        let hash: UInt64 = 0x0A11
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(after, headerHash: hash),
                                                    expectedHeaderHash: hash,
                                                    maxItems: after.count, rootAllowance: 1))
        XCTAssertEqual(decoded.path(of: 0), first.url.path)
    }

    func testZeroBudgetAndAllInvalidCallsDoNotConsumeCatalogIngest() {
        let valid = ScannedApp(url: URL(fileURLWithPath: "/Catalog/Valid.app"),
                               displayName: "Valid", bundleID: nil, aliases: [], mtime: nil)
        let invalid = ScannedApp(url: URL(fileURLWithPath: "/Catalog/.app"),
                                 displayName: "", bundleID: nil, aliases: [], mtime: nil)

        let zeroFirst = IndexBuilder()
        XCTAssertTrue(AppScanner.add([valid], to: zeroFirst, maxItems: 0))
        XCTAssertFalse(AppScanner.add([valid], to: zeroFirst),
                       "a zero item budget must fail before claiming the one-shot ingest")
        XCTAssertEqual(zeroFirst.count, 1)

        let invalidFirst = IndexBuilder()
        XCTAssertFalse(AppScanner.add([invalid], to: invalidFirst))
        XCTAssertFalse(AppScanner.add([valid], to: invalidFirst),
                       "an entirely invalid call must not claim or mutate catalog state")
        XCTAssertEqual(invalidFirst.count, 1)
    }

    func testOverlongAppPathDoesNotLeaveCatalogDirectoriesOrBlockLaterValidApp() throws {
        let components = [
            String(repeating: "a", count: SafetyLimits.maxNameUTF8Bytes),
            String(repeating: "b", count: SafetyLimits.maxNameUTF8Bytes),
            String(repeating: "c", count: SafetyLimits.maxNameUTF8Bytes),
            String(repeating: "d", count: 1_015),
        ]
        let overlongParent = "/" + components.joined(separator: "/")
        XCTAssertEqual(overlongParent.utf8.count, 4_091)
        XCTAssertTrue(SafetyLimits.isSafeAbsolutePath(overlongParent))
        let blocked = ScannedApp(
            url: URL(fileURLWithPath: overlongParent + "/Blocked.app"),
            displayName: "Blocked", bundleID: nil, aliases: [], mtime: nil
        )
        let valid = ScannedApp(url: URL(fileURLWithPath: "/Applications/Valid.app"),
                               displayName: "Valid", bundleID: nil, aliases: [], mtime: nil)
        let builder = IndexBuilder()

        XCTAssertFalse(AppScanner.add([blocked, valid], to: builder))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, 2, "only '/' and Applications should be committed")
        XCTAssertEqual(store.path(of: 0), valid.url.path)
        XCTAssertFalse(store.dirs.indices.contains {
            store.dirPath(Int32($0)).contains(components[0])
        }, "the rejected path must not leave a dead catalog prefix")

        let hash: UInt64 = 0xA770_4096
        let decoded = try XCTUnwrap(Snapshot.decode(try Snapshot.encode(store, headerHash: hash),
                                                    expectedHeaderHash: hash,
                                                    maxItems: 1, rootAllowance: 1))
        XCTAssertEqual(decoded.path(of: 0), valid.url.path)
    }

    func testInvalidParentComponentAndNonFileURLDoNotConsumeCatalogIngest() {
        let valid = ScannedApp(url: URL(fileURLWithPath: "/Applications/Valid.app"),
                               displayName: "Valid", bundleID: nil, aliases: [], mtime: nil)
        let invalidComponent = ScannedApp(
            url: URL(fileURLWithPath: "/" + String(repeating: "x", count: 1_025)
                                     + "/Bad.app"),
            displayName: "Bad", bundleID: nil, aliases: [], mtime: nil
        )
        let invalidBuilder = IndexBuilder()
        XCTAssertFalse(AppScanner.add([invalidComponent], to: invalidBuilder))
        XCTAssertEqual(invalidBuilder.count, 0)
        XCTAssertEqual(invalidBuilder.dirCount, 0)
        XCTAssertFalse(AppScanner.add([valid], to: invalidBuilder),
                       "component validation must happen before claiming one-shot state")
        XCTAssertEqual(invalidBuilder.build(generation: 1).path(of: 0), valid.url.path)

        let remote = ScannedApp(url: URL(string: "https://example.com/Fake.app")!,
                                displayName: "Fake", bundleID: nil, aliases: [], mtime: nil)
        let remoteBuilder = IndexBuilder()
        XCTAssertFalse(AppScanner.add([remote], to: remoteBuilder))
        XCTAssertEqual(remoteBuilder.count, 0)
        XCTAssertEqual(remoteBuilder.dirCount, 0)
        XCTAssertFalse(AppScanner.add([valid], to: remoteBuilder),
                       "a non-file URL must not become a synthetic local path or consume ingest")
        let remoteStore = remoteBuilder.build(generation: 1)
        XCTAssertEqual(remoteStore.count, 1)
        XCTAssertEqual(remoteStore.path(of: 0), valid.url.path)

        let wrongSuffixes = [
            ScannedApp(url: URL(fileURLWithPath: "/Applications/Fake.txt"),
                       displayName: "Fake", bundleID: nil, aliases: [], mtime: nil),
            ScannedApp(url: URL(fileURLWithPath: "/Applications/Upper.APP"),
                       displayName: "Upper", bundleID: nil, aliases: [], mtime: nil),
        ]
        let suffixBuilder = IndexBuilder()
        XCTAssertFalse(AppScanner.add(wrongSuffixes, to: suffixBuilder))
        XCTAssertEqual(suffixBuilder.count, 0)
        XCTAssertEqual(suffixBuilder.dirCount, 0)
        XCTAssertFalse(AppScanner.add([valid], to: suffixBuilder),
                       "rejected suffix spellings must not consume catalog ingest")
        XCTAssertEqual(suffixBuilder.build(generation: 1).path(of: 0), valid.url.path)
    }

    func testPreinternedCatalogRootDoesNotConsumeInjectedDirectoryBudget() throws {
        let builder = IndexBuilder()
        XCTAssertEqual(builder.addRoot("/"), 0)
        let app = ScannedApp(url: URL(fileURLWithPath: "/A/App.app"),
                             displayName: "App", bundleID: nil, aliases: [], mtime: nil)

        XCTAssertFalse(AppScanner.add([app], to: builder, maxItems: 1,
                                      catalogDirectoryLimit: 1,
                                      catalogDirectoryByteLimit: 1))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.dirs.count, 2)
        XCTAssertEqual(store.path(of: 0), app.url.path)
        let hash: UInt64 = 0xB007_0001
        XCTAssertNotNil(Snapshot.decode(try Snapshot.encode(store, headerHash: hash),
                                        expectedHeaderHash: hash,
                                        maxItems: 1, rootAllowance: 1))
    }

    func testCanonicalParentReusePreflightsTheCommittedPathLength() {
        let leading = [
            String(repeating: "a", count: SafetyLimits.maxNameUTF8Bytes),
            String(repeating: "b", count: SafetyLimits.maxNameUTF8Bytes),
            String(repeating: "c", count: SafetyLimits.maxNameUTF8Bytes),
        ]
        let finalStem = String(repeating: "d", count: 1_008) + "caf"
        let nfcParent = "/" + (leading + [finalStem + "é"]).joined(separator: "/")
        let nfdParent = "/" + (leading + [finalStem + "e\u{301}"]).joined(separator: "/")
        XCTAssertEqual(nfcParent, nfdParent)
        XCTAssertEqual(nfcParent.utf8.count, 4_089)
        XCTAssertEqual(nfdParent.utf8.count, 4_090)

        let first = ScannedApp(url: URL(fileURLWithPath: nfdParent + "/A.app"),
                               displayName: "A", bundleID: nil, aliases: [], mtime: nil)
        let mappedOverlong = ScannedApp(url: URL(fileURLWithPath: nfcParent + "/BB.app"),
                                        displayName: "BB", bundleID: nil,
                                        aliases: [], mtime: nil)
        let later = ScannedApp(url: URL(fileURLWithPath: "/Applications/Later.app"),
                               displayName: "Later", bundleID: nil, aliases: [], mtime: nil)
        let builder = IndexBuilder()

        XCTAssertFalse(AppScanner.add([first, mappedOverlong, later], to: builder))
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.path(of: 0), first.url.path)
        XCTAssertEqual(store.path(of: 1), later.url.path)
        XCTAssertFalse((0..<store.count).contains { store.name(of: $0) == "BB" })
    }

    func testRejectedLargeAppInfoDoesNotCommitParentBeforeLaterSmallApp() {
        let builder = IndexBuilder()
        let preloadRoot = builder.addRoot("/preload")
        let aliasBytes = [UInt8](repeating: 255,
                                 count: IndexStoreLimits.maxAnalyzedNameBytes)
        let fillerAlias = SearchString(folded: aliasBytes, bonus: aliasBytes,
                                       mask: 1, initials: 1)
        let fillerInfo = AppInfo(bundleID: nil, displayName: "Seed",
                                 aliases: [fillerAlias])
        let fillerCost = IndexStoreLimits.adding(
            IndexStoreLimits.estimatedAppInfoJSONBytes(fillerInfo), 16
        )
        let smallInfo = AppInfo(bundleID: nil, displayName: "Small", aliases: [])
        let reservedForSmall = IndexStoreLimits.adding(
            IndexStoreLimits.adding(IndexStoreLimits.estimatedAppInfoJSONBytes(smallInfo), 16),
            IndexStoreLimits.estimatedExtensionJSONBytes("app")
        )
        let availableForFillers = SafetyLimits.maxAppSideTableBytes
            - IndexStoreLimits.sideTableFixedBytes - reservedForSmall
        let fillerCount = availableForFillers / fillerCost
        XCTAssertGreaterThan(fillerCount, 100)
        for _ in 0..<fillerCount {
            XCTAssertGreaterThanOrEqual(
                builder.addItem(dir: preloadRoot, name: "Seed",
                                analyzed: TextAnalyzer.analyze("Seed"), kind: .app,
                                flags: [.appBundle], mtime: nil, depth: 1,
                                ext: nil, app: fillerInfo),
                0
            )
        }

        let largeAliases = (0..<AppScanner.maxAliases).map { index in
            String(format: "%02d", index)
                + String(repeating: "z", count: SafetyLimits.maxNameUTF8Bytes - 2)
        }
        let rejected = ScannedApp(url: URL(fileURLWithPath: "/Rejected/Large.app"),
                                  displayName: "Large", bundleID: nil,
                                  aliases: largeAliases, mtime: nil)
        let accepted = ScannedApp(url: URL(fileURLWithPath: "/Accepted/Small.app"),
                                  displayName: "Small", bundleID: nil,
                                  aliases: [], mtime: nil)
        XCTAssertTrue(AppScanner.add([rejected, accepted], to: builder),
                      "the large side table is omitted while the reserved small item succeeds")
        let store = builder.build(generation: 1)
        XCTAssertEqual(store.count, fillerCount + 1)
        XCTAssertEqual(store.path(of: store.count - 1), accepted.url.path)
        XCTAssertFalse(store.dirs.indices.contains {
            store.dirPath(Int32($0)) == "/Rejected"
        }, "a side-budget rejection must not commit its new parent")
        XCTAssertTrue(store.dirs.indices.contains {
            store.dirPath(Int32($0)) == "/Accepted"
        })
    }

    func testAddSanitizesPublicScannedAppAndKeepsSnapshotAliasInvariant() throws {
        let oversized = String(repeating: "x", count: 2 * 1_048_576)
        let aliases = [String](repeating: oversized, count: 100_000)
            + (0..<100).map { "微信音乐测试\($0)" }
        let app = ScannedApp(
            url: tempDir.appendingPathComponent("Applications/Safe.app"),
            displayName: oversized,
            bundleID: oversized,
            aliases: aliases,
            mtime: nil
        )
        let builder = IndexBuilder()
        XCTAssertFalse(AppScanner.add([app], to: builder))
        let store = builder.build(generation: 1)
        let index = try XCTUnwrap(store.appItems.first)
        let info = try XCTUnwrap(store.appInfo[index])

        XCTAssertEqual(info.displayName, "Safe")
        XCTAssertNil(info.bundleID)
        XCTAssertTrue(info.aliases.isEmpty,
                      "only the bounded raw alias prefix is inspected; later valid values are ignored")
        XCTAssertLessThanOrEqual(info.aliases.count, SafetyLimits.maxSearchAliasesPerApp)
        XCTAssertTrue(info.aliases.allSatisfy {
            $0.folded.count <= Snapshot.maximumAnalyzedNameBytes
                && $0.folded.count == $0.bonus.count
        })
        XCTAssertNoThrow(try Snapshot.encode(store, headerHash: 1))
    }

    func testAddCapsThePublicAppsArrayEvenWhenEveryEntryIsInvalid() {
        let invalid = ScannedApp(url: URL(fileURLWithPath: "/Applications/.app"),
                                 displayName: "", bundleID: nil, aliases: [], mtime: nil)
        let apps = [ScannedApp](repeating: invalid,
                                count: SafetyLimits.maxAppCandidates + 1)
        let builder = IndexBuilder()

        XCTAssertTrue(AppScanner.add(apps, to: builder))
        XCTAssertEqual(builder.count, 0)
        XCTAssertEqual(builder.dirCount, 0)
    }

    // MARK: - Real-system smoke (guarded)

    func testRealSystemScanSmoke() throws {
        try XCTSkipUnless(fm.fileExists(atPath: "/System/Applications"), "no system apps on this host")
        let apps = AppScanner.scan()
        XCTAssertGreaterThanOrEqual(apps.count, 30, "expected many system apps, got \(apps.count)")
        XCTAssertTrue(apps.contains { $0.fileName == "Xcode" || $0.fileName == "Finder"
                                      || $0.displayName == "Xcode" || $0.displayName == "Finder" },
                      "expected Finder or Xcode among scanned apps")
    }
}
