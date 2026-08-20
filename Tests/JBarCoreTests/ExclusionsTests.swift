import XCTest
@testable import JBarCore

/// Tests for `Exclusions` / `ExcludedPathMatcher` / `FNV1a` (DESIGN.md §4.3–4.4).
/// A fixed home (`/home/u`) is used for path assertions so they are deterministic on any machine.
final class ExclusionsTests: XCTestCase {
    private let home = "/home/u"

    // MARK: - defaults(home:)

    func testDefaultsLowercasesNamesAndExpandsTilde() {
        let e = Exclusions.defaults(home: home)
        // Every stored exclude/downrank name is lowercase.
        for n in e.excludeNames { XCTAssertEqual(n, n.lowercased(), "exclude name not lowercased: \(n)") }
        for n in e.downrankNames { XCTAssertEqual(n, n.lowercased(), "downrank name not lowercased: \(n)") }
        // Well-known defaults are present.
        XCTAssertTrue(e.excludeNames.contains("node_modules"))
        XCTAssertTrue(e.excludeNames.contains(".venv"))
        XCTAssertTrue(e.downrankNames.contains("build"))
        XCTAssertTrue(e.downrankNames.contains("vendor"))
        // `~` was expanded: a miniconda3 path rooted at `home` is present, and no path still begins with "~".
        XCTAssertTrue(e.excludePaths.contains("\(home)/miniconda3"), "expected expanded miniconda3 path; got \(e.excludePaths)")
        XCTAssertTrue(e.excludePaths.contains("\(home)/Library"))
        XCTAssertFalse(e.excludePaths.contains { $0.hasPrefix("~") }, "tilde not expanded in \(e.excludePaths)")
    }

    func testDefaultUsesDocumentedConstants() {
        let e = Exclusions.defaults(home: home)
        XCTAssertFalse(e.includeHidden)
        XCTAssertEqual(e.maxDepth, 12)
        XCTAssertEqual(e.maxDirEntries, 20_000)
        XCTAssertEqual(e.downrankDirEntries, 5_000)
    }

    // MARK: - expandTilde

    func testExpandTilde() {
        XCTAssertEqual(Exclusions.expandTilde("~", home: home), "/home/u")
        XCTAssertEqual(Exclusions.expandTilde("~/", home: home), "/home/u")
        XCTAssertEqual(Exclusions.expandTilde("~/Library", home: home), "/home/u/Library")
        XCTAssertEqual(Exclusions.expandTilde("~/Library/", home: home), "/home/u/Library")
        XCTAssertEqual(Exclusions.expandTilde("~/a/b/", home: home), "/home/u/a/b")
        // Absolute paths: only trailing-slash normalisation.
        XCTAssertEqual(Exclusions.expandTilde("/abs/path", home: home), "/abs/path")
        XCTAssertEqual(Exclusions.expandTilde("/abs/path/", home: home), "/abs/path")
        XCTAssertEqual(Exclusions.expandTilde("/", home: home), "/")
        // A "~" that is not "~" alone nor a "~/" prefix is left untouched.
        XCTAssertEqual(Exclusions.expandTilde("~foo", home: home), "~foo")
        XCTAssertEqual(Exclusions.expandTilde("relative", home: home), "relative")
        // A home with a trailing slash is normalised before substitution.
        XCTAssertEqual(Exclusions.expandTilde("~", home: "/home/u/"), "/home/u")
        XCTAssertEqual(Exclusions.expandTilde("~/x", home: "/home/u/"), "/home/u/x")
    }

    // MARK: - Name checks (case-insensitive)

    func testIsExcludedNameIsCaseInsensitive() {
        let e = Exclusions.defaults(home: home)
        XCTAssertTrue(e.isExcludedName("node_modules"))
        XCTAssertTrue(e.isExcludedName("NODE_MODULES"))
        XCTAssertTrue(e.isExcludedName("Node_Modules"))
        XCTAssertTrue(e.isExcludedName(".GIT"))
        XCTAssertFalse(e.isExcludedName("src"))
        XCTAssertFalse(e.isExcludedName("Documents"))
    }

    func testIsDownrankNameIsCaseInsensitive() {
        let e = Exclusions.defaults(home: home)
        XCTAssertTrue(e.isDownrankName("build"))
        XCTAssertTrue(e.isDownrankName("BUILD"))
        XCTAssertTrue(e.isDownrankName("Vendor"))
        XCTAssertTrue(e.isDownrankName("target"))
        XCTAssertFalse(e.isDownrankName("src"))
        XCTAssertFalse(e.isDownrankName("node_modules")) // excluded, not downranked
    }

    // MARK: - Path checks (exact + glob)

