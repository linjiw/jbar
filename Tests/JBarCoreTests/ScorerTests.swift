import XCTest
@testable import JBarCore

/// Tests for `Scorer` (DESIGN.md §6.3–6.4). Scores are asserted against hand-derived values from the
/// spec's recurrence, a straight-line reference implementation of the pseudocode, and an alignment
/// evaluator that re-scores the positions returned by `matchPositions`.
final class ScorerTests: XCTestCase {
    private let scratch = ScorerScratch()

    // MARK: Helpers

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Score of `query` (already folded) against the display string `text` using real analyzer bonuses.
    private func score(_ query: String, _ text: String) -> Int16? {
        let t = TextAnalyzer.analyze(text)
        return Scorer.score(query: bytes(query), text: t.folded, bonus: t.bonus, scratch: scratch)?.score
    }

    private func positions(_ query: String, _ text: String) -> [Int] {
        let t = TextAnalyzer.analyze(text)
        return Scorer.matchPositions(query: bytes(query)[...], text: t.folded[...], bonus: t.bonus[...])
    }

    /// Score of one concrete alignment (increasing positions) per §6.3 semantics + fzf's run rule: first match
    /// gets `match + 2·bonus`; a match continuing a run gets `match + max(bonus, consecutive, bonusOfRunStart)`
    /// unless its own bonus is a boundary bonus (≥ `boundary`) larger than the run start's, in which case it
    /// starts a new run (`match + bonus`); a match after a gap of g bytes gets
    /// `match + bonus + gapStart + (g−1)·gapExt`. Leading/trailing gaps are free.
    private func alignmentScore(_ pos: [Int], bonus: [UInt8]) -> Int {
        var s = 0
        var runStart = 0
        let consec = Int(BonusConstants.consecutive), boundary = Int(BonusConstants.boundary)
        for (k, p) in pos.enumerated() {
            if k == 0 { s += Int(ScoreConstants.match) + Int(bonus[p]) * Int(BonusConstants.firstMult); runStart = p; continue }
            let gap = p - pos[k - 1] - 1
            if gap == 0 {
                let b = Int(bonus[p]), fb = Int(bonus[runStart])
                if b >= boundary && b > fb { s += Int(ScoreConstants.match) + b; runStart = p }
                else { s += Int(ScoreConstants.match) + max(b, max(consec, fb)) }
            } else {
                s += Int(ScoreConstants.gapStart) + (gap - 1) * Int(ScoreConstants.gapExt)
                s += Int(ScoreConstants.match) + Int(bonus[p])
                runStart = p
            }
        }
        return s
    }

    /// Best `alignmentScore` over every alignment of `q` in `t` (exponential; tiny inputs only).
    private func bruteForceBest(_ q: [UInt8], _ t: [UInt8], _ b: [UInt8]) -> Int? {
        var best: Int?
        var pos: [Int] = []
        func rec(_ i: Int, _ from: Int) {
            if i == q.count { let s = alignmentScore(pos, bonus: b); if best == nil || s > best! { best = s }; return }
            var j = from
            while j < t.count {
                if t[j] == q[i] { pos.append(j); rec(i + 1, j + 1); pos.removeLast() }
                j += 1
            }
        }
        rec(0, 0)
        return best
    }

