import Foundation

/// Scorer constants (fzf-V2 style Smith-Waterman with affine gaps). See DESIGN.md §6.3.
public enum ScoreConstants {
    public static let match: Int16 = 16
    public static let gapStart: Int16 = -3
    public static let gapExt: Int16 = -1
    /// "No match" sentinel — any real score is > neg.
    public static let neg: Int16 = Int16.min / 2
    /// Per-character bonus when the query has uppercase and the original char matches case (applied in backtrace only).
    public static let caseMatch: Int16 = 4
}

/// Result of scoring one query term against one text.
public struct ScoreResult: Equatable, Sendable {
    /// DP score (higher is better). Always > ScoreConstants.neg when returned.
    public var score: Int16
    /// Byte offset (relative to the text start) of the first possible match of the first query byte
    /// (from the greedy subsequence pass). Used as a tie-breaker.
    public var firstMatch: Int16
    public init(score: Int16, firstMatch: Int16) { self.score = score; self.firstMatch = firstMatch }
}

/// Reusable DP scratch rows to avoid per-call allocation. One per worker thread.
public final class ScorerScratch {
    public var h: [Int16]
    public var c: [Int16]
    /// Greedy match start column per query row (`Scorer.maxQueryBytes` entries). Internal: lets the
    /// DP skip the unreachable prefix of every row without allocating per call. Raw storage so the
    /// hot path pays no array accessor / exclusivity cost; owned by this object (freed in deinit).
    let starts: UnsafeMutablePointer<Int32>
    public init(capacity: Int = 512) {
        h = [Int16](repeating: 0, count: capacity)
        c = [Int16](repeating: 0, count: capacity)
        starts = UnsafeMutablePointer<Int32>.allocate(capacity: Scorer.maxQueryBytes)
        starts.initialize(repeating: 0, count: Scorer.maxQueryBytes)
    }
    deinit { starts.deallocate() }
    /// Grow if needed (both rows are kept the same length).
    @inlinable public func ensure(_ n: Int) {
        if h.count < n || c.count < n {
            let cap = max(n, h.count, c.count)
            h = [Int16](repeating: 0, count: cap); c = [Int16](repeating: 0, count: cap)
        }
    }
}

/// Fuzzy scorer. All inputs are FOLDED UTF-8 bytes (see `TextAnalyzer`); `bonus` parallels `text`.
///
/// Owner: match agent. Performance target: ≥ 100k candidate scorings per ms-of-budget… concretely,
/// scoring 400k names for a 3-char query in < 10 ms single-threaded on Apple Silicon
/// (mask + greedy pre-filters reject most items before the DP runs).
///
/// Algorithm (DESIGN.md §6.3): Smith-Waterman with affine gaps over two `Int16` rows
/// (`H` = best score ending at column j, `C` = length of the consecutive match run ending there).
/// A match scores `ScoreConstants.match` + the per-byte boundary bonus (`BonusConstants`), the first
/// query byte's bonus is multiplied by `BonusConstants.firstMult`, and a match that continues a run
/// gets max(own bonus, `BonusConstants.consecutive`, bonus of the run's first byte) — fzf's rule that lets a
/// contiguous match at a word start carry the word bonus across the whole run. Gaps cost `gapStart` then
/// `gapExt` per extra byte.
/// Leading and trailing gaps are free (local alignment). The score is the maximum over the last row.
///
/// Implementation notes:
/// - The greedy subsequence scan runs first (fast rejection); it also yields the first column each
///   DP row can reach, so rows start there and stop after the last occurrence of the last query byte.
/// - Only the first `maxQueryBytes` (64) bytes of the query are scored; the subsequence check still
///   uses the whole query (so `nil` ⇔ not a subsequence).
/// - Gap chains are floored at `ScoreConstants.neg + 1` so texts up to 65 535 bytes can never
///   overflow `Int16`; such hopeless scores (< −16 000) keep their relative ordering irrelevant.
/// - `ScoreResult.firstMatch` saturates at `Int16.max` for texts longer than 32 767 bytes.
public enum Scorer {
    /// Maximum number of query bytes the DP scores (longer queries are truncated for scoring; the
    /// subsequence check still uses all bytes). 64 bytes × 255-byte names keeps the DP bounded.
    public static let maxQueryBytes = 64