    func testIsExcludedPathExact() {
        let e = Exclusions.defaults(home: home)
        XCTAssertTrue(e.isExcludedPath("/home/u/Library"))
        XCTAssertTrue(e.isExcludedPath("/home/u/library"))          // case-insensitive
        XCTAssertTrue(e.isExcludedPath("/home/u/Library/"))          // trailing slash normalised
        XCTAssertTrue(e.isExcludedPath("/home/u/miniconda3"))
        XCTAssertTrue(e.isExcludedPath("/home/u/.Trash"))
        XCTAssertFalse(e.isExcludedPath("/home/u/Documents"))
        XCTAssertFalse(e.isExcludedPath("/home/u/Library/Extra"))    // only the exact dir, not descendants
    }

    func testIsExcludedPathGlobOnLastComponent() {
        let e = Exclusions.defaults(home: home)
        // "~/Creative Cloud Files*" — prefix glob on the last component.
        XCTAssertTrue(e.isExcludedPath("/home/u/Creative Cloud Files"))
        XCTAssertTrue(e.isExcludedPath("/home/u/Creative Cloud Files 2024"))
        XCTAssertTrue(e.isExcludedPath("/home/u/creative cloud files"))     // case-insensitive
        XCTAssertFalse(e.isExcludedPath("/home/u/Creative Cloud"))          // does not reach "Files"
        XCTAssertFalse(e.isExcludedPath("/home/u/x/Creative Cloud Files"))  // wrong parent
        // "~/Pictures/*.photoslibrary"
        XCTAssertTrue(e.isExcludedPath("/home/u/Pictures/My Photos.photoslibrary"))
        XCTAssertTrue(e.isExcludedPath("/home/u/Pictures/library.photoslibrary"))
        XCTAssertFalse(e.isExcludedPath("/home/u/Pictures/My Photos.library"))   // wrong extension
        XCTAssertFalse(e.isExcludedPath("/home/u/Documents/x.photoslibrary"))    // wrong parent
    }

    func testExcludedPathMatcherHelpers() {
        XCTAssertEqual(ExcludedPathMatcher.normalize("/A/B/"), "/a/b")
        XCTAssertEqual(ExcludedPathMatcher.normalize("/"), "/")
        XCTAssertEqual(ExcludedPathMatcher.parent(of: "/a/b/c"), "/a/b")
        XCTAssertEqual(ExcludedPathMatcher.parent(of: "/a"), "/")
        XCTAssertEqual(ExcludedPathMatcher.parent(of: "rel"), "")
        // Empty patterns are dropped and never match.
        XCTAssertFalse(ExcludedPathMatcher(patterns: ["", "  "].map { $0 }).matches("/anything"))
    }

    // MARK: - stableHash

    func testStableHashEqualForEqualConfigs() {
        let a = Exclusions.defaults(home: home)
        let b = Exclusions.defaults(home: home)
        XCTAssertEqual(a.stableHash, b.stableHash)
        XCTAssertEqual(a, b)
    }

    func testStableHashIsOrderIndependentForPaths() {
        // excludePaths is an array but stableHash sorts it, so ordering does not matter.
        let a = Exclusions(excludeNames: ["x", "y"], excludePaths: ["/a", "/b", "/c"], downrankNames: ["p"])
        let b = Exclusions(excludeNames: ["y", "x"], excludePaths: ["/c", "/a", "/b"], downrankNames: ["p"])
        XCTAssertEqual(a.stableHash, b.stableHash)
    }

    func testStableHashDiffersWhenAnyFieldChanges() {
        let base = Exclusions(excludeNames: ["node_modules"], excludePaths: ["/home/u/Library"], downrankNames: ["build"])
        var names = base; names.excludeNames.insert("extra")
        var paths = base; paths.excludePaths.append("/home/u/other")
        var down = base; down.downrankNames.insert("dist")
        var hidden = base; hidden.includeHidden = true
        var depth = base; depth.maxDepth = 3
        var dirEntries = base; dirEntries.maxDirEntries = 42
        var downrankEntries = base; downrankEntries.downrankDirEntries = 42
        let hashes = [base, names, paths, down, hidden, depth, dirEntries, downrankEntries].map { $0.stableHash }
        XCTAssertEqual(Set(hashes).count, hashes.count, "every distinct config must hash differently: \(hashes)")
    }

    // MARK: - FNV1a

    func testFNV1aIsStableAndDeterministic() {
        XCTAssertEqual(FNV1a.hash("hello"), FNV1a.hash("hello"))
        XCTAssertNotEqual(FNV1a.hash("hello"), FNV1a.hash("world"))
        // Well-known FNV-1a 64 vector for the empty string is the offset basis.
        var empty = FNV1a()
        XCTAssertEqual(empty.value, 0xcbf29ce484222325)
        empty.update("")
        XCTAssertEqual(empty.value, 0xcbf29ce484222325)
        // Updating byte-by-byte matches updating with a string.
        var byBytes = FNV1a()
        for b in "abc".utf8 { byBytes.update(byte: b) }
        XCTAssertEqual(byBytes.value, FNV1a.hash("abc"))
        // The UInt64 overload folds all eight bytes in.
        var u1 = FNV1a(); u1.update(UInt64(1))
        var u2 = FNV1a(); u2.update(UInt64(2))
        XCTAssertNotEqual(u1.value, u2.value)
    }
}