    /// Straight-line transcription of the DESIGN.md §6.3 pseudocode (full rows, Int arithmetic, no
    /// start/end pruning). Used to validate the optimised implementation on random inputs.
    private func referenceScore(_ q: [UInt8], _ t: [UInt8], _ b: [UInt8]) -> Int? {
        let m = q.count, n = t.count
        if m == 0 { return 0 }
        if m > n || Scorer.subsequenceStart(query: q[...], text: t[...]) == nil { return nil }
        let neg = Int(ScoreConstants.neg), match = Int(ScoreConstants.match)
        let gs = Int(ScoreConstants.gapStart), ge = Int(ScoreConstants.gapExt)
        let consec = Int(BonusConstants.consecutive), fm = Int(BonusConstants.firstMult)
        let boundary = Int(BonusConstants.boundary)
        var h = [Int](repeating: neg, count: n), c = [Int](repeating: 0, count: n)
        var prevH = neg, inGap = false
        for j in 0..<n {
            let s1 = t[j] == q[0] ? match + Int(b[j]) * fm : neg
            let s2 = prevH > neg ? prevH + (inGap ? ge : gs) : neg
            if s1 >= s2 { h[j] = s1; c[j] = 1; inGap = false } else { h[j] = s2; c[j] = 0; inGap = true }
            prevH = h[j]
        }
        for i in 1..<max(1, m) {
            var diagH = neg, diagC = 0
            prevH = neg; inGap = false
            for j in 0..<n {
                let upH = h[j], upC = c[j]
                var s1 = neg, c1 = 0
                if t[j] == q[i] && diagH > neg {
                    var bb = Int(b[j]); c1 = diagC + 1
                    if diagC > 0 {
                        let fb = Int(b[j - diagC])
                        if bb >= boundary && bb > fb { c1 = 1 } else { bb = max(bb, max(consec, fb)) }
                    }
                    s1 = diagH + match + bb
                }
                let s2 = prevH > neg ? prevH + (inGap ? ge : gs) : neg
                if s1 >= s2 { h[j] = s1; c[j] = c1; inGap = false } else { h[j] = s2; c[j] = 0; inGap = true }
                diagH = upH; diagC = upC; prevH = h[j]
            }
        }
        return h.max()
    }

    /// Deterministic PRNG (SplitMix64) so failures are reproducible.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: (1) Subsequence semantics

