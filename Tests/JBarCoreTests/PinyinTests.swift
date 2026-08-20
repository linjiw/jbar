import XCTest
@testable import JBarCore

final class PinyinTests: XCTestCase {

    private func fulls(_ s: String) -> [String] { Pinyin.variants(of: s).map(\.full) }
    private func str(_ a: SearchString) -> String { String(decoding: a.folded, as: UTF8.self) }

    // MARK: containsCJK

    func testContainsCJK() {
        XCTAssertTrue(Pinyin.containsCJK("微信"))
        XCTAssertTrue(Pinyin.containsCJK("WeChat微信"))
        XCTAssertTrue(Pinyin.containsCJK("網易雲音樂"))                 // traditional
        XCTAssertTrue(Pinyin.containsCJK("\u{3400}"))                  // Ext-A start
        XCTAssertTrue(Pinyin.containsCJK("\u{4DBF}"))                  // Ext-A end
        XCTAssertTrue(Pinyin.containsCJK("\u{4E00}"))                  // URO start
        XCTAssertTrue(Pinyin.containsCJK("\u{9FFF}"))                  // URO end
        XCTAssertTrue(Pinyin.containsCJK("\u{20000}"))                 // Ext-B start
        XCTAssertTrue(Pinyin.containsCJK("\u{2A6DF}"))                 // Ext-B end
        XCTAssertTrue(Pinyin.containsCJK("\u{F900}"))                  // compatibility
        XCTAssertTrue(Pinyin.containsCJK("\u{FAFF}"))
        XCTAssertTrue(Pinyin.containsCJK("file-中文.pdf"))

        XCTAssertFalse(Pinyin.containsCJK(""))
        XCTAssertFalse(Pinyin.containsCJK("Xcode"))
        XCTAssertFalse(Pinyin.containsCJK("Café Résumé ＡＢＣ"))
        XCTAssertFalse(Pinyin.containsCJK("ひらがなカタカナ"))            // kana only
        XCTAssertFalse(Pinyin.containsCJK("한국어"))                     // hangul
        XCTAssertFalse(Pinyin.containsCJK("、。「」（）"))               // CJK punctuation, not ideographs
        XCTAssertFalse(Pinyin.containsCJK("\u{33FF}\u{4DC0}\u{1FFFF}\u{2A6E0}\u{F8FF}\u{FB00}")) // just outside every range
    }

    // MARK: Basic transliteration

