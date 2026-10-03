import XCTest
import JBarCLI

final class CLIOptionsSmokeTests: XCTestCase {
    func testMachineOutputParsingDoesNotNeedAnIndex() throws {
        let options = try CLIOptions.parse(["search", "report pdf", "--format", "json", "--limit", "500"])
        XCTAssertEqual(options.command, .search)
        XCTAssertEqual(options.query, "report pdf")
        XCTAssertEqual(options.format, .json)
        XCTAssertEqual(options.limit, 500)
    }
}