    /// Lowest value a reachable cell can hold (see the floor note in the type doc).
    static let floorScore: Int16 = ScoreConstants.neg + 1

    // MARK: Subsequence

    /// Returns the index (relative to `text.startIndex`) of the first byte of `query` found via a
    /// greedy left-to-right subsequence scan, or nil if `query` is not a subsequence of `text`.
    /// Empty query → 0.
    public static func subsequenceStart(query: ArraySlice<UInt8>, text: ArraySlice<UInt8>) -> Int? {
        query.withUnsafeBufferPointer { q in
            text.withUnsafeBufferPointer { t in subsequenceStart(query: q, text: t) }
        }
    }

    /// Pointer variant of `subsequenceStart(query:text:)` for callers that have pinned the arena.
    public static func subsequenceStart(query q: UnsafeBufferPointer<UInt8>, text t: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = q.count, n = t.count
        if m == 0 { return 0 }
        if m > n { return nil }
        guard let qp = q.baseAddress, let tp = t.baseAddress else { return nil }
        let first = findByte(qp[0], in: tp, from: 0, count: n)
        guard first >= 0 else { return nil }
        var j = first + 1
        var i = 1
        while i < m {
            // Remaining query bytes must fit in the remaining text.
            if m - i > n - j { return nil }
            let pos = findByte(qp[i], in: tp, from: j, count: n)
            if pos < 0 { return nil }
            j = pos + 1
            i += 1
        }
        return first
    }

    /// Index of the first `byte` in `tp[from..<count]`, or -1. A plain byte loop beats `memchr` here:
    /// names average ~20 bytes, so the libc call overhead dominates a vectorised search.
    @inline(__always)
    static func findByte(_ byte: UInt8, in tp: UnsafePointer<UInt8>, from: Int, count: Int) -> Int {
        var j = from
        while j < count {
            if tp[j] == byte { return j }
            j &+= 1
        }
        return -1
    }

    // MARK: Score

    /// Full fzf-V2 DP score of `query` against `text`. Returns nil if not a subsequence.
    /// `scratch` must outlive the call and not be shared across threads.
    public static func score(query: ArraySlice<UInt8>, text: ArraySlice<UInt8>, bonus: ArraySlice<UInt8>, scratch: ScorerScratch) -> ScoreResult? {
        query.withUnsafeBufferPointer { q in
            text.withUnsafeBufferPointer { t in
                bonus.withUnsafeBufferPointer { b in score(query: q, text: t, bonus: b, scratch: scratch) }
            }
        }
    }

    /// Convenience for arrays.
    @inlinable public static func score(query: [UInt8], text: [UInt8], bonus: [UInt8], scratch: ScorerScratch) -> ScoreResult? {
        score(query: query[...], text: text[...], bonus: bonus[...], scratch: scratch)
    }

    /// Pointer variant of `score(query:text:bonus:scratch:)` for callers that have pinned the arenas
    /// (no slice bookkeeping per candidate). `bonus.count` must equal `text.count`; a mismatch is a
    /// programming error and yields nil (asserts in debug).
    public static func score(query q: UnsafeBufferPointer<UInt8>, text t: UnsafeBufferPointer<UInt8>, bonus b: UnsafeBufferPointer<UInt8>, scratch: ScorerScratch) -> ScoreResult? {
        let n = t.count
        let mFull = q.count
        if mFull == 0 { return ScoreResult(score: 0, firstMatch: 0) }
        if mFull > n { return nil }
        guard b.count == n else { assertionFailure("Scorer.score: bonus must parallel text"); return nil }
        guard let qp = q.baseAddress, let tp = t.baseAddress, let bp = b.baseAddress else { return nil }
        let m = min(mFull, maxQueryBytes)
        // Greedy pass: rejects non-subsequences and records each DP row's first reachable column.
        guard let first = greedyStarts(qp: qp, mFull: mFull, m: m, tp: tp, n: n, scratch: scratch) else { return nil }
        scratch.ensure(n)
        let starts = UnsafePointer(scratch.starts)
        let end = lastOccurrence(of: qp[m - 1], in: tp, n: n, notBefore: Int(starts[m - 1])) + 1
        let best = scratch.h.withUnsafeMutableBufferPointer { hb -> Int16 in
            scratch.c.withUnsafeMutableBufferPointer { cb -> Int16 in
                dp(qp: qp, m: m, tp: tp, bp: bp, end: end, starts: starts, h: hb.baseAddress!, c: cb.baseAddress!)
            }
        }
        // Unreachable by construction (greedy succeeded ⇒ the greedy alignment is in the DP), kept as a guard.
        guard best > ScoreConstants.neg else { assertionFailure("Scorer.score: DP lost the greedy alignment"); return nil }
        return ScoreResult(score: best, firstMatch: Int16(clamping: first))
    }

