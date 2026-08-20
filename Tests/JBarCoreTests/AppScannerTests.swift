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
