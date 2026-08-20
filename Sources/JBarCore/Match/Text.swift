import Foundation

/// Character classes used for boundary bonuses (fzf-V2 style). Computed from the ORIGINAL
/// (un-folded) text so camelCase information survives folding.
public enum CharClass: UInt8 {
    case white = 0, nonword = 1, delim = 2, lower = 3, upper = 4, digit = 5

    @inlinable public static func of(_ scalar: Unicode.Scalar) -> CharClass {
        let v = scalar.value
        if v < 128 {
            let b = UInt8(v)
            switch b {
            case 0x61...0x7A: return .lower
            case 0x41...0x5A: return .upper
            case 0x30...0x39: return .digit
            case 0x20, 0x09, 0x0A, 0x0D: return .white
            case 0x2F, 0x2C, 0x3A, 0x3B, 0x7C: return .delim      // / , : ; |
            default: return .nonword
            }
        }
        if scalar.properties.isWhitespace { return .white }
        if scalar.properties.isAlphabetic || scalar.properties.isIdeographic { return .lower }
        if scalar.properties.numericType != nil { return .digit }
        return .nonword
    }
}

/// Boundary-bonus constants (launcher-tuned; fzf originals in DESIGN.md §6.3).
/// These are baked into the bonus arena at index time, so changing them requires a reindex
/// (the snapshot header hashes them).
public enum BonusConstants {
    public static let white: UInt8 = 16
    public static let delim: UInt8 = 14
    public static let boundary: UInt8 = 12
    public static let camel: UInt8 = 12
    public static let nonword: UInt8 = 4
    /// Bonus for a match that continues the previous match (applied by the scorer, not stored).
    public static let consecutive: UInt8 = 6
    /// Multiplier for the bonus of the first matched character.
    public static let firstMult: Int16 = 2
    /// Stable hash of the constants, mixed into snapshot headers.
    public static var hash: UInt64 {
        UInt64(white) | UInt64(delim) << 8 | UInt64(boundary) << 16 | UInt64(camel) << 24 | UInt64(nonword) << 32 | UInt64(consecutive) << 40
    }

    /// Bonus for a character of class `cur` preceded by a character of class `prev`.
    @inlinable public static func bonus(prev: CharClass, cur: CharClass) -> UInt8 {
        if cur == .lower || cur == .upper || cur == .digit {
            switch prev {
            case .white: return white
            case .delim: return delim
            case .nonword: return boundary
            case .lower: return (cur == .upper || cur == .digit) ? camel : 0 // lower→Upper, letter→digit
            case .upper: return cur == .digit ? camel : 0                     // letter→digit
            case .digit: return 0
            }
        }
        if cur == .nonword || cur == .delim { return nonword }
        return 0
    }
}

/// 64-bit character-presence mask: bits 0–25 `a–z`, 26–35 `0–9`, 36 ASCII punctuation,
/// 37 any non-ASCII byte. Items whose mask lacks any query bit cannot match and are skipped.
public enum Mask {
    @inlinable public static func bit(forFoldedByte b: UInt8) -> UInt64 {
        switch b {
        case 0x61...0x7A: return 1 << UInt64(b - 0x61)
        case 0x30...0x39: return 1 << UInt64(26 + (b - 0x30))
        case 0x80...0xFF: return 1 << 37
        case 0x20: return 0
        default: return 1 << 36
        }
    }
    @inlinable public static func of(_ folded: [UInt8]) -> UInt64 {
        var m: UInt64 = 0
        for b in folded { m |= bit(forFoldedByte: b) }
        return m
    }
    @inlinable public static func of(_ folded: ArraySlice<UInt8>) -> UInt64 {
        var m: UInt64 = 0
        for b in folded { m |= bit(forFoldedByte: b) }
        return m
    }
}

/// Text normalisation + pre-analysis shared by the indexer (items, app aliases) and the engine (queries).
public enum TextAnalyzer {
    /// Case-, diacritic- and width-insensitive folding. CJK is preserved (multi-byte UTF-8).
    @inlinable public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Maximum number of initials packed into the `initials` word (8 × 8 bits).
    public static let maxInitials = 8

