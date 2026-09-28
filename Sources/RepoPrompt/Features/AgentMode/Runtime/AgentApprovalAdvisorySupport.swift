import Foundation

/// An advisory only: never changes an approval decision or the permission store.
enum AgentApprovalAdvisorySupport {
    private struct State: Encodable {
        let method: String
        let kind: String
        let command: String?
        let reason: String?
        let details: [Detail]

        struct Detail: Encodable {
            let label: String
            let value: String
        }
    }

    @MainActor
    static func enrichWithIrreversibilityHint(
        session: AgentTabSession,
        request: AgentApprovalRequest,
        service: (any JevContentJudging)?,
        gateOverride: Bool? = nil,
        onEnriched: @MainActor () -> Void = {}
    ) async {
        let consumer = JevContentJudgmentConsumer.approvalAdvisory
        func audit(
            _ decision: AgentAutomationTurnAudit.Decision,
            probability: Double? = nil,
            usage: JevContentJudgmentRecord? = nil,
            applied: Bool = false
        ) {
            session.appendContentJudgmentAudit(AgentContentJudgmentAudit(
                id: UUID(),
                createdAt: Date(),
                consumer: consumer.rawValue,
                policyVersion: consumer.policyVersion,
                decision: decision,
                chosenKey: applied ? "possiblyIrreversible" : nil,
                probability: probability,
                inputTokens: usage?.inputTokens,
                latencyMs: usage?.latencyMs,
                applied: applied
            ))
        }

        guard gateOverride ?? GlobalSettingsStore.shared.contentJudgmentsEnabled(workspaceID: session.workspaceID) else {
            audit(.disabled)
            return
        }
        guard let service else {
            audit(.unavailable)
            return
        }
        let state = State(
            method: request.method,
            kind: request.kind.rawValue,
            command: request.command,
            reason: request.reason,
            details: request.details.map { State.Detail(label: $0.label, value: $0.value) }
        )
        guard let encoded = try? JevContentJudgmentBatch.jsonState(state),
              let batch = try? JevContentJudgmentBatch(
                  state: encoded,
                  questions: JevContentJudgmentPolicy.ApprovalAdvisory.questions()
              )
        else {
            audit(.ineligible)
            return
        }
        let result = await service.judge(
            batch: batch,
            budget: JevContentJudgmentPolicy.ApprovalAdvisory.budget,
            consumer: consumer
        )
        guard !Task.isCancelled else { return }
        guard case let .applied(answers, usage) = result else {
            audit(.unavailable)
            return
        }
        guard case let .noul(probability)? = answers[JevContentJudgmentPolicy.ApprovalAdvisory.questionID] else {
            audit(.fallback, usage: usage)
            return
        }
        guard probability >= JevContentJudgmentPolicy.ApprovalAdvisory.threshold else {
            audit(.fallback, probability: probability, usage: usage)
            return
        }
        guard session.pendingApproval?.requestID == request.requestID,
              session.runState == .waitingForApproval
        else {
            audit(.fallback, probability: probability, usage: usage)
            return
        }
        session.pendingApproval = request.withIrreversibilityHint(.possiblyIrreversible(jevProbability: probability))
        onEnriched()
        audit(.selected, probability: probability, usage: usage, applied: true)
    }
}
