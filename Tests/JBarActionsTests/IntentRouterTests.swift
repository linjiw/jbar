import XCTest
@testable import JBarActions

final class IntentRouterTests: XCTestCase {
    private let router = IntentRouter()

    func testRoutesOnlyLeadingSigilsIntoActions() {
        XCTAssertEqual(router.route("report ? draft"), .search(query: "report ? draft"))
        XCTAssertEqual(router.route("? explain this"), .ask(prompt: "explain this"))
        XCTAssertEqual(router.route("! tidy screenshots"), .organize(task: "tidy screenshots"))
        XCTAssertEqual(router.route("> git status"), .shell(command: "git status"))
    }

    func testRoutesFullWidthChineseInputSigils() {
        XCTAssertEqual(router.route("？ 查找八月的收据"), .ask(prompt: "查找八月的收据"))
        XCTAssertEqual(router.route("！ 整理所有截图"), .organize(task: "整理所有截图"))
        XCTAssertEqual(router.route("＞ 检查工作区"), .shell(command: "检查工作区"))
    }

    func testEmptyActionPayloadStaysAnActionButCannotBeSubmittedByTheUI() {
        XCTAssertEqual(router.route("?   "), .ask(prompt: ""))
        XCTAssertEqual(router.route("!"), .organize(task: ""))
        XCTAssertEqual(router.route(">\n\t"), .shell(command: ""))
    }

    func testSearchIntentHasNoActionPayload() {
        XCTAssertFalse(router.route("invoice").isAction)
        XCTAssertNil(router.route("invoice").payload)
        XCTAssertEqual(router.route("? a").payload, "a")
    }
}
