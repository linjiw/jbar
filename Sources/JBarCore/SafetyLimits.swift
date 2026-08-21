import Foundation

/// Process-wide resource and input bounds.
///
/// These are product limits, not merely UI defaults. Every boundary that accepts user-controlled
/// configuration or public API arguments must either validate against them or apply an equally strict
/// defensive bound before allocating or multiplying.
public enum SafetyLimits {
    public static let maxResults = 1...500
    public static let visibleRows = 1...20
    public static let maxDepth = 0...64
    public static let maxIndexedItems = 1...2_000_000

    public static let maxConfigFileBytes = 1_048_576       // 1 MiB
    public static let maxHistoryFileBytes = 8 * 1_048_576  // 8 MiB
    /// Public callers may choose a smaller history, but cannot turn the in-memory store into an
    /// unbounded dictionary. The product default remains 500.
    public static let maxHistoryEntries = 10_000
    /// Bundle metadata is untrusted input: an installed app may expose a symlink, FIFO, device, or
    /// enormous plist/strings file. Real Info.plist files are far below this ceiling.
    public static let maxBundleMetadataFileBytes = 1_048_576
    public static let maxHotkeyUTF8Bytes = 128
    public static let maxSettingUTF8Bytes = 256
    public static let maxQueryCharacters = 4_096
    /// A grapheme can contain an arbitrary number of combining scalars, so the character limit alone
    /// is not a memory/work bound. Enforce this byte ceiling before grapheme segmentation.
    public static let maxQueryUTF8Bytes = 16_384
    public static let maxPathUTF8Bytes = 4_096
    public static let maxNameUTF8Bytes = 1_024
    /// Extensions are limited by user-visible characters and separately by UTF-8 work. Thirty-two
    /// bytes permits eight four-byte Unicode scalars instead of accidentally limiting CJK to two.
    public static let maxExtensionCharacters = 8
    public static let maxExtensionUTF8Bytes = 32

    public static let maxRootEntries = 128
    /// A complete index may combine the maximum configured file roots and app roots plus the
    /// scanner's shared synthetic catalog root. Persistence, coordination, and builders must use
    /// this same value so an exactly-full valid configuration remains round-trippable.
    public static let maxIndexRoots = maxRootEntries * 2 + 1
    public static let maxExcludedPathEntries = 1_024
    public static let maxNameEntries = 4_096
    /// Final folded aliases stored for one app, including display, localized, and generated pinyin
    /// variants. This must stay aligned with the snapshot validator.
    public static let maxSearchAliasesPerApp = 64
    /// Aggregate semantic payload retained for application side tables. Both `IndexBuilder` and
    /// snapshot encoding enforce this before constructing a potentially much larger JSON object.
    public static let maxAppSideTableBytes = 32 * 1_048_576

    /// Bounds for application discovery. Directory reads are streamed and rejected wholesale when
    /// they exceed the per-directory ceiling, so a user-controlled app root cannot force an
    /// unbounded allocation. Separate global ceilings bound inspected names and retained candidates
    /// across every configured root and depth-two subdirectory.
    public static let maxAppDirectoryEntries = 100_000
    public static let maxAppInspectedEntries = 500_000
    public static let maxAppCandidates = 20_000
    /// Extra directory-table entries the shared `/` application catalog may create while
    /// reconstructing exact absolute parent paths. AppScanner claims this budget atomically before
    /// adding a path, and snapshot/model topology bounds reserve the same allowance.
    public static let maxAppCatalogDirectories = 100_000
    /// Aggregate UTF-8 bytes retained by the catalog's directory-name arena. A count-only ceiling
    /// would still allow 100,000 maximum-length components to exceed Snapshot's bounded arena.
    public static let maxAppCatalogDirectoryBytes = 32 * 1_048_576
    public static let maxLocalizedResourceDirectories = 256
    /// Per-bundle localization work is independent of the number of installed applications. These
    /// limits include only bounded regular files opened relative to a validated bundle descriptor.
    public static let maxBundleLocalizationFiles = 64
    public static let maxBundleMetadataTotalBytes = 4 * 1_048_576

