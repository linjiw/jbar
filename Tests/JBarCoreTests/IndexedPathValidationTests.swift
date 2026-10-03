import XCTest
@testable import JBarCore

final class IndexedPathValidationTests: XCTestCase {
    func testByteValidatorMatchesFoundationForDeterministicByteCorpus() {
        func check(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            let expected = String(bytes: bytes, encoding: .utf8).map {
                SafetyLimits.isSafePathComponent($0, maxUTF8Bytes: 256)
            } ?? false
            XCTAssertEqual(IndexedPathValidation.isSafePathComponent(bytes[...], maxBytes: 256),
                           expected, "\(bytes)", file: file, line: line)
        }
        // Exhaust every one- and two-byte sequence, including overlong forms and stray continuations.
        for first in UInt16(0)...255 {
            check([UInt8(first)])
            for second in UInt16(0)...255 { check([UInt8(first), UInt8(second)]) }
        }
        // Fixed-seed multibyte fuzzing keeps malformed and mixed ASCII/Unicode inputs reproducible.
        var state: UInt64 = 0x4A424152
        func nextByte() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        for _ in 0..<20_000 {
            let count = 3 + Int(nextByte() % 6)
            check((0..<count).map { _ in nextByte() })
        }
    }

    func testByteValidatorMatchesStringContractForValidUTF8() {
        let samples = ["", ".", "..", "...", "simple", "报告😀", "café", "cafe\u{301}",
                       "slash/\u{301}", "nul\0\u{301}", "\u{7F}", "\u{80}", "\u{800}",
                       "\u{D7FF}", "\u{E000}", "\u{FFFF}", "\u{10000}", "\u{10FFFF}"]
        for name in samples {
            let bytes = [UInt8](name.utf8)
            for limit in [0, 1, 2, 8, SafetyLimits.maxNameUTF8Bytes] {
                XCTAssertEqual(IndexedPathValidation.isSafePathComponent(bytes[...], maxBytes: limit),
                               SafetyLimits.isSafePathComponent(name, maxUTF8Bytes: limit),
                               "\(name.debugDescription), limit \(limit)")
            }
        }
        let arena = Array("prefix/研究😀/suffix".utf8)
        let name = Array("研究😀".utf8)
        XCTAssertTrue(IndexedPathValidation.isSafePathComponent(arena[7..<(7 + name.count)], maxBytes: 256),
                      "slices need not start at zero")
    }

    func testByteValidatorRejectsMalformedUTF8AndTruncations() {
        let malformed: [[UInt8]] = [
            [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xC2, 0x7F], [0xDF, 0xC0],
            [0xE0, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xEF, 0xBF, 0x7F],
            [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
            [0xFF], [0x00, 0xCC, 0x81], [0x2F, 0xCC, 0x81],
        ]
        for bytes in malformed {
            XCTAssertFalse(IndexedPathValidation.isSafePathComponent(bytes[...], maxBytes: 256), "\(bytes)")
        }
        for name in ["é", "研", "😀"] {
            let bytes = Array(name.utf8)
            XCTAssertTrue(IndexedPathValidation.isSafePathComponent(bytes[...], maxBytes: 256))
            for length in 1..<bytes.count {
                XCTAssertFalse(IndexedPathValidation.isSafePathComponent(bytes.prefix(length), maxBytes: 256))
            }
        }
    }

    func testCompleteBytePathMatchesStringContractAndAppSuffixBudget() {
        for name in ["Tool", "Tool.app", "Tool.APP", "研究😀", "café"] {
            for flags in [UInt8(0), ItemFlags.appBundle.rawValue] {
                for slash in [false, true] {
                    for pathBytes in [1, SafetyLimits.maxPathUTF8Bytes - name.utf8.count - 4,
                                      SafetyLimits.maxPathUTF8Bytes - name.utf8.count,
                                      SafetyLimits.maxPathUTF8Bytes] {
                        XCTAssertEqual(IndexedPathValidation.completeItemPathFits(
                            directoryPathUTF8Bytes: pathBytes, directoryEndsInSlash: slash,
                            storedName: Array(name.utf8)[...], flagsRaw: flags
                        ), IndexStoreLimits.completeItemPathFits(
                            directoryPathUTF8Bytes: pathBytes, directoryEndsInSlash: slash,
                            storedName: name, flagsRaw: flags
                        ), "\(name), flags \(flags), path \(pathBytes), slash \(slash)")
                    }
                }
            }
        }
    }
}
