import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPFileSearchSemanticRerankTests: XCTestCase {
    func testRerankMovesRelevantMatchAboveTheExistingCap() async throws {
        let matches = [
            match("First.swift", text: String(repeating: "a", count: 30000)),
            match("Second.swift", text: String(repeating: "b", count: 30000))
        ]
        let fake = FakeJevContentJudge(applied(probabilities: ["m000": 0.1, "m001": 0.9]))

        let result = await MCPFileSearchSemanticRerank.rerank(matches: matches, query: "second", judge: fake)

        XCTAssertEqual(result.order, [1, 0])
        XCTAssertEqual(cappedPaths(matches, order: result.order), ["Second.swift"])
        XCTAssertEqual(result.metadata.applied, true)
        XCTAssertEqual(result.metadata.judgedMatchCount, 2)
        XCTAssertEqual(result.metadata.reorderedMatchCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(result.metadata.prioritizedChars), 0)
        let capturedBatch = await fake.lastBatch()
        let batch = try XCTUnwrap(capturedBatch)
        XCTAssertEqual(batch.questions.first?.id, JevContentJudgmentPolicy.FileSearch.rankQuestionID)
        XCTAssertTrue(batch.state.contains("m000|First.swift:1:"))
        XCTAssertTrue(batch.state.contains("m001|Second.swift:1:"))
        XCTAssertFalse(batch.state.contains(String(repeating: "b", count: 401)))
    }

    func testPartialCoverageKeepsUnjudgedMatchesInLinearOrder() async {
        let matches = [match("A.swift"), match("B.swift"), match("C.swift"), match("D.swift")]
        let fake = FakeJevContentJudge(applied(probabilities: ["m002": 0.8, "m000": 0.2]))

        let result = await MCPFileSearchSemanticRerank.rerank(matches: matches, query: "C", judge: fake)

        XCTAssertEqual(result.order, [2, 0, 1, 3])
        XCTAssertEqual(result.metadata.judgedMatchCount, 2)
        XCTAssertNil(result.metadata.reason)
    }

    func testBudgetFittedPrefixReportsPartialRerankAndLeavesTailLinear() async throws {
        let matches = (0 ..< 260).map { match("File\($0).swift") }
        let fake = FakeJevContentJudge(applied(probabilities: ["m001": 0.9, "m000": 0.1]))

        let result = await MCPFileSearchSemanticRerank.rerank(matches: matches, query: "intent", judge: fake)

        XCTAssertEqual(Array(result.order.prefix(3)), [1, 0, 2])
        XCTAssertEqual(Array(result.order.suffix(5)), [255, 256, 257, 258, 259])
        XCTAssertEqual(result.metadata.reason, "partial_rerank")
        let capturedBatch = await fake.lastBatch()
        let batch = try XCTUnwrap(capturedBatch)
        XCTAssertEqual(batch.questions.first?.id, JevContentJudgmentPolicy.FileSearch.rankQuestionID)
        XCTAssertEqual(batch.state.components(separatedBy: "\n").count, 257)
        XCTAssertLessThanOrEqual(batch.state.utf8.count, JevContentJudgmentPolicy.stateCharBudget)
    }

    func testCountOnlyAndEmptyIntentSkipRerank() {
        XCTAssertFalse(MCPFileSearchSemanticRerank.shouldAttempt(query: "intent", countOnly: true))
        XCTAssertFalse(MCPFileSearchSemanticRerank.shouldAttempt(query: nil, countOnly: false))
        XCTAssertFalse(MCPFileSearchSemanticRerank.shouldAttempt(query: "", countOnly: false))
        XCTAssertTrue(MCPFileSearchSemanticRerank.shouldAttempt(query: "intent", countOnly: false))
    }

    func testNoCandidatesAndCancellationFailOpen() async {
        let fake = FakeJevContentJudge(.unavailable(reason: .cancelled))
        let one = await MCPFileSearchSemanticRerank.rerank(matches: [match("A.swift")], query: "intent", judge: fake)
        XCTAssertEqual(one.order, [0])
        XCTAssertEqual(one.metadata.reason, "no_candidates")
        let callsAfterSingle = await fake.callCount()
        XCTAssertEqual(callsAfterSingle, 0)

        let cancelled = await MCPFileSearchSemanticRerank.rerank(
            matches: [match("A.swift"), match("B.swift")], query: "intent", judge: fake
        )
        XCTAssertEqual(cancelled.order, [0, 1])
        XCTAssertFalse(cancelled.metadata.applied)
        XCTAssertEqual(cancelled.metadata.reason, "cancelled")
        let callsAfterCancellation = await fake.callCount()
        XCTAssertEqual(callsAfterCancellation, 1)
    }

    func testFailedJudgmentPreservesLinearOrder() async {
        let fake = FakeJevContentJudge(.failed(.timeout, usage: usage()))
        let result = await MCPFileSearchSemanticRerank.rerank(
            matches: [match("A.swift"), match("B.swift")], query: "intent", judge: fake
        )
        XCTAssertEqual(result.order, [0, 1])
        XCTAssertFalse(result.metadata.applied)
        XCTAssertEqual(result.metadata.reason, "timeout")
    }

    func testMissingJudgeAndUnsafeDisplayPathDoNotEgress() async {
        let matches = [match("A.swift"), match("B.swift")]
        let missing = await MCPFileSearchSemanticRerank.rerank(matches: matches, query: "intent", judge: nil)
        XCTAssertEqual(missing.order, [0, 1])
        XCTAssertEqual(missing.metadata.reason, "key_not_ready")

        let fake = FakeJevContentJudge(applied(probabilities: ["m000": 0.5, "m001": 0.5]))
        let unsafe = await MCPFileSearchSemanticRerank.rerank(
            matches: [match("/physical/A.swift"), match("B.swift")], query: "intent", judge: fake
        )
        XCTAssertEqual(unsafe.order, [0, 1])
        XCTAssertEqual(unsafe.metadata.reason, "unsafe_display_path")
        let callsAfterUnsafePath = await fake.callCount()
        XCTAssertEqual(callsAfterUnsafePath, 0)
    }

    func testDisabledWorkspaceDTOOmitsSemanticRerankAndGateRejectsMissingIdentity() async throws {
        let missingIdentityGate = await MCPFileToolProvider.resolveContentJudgmentsGate(identity: nil)
        XCTAssertFalse(missingIdentityGate)
        let baseline = ToolResultDTOs.SearchResultDTO(
            totalMatches: 0, totalFiles: 0, contentMatches: 0, pathMatches: 0,
            limitHit: false, perFileCounts: [], pathMatchLines: [], contentMatchGroups: []
        )
        let withDisabledGate = ToolResultDTOs.SearchResultDTO(
            totalMatches: 0, totalFiles: 0, contentMatches: 0, pathMatches: 0,
            limitHit: false, perFileCounts: [], pathMatchLines: [], contentMatchGroups: [],
            semanticRerank: nil
        )
        let encoder = JSONEncoder()
        XCTAssertEqual(try encoder.encode(baseline), try encoder.encode(withDisabledGate))
        XCTAssertFalse(try String(decoding: encoder.encode(baseline), as: UTF8.self).contains("semantic_rerank"))
    }

    private func match(_ path: String, text: String = "line") -> SearchMatch {
        SearchMatch(filePath: path, lineNumber: 0, lineText: text)
    }

    private func cappedPaths(_ matches: [SearchMatch], order: [Int]) -> [String] {
        var used = 0
        var paths: [String] = []
        for index in order {
            let match = matches[index]
            let cost = "\(match.filePath):\(match.lineNumber + 1): \(match.lineText)".count + 3
            guard used + cost <= MCPFileSearchSemanticRerank.capBudget else { break }
            used += cost
            paths.append(match.filePath)
        }
        return paths
    }

    private func applied(probabilities: [String: Double]) -> JevContentJudgmentResult {
        .applied(
            answers: [
                JevContentJudgmentPolicy.FileSearch.rankQuestionID: .choice(
                    selectedKey: probabilities.max(by: { $0.value < $1.value })?.key ?? "m000",
                    probabilities: probabilities,
                    confidence: 0.9
                ),
                JevContentJudgmentPolicy.FileSearch.presenceQuestionID: .noul(value: 0.8)
            ],
            usage: usage()
        )
    }

    private func usage() -> JevContentJudgmentRecord {
        JevContentJudgmentRecord(
            timestamp: Date(), consumer: JevContentJudgmentConsumer.fileSearch.rawValue,
            outcome: "applied", inputTokens: 42, outputTokens: 0, latencyMs: 10,
            bytesAvoidedEstimate: nil, questionCount: 2,
            policyVersion: JevContentJudgmentPolicy.fileSearchRerank
        )
    }
}

private actor FakeJevContentJudge: JevContentJudging {
    private let result: JevContentJudgmentResult
    private var batches: [JevContentJudgmentBatch] = []

    init(_ result: JevContentJudgmentResult) {
        self.result = result
    }

    func judge(
        batch: JevContentJudgmentBatch,
        budget: Duration,
        consumer: JevContentJudgmentConsumer
    ) async -> JevContentJudgmentResult {
        batches.append(batch)
        return result
    }

    func recordBytesAvoided(_: Int, consumer _: JevContentJudgmentConsumer) async {}

    func callCount() -> Int {
        batches.count
    }

    func lastBatch() -> JevContentJudgmentBatch? {
        batches.last
    }
}
