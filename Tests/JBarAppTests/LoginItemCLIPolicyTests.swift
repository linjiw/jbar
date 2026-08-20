import XCTest
@testable import JBarApp

final class LoginItemCLIPolicyTests: XCTestCase {
    private final class FakeService {
        var statuses: [LoginItem.State]
        var statusReadCount = 0
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(
            _ statuses: [LoginItem.State],
            registerError: Error? = nil,
            unregisterError: Error? = nil
        ) {
            self.statuses = statuses
            self.registerError = registerError
            self.unregisterError = unregisterError
        }

        func readStatus() -> LoginItem.State {
            defer { statusReadCount += 1 }
            return statuses[min(statusReadCount, statuses.count - 1)]
        }

        func register() throws {
            registerCallCount += 1
            if let registerError { throw registerError }
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let unregisterError { throw unregisterError }
        }
    }

    private func simulatedError() -> NSError {
        NSError(domain: "JBarAppTests.Simulated", code: 73)
    }

    private func run(_ fake: FakeService) -> CLI.LoginItemUnregisterResult {
        CLI.unregisterLoginItem(
            status: { fake.readStatus() },
            unregister: { try fake.unregister() }
        )
    }

    private func runUI(_ fake: FakeService) -> String? {
        LoginItem.unregister(
            status: { fake.readStatus() },
            performUnregister: { try fake.unregister() }
        )
    }

    private func runRegisterPolicy(_ fake: FakeService) -> LoginItem.RegisterOutcome {
        LoginItem.ensureRegistered(
            status: { fake.readStatus() },
            performRegister: { try fake.register() }
        )
    }

    private func runRegisterUI(_ fake: FakeService) -> String? {
        LoginItem.register(
            status: { fake.readStatus() },
            performRegister: { try fake.register() }
        )
    }

