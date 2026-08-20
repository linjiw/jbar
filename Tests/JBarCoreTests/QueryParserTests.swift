import XCTest
@testable import JBarCore

final class QueryParserTests: XCTestCase {
    private let home = "/Users/test"

    private func parse(_ s: String) -> ParsedQuery { QueryParser.parse(s, home: home) }

    // MARK: - Empty

    func testEmptyAndWhitespaceOnly() {
        for s in ["", " ", "\n\t  "] {
            let q = parse(s)
            XCTAssertEqual(q.mode, .empty, "'\(s)'")
            XCTAssertEqual(q.raw, s)
            XCTAssertTrue(q.terms.isEmpty)
            XCTAssertTrue(q.termStrings.isEmpty)
            XCTAssertTrue(q.wholeFolded.isEmpty)
            XCTAssertEqual(q.mask, 0)
            XCTAssertFalse(q.lastTermComplete)
            XCTAssertFalse(q.hasUppercase)
        }
    }

    // MARK: - Search

    func testSingleTerm() {
        let q = parse("vsc")
        XCTAssertEqual(q.mode, .search)
        XCTAssertEqual(q.termStrings, ["vsc"])
        XCTAssertEqual(q.terms.count, 1)
        XCTAssertEqual(q.terms[0].folded, Array("vsc".utf8))
        XCTAssertEqual(q.wholeFolded, Array("vsc".utf8))
        XCTAssertEqual(q.mask, Mask.of(Array("vsc".utf8)))
        XCTAssertFalse(q.lastTermComplete)
        XCTAssertFalse(q.hasUppercase)
    }

    func testMultipleTermsAndWhole() {
        let q = parse("  Visual   Studio code ")
        XCTAssertEqual(q.mode, .search)
        XCTAssertEqual(q.termStrings, ["Visual", "Studio", "code"])
        XCTAssertEqual(q.terms.map { String(decoding: $0.folded, as: UTF8.self) }, ["visual", "studio", "code"])
        XCTAssertEqual(String(decoding: q.wholeFolded, as: UTF8.self), "visual studio code", "whitespace runs collapsed, folded")
        XCTAssertEqual(q.mask, q.terms.reduce(0) { $0 | $1.mask })
        XCTAssertTrue(q.hasUppercase)
        XCTAssertTrue(q.lastTermComplete, "trailing space → last term complete")
        XCTAssertEqual(q.raw, "  Visual   Studio code ")
    }

    func testLastTermCompleteVariants() {
        XCTAssertFalse(parse("report pdf").lastTermComplete)
        XCTAssertTrue(parse("report pdf ").lastTermComplete)
        XCTAssertTrue(parse("report pdf\n").lastTermComplete)
        XCTAssertTrue(parse("report pdf\t").lastTermComplete)
        XCTAssertFalse(parse("  report").lastTermComplete, "leading whitespace only")
    }

    func testNeverSplitsOnDashOrUnderscore() {
        let q = parse("node-gyp my_file")
        XCTAssertEqual(q.termStrings, ["node-gyp", "my_file"])
        XCTAssertEqual(q.terms[0].folded, Array("node-gyp".utf8))
    }

