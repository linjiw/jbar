import XCTest
@testable import JBarCore

final class HighlightRegressionTests: XCTestCase {
    func testMatchPositionsCountEqualsQueryLength() {
        let cases = ["codex-experimental-api-macros", "codex_last_message.txt", "Visual Studio Code", "Claude Code URL Handler", "encoder"]
        for text in cases {
            let t = TextAnalyzer.analyze(text)
            let q = TextAnalyzer.analyze("code")
            let pos = Scorer.matchPositions(query: q.folded[...], text: t.folded[...], bonus: t.bonus[...])
            XCTAssertEqual(pos.count, 4, "\(text): \(pos)")
            XCTAssertEqual(pos, pos.sorted(), "positions must be increasing: \(text)")
            for (k, p) in pos.enumerated() { XCTAssertEqual(t.folded[p], q.folded[k], "\(text) pos \(p)") }
            let score = Scorer.score(query: q.folded[...], text: t.folded[...], bonus: t.bonus[...], scratch: ScorerScratch())
            print("\(text): positions=\(pos) score=\(String(describing: score))")
        }
    }
}