    func testKnownServiceManagementStatusesMapToPolicyStates() {
        XCTAssertEqual(LoginItem.state(for: .enabled), .enabled)
        XCTAssertEqual(LoginItem.state(for: .notRegistered), .notRegistered)
        XCTAssertEqual(LoginItem.state(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItem.state(for: .notFound), .notFound)
    }

    func testRegistrationPolicyTreatsRegisteredInitialStatesAsSuccessWithoutMutation() {
        for initial in [LoginItem.State.enabled, .requiresApproval] {
            let fake = FakeService([initial])

            XCTAssertEqual(runRegisterPolicy(fake), .alreadyRegistered(initial))
            XCTAssertEqual(fake.statusReadCount, 1, "initial status \(initial)")
            XCTAssertEqual(fake.registerCallCount, 0, "initial status \(initial)")
        }
    }

    func testRegistrationPolicyRefusesAmbiguousInitialStatesWithoutMutation() {
        for initial in [LoginItem.State.notFound, .unknown(81)] {
            let fake = FakeService([initial])

            XCTAssertEqual(runRegisterPolicy(fake), .refused(initial))
            XCTAssertEqual(fake.statusReadCount, 1, "initial status \(initial)")
            XCTAssertEqual(fake.registerCallCount, 0, "initial status \(initial)")
        }
    }

    func testRegistrationPolicyAcceptsBothRegisteredPostStatesAfterOneCall() {
        for terminal in [LoginItem.State.enabled, .requiresApproval] {
            let fake = FakeService([.notRegistered, terminal])

            XCTAssertEqual(
                runRegisterPolicy(fake),
                .registered(from: .notRegistered, to: terminal)
            )
            XCTAssertEqual(fake.statusReadCount, 2, "terminal status \(terminal)")
            XCTAssertEqual(fake.registerCallCount, 1, "terminal status \(terminal)")
        }
    }

    func testRegistrationPolicyRejectsEveryNonRegisteredPostStateAfterNonthrow() {
        let terminals: [LoginItem.State] = [
            .notRegistered, .notFound, .unknown(82),
        ]

        for terminal in terminals {
            let fake = FakeService([.notRegistered, terminal])

            XCTAssertEqual(
                runRegisterPolicy(fake),
                .nonTerminal(from: .notRegistered, to: terminal)
            )
            XCTAssertEqual(fake.statusReadCount, 2, "terminal status \(terminal)")
            XCTAssertEqual(fake.registerCallCount, 1, "terminal status \(terminal)")
        }
    }

    func testRegistrationPolicyAcceptsRegisteredPostStatesAfterThrowAndPreservesDiagnostic() {
        let expectedError = LoginItem.ServiceAPIError(simulatedError())
        for terminal in [LoginItem.State.enabled, .requiresApproval] {
            let fake = FakeService(
                [.notRegistered, terminal], registerError: simulatedError()
            )

            XCTAssertEqual(
                runRegisterPolicy(fake),
                .registeredAfterAPIError(
                    from: .notRegistered, error: expectedError, terminal: terminal
                )
            )
            XCTAssertEqual(fake.statusReadCount, 2, "terminal status \(terminal)")
            XCTAssertEqual(fake.registerCallCount, 1, "terminal status \(terminal)")
        }
    }

    func testRegistrationPolicyRejectsEveryNonRegisteredPostStateAfterThrow() {
        let expectedError = LoginItem.ServiceAPIError(simulatedError())
        let terminals: [LoginItem.State] = [
            .notRegistered, .notFound, .unknown(83),
        ]

        for terminal in terminals {
            let fake = FakeService(
                [.notRegistered, terminal], registerError: simulatedError()
            )

            XCTAssertEqual(
                runRegisterPolicy(fake),
                .apiError(
                    from: .notRegistered, error: expectedError, terminal: terminal
                )
            )
            XCTAssertEqual(fake.statusReadCount, 2, "terminal status \(terminal)")
            XCTAssertEqual(fake.registerCallCount, 1, "terminal status \(terminal)")
        }
    }

    func testRegistrationUIAdapterReturnsNilOnlyForVerifiedRegisteredStates() {
        let cases: [([LoginItem.State], Error?, Int)] = [
            ([.enabled], nil, 0),
            ([.requiresApproval], nil, 0),
            ([.notRegistered, .enabled], nil, 1),
            ([.notRegistered, .requiresApproval], nil, 1),
            ([.notRegistered, .enabled], simulatedError(), 1),
            ([.notRegistered, .requiresApproval], simulatedError(), 1),
        ]

        for (statuses, error, expectedCalls) in cases {
            let fake = FakeService(statuses, registerError: error)

            XCTAssertNil(runRegisterUI(fake), "statuses \(statuses)")
            XCTAssertEqual(fake.statusReadCount, statuses.count, "statuses \(statuses)")
            XCTAssertEqual(fake.registerCallCount, expectedCalls, "statuses \(statuses)")
        }
    }

    func testRegistrationUIAdapterReturnsStableNonlocalizedErrorsForUnverifiedStates() {
        let cases: [([LoginItem.State], Error?, String, Int)] = [
            (
                [.notFound], nil,
                "login item status not found cannot confirm registration", 0
            ),
            (
                [.unknown(84)], nil,
                "login item status unknown(84) cannot confirm registration", 0
            ),
            (
                [.notRegistered, .notRegistered], nil,
                "login item status remained not registered after register", 1
            ),
            (
                [.notRegistered, .notFound], simulatedError(),
                "login item register failed (domain JBarAppTests.Simulated, code 73); terminal status is not found",
                1
            ),
        ]

        for (statuses, error, expectedMessage, expectedCalls) in cases {
            let fake = FakeService(statuses, registerError: error)

            XCTAssertEqual(runRegisterUI(fake), expectedMessage, "statuses \(statuses)")
            XCTAssertEqual(fake.statusReadCount, statuses.count, "statuses \(statuses)")
            XCTAssertEqual(fake.registerCallCount, expectedCalls, "statuses \(statuses)")
        }
    }

    func testAlreadyNotRegisteredIsCleanSuccessWithoutMutation() {
        let fake = FakeService([.notRegistered])

        XCTAssertEqual(
            run(fake),
            .init(
                exitCode: 0,
                standardOutput: ["login item status before: not registered"],
                standardError: []
            )
        )
        XCTAssertEqual(fake.statusReadCount, 1)
        XCTAssertEqual(fake.unregisterCallCount, 0)
    }

    func testEnabledUnregistersAndRequiresNotRegisteredPostcondition() {
        let fake = FakeService([.enabled, .notRegistered])

        XCTAssertEqual(
            run(fake),
            .init(
                exitCode: 0,
                standardOutput: [
                    "login item status before: enabled",
                    "login item status after: not registered",
                ],
                standardError: []
            )
        )
        XCTAssertEqual(fake.statusReadCount, 2)
        XCTAssertEqual(fake.unregisterCallCount, 1)
    }

    func testRequiresApprovalAlsoUnregistersAndCanSucceed() {
        let fake = FakeService([.requiresApproval, .notRegistered])

        XCTAssertEqual(
            run(fake),
            .init(
                exitCode: 0,
                standardOutput: [
                    "login item status before: requires approval",
                    "login item status after: not registered",
                ],
                standardError: []
            )
        )
        XCTAssertEqual(fake.statusReadCount, 2)
        XCTAssertEqual(fake.unregisterCallCount, 1)
    }

    func testNotFoundBeforeUnregisterFailsClosedWithoutMutation() {
        let fake = FakeService([.notFound])

        XCTAssertEqual(
            run(fake),
            .init(
                exitCode: 1,
                standardOutput: ["login item status before: not found"],
                standardError: [
                    "unregister failed: status not found is not proof that the login item is unregistered",
                ]
            )
        )
        XCTAssertEqual(fake.statusReadCount, 1)
        XCTAssertEqual(fake.unregisterCallCount, 0)
    }

    func testUnknownBeforeUnregisterFailsClosedWithoutMutation() {
        let fake = FakeService([.unknown(91)])

        XCTAssertEqual(
            run(fake),
            .init(
                exitCode: 1,
                standardOutput: ["login item status before: unknown(91)"],
                standardError: ["unregister failed: unsupported login item status unknown(91)"]
            )
        )
        XCTAssertEqual(fake.statusReadCount, 1)
        XCTAssertEqual(fake.unregisterCallCount, 0)
    }

    func testThrownUnregisterErrorCanSucceedOnlyWhenPostStatusIsNotRegistered() {
        let cases: [(LoginItem.State, String)] = [
            (.enabled, "enabled"),
            (.requiresApproval, "requires approval"),
        ]

        for (beforeStatus, description) in cases {
            let fake = FakeService(
                [beforeStatus, .notRegistered], unregisterError: simulatedError()
            )

            XCTAssertEqual(
                run(fake),
                .init(
                    exitCode: 0,
                    standardOutput: [
                        "login item status before: \(description)",
                        "login item status after API error: not registered",
                    ],
                    standardError: [
                        "unregister warning: API returned domain=JBarAppTests.Simulated code=73, but terminal status is not registered",
                    ]
                ),
                "before status \(description)"
            )
            XCTAssertEqual(fake.statusReadCount, 2, "before status \(description)")
            XCTAssertEqual(fake.unregisterCallCount, 1, "before status \(description)")
        }
    }

    func testThrownUnregisterErrorFailsForEveryNonTerminalPostStatus() {
        let cases: [(LoginItem.State, String)] = [
            (.enabled, "enabled"),
            (.requiresApproval, "requires approval"),
            (.notFound, "not found"),
            (.unknown(93), "unknown(93)"),
        ]

        for (postStatus, description) in cases {
            let fake = FakeService([.enabled, postStatus], unregisterError: simulatedError())

            XCTAssertEqual(
                run(fake),
                .init(
                    exitCode: 1,
                    standardOutput: [
                        "login item status before: enabled",
                        "login item status after API error: \(description)",
                    ],
                    standardError: [
                        "unregister failed: domain=JBarAppTests.Simulated code=73; terminal status is \(description)",
                    ]
                ),
                "post status \(description)"
            )
            XCTAssertEqual(fake.statusReadCount, 2, "post status \(description)")
            XCTAssertEqual(fake.unregisterCallCount, 1, "post status \(description)")
        }
    }

    func testEveryNonTerminalPostStatusFailsClosed() {
        let cases: [(LoginItem.State, String)] = [
            (.enabled, "enabled"),
            (.requiresApproval, "requires approval"),
            (.notFound, "not found"),
            (.unknown(92), "unknown(92)"),
        ]

        for (postStatus, description) in cases {
            let fake = FakeService([.enabled, postStatus])

            XCTAssertEqual(
                run(fake),
                .init(
                    exitCode: 1,
                    standardOutput: [
                        "login item status before: enabled",
                        "login item status after: \(description)",
                    ],
                    standardError: [
                        "unregister failed: expected not registered after unregister, got \(description)",
                    ]
                ),
                "post status \(description)"
            )
            XCTAssertEqual(fake.statusReadCount, 2, "post status \(description)")
            XCTAssertEqual(fake.unregisterCallCount, 1, "post status \(description)")
        }
    }

    func testUIAdapterReturnsNilOnlyForAlreadyCleanOrVerifiedTerminalStates() {
        let cases: [([LoginItem.State], Error?, Int)] = [
            ([.notRegistered], nil, 0),
            ([.enabled, .notRegistered], nil, 1),
            ([.requiresApproval, .notRegistered], nil, 1),
            ([.enabled, .notRegistered], simulatedError(), 1),
        ]

        for (statuses, error, expectedCalls) in cases {
            let fake = FakeService(statuses, unregisterError: error)

            XCTAssertNil(runUI(fake), "statuses \(statuses)")
            XCTAssertEqual(fake.statusReadCount, statuses.count, "statuses \(statuses)")
            XCTAssertEqual(fake.unregisterCallCount, expectedCalls, "statuses \(statuses)")
        }
    }

    func testUIAdapterReturnsStableNonlocalizedErrorsForUnverifiedStates() {
        let cases: [([LoginItem.State], Error?, String, Int)] = [
            (
                [.notFound], nil,
                "login item status not found cannot confirm unregistration", 0
            ),
            (
                [.unknown(94)], nil,
                "login item status unknown(94) cannot confirm unregistration", 0
            ),
            (
                [.enabled, .enabled], nil,
                "login item status remained enabled after unregister", 1
            ),
            (
                [.enabled, .notFound], simulatedError(),
                "login item unregister failed (domain JBarAppTests.Simulated, code 73); terminal status is not found",
                1
            ),
        ]

        for (statuses, error, expectedMessage, expectedCalls) in cases {
            let fake = FakeService(statuses, unregisterError: error)

            XCTAssertEqual(runUI(fake), expectedMessage, "statuses \(statuses)")
            XCTAssertEqual(fake.statusReadCount, statuses.count, "statuses \(statuses)")
            XCTAssertEqual(fake.unregisterCallCount, expectedCalls, "statuses \(statuses)")
        }
    }
}
