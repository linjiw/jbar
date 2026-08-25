import XCTest
@testable import JBarActions

final class SearchPlanTests: XCTestCase {
    func testValidPlanDecodesAllBoundedFields() throws {
        let value = plan([
            "nameTerms": .array([.string("预算"), .string("draft")]),
            "extensions": .array([.string("pdf")]),
            "kinds": .array([.string("document")]),
            "modifiedAfter": .string("2026-08-17T00:00:00Z"),
            "modifiedBefore": .string("2026-08-24T23:59:59Z"),
            "minimumSizeBytes": .number(1_024),
            "maximumSizeBytes": .number(8_192),
            "sort": .string("modifiedDescending"),
            "limit": .number(3),
        ])

        let decoded = try SearchPlan.decode(value, expectedScopeID: .indexedFiles)

        XCTAssertEqual(decoded.nameTerms, ["预算", "draft"])
        XCTAssertEqual(decoded.extensions, ["pdf"])
        XCTAssertEqual(decoded.kinds, [.document])
        XCTAssertEqual(decoded.minimumSizeBytes, 1_024)
        XCTAssertEqual(decoded.maximumSizeBytes, 8_192)
        XCTAssertEqual(decoded.sort, .modifiedDescending)
        XCTAssertEqual(decoded.limit, 3)
        XCTAssertFalse(decoded.needsCandidateRerank)
        XCTAssertNotNil(decoded.modifiedAfter)
        XCTAssertNotNil(decoded.modifiedBefore)
    }

    func testDecoderRejectsUnknownMissingAndWrongScopeFields() {
        var unknown = plan().objectValue!
        unknown["command"] = .string("find ~")
        XCTAssertThrowsError(try SearchPlan.decode(.object(unknown), expectedScopeID: .indexedFiles)) {
            XCTAssertEqual($0 as? SearchPlanValidationError, .unexpectedFields)
        }

        var missing = plan().objectValue!
        missing.removeValue(forKey: "limit")
        XCTAssertThrowsError(try SearchPlan.decode(.object(missing), expectedScopeID: .indexedFiles)) {
            XCTAssertEqual($0 as? SearchPlanValidationError, .unexpectedFields)
        }

        var escaped = plan().objectValue!
        escaped["scopeID"] = .string("home")
        XCTAssertThrowsError(try SearchPlan.decode(.object(escaped), expectedScopeID: .indexedFiles)) {
            XCTAssertEqual($0 as? SearchPlanValidationError, .scopeMismatch)
        }
    }

    func testDecoderRejectsTraversalControlsDuplicatesAndInvertedRanges() {
        XCTAssertThrowsError(try SearchPlan.decode(plan([
            "nameTerms": .array([.string("../Secrets")]),
        ]), expectedScopeID: .indexedFiles))

        XCTAssertThrowsError(try SearchPlan.decode(plan([
            "extensions": .array([.string("pdf"), .string("pdf")]),
        ]), expectedScopeID: .indexedFiles))

        XCTAssertThrowsError(try SearchPlan.decode(plan([
            "modifiedAfter": .string("2026-08-24T00:00:00Z"),
            "modifiedBefore": .string("2026-08-17T00:00:00Z"),
        ]), expectedScopeID: .indexedFiles)) {
            XCTAssertEqual($0 as? SearchPlanValidationError, .invalidRange)
        }

        XCTAssertThrowsError(try SearchPlan.decode(plan([
            "minimumSizeBytes": .number(9_000),
            "maximumSizeBytes": .number(1_000),
        ]), expectedScopeID: .indexedFiles)) {
            XCTAssertEqual($0 as? SearchPlanValidationError, .invalidRange)
        }
    }

    func testOutputSchemaRequiresEveryFieldAndForbidsAdditionalProperties() throws {
        XCTAssertEqual(SearchPlan.outputSchema["additionalProperties"], .bool(false))
        let required = try XCTUnwrap(SearchPlan.outputSchema["required"]?.arrayValue)
        XCTAssertEqual(required.count, 12)
        XCTAssertTrue(required.contains(.string("scopeID")))
        XCTAssertTrue(required.contains(.string("needsCandidateRerank")))
        XCTAssertEqual(SearchPlan.outputSchema["properties"]?["scopeID"]?["const"],
                       .string(ScopeID.indexedFiles.rawValue))
    }

    private func plan(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "schemaVersion": .number(1),
            "scopeID": .string(ScopeID.indexedFiles.rawValue),
            "nameTerms": .array([]),
            "extensions": .array([]),
            "kinds": .array([]),
            "modifiedAfter": .null,
            "modifiedBefore": .null,
            "minimumSizeBytes": .null,
            "maximumSizeBytes": .null,
            "sort": .string("relevance"),
            "limit": .number(40),
            "needsCandidateRerank": .bool(false),
        ]
        for (key, value) in overrides { object[key] = value }
        return .object(object)
    }
}
