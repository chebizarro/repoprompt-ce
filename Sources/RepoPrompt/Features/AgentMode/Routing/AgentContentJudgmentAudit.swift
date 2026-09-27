import Foundation

/// Bounded local evidence for an advisory content judgment. Never stores submitted text.
struct AgentContentJudgmentAudit: Codable, Equatable {
    static let retainedLimit = 128

    var schemaVersion = 1
    let id: UUID
    let createdAt: Date
    let consumer: String
    let policyVersion: String
    var decision: AgentAutomationTurnAudit.Decision
    var chosenKey: String? = nil
    var probability: Double? = nil
    var inputTokens: Int? = nil
    var latencyMs: Int? = nil
    var applied: Bool

    static func retain(_ rows: [Self]) -> [Self] {
        Array(rows.suffix(retainedLimit))
    }
}
