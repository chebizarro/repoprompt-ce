import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPReadFileRelevantToTests: XCTestCase {
    private typealias Projection = MCPReadFileToolProjection
    private typealias Answer = JevContentJudgmentInterpreter.Answer

    func testWindowsAreAtMost128LinesAndKeepAbsoluteLineIDs() {
        let reply = makeReply(firstLine: 42, count: 260, totalLines: 500)
        let windows = Projection.windows(in: reply)

        XCTAssertEqual(windows.map(\.lines.count), [128, 128, 4])
        XCTAssertEqual(windows.map(\.firstLine), [42, 170, 298])
        let state = JevContentJudgmentPolicy.ReadFile.state(relevantTo: "needle", windows: windows)
        XCTAssertTrue(state.contains("w0|L00042|line 42"))
        XCTAssertTrue(state.contains("w1|L00170|line 170"))
        XCTAssertTrue(state.contains("w2|L00298|line 298"))
    }

    func testHighAndMidPresenceTrimAroundBestLinesAndInsertElision() throws {
        let original = makeReply(firstLine: 1, count: 256, totalLines: 300)
        let windows = Projection.windows(in: original)
        let result = try XCTUnwrap(Projection.assembleWindowedReply(
            from: original,
            windows: windows,
            presenceAnswers: ["present_w0": .noul(value: 0.70), "present_w1": .noul(value: 0.35)],
            choiceAnswers: ["best_w0": choice(line: 80), "best_w1": choice(line: 200)],
            relevantTo: "needle",
            jevInputTokens: 123
        ))

        XCTAssertEqual(result.reply.lineRanges, [.init(start: 48, end: 112), .init(start: 184, end: 216)])
        XCTAssertEqual(result.reply.firstLine, 48)
        XCTAssertEqual(result.reply.lastLine, 216)
        XCTAssertEqual(result.reply.totalLines, 300)
        XCTAssertEqual(result.returnedLineCount, 98)
        XCTAssertTrue(result.reply.content.contains("line 48\n"))
        XCTAssertTrue(result.reply.content.contains("line 216"))
        XCTAssertFalse(result.reply.content.contains("line 113\n"))
        XCTAssertTrue(result.reply.content.contains("… [lines 113–183 omitted; pass relevant_to=nil or start_line/limit to read them] …"))
        XCTAssertEqual(result.reply.relevantTo, "needle")
        XCTAssertEqual(result.reply.semanticFilter?.windowsConsidered, 2)
        XCTAssertEqual(result.reply.semanticFilter?.windowsKept, 2)
        XCTAssertEqual(result.reply.semanticFilter?.jevInputTokens, 123)
        XCTAssertEqual(result.bytesAvoidedEstimate, original.content.utf8.count - result.reply.content.utf8.count)
    }

    func testAdjacentTrimmedWindowsMergeWithoutElision() throws {
        let original = makeReply(firstLine: 1, count: 256, totalLines: 256)
        let windows = Projection.windows(in: original)
        let result = try XCTUnwrap(Projection.assembleWindowedReply(
            from: original,
            windows: windows,
            presenceAnswers: ["present_w0": .noul(value: 0.9), "present_w1": .noul(value: 0.9)],
            choiceAnswers: ["best_w0": choice(line: 126), "best_w1": choice(line: 130)],
            relevantTo: "adjacent",
            jevInputTokens: nil
        ))

        XCTAssertEqual(result.reply.lineRanges, [.init(start: 94, end: 162)])
        XCTAssertEqual(result.returnedLineCount, 69)
        XCTAssertFalse(result.reply.content.contains("omitted"))
    }

    func testMidPresenceWithoutValidChoiceKeepsWholeWindowAndDropsLowPresence() throws {
        let original = makeReply(firstLine: 1, count: 384, totalLines: 384)
        let windows = Projection.windows(in: original)
        let result = try XCTUnwrap(Projection.assembleWindowedReply(
            from: original,
            windows: windows,
            presenceAnswers: [
                "present_w0": .noul(value: 0.1),
                "present_w1": .noul(value: 0.5),
                "present_w2": .invalid(reason: .missingAnswer)
            ],
            choiceAnswers: [:],
            relevantTo: "middle",
            jevInputTokens: 12,
            reason: "choice_timeout"
        ))

        XCTAssertEqual(result.reply.lineRanges, [.init(start: 129, end: 256)])
        XCTAssertEqual(result.returnedLineCount, 128)
        XCTAssertEqual(result.reply.semanticFilter?.reason, "choice_timeout")
        XCTAssertEqual(result.reply.semanticFilter?.windowsKept, 1)
    }

    @MainActor
    func testBaseReplyForwardsOptionalWindowMetadataAndCountsReturnedLines() async throws {
        let prepared = WorkspaceInteractiveReadProcessor.prepare("one\ntwo\nthree")
        let ranges: [ToolResultDTOs.ReadFileReply.LineRange] = [.init(start: 1, end: 3)]
        let filter = ToolResultDTOs.ReadFileReply.SemanticFilter(
            applied: true,
            reason: nil,
            jevInputTokens: 4,
            windowsConsidered: 1,
            windowsKept: 1,
            policyVersion: JevContentJudgmentPolicy.readFileWindows
        )
        let result = try await Projection.makeBaseReply(
            preparedContent: prepared,
            startLine1Based: nil,
            lineCount: nil,
            displayPath: "file.swift",
            lineRanges: ranges,
            relevantTo: "needle",
            semanticFilter: filter
        )

        XCTAssertEqual(result.reply.lineRanges, ranges)
        XCTAssertEqual(result.reply.relevantTo, "needle")
        XCTAssertEqual(result.reply.semanticFilter, filter)
        XCTAssertEqual(result.returnedLineCount, 3)
    }

    @MainActor
    func testReplyProjectionForwardsWindowMetadata() async throws {
        let filter = ToolResultDTOs.ReadFileReply.SemanticFilter(
            applied: true,
            reason: nil,
            jevInputTokens: 9,
            windowsConsidered: 2,
            windowsKept: 1,
            policyVersion: JevContentJudgmentPolicy.readFileWindows
        )
        let reply = ToolResultDTOs.ReadFileReply(
            content: "line 12",
            totalLines: 300,
            firstLine: 12,
            lastLine: 12,
            displayPath: "physical.swift",
            lineRanges: [.init(start: 12, end: 12)],
            relevantTo: "needle",
            semanticFilter: filter
        )

        let projected = try await Projection.projectReply(reply, displayPath: "logical.swift", worktreeScope: nil)
        XCTAssertEqual(projected.displayPath, "logical.swift")
        XCTAssertEqual(projected.lineRanges, reply.lineRanges)
        XCTAssertEqual(projected.relevantTo, "needle")
        XCTAssertEqual(projected.semanticFilter, filter)
    }

    @MainActor
    func testReplyProjectionKeepsLegacyErrorFieldOmission() async throws {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "line 1",
            totalLines: 1,
            firstLine: 1,
            lastLine: 1,
            errorMessage: "unavailable",
            errorCode: "read_failed",
            retryable: true,
            retryAfterMilliseconds: 100
        )

        let projected = try await Projection.projectReply(reply, displayPath: "file.swift", worktreeScope: nil)
        XCTAssertNil(projected.errorMessage)
        XCTAssertNil(projected.errorCode)
        XCTAssertNil(projected.retryable)
        XCTAssertNil(projected.retryAfterMilliseconds)
    }

    func testNoQualifyingWindowsReturnsNilForFullReadFallback() {
        let original = makeReply(firstLine: 1, count: 128, totalLines: 128)
        let windows = Projection.windows(in: original)
        let result = Projection.assembleWindowedReply(
            from: original,
            windows: windows,
            presenceAnswers: ["present_w0": .noul(value: 0.349)],
            choiceAnswers: [:],
            relevantTo: "absent",
            jevInputTokens: 5
        )
        XCTAssertNil(result)
    }

    @MainActor
    func testProviderGateOffPreservesEncodedReplyAndDoesNotCallJudge() async throws {
        let original = makeReply(firstLine: 1, count: 128, totalLines: 128)
        let fake = FakeReadFileJudge([applied(["present_w0": .noul(value: 0.9)])])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: false, judge: fake
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encodedResult = try encoder.encode(result.reply)
        let encodedOriginal = try encoder.encode(original)
        XCTAssertEqual(encodedResult, encodedOriginal)

        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedResult) as? [String: Any])
        XCTAssertNil(encodedObject["line_ranges"])
        XCTAssertNil(encodedObject["relevant_to"])
        XCTAssertNil(encodedObject["semantic_filter"])
        let calls = await fake.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testProviderOverBudgetFallsBackBeforeJudgment() async {
        let original = ToolResultDTOs.ReadFileReply(
            content: String(repeating: "x", count: JevContentJudgmentPolicy.stateCharBudget + 1),
            totalLines: 1, firstLine: 1, lastLine: 1, displayPath: "example.swift"
        )
        let fake = FakeReadFileJudge([])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: true, judge: fake
        )

        XCTAssertEqual(result.reply.content, original.content)
        XCTAssertEqual(result.reply.semanticFilter?.reason, "over_budget")
        XCTAssertFalse(result.reply.semanticFilter?.applied ?? true)
        let calls = await fake.callCount()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testProviderNoQualifyingWindowFallsBackWithoutChoiceRequest() async {
        let original = makeReply(firstLine: 1, count: 128, totalLines: 128)
        let fake = FakeReadFileJudge([applied(["present_w0": .noul(value: 0.349)])])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: true, judge: fake
        )

        XCTAssertEqual(result.reply.content, original.content)
        XCTAssertEqual(result.reply.semanticFilter?.reason, "no_relevant_windows")
        let calls = await fake.callCount()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testProviderChoiceTimeoutUsesPresenceOnlyWindows() async {
        let original = makeReply(firstLine: 1, count: 256, totalLines: 256)
        let fake = FakeReadFileJudge([
            applied(["present_w0": .noul(value: 0.8), "present_w1": .noul(value: 0.1)]),
            .failed(.timeout, usage: usage())
        ])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: true, judge: fake
        )

        XCTAssertEqual(result.reply.lineRanges, [.init(start: 1, end: 128)])
        XCTAssertEqual(result.returnedLineCount, 128)
        XCTAssertEqual(result.reply.semanticFilter?.reason, "choice_timeout")
        let calls = await fake.callCount()
        let recordedBytes = await fake.recordedBytes()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(recordedBytes, [original.content.utf8.count - result.reply.content.utf8.count])
    }

    @MainActor
    func testProviderChoiceFailureFallsBackToFullRead() async {
        let original = makeReply(firstLine: 1, count: 128, totalLines: 128)
        let fake = FakeReadFileJudge([
            applied(["present_w0": .noul(value: 0.8)]),
            .unavailable(reason: .locallyRateLimited)
        ])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: true, judge: fake
        )

        XCTAssertEqual(result.reply.content, original.content)
        XCTAssertNil(result.reply.lineRanges)
        XCTAssertEqual(result.reply.semanticFilter?.reason, "rate_limited_locally")
        let recordedBytes = await fake.recordedBytes()
        XCTAssertTrue(recordedBytes.isEmpty)
    }

    @MainActor
    func testProviderWindowedReplyFeedsAutoSelectionExactRanges() async throws {
        let original = makeReply(firstLine: 1, count: 384, totalLines: 384)
        let fake = FakeReadFileJudge([
            applied([
                "present_w0": .noul(value: 0.9),
                "present_w1": .noul(value: 0.1),
                "present_w2": .noul(value: 0.9)
            ]),
            applied([
                "best_w0": choice(line: 80),
                "best_w2": choice(line: 300)
            ])
        ])

        let result = await MCPFileToolProvider.applyReadFileRelevantTo(
            original, relevantTo: "needle", enabled: true, judge: fake
        )
        let selection = try XCTUnwrap(AutoSliceSelection.readFileSelection(from: result.reply))

        XCTAssertEqual(result.reply.lineRanges, [.init(start: 48, end: 112), .init(start: 268, end: 332)])
        XCTAssertEqual(result.returnedLineCount, 130)
        XCTAssertEqual(selection, .slice(.init(path: "example.swift", ranges: [
            LineRange(start: 48, end: 112), LineRange(start: 268, end: 332)
        ])))
        let calls = await fake.callCount()
        XCTAssertEqual(calls, 2)
    }

    private func applied(_ answers: [String: Answer]) -> JevContentJudgmentResult {
        .applied(answers: answers, usage: usage())
    }

    private func usage() -> JevContentJudgmentRecord {
        JevContentJudgmentRecord(
            timestamp: Date(), consumer: JevContentJudgmentConsumer.readFile.rawValue,
            outcome: "applied", inputTokens: 7, outputTokens: 0, latencyMs: 10,
            bytesAvoidedEstimate: nil, questionCount: 1,
            policyVersion: JevContentJudgmentPolicy.readFileWindows
        )
    }

    private func makeReply(firstLine: Int, count: Int, totalLines: Int) -> ToolResultDTOs.ReadFileReply {
        ToolResultDTOs.ReadFileReply(
            content: (firstLine ..< firstLine + count).map { "line \($0)" }.joined(separator: "\n"),
            totalLines: totalLines,
            firstLine: firstLine,
            lastLine: firstLine + count - 1,
            displayPath: "example.swift"
        )
    }

    private func choice(line: Int) -> Answer {
        .choice(
            selectedKey: JevContentJudgmentPolicy.ReadFile.lineID(line),
            probabilities: [JevContentJudgmentPolicy.ReadFile.lineID(line): 0.9],
            confidence: 0.9
        )
    }
}

private actor FakeReadFileJudge: JevContentJudging {
    private var results: [JevContentJudgmentResult]
    private var batches: [JevContentJudgmentBatch] = []
    private var bytes: [Int] = []

    init(_ results: [JevContentJudgmentResult]) {
        self.results = results
    }

    func judge(
        batch: JevContentJudgmentBatch,
        budget _: Duration,
        consumer _: JevContentJudgmentConsumer
    ) async -> JevContentJudgmentResult {
        batches.append(batch)
        guard !results.isEmpty else { return .unavailable(reason: .noCandidates) }
        return results.removeFirst()
    }

    func recordBytesAvoided(_ value: Int, consumer _: JevContentJudgmentConsumer) async {
        bytes.append(value)
    }

    func callCount() -> Int {
        batches.count
    }

    func recordedBytes() -> [Int] {
        bytes
    }
}
