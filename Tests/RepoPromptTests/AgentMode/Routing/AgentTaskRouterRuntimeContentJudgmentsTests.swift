import Foundation
@testable import RepoPromptApp
import XCTest

/// Content judgments must share the runtime's single Jev credential so key validation, removal,
/// and authentication failures invalidate routing, Auto effort, and content judgments together.
@MainActor
final class AgentTaskRouterRuntimeContentJudgmentsTests: XCTestCase {
    func testBootstrapSelectsJevWhenOnlyContentJudgmentsAreEnabled() {
        XCTAssertEqual(
            AgentTaskRouterRuntime.bootstrapBackendID(
                routerEnabled: false,
                selectedBackendID: nil,
                autoEffortEnabled: false,
                hasAnyContentJudgmentsEnabled: true
            ),
            .jev
        )
        XCTAssertNil(AgentTaskRouterRuntime.bootstrapBackendID(
            routerEnabled: false,
            selectedBackendID: .jev,
            autoEffortEnabled: false,
            hasAnyContentJudgmentsEnabled: false
        ))
        XCTAssertEqual(AgentTaskRouterRuntime.bootstrapBackendID(
            routerEnabled: true,
            selectedBackendID: .jev,
            autoEffortEnabled: false,
            hasAnyContentJudgmentsEnabled: false
        ), .jev)
        XCTAssertEqual(AgentTaskRouterRuntime.bootstrapBackendID(
            routerEnabled: false,
            selectedBackendID: nil,
            autoEffortEnabled: true,
            hasAnyContentJudgmentsEnabled: false
        ), .jev)
    }

    func testConvenienceInitSharesTheJevBackendCredentialService() async throws {
        let runtime = AgentTaskRouterRuntime(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            jevClient: OfflineJevClient()
        )

        let service = try XCTUnwrap(runtime.contentJudgments as? JevContentJudgmentService)
        let registration = await runtime.registry.registration(for: .jev)
        let backend = try XCTUnwrap(registration?.backend as? JevTaskRouterBackend)
        XCTAssertTrue(service.credentials === backend.credentialService)
        XCTAssertTrue(registration?.settings?.controller as? JevRouterCredentialService === backend.credentialService)
    }

    func testConvenienceInitContentJudgmentsFailOpenWithoutAValidatedKey() async throws {
        let client = OfflineJevClient()
        let runtime = AgentTaskRouterRuntime(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            jevClient: client
        )
        let batch = try JevContentJudgmentBatch(state: "s", questions: [
            .noul(id: "p", instructions: "i", trueDescription: "Yes.", falseDescription: "No.")
        ])

        let result = await runtime.contentJudgments?.judge(batch: batch, budget: .seconds(2), consumer: .fileSearch)

        XCTAssertEqual(result, .unavailable(reason: .keyNotReady))
        XCTAssertEqual(client.judgeCount, 0)
    }

    func testDesignatedInitDefaultsToNoContentJudgments() throws {
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(backend: JevTaskRouterBackend(credentialService: JevRouterCredentialService(client: OfflineJevClient())))
        ])
        XCTAssertNil(runtime.contentJudgments)
    }

    func testDesignatedInitStoresInjectedContentJudgments() throws {
        let credentials = JevRouterCredentialService(client: OfflineJevClient())
        let service = JevContentJudgmentService(credentials: credentials)
        let runtime = try AgentTaskRouterRuntime(
            registrations: [.init(backend: JevTaskRouterBackend(credentialService: credentials))],
            contentJudgments: service
        )
        XCTAssertTrue(runtime.contentJudgments as? JevContentJudgmentService === service)
    }
}

private final class OfflineJevClient: JevRoutingClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var judgeCalls = 0

    var judgeCount: Int {
        lock.withLock { judgeCalls }
    }

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        throw JevRoutingClientError.authentication
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) async throws -> JevRoutingWireResponse {
        lock.withLock { judgeCalls += 1 }
        throw JevRoutingClientError.invalidRequest
    }
}
