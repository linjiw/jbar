import Foundation

/// A scope is created by JBar and echoed by the planner. The model never creates or expands one.
public struct ScopeID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let indexedFiles = ScopeID(rawValue: "indexed-files")
}

public enum SearchPlanKind: String, Codable, CaseIterable, Sendable {
    case app
    case folder
    case document
    case image
    case video
    case audio
    case code
    case archive
    case other
}

public enum SearchPlanSort: String, Codable, CaseIterable, Sendable {
    case relevance
    case modifiedDescending
    case nameAscending
}

/// The only model-authored value that can cross into local file search. Every field is bounded and
/// the wire decoder rejects unknown keys so a newer or malicious plan cannot silently gain meaning.
public struct SearchPlan: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumNameTerms = 6
    public static let maximumExtensions = 8
    public static let maximumTermCharacters = 128
    public static let maximumTermUTF8Bytes = 512
    public static let maximumResults = 40
    public static let maximumSizeBytes: Int64 = 1_125_899_906_842_624 // 1 PiB

    public let scopeID: ScopeID
    public let nameTerms: [String]
    public let extensions: [String]
    public let kinds: [SearchPlanKind]
    public let modifiedAfter: Date?
    public let modifiedBefore: Date?
    public let minimumSizeBytes: Int64?
    public let maximumSizeBytes: Int64?
    public let sort: SearchPlanSort
    public let limit: Int
    public let needsCandidateRerank: Bool

    public init(scopeID: ScopeID, nameTerms: [String], extensions: [String],
                kinds: [SearchPlanKind], modifiedAfter: Date? = nil,
                modifiedBefore: Date? = nil, minimumSizeBytes: Int64? = nil,
                maximumSizeBytes: Int64? = nil, sort: SearchPlanSort = .relevance,
                limit: Int = SearchPlan.maximumResults, needsCandidateRerank: Bool = false) {
        self.scopeID = scopeID
        self.nameTerms = nameTerms
        self.extensions = extensions
        self.kinds = kinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.minimumSizeBytes = minimumSizeBytes
        self.maximumSizeBytes = maximumSizeBytes
        self.sort = sort
        self.limit = limit
        self.needsCandidateRerank = needsCandidateRerank
    }

    /// JSON Schema supplied to `turn/start.outputSchema`. Nullable fields are required so absence and
    /// `null` cannot acquire different meanings across model/runtime versions.
    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "schemaVersion": .object(["type": .string("integer"), "const": .number(1)]),
            "scopeID": .object(["type": .string("string"), "const": .string(ScopeID.indexedFiles.rawValue)]),
            "nameTerms": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "maxLength": .number(Double(maximumTermCharacters))]),
                "maxItems": .number(Double(maximumNameTerms)),
            ]),
            "extensions": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "pattern": .string("^[a-z0-9]{1,8}$")]),
                "maxItems": .number(Double(maximumExtensions)),
            ]),
            "kinds": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"),
                                   "enum": .array(SearchPlanKind.allCases.map { .string($0.rawValue) })]),
                "maxItems": .number(Double(SearchPlanKind.allCases.count)),
            ]),
            "modifiedAfter": nullableDateSchema,
            "modifiedBefore": nullableDateSchema,
            "minimumSizeBytes": nullableSizeSchema,
            "maximumSizeBytes": nullableSizeSchema,
            "sort": .object(["type": .string("string"),
                             "enum": .array(SearchPlanSort.allCases.map { .string($0.rawValue) })]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1),
                              "maximum": .number(Double(maximumResults))]),
            "needsCandidateRerank": .object(["type": .string("boolean")]),
        ]),
        "required": .array(wireKeys.sorted().map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])

    public static func decode(_ text: String, expectedScopeID: ScopeID) throws -> SearchPlan {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw SearchPlanValidationError.invalidJSON
        }
        return try decode(value, expectedScopeID: expectedScopeID)
    }

    public static func decode(_ value: JSONValue, expectedScopeID: ScopeID) throws -> SearchPlan {
        guard let object = value.objectValue else { throw SearchPlanValidationError.invalidJSON }
        guard Set(object.keys) == wireKeys else { throw SearchPlanValidationError.unexpectedFields }
        guard object["schemaVersion"]?.intValue == schemaVersion else {
            throw SearchPlanValidationError.invalidField
        }
        guard let rawScope = object["scopeID"]?.stringValue,
              rawScope == expectedScopeID.rawValue else {
            throw SearchPlanValidationError.scopeMismatch
        }

        let nameTerms = try stringArray(object["nameTerms"], maximumCount: maximumNameTerms)
        guard nameTerms.allSatisfy(validTerm), Set(nameTerms).count == nameTerms.count else {
            throw SearchPlanValidationError.invalidField
        }
        let extensions = try stringArray(object["extensions"], maximumCount: maximumExtensions)
        guard extensions.allSatisfy(validExtension), Set(extensions).count == extensions.count else {
            throw SearchPlanValidationError.invalidField
        }
        let kindStrings = try stringArray(object["kinds"], maximumCount: SearchPlanKind.allCases.count)
        let kinds = kindStrings.compactMap(SearchPlanKind.init(rawValue:))
        guard kinds.count == kindStrings.count, Set(kindStrings).count == kindStrings.count else {
            throw SearchPlanValidationError.invalidField
        }

        let modifiedAfter = try optionalDate(object["modifiedAfter"])
        let modifiedBefore = try optionalDate(object["modifiedBefore"])
        guard modifiedAfter == nil || modifiedBefore == nil || modifiedAfter! <= modifiedBefore! else {
            throw SearchPlanValidationError.invalidRange
        }
        let minimumSize = try optionalInt64(object["minimumSizeBytes"])
        let maximumSize = try optionalInt64(object["maximumSizeBytes"])
        guard [minimumSize, maximumSize].compactMap({ $0 }).allSatisfy({
            $0 >= 0 && $0 <= Self.maximumSizeBytes
        }), minimumSize == nil || maximumSize == nil || minimumSize! <= maximumSize! else {
            throw SearchPlanValidationError.invalidRange
        }
        guard let rawSort = object["sort"]?.stringValue,
              let sort = SearchPlanSort(rawValue: rawSort),
              let limit = object["limit"]?.intValue, (1...maximumResults).contains(limit),
              let needsCandidateRerank = object["needsCandidateRerank"]?.boolValue else {
            throw SearchPlanValidationError.invalidField
        }

        return SearchPlan(scopeID: expectedScopeID, nameTerms: nameTerms, extensions: extensions,
                          kinds: kinds, modifiedAfter: modifiedAfter, modifiedBefore: modifiedBefore,
                          minimumSizeBytes: minimumSize, maximumSizeBytes: maximumSize, sort: sort,
                          limit: limit, needsCandidateRerank: needsCandidateRerank)
    }

    private static let wireKeys: Set<String> = [
        "schemaVersion", "scopeID", "nameTerms", "extensions", "kinds", "modifiedAfter",
        "modifiedBefore", "minimumSizeBytes", "maximumSizeBytes", "sort", "limit",
        "needsCandidateRerank",
    ]

    private static let nullableDateSchema: JSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
        "format": .string("date-time"),
    ])

    private static let nullableSizeSchema: JSONValue = .object([
        "type": .array([.string("integer"), .string("null")]),
        "minimum": .number(0),
        "maximum": .number(Double(maximumSizeBytes)),
    ])

    private static func stringArray(_ value: JSONValue?, maximumCount: Int) throws -> [String] {
        guard let array = value?.arrayValue, array.count <= maximumCount else {
            throw SearchPlanValidationError.invalidField
        }
        let strings = array.compactMap(\.stringValue)
        guard strings.count == array.count else { throw SearchPlanValidationError.invalidField }
        return strings
    }

    private static func validTerm(_ term: String) -> Bool {
        guard !term.isEmpty, term.count <= maximumTermCharacters,
              term.utf8.count <= maximumTermUTF8Bytes else { return false }
        return !term.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\"
        }
    }

    private static func validExtension(_ value: String) -> Bool {
        guard (1...8).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
        }
    }

    private static func optionalDate(_ value: JSONValue?) throws -> Date? {
        if value == .null { return nil }
        guard let raw = value?.stringValue else { throw SearchPlanValidationError.invalidField }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let date = wholeSeconds.date(from: raw) else {
            throw SearchPlanValidationError.invalidField
        }
        return date
    }

    private static func optionalInt64(_ value: JSONValue?) throws -> Int64? {
        if value == .null { return nil }
        guard case .number(let number) = value, number.isFinite, number.rounded() == number,
              number >= Double(Int64.min), number <= Double(Int64.max) else {
            throw SearchPlanValidationError.invalidField
        }
        return Int64(number)
    }
}

public enum SearchPlanValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedFields
    case scopeMismatch
    case invalidField
    case invalidRange
}

extension SearchPlanValidationError: LocalizedError {
    public var errorDescription: String? {
        "Codex did not return a safe, compatible search plan. No local search was run."
    }
}
