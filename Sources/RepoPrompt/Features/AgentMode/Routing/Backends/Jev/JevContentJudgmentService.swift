import Foundation

enum JevContentJudgmentUnavailableReason: String, Equatable {
    case workspaceNotOptedIn = "workspace_not_opted_in"
    case keyNotReady = "key_not_ready"
    case overBudget = "over_budget"
    case noCandidates = "no_candidates"
    case locallyRateLimited = "rate_limited_locally"
    case cancelled
}

/// DEBUG ledger entry and per-call usage. Never contains file text, paths, or prompt text.
struct JevContentJudgmentRecord: Codable, Equatable {
    let timestamp: Date
    /// `JevContentJudgmentConsumer.rawValue`.
    let consumer: String
    /// `applied`, `skipped:<reason>`, `failed:<error>`, or `accounting` for consumer-side savings.
    let outcome: String
    let inputTokens: Int
    /// `usage.output_tokens`; expected 0 for jev-1.13.0 and never part of savings evidence.
    let outputTokens: Int?
    let latencyMs: Int
    /// `read_file` only: original minus returned UTF-8 bytes.
    let bytesAvoidedEstimate: Int?
    let questionCount: Int
    let policyVersion: String
}

enum JevContentJudgmentResult: Equatable {
    case applied(answers: [String: JevContentJudgmentInterpreter.Answer], usage: JevContentJudgmentRecord)
    /// No request was sent (or its result was discarded); consumers fail open.
    case unavailable(reason: JevContentJudgmentUnavailableReason)
    /// The request was sent and failed; consumers fail open.
    case failed(JevRoutingClientError, usage: JevContentJudgmentRecord)

    /// Stable machine-readable reason for DTO metadata; `nil` when applied.
    var reasonCode: String? {
        switch self {
        case .applied: nil
        case let .unavailable(reason): reason.rawValue
        case let .failed(error, _): error.contentJudgmentCode
        }
    }
}

/// Seam consumed by MCP tools, Context Builder, and Agent Mode. Callers check the per-workspace
/// gate before calling; implementations enforce credential readiness, budget, and spend ceiling.
protocol JevContentJudging: Sendable {
    func judge(
        batch: JevContentJudgmentBatch,
        budget: Duration,
        consumer: JevContentJudgmentConsumer
    ) async -> JevContentJudgmentResult

    /// Records consumer-side savings (for example `read_file` windowing) in the DEBUG ledger.
    /// Deliberately has no default implementation: a protocol-extension default would silently
    /// shadow a conformer's synchronous actor method and drop the accounting record.
    func recordBytesAvoided(_ bytes: Int, consumer: JevContentJudgmentConsumer) async
}

