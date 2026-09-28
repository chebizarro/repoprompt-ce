import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderCandidatePrePassTests: XCTestCase {
    func testSectionUsesWeightedScoreBandsAndListsUnrankedFiles() async throws {
        let judge = FakeContextBuilderJudge(scores: [
            "Central.swift": 2.8,
            "Useful.swift": 1.8,
            "Low.swift": 0.5
        ])
        let section = try await ContextBuilderCandidatePrePass.section(
            task: "change the flow",
            candidates: [
                candidate("Central.swift"),
                candidate("Useful.swift"),
                candidate("Low.swift"),
                candidate("Unknown.swift"),
                candidate("Binary.dat", excerpt: nil)
            ],
            enabled: true,
            judge: judge,
            isCurrent: { true }
        )
        let text = try XCTUnwrap(section)
        XCTAssertTrue(text.contains("central:\n- Central.swift"))
        XCTAssertTrue(text.contains("useful context:\n- Useful.swift"))
        XCTAssertTrue(text.contains("unranked selected files:\n- Binary.dat"))
        XCTAssertTrue(text.contains("- Unknown.swift"))
        XCTAssertFalse(text.contains("- Low.swift"))
        let batches = await judge.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].questions.count, 4)
        XCTAssertEqual(batches[0].questions.map(\.wireType), ["score", "score", "score", "score"])
        XCTAssertTrue(batches[0].state.contains("\"task\":\"change the flow\""))
        XCTAssertTrue(batches[0].state.contains("\"path\":\"Central.swift\""))
    }

    func testBatchesAtFortyCapsAtEightyAndListsTheTailUnranked() async throws {
        let judge = FakeContextBuilderJudge(defaultScore: 2.8)
        let candidates = (0 ..< 85).map { candidate(String(format: "File%03d.swift", $0)) }
        let section = try await ContextBuilderCandidatePrePass.section(
            task: "update files", candidates: candidates, enabled: true, judge: judge, isCurrent: { true }
        )
        let text = try XCTUnwrap(section)
        let batches = await judge.batches()
        XCTAssertEqual(batches.map(\.questions.count), [40, 40])
        XCTAssertTrue(batches.allSatisfy { $0.state.utf8.count <= JevContentJudgmentPolicy.stateCharBudget })
        XCTAssertEqual(text.components(separatedBy: "\n- File").count - 1, 15)
        XCTAssertTrue(text.contains("unranked selected files:\n- File080.swift"))
        XCTAssertTrue(text.contains("- File084.swift"))
    }

    func testFailedOrUnavailableBatchOmitsEntireSection() async throws {
        let candidates = (0 ..< 41).map { candidate("File\($0).swift") }
        for failedResult in [
            JevContentJudgmentResult.failed(.timeout, usage: usage()),
            .unavailable(reason: .keyNotReady)
        ] {
            let judge = FakeContextBuilderJudge(defaultScore: 2.8, secondResult: failedResult)
            let section = try await ContextBuilderCandidatePrePass.section(
                task: "update files", candidates: candidates, enabled: true, judge: judge, isCurrent: { true }
            )
            XCTAssertNil(section)
            let count = await judge.callCount()
            XCTAssertEqual(count, 2)
        }
    }

    func testRunStartSelectionWinsAndDisabledGatePreservesMessage() async throws {
        let captured = ContextBuilderCandidatePrePass.Input(
            prompt: "captured task", selection: StoredSelection(selectedPaths: ["Captured.swift"])
        )
        let snapshot = ContextBuilderCandidatePrePass.Input(
            prompt: "snapshot task", selection: StoredSelection(selectedPaths: ["Snapshot.swift"])
        )
        let live = ContextBuilderCandidatePrePass.Input(
            prompt: "live task", selection: StoredSelection(selectedPaths: ["Live.swift"])
        )
        let chosen = try XCTUnwrap(ContextBuilderCandidatePrePass.preferredInput(
            captured: captured, snapshot: snapshot, live: live
        ))
        XCTAssertEqual(chosen.prompt, "captured task")
        XCTAssertEqual(chosen.selection.selectedPaths, ["Captured.swift"])
        let selectedCandidates = chosen.selection.selectedPaths.map { candidate($0) }
        let enabledJudge = FakeContextBuilderJudge(defaultScore: 3)
        let selectedSection = try await ContextBuilderCandidatePrePass.section(
            task: chosen.prompt, candidates: selectedCandidates, enabled: true,
            judge: enabledJudge, isCurrent: { true }
        )
        XCTAssertTrue(try XCTUnwrap(selectedSection).contains("- Captured.swift"))
        let submitted = await enabledJudge.batches()
        XCTAssertTrue(try XCTUnwrap(submitted.first).state.contains("Captured.swift"))
        XCTAssertFalse(try XCTUnwrap(submitted.first).state.contains("Snapshot.swift"))

        let disabledJudge = FakeContextBuilderJudge(defaultScore: 3)
        let section = try await ContextBuilderCandidatePrePass.section(
            task: chosen.prompt, candidates: selectedCandidates, enabled: false,
            judge: disabledJudge, isCurrent: { true }
        )
        XCTAssertNil(section)
        let count = await disabledJudge.callCount()
        XCTAssertEqual(count, 0)
        let baseline = "<file_map>\nCaptured.swift\n</file_map>\n\n<current_prompt_content>\ncaptured task\n</current_prompt_content>"
        XCTAssertEqual(baseline + ContextBuilderCandidatePrePass.sectionBlock(section), baseline)
    }

    func testHeadReadUsesFortyLinesAndSkipsEmptyOrBinary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textPath = directory.appendingPathComponent("text.swift")
        try (1 ... 45).map { "line\($0)" }.joined(separator: "\n").write(to: textPath, atomically: true, encoding: .utf8)
        let excerpt = try XCTUnwrap(ContextBuilderCandidatePrePass.readExcerpt(at: textPath.path))
        XCTAssertEqual(excerpt.components(separatedBy: "\n").count, 40)
        XCTAssertTrue(excerpt.hasSuffix("line40"))
        let emptyPath = directory.appendingPathComponent("empty.swift")
        try Data().write(to: emptyPath)
        XCTAssertNil(ContextBuilderCandidatePrePass.readExcerpt(at: emptyPath.path))
        let binaryPath = directory.appendingPathComponent("binary.dat")
        try Data([0, 1, 2]).write(to: binaryPath)
        XCTAssertNil(ContextBuilderCandidatePrePass.readExcerpt(at: binaryPath.path))
    }

    private func candidate(_ path: String, excerpt: String? = "first line") -> ContextBuilderCandidatePrePass.Candidate {
        .init(displayPath: path, excerpt: excerpt)
    }

    private func usage() -> JevContentJudgmentRecord {
        JevContentJudgmentRecord(
            timestamp: Date(), consumer: JevContentJudgmentConsumer.contextBuilder.rawValue,
            outcome: "applied", inputTokens: 42, outputTokens: 0, latencyMs: 10,
            bytesAvoidedEstimate: nil, questionCount: 40,
            policyVersion: JevContentJudgmentPolicy.contextBuilderPrePass
        )
    }
}

