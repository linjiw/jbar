import XCTest
@testable import JBarCore

final class TextAnalyzerTests: XCTestCase {
    func testFoldLowercasesAndStripsDiacritics() {
        XCTAssertEqual(TextAnalyzer.fold("Café Résumé"), "cafe resume")
        XCTAssertEqual(TextAnalyzer.fold("ＡＢＣ"), "abc") // width-insensitive
        XCTAssertEqual(TextAnalyzer.fold("微信"), "微信")
    }

    func testFoldCanonicalizesDecomposedKorean() {
        let precomposed = "한글"
        let decomposed = precomposed.decomposedStringWithCanonicalMapping

        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8), "fixture must exercise distinct UTF-8 encodings")
        XCTAssertEqual(TextAnalyzer.fold(decomposed), TextAnalyzer.fold(precomposed))

        let precomposedAnalysis = TextAnalyzer.analyze(precomposed)
        let decomposedAnalysis = TextAnalyzer.analyze(decomposed)
        XCTAssertEqual(decomposedAnalysis.folded, precomposedAnalysis.folded)
        XCTAssertEqual(decomposedAnalysis.folded, Array(TextAnalyzer.fold(decomposed).utf8))
        XCTAssertEqual(decomposedAnalysis.bonus, precomposedAnalysis.bonus)
        XCTAssertEqual(decomposedAnalysis.mask, precomposedAnalysis.mask)
    }

    func testKoreanCanonicalMatchMapsBackToOriginalCharacters() {
        let display = "한글".decomposedStringWithCanonicalMapping
        let text = TextAnalyzer.analyze(display)
        let query = TextAnalyzer.analyze("글")

        let positions = Scorer.matchPositions(query: query.folded[...], text: text.folded[...], bonus: text.bonus[...])
        XCTAssertEqual(positions.count, query.folded.count)
        XCTAssertEqual(TextAnalyzer.characterIndices(display: display, matchedFoldedByteOffsets: positions), [1])
        XCTAssertLessThan(1, display.count, "highlight index must be valid in the original decomposed display string")
    }

    func testInitials() {
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("Visual Studio Code").initials), Array("vsc".utf8))
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("Google Chrome").initials), Array("gc".utf8))
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("iTermApp").initials), Array("ita".utf8))
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("report2024.pdf").initials), Array("r2p".utf8))
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("node-gyp_build").initials), Array("ngb".utf8))
    }

    func testTokens() {
        XCTAssertEqual(TextAnalyzer.tokens("iTermApp"), ["i", "Term", "App"])
        XCTAssertEqual(TextAnalyzer.tokens("report2024.pdf"), ["report", "2024", "pdf"])
        XCTAssertEqual(TextAnalyzer.tokens("Visual Studio Code"), ["Visual", "Studio", "Code"])
        XCTAssertEqual(TextAnalyzer.tokens("my-file_name (1).txt"), ["my", "file", "name", "1", "txt"])
    }

    func testBonusAndAlignment() {
        let s = TextAnalyzer.analyze("Visual Studio Code")
        XCTAssertEqual(s.folded, Array("visual studio code".utf8))
        XCTAssertEqual(s.folded.count, s.bonus.count)
        XCTAssertEqual(s.bonus[0], BonusConstants.white)   // 'V' at start
        XCTAssertEqual(s.bonus[1], 0)                      // 'i'
        XCTAssertEqual(s.bonus[7], BonusConstants.white)   // 'S' after space
        let camel = TextAnalyzer.analyze("fooBar9")
        XCTAssertEqual(camel.bonus[3], BonusConstants.camel) // 'B'
        XCTAssertEqual(camel.bonus[6], BonusConstants.camel) // '9' after letter
        let cjk = TextAnalyzer.analyze("微信")
        XCTAssertEqual(cjk.folded.count, 6)
        XCTAssertEqual(cjk.bonus[0], BonusConstants.white)
        XCTAssertEqual(cjk.bonus[1], 0); XCTAssertEqual(cjk.bonus[2], 0)
        XCTAssertEqual(cjk.bonus[3], 0) // second CJK char follows an ideograph (class lower→lower)
    }

    func testMask() {
        let s = TextAnalyzer.analyze("vsc 42!")
        XCTAssertTrue(s.mask & Mask.bit(forFoldedByte: UInt8(ascii: "v")) != 0)
        XCTAssertTrue(s.mask & Mask.bit(forFoldedByte: UInt8(ascii: "4")) != 0)
        XCTAssertTrue(s.mask & (1 << 36) != 0)
        XCTAssertTrue(s.mask & Mask.bit(forFoldedByte: UInt8(ascii: "z")) == 0)
        let q = TextAnalyzer.analyze("vc")
        XCTAssertEqual(s.mask & q.mask, q.mask)
    }

    func testCharacterIndicesMapping() {
        // "Café.txt" folds to "cafe.txt": byte offsets 0,3,4 -> chars C(0), é(3), .(4)
        let idx = TextAnalyzer.characterIndices(display: "Café.txt", matchedFoldedByteOffsets: [0, 3, 4])
        XCTAssertEqual(idx, [0, 3, 4])
        // CJK: "微信" folded bytes 0..5; matching byte 3 -> char 1
        XCTAssertEqual(TextAnalyzer.characterIndices(display: "微信", matchedFoldedByteOffsets: [3]), [1])
    }

    func testFileExtension() {
        XCTAssertEqual(TextAnalyzer.fileExtension(of: "Report.PDF"), "pdf")
        XCTAssertNil(TextAnalyzer.fileExtension(of: ".bashrc"))
        XCTAssertNil(TextAnalyzer.fileExtension(of: "Makefile"))
        XCTAssertNil(TextAnalyzer.fileExtension(of: "a.verylongextension"))
    }
}

