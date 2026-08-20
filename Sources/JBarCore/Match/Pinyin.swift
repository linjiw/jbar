import Foundation

/// One pinyin reading of a name. `full` = syllables concatenated ("weixin"), `initials` = first
/// letter of each syllable ("wx"). Non-CJK runs are kept verbatim (lowercased) in `full` and their
/// first letter contributes to `initials`.
public struct PinyinVariant: Hashable, Sendable {
    public var full: String
    public var initials: String
    public var spaced: String   // "wei xin" — useful as a third alias so prefix bonuses work per syllable
    public init(full: String, initials: String, spaced: String) { self.full = full; self.initials = initials; self.spaced = spaced }
}

/// Pinyin transliteration for Chinese app/file names so latin queries (`weixin`, `wx`) match `微信`.
///
/// Owner: pinyin agent. Uses Foundation's `StringTransform.mandarinToLatin` + `.stripDiacritics`
/// (verified on this Mac: "微信 网易云音乐" → "wei xin wang yi yun yin le"), with an override
/// table for common heteronyms (音乐 → yinyue, 银行 → yinhang, …) and multi-reading expansion for a
/// small set of characters (乐 行 重 长 朝 便 觉 还 都 发 和 …), capped at 4 variants.
///
/// Pipeline (`variants(of:)`):
/// 1. Split the name into CJK runs and non-CJK runs. Non-CJK runs are split on whitespace into
///    words that are kept verbatim (lowercased): `WeChat微信` → `wechat` + `wei` `xin`.
/// 2. Inside each CJK run, scan for override words (`音乐` → `yin yue`) *before* transliteration;
///    the remaining characters are transliterated by ICU in one call per sub-run (so ICU's own
///    multi-character context, e.g. `重庆` → `chong qing`, is preserved) and cached per run.
/// 3. Characters from the multi-reading set that were not covered by an override get an
///    alternative reading; the preferred variant comes first, then single substitutions, then the
///    pair combination — capped at 4 distinct variants.
///
/// Cost: dominated by ICU (~17 µs per call + ~7 µs per character on this Mac). Measured in release:
/// 1000 distinct 4–6-character names → 16.6 ms `variants` cold (16.6 µs/name), 12.3 ms `aliases`
/// with a warm cache. A bounded run cache makes repeated words (common in file names) essentially
/// free. Thread-safe; call off the main thread at index time.
public enum Pinyin {
    /// True if `s` contains any CJK Unified Ideograph (U+4E00–9FFF, U+3400–4DBF, U+20000–2A6DF)
    /// or CJK Compatibility Ideograph (U+F900–FAFF).
    public static func containsCJK(_ s: String) -> Bool {
        for u in s.unicodeScalars where isCJK(u.value) { return true }
        return false
    }

    /// All pinyin variants of `s` (empty if `s` has no CJK). First element is the preferred reading.
    /// Runs in 5–20 µs per name; call off the main thread at index time.
    public static func variants(of s: String) -> [PinyinVariant] {
        guard containsCJK(s) else { return [] }
        let pieces = segment(s)
        return expand(pieces)
    }

    /// Build the extra `SearchString` aliases for a CJK name (full, spaced, initials for each variant; deduped).
    ///
    /// Order: for each variant (preferred first) `full`, `spaced`, `initials`. Strings that fold to
    /// the same bytes are emitted once (so a single-syllable name does not get `spaced == full`
    /// twice). Initials shorter than 2 characters are skipped: a one-letter alias would turn every
    /// one-letter query into an "exact" match for that item. At most 12 entries (4 variants × 3).
    public static func aliases(for s: String) -> [SearchString] {
        let vs = variants(of: s)
        guard !vs.isEmpty else { return [] }
        var seen = Set<[UInt8]>()
        var out: [SearchString] = []
        out.reserveCapacity(vs.count * 3)
        func add(_ text: String) {
            guard !text.isEmpty else { return }
            let a = TextAnalyzer.analyze(text)
            if !a.folded.isEmpty && seen.insert(a.folded).inserted { out.append(a) }
        }
        for v in vs {
            add(v.full)
            add(v.spaced)
            if v.initials.count >= 2 { add(v.initials) }
        }
        return out
    }

    // MARK: - Character classification