    func testSubsequenceStart() {
        let t = bytes("visual studio code")[...]
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("")[...], text: t), 0)
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("vsc")[...], text: t), 0)
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("code")[...], text: t), 14)
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("visual studio code")[...], text: t), 0)
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("visual studio codex")[...], text: t))
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("vscz")[...], text: t))
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("ev")[...], text: t))   // order matters
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("VSC")[...], text: t))  // inputs are folded; no case folding here
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("a")[...], text: bytes("")[...]))
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("")[...], text: bytes("")[...]), 0)
        // Slices with non-zero startIndex: result is relative to text.startIndex.
        let arena = bytes("xxxabcxxx")
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("bc")[...], text: arena[3..<6]), 1)
        XCTAssertEqual(Scorer.subsequenceStart(query: arena[4..<6], text: arena[3..<6]), 1)
        XCTAssertNil(Scorer.subsequenceStart(query: bytes("x")[...], text: arena[3..<6]))
    }

    func testSubsequenceStartIsGreedyLeftmost() {
        // 'sc' in "visual studio code": first 's' at 2 ("vi-s-ual"), then 'c' at 14 → start 2.
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("sc")[...], text: bytes("visual studio code")[...]), 2)
        XCTAssertEqual(Scorer.subsequenceStart(query: bytes("ab")[...], text: bytes("a a b")[...]), 0)
    }

    func testSubsequenceStartOnUTF8Bytes() {
        let cjk = TextAnalyzer.analyze("微信")
        XCTAssertEqual(Scorer.subsequenceStart(query: cjk.folded[3..<6], text: cjk.folded[...]), 3)
        XCTAssertEqual(Scorer.subsequenceStart(query: cjk.folded[...], text: cjk.folded[...]), 0)
    }

    // MARK: (2) Exact values and ranking sanity

    func testExactScoresFromSpecRecurrence() {
        // "a" vs "a": match + white·firstMult = 16 + 32.
        XCTAssertEqual(score("a", "a"), 48)
        // "ab" vs "ab": 48 + (16 + run-start bonus 16) = 80 (fzf rule: a run carries its first byte's bonus).
        XCTAssertEqual(score("ab", "ab"), 80)
        // "ab" vs "axb": 48, gap start −3 → 45 at 'x', then 'b' = 45 + 16 + 0 = 61.
        XCTAssertEqual(score("ab", "axb"), 61)
        // "ab" vs "axxb": 48 → 45 → 44 → 'b' 60.
        XCTAssertEqual(score("ab", "axxb"), 60)
        // "b" vs "ab": 'b' has no boundary bonus → 16; no leading-gap penalty.
        XCTAssertEqual(score("b", "ab"), 16)
        // "b" vs "a b": after white → 16 + 32 = 48 (leading gap free).
        XCTAssertEqual(score("b", "a b"), 48)
        // "vsc" vs "Visual Studio Code": 48 + (−3 −5) + 32 + (−3 −5) + 32 = 96.
        XCTAssertEqual(score("vsc", "Visual Studio Code"), 96)
        // Trailing gap is free: same score with a suffix.
        XCTAssertEqual(score("vsc", "Visual Studio Code Insiders"), 96)
    }

    func testScoreMatchesReferenceOnHandPicked() {
        let cases: [(String, String)] = [
            ("vsc", "Visual Studio Code"), ("vsc", "vas Screaming"), ("gc", "Google Chrome"), ("gc", "logcat"),
            ("code", "Visual Studio Code"), ("code", "encoder"), ("tb", "fooTermBar"), ("tb", "footerbar"),
            ("chrome", "chrome"), ("chrome", "Google Chrome"), ("aaa", "aaaaaa"), ("aba", "abababa"),
            ("x", "xcode"), ("xc", "Xcode"), ("rp", "report2024.pdf"), ("2024", "report2024.pdf"),
            ("ng", "node-gyp_build"), ("wx", "微信 WeChat"),
        ]
        for (q, text) in cases {
            let t = TextAnalyzer.analyze(text)
            let got = Scorer.score(query: bytes(q), text: t.folded, bonus: t.bonus, scratch: scratch)?.score
            let ref = referenceScore(bytes(q), t.folded, t.bonus)
            XCTAssertEqual(got.map(Int.init), ref, "\(q) vs \(text)")
        }
    }

    func testRankingSanity() throws {
        // Word-initial matches beat mid-word consecutive runs.
        XCTAssertGreaterThan(try XCTUnwrap(score("gc", "Google Chrome")), try XCTUnwrap(score("gc", "logcat")))
        // A contiguous prefix ("gcc") out-scores the acronym at the raw text level (fzf behaviour); the
        // launcher's acronym preference comes from Ranking.initialsBonus (+60), tested in RankingTests/SearchEngineTests.
        XCTAssertGreaterThan(try XCTUnwrap(score("gc", "gcc")), try XCTUnwrap(score("gc", "Google Chrome")))
        // Whole-word match at a boundary beats the same run inside a word.
        XCTAssertGreaterThan(try XCTUnwrap(score("code", "Visual Studio Code")), try XCTUnwrap(score("code", "encoder")))
        // camelCase boundaries carry the camel bonus.
        XCTAssertGreaterThan(try XCTUnwrap(score("tb", "fooTermBar")), try XCTUnwrap(score("tb", "footerbar")))
        // Exact match scores at least as high as the same word inside a longer name. With the spec
        // constants these tie at 208 (48 for 'c' after white, then 5 × (16 + run-start bonus 16));
        // the ranking layer breaks the tie by tier / name length.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score("chrome", "chrome")), try XCTUnwrap(score("chrome", "Google Chrome")))
        XCTAssertEqual(score("chrome", "chrome"), 208)
        XCTAssertEqual(score("chrome", "Google Chrome"), 208)
        // A contiguous run at a word start is preferred over the same letters split across a boundary
        // ("cod" + "-e"): equal score, and the backtrace picks the contiguous alignment.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score("code", "codex_last_message.txt")), try XCTUnwrap(score("code", "codex-experimental")))
        XCTAssertEqual(positions("code", "codex-experimental"), [0, 1, 2, 3])
        // Acronym beats a scattered subsequence that does not start a word.
        XCTAssertGreaterThan(try XCTUnwrap(score("vsc", "Visual Studio Code")), try XCTUnwrap(score("vsc", "vascular")))
        XCTAssertGreaterThan(try XCTUnwrap(score("xc", "Xcode")), try XCTUnwrap(score("xc", "Excalibur")))
        // Prefix of a word beats the same letters spread out.
        XCTAssertGreaterThan(try XCTUnwrap(score("chr", "Google Chrome")), try XCTUnwrap(score("chr", "chapter")))
    }

    /// Documents a known property of the constants (DESIGN.md §6.3 + fzf run rule): on text score alone
    /// `vsc` gives "vas Screaming" 107 vs "Visual Studio Code" 96, because the "Sc" run at a word start
    /// carries the word bonus on both bytes. The ranking layer's `initialsBonus` (+60 when the term equals
    /// the item's initials, §6.5) decides it — acronym preference is a launcher concern, not the scorer's.
    func testVscVersusVasScreamingIsDecidedByInitialsBonus() throws {
        let vsc = Int(try XCTUnwrap(score("vsc", "Visual Studio Code")))
        let vas = Int(try XCTUnwrap(score("vsc", "vas Screaming")))
        XCTAssertEqual(vsc, 96)
        XCTAssertEqual(vas, 107)
        let initialsBonus = 60
        XCTAssertEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("Visual Studio Code").initials), bytes("vsc"))
        XCTAssertNotEqual(TextAnalyzer.unpackInitials(TextAnalyzer.analyze("vas Screaming").initials), bytes("vsc"))
        XCTAssertGreaterThan(vsc + initialsBonus, vas)
    }

    func testScoreGuards() {
        let t = TextAnalyzer.analyze("abc")
        // Empty query → score 0, firstMatch 0.
        XCTAssertEqual(Scorer.score(query: [], text: t.folded, bonus: t.bonus, scratch: scratch), ScoreResult(score: 0, firstMatch: 0))
        // m > n → nil.
        XCTAssertNil(Scorer.score(query: bytes("abcd"), text: t.folded, bonus: t.bonus, scratch: scratch))
        // Not a subsequence → nil.
        XCTAssertNil(Scorer.score(query: bytes("ca"), text: t.folded, bonus: t.bonus, scratch: scratch))
        // Empty text, non-empty query → nil; empty both → 0.
        XCTAssertNil(Scorer.score(query: bytes("a"), text: [], bonus: [], scratch: scratch))
        XCTAssertEqual(Scorer.score(query: [], text: [], bonus: [], scratch: scratch)?.score, 0)
        // firstMatch is the greedy start.
        let r = Scorer.score(query: bytes("c"), text: bytes("abcabc"), bonus: [UInt8](repeating: 0, count: 6), scratch: scratch)
        XCTAssertEqual(r?.firstMatch, 2)
        XCTAssertEqual(r?.score, 16)
    }

    func testScoreWorksOnSubSlicesOfAnArena() {
        let s = TextAnalyzer.analyze("xx Google Chrome yy")
        let text = s.folded[3..<16], bonus = s.bonus[3..<16]   // "google chrome"
        XCTAssertEqual(Array(text), bytes("google chrome"))
        let r = Scorer.score(query: bytes("gc")[...], text: text, bonus: bonus, scratch: scratch)
        XCTAssertEqual(r?.score, score("gc", "Google Chrome"))
        XCTAssertEqual(r?.firstMatch, 0)
    }

    func testScoreRandomAgainstReferenceAndBruteForce() {
        var rng = SplitMix(state: 0x5EED)
        let alphabet = Array("aAbB c-.a")   // repeated letters, case and boundaries
        let qAlphabet = bytes("abc -.")
        var scored = 0
        for _ in 0..<4000 {
            let n = Int.random(in: 1...12, using: &rng), m = Int.random(in: 1...4, using: &rng)
            let text = String((0..<n).map { _ in alphabet.randomElement(using: &rng)! })
            let t = TextAnalyzer.analyze(text)
            let q = (0..<m).map { _ in qAlphabet.randomElement(using: &rng)! }
            let got = Scorer.score(query: q, text: t.folded, bonus: t.bonus, scratch: scratch)
            let ref = referenceScore(q, t.folded, t.bonus)
            XCTAssertEqual(got.map { Int($0.score) }, ref, "q=\(String(decoding: q, as: UTF8.self)) text=\(text)")
            guard let r = got else { continue }
            scored += 1
            // The DP value is the score of a real alignment, so it never exceeds the exhaustive optimum
            // (fzf's V2 heuristic tracks only the run length of the chosen path, so it may fall below it).
            let brute = bruteForceBest(q, t.folded, t.bonus)!
            XCTAssertLessThanOrEqual(Int(r.score), brute, "q=\(String(decoding: q, as: UTF8.self)) text=\(text)")
            // matchPositions must re-score to exactly the DP value.
            let pos = Scorer.matchPositions(query: q[...], text: t.folded[...], bonus: t.bonus[...])
            XCTAssertEqual(pos.count, m)
            XCTAssertEqual(alignmentScore(pos, bonus: t.bonus), Int(r.score), "q=\(String(decoding: q, as: UTF8.self)) text=\(text) pos=\(pos)")
            XCTAssertEqual(Scorer.subsequenceStart(query: q[...], text: t.folded[...]).map { Int16($0) }, r.firstMatch)
        }
        XCTAssertGreaterThan(scored, 500, "random corpus should produce plenty of matches")
    }

    func testLongQueryIsTruncatedForScoringButFullyChecked() {
        let text = String(repeating: "a", count: 100)
        let t = TextAnalyzer.analyze(text)
        let q64 = [UInt8](repeating: 0x61, count: 64)
        let q80 = [UInt8](repeating: 0x61, count: 80)
        let s64 = Scorer.score(query: q64, text: t.folded, bonus: t.bonus, scratch: scratch)
        let s80 = Scorer.score(query: q80, text: t.folded, bonus: t.bonus, scratch: scratch)
        XCTAssertNotNil(s64); XCTAssertEqual(s64, s80)   // only the first 64 bytes are scored
        // 48 + 63·(16 + run-start bonus 16) = 2064
        XCTAssertEqual(s64?.score, 48 + 63 * 32)
        // But the subsequence check still uses all bytes: 101 a's cannot match 100 a's.
        XCTAssertNil(Scorer.score(query: [UInt8](repeating: 0x61, count: 101), text: t.folded, bonus: t.bonus, scratch: scratch))
        // And a long query whose tail is absent is rejected.
        var qTail = q64; qTail.append(0x7A)
        XCTAssertNil(Scorer.score(query: qTail, text: t.folded, bonus: t.bonus, scratch: scratch))
        XCTAssertEqual(Scorer.matchPositions(query: q80[...], text: t.folded[...], bonus: t.bonus[...]).count, 64)
    }

    func testVeryLongTextIsSafe() {
        // n = 65535 with the match at both ends: the gap chain is floored, no Int16 overflow, still a match.
        let n = 65535
        var text = [UInt8](repeating: 0x78, count: n)   // 'x'
        text[0] = 0x61; text[n - 1] = 0x62                // "a…b"
        let bonus = [UInt8](repeating: 0, count: n)
        let small = ScorerScratch(capacity: 4)           // forces ensure() to grow
        let r = Scorer.score(query: bytes("ab"), text: text, bonus: bonus, scratch: small)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.firstMatch, 0)
        XCTAssertGreaterThan(r!.score, ScoreConstants.neg)
        XCTAssertLessThan(r!.score, 0)
        XCTAssertGreaterThanOrEqual(small.h.count, n)
        // firstMatch saturates beyond Int16.max.
        text[0] = 0x78; text[40000] = 0x61
        let r2 = Scorer.score(query: bytes("ab"), text: text, bonus: bonus, scratch: small)
        XCTAssertEqual(r2?.firstMatch, Int16.max)
        // A single-byte query deep in a long text keeps its proper score (no gaps involved).
        let r3 = Scorer.score(query: bytes("b"), text: text, bonus: bonus, scratch: small)
        XCTAssertEqual(r3?.score, 16)
    }

    func testScratchEnsureGrows() {
        let s = ScorerScratch(capacity: 8)
        XCTAssertEqual(s.h.count, 8); XCTAssertEqual(s.c.count, 8)
        s.ensure(4); XCTAssertEqual(s.h.count, 8)
        s.ensure(300); XCTAssertEqual(s.h.count, 300); XCTAssertEqual(s.c.count, 300)
    }

    func testScratchAndScoreClampExtremePublicCapacities() {
        let negative = ScorerScratch(capacity: Int.min)
        XCTAssertEqual(negative.h.count, 0)
        XCTAssertEqual(negative.c.count, 0)
        negative.ensure(Int.max)
        XCTAssertEqual(negative.h.count, Scorer.maxTextBytes)
        XCTAssertEqual(negative.c.count, Scorer.maxTextBytes)

        let oversizedText = [UInt8](repeating: 0x61, count: Scorer.maxTextBytes + 1)
        XCTAssertNil(Scorer.score(query: [0x61], text: oversizedText,
                                  bonus: oversizedText, scratch: negative))
        XCTAssertEqual(Scorer.matchPositions(query: [0x61][...], text: oversizedText[...],
                                             bonus: oversizedText[...]), [])
    }

    func testScoreBest() {
        let strings = [TextAnalyzer.analyze("WeChat"), TextAnalyzer.analyze("微信"), TextAnalyzer.analyze("weixin"), TextAnalyzer.analyze("wx")]
        // "wx" matches the initials alias exactly (48 + 32 = 80) and "weixin" loosely; best is the alias.
        let wx = Scorer.scoreBest(query: bytes("wx")[...], against: strings, scratch: scratch)
        XCTAssertEqual(wx?.score, 80)
        // "wechat" only matches the display name.
        XCTAssertEqual(Scorer.scoreBest(query: bytes("wechat")[...], against: strings, scratch: scratch)?.score, score("wechat", "WeChat"))
        // Nothing matches → nil; empty list → nil; empty query → 0 (first string wins).
        XCTAssertNil(Scorer.scoreBest(query: bytes("zzz")[...], against: strings, scratch: scratch))
        XCTAssertNil(Scorer.scoreBest(query: bytes("w")[...], against: [], scratch: scratch))
        XCTAssertEqual(Scorer.scoreBest(query: ArraySlice<UInt8>(), against: strings, scratch: scratch), ScoreResult(score: 0, firstMatch: 0))
        // Ties prefer the earlier first-match column.
        let tie = [TextAnalyzer.analyze("xx ab"), TextAnalyzer.analyze("ab")]
        XCTAssertEqual(Scorer.scoreBest(query: bytes("ab")[...], against: tie, scratch: scratch), ScoreResult(score: 80, firstMatch: 0))
        // Mask prefilter rejects strings lacking a query letter without changing results.
        XCTAssertEqual(Scorer.scoreBest(query: bytes("wei")[...], against: strings, scratch: scratch)?.score, score("wei", "weixin"))
    }

    // MARK: (3) matchPositions

    func testMatchPositionsBasics() {
        XCTAssertEqual(positions("vsc", "visual studio code"), [0, 7, 14])
        XCTAssertEqual(positions("vsc", "Visual Studio Code"), [0, 7, 14])
        XCTAssertEqual(positions("code", "Visual Studio Code"), [14, 15, 16, 17])
        XCTAssertEqual(positions("gc", "Google Chrome"), [0, 7])
        XCTAssertEqual(positions("tb", "fooTermBar"), [3, 7])
        XCTAssertEqual(positions("chrome", "Google Chrome"), [7, 8, 9, 10, 11, 12])
        XCTAssertEqual(positions("", "abc"), [])
        XCTAssertEqual(positions("zz", "abc"), [])
        XCTAssertEqual(positions("abcd", "abc"), [])
        // Prefers the boundary-bonus occurrence over an earlier plain one.
        XCTAssertEqual(positions("b", "ab b"), [3])
        // Leftmost among equal maxima.
        XCTAssertEqual(positions("b", "b b"), [0])
    }

    func testMatchPositionsAreIncreasingAndMatchQuery() {
        var rng = SplitMix(state: 42)
        let alphabet = Array("abcABC -_.")
        for _ in 0..<500 {
            let text = String((0..<Int.random(in: 1...20, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let t = TextAnalyzer.analyze(text)
            let q = (0..<Int.random(in: 1...5, using: &rng)).map { _ in bytes("abc")[Int.random(in: 0..<3, using: &rng)] }
            let pos = Scorer.matchPositions(query: q[...], text: t.folded[...], bonus: t.bonus[...])
            if Scorer.subsequenceStart(query: q[...], text: t.folded[...]) == nil { XCTAssertEqual(pos, []); continue }
            XCTAssertEqual(pos.count, q.count)
            for (k, p) in pos.enumerated() {
                XCTAssertEqual(t.folded[p], q[k])
                if k > 0 { XCTAssertGreaterThan(p, pos[k - 1]) }
            }
        }
    }

    func testMatchPositionsOnSlices() {
        let s = TextAnalyzer.analyze("xx Google Chrome yy")
        XCTAssertEqual(Scorer.matchPositions(query: bytes("gc")[...], text: s.folded[3..<16], bonus: s.bonus[3..<16]), [0, 7])
        // Mismatched bonus length is rejected rather than trapping.
        XCTAssertEqual(Scorer.matchPositions(query: bytes("gc")[...], text: s.folded[3..<16], bonus: s.bonus[3..<10]), [])
    }

    // MARK: (4) substringStart

    func testSubstringStart() {
        let t = bytes("visual studio code")[...]
        XCTAssertEqual(Scorer.substringStart(query: bytes("")[...], text: t), 0)
        XCTAssertEqual(Scorer.substringStart(query: bytes("visual")[...], text: t), 0)
        XCTAssertEqual(Scorer.substringStart(query: bytes("studio")[...], text: t), 7)
        XCTAssertEqual(Scorer.substringStart(query: bytes("code")[...], text: t), 14)
        XCTAssertEqual(Scorer.substringStart(query: bytes("e")[...], text: t), 17)
        XCTAssertEqual(Scorer.substringStart(query: bytes("visual studio code")[...], text: t), 0)
        XCTAssertNil(Scorer.substringStart(query: bytes("vsc")[...], text: t))       // subsequence but not substring
        XCTAssertNil(Scorer.substringStart(query: bytes("codes")[...], text: t))
        XCTAssertNil(Scorer.substringStart(query: bytes("visual studio code!")[...], text: t))
        XCTAssertNil(Scorer.substringStart(query: bytes("a")[...], text: bytes("")[...]))
        XCTAssertEqual(Scorer.substringStart(query: bytes("")[...], text: bytes("")[...]), 0)
        // Slices: relative to text.startIndex.
        let arena = bytes("..abcabc..")
        XCTAssertEqual(Scorer.substringStart(query: bytes("cab")[...], text: arena[2..<8]), 2)
        XCTAssertEqual(Scorer.substringStart(query: arena[5..<8], text: arena[2..<8]), 0)
        XCTAssertNil(Scorer.substringStart(query: bytes(".")[...], text: arena[2..<8]))
        // CJK bytes (contiguous multi-byte match).
        let cjk = TextAnalyzer.analyze("微信 WeChat")
        XCTAssertEqual(Scorer.substringStart(query: TextAnalyzer.analyze("信").folded[...], text: cjk.folded[...]), 3)
        XCTAssertNil(Scorer.substringStart(query: TextAnalyzer.analyze("微信信").folded[...], text: cjk.folded[...]))
    }

    // MARK: (5) Performance

    /// Builds ~400k synthetic names (dictionary word pairs, kebab files, camelCase) into a real
    /// `IndexStore` via `IndexBuilder`, then times mask prefilter + greedy + DP for short queries.
    /// The assertion is generous so debug CI passes; the printed numbers are what matter
    /// (run with `swift test -c release --filter ScorerTests/testPerf`).
    func testPerf() throws {
        let names = ScorerTests.syntheticNames(count: 400_000)
        let builder = IndexBuilder()
        builder.reserve(items: names.count, dirs: 1)
        let root = builder.addRoot("/synthetic")
        let tBuild0 = DispatchTime.now().uptimeNanoseconds
        for name in names {
            builder.addItem(dir: root, name: name, analyzed: ScorerTests.fastAnalyze(name), kind: .other, flags: [], mtime: nil, depth: 1, ext: nil)
        }
        let store = builder.build(generation: 1)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - tBuild0) / 1e6
        XCTAssertEqual(store.count, names.count)
        print("[perf] analyzed+built \(store.count) items in \(String(format: "%.1f", buildMs)) ms; arena \(store.foldedArena.count) B")

        for query in ["vsc", "gc", "x", "chrome", "net"] {
            let q = TextAnalyzer.analyze(query)
            var bestMs = Double.infinity
            var matched = 0, maskPassed = 0, top: Int16 = ScoreConstants.neg
            for _ in 0..<5 {
                matched = 0; maskPassed = 0; top = ScoreConstants.neg
                let t0 = DispatchTime.now().uptimeNanoseconds
                for i in 0..<store.count {
                    if (store.mask[i] & q.mask) != q.mask { continue }
                    maskPassed += 1
                    // score() runs the greedy subsequence check first (fast path) and the DP only for survivors.
                    guard let r = Scorer.score(query: q.folded[...], text: store.foldedName(of: i), bonus: store.bonus(of: i), scratch: scratch) else { continue }
                    matched += 1
                    if r.score > top { top = r.score }
                }
                bestMs = min(bestMs, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            print("[perf] query '\(query)': \(String(format: "%.2f", bestMs)) ms (best of 5), mask passed \(maskPassed), matched \(matched), top score \(top)")
            XCTAssertLessThan(bestMs, 2000, "scoring 400k names must stay well under 2 s even in debug")
            XCTAssertGreaterThan(matched, 0)
        }
    }

    // MARK: Synthetic corpus helpers

    /// Deterministic synthetic corpus: "Word Word", "word-word.ext", "wordWord", "word_word2024.ext", "word".
    static func syntheticNames(count: Int) -> [String] {
        var words = loadDictionaryWords()
        if words.count < 1000 { words = (0..<5000).map { "w\($0)abc" } }
        var rng = SplitMix(state: 0xC0FFEE)
        let exts = ["pdf", "txt", "swift", "png", "md", "json", "mov", "zip"]
        var out: [String] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            let a = words[Int.random(in: 0..<words.count, using: &rng)]
            let b = words[Int.random(in: 0..<words.count, using: &rng)]
            switch k % 5 {
            case 0: out.append("\(a.capitalized) \(b.capitalized)")
            case 1: out.append("\(a)-\(b).\(exts[k / 5 % exts.count])")
            case 2: out.append("\(a)\(b.capitalized)")
            case 3: out.append("\(a)_\(b)\(2000 + k % 30).\(exts[k / 7 % exts.count])")
            default: out.append(a)
            }
        }
        return out
    }

    static func loadDictionaryWords() -> [String] {
        guard let data = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return data.split(separator: "\n").filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }.map(String.init)
    }

    /// ASCII-only fast path equivalent to `TextAnalyzer.analyze` (which folds per character through
    /// Foundation and is too slow for 400k names inside a unit test). `testFastAnalyzeMatchesTextAnalyzer`
    /// guards the equivalence; non-ASCII input falls back to the real analyzer.
    static func fastAnalyze(_ s: String) -> SearchString {
        var folded: [UInt8] = [], bonus: [UInt8] = []
        var mask: UInt64 = 0, initials: UInt64 = 0, nInitials = 0
        var prev: CharClass = .white
        for b in s.utf8 {
            guard b < 128 else { return TextAnalyzer.analyze(s) }
            let cur = CharClass.of(Unicode.Scalar(b))
            let lb = (b >= 0x41 && b <= 0x5A) ? b + 32 : b
            folded.append(lb)
            bonus.append(BonusConstants.bonus(prev: prev, cur: cur))
            mask |= Mask.bit(forFoldedByte: lb)
            if nInitials < TextAnalyzer.maxInitials && TextAnalyzer.isTokenStart(prev: prev, cur: cur)
                && ((lb >= 0x61 && lb <= 0x7A) || (lb >= 0x30 && lb <= 0x39)) {
                initials |= UInt64(lb) << UInt64(8 * nInitials); nInitials += 1
            }
            prev = cur
        }
        return SearchString(folded: folded, bonus: bonus, mask: mask, initials: initials)
    }

    func testFastAnalyzeMatchesTextAnalyzer() {
        for name in ScorerTests.syntheticNames(count: 2000) + ["Visual Studio Code", "report2024.pdf", "my-file_name (1).txt", "iTermApp", "微信"] {
            XCTAssertEqual(ScorerTests.fastAnalyze(name), TextAnalyzer.analyze(name), name)
        }
    }
}