private actor FakeContextBuilderJudge: JevContentJudging {
    private let scores: [String: Double]
    private let defaultScore: Double?
    private let secondResult: JevContentJudgmentResult?
    private var submitted: [JevContentJudgmentBatch] = []

    init(
        scores: [String: Double] = [:],
        defaultScore: Double? = nil,
        secondResult: JevContentJudgmentResult? = nil
    ) {
        self.scores = scores
        self.defaultScore = defaultScore
        self.secondResult = secondResult
    }

    func judge(
        batch: JevContentJudgmentBatch,
        budget: Duration,
        consumer: JevContentJudgmentConsumer
    ) async -> JevContentJudgmentResult {
        submitted.append(batch)
        if submitted.count == 2, let secondResult { return secondResult }
        let state = (try? JSONSerialization.jsonObject(with: Data(batch.state.utf8))) as? [String: Any]
        let files = state?["files"] as? [String: [String: String]] ?? [:]
        var answers: [String: JevContentJudgmentInterpreter.Answer] = [:]
        for question in batch.questions {
            guard let path = files[question.id]?["path"], let score = scores[path] ?? defaultScore else { continue }
            answers[question.id] = .score(level: Int(score.rounded()), weighted: score)
        }
        return .applied(
            answers: answers,
            usage: JevContentJudgmentRecord(
                timestamp: Date(), consumer: consumer.rawValue, outcome: "applied",
                inputTokens: 42, outputTokens: 0, latencyMs: 10, bytesAvoidedEstimate: nil,
                questionCount: batch.questions.count, policyVersion: consumer.policyVersion
            )
        )
    }

    func recordBytesAvoided(_: Int, consumer _: JevContentJudgmentConsumer) async {}

    func batches() -> [JevContentJudgmentBatch] {
        submitted
    }

    func callCount() -> Int {
        submitted.count
    }
}