/// App-global, advisory, fail-open content-judgment service. Owned by `AgentTaskRouterRuntime`,
/// which shares its single `JevRouterCredentialService` so credential generation is shared too.
actor JevContentJudgmentService: JevContentJudging {
    struct SpendCeiling: Equatable {
        let window: Duration
        let maxRequests: Int
        let maxStateChars: Int

        static let standard = SpendCeiling(
            window: JevContentJudgmentPolicy.spendWindow,
            maxRequests: JevContentJudgmentPolicy.maxRequestsPerSpendWindow,
            maxStateChars: JevContentJudgmentPolicy.maxStateCharsPerSpendWindow
        )
    }

    nonisolated let credentials: JevRouterCredentialService
    private let ledger: JevContentJudgmentLedger
    private let ceiling: SpendCeiling
    private let now: @Sendable () -> ContinuousClock.Instant
    private let wallClock: @Sendable () -> Date
    private var admitted: [(instant: ContinuousClock.Instant, stateChars: Int)] = []

    init(
        credentials: JevRouterCredentialService,
        ledger: JevContentJudgmentLedger = JevContentJudgmentLedger(),
        ceiling: SpendCeiling = .standard,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.ledger = ledger
        self.ceiling = ceiling
        self.now = now
        self.wallClock = wallClock
    }

    func judge(
        batch: JevContentJudgmentBatch,
        budget: Duration,
        consumer: JevContentJudgmentConsumer
    ) async -> JevContentJudgmentResult {
        let started = now()
        guard !Task.isCancelled else { return skipped(.cancelled, batch: batch, consumer: consumer, started: started) }
        // Readiness is checked without touching the keychain or the network: an unconfigured or
        // still-validating credential is a silent fail-open, never a Settings prompt.
        guard case .ready = await credentials.readinessSnapshot() else {
            return skipped(.keyNotReady, batch: batch, consumer: consumer, started: started)
        }
        guard admit(stateChars: batch.stateCharCount, at: now()) else {
            return skipped(.locallyRateLimited, batch: batch, consumer: consumer, started: started)
        }
        let response: JevRoutingWireResponse
        do {
            response = try await credentials.judge(batch.wireRequest(), timeout: budget)
        } catch is CancellationError {
            return skipped(.cancelled, batch: batch, consumer: consumer, started: started)
        } catch {
            // Non-client errors come from secure storage while loading the key.
            let clientError = error as? JevRoutingClientError ?? .authentication
            let usage = record(
                outcome: "failed:\(clientError.contentJudgmentCode)",
                inputTokens: 0,
                outputTokens: nil,
                batch: batch,
                consumer: consumer,
                started: started
            )
            return .failed(clientError, usage: usage)
        }
        guard !Task.isCancelled else { return skipped(.cancelled, batch: batch, consumer: consumer, started: started) }
        do {
            let interpretation = try JevContentJudgmentInterpreter().interpret(response, batch: batch)
            let usage = record(
                outcome: "applied",
                inputTokens: interpretation.inputTokens,
                outputTokens: interpretation.outputTokens,
                batch: batch,
                consumer: consumer,
                started: started
            )
            return .applied(answers: interpretation.answers, usage: usage)
        } catch {
            let usage = record(
                outcome: "failed:\(JevRoutingClientError.invalidResponse.contentJudgmentCode)",
                inputTokens: max(0, response.usage.inputTokens),
                outputTokens: nil,
                batch: batch,
                consumer: consumer,
                started: started
            )
            return .failed(.invalidResponse, usage: usage)
        }
    }

    func recordBytesAvoided(_ bytes: Int, consumer: JevContentJudgmentConsumer) {
        ledger.append(JevContentJudgmentRecord(
            timestamp: wallClock(),
            consumer: consumer.rawValue,
            outcome: "accounting",
            inputTokens: 0,
            outputTokens: nil,
            latencyMs: 0,
            bytesAvoidedEstimate: bytes,
            questionCount: 0,
            policyVersion: consumer.policyVersion
        ))
    }

    /// Sliding-window egress guard. Admission is charged before the request is sent because the
    /// state leaves the machine even if the request later fails.
    private func admit(stateChars: Int, at instant: ContinuousClock.Instant) -> Bool {
        admitted.removeAll { instant - $0.instant >= ceiling.window }
        let admittedChars = admitted.reduce(0) { $0 + $1.stateChars }
        guard admitted.count < ceiling.maxRequests, admittedChars + stateChars <= ceiling.maxStateChars else {
            return false
        }
        admitted.append((instant, stateChars))
        return true
    }

    private func skipped(
        _ reason: JevContentJudgmentUnavailableReason,
        batch: JevContentJudgmentBatch,
        consumer: JevContentJudgmentConsumer,
        started: ContinuousClock.Instant
    ) -> JevContentJudgmentResult {
        _ = record(
            outcome: "skipped:\(reason.rawValue)",
            inputTokens: 0,
            outputTokens: nil,
            batch: batch,
            consumer: consumer,
            started: started
        )
        return .unavailable(reason: reason)
    }

    private func record(
        outcome: String,
        inputTokens: Int,
        outputTokens: Int?,
        batch: JevContentJudgmentBatch,
        consumer: JevContentJudgmentConsumer,
        started: ContinuousClock.Instant
    ) -> JevContentJudgmentRecord {
        let elapsed = (now() - started).components
        let record = JevContentJudgmentRecord(
            timestamp: wallClock(),
            consumer: consumer.rawValue,
            outcome: outcome,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            latencyMs: max(0, Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)),
            bytesAvoidedEstimate: nil,
            questionCount: batch.questions.count,
            policyVersion: consumer.policyVersion
        )
        ledger.append(record)
        return record
    }
}

extension JevRoutingClientError {
    /// Stable snake_case code for ledger outcomes and DTO reasons.
    var contentJudgmentCode: String {
        switch self {
        case .invalidResponse: "invalid_response"
        case .authentication: "authentication"
        case .invalidRequest: "invalid_request"
        case .rateLimited: "rate_limited"
        case .overloaded: "overloaded"
        case .timeout: "timeout"
        case let .service(statusCode): "service_\(statusCode)"
        case .decoding: "decoding"
        }
    }
}

/// DEBUG-only JSONL ledger of `JevContentJudgmentRecord`s, written `0600`.
///
/// Gated on UserDefaults `jevContentJudgmentDiagnosticsEnabled`; `jevContentJudgmentLogFilePath`
/// overrides the directory (empty ⇒ the non-workspace temp debug directory), matching the
/// `claudeRawEventLogFilePath` convention. Release builds compile the type but never write.
struct JevContentJudgmentLedger {
    static let diagnosticsEnabledKey = "jevContentJudgmentDiagnosticsEnabled"
    static let logFilePathKey = "jevContentJudgmentLogFilePath"
    static let fileName = "jev-content-judgments.jsonl"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func logFileURL() -> URL {
        let override = defaults.string(forKey: Self.logFilePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL = if let override, !override.isEmpty {
            URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent("JevContentJudgments", isDirectory: true)
        }
        return directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func append(_ record: JevContentJudgmentRecord) {
        #if DEBUG
            guard defaults.bool(forKey: Self.diagnosticsEnabledKey) else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            let url = logFileURL()
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                return
            }
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            // Tighten a pre-existing file too; records are local diagnostics reviewed before sharing.
            fchmod(descriptor, 0o600)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try? handle.write(contentsOf: line)
        #endif
    }
}