    func testMaxSixTerms() {
        let q = parse("a b c d e f g h")
        XCTAssertEqual(q.termStrings, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(q.terms.count, 6)
        XCTAssertEqual(String(decoding: q.wholeFolded, as: UTF8.self), "a b c d e f g h")
    }

    func testFoldingAndMask() {
        let q = parse("Café Résumé")
        XCTAssertEqual(q.terms.map { String(decoding: $0.folded, as: UTF8.self) }, ["cafe", "resume"])
        XCTAssertEqual(String(decoding: q.wholeFolded, as: UTF8.self), "cafe resume")
        XCTAssertTrue(q.hasUppercase)
        let expectedMask = Mask.of(Array("caferesume".utf8))
        XCTAssertEqual(q.mask, expectedMask)
    }

    func testCJKQuery() {
        let q = parse("微信")
        XCTAssertEqual(q.mode, .search)
        XCTAssertEqual(q.termStrings, ["微信"])
        XCTAssertNotEqual(q.mask & (1 << 37), 0, "non-ASCII bit set")
        XCTAssertFalse(q.hasUppercase)
    }

    func testHasUppercaseOnlyForUppercase() {
        XCTAssertFalse(parse("xcode 12").hasUppercase)
        XCTAssertTrue(parse("Xcode").hasUppercase)
        XCTAssertTrue(parse("xcoDe").hasUppercase)
    }

    func testDotQueriesThatAreNotExtensionOnly() {
        // Too long (9 chars after the dot) → search.
        XCTAssertEqual(parse(".gitignore").mode, .search)
        // Lone dot → search.
        XCTAssertEqual(parse(".").mode, .search)
        // Contains whitespace → search (two terms).
        let q = parse(".pdf report")
        XCTAssertEqual(q.mode, .search)
        XCTAssertEqual(q.termStrings, [".pdf", "report"])
        // Non-alphanumeric char → search.
        XCTAssertEqual(parse(".tar.gz").mode, .search)
        XCTAssertEqual(parse(".c++").mode, .search)
        XCTAssertEqual(parse(".env-local").mode, .search)
        // Dot in the middle → search.
        XCTAssertEqual(parse("report.pdf").mode, .search)
    }

    // MARK: - Extension-only

    func testExtensionOnly() {
        let q = parse(".pdf")
        XCTAssertEqual(q.mode, .extensionOnly("pdf"))
        XCTAssertEqual(q.termStrings, ["pdf"])
        XCTAssertEqual(q.terms.count, 1)
        XCTAssertEqual(q.wholeFolded, Array("pdf".utf8))
        XCTAssertEqual(q.mask, Mask.of(Array("pdf".utf8)))
        XCTAssertFalse(q.lastTermComplete)
    }

    func testExtensionOnlyCaseAndLength() {
        XCTAssertEqual(parse(".PDF").mode, .extensionOnly("pdf"))
        XCTAssertEqual(parse(" .Mp4 ").mode, .extensionOnly("mp4"))
        XCTAssertEqual(parse(".c").mode, .extensionOnly("c"))
        XCTAssertEqual(parse(".7z").mode, .extensionOnly("7z"))
        XCTAssertEqual(parse(".markdown").mode, .extensionOnly("markdown"), "8 chars allowed")
        XCTAssertEqual(parse(".abcdefghi").mode, .search, "9 chars → not extension-only")
        XCTAssertTrue(parse(".pdf ").lastTermComplete)
        XCTAssertTrue(parse(".PDF").hasUppercase)
    }

    // MARK: - Path mode

    private func assertPath(_ s: String, base: String, filter: String, _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let q = parse(s)
        XCTAssertEqual(q.mode, .path(base: base, filter: filter), "'\(s)' \(note)", file: file, line: line)
    }

    func testPathModeHome() {
        assertPath("~", base: home, filter: "")
        assertPath("~/", base: home, filter: "")
        assertPath("~/Dow", base: home, filter: "Dow")
        assertPath("~/Documents/rep", base: home + "/Documents", filter: "rep")
        assertPath("~/Documents/", base: home + "/Documents", filter: "")
        assertPath("~/Documents//", base: home + "/Documents", filter: "")
        assertPath("~Dow", base: home, filter: "Dow", "a missed slash after ~ is tolerated")
        assertPath("~/My Folder/some file", base: home + "/My Folder", filter: "some file")
        assertPath("  ~/Dow  ", base: home, filter: "Dow")
    }

    func testPathModeAbsolute() {
        assertPath("/", base: "/", filter: "")
        assertPath("/App", base: "/", filter: "App")
        assertPath("/Applications/", base: "/Applications", filter: "")
        assertPath("/Applications/Xc", base: "/Applications", filter: "Xc")
        assertPath("/Applications/Utilities/Term", base: "/Applications/Utilities", filter: "Term")
        assertPath("//", base: "/", filter: "")
    }

    func testPathModeTermsDescribeFilter() {
        let q = parse("~/Dow")
        XCTAssertEqual(q.termStrings, ["Dow"])
        XCTAssertEqual(q.terms.count, 1)
        XCTAssertEqual(q.terms[0].folded, Array("dow".utf8))
        XCTAssertEqual(q.wholeFolded, Array("dow".utf8))
        XCTAssertEqual(q.mask, Mask.of(Array("dow".utf8)))
        XCTAssertTrue(q.hasUppercase)
        XCTAssertFalse(q.lastTermComplete)

        let empty = parse("~/Documents/")
        XCTAssertTrue(empty.terms.isEmpty)
        XCTAssertTrue(empty.termStrings.isEmpty)
        XCTAssertTrue(empty.wholeFolded.isEmpty)
        XCTAssertEqual(empty.mask, 0)
    }

    func testSlashInsideQueryIsNotPathMode() {
        // Only a leading `/` or `~` triggers path mode; `a/b` is a normal search term.
        let q = parse("src/main")
        XCTAssertEqual(q.mode, .search)
        XCTAssertEqual(q.termStrings, ["src/main"])
    }

    func testDefaultHomeParameter() {
        let q = QueryParser.parse("~/x")
        XCTAssertEqual(q.mode, .path(base: NSHomeDirectory(), filter: "x"))
    }

    // MARK: - Helpers

    func testSplitPathHelper() {
        XCTAssertEqual(QueryParser.splitPath("/a/b/c", home: home).base, "/a/b")
        XCTAssertEqual(QueryParser.splitPath("/a/b/c", home: home).filter, "c")
        XCTAssertEqual(QueryParser.splitPath("~", home: "/").base, "/")
    }

    func testExtensionOnlyHelper() {
        XCTAssertEqual(QueryParser.extensionOnly(".pdf"), "pdf")
        XCTAssertNil(QueryParser.extensionOnly("pdf"))
        XCTAssertNil(QueryParser.extensionOnly("."))
        XCTAssertNil(QueryParser.extensionOnly(".a b"))
        XCTAssertNil(QueryParser.extensionOnly(".ä"))
    }
}