    /// Greedy subsequence scan that records `scratch.starts[i]` (column of the i-th query byte) for
    /// `i < m` and checks all `mFull` bytes. Returns the first match column or nil.
    @inline(__always)
    private static func greedyStarts(qp: UnsafePointer<UInt8>, mFull: Int, m: Int, tp: UnsafePointer<UInt8>, n: Int, scratch: ScorerScratch) -> Int? {
        let sb = scratch.starts
        var j = 0
        var i = 0
        var first = 0
        while i < mFull {
            if mFull - i > n - j { return nil }
            let pos = findByte(qp[i], in: tp, from: j, count: n)
            if pos < 0 { return nil }
            if i == 0 { first = pos }
            if i < m { sb[i] = Int32(truncatingIfNeeded: pos) }
            j = pos + 1
            i += 1
        }
        return first
    }

    /// Last column in `[notBefore, n)` holding `byte` (the caller guarantees at least one).
    @inline(__always)
    private static func lastOccurrence(of byte: UInt8, in tp: UnsafePointer<UInt8>, n: Int, notBefore: Int) -> Int {
        var j = n - 1
        while j > notBefore && tp[j] != byte { j -= 1 }
        return j
    }

    /// The two-row DP. Row i is evaluated for columns `starts[i] ..< end`; every other cell is
    /// unreachable (NEG) and never read. Returns the maximum of the last row.
    @inline(__always)
    private static func dp(qp: UnsafePointer<UInt8>, m: Int, tp: UnsafePointer<UInt8>, bp: UnsafePointer<UInt8>, end: Int,
                           starts: UnsafePointer<Int32>, h: UnsafeMutablePointer<Int16>, c: UnsafeMutablePointer<Int16>) -> Int16 {
        // Wrapping arithmetic (&+, &*) is safe here: reachable cells are floored at `floorScore` and the
        // largest possible score is maxQueryBytes × (match + 2·maxBonus) ≈ 3 072 ≪ Int16.max.
        let neg = ScoreConstants.neg
        let match = ScoreConstants.match, gapStart = ScoreConstants.gapStart, gapExt = ScoreConstants.gapExt
        let consec = Int16(BonusConstants.consecutive), firstMult = BonusConstants.firstMult
        let boundary = Int16(BonusConstants.boundary)
        // Row 0: a match here starts a fresh alignment (leading gap is free).
        let q0 = qp[0]
        var prevH = neg
        var inGap = false
        var j = Int(starts[0])
        while j < end {
            let s1: Int16 = tp[j] == q0 ? match &+ Int16(truncatingIfNeeded: bp[j]) &* firstMult : neg
            let s2: Int16 = prevH > neg ? max(floorScore, prevH &+ (inGap ? gapExt : gapStart)) : neg
            if s1 >= s2 { h[j] = s1; c[j] = 1; inGap = false } else { h[j] = s2; c[j] = 0; inGap = true }
            prevH = h[j]
            j &+= 1
        }
        // Rows 1..m-1: diag = cell (i-1, j-1), read before it is overwritten in place.
        var i = 1
        while i < m {
            let qi = qp[i]
            let start = Int(starts[i])          // ≥ starts[i-1] + 1 ≥ 1
            var diagH = h[start - 1], diagC = c[start - 1]
            prevH = neg; inGap = false
            j = start
            while j < end {
                let upH = h[j], upC = c[j]
                var s1 = neg
                var c1: Int16 = 0
                if tp[j] == qi && diagH > neg {
                    var bb = Int16(truncatingIfNeeded: bp[j])
                    c1 = diagC &+ 1
                    if diagC > 0 {
                        // fzf V2 rule: a consecutive run carries the bonus of its FIRST byte (so "code" at a word
                        // start scores the word bonus on every byte); a byte with a boundary bonus larger than the
                        // run's first bonus starts a new run instead.
                        let fb = Int16(truncatingIfNeeded: bp[j &- Int(diagC)])
                        if bb >= boundary && bb > fb { c1 = 1 } else { bb = max(bb, max(consec, fb)) }
                    }
                    s1 = diagH &+ match &+ bb
                }
                let s2: Int16 = prevH > neg ? max(floorScore, prevH &+ (inGap ? gapExt : gapStart)) : neg
                if s1 >= s2 { h[j] = s1; c[j] = c1; inGap = false } else { h[j] = s2; c[j] = 0; inGap = true }
                diagH = upH; diagC = upC; prevH = h[j]
                j &+= 1
            }
            i &+= 1
        }
        var best = neg
        j = Int(starts[m - 1])
        while j < end { if h[j] > best { best = h[j] }; j &+= 1 }
        return best
    }

