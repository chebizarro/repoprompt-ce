import Foundation
@testable import RepoPromptApp
import XCTest

/// The service is the single egress point for content judgments. Every failure mode must fail
/// open without prompting, and anything that is not sent must not reach the transport.
final class JevContentJudgmentServiceTests: XCTestCase {
    func testKeyNotReadyIsUnavailableWithoutTransportCall() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse()))
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            client: client
        )
        let service = JevContentJudgmentService(credentials: credentials, ledger: disabledLedger())

        let result = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .readFile)

        XCTAssertEqual(result, .unavailable(reason: .keyNotReady))
        XCTAssertEqual(result.reasonCode, "key_not_ready")
        XCTAssertEqual(client.judgeCount, 0)
    }

    func testAppliedResultCarriesInterpretedAnswersUsageAndBudget() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse(value: 0.9, inputTokens: 42)))
        let service = try await readyService(client: client)

        let result = try await service.judge(batch: presenceBatch(), budget: .milliseconds(1200), consumer: .readFile)

        guard case let .applied(answers, usage) = result else { return XCTFail("Expected applied, got \(result)") }
        XCTAssertEqual(answers, ["present": .noul(value: 0.9)])
        XCTAssertEqual(usage.inputTokens, 42)
        XCTAssertEqual(usage.outcome, "applied")
        XCTAssertEqual(usage.consumer, "read_file")
        XCTAssertEqual(usage.policyVersion, JevContentJudgmentPolicy.readFileWindows)
        XCTAssertNil(result.reasonCode)
        XCTAssertEqual(client.judgeCount, 1)
        XCTAssertEqual(client.lastTimeout, .milliseconds(1200))
        XCTAssertEqual(client.lastRequest?.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(client.lastRequest?.questions["present"]?.type, "noul")
    }

    func testTimeoutFailsOpenWithoutRetry() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .error(.timeout))
        let service = try await readyService(client: client)

        let result = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch)

        guard case let .failed(error, usage) = result else { return XCTFail("Expected failed, got \(result)") }
        XCTAssertEqual(error, .timeout)
        XCTAssertEqual(usage.outcome, "failed:timeout")
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(result.reasonCode, "timeout")
        XCTAssertEqual(client.judgeCount, 1)
    }

    func testAuthenticationFailureAdvancesSharedCredentialGeneration() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .error(.authentication))
        let service = try await readyService(client: client)
        guard case let .ready(readyGeneration, _) = await service.credentials.readinessSnapshot() else {
            return XCTFail("Expected a ready credential")
        }

        let result = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch)

        guard case .failed(.authentication, _) = result else { return XCTFail("Expected authentication failure, got \(result)") }
        guard case let .needsConfiguration(generation, _) = await service.credentials.readinessSnapshot() else {
            return XCTFail("Authentication failure must invalidate the shared credential")
        }
        XCTAssertGreaterThan(generation, readyGeneration)

        let next = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch)
        XCTAssertEqual(next, .unavailable(reason: .keyNotReady))
        XCTAssertEqual(client.judgeCount, 1)
    }

    func testWrongEvaluatorIsAFailedInvalidResponse() async throws {
        let response = JevRoutingWireResponse(
            model: "jev-2.0.0",
            answers: ["present": .init(type: "noul", noul: 0.9)],
            usage: .init(inputTokens: 5, outputTokens: 0)
        )
        let service = try await readyService(client: ScriptedContentJudgmentClient(outcome: .response(response)))

        let result = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch)

        guard case let .failed(error, usage) = result else { return XCTFail("Expected failed, got \(result)") }
        XCTAssertEqual(error, .invalidResponse)
        XCTAssertEqual(usage.inputTokens, 5)
    }

    func testCancellationMidCallDiscardsTheResult() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .hangUntilCancelled)
        let service = try await readyService(client: client)
        let batch = try presenceBatch()

        let judgment = Task { await service.judge(batch: batch, budget: .seconds(2), consumer: .readFile) }
        await client.waitUntilJudgeStarted()
        judgment.cancel()

        let result = await judgment.value
        XCTAssertEqual(result, .unavailable(reason: .cancelled))
        XCTAssertEqual(client.judgeCount, 1)
    }

    func testAlreadyCancelledCallerNeverReachesTransport() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse()))
        let service = try await readyService(client: client)
        let batch = try presenceBatch()

        let judgment = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.judge(batch: batch, budget: .seconds(2), consumer: .readFile)
        }

        let result = await judgment.value
        XCTAssertEqual(result, .unavailable(reason: .cancelled))
        XCTAssertEqual(client.judgeCount, 0)
    }

    func testRequestCeilingRateLimitsLocallyWithoutTransportCall() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse()))
        let clock = ManualInstant()
        let service = try await readyService(
            client: client,
            ceiling: .init(window: .seconds(300), maxRequests: 1, maxStateChars: 1000),
            now: clock.now
        )

        guard case .applied = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch) else {
            return XCTFail("First request must be admitted")
        }
        let limited = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch)
        XCTAssertEqual(limited, .unavailable(reason: .locallyRateLimited))
        XCTAssertEqual(limited.reasonCode, "rate_limited_locally")
        XCTAssertEqual(client.judgeCount, 1)

        clock.advance(by: .seconds(300))
        guard case .applied = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .fileSearch) else {
            return XCTFail("A request must be admitted once the window slides past the first one")
        }
        XCTAssertEqual(client.judgeCount, 2)
    }

    func testStateCharCeilingRateLimitsLocally() async throws {
        let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse()))
        let service = try await readyService(
            client: client,
            ceiling: .init(window: .seconds(300), maxRequests: 60, maxStateChars: 15)
        )

        guard case .applied = try await service.judge(batch: presenceBatch(state: "0123456789"), budget: .seconds(2), consumer: .fileSearch) else {
            return XCTFail("First request must be admitted")
        }
        let limited = try await service.judge(batch: presenceBatch(state: "0123456789"), budget: .seconds(2), consumer: .fileSearch)
        XCTAssertEqual(limited, .unavailable(reason: .locallyRateLimited))
        XCTAssertEqual(client.judgeCount, 1)
    }

    #if DEBUG
        func testLedgerRecordsOutcomeFieldsWithoutContentAt0600() async throws {
            let (ledger, directory) = try enabledLedger()
            let client = ScriptedContentJudgmentClient(outcome: .response(noulResponse(value: 0.9, inputTokens: 42)))
            let service = try await readyService(
                client: client,
                ceiling: .init(window: .seconds(300), maxRequests: 1, maxStateChars: 10000),
                ledger: ledger
            )
            let secret = "SECRET_FILE_TEXT_7f3a"

            _ = try await service.judge(batch: presenceBatch(state: secret), budget: .seconds(2), consumer: .readFile)
            _ = try await service.judge(batch: presenceBatch(state: secret), budget: .seconds(2), consumer: .readFile)
            await service.recordBytesAvoided(900, consumer: .readFile)

            let url = directory.appendingPathComponent(JevContentJudgmentLedger.fileName)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.contains(secret))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try contents.split(separator: "\n").map {
                try decoder.decode(JevContentJudgmentRecord.self, from: Data($0.utf8))
            }
            XCTAssertEqual(records.map(\.outcome), ["applied", "skipped:rate_limited_locally", "accounting"])
            XCTAssertEqual(records.map(\.inputTokens), [42, 0, 0])
            XCTAssertEqual(records.map(\.bytesAvoidedEstimate), [nil, nil, 900])
            XCTAssertEqual(records.map(\.questionCount), [1, 1, 0])
            XCTAssertEqual(records.first?.outputTokens, 0)
            XCTAssertTrue(records.allSatisfy { $0.consumer == "read_file" })
            XCTAssertTrue(records.allSatisfy { $0.policyVersion == JevContentJudgmentPolicy.readFileWindows })
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }

        func testLedgerWritesNothingWhenDiagnosticsAreDisabled() async throws {
            let (ledger, directory) = try enabledLedger(enabled: false)
            let service = try await readyService(
                client: ScriptedContentJudgmentClient(outcome: .response(noulResponse())),
                ledger: ledger
            )

            _ = try await service.judge(batch: presenceBatch(), budget: .seconds(2), consumer: .readFile)

            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(JevContentJudgmentLedger.fileName).path
            ))
        }
    #endif

    // MARK: - Fixtures

    private func readyService(
        client: ScriptedContentJudgmentClient,
        ceiling: JevContentJudgmentService.SpendCeiling = .standard,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        ledger: JevContentJudgmentLedger? = nil
    ) async throws -> JevContentJudgmentService {
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: client
        )
        let validation = await credentials.validateStoredKey(operationID: UUID())
        guard case .saved = validation else {
            XCTFail("Fixture credential failed to validate: \(validation)")
            throw CancellationError()
        }
        return JevContentJudgmentService(
            credentials: credentials,
            ledger: ledger ?? disabledLedger(),
            ceiling: ceiling,
            now: now
        )
    }

    private func presenceBatch(state: String = "relevant_to: parser") throws -> JevContentJudgmentBatch {
        try JevContentJudgmentBatch(state: state, questions: [
            .noul(id: "present", instructions: "Present?", trueDescription: "Yes.", falseDescription: "No.")
        ])
    }

    private func noulResponse(value: Double = 0.8, inputTokens: Int = 10) -> JevRoutingWireResponse {
        JevRoutingWireResponse(
            model: JevRouterCredentialService.pinnedModel,
            answers: ["present": .init(type: "noul", noul: value)],
            usage: .init(inputTokens: inputTokens, outputTokens: 0)
        )
    }

    private func disabledLedger() -> JevContentJudgmentLedger {
        let suite = "JevContentJudgmentServiceTests.disabled.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return JevContentJudgmentLedger(defaults: defaults)
    }

    private func enabledLedger(enabled: Bool = true) throws -> (JevContentJudgmentLedger, URL) {
        let suite = "JevContentJudgmentServiceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JevContentJudgmentLedger-\(UUID())", isDirectory: true)
        defaults.set(enabled, forKey: JevContentJudgmentLedger.diagnosticsEnabledKey)
        defaults.set(directory.path, forKey: JevContentJudgmentLedger.logFilePathKey)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (JevContentJudgmentLedger(defaults: defaults), directory)
    }
}

