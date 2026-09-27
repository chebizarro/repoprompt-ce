import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentApprovalIrreversibilityHintTests: XCTestCase {
    private actor FakeJudge: JevContentJudging {
        let result: JevContentJudgmentResult
        var submittedState: String?
        init(_ result: JevContentJudgmentResult) {
            self.result = result
        }

        func judge(
            batch: JevContentJudgmentBatch,
            budget: Duration,
            consumer: JevContentJudgmentConsumer
        ) async -> JevContentJudgmentResult {
            result
        }

        func recordBytesAvoided(_ bytes: Int, consumer: JevContentJudgmentConsumer) async {}
    }

    private func request(_ id: String = "one") -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .acp(id),
            method: "terminal/execute",
            kind: .commandExecution,
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            reason: "Needs approval",
            command: "rm temp.txt",
            cwd: "/private/path",
            grantRoot: "/secret",
            proposedExecpolicyAmendmentJSON: "secret-policy",
            details: [AgentApprovalDetail(label: "Command", value: "rm temp.txt")]
        ) async -> JevContentJudgmentResult {
            submittedState = batch.state
            return result
        }
    }

    private func positive() -> JevContentJudgmentResult {
        .applied(
            answers: ["irreversible": .noul(value: 0.9)],
            usage: JevContentJudgmentRecord(
                timestamp: Date(),
                consumer: "approval_advisory",
                outcome: "applied",
                inputTokens: 12,
                outputTokens: 0,
                latencyMs: 7,
                bytesAvoidedEstimate: nil,
                questionCount: 1,
                policyVersion: JevContentJudgmentPolicy.approvalAdvisory
            )
        )
    }

    func testHintKeepsStableIdentityAndAllRequestFields() {
        let original = request()
        let hinted = original.withIrreversibilityHint(.possiblyIrreversible(jevProbability: 0.9))
        XCTAssertEqual(hinted.id, original.id)
        XCTAssertEqual(hinted.requestID, original.requestID)
        XCTAssertEqual(hinted.details, original.details)
        XCTAssertEqual(hinted.cwd, original.cwd)
        XCTAssertEqual(hinted.grantRoot, original.grantRoot)
        XCTAssertEqual(hinted.proposedExecpolicyAmendmentJSON, original.proposedExecpolicyAmendmentJSON)
    }

    func testSelectedHintOnlyAttachesToWaitingMatchingRequest() async {
        let session = AgentTabSession(tabID: UUID())
        let pending = request()
        session.pendingApproval = pending
        session.runState = .waitingForApproval
        let fake = FakeJudge(positive())
        await AgentApprovalAdvisorySupport.enrichWithIrreversibilityHint(
            session: session, request: pending, service: fake, gateOverride: true
        )
        let state = await fake.submittedState ?? ""
        XCTAssertFalse(state.contains("/private/path"))
        XCTAssertFalse(state.contains("/secret"))
        XCTAssertFalse(state.contains("secret-policy"))
        XCTAssertNotNil(session.pendingApproval?.irreversibilityHint)
        XCTAssertEqual(session.pendingApproval?.id, pending.id)
        XCTAssertEqual(session.contentJudgmentAudit.last?.decision, .selected)
    }

    func testClearedApprovalIsNotResurrected() async {
        let session = AgentTabSession(tabID: UUID())
        session.runState = .waitingForApproval
        await AgentApprovalAdvisorySupport.enrichWithIrreversibilityHint(
            session: session, request: request(), service: FakeJudge(positive()), gateOverride: true
        )
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(session.contentJudgmentAudit.last?.decision, .fallback)
    }

    func testUnavailableLeavesHintNil() async {
        let session = AgentTabSession(tabID: UUID())
        let pending = request()
        session.pendingApproval = pending
        session.runState = .waitingForApproval
        await AgentApprovalAdvisorySupport.enrichWithIrreversibilityHint(
            session: session,
            request: pending,
            service: FakeJudge(.unavailable(reason: .keyNotReady)),
            gateOverride: true
        )
        XCTAssertNil(session.pendingApproval?.irreversibilityHint)
        XCTAssertEqual(session.contentJudgmentAudit.last?.decision, .unavailable)
    }
}
