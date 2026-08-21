import Foundation

/// Interpretation of the raw text the user typed. DESIGN.md §6.2, §7.5.
public enum QueryMode: Sendable, Equatable {
    /// Nothing typed (show recents).
    case empty
    /// Normal fuzzy search.
    case search
    /// Path browsing: `base` is the directory to list (absolute, expanded), `filter` the trailing partial segment.
    case path(base: String, filter: String)
    /// Query like ".pdf" → list by extension only.
    case extensionOnly(String)
}

public struct ParsedQuery: Sendable, Equatable {
    public var raw: String
    public var mode: QueryMode
    /// Folded, analysed terms (≤ 6), whitespace-split; never split on `-`/`_`.
    public var terms: [SearchString]
    /// Original (trimmed) term strings, parallel to `terms`.
    public var termStrings: [String]
    /// The whole trimmed query folded (for exact/prefix name checks), spaces preserved.
    public var wholeFolded: [UInt8]
    /// Combined mask of all terms (AND filter pre-check).
    public var mask: UInt64
    /// Raw ended with whitespace → last term must match as a contiguous substring.
    public var lastTermComplete: Bool
    /// Query contains an uppercase letter (enables case-match bonus in highlighting).
    public var hasUppercase: Bool
    public init(raw: String, mode: QueryMode, terms: [SearchString], termStrings: [String], wholeFolded: [UInt8], mask: UInt64, lastTermComplete: Bool, hasUppercase: Bool) {
        self.raw = raw; self.mode = mode; self.terms = terms; self.termStrings = termStrings; self.wholeFolded = wholeFolded
        self.mask = mask; self.lastTermComplete = lastTermComplete; self.hasUppercase = hasUppercase
    }
}

/// Owner: config/query agent.
public enum QueryParser {
    /// Maximum number of whitespace-separated terms kept; extra terms are dropped.
    public static let maxTerms = 6
    /// Maximum extension length (without the dot) for the `.ext` extension-only mode.
    public static let maxExtensionLength = 8

    /// Parse `raw`. Rules: trim; empty → .empty; starts with `/`, `~`, `~/` or contains `/` with a leading `~`/`/` → .path
    /// (base = everything up to and including the last `/`, `~` expanded with `home`; filter = remainder);
    /// starts with `.` and has no spaces and ≤ 8 chars → .extensionOnly(lowercased without dot); else .search with ≤ 6 terms.
    ///
    /// Details:
    /// - Path mode: `~` / `~/` → (home, ""); `~/Dow` → (home, "Dow"); `~/Documents/rep` → (home/Documents, "rep");
    ///   `/App` → ("/", "App"); `/Applications/` → ("/Applications", ""). `~name` (no slash) is treated as `~/name`.
    ///   `terms`/`wholeFolded`/`mask` describe the filter segment (one term, or none when the filter is empty) so the
    ///   path-mode lister can reuse the scorer.
    /// - Extension-only: `.` + 1–8 chars of `[a-z0-9]` (case-insensitive, no whitespace) → `.extensionOnly("pdf")`.
    /// - Search: whitespace-split terms (≤ 6), each analysed with `TextAnalyzer.analyze`; `wholeFolded` is the trimmed
    ///   query with whitespace runs collapsed to single spaces, folded; `mask` is the OR of the term masks.
    /// - `lastTermComplete` = raw ends with whitespace (and is non-empty after trimming); `hasUppercase` = any uppercase
    ///   character in the trimmed query. Both are computed for every non-empty mode.
    public static func parse(_ raw: String, home: String = NSHomeDirectory()) -> ParsedQuery {
        // A paste is an untrusted local input just like config. Bound all subsequent folding, splitting,
        // and path work even when QueryParser is called without the UI. `prefix` walks at most the limit,
        // so a multi-megabyte String does not first incur another full-size allocation.
        let raw = boundedRaw(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuery(raw: raw, mode: .empty, terms: [], termStrings: [], wholeFolded: [], mask: 0,
                               lastTermComplete: false, hasUppercase: false)
        }
        let lastComplete = raw.last.map { $0.isWhitespace } ?? false
        let upper = trimmed.contains { $0.isUppercase }

        if trimmed.utf8.first == 0x2F || trimmed.utf8.first == 0x7E {
            let (base, filter) = splitPath(trimmed, home: normalizedHome(home))
            let termStrings = filter.isEmpty ? [] : [filter]
            let terms = termStrings.map { TextAnalyzer.analyze($0) }
            return ParsedQuery(raw: raw, mode: .path(base: base, filter: filter), terms: terms, termStrings: termStrings,
                               wholeFolded: filter.isEmpty ? [] : TextAnalyzer.analyze(filter).folded,
                               mask: terms.reduce(0) { $0 | $1.mask }, lastTermComplete: lastComplete, hasUppercase: upper)
        }

        if let ext = extensionOnly(trimmed) {
            let analyzed = TextAnalyzer.analyze(ext)
            return ParsedQuery(raw: raw, mode: .extensionOnly(ext), terms: [analyzed], termStrings: [ext],
                               wholeFolded: analyzed.folded, mask: analyzed.mask, lastTermComplete: lastComplete, hasUppercase: upper)
        }

        let termStrings = trimmed.split(whereSeparator: { $0.isWhitespace }).prefix(maxTerms).map(String.init)
        let terms = termStrings.map { TextAnalyzer.analyze($0) }
        let whole = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return ParsedQuery(raw: raw, mode: .search, terms: terms, termStrings: termStrings,
                           wholeFolded: TextAnalyzer.analyze(whole).folded, mask: terms.reduce(0) { $0 | $1.mask },
                           lastTermComplete: lastComplete, hasUppercase: upper)
    }

