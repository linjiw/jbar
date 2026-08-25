import XCTest
@testable import JBarActions

final class OrganizePlanTests: XCTestCase {
    func testValidPlanUsesOnlyAllowedOpaqueIDs() throws {
        let first = UUID()
        let second = UUID()
        let value = planValue(scopeID: "folder-scope", operations: [
            operation(first, folder: .string("2026-08 Receipts"), newName: .null),
            operation(second, folder: .null, newName: .string("budget-final.pdf")),
        ])
        let plan = try OrganizePlan.decode(value, expectedScopeID: "folder-scope",
                                           allowedSourceIDs: [first, second])
        XCTAssertEqual(plan.operations.count, 2)
        XCTAssertEqual(plan.operations[0].destinationFolderName, "2026-08 Receipts")
        XCTAssertNil(plan.operations[0].newName)
        XCTAssertNil(plan.operations[1].destinationFolderName)
        XCTAssertEqual(plan.operations[1].newName, "budget-final.pdf")
    }

    func testDecoderRejectsUnknownDuplicateAndEscapingSources() {
        let allowed = UUID()
        XCTAssertThrowsError(try OrganizePlan.decode(
            planValue(scopeID: "scope", operations: [operation(UUID(), folder: .string("Receipts"))]),
            expectedScopeID: "scope", allowedSourceIDs: [allowed]
        )) { XCTAssertEqual($0 as? OrganizePlanValidationError, .unknownOrDuplicateSource) }

        XCTAssertThrowsError(try OrganizePlan.decode(
            planValue(scopeID: "scope", operations: [
                operation(allowed, folder: .string("Receipts")),
                operation(allowed, folder: .string("Other")),
            ]), expectedScopeID: "scope", allowedSourceIDs: [allowed]
        )) { XCTAssertEqual($0 as? OrganizePlanValidationError, .unknownOrDuplicateSource) }

        for name in ["../escape", "nested/path", ".hidden", "folder​", " trailing"] {
            XCTAssertThrowsError(try OrganizePlan.decode(
                planValue(scopeID: "scope", operations: [operation(allowed, folder: .string(name))]),
                expectedScopeID: "scope", allowedSourceIDs: [allowed]
            )) { XCTAssertEqual($0 as? OrganizePlanValidationError, .invalidName) }
        }
    }

    func testDecoderRejectsWrongScopeUnknownFieldsAndNoOp() {
        let id = UUID()
        XCTAssertThrowsError(try OrganizePlan.decode(
            planValue(scopeID: "other", operations: [operation(id, folder: .string("Receipts"))]),
            expectedScopeID: "scope", allowedSourceIDs: [id]
        )) { XCTAssertEqual($0 as? OrganizePlanValidationError, .scopeMismatch) }

        var extra = planValue(scopeID: "scope", operations: []).objectValue ?? [:]
        extra["path"] = .string("/Users/example")
        XCTAssertThrowsError(try OrganizePlan.decode(.object(extra), expectedScopeID: "scope",
                                                     allowedSourceIDs: [id]))

        XCTAssertThrowsError(try OrganizePlan.decode(
            planValue(scopeID: "scope", operations: [operation(id, folder: .null, newName: .null)]),
            expectedScopeID: "scope", allowedSourceIDs: [id]
        )) { XCTAssertEqual($0 as? OrganizePlanValidationError, .invalidField) }
    }

    func testSchemaIsClosedAndBounded() throws {
        let root = try XCTUnwrap(OrganizePlan.outputSchema.objectValue)
        XCTAssertEqual(root["additionalProperties"], .bool(false))
        XCTAssertEqual(root["properties"]?["operations"]?["maxItems"]?.intValue,
                       OrganizePlan.maximumOperations)
        XCTAssertEqual(root["properties"]?["operations"]?["items"]?["additionalProperties"],
                       .bool(false))
    }

    private func planValue(scopeID: String, operations: [JSONValue]) -> JSONValue {
        .object([
            "schemaVersion": .number(1),
            "scopeID": .string(scopeID),
            "summary": .string("Group receipts by month"),
            "operations": .array(operations),
        ])
    }

    private func operation(_ id: UUID, folder: JSONValue,
                           newName: JSONValue = .null) -> JSONValue {
        .object([
            "sourceID": .string(id.uuidString),
            "destinationFolderName": folder,
            "newName": newName,
        ])
    }
}