private final class ManualInstant: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in lock.withLock { base.advanced(by: offset) } }
    }

    func advance(by duration: Duration) {
        lock.withLock { offset += duration }
    }
}

private final class ScriptedContentJudgmentClient: JevRoutingClientProtocol, @unchecked Sendable {
    enum Outcome {
        case response(JevRoutingWireResponse)
        case error(JevRoutingClientError)
        case hangUntilCancelled
    }

    private let lock = NSLock()
    private let outcome: Outcome
    private var requests: [(request: JevRoutingWireRequest, timeout: Duration)] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    var judgeCount: Int {
        lock.withLock { requests.count }
    }

    var lastRequest: JevRoutingWireRequest? {
        lock.withLock { requests.last?.request }
    }

    var lastTimeout: Duration? {
        lock.withLock { requests.last?.timeout }
    }

    func waitUntilJudgeStarted() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                if requests.isEmpty { startWaiters.append(continuation) }
                return !requests.isEmpty
            }
            if started { continuation.resume() }
        }
    }

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        .init(models: [.init(name: "jev-1.13.0")])
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) async throws -> JevRoutingWireResponse {
        let waiters = lock.withLock {
            requests.append((request, timeout))
            defer { startWaiters.removeAll() }
            return startWaiters
        }
        waiters.forEach { $0.resume() }
        switch outcome {
        case let .response(response):
            return response
        case let .error(error):
            throw error
        case .hangUntilCancelled:
            try await Task.sleep(for: .seconds(600))
            throw JevRoutingClientError.timeout
        }
    }
}
