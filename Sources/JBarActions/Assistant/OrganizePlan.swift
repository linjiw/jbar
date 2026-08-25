import Foundation

/// One local, opaque file reference supplied to the planner. Paths are intentionally absent.
public struct OrganizeCandidate: Equatable, Sendable {
    public static let maximumNameUTF8Bytes = 1_024
    // JSON numbers are represented as Double by the app-server payload layer. Keep exact integer
    // semantics while allowing files far larger than the organize workflow will realistically use.
    public static let maximumSizeBytes: Int64 = 1_125_899_906_842_624 // 2^50 (1 PiB)

    public let id: UUID
    public let name: String
    public let sizeBytes: Int64
    public let modifiedAt: Date?

    public init(id: UUID, name: String, sizeBytes: Int64, modifiedAt: Date?) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    var jsonValue: JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "name": .string(name),
            "sizeBytes": .number(Double(sizeBytes)),
            "modifiedAt": modifiedAt.map { date in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return .string(formatter.string(from: date))
            } ?? .null,
        ])
    }
}

/// A model-authored operation can refer only to a JBar-created source ID and direct-child names.
public struct OrganizePlanOperation: Equatable, Sendable {
    public let sourceID: UUID
    public let destinationFolderName: String?
    public let newName: String?

    public init(sourceID: UUID, destinationFolderName: String?, newName: String?) {
        self.sourceID = sourceID
        self.destinationFolderName = destinationFolderName
        self.newName = newName
    }
}

public struct OrganizePlan: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumOperations = 500
    public static let maximumSummaryCharacters = 280
    public static let maximumNameCharacters = 255
    public static let maximumNameUTF8Bytes = 1_024

    public let scopeID: String
    public let summary: String
    public let operations: [OrganizePlanOperation]

    public init(scopeID: String, summary: String, operations: [OrganizePlanOperation]) {
        self.scopeID = scopeID
        self.summary = summary
        self.operations = operations
    }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "schemaVersion": .object(["type": .string("integer"), "const": .number(1)]),
            "scopeID": .object(["type": .string("string"), "maxLength": .number(128)]),
            "summary": .object([
                "type": .string("string"),
                "maxLength": .number(Double(maximumSummaryCharacters)),
            ]),
            "operations": .object([
                "type": .string("array"),
                "maxItems": .number(Double(maximumOperations)),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sourceID": .object(["type": .string("string"), "format": .string("uuid")]),
                        "destinationFolderName": nullableNameSchema,
                        "newName": nullableNameSchema,
                    ]),
                    "required": .array([
                        .string("sourceID"), .string("destinationFolderName"), .string("newName"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([
            .string("schemaVersion"), .string("scopeID"), .string("summary"), .string("operations"),
        ]),
        "additionalProperties": .bool(false),
    ])

    public static func decode(_ text: String, expectedScopeID: String,
                              allowedSourceIDs: Set<UUID>) throws -> OrganizePlan {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OrganizePlanValidationError.invalidJSON
        }
        return try decode(value, expectedScopeID: expectedScopeID,
                          allowedSourceIDs: allowedSourceIDs)
    }

    public static func decode(_ value: JSONValue, expectedScopeID: String,
                              allowedSourceIDs: Set<UUID>) throws -> OrganizePlan {
        guard let object = value.objectValue,
              Set(object.keys) == Set(["schemaVersion", "scopeID", "summary", "operations"]),
              object["schemaVersion"]?.intValue == schemaVersion else {
            throw OrganizePlanValidationError.unexpectedFields
        }
        guard object["scopeID"]?.stringValue == expectedScopeID else {
            throw OrganizePlanValidationError.scopeMismatch
        }
        guard let summary = object["summary"]?.stringValue,
              summary.count <= maximumSummaryCharacters,
              validText(summary, allowEmpty: true),
              let rawOperations = object["operations"]?.arrayValue,
              rawOperations.count <= maximumOperations else {
            throw OrganizePlanValidationError.invalidField
        }

        var operations: [OrganizePlanOperation] = []
        operations.reserveCapacity(rawOperations.count)
        var seen = Set<UUID>()
        for raw in rawOperations {
            guard let operation = raw.objectValue,
                  Set(operation.keys) == Set(["sourceID", "destinationFolderName", "newName"]),
                  let rawID = operation["sourceID"]?.stringValue,
                  let sourceID = UUID(uuidString: rawID),
                  allowedSourceIDs.contains(sourceID), seen.insert(sourceID).inserted else {
                throw OrganizePlanValidationError.unknownOrDuplicateSource
            }
            let folder = try optionalName(operation["destinationFolderName"])
            let newName = try optionalName(operation["newName"])
            guard folder != nil || newName != nil else {
                throw OrganizePlanValidationError.invalidField
            }
            operations.append(OrganizePlanOperation(sourceID: sourceID,
                                                     destinationFolderName: folder,
                                                     newName: newName))
        }
        return OrganizePlan(scopeID: expectedScopeID, summary: summary, operations: operations)
    }

    private static let nullableNameSchema: JSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
        "maxLength": .number(Double(maximumNameCharacters)),
    ])

    private static func optionalName(_ value: JSONValue?) throws -> String? {
        if value == .null { return nil }
        guard let name = value?.stringValue, validName(name) else {
            throw OrganizePlanValidationError.invalidName
        }
        return name
    }

    public static func validName(_ name: String) -> Bool {
        guard validText(name, allowEmpty: false), name.count <= maximumNameCharacters,
              name.utf8.count <= maximumNameUTF8Bytes,
              name != ".", name != "..", name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains(":") else { return false }
        return true
    }

    private static func validText(_ value: String, allowEmpty: Bool) -> Bool {
        guard allowEmpty || !value.isEmpty else { return false }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.properties.isDefaultIgnorableCodePoint
        }
    }
}

public enum OrganizePlanValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedFields
    case scopeMismatch
    case invalidField
    case invalidName
    case unknownOrDuplicateSource
}

extension OrganizePlanValidationError: LocalizedError {
    public var errorDescription: String? {
        "Codex did not return a safe, compatible organize plan. No file was changed."
    }
}
