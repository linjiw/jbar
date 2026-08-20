import XCTest
@testable import JBarCore

/// `Crawler.depthOf(path:)` must assign the same depth the full crawl assigns, for every root shape —
/// this is what makes incremental FSEvents re-lists depth-consistent (the old topology heuristic was
/// off by one for a "/" root and again for a root that is an immediate child of "/").
final class DepthOfTests: XCTestCase {
    private func crawler(roots: [String]) -> Crawler {
        Crawler(roots: roots.map { CrawlRoot(path: $0) }, exclusions: .defaults(home: "/Users/me"))
    }
    func testComponentCount() {
        XCTAssertEqual(Crawler.pathComponentCount("/"), 0)
        XCTAssertEqual(Crawler.pathComponentCount("/opt"), 1)
        XCTAssertEqual(Crawler.pathComponentCount("/Users/me/projects"), 3)
        XCTAssertEqual(Crawler.pathComponentCount("/Users/me/projects/"), 3)
    }
    func testHomeSubdirRoot() {
        let c = crawler(roots: ["/Users/me/projects"])
        XCTAssertEqual(c.depthOf(path: "/Users/me/projects"), 0)       // root dir itself
        XCTAssertEqual(c.depthOf(path: "/Users/me/projects/foo"), 1)   // direct child
        XCTAssertEqual(c.depthOf(path: "/Users/me/projects/foo/bar"), 2)
    }
    func testSlashRoot() {
        let c = crawler(roots: ["/"])
        XCTAssertEqual(c.depthOf(path: "/"), 0)
        XCTAssertEqual(c.depthOf(path: "/opt"), 1)
        XCTAssertEqual(c.depthOf(path: "/opt/bar"), 2)
    }
    func testChildOfSlashRoot() {
        // The case the topology heuristic got wrong: a root that is an immediate child of "/".
        let c = crawler(roots: ["/opt"])
        XCTAssertEqual(c.depthOf(path: "/opt"), 0)
        XCTAssertEqual(c.depthOf(path: "/opt/bar"), 1)
        XCTAssertEqual(c.depthOf(path: "/opt/bar/baz"), 2)
    }
    func testMostSpecificRootWins() {
        let c = crawler(roots: ["/Users/me", "/Users/me/projects"])
        // /Users/me/projects/foo is under both roots; the deeper root gives the right (smaller) depth.
        XCTAssertEqual(c.depthOf(path: "/Users/me/projects/foo"), 1)
    }
    func testUnknownPathIsZero() {
        let c = crawler(roots: ["/Users/me/projects"])
        XCTAssertEqual(c.depthOf(path: "/somewhere/else"), 0)
    }
}