    public static let maxBenchmarkIterations = 10_000

    /// Checks a UTF-8 byte ceiling without first walking or allocating the entire string. This is
    /// used before hashing/folding untrusted metadata, paths, and queries.
    public static func utf8Fits(_ value: String, maxBytes: Int) -> Bool {
        guard maxBytes >= 0 else { return false }
        let bytes = value.utf8
        guard let boundary = bytes.index(bytes.startIndex, offsetBy: maxBytes,
                                         limitedBy: bytes.endIndex) else {
            return true
        }
        return boundary == bytes.endIndex
    }

    /// Validate one POSIX path component using UTF-8 bytes. Swift `Character` comparisons are not
    /// suitable here because an ASCII slash followed by a combining mark may form one grapheme while
    /// the filesystem still treats byte 0x2F as a separator.
    public static func isSafePathComponent(_ value: String, maxUTF8Bytes: Int) -> Bool {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return false }
        var byteCount = 0
        var onlyDots = true
        for byte in value.utf8 {
            if byte == 0 || byte == 0x2F { return false }
            byteCount += 1
            if byte != 0x2E { onlyDots = false }
        }
        guard byteCount > 0 else { return false }
        return !(onlyDots && (byteCount == 1 || byteCount == 2))
    }

    public static func containsNULByte(_ value: String) -> Bool {
        value.utf8.contains(0)
    }

    /// POSIX hidden-name checks must inspect the first UTF-8 byte. Swift `hasPrefix(".")` compares
    /// extended grapheme clusters, so a dot followed by a combining scalar can otherwise evade it.
    public static func hasDotPrefix(_ value: String) -> Bool {
        value.utf8.first == 0x2E
    }

    public static func hasTildeDollarPrefix(_ value: String) -> Bool {
        var iterator = value.utf8.makeIterator()
        return iterator.next() == 0x7E && iterator.next() == 0x24
    }

    /// Test the POSIX byte prefix `~/`. Swift `String.hasPrefix("~/")` is not suitable here:
    /// the slash and a following combining scalar can form one extended grapheme cluster even
    /// though the filesystem still sees byte 0x2F as the separator.
    public static func hasTildeSlashPrefix(_ value: String) -> Bool {
        var iterator = value.utf8.makeIterator()
        return iterator.next() == 0x7E && iterator.next() == 0x2F
    }

    /// Validate either an absolute path or the two supported home-relative spellings (`~` and
    /// `~/...`) entirely by UTF-8 bytes. The suffix after `~` is validated as an absolute path so
    /// literal `.` / `..` components cannot be hidden by Unicode grapheme composition.
    public static func isSafeAbsoluteOrTildePath(
        _ value: String,
        maxUTF8Bytes: Int = maxPathUTF8Bytes
    ) -> Bool {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return false }
        if isSafeAbsolutePath(value, maxUTF8Bytes: maxUTF8Bytes) { return true }
        if value == "~" { return true }
        guard hasTildeSlashPrefix(value) else { return false }
        let suffix = String(decoding: value.utf8.dropFirst(), as: UTF8.self)
        return isSafeAbsolutePath(suffix, maxUTF8Bytes: maxUTF8Bytes)
    }

    /// Expand a validated leading `~` without using Character-level prefix/drop operations.
    /// Returns `nil` for relative, oversized, unsafe, or traversal-containing input.
    public static func expandingLeadingTilde(
        _ value: String,
        home: String,
        maxUTF8Bytes: Int = maxPathUTF8Bytes
    ) -> String? {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes),
              isSafeAbsolutePath(home, maxUTF8Bytes: maxUTF8Bytes),
              isSafeAbsoluteOrTildePath(value, maxUTF8Bytes: maxUTF8Bytes) else { return nil }

        var output: [UInt8]
        if value == "~" {
            output = Array(home.utf8)
        } else if hasTildeSlashPrefix(value) {
            var homeBytes = Array(home.utf8)
            while homeBytes.count > 1 && homeBytes.last == 0x2F { homeBytes.removeLast() }
            let suffix = value.utf8.dropFirst() // retain the POSIX slash, drop only byte '~'
            if homeBytes == [0x2F] {
                output = homeBytes + suffix.dropFirst()
            } else {
                output = homeBytes + suffix
            }
        } else {
            output = Array(value.utf8)
        }

        while output.count > 1 && output.last == 0x2F { output.removeLast() }
        guard output.count <= maxUTF8Bytes else { return nil }
        let expanded = String(decoding: output, as: UTF8.self)
        return isSafeAbsolutePath(expanded, maxUTF8Bytes: maxUTF8Bytes) ? expanded : nil
    }

    /// Remove trailing POSIX slash bytes from a bounded path while preserving `/`. Oversized input
    /// is returned unchanged so this helper cannot turn a public call into an unbounded traversal.
    public static func trimmingTrailingPathSlashes(
        _ value: String,
        maxUTF8Bytes: Int = maxPathUTF8Bytes
    ) -> String {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return value }
        var bytes = Array(value.utf8)
        while bytes.count > 1 && bytes.last == 0x2F { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// POSIX containment using path-separator bytes rather than Swift Characters. Both inputs must
    /// already be bounded, absolute, traversal-free paths; `/` contains every such path. Components
    /// are then compared as Swift Strings so canonically equivalent NFC/NFD filesystem spellings
    /// remain equal while separator discovery stays byte-accurate.
    public static func isPath(_ candidate: String, within root: String) -> Bool {
        guard isSafeAbsolutePath(candidate), isSafeAbsolutePath(root) else { return false }
        if exactByteRelativeOffset(candidate, within: root) != nil { return true }
        guard
              let candidateComponents = posixPathComponents(candidate),
              let rootComponents = posixPathComponents(root),
              rootComponents.count <= candidateComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { $0.0 == $0.1 }
    }

    /// Return the byte-relative suffix when `candidate` is contained in `root`. The suffix never
    /// starts with a slash and is empty when both paths identify the same location.
    public static func relativePath(_ candidate: String, within root: String) -> String? {
        guard isSafeAbsolutePath(candidate), isSafeAbsolutePath(root) else { return nil }
        if let offset = exactByteRelativeOffset(candidate, within: root) {
            return String(decoding: candidate.utf8.dropFirst(offset), as: UTF8.self)
        }
        guard
              let candidateComponents = posixPathComponents(candidate),
              let rootComponents = posixPathComponents(root),
              rootComponents.count <= candidateComponents.count,
              zip(rootComponents, candidateComponents).allSatisfy({ $0.0 == $0.1 }) else { return nil }
        return candidateComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Allocation-free common path for descriptor/FSEvent strings whose filesystem spelling is
    /// already byte-identical. Canonical NFC/NFD variants fall through to component comparison.
    private static func exactByteRelativeOffset(_ candidate: String, within root: String) -> Int? {
        let candidateBytes = candidate.utf8
        let rootBytes = root.utf8
        var rootEnd = rootBytes.endIndex
        while rootEnd != rootBytes.startIndex {
            let last = rootBytes.index(before: rootEnd)
            guard rootBytes[last] == 0x2F, last != rootBytes.startIndex else { break }
            rootEnd = last
        }

        var candidateIndex = candidateBytes.startIndex
        var rootIndex = rootBytes.startIndex
        var consumed = 0
        while rootIndex != rootEnd {
            guard candidateIndex != candidateBytes.endIndex,
                  rootBytes[rootIndex] == candidateBytes[candidateIndex] else { return nil }
            rootBytes.formIndex(after: &rootIndex)
            candidateBytes.formIndex(after: &candidateIndex)
            consumed += 1
        }

        let normalizedRootIsSlash = consumed == 1 && rootBytes.first == 0x2F
        if candidateIndex == candidateBytes.endIndex { return consumed }
        if !normalizedRootIsSlash {
            guard candidateBytes[candidateIndex] == 0x2F else { return nil }
        }
        while candidateIndex != candidateBytes.endIndex,
              candidateBytes[candidateIndex] == 0x2F {
            candidateBytes.formIndex(after: &candidateIndex)
            consumed += 1
        }
        return consumed
    }

    /// Display an absolute path relative to a validated home directory. This shares containment
    /// semantics with the crawler, including home `/`, slash+combining input, and NFC/NFD equality.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        guard let relative = relativePath(path, within: home) else { return path }
        let wantsTrailingSlash = path.utf8.count > 1 && path.utf8.last == 0x2F
        let normalizedRelative = trimmingTrailingPathSlashes(relative)
        guard !normalizedRelative.isEmpty else { return wantsTrailingSlash ? "~/" : "~" }
        return "~/" + normalizedRelative + (wantsTrailingSlash ? "/" : "")
    }

    /// Split a bounded POSIX path on slash bytes, omitting empty components. This deliberately does
    /// not use `String.split(separator: "/")`, whose Character semantics can miss a slash followed
    /// by a combining scalar. Absolute and relative bounded suffixes are both accepted.
    public static func posixPathComponents(
        _ value: String,
        maxUTF8Bytes: Int = maxPathUTF8Bytes
    ) -> [String]? {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return nil }
        var result: [String] = []
        var component: [UInt8] = []
        for byte in value.utf8 {
            if byte == 0 { return nil }
            if byte == 0x2F {
                if !component.isEmpty {
                    result.append(String(decoding: component, as: UTF8.self))
                    component.removeAll(keepingCapacity: true)
                }
            } else {
                component.append(byte)
            }
        }
        if !component.isEmpty { result.append(String(decoding: component, as: UTF8.self)) }
        return result
    }

    public static func posixPathComponentCount(
        _ value: String,
        maxUTF8Bytes: Int = maxPathUTF8Bytes
    ) -> Int? {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return nil }
        var count = 0
        var inComponent = false
        for byte in value.utf8 {
            if byte == 0 { return nil }
            if byte == 0x2F {
                inComponent = false
            } else if !inComponent {
                count += 1
                inComponent = true
            }
        }
        return count
    }

    /// Validate an absolute POSIX path without allocating `split` components. Empty components from
    /// repeated slashes remain harmless, but literal `.` / `..`, NUL, and an oversized input fail.
    public static func isSafeAbsolutePath(_ value: String, maxUTF8Bytes: Int = maxPathUTF8Bytes) -> Bool {
        guard utf8Fits(value, maxBytes: maxUTF8Bytes) else { return false }
        var iterator = value.utf8.makeIterator()
        guard iterator.next() == 0x2F else { return false }
        var componentBytes = 0
        var onlyDots = true
        while let byte = iterator.next() {
            if byte == 0 { return false }
            if byte == 0x2F {
                if onlyDots && (componentBytes == 1 || componentBytes == 2) { return false }
                componentBytes = 0
                onlyDots = true
            } else {
                componentBytes += 1
                if byte != 0x2E { onlyDots = false }
            }
        }
        return !(onlyDots && (componentBytes == 1 || componentBytes == 2))
    }

    /// A conservative upper bound for the bytes needed to encode one JSON string value, excluding
    /// its surrounding quotes. ASCII stays close to its real encoded size instead of applying a
    /// blanket six-times multiplier, while controls and non-ASCII scalars are costed as their longest
    /// standards-compliant escape form. Arithmetic saturates so callers can fail closed.
    public static func jsonEscapedStringByteUpperBound(_ value: String) -> Int {
        var total = 0
        for scalar in value.unicodeScalars {
            let width: Int
            switch scalar.value {
            case 0...0x1F:
                width = 6 // \u00XX (also covers the shorter named escapes)
            case 0x22, 0x2F, 0x5C:
                width = 2 // quote, optional escaped slash, backslash
            case 0...0x7F:
                width = 1
            case 0...0xFFFF:
                width = 6 // raw UTF-8 is shorter; \uXXXX is the conservative form
            default:
                width = 12 // a UTF-16 surrogate pair: \uXXXX\uXXXX
            }
            let (next, overflow) = total.addingReportingOverflow(width)
            if overflow { return Int.max }
            total = next
        }
        return total
    }
}