final class IndexStoreTests: XCTestCase {
    func testBuildAndPaths() {
        let b = IndexBuilder()
        let root = b.addRoot("/Users/me")
        let docs = b.addDir(parent: root, name: "Documents")
        let sub = b.addDir(parent: docs, name: "Sub Dir")
        let i = b.addItem(dir: sub, name: "Résumé.pdf", analyzed: TextAnalyzer.analyze("Résumé.pdf"), kind: .document, flags: [], mtime: Date(timeIntervalSinceReferenceDate: 1000), depth: 3, ext: "pdf")
        let a = b.addItem(dir: root, name: "Xcode", analyzed: TextAnalyzer.analyze("Xcode"), kind: .app, flags: [.appBundle], mtime: nil, depth: 1, ext: "app", app: AppInfo(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", aliases: []))
        let s = b.build(generation: 1)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.path(of: Int(i)), "/Users/me/Documents/Sub Dir/Résumé.pdf")
        XCTAssertEqual(s.name(of: Int(i)), "Résumé.pdf")
        XCTAssertEqual(Array(s.foldedName(of: Int(i))), Array("resume.pdf".utf8))
        XCTAssertEqual(s.ext(of: Int(i)), "pdf")
        XCTAssertEqual(s.itemKind(Int(a)), .app)
        XCTAssertEqual(s.path(of: Int(a)), "/Users/me/Xcode.app", "app bundle paths must carry the .app suffix")
        XCTAssertEqual(s.fileName(of: Int(a)), "Xcode.app")
        XCTAssertEqual(s.name(of: Int(a)), "Xcode")
        XCTAssertEqual(s.appItems, [a])
        XCTAssertEqual(s.appInfo[a]?.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(s.parentDisplayPath(of: Int(i), home: "/Users/me"), "~/Documents/Sub Dir")
        XCTAssertEqual(s.mtime[Int(i)], 1000)
        XCTAssertEqual(s.dirPath(root), "/Users/me")
    }
    func testRootWithTrailingSlash() {
        let b = IndexBuilder()
        let root = b.addRoot("/")
        let i = b.addItem(dir: root, name: "Applications", analyzed: TextAnalyzer.analyze("Applications"), kind: .folder, flags: [], mtime: nil, depth: 1, ext: nil)
        XCTAssertEqual(b.build(generation: 1).path(of: Int(i)), "/Applications")
    }
}
