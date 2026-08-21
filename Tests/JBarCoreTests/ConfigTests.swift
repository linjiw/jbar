import XCTest
import Darwin
@testable import JBarCore

final class ConfigTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jbar-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ name: String = "config.json") -> URL { tempDir.appendingPathComponent(name) }

    // MARK: - Codable

    func testDefaultsRoundTrip() throws {
        let data = try Config.default.jsonData()
        let decoded = try Config.decode(data)
        XCTAssertEqual(decoded, Config.default)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        XCTAssertTrue(text.contains("\"hotkey\" : \"option+space\""))
        XCTAssertTrue(text.contains("~/Library"), "~ paths kept as written")
        XCTAssertFalse(text.contains("\\/"), "slashes not escaped")
        // Sorted keys: every CodingKey present and in ascending order.
        let keys = Config.CodingKeys.allCases.map { $0.rawValue }
        let positions = keys.map { text.range(of: "\"\($0)\" :")!.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        let sortedKeys = keys.sorted()
        let sortedPositions = sortedKeys.map { text.range(of: "\"\($0)\" :")!.lowerBound }
        XCTAssertEqual(sortedPositions, sortedPositions.sorted(), "keys are written in sorted order")
    }

    func testPartialJSONUsesDefaults() throws {
        let json = #"{"hotkey": "cmd+shift+k", "visibleRows": 12}"#
        let c = try Config.decode(Data(json.utf8))
        XCTAssertEqual(c.hotkey, "cmd+shift+k")
        XCTAssertEqual(c.visibleRows, 12)
        XCTAssertEqual(c.maxResults, Config.default.maxResults)
        XCTAssertEqual(c.appsFirstCap, Config.default.appsFirstCap)
        XCTAssertEqual(c.fileRoots, ["~"])
        XCTAssertEqual(c.excludeNames, Exclusions.defaultExcludeNames)
        XCTAssertEqual(c.launchAtLogin, true)
    }

    func testEmptyObjectIsDefaults() throws {
        XCTAssertEqual(try Config.decode(Data("{}".utf8)), Config.default)
    }

    func testUnknownKeysIgnored() throws {
        let json = #"{"someFutureKey": [1,2,3], "includeHidden": true, "nested": {"a": 1}}"#
        let c = try Config.decode(Data(json.utf8))
        XCTAssertTrue(c.includeHidden)
        XCTAssertEqual(c.maxDepth, 12)
    }

    func testWrongTypeIsAnError() {
        XCTAssertThrowsError(try Config.decode(Data(#"{"maxResults": "eight"}"#.utf8))) { error in
            let msg = Config.describe(error)
            XCTAssertTrue(msg.contains("maxResults"), "message should name the key: \(msg)")
        }
    }

    func testNumericSafetyBoundaries() throws {
        func decoded(_ fragment: String) throws -> Config {
            try Config.decode(Data("{\(fragment)}".utf8))
        }
        XCTAssertEqual(try decoded(#""maxResults": 1, "visibleRows": 1"#).maxResults, 1)
        XCTAssertEqual(try decoded(#""maxResults": 1, "visibleRows": 1"#).appsFirstCap, 1,
                       "an omitted dependent cap follows maxResults")
        XCTAssertEqual(try decoded(#""maxResults": 500, "visibleRows": 20"#).maxResults, 500)
        XCTAssertEqual(try decoded(#""visibleRows": 1"#).visibleRows, 1)
        XCTAssertEqual(try decoded(#""visibleRows": 20"#).visibleRows, 20)
        XCTAssertEqual(try decoded(#""appsFirstCap": 0"#).appsFirstCap, 0)
        XCTAssertEqual(try decoded(#""appsFirstCap": 40"#).appsFirstCap, 40)
        XCTAssertEqual(try decoded(#""maxDepth": 0"#).maxDepth, 0)
        XCTAssertEqual(try decoded(#""maxDepth": 64"#).maxDepth, 64)
        XCTAssertEqual(try decoded(#""maxIndexedItems": 1"#).maxIndexedItems, 1)
        XCTAssertEqual(try decoded(#""maxIndexedItems": 2000000"#).maxIndexedItems, 2_000_000)

        let invalid: [(key: String, fragment: String)] = [
            ("maxResults", #""maxResults": 0, "visibleRows": 1"#),
            ("maxResults", #""maxResults": 501, "visibleRows": 8"#),
            ("maxResults", #""maxResults": 9223372036854775807, "visibleRows": 8"#),
            ("maxResults", #""maxResults": -9223372036854775808, "visibleRows": 1"#),
            ("visibleRows", #""visibleRows": 0"#),
            ("visibleRows", #""visibleRows": 21"#),
            ("visibleRows", #""maxResults": 1, "visibleRows": 20"#),
            ("appsFirstCap", #""appsFirstCap": -1"#),
            ("appsFirstCap", #""maxResults": 10, "visibleRows": 8, "appsFirstCap": 11"#),
            ("maxDepth", #""maxDepth": -1"#),
            ("maxDepth", #""maxDepth": 65"#),
            ("maxIndexedItems", #""maxIndexedItems": 0"#),
            ("maxIndexedItems", #""maxIndexedItems": 2000001"#),
        ]
        for test in invalid {
            XCTAssertThrowsError(try decoded(test.fragment), test.fragment) { error in
                let message = Config.describe(error)
                XCTAssertTrue(message.contains(test.key), "\(test.fragment): \(message)")
                XCTAssertTrue(message.contains("expected"), "\(test.fragment): \(message)")
            }
        }
    }

    func testLegacyVisibleRowsMigrationIsBounded() throws {
        let high = try Config.decode(Data(#"{"maxResults":60}"#.utf8))
        XCTAssertEqual(high.maxResults, 60)
        XCTAssertEqual(high.visibleRows, SafetyLimits.visibleRows.upperBound)

        XCTAssertThrowsError(try Config.decode(Data(#"{"maxResults":9223372036854775807}"#.utf8))) { error in
            XCTAssertTrue(Config.describe(error).contains("maxResults"))
        }
        XCTAssertThrowsError(try Config.decode(Data(#"{"maxResults":-1}"#.utf8))) { error in
            XCTAssertTrue(Config.describe(error).contains("maxResults"))
        }
    }

    func testStringAndCollectionSafetyBounds() throws {
        func data(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(try Config.decode(data(["hotkey": "not-a-hotkey"])).hotkey, "not-a-hotkey",
                       "invalid syntax is handled by the existing visible hotkey fallback")
        XCTAssertEqual(try Config.decode(data(["screen": "sideways"])).screen, "sideways",
                       "unknown screens retain the established mouse-screen fallback")
        XCTAssertThrowsError(try Config.decode(data(["hotkey": String(repeating: "x", count: SafetyLimits.maxHotkeyUTF8Bytes + 1)]))) { error in
            XCTAssertTrue(Config.describe(error).contains("hotkey"))
        }
        XCTAssertThrowsError(try Config.decode(data(["screen": String(repeating: "x", count: SafetyLimits.maxSettingUTF8Bytes + 1)]))) { error in
            XCTAssertTrue(Config.describe(error).contains("screen"))
        }
        XCTAssertThrowsError(try Config.decode(data(["fileRoots": Array(repeating: "~", count: SafetyLimits.maxRootEntries + 1)]))) { error in
            XCTAssertTrue(Config.describe(error).contains("fileRoots"))
        }
        XCTAssertThrowsError(try Config.decode(data(["excludePaths": Array(repeating: "~/x", count: SafetyLimits.maxExcludedPathEntries + 1)]))) { error in
            XCTAssertTrue(Config.describe(error).contains("excludePaths"))
        }
        XCTAssertThrowsError(try Config.decode(data(["excludeNames": Array(repeating: "x", count: SafetyLimits.maxNameEntries + 1)]))) { error in
            XCTAssertTrue(Config.describe(error).contains("excludeNames"))
        }
        let longPath = "/" + String(repeating: "a", count: SafetyLimits.maxPathUTF8Bytes)
        XCTAssertThrowsError(try Config.decode(data(["appDirectories": [longPath]]))) { error in
            XCTAssertTrue(Config.describe(error).contains("appDirectories[0]"))
        }
        let longName = String(repeating: "a", count: SafetyLimits.maxNameUTF8Bytes + 1)
        XCTAssertThrowsError(try Config.decode(data(["downrankNames": [longName]]))) { error in
            XCTAssertTrue(Config.describe(error).contains("downrankNames[0]"))
        }
        for (key, object) in [
            ("fileRoots", ["fileRoots": ["relative/path"]]),
            ("appDirectories", ["appDirectories": ["~someone/Applications"]]),
            ("excludePaths", ["excludePaths": ["/safe\0truncated"]]),
            ("excludePaths", ["excludePaths": ["/safe\0\u{301}truncated"]]),
            ("fileRoots", ["fileRoots": ["/safe/\u{301}/../escape"]]),
            ("fileRoots", ["fileRoots": ["~/\u{301}/../escape"]]),
            ("excludeNames", ["excludeNames": ["bad\0name"]]),
        ] as [(String, [String: Any])] {
            XCTAssertThrowsError(try Config.decode(data(object))) { error in
                XCTAssertTrue(Config.describe(error).contains(key), "\(key): \(error)")
            }
        }
        XCTAssertEqual(try Config.decode(data(["fileRoots": ["~/\u{301}目录"]])).fileRoots,
                       ["~/\u{301}目录"],
                       "valid POSIX tilde paths must not depend on Swift grapheme segmentation")
    }

    func testDirectSaveRejectsInvalidConfig() throws {
        var c = Config.default
        c.maxResults = Int.max
        XCTAssertThrowsError(try c.jsonData())
        XCTAssertThrowsError(try c.save(to: url()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path))
    }

    func testEncodedConfigCannotExceedItsOwnLoaderLimitOrReplaceLastGoodFile() throws {
        var config = Config.default
        config.excludeNames = (0..<1_100).map { index in
            String(repeating: "a", count: 1_020) + String(format: "%04d", index)
        }
        let destination = url()
        let existing = Data(#"{"visibleRows":7}"#.utf8)
        try existing.write(to: destination)

        XCTAssertThrowsError(try config.jsonData()) { error in
            guard let validation = error as? Config.ValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(validation.key, "configFile")
        }
        XCTAssertThrowsError(try config.save(to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), existing,
                       "a rejected oversized encoding must not replace the last-good file")
    }

    func testAggregateEscapedConfigIsRejectedBeforeAnyEncoderCanMaterializeIt() {
        var config = Config.default
        let controlHeavy = String(repeating: "\u{0001}", count: SafetyLimits.maxNameUTF8Bytes)
        config.excludeNames = [String](repeating: controlHeavy, count: 200)
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual((error as? Config.ValidationError)?.key, "configFile")
        }
        XCTAssertThrowsError(try JSONEncoder().encode(config),
                             "the public Encodable entry must enforce the same preflight")
    }

    func testAggregatePreflightDoesNotRejectOrdinaryASCIIWellBelowTheFileLimit() throws {
        var config = Config.default
        config.excludeNames = (0..<200).map { index in
            String(format: "%04d-", index) + String(repeating: "a", count: 995)
        }
        try config.validate()
        let data = try config.jsonData()
        XCTAssertLessThan(data.count, SafetyLimits.maxConfigFileBytes)
        XCTAssertGreaterThan(data.count, 190_000)
    }

    func testAllFieldsRoundTrip() throws {
        var c = Config()
        c.hotkey = "ctrl+option+space"; c.launchAtLogin = false; c.maxResults = 10; c.appsFirstCap = 3; c.screen = "main"
        c.restoreQueryOnReopen = true; c.showRecentsOnEmpty = false; c.appDirectories = ["/Applications"]
        c.fileRoots = ["~/Documents", "/Volumes/Data"]; c.excludePaths = ["~/Library"]; c.excludeNames = ["node_modules"]
        c.downrankNames = ["build"]; c.includeHidden = true; c.maxDepth = 5; c.maxIndexedItems = 1234
        let back = try Config.decode(try c.jsonData())
        XCTAssertEqual(back, c)
        XCTAssertNotEqual(back, Config.default)
    }

    // MARK: - load / save

    func testLoadMissingCreatesDefaults() throws {
        let u = url("nested/dir/config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
        let result = Config.load(from: u)
        XCTAssertEqual(result, .created(.default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), "defaults written, parent dirs created")
        // Second load reads the file back.
        XCTAssertEqual(Config.load(from: u), .loaded(.default))
    }

    func testReadOnlyLoadMissingDoesNotCreateAnything() {
        let u = url("diagnostic-only/config.json")

        XCTAssertEqual(Config.loadReadOnly(from: u), .missing)

        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path),
                       "read-only loading must not even create the parent directory")
    }

    func testReadOnlyLoadUsesNormalValidationWithoutMutatingFile() throws {
        let u = url()
        let original = Data(#"{"maxResults": 17, "visibleRows": 6}"#.utf8)
        try original.write(to: u)

        XCTAssertEqual(Config.loadReadOnly(from: u), .loaded({
            var config = Config.default
            config.maxResults = 17
            config.visibleRows = 6
            return config
        }()))
        XCTAssertEqual(try Data(contentsOf: u), original)
    }

    func testReadOnlyLoadRejectsFIFOWithoutBlocking() throws {
        let u = url("config.fifo")
        XCTAssertEqual(mkfifo(u.path, 0o600), 0)

        guard case .invalid(let message) = Config.loadReadOnly(from: u) else {
            return XCTFail("expected a FIFO to be rejected")
        }
        XCTAssertTrue(message.contains("regular file"), message)
    }

    func testLoadValidFile() throws {
        let u = url()
        try Data(#"{"hotkey": "cmd+space", "maxDepth": 3}"#.utf8).write(to: u)
        guard case .loaded(let c) = Config.load(from: u) else { return XCTFail("expected .loaded") }
        XCTAssertEqual(c.hotkey, "cmd+space")
        XCTAssertEqual(c.maxDepth, 3)
    }

    func testLoadInvalidJSON() throws {
        let u = url()
        try Data("{ not json".utf8).write(to: u)
        guard case .invalid(let message) = Config.load(from: u) else { return XCTFail("expected .invalid") }
        XCTAssertTrue(message.contains(u.path), "message names the file: \(message)")
        XCTAssertFalse(message.isEmpty)
        // Contains some description from the JSON parser.
        XCTAssertTrue(message.lowercased().contains("json") || message.lowercased().contains("corrupt") || message.contains("format"),
                      "message should include the decoding error: \(message)")
    }

    func testLoadWrongType() throws {
        let u = url()
        try Data(#"{"fileRoots": "~"}"#.utf8).write(to: u)
        guard case .invalid(let message) = Config.load(from: u) else { return XCTFail("expected .invalid") }
        XCTAssertTrue(message.contains("fileRoots"), message)
    }

    func testLoadRejectsOversizedFileBeforeReading() throws {
        let u = url()
        try Data(repeating: 0x20, count: SafetyLimits.maxConfigFileBytes + 1).write(to: u)
        guard case .invalid(let message) = Config.load(from: u) else { return XCTFail("expected .invalid") }
        XCTAssertTrue(message.contains("too large"), message)
        XCTAssertTrue(message.contains(String(SafetyLimits.maxConfigFileBytes)), message)
    }

    func testLoadUnreadableFileIsInvalid() throws {
        let u = url()
        try Data("{}".utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: u.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path) }
        guard case .invalid(let message) = Config.load(from: u) else { return XCTFail("expected .invalid (running as root?)") }
        XCTAssertTrue(message.contains("Could not read"), message)
    }

    func testNullValuesFallBackToDefaults() throws {
        let c = try Config.decode(Data(#"{"maxResults": null, "fileRoots": null}"#.utf8))
        XCTAssertEqual(c, Config.default)
    }

    func testDescribeNonDecodingError() {
        let plain = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(Config.describe(plain), "boom")
        let withDebug = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom", NSDebugDescriptionErrorKey: "details"])
        XCTAssertEqual(Config.describe(withDebug), "boom (details)")
    }

    func testLoadDirectoryPathIsInvalid() throws {
        let result = Config.load(from: tempDir)
        guard case .invalid(let message) = result else { return XCTFail("expected .invalid") }
        XCTAssertTrue(message.contains("directory"), message)
    }

    func testLoadUnwritableLocationIsInvalid() {
        // /System is read-only (SIP) → defaults cannot be written.
        let u = URL(fileURLWithPath: "/System/jbar-test-\(UUID().uuidString)/config.json")
        guard case .invalid(let message) = Config.load(from: u) else { return XCTFail("expected .invalid") }
        XCTAssertTrue(message.contains("Could not write"), message)
    }

    func testSaveIsAtomicAndCreatesDirs() throws {
        let u = url("a/b/config.json")
        var c = Config(); c.maxResults = 9
        try c.save(to: u)
        XCTAssertEqual(Config.load(from: u), .loaded(c))
        // Overwrite keeps a single valid file.
        c.maxResults = 11
        try c.save(to: u)
        XCTAssertEqual(Config.load(from: u), .loaded(c))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["config.json"], "no temp files left behind")
    }

    func testDefaultURLHonoursXDG() {
        let u = Config.defaultURL()
        XCTAssertTrue(u.path.hasSuffix("/jbar/config.json"))
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            XCTAssertTrue(u.path.hasPrefix(xdg))
        } else {
            XCTAssertTrue(u.path.hasPrefix(NSHomeDirectory() + "/.config"))
        }
    }

    // MARK: - Derived objects

    func testExclusions() {
        var c = Config()
        c.excludeNames = ["Node_Modules", ".Git"]
        c.downrankNames = ["Build", "DIST"]
        c.excludePaths = ["~/Library", "~", "/opt/x/", "~/Pictures/*.photoslibrary"]
        c.includeHidden = true
        c.maxDepth = 7
        let ex = c.exclusions(home: "/Users/test")
        XCTAssertEqual(ex.excludeNames, ["node_modules", ".git"])
        XCTAssertEqual(ex.downrankNames, ["build", "dist"])
        XCTAssertEqual(ex.excludePaths, ["/Users/test/Library", "/Users/test", "/opt/x", "/Users/test/Pictures/*.photoslibrary"])
        XCTAssertTrue(ex.includeHidden)
        XCTAssertEqual(ex.maxDepth, 7)
    }

    func testExpandTilde() {
        XCTAssertEqual(Config.expandTilde("~", home: "/h"), "/h")
        XCTAssertEqual(Config.expandTilde("~/", home: "/h"), "/h")
        XCTAssertEqual(Config.expandTilde("~/a/b/", home: "/h"), "/h/a/b")
        XCTAssertEqual(Config.expandTilde("/", home: "/h"), "/")
        XCTAssertEqual(Config.expandTilde("~user/x", home: "/h"), "~user/x", "other users' homes are left alone")
        XCTAssertEqual(Config.expandTilde("rel/~/x", home: "/h"), "rel/~/x")
        XCTAssertEqual(Config.expandTilde("~/\u{301}目录", home: "/h"), "/h/\u{301}目录")
    }

    func testCoordinatorOptions() {
        var c = Config()
        c.appDirectories = ["/Applications", "~/Applications"]
        c.fileRoots = ["~/Documents"]
        c.maxIndexedItems = 4242
        c.excludeNames = ["X"]
        let o = c.coordinatorOptions(home: "/Users/test")
        XCTAssertEqual(o.home, "/Users/test")
        XCTAssertEqual(o.appRoots, ["/Applications", "~/Applications"])
        XCTAssertEqual(o.fileRoots, ["~/Documents"])
        XCTAssertEqual(o.maxItems, 4242)
        XCTAssertEqual(o.exclusions, c.exclusions(home: "/Users/test"))
        XCTAssertEqual(o.exclusions.excludeNames, ["x"])
    }

    // MARK: - Hotkey

    func testParseHotkeyDefaults() {
        let p = Config.parseHotkey("option+space")
        XCTAssertEqual(p?.carbonModifiers, Config.CarbonModifier.option)
        XCTAssertEqual(p?.keyCode, 0x31)
        XCTAssertEqual(Config.CarbonModifier.cmd, 0x100)
        XCTAssertEqual(Config.CarbonModifier.shift, 0x200)
        XCTAssertEqual(Config.CarbonModifier.option, 0x800)
        XCTAssertEqual(Config.CarbonModifier.control, 0x1000)
    }

    func testParseHotkeyCombos() {
        let p = Config.parseHotkey("cmd+shift+k")
        XCTAssertEqual(p?.carbonModifiers, Config.CarbonModifier.cmd | Config.CarbonModifier.shift)
        XCTAssertEqual(p?.keyCode, 0x28)
        let q = Config.parseHotkey("ctrl+option+space")
        XCTAssertEqual(q?.carbonModifiers, Config.CarbonModifier.control | Config.CarbonModifier.option)
        XCTAssertEqual(q?.keyCode, 0x31)
        let r = Config.parseHotkey(" Command + Alt + Control + SHIFT + F12 ")
        XCTAssertEqual(r?.carbonModifiers, Config.CarbonModifier.cmd | Config.CarbonModifier.option | Config.CarbonModifier.control | Config.CarbonModifier.shift)
        XCTAssertEqual(r?.keyCode, 0x6F)
    }

    func testParseHotkeyKeyTable() {
        let expect: [String: UInt32] = [
            "a": 0x00, "z": 0x06, "0": 0x1D, "1": 0x12, "9": 0x19, "f1": 0x7A, "f19": 0x50, "return": 0x24, "tab": 0x30,
            "escape": 0x35, "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C,
            "`": 0x32, "\\": 0x2A, "delete": 0x33, "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C, "space": 0x31,
        ]
        for (k, code) in expect {
            XCTAssertEqual(Config.parseHotkey("cmd+\(k)")?.keyCode, code, "key \(k)")
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertNotNil(Config.parseHotkey("option+\(letter)"), "letter \(letter)")
        }
        for n in 1...19 {
            XCTAssertNotNil(Config.parseHotkey("option+f\(n)"), "f\(n)")
        }
        XCTAssertNil(Config.parseHotkey("option+f20"))
    }

    func testParseHotkeyRejectsInvalid() {
        XCTAssertNil(Config.parseHotkey(""))
        XCTAssertNil(Config.parseHotkey("space"), "modifier required")
        XCTAssertNil(Config.parseHotkey("cmd"), "key required")
        XCTAssertNil(Config.parseHotkey("cmd+shift"), "key required")
        XCTAssertNil(Config.parseHotkey("cmd+a+b"), "exactly one key")
        XCTAssertNil(Config.parseHotkey("cmd+bogus"))
        XCTAssertNil(Config.parseHotkey("hyper+a"))
        XCTAssertNil(Config.parseHotkey("cmd++a"), "empty token")
        XCTAssertNil(Config.parseHotkey("+cmd+a"))
        XCTAssertNil(Config.parseHotkey("cmd+a+"))
    }

    func testHotkeyDisplay() {
        XCTAssertEqual(Config.hotkeyDisplay("option+space"), "⌥Space")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+shift+k"), "⇧⌘K")
        XCTAssertEqual(Config.hotkeyDisplay("shift+cmd+ctrl+option+a"), "⌃⌥⇧⌘A")
        XCTAssertEqual(Config.hotkeyDisplay("ctrl+return"), "⌃↩")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+escape"), "⌘⎋")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+tab"), "⌘⇥")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+delete"), "⌘⌫")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+up"), "⌘↑")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+f5"), "⌘F5")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+/"), "⌘/")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+comma"), "⌘,")
        XCTAssertEqual(Config.hotkeyDisplay("cmd+space"), "⌘Space")
        XCTAssertEqual(Config.hotkeyDisplay("nonsense"), "nonsense", "invalid strings are returned unchanged")
    }

    // MARK: - ConfigWatcher

    /// Helper: a watcher on `u` that records changes/errors on a serial queue.
    /// All mutable fields are confined to `queue`; the unchecked conformance exists solely so the
    /// watcher's `@Sendable` callbacks can capture this queue-isolated test probe.
    private final class Recorder: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.recorder")
        private(set) var changes: [Config] = []
        private(set) var errors: [String] = []
        private var onChangeExpectation: XCTestExpectation?
        private var onErrorExpectation: XCTestExpectation?

        func setChangeExpectation(_ expectation: XCTestExpectation?) {
            queue.sync { onChangeExpectation = expectation }
        }

        func setErrorExpectation(_ expectation: XCTestExpectation?) {
            queue.sync { onErrorExpectation = expectation }
        }

        func record(change: Config) {
            changes.append(change)
            onChangeExpectation?.fulfill()
        }

        func record(error: String) {
            errors.append(error)
            onErrorExpectation?.fulfill()
        }
    }

    private func makeWatcher(_ u: URL, _ rec: Recorder) -> ConfigWatcher {
        ConfigWatcher(url: u, queue: rec.queue,
                      onChange: { rec.record(change: $0) },
                      onError: { rec.record(error: $0) })
    }

    /// Write with a temp file + rename (what editors do).
    private func atomicReplace(_ u: URL, _ text: String) throws {
        let tmp = u.deletingLastPathComponent().appendingPathComponent(".config.json.tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(u, withItemAt: tmp)
    }

    func testWatcherDetectsInPlaceModification() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        w.start() // idempotent
        defer { w.stop() }
        let exp = expectation(description: "onChange")
        rec.setChangeExpectation(exp)
        // In-place write (no rename): truncate + write via FileHandle.
        Thread.sleep(forTimeInterval: 0.1)
        let fh = try FileHandle(forWritingTo: u)
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data(#"{"visibleRows": 3}"#.utf8))
        try fh.close()
        wait(for: [exp], timeout: 3)
        rec.queue.sync {
            XCTAssertEqual(rec.changes.last?.visibleRows, 3)
            XCTAssertTrue(rec.errors.isEmpty)
        }
    }

    func testWatcherDetectsAtomicReplaceTwice() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        let exp1 = expectation(description: "first replace")
        rec.setChangeExpectation(exp1)
        try atomicReplace(u, #"{"hotkey": "cmd+space"}"#)
        wait(for: [exp1], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.hotkey, "cmd+space") }

        // The file source was re-armed on the new inode: a second replace must also be seen.
        let exp2 = expectation(description: "second replace")
        rec.setChangeExpectation(exp2)
        try atomicReplace(u, #"{"hotkey": "ctrl+space"}"#)
        wait(for: [exp2], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.hotkey, "ctrl+space") }

        // And a plain in-place write after the replace is seen too.
        let exp3 = expectation(description: "in-place after replace")
        rec.setChangeExpectation(exp3)
        let fh = try FileHandle(forWritingTo: u)
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data(#"{"hotkey": "option+k"}"#.utf8))
        try fh.close()
        wait(for: [exp3], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.hotkey, "option+k") }
    }

    func testWatcherReportsInvalidJSON() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        let exp = expectation(description: "onError")
        rec.setErrorExpectation(exp)
        try atomicReplace(u, "{ definitely not json")
        wait(for: [exp], timeout: 3)
        rec.queue.sync {
            XCTAssertEqual(rec.errors.count, 1)
            XCTAssertTrue(rec.errors[0].contains("Invalid config"))
        }
        // Fixing the file fires onChange again (so the app can clear its warning).
        let exp2 = expectation(description: "fixed")
        rec.setChangeExpectation(exp2)
        try atomicReplace(u, #"{"visibleRows": 5}"#)
        wait(for: [exp2], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.visibleRows, 5) }
    }

    func testWatcherRejectsUnsafeValueAndKeepsLastGood() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        let rejected = expectation(description: "unsafe config rejected")
        rec.setErrorExpectation(rejected)
        try atomicReplace(u, #"{"maxResults":9223372036854775807,"visibleRows":8}"#)
        wait(for: [rejected], timeout: 3)
        rec.queue.sync {
            XCTAssertTrue(rec.changes.isEmpty, "an invalid reload must not replace the caller's last-good config")
            XCTAssertTrue(rec.errors.last?.contains("maxResults") == true, "\(rec.errors)")
        }

        let accepted = expectation(description: "valid config accepted afterward")
        rec.setChangeExpectation(accepted)
        try atomicReplace(u, #"{"maxResults":50,"visibleRows":10}"#)
        wait(for: [accepted], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.maxResults, 50) }
    }

    func testWatcherDebouncesBurst() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        let exp = expectation(description: "onChange")
        exp.assertForOverFulfill = false
        rec.setChangeExpectation(exp)
        for i in 1...5 {
            try atomicReplace(u, #"{"visibleRows": \#(i)}"#)
            Thread.sleep(forTimeInterval: 0.02)
        }
        wait(for: [exp], timeout: 3)
        Thread.sleep(forTimeInterval: 0.5)
        rec.queue.sync {
            XCTAssertEqual(rec.changes.last?.visibleRows, 5)
            XCTAssertLessThanOrEqual(rec.changes.count, 2, "burst of 5 writes within 100 ms coalesces (got \(rec.changes.count))")
        }
    }

    func testWatcherRecreatesDeletedFile() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        let exp = expectation(description: "onChange after delete")
        exp.assertForOverFulfill = false
        rec.setChangeExpectation(exp)
        try FileManager.default.removeItem(at: u)
        wait(for: [exp], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), "defaults re-created")
        rec.queue.sync { XCTAssertEqual(rec.changes.last, Config.default) }
    }

    func testWatcherSurvivesDirectoryDeletion() throws {
        let u = url("cfgdir/config.json")
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        let exp = expectation(description: "defaults re-created after rm -rf")
        exp.assertForOverFulfill = false
        rec.setChangeExpectation(exp)
        try FileManager.default.removeItem(at: u.deletingLastPathComponent())
        wait(for: [exp], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
        Thread.sleep(forTimeInterval: 0.5)
        // The directory and file sources were re-armed on the new inodes: a later edit is still seen.
        let exp2 = expectation(description: "edit after re-creation")
        rec.setChangeExpectation(exp2)
        try atomicReplace(u, #"{"visibleRows": 7}"#)
        wait(for: [exp2], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.visibleRows, 7) }
    }

    func testWatcherStopIsIdempotentAndSilencesEvents() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.stop() // before start: no-op
        w.start()
        w.stop()
        w.stop()
        try atomicReplace(u, #"{"maxResults": 2}"#)
        Thread.sleep(forTimeInterval: 0.7)
        rec.queue.sync { XCTAssertTrue(rec.changes.isEmpty && rec.errors.isEmpty) }
        // Restart works.
        w.start()
        let exp = expectation(description: "after restart")
        rec.setChangeExpectation(exp)
        Thread.sleep(forTimeInterval: 0.1)
        try atomicReplace(u, #"{"visibleRows": 4}"#)
        wait(for: [exp], timeout: 3)
        w.stop()
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.visibleRows, 4) }
    }

    func testWatcherConcurrentLifecycleStressLeavesNoStaleCallbacks() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        let w = makeWatcher(u, rec)

        // Exercise the public thread-safety contract and descriptor cancellation from many callers.
        DispatchQueue.concurrentPerform(iterations: 128) { i in
            if i.isMultiple(of: 2) { w.start() } else { w.stop() }
        }
        // Establish a final linearization point after all concurrent operations complete.
        w.stop()
        let callbacksAtStop = rec.queue.sync { rec.changes.count + rec.errors.count }

        try atomicReplace(u, #"{"visibleRows": 6}"#)
        Thread.sleep(forTimeInterval: 0.7)
        let callbacksAfterEdit = rec.queue.sync { rec.changes.count + rec.errors.count }
        XCTAssertEqual(callbacksAfterEdit, callbacksAtStop,
                       "a stopped lifecycle generation must not deliver queued or new events")

        // The heavily exercised watcher can still be restarted and observe a fresh generation.
        let restarted = expectation(description: "reload after lifecycle stress")
        rec.setChangeExpectation(restarted)
        w.start()
        Thread.sleep(forTimeInterval: 0.1)
        try atomicReplace(u, #"{"visibleRows": 9}"#)
        wait(for: [restarted], timeout: 3)
        w.stop()
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.visibleRows, 9) }
    }

    func testWatcherCreatesMissingDirectory() throws {
        let u = url("missing/dir/config.json")
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        w.start()
        defer { w.stop() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path))
        let exp = expectation(description: "first save seen")
        rec.setChangeExpectation(exp)
        Thread.sleep(forTimeInterval: 0.1)
        var c = Config(); c.maxResults = 6; c.visibleRows = 6
        try c.save(to: u)
        wait(for: [exp], timeout: 3)
        rec.queue.sync { XCTAssertEqual(rec.changes.last?.maxResults, 6) }
    }

    func testWatcherUnwatchableDirectoryReportsError() {
        let u = URL(fileURLWithPath: "/System/jbar-unwatchable-\(UUID().uuidString)/config.json")
        let rec = Recorder()
        let w = makeWatcher(u, rec)
        let exp = expectation(description: "onError")
        rec.setErrorExpectation(exp)
        w.start()
        wait(for: [exp], timeout: 3)
        rec.queue.sync { XCTAssertTrue(rec.errors.first?.contains("Cannot watch") ?? false) }
        w.stop()
    }

    func testWatcherDeallocWhileRunningDoesNotCrash() throws {
        let u = url()
        try Config.default.save(to: u)
        let rec = Recorder()
        var w: ConfigWatcher? = makeWatcher(u, rec)
        w?.start()
        w = nil
        try atomicReplace(u, #"{"maxResults": 2}"#)
        Thread.sleep(forTimeInterval: 0.6)
        rec.queue.sync { XCTAssertTrue(rec.changes.isEmpty) }
    }
}
