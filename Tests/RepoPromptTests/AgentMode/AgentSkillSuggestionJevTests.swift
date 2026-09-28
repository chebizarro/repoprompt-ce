import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSkillSuggestionJevTests: XCTestCase {
    private actor FakeJudge: JevContentJudging {
        var responses: [JevContentJudgmentResult]
        var calls = 0

        init(_ responses: [JevContentJudgmentResult]) {
            self.responses = responses
        }

        func judge(
            batch: JevContentJudgmentBatch,
            budget: Duration,
            consumer: JevContentJudgmentConsumer
        ) async -> JevContentJudgmentResult {
            calls += 1
            return responses.removeFirst()
        }

        func recordBytesAvoided(_ bytes: Int, consumer: JevContentJudgmentConsumer) async {}
    }

    private func skill() -> AgentSkillDefinition {
        AgentSkillDefinition(
            id: "deploy",
            name: "deploy",
            description: "Deploy the application safely",
            variant: nil,
            fileURL: URL(fileURLWithPath: "/tmp/deploy/SKILL.md"),
            template: "# Deploy\nValidate and release the application.",
            source: .globalAgentsSkills
        )
    }

    private func applied(_ answers: [String: JevContentJudgmentInterpreter.Answer]) -> JevContentJudgmentResult {
        .applied(answers: answers, usage: JevContentJudgmentRecord(
            timestamp: Date(),
            consumer: "skill_suggestion",
            outcome: "applied",
            inputTokens: 10,
            outputTokens: 0,
            latencyMs: 8,
            bytesAvoidedEstimate: nil,
            questionCount: answers.count,
            policyVersion: JevContentJudgmentPolicy.skillSuggestion
        ))
    }

    private func firstAnswers(key: String, acts: Double = 1, procedure: Double = 1, prose: Double = 0) -> [String: JevContentJudgmentInterpreter.Answer] {
        [
            "which": .choice(selectedKey: key, probabilities: ["deploy": 0.8, "none": 0.2], confidence: 0.8),
            "acts": .noul(value: acts),
            "procedure": .noul(value: procedure),
            "prose": .noul(value: prose)
        ]
    }

    func testLowGateSkipsSecondStage() async {
        let fake = FakeJudge([applied(firstAnswers(key: "deploy", acts: 0, procedure: 0, prose: 1))])
        let result = await AgentSkillSuggestionJev.suggest(text: "Please explain this", skills: [skill()], service: fake)
        XCTAssertNil(result.skill)
        XCTAssertEqual(result.audit.decision, .fallback)
        let calls = await fake.calls
        XCTAssertEqual(calls, 1)
    }

    func testNoneChoiceDoesNotSuggest() async {
        let fake = FakeJudge([applied(firstAnswers(key: "none"))])
        let result = await AgentSkillSuggestionJev.suggest(text: "Deploy it", skills: [skill()], service: fake)
        XCTAssertNil(result.skill)
        let calls = await fake.calls
        XCTAssertEqual(calls, 1)
    }

    func testFitControlsSuggestion() async {
        let fake = FakeJudge([
            applied(firstAnswers(key: "deploy")),
            applied(["fit": .noul(value: 0.2)])
        ])
        let result = await AgentSkillSuggestionJev.suggest(text: "Deploy it", skills: [skill()], service: fake)
        XCTAssertNil(result.skill)
        XCTAssertEqual(result.audit.decision, .fallback)
        let calls = await fake.calls
        XCTAssertEqual(calls, 2)
    }

    func testDraftChangeAndDismissClearNonBlockingSuggestion() {
        let viewModel = AgentModeViewModel(
            testWindowID: -991,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Suggestion test must not start Codex")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.suggestedSkill = skill()
        viewModel.suggestedSkillTabID = tabID
        viewModel.storeDraftText(for: tabID, "changed")
        XCTAssertNil(viewModel.suggestedSkill)
        viewModel.suggestedSkill = skill()
        viewModel.suggestedSkillTabID = tabID
        viewModel.dismissSuggestedSkill()
        XCTAssertNil(viewModel.suggestedSkill)
        viewModel.storeDraftText(for: tabID, "")
        XCTAssertNil(viewModel.suggestedSkill)
    }

    func testPositiveFitSelectsAuditedSkill() async {
        let fake = FakeJudge([
            applied(firstAnswers(key: "deploy")),
            applied(["fit": .noul(value: 0.9)])
        ])
        let result = await AgentSkillSuggestionJev.suggest(text: "Deploy it", skills: [skill()], service: fake)
        XCTAssertEqual(result.skill?.name, "deploy")
        XCTAssertTrue(result.audit.applied)
        XCTAssertEqual(result.audit.inputTokens, 20)
    }
}