    /// Analyse a display string into its searchable form.
    ///
    /// - folded bytes: UTF-8 of `fold(s)` (per character, so bonus alignment is exact)
    /// - bonus: boundary bonus on the first folded byte of each character, 0 on continuation bytes
    /// - mask: presence bits of all folded bytes
    /// - initials: lowercase ASCII first byte of each word token (see `isTokenStart`), max 8, packed
    public static func analyze(_ s: String) -> SearchString {
        var folded: [UInt8] = []
        var bonus: [UInt8] = []
        folded.reserveCapacity(s.utf8.count)
        bonus.reserveCapacity(s.utf8.count)
        var mask: UInt64 = 0
        var initials: UInt64 = 0
        var nInitials = 0
        var prev: CharClass = .white
        for ch in s {
            // Class from the original character (first scalar), bonus computed before folding.
            let cur = CharClass.of(ch.unicodeScalars.first!)
            let b = BonusConstants.bonus(prev: prev, cur: cur)
            let fch = fold(String(ch))
            var first = true
            for byte in fch.utf8 {
                folded.append(byte)
                bonus.append(first ? b : 0)
                mask |= Mask.bit(forFoldedByte: byte)
                if first && nInitials < maxInitials && isTokenStart(prev: prev, cur: cur) {
                    let lb = byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte
                    if (lb >= 0x61 && lb <= 0x7A) || (lb >= 0x30 && lb <= 0x39) {
                        initials |= UInt64(lb) << UInt64(8 * nInitials)
                        nInitials += 1
                    }
                }
                first = false
            }
            prev = cur
        }
        return SearchString(folded: folded, bonus: bonus, mask: mask, initials: initials)
    }

    /// A token starts at a word char following white/delim/nonword, at lower→Upper, or at non-digit→digit.
    @inlinable public static func isTokenStart(prev: CharClass, cur: CharClass) -> Bool {
        guard cur == .lower || cur == .upper || cur == .digit else { return false }
        switch prev {
        case .white, .delim, .nonword: return true
        case .lower: return cur == .upper || cur == .digit
        case .upper: return cur == .digit
        case .digit: return false
        }
    }

    /// Word tokens of `s` (original case), split on whitespace, `- _ . / ( ) [ ] , : ; & +`,
    /// lower→Upper and letter→digit transitions. `iTermApp` → `["i","Term","App"]`.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: CharClass = .white
        for ch in s {
            let c = CharClass.of(ch.unicodeScalars.first!)
            if c == .white || c == .delim || c == .nonword {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                if !cur.isEmpty && isTokenStart(prev: prev, cur: c) { out.append(cur); cur = "" }
                cur.append(ch)
            }
            prev = c
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Pack up to 8 lowercase ASCII initials into a UInt64 (same layout as `analyze`).
    public static func packInitials(_ s: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in s.prefix(maxInitials).enumerated() { v |= UInt64(b) << UInt64(8 * i) }
        return v
    }

    /// Unpack the initials word back into bytes (for tests / prefix checks).
    public static func unpackInitials(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<maxInitials {
            let b = UInt8((v >> UInt64(8 * i)) & 0xFF)
            if b == 0 { break }
            out.append(b)
        }
        return out
    }

    /// Map matched byte offsets in the FOLDED form of `display` back to character indices of `display`.
    /// Used only for highlighting the top rows. Folding is done per character so offsets align with `analyze`.
    public static func characterIndices(display: String, matchedFoldedByteOffsets: [Int]) -> [Int] {
        guard !matchedFoldedByteOffsets.isEmpty else { return [] }
        let wanted = Set(matchedFoldedByteOffsets)
        var result: [Int] = []
        var byteOff = 0
        for (ci, ch) in display.enumerated() {
            let n = fold(String(ch)).utf8.count
            for k in 0..<n where wanted.contains(byteOff + k) { result.append(ci); break }
            byteOff += n
        }
        return result
    }

    /// Lowercase extension of a file name (no dot), or nil if none/too long/hidden-file-only.
    public static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8, !ext.contains(" ") else { return nil }
        return ext.lowercased()
    }
}