    /// Unicode scalar value ranges treated as CJK ideographs.
    static func isCJK(_ v: UInt32) -> Bool {
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    // MARK: - Pieces

    /// One unit of the transliterated name: either a pinyin syllable (with an optional alternative
    /// reading) or a verbatim lowercased non-CJK word.
    struct Piece: Equatable {
        var text: String
        var alt: String?
        var isSyllable: Bool

        static func syllable(_ t: String, alt: String? = nil) -> Piece { Piece(text: t, alt: alt, isSyllable: true) }
        static func latin(_ t: String) -> Piece { Piece(text: t, alt: nil, isSyllable: false) }
    }

    /// Split `s` into pieces: CJK runs → syllables (override + ICU), non-CJK runs → words.
    static func segment(_ s: String) -> [Piece] {
        var pieces: [Piece] = []
        var latin = String()
        var han: [Unicode.Scalar] = []
        for u in s.unicodeScalars {
            if isCJK(u.value) {
                if !latin.isEmpty { appendLatinWords(latin, to: &pieces); latin.removeAll(keepingCapacity: true) }
                han.append(u)
            } else {
                if !han.isEmpty { appendHanRun(han, to: &pieces); han.removeAll(keepingCapacity: true) }
                latin.unicodeScalars.append(u)
            }
        }
        if !latin.isEmpty { appendLatinWords(latin, to: &pieces) }
        if !han.isEmpty { appendHanRun(han, to: &pieces) }
        return pieces
    }

    /// Split a non-CJK run on whitespace; each word becomes a verbatim lowercased piece.
    static func appendLatinWords(_ run: String, to pieces: inout [Piece]) {
        var word = String()
        for u in run.unicodeScalars {
            if u.properties.isWhitespace {
                if !word.isEmpty { pieces.append(.latin(word.lowercased())); word.removeAll(keepingCapacity: true) }
            } else {
                word.unicodeScalars.append(u)
            }
        }
        if !word.isEmpty { pieces.append(.latin(word.lowercased())) }
    }

    /// Transliterate one CJK run: override words first, ICU for everything in between.
    static func appendHanRun(_ run: [Unicode.Scalar], to pieces: inout [Piece]) {
        var pending: [Unicode.Scalar] = []
        var i = 0
        while i < run.count {
            if let (length, syllables) = overrideMatch(in: run, at: i) {
                if !pending.isEmpty { appendICUSyllables(pending, to: &pieces); pending.removeAll(keepingCapacity: true) }
                for syl in syllables { pieces.append(.syllable(syl)) }
                i += length
            } else {
                pending.append(run[i])
                i += 1
            }
        }
        if !pending.isEmpty { appendICUSyllables(pending, to: &pieces) }
    }

    /// Longest override word starting at `run[i]`, as (length in scalars, syllables).
    static func overrideMatch(in run: [Unicode.Scalar], at i: Int) -> (Int, [String])? {
        guard let candidates = overrideTable[run[i].value] else { return nil }
        for entry in candidates {  // sorted longest first
            let n = entry.word.count
            guard i + n <= run.count else { continue }
            var ok = true
            for k in 1..<n where run[i + k].value != entry.word[k] { ok = false; break }
            if ok { return (n, entry.syllables) }
        }
        return nil
    }

    /// Transliterate `chars` with ICU (cached) and append one syllable piece per character, with
    /// alternative readings for multi-reading characters. If ICU's syllable count does not line up
    /// with the character count (should not happen — untransliterable characters pass through as
    /// their own token), no alternatives are attached.
    static func appendICUSyllables(_ chars: [Unicode.Scalar], to pieces: inout [Piece]) {
        let syllables = transliterate(chars)
        if syllables.count == chars.count {
            for (k, syl) in syllables.enumerated() {
                pieces.append(.syllable(syl, alt: alternativeReading(of: chars[k].value, preferred: syl)))
            }
        } else {
            for syl in syllables { pieces.append(.syllable(syl)) }
        }
    }

    /// The other common reading of a multi-reading character, or nil if `preferred` is its only one.
    static func alternativeReading(of scalar: UInt32, preferred: String) -> String? {
        guard let readings = multiReadings[scalar] else { return nil }
        return readings.first { $0 != preferred }
    }

    // MARK: - ICU transliteration (cached)

    private static let cacheLock = NSLock()
    private static var runCache: [String: [String]] = [:]
    /// Upper bound on cached runs; the cache is simply cleared when it fills (no LRU bookkeeping).
    static let runCacheLimit = 8192

    /// Space-separated pinyin syllables of a pure-CJK run via `mandarinToLatin` + `stripDiacritics`.
    /// Falls back to the characters themselves if the transform is unavailable.
    static func transliterate(_ chars: [Unicode.Scalar]) -> [String] {
        var key = String()
        key.unicodeScalars.append(contentsOf: chars)
        cacheLock.lock()
        let hit = runCache[key]
        cacheLock.unlock()
        if let hit { return hit }
        let result = icuSyllables(of: key) ?? chars.map { String($0) }
        cacheLock.lock()
        if runCache.count >= runCacheLimit { runCache.removeAll(keepingCapacity: true) }
        runCache[key] = result
        cacheLock.unlock()
        return result
    }

    /// Raw ICU pass (uncached). Returns nil if either transform fails.
    static func icuSyllables(of run: String) -> [String]? {
        guard let latin = (run as NSString).applyingTransform(.mandarinToLatin, reverse: false),
              let plain = (latin as NSString).applyingTransform(.stripDiacritics, reverse: false) else { return nil }
        return plain.lowercased().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Number of cached runs (for tests).
    static var cachedRunCount: Int { cacheLock.lock(); defer { cacheLock.unlock() }; return runCache.count }

    /// Drop all cached runs (for tests).
    static func clearCache() { cacheLock.lock(); runCache.removeAll(); cacheLock.unlock() }

    // MARK: - Variant expansion

    /// Maximum number of variants emitted per name.
    public static let maxVariants = 4

    /// Build ≤ `maxVariants` distinct variants: preferred reading, then single alternative
    /// substitutions, then the first pair. Deduped on `full`.
    static func expand(_ pieces: [Piece]) -> [PinyinVariant] {
        let altPositions = pieces.indices.filter { pieces[$0].alt != nil }
        var out: [PinyinVariant] = []
        var seen = Set<String>()
        for mask in substitutionMasks(altCount: altPositions.count) {
            let v = makeVariant(pieces, altPositions: altPositions, mask: mask)
            if v.full.isEmpty || !seen.insert(v.full).inserted { continue }
            out.append(v)
            if out.count == maxVariants { break }
        }
        return out
    }

    /// Bitmasks over alternative positions, in preference order: none, each single, then the first pair.
    static func substitutionMasks(altCount n: Int) -> [UInt32] {
        var masks: [UInt32] = [0]
        for i in 0..<min(n, maxVariants - 1) { masks.append(1 << UInt32(i)) }
        if n >= 2 { masks.append(0b11) }
        return masks
    }

    /// Assemble full/spaced/initials from `pieces`, substituting `alt` where `mask` selects it.
    static func makeVariant(_ pieces: [Piece], altPositions: [Int], mask: UInt32) -> PinyinVariant {
        var full = String(), spaced = String(), initials = String()
        var altIndex = 0
        for (i, p) in pieces.enumerated() {
            var text = p.text
            if altIndex < altPositions.count && altPositions[altIndex] == i {
                if mask & (1 << UInt32(altIndex)) != 0, let a = p.alt { text = a }
                altIndex += 1
            }
            if text.isEmpty { continue }
            full.append(text)
            if !spaced.isEmpty { spaced.append(" ") }
            spaced.append(text)
            if let c = initial(of: text) { initials.unicodeScalars.append(c) }
        }
        return PinyinVariant(full: full, initials: initials, spaced: spaced)
    }

    /// First ASCII letter/digit of `text` (non-ASCII letters are folded first: `é` → `e`).
    static func initial(of text: String) -> Unicode.Scalar? {
        for u in text.unicodeScalars {
            if u.isASCII {
                if isASCIIAlnum(u.value) { return u }
                continue
            }
            if let f = TextAnalyzer.fold(String(u)).unicodeScalars.first, isASCIIAlnum(f.value) { return f }
        }
        return nil
    }

    static func isASCIIAlnum(_ v: UInt32) -> Bool {
        (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
    }

    // MARK: - Tables

    struct Override { let word: [UInt32]; let syllables: [String] }

    /// Heteronym words whose reading ICU gets wrong (or where the common reading must be pinned so
    /// no alternative variant is produced). Applied before transliteration, longest match first.
    static let overrideWords: [(String, String)] = [
        ("音乐", "yin yue"), ("银行", "yin hang"), ("行情", "hang qing"), ("长城", "chang cheng"),
        ("相册", "xiang ce"), ("会计", "kuai ji"), ("朝阳", "chao yang"), ("乐视", "le shi"),
        ("快乐", "kuai le"), ("便签", "bian qian"), ("便利", "bian li"), ("睡觉", "shui jiao"),
        ("觉醒", "jue xing"), ("还原", "huan yuan"), ("还有", "hai you"), ("重庆", "chong qing"),
        ("重要", "zhong yao"), ("长度", "chang du"), ("成长", "cheng zhang"), ("发现", "fa xian"),
        ("头发", "tou fa"), ("都会", "dou hui"), ("首都", "shou du"), ("参加", "can jia"),
        ("人参", "ren shen"), ("调整", "tiao zheng"), ("调查", "diao cha"), ("干净", "gan jing"),
        ("干活", "gan huo"), ("假期", "jia qi"), ("降落", "jiang luo"), ("投降", "tou xiang"),
        ("学校", "xue xiao"), ("校对", "jiao dui"), ("兴趣", "xing qu"), ("高兴", "gao xing"),
        ("切换", "qie huan"), ("一切", "yi qie"), ("省份", "sheng fen"), ("反省", "fan xing"),
        ("薄荷", "bo he"), ("单薄", "dan bo"), ("和平", "he ping"), ("暖和", "nuan huo"),
        ("藏书", "cang shu"), ("西藏", "xi zang"), ("曾经", "ceng jing"), ("姓曾", "xing zeng"),
        ("弹琴", "tan qin"), ("子弹", "zi dan"),
    ]

    /// `overrideWords` indexed by first scalar, longest word first.
    static let overrideTable: [UInt32: [Override]] = {
        var t: [UInt32: [Override]] = [:]
        for (word, pinyin) in overrideWords {
            let scalars = word.unicodeScalars.map { $0.value }
            guard let first = scalars.first else { continue }
            let entry = Override(word: scalars, syllables: pinyin.split(separator: " ").map(String.init))
            t[first, default: []].append(entry)
        }
        for k in t.keys { t[k]!.sort { $0.word.count > $1.word.count } }
        return t
    }()

    /// Common readings of multi-reading characters (simplified + a few traditional forms).
    /// The alternative emitted is the first listed reading that differs from ICU's choice.
    static let multiReadingChars: [(String, [String])] = [
        ("乐", ["le", "yue"]), ("行", ["xing", "hang"]), ("重", ["zhong", "chong"]), ("长", ["chang", "zhang"]),
        ("朝", ["chao", "zhao"]), ("便", ["bian", "pian"]), ("觉", ["jue", "jiao"]), ("还", ["hai", "huan"]),
        ("都", ["dou", "du"]), ("发", ["fa"]), ("和", ["he", "huo"]), ("藏", ["cang", "zang"]),
        ("曾", ["ceng", "zeng"]), ("弹", ["tan", "dan"]), ("调", ["tiao", "diao"]), ("干", ["gan"]),
        ("假", ["jia"]), ("降", ["jiang", "xiang"]), ("校", ["xiao", "jiao"]), ("兴", ["xing"]),
        ("参", ["can", "shen"]), ("薄", ["bo", "bao"]), ("切", ["qie", "qia"]), ("省", ["sheng", "xing"]),
        // Traditional forms ICU also handles.
        ("樂", ["le", "yue"]), ("長", ["chang", "zhang"]), ("還", ["hai", "huan"]), ("彈", ["tan", "dan"]),
        ("調", ["tiao", "diao"]), ("覺", ["jue", "jiao"]), ("參", ["can", "shen"]),
    ]

    /// `multiReadingChars` keyed by scalar value.
    static let multiReadings: [UInt32: [String]] = {
        var t: [UInt32: [String]] = [:]
        for (ch, readings) in multiReadingChars {
            if let u = ch.unicodeScalars.first { t[u.value] = readings }
        }
        return t
    }()
}