    static func boundedRaw(_ raw: String) -> String {
        // Limit UTF-8 first. A single extended grapheme may contain an arbitrary number of combining
        // marks, so asking String for its first N Characters before this step would still permit work
        // proportional to a multi-megabyte paste. Decoding a prefix also repairs a split UTF-8 scalar.
        let bytes = raw.utf8
        let byteLimited: String
        if let end = bytes.index(bytes.startIndex, offsetBy: SafetyLimits.maxQueryUTF8Bytes,
                                 limitedBy: bytes.endIndex), end < bytes.endIndex {
            byteLimited = String(decoding: bytes[..<end], as: UTF8.self)
        } else {
            byteLimited = raw
        }

        guard let end = byteLimited.index(byteLimited.startIndex, offsetBy: SafetyLimits.maxQueryCharacters,
                                          limitedBy: byteLimited.endIndex), end < byteLimited.endIndex else {
            return byteLimited
        }
        return String(byteLimited[..<end])
    }

    /// Split a path-mode query into (base directory, trailing filter segment), expanding a leading `~`.
    static func splitPath(_ q: String, home: String) -> (base: String, filter: String) {
        let home = normalizedHome(home)
        let queryBytes = Array(boundedRaw(q).utf8)
        let homeBytes = Array(home.utf8)
        let expanded: [UInt8]
        if queryBytes.first == 0x7E {
            var suffix = Array(queryBytes.dropFirst())
            if suffix.first != 0x2F { suffix.insert(0x2F, at: 0) }
            // A root home already supplies the separator. Avoid producing `//foo`, which changes
            // the parser's base and breaks home-relative browsing for embedded/test callers.
            expanded = homeBytes == [0x2F] ? homeBytes + suffix.dropFirst() : homeBytes + suffix
        } else {
            expanded = queryBytes
        }
        guard let slash = expanded.lastIndex(of: 0x2F) else {
            return ("/", String(decoding: expanded, as: UTF8.self))
        }
        var baseBytes = Array(expanded[..<slash])
        while baseBytes.count > 1 && baseBytes.last == 0x2F { baseBytes.removeLast() }
        if baseBytes.isEmpty { baseBytes = [0x2F] }
        let filterStart = expanded.index(after: slash)
        return (String(decoding: baseBytes, as: UTF8.self),
                String(decoding: expanded[filterStart...], as: UTF8.self))
    }

    static func normalizedHome(_ candidate: String) -> String {
        if SafetyLimits.isSafeAbsolutePath(candidate) {
            return SafetyLimits.trimmingTrailingPathSlashes(candidate)
        }
        let fallback = NSHomeDirectory()
        return SafetyLimits.isSafeAbsolutePath(fallback)
            ? SafetyLimits.trimmingTrailingPathSlashes(fallback) : "/"
    }

    /// `.pdf` → "pdf" if the trimmed query is a dot followed by 1–8 `[a-z0-9]` characters (case-insensitive); else nil.
    static func extensionOnly(_ trimmed: String) -> String? {
        guard SafetyLimits.hasDotPrefix(trimmed),
              SafetyLimits.utf8Fits(trimmed, maxBytes: maxExtensionLength + 1) else { return nil }
        let bytes = Array(trimmed.utf8)
        guard bytes.count >= 2 else { return nil }
        var folded: [UInt8] = []
        folded.reserveCapacity(bytes.count - 1)
        for byte in bytes.dropFirst() {
            switch byte {
            case 0x30...0x39, 0x61...0x7A: folded.append(byte)
            case 0x41...0x5A: folded.append(byte + 0x20)
            default: return nil
            }
        }
        return String(decoding: folded, as: UTF8.self)
    }
}