    /// Best score of `query` over several searchable strings (an app's display name + aliases).
    /// Strings failing the character-mask prefilter are skipped. Ties prefer the earlier first-match
    /// column, then the earlier string. Returns nil if no string matches.
    public static func scoreBest(query: ArraySlice<UInt8>, against strings: [SearchString], scratch: ScorerScratch) -> ScoreResult? {
        let qmask = Mask.of(query)
        var best: ScoreResult?
        for s in strings {
            guard (s.mask & qmask) == qmask else { continue }
            guard let r = score(query: query, text: s.folded[...], bonus: s.bonus[...], scratch: scratch) else { continue }
            if let b = best, (r.score < b.score || (r.score == b.score && r.firstMatch >= b.firstMatch)) { continue }
            best = r
        }
        return best
    }

    // MARK: Match positions (backtrace)

    /// Byte positions (relative to `text.startIndex`) of the optimal alignment, for highlighting.
    /// Only called for the final top rows. Returns [] if no match. If `originalText` (un-folded, same
    /// length only when ASCII) is provided together with `queryHasUppercase`, the backtrace prefers
    /// case-matching positions (+caseMatch) — optional refinement.
    ///
    /// Runs the same recurrence as `score(query:text:bonus:scratch:)` over the full text, keeping a
    /// direction byte per cell, then walks back from the leftmost maximum of the last row. The
    /// returned alignment's score equals `score()`; with queries longer than `maxQueryBytes` only the
    /// scored prefix is highlighted. Allocates O(m·n) bytes — fine for ≤ 50 rows.
    /// (The case-match refinement is not implemented: the signature carries no original text.)
    public static func matchPositions(query: ArraySlice<UInt8>, text: ArraySlice<UInt8>, bonus: ArraySlice<UInt8>) -> [Int] {
        let n = text.count
        let mFull = query.count
        if mFull == 0 || mFull > n || bonus.count != n { return [] }
        guard subsequenceStart(query: query, text: text) != nil else { return [] }
        let m = min(mFull, maxQueryBytes)
        let q = Array(query.prefix(m)), t = Array(text), b = Array(bonus)
        var dir = [UInt8](repeating: 0, count: m * n)   // 1 = came from a match (diagonal), 0 = gap (left)
        var h = [Int16](repeating: ScoreConstants.neg, count: n)
        var c = [Int16](repeating: 0, count: n)
        fillRow0(q: q, t: t, b: b, h: &h, c: &c, dir: &dir)
        if m > 1 { for i in 1..<m { fillRow(i, q: q, t: t, b: b, h: &h, c: &c, dir: &dir) } }
        return backtrace(m: m, n: n, h: h, dir: dir)
    }

