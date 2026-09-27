import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentContentJudgmentAuditTests: XCTestCase {
    func testRetentionKeepsNewest128Rows() {
        let rows = (0 ..< 130).map { index in
            AgentContentJudgmentAudit(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                consumer: "skill_suggestion",
                policyVersion: "test-v1",
                decision: .selected,
                chosenKey: "skill",
                applied: true
            )
        }
        let retained = AgentContentJudgmentAudit.retain(rows)
        XCTAssertEqual(retained.count, 128)
        XCTAssertEqual(retained.first?.id, rows[2].id)
        XCTAssertEqual(retained.last?.id, rows[129].id)
    }

    func testOlderSessionWithoutAuditFieldDecodesEmpty() throws {
        let data = try JSONEncoder().encode(AgentSession())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "contentJudgmentAudit")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AgentSession.self, from: oldData)
        XCTAssertTrue(restored.contentJudgmentAudit.isEmpty)
    }

    func testEncodedRowContainsNoSubmittedText() throws {
        let row = AgentContentJudgmentAudit(
            id: UUID(),
            createdAt: Date(),
            consumer: "approval_advisory",
            policyVersion: "test-v1",
            decision: .fallback,
            chosenKey: nil,
            applied: false
        )
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(row), encoding: .utf8))
        XCTAssertFalse(encoded.contains("private draft"))
        XCTAssertEqual(row.decision, AgentAutomationTurnAudit.Decision.fallback)
    }
}