    func testWeixin() {
        let vs = Pinyin.variants(of: "微信")
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs.first, PinyinVariant(full: "weixin", initials: "wx", spaced: "wei xin"))
    }

    func testWangyiyunyinyueUsesOverride() {
        let vs = Pinyin.variants(of: "网易云音乐")
        XCTAssertEqual(vs.first?.full, "wangyiyunyinyue")
        XCTAssertEqual(vs.first?.initials, "wyyyy")
        XCTAssertEqual(vs.first?.spaced, "wang yi yun yin yue")
        XCTAssertEqual(vs.count, 1, "乐 is covered by the 音乐 override → no alternative variant")
    }

    func testOverrides() {
        XCTAssertEqual(fulls("银行").first, "yinhang")
        XCTAssertEqual(fulls("重庆").first, "chongqing")
        XCTAssertEqual(fulls("长城").first, "changcheng")
        XCTAssertEqual(fulls("会计").first, "kuaiji")
        XCTAssertEqual(fulls("睡觉").first, "shuijiao")
        XCTAssertEqual(fulls("西藏").first, "xizang")
        XCTAssertEqual(fulls("快乐").first, "kuaile")
        XCTAssertEqual(fulls("快乐"), ["kuaile"], "override pins the reading, no 'kuaiyue'")
        XCTAssertEqual(fulls("中国银行").first, "zhongguoyinhang")     // override in the middle of a run
        XCTAssertEqual(fulls("银行卡").first, "yinhangka")             // override at the start of a run
        XCTAssertEqual(fulls("音乐银行").first, "yinyueyinhang")       // two adjacent overrides
        XCTAssertEqual(Pinyin.variants(of: "音乐银行").first?.initials, "yyyh")
    }

    func testEveryOverrideWordProducesItsPinyin() {
        for (word, pinyin) in Pinyin.overrideWords {
            let v = Pinyin.variants(of: word)
            XCTAssertEqual(v.first?.spaced, pinyin, "override \(word)")
            XCTAssertEqual(v.count, 1, "override \(word) must not expand")
        }
    }

    // MARK: Multi-reading expansion

    func testLegaoYieldsBothReadings() {
        let f = fulls("乐高")
        XCTAssertEqual(f.first, "legao", "ICU reading first")
        XCTAssertTrue(f.contains("yuegao"))
        XCTAssertEqual(f.count, 2)
        let vs = Pinyin.variants(of: "乐高")
        XCTAssertEqual(vs[1].initials, "yg")
        XCTAssertEqual(vs[1].spaced, "yue gao")
    }

    func testMultiReadingAlternativesForWholeSet() {
        // Every character in the set has its ICU reading first and, if it has another reading, exactly one alternative.
        for (ch, readings) in Pinyin.multiReadingChars {
            let f = fulls(ch)
            XCTAssertFalse(f.isEmpty, ch)
            if readings.count > 1 {
                XCTAssertEqual(f.count, 2, "\(ch) should have two variants: \(f)")
                XCTAssertEqual(Set(f), Set(readings), "\(ch) variants should be exactly its readings: \(f)")
            } else {
                XCTAssertEqual(f, readings, "\(ch) has a single reading")
            }
        }
    }

    func testTwoMultiReadingCharsGiveFourVariantsCapped() {
        let f = fulls("乐行")
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f[0], "lexing")
        XCTAssertEqual(Set(f), ["lexing", "yuexing", "lehang", "yuehang"])
        // Three multi-reading chars → still capped at 4, preferred first, singles next.
        let g = fulls("乐行重")
        XCTAssertEqual(g.count, Pinyin.maxVariants)
        XCTAssertEqual(g[0], "lexingzhong")
        XCTAssertEqual(Set(g), ["lexingzhong", "yuexingzhong", "lehangzhong", "lexingchong"])
        XCTAssertLessThanOrEqual(fulls("乐行重长朝便觉").count, Pinyin.maxVariants)
    }

    func testVariantsAreDistinct() {
        for name in ["乐行重长", "发发", "干干净净", "微信微信", "WeChat微信 WeChat"] {
            let f = fulls(name)
            XCTAssertEqual(Set(f).count, f.count, name)
        }
    }

    // MARK: Mixed scripts

    func testMixedLatinAndCJK() {
        let v = Pinyin.variants(of: "WeChat微信")
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0], PinyinVariant(full: "wechatweixin", initials: "wwx", spaced: "wechat wei xin"))

        let m = Pinyin.variants(of: "网易云音乐 Music")[0]
        XCTAssertEqual(m.full, "wangyiyunyinyuemusic")
        XCTAssertEqual(m.initials, "wyyyym")
        XCTAssertEqual(m.spaced, "wang yi yun yin yue music")

        let p = Pinyin.variants(of: "WeChat 微信 Pro")[0]
        XCTAssertEqual(p, PinyinVariant(full: "wechatweixinpro", initials: "wwxp", spaced: "wechat wei xin pro"))

        let d = Pinyin.variants(of: "微信2024")[0]
        XCTAssertEqual(d, PinyinVariant(full: "weixin2024", initials: "wx2", spaced: "wei xin 2024"))

        let t = Pinyin.variants(of: "iTerm微信")[0]
        XCTAssertEqual(t.full, "itermweixin")
        XCTAssertEqual(t.initials, "iwx")
    }

    func testPunctuationAndFileNames() {
        let v = Pinyin.variants(of: "中文-文件.pdf")[0]
        XCTAssertEqual(v.full, "zhongwen-wenjian.pdf")
        XCTAssertEqual(v.spaced, "zhong wen - wen jian .pdf")
        XCTAssertEqual(v.initials, "zwwjp")   // '-' has no initial; '.pdf' → 'p'

        let w = Pinyin.variants(of: "微信（测试）")[0]
        XCTAssertEqual(w.full, "weixin（ceshi）")
        XCTAssertEqual(w.initials, "wxcs")

        let e = Pinyin.variants(of: "  微信  ")[0]     // surrounding whitespace is dropped
        XCTAssertEqual(e.full, "weixin")
        XCTAssertEqual(e.spaced, "wei xin")

        let a = Pinyin.variants(of: "Éric的文件")[0]   // accented latin initial folds to 'e'
        XCTAssertEqual(a.full, "éricdewenjian")
        XCTAssertEqual(a.initials, "edwj")
    }

    func testTraditionalCharacters() {
        let v = Pinyin.variants(of: "網易雲音樂")
        XCTAssertEqual(v.first?.full, "wangyiyunyinle")     // ICU's reading for 樂 (no override for the traditional word)
        XCTAssertTrue(v.map(\.full).contains("wangyiyunyinyue"), "樂 is in the multi-reading set")
        XCTAssertEqual(fulls("微信").first, fulls("微信").first)
        XCTAssertEqual(Pinyin.variants(of: "繁體").first?.full, "fanti")
    }

    func testUntransliterableCharacterPassesThrough() throws {
        // Find a CJK ideograph ICU has no reading for (U+9FD8 on macOS 26); it must stay a token of
        // its own and must not break the character ↔ syllable alignment used for alternatives.
        let candidate = (0x9FD8...0x9FFF).lazy.map { Unicode.Scalar($0)! }
            .first { Pinyin.icuSyllables(of: String($0)) == [String($0)] }
        guard let ch = candidate.map(String.init) else { throw XCTSkip("ICU on this system transliterates every tested ideograph") }
        let v = Pinyin.variants(of: "微" + ch + "乐")
        XCTAssertFalse(v.isEmpty)
        XCTAssertEqual(v[0].spaced, "wei " + ch + " le")
        XCTAssertEqual(v[0].initials, "wl")
        XCTAssertEqual(v.map(\.full), ["wei" + ch + "le", "wei" + ch + "yue"])
        // Alignment mismatch path: a run whose ICU output has fewer tokens than characters gets no alternatives.
        var pieces: [Pinyin.Piece] = []
        Pinyin.appendICUSyllables(Array("乐高".unicodeScalars), to: &pieces)
        XCTAssertEqual(pieces.map(\.text), ["le", "gao"])
        XCTAssertEqual(pieces[0].alt, "yue")
    }

    func testNoCJKGivesNothing() {
        XCTAssertEqual(Pinyin.variants(of: "Xcode"), [])
        XCTAssertEqual(Pinyin.variants(of: ""), [])
        XCTAssertEqual(Pinyin.variants(of: "Visual Studio Code"), [])
        XCTAssertEqual(Pinyin.aliases(for: "Xcode"), [])
        XCTAssertEqual(Pinyin.aliases(for: ""), [])
    }

    // MARK: aliases(for:)

    func testAliasesForWeixin() {
        let a = Pinyin.aliases(for: "微信")
        XCTAssertEqual(a.map(str), ["weixin", "wei xin", "wx"])
        // Each alias is a fully analysed SearchString.
        XCTAssertEqual(a[0], TextAnalyzer.analyze("weixin"))
        XCTAssertEqual(a[2].mask, Mask.of(Array("wx".utf8)))
        XCTAssertEqual(TextAnalyzer.unpackInitials(a[1].initials), Array("wx".utf8))
    }

    func testAliasesDedupeAndCap() {
        // Single syllable: spaced == full → deduped; 1-letter initials dropped.
        XCTAssertEqual(Pinyin.aliases(for: "乐").map(str), ["le", "yue"])
        // 4 variants × 3 strings = 12 max.
        XCTAssertLessThanOrEqual(Pinyin.aliases(for: "乐行重长朝").count, 12)
        XCTAssertEqual(Pinyin.aliases(for: "乐行").count, 12)
        let names = ["网易云音乐", "WeChat微信", "中文-文件.pdf", "乐行重长朝便觉还都发和藏曾弹调干假降校兴参薄切省", "微信 微信"]
        for n in names {
            let a = Pinyin.aliases(for: n)
            XCTAssertLessThanOrEqual(a.count, 12, n)
            XCTAssertEqual(Set(a.map(\.folded)).count, a.count, "aliases must be deduped for \(n)")
            XCTAssertFalse(a.contains { $0.folded.isEmpty }, n)
        }
    }

    func testAliasesMixedAndOrder() {
        let a = Pinyin.aliases(for: "乐高").map(str)
        XCTAssertEqual(a, ["legao", "le gao", "lg", "yuegao", "yue gao", "yg"])
    }

    // MARK: Internals

    func testSubstitutionMasks() {
        XCTAssertEqual(Pinyin.substitutionMasks(altCount: 0), [0])
        XCTAssertEqual(Pinyin.substitutionMasks(altCount: 1), [0, 1])
        XCTAssertEqual(Pinyin.substitutionMasks(altCount: 2), [0, 1, 2, 3])
        XCTAssertEqual(Pinyin.substitutionMasks(altCount: 3), [0, 1, 2, 4, 3])
        XCTAssertEqual(Pinyin.substitutionMasks(altCount: 9), [0, 1, 2, 4, 3])
    }

    func testInitialOf() {
        XCTAssertEqual(Pinyin.initial(of: "wei"), "w")
        XCTAssertEqual(Pinyin.initial(of: "2024"), "2")
        XCTAssertEqual(Pinyin.initial(of: ".pdf"), "p")
        XCTAssertEqual(Pinyin.initial(of: "-"), nil)
        XCTAssertEqual(Pinyin.initial(of: "éric"), "e")
        XCTAssertEqual(Pinyin.initial(of: "（x"), "x")
        XCTAssertEqual(Pinyin.initial(of: "微"), nil)
        XCTAssertEqual(Pinyin.initial(of: ""), nil)
    }

    func testOverrideTableIsLongestFirstAndComplete() {
        XCTAssertEqual(Pinyin.overrideTable.values.reduce(0) { $0 + $1.count }, Pinyin.overrideWords.count)
        for entries in Pinyin.overrideTable.values {
            let lens = entries.map { $0.word.count }
            XCTAssertEqual(lens, lens.sorted(by: >))
            for e in entries { XCTAssertEqual(e.word.count, e.syllables.count, "one syllable per character") }
        }
        XCTAssertEqual(Pinyin.multiReadings.count, Pinyin.multiReadingChars.count)
    }

    func testICUFallbackWhenAlignmentBreaks() {
        // Direct check of the ICU helper and cache behaviour.
        XCTAssertEqual(Pinyin.icuSyllables(of: "微信"), ["wei", "xin"])
        XCTAssertEqual(Pinyin.icuSyllables(of: ""), [])
        Pinyin.clearCache()
        XCTAssertEqual(Pinyin.cachedRunCount, 0)
        _ = Pinyin.variants(of: "微信")
        XCTAssertEqual(Pinyin.cachedRunCount, 1)
        _ = Pinyin.variants(of: "微信")
        XCTAssertEqual(Pinyin.cachedRunCount, 1, "second call is a cache hit")
        _ = Pinyin.variants(of: "网易云音乐")   // '网易云' is ICU'd, '音乐' is an override
        XCTAssertEqual(Pinyin.cachedRunCount, 2)
        XCTAssertEqual(Pinyin.transliterate(Array("钉钉".unicodeScalars)), ["ding", "ding"])
    }

    func testCacheIsBounded() {
        Pinyin.clearCache()
        // Generate more distinct runs than the cache limit; the cache must never exceed the limit.
        var names: [String] = []
        for i in 0..<(Pinyin.runCacheLimit + 50) {
            // 0x4E00 + i*7 stays well inside the URO block (limit*7 ≈ 57k < 0x5200 span).
            let a = Unicode.Scalar(0x4E00 + (i * 7) % 0x51FF)!, b = Unicode.Scalar(0x4E00 + (i * 13) % 0x51FF)!
            names.append(String(a) + String(b) + String(UnicodeScalar(0x4E00 + i % 0x51FF)!))
        }
        for n in names { _ = Pinyin.transliterate(Array(n.unicodeScalars)) }
        XCTAssertLessThanOrEqual(Pinyin.cachedRunCount, Pinyin.runCacheLimit)
        XCTAssertGreaterThan(Pinyin.cachedRunCount, 0)
    }

    func testThreadSafety() {
        let names = ["微信", "网易云音乐", "乐高", "WeChat微信", "中文-文件.pdf", "银行", "重庆", "乐行重长"]
        let expected = names.map { Pinyin.variants(of: $0) }
        Pinyin.clearCache()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let n = names[i % names.count]
            XCTAssertEqual(Pinyin.variants(of: n), expected[i % names.count])
        }
    }

    // MARK: Performance

    func testPerformance1000Names() {
        // 1000 distinct realistic names (CJK word pairs + latin suffixes).
        let words = ["微信", "网易云音乐", "文档", "截图", "报告", "设计", "项目", "会议", "照片", "视频", "合同", "简历",
                     "银行", "重庆", "乐高", "学校", "音乐", "相册", "备份", "总结", "计划", "数据", "分析", "测试",
                     "开发", "产品", "市场", "财务", "人事", "培训", "旅行", "美食"]
        let suffixes = ["", ".pdf", ".docx", " 2024", "_v2.xlsx", " final", "-备份.zip", " WeChat"]
        // k-th name = words[k / 32] + words[k % 32] + suffix[k % 8] → 1000 distinct CJK runs (cold ICU for every name).
        var names: [String] = []
        for k in 0..<1000 {
            let a: String = words[k / 32], b: String = words[k % 32], c: String = suffixes[k % 8]
            names.append(a + b + c)
        }
        XCTAssertEqual(Set(names).count, 1000)

        Pinyin.clearCache()
        let t0 = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for n in names { total += Pinyin.variants(of: n).count }
        let coldMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertGreaterThanOrEqual(total, 1000)

        let t1 = DispatchTime.now().uptimeNanoseconds
        for n in names { total += Pinyin.aliases(for: n).count }
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6

        let coldStr = String(format: "%.1f", coldMs)
        let warmStr = String(format: "%.1f", warmMs)
        print("[Pinyin perf] 1000 distinct names: variants cold-cache \(coldStr) ms (= \(coldStr) µs/name); aliases warm-cache \(warmStr) ms")
        // Loose bound: ICU alone costs ~35 µs/name in release; debug builds of this file add overhead.
        XCTAssertLessThan(coldMs, 1000, "1000 names should transliterate well under a second")
    }
}
