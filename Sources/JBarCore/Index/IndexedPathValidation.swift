/// Shared allocation-free validation of indexed item paths. Snapshot bytes and module-internal
/// raw stores remain untrusted: validate strict UTF-8 before reusing their path metadata.
enum IndexedPathValidation {
    static func completeItemPathFits(directoryPathUTF8Bytes: Int,
                                     directoryEndsInSlash: Bool,
                                     storedName: ArraySlice<UInt8>, flagsRaw: UInt8) -> Bool {
        guard directoryPathUTF8Bytes > 0,
              directoryPathUTF8Bytes <= SafetyLimits.maxPathUTF8Bytes,
              isSafePathComponent(storedName, maxBytes: SafetyLimits.maxNameUTF8Bytes) else {
            return false
        }
        let needsAppSuffix = flagsRaw & ItemFlags.appBundle.rawValue != 0
            && !hasAppSuffix(storedName)
        let fileNameBytes = IndexStoreLimits.adding(storedName.count, needsAppSuffix ? 4 : 0)
        guard fileNameBytes <= SafetyLimits.maxNameUTF8Bytes else { return false }
        return IndexStoreLimits.adding(
            IndexStoreLimits.adding(directoryPathUTF8Bytes, directoryEndsInSlash ? 0 : 1),
            fileNameBytes
        ) <= SafetyLimits.maxPathUTF8Bytes
    }

    /// The same POSIX component contract as SafetyLimits, plus strict UTF-8 validity. The single
    /// byte pass rejects overlong forms, surrogate scalars, out-of-range scalars, NUL and slash.
    static func isSafePathComponent(_ bytes: ArraySlice<UInt8>, maxBytes: Int) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maxBytes else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            if buffer.count <= 2 && buffer.allSatisfy({ $0 == 0x2E }) { return false }
            var index = 0
            while index < buffer.count {
                let lead = buffer[index]
                index += 1
                switch lead {
                case 0x01...0x2E, 0x30...0x7F:
                    continue
                case 0xC2...0xDF:
                    guard index < buffer.count, (0x80...0xBF).contains(buffer[index]) else { return false }
                    index += 1
                case 0xE0...0xEF:
                    guard buffer.count - index >= 2 else { return false }
                    let second = buffer[index], third = buffer[index + 1]
                    let secondRange: ClosedRange<UInt8> = lead == 0xE0 ? 0xA0...0xBF
                        : lead == 0xED ? 0x80...0x9F : 0x80...0xBF
                    guard secondRange.contains(second), (0x80...0xBF).contains(third) else { return false }
                    index += 2
                case 0xF0...0xF4:
                    guard buffer.count - index >= 3 else { return false }
                    let second = buffer[index], third = buffer[index + 1], fourth = buffer[index + 2]
                    let secondRange: ClosedRange<UInt8> = lead == 0xF0 ? 0x90...0xBF
                        : lead == 0xF4 ? 0x80...0x8F : 0x80...0xBF
                    guard secondRange.contains(second), (0x80...0xBF).contains(third),
                          (0x80...0xBF).contains(fourth) else { return false }
                    index += 3
                default:
                    return false
                }
            }
            return true
        }
    }

    private static func hasAppSuffix(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 4 else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            let offset = buffer.count - 4
            func lowerASCII(_ byte: UInt8) -> UInt8 {
                (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            }
            return buffer[offset] == 0x2E && lowerASCII(buffer[offset + 1]) == 0x61
                && lowerASCII(buffer[offset + 2]) == 0x70 && lowerASCII(buffer[offset + 3]) == 0x70
        }
    }
}