    /// Row 0 of the full DP (first-match bonus doubled, fresh starts).
    private static func fillRow0(q: [UInt8], t: [UInt8], b: [UInt8], h: inout [Int16], c: inout [Int16], dir: inout [UInt8]) {
        let neg = ScoreConstants.neg
        var prevH = neg
        var inGap = false
        for j in 0..<t.count {
            let s1: Int16 = t[j] == q[0] ? ScoreConstants.match + Int16(b[j]) * BonusConstants.firstMult : neg
            let s2: Int16 = prevH > neg ? max(floorScore, prevH + (inGap ? ScoreConstants.gapExt : ScoreConstants.gapStart)) : neg
            if s1 >= s2 { h[j] = s1; c[j] = 1; dir[j] = 1; inGap = false } else { h[j] = s2; c[j] = 0; dir[j] = 0; inGap = true }
            prevH = h[j]
        }
    }

    /// Row `i ≥ 1` of the full DP, updating `h`/`c` in place and recording directions.
    private static func fillRow(_ i: Int, q: [UInt8], t: [UInt8], b: [UInt8], h: inout [Int16], c: inout [Int16], dir: inout [UInt8]) {
        let neg = ScoreConstants.neg
        let n = t.count
        let consec = Int16(BonusConstants.consecutive)
        let boundary = Int16(BonusConstants.boundary)
        var diagH = neg, diagC: Int16 = 0, prevH = neg
        var inGap = false
        for j in 0..<n {
            let upH = h[j], upC = c[j]
            var s1 = neg
            var c1: Int16 = 0
            if t[j] == q[i] && diagH > neg {
                var bb = Int16(b[j])
                c1 = diagC + 1
                if diagC > 0 {
                    let fb = Int16(b[j - Int(diagC)])
                    if bb >= boundary && bb > fb { c1 = 1 } else { bb = max(bb, max(consec, fb)) }
                }
                s1 = diagH + ScoreConstants.match + bb
            }
            let s2: Int16 = prevH > neg ? max(floorScore, prevH + (inGap ? ScoreConstants.gapExt : ScoreConstants.gapStart)) : neg
            let cell = i * n + j
            if s1 >= s2 { h[j] = s1; c[j] = c1; dir[cell] = 1; inGap = false } else { h[j] = s2; c[j] = 0; dir[cell] = 0; inGap = true }
            diagH = upH; diagC = upC; prevH = h[j]
        }
    }

    /// Walk the direction matrix back from the leftmost maximum of the last row.
    private static func backtrace(m: Int, n: Int, h: [Int16], dir: [UInt8]) -> [Int] {
        var bestJ = -1
        var best = ScoreConstants.neg
        for j in 0..<n where h[j] > best { best = h[j]; bestJ = j }
        guard bestJ >= 0 else { return [] }
        var out: [Int] = []
        out.reserveCapacity(m)
        var i = m - 1, j = bestJ
        while i >= 0 && j >= 0 {
            if dir[i * n + j] == 1 { out.append(j); i -= 1 }
            j -= 1
        }
        guard i < 0 else { assertionFailure("Scorer.matchPositions: broken backtrace"); return [] }
        return out.reversed()
    }

    // MARK: Substring

    /// True if `query` occurs as a contiguous substring of `text` (used for "complete term" semantics
    /// after a trailing space and for CJK substring matching). Returns the start offset or nil.
    public static func substringStart(query: ArraySlice<UInt8>, text: ArraySlice<UInt8>) -> Int? {
        let m = query.count, n = text.count
        if m == 0 { return 0 }
        if m > n { return nil }
        return query.withUnsafeBufferPointer { q -> Int? in
            text.withUnsafeBufferPointer { t -> Int? in
                guard let qp = q.baseAddress, let tp = t.baseAddress else { return nil }
                guard let hit = memmem(tp, n, qp, m) else { return nil }
                return UnsafeRawPointer(hit).assumingMemoryBound(to: UInt8.self) - tp
            }
        }
    }
}
