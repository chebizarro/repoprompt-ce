import Foundation

/// Two-stage, non-blocking skill recommendation. The caller owns debounce and stale-draft rejection.
@MainActor
enum AgentSkillSuggestionJev {
    private typealias Policy = JevContentJudgmentPolicy.SkillSuggestion
    struct Outcome {
        let skill: AgentSkillDefinition?
        let audit: AgentContentJudgmentAudit
    }

    private struct StageOneState: Encodable {
        let request: String
        let skills: [String: String]
    }

    private struct StageTwoState: Encodable {
        let request: String
        let skills: [String: String]
        let candidate: String
    }

    private static func skillBody(_ template: String) -> String {
        guard template.hasPrefix("---\n"), let closing = template.range(of: "\n---\n") else {
            return template
        }
        return String(template[closing.upperBound...])
    }

    static func suggest(
        text: String,
        skills: [AgentSkillDefinition],
        service: (any JevContentJudging)?
    ) async -> Outcome {
        let consumer = JevContentJudgmentConsumer.skillSuggestion
        func outcome(
            _ decision: AgentAutomationTurnAudit.Decision,
            skill: AgentSkillDefinition? = nil,
            probability: Double? = nil,
            inputTokens: Int? = nil,
            latencyMs: Int? = nil
        ) -> Outcome {
            Outcome(
                skill: skill,
                audit: AgentContentJudgmentAudit(
                    id: UUID(),
                    createdAt: Date(),
                    consumer: consumer.rawValue,
                    policyVersion: consumer.policyVersion,
                    decision: decision,
                    chosenKey: skill?.name,
                    probability: probability,
                    inputTokens: inputTokens,
                    latencyMs: latencyMs,
                    applied: skill != nil
                )
            )
        }

        guard !skills.isEmpty,
              Set(skills.map(\.name)).count == skills.count,
              !skills.contains(where: { $0.name == Policy.noneKey })
        else { return outcome(.ineligible) }
        guard let service else { return outcome(.unavailable) }
        let catalog = Dictionary(uniqueKeysWithValues: skills.map {
            ($0.name, String(($0.description ?? $0.name).prefix(Policy.descriptionChars)))
        })
        let criteria = skills.map { Policy.Skill(name: $0.name, description: $0.description ?? $0.name) }
        guard let state = try? JevContentJudgmentBatch.jsonState(StageOneState(request: text, skills: catalog)),
              let batch = try? JevContentJudgmentBatch(state: state, questions: Policy.stageOneQuestions(skills: criteria))
        else { return outcome(.ineligible) }
        let first = await service.judge(batch: batch, budget: Policy.stageBudget, consumer: consumer)
        guard case let .applied(answers, firstUsage) = first else { return outcome(.unavailable) }
        guard case let .noul(acts)? = answers[Policy.actsQuestionID],
              case let .noul(procedure)? = answers[Policy.procedureQuestionID],
              case let .noul(prose)? = answers[Policy.proseQuestionID],
              (acts + procedure + 1 - prose) / 3 >= Policy.gateThreshold
        else { return outcome(.fallback, inputTokens: firstUsage.inputTokens, latencyMs: firstUsage.latencyMs) }
        guard case let .choice(key, probabilities, _)? = answers[Policy.whichQuestionID],
              key != Policy.noneKey,
              let whichProbability = probabilities[key],
              whichProbability >= Policy.minimumWhichProbability,
              let skill = skills.first(where: { $0.name == key })
        else { return outcome(.fallback, inputTokens: firstUsage.inputTokens, latencyMs: firstUsage.latencyMs) }
        guard let secondState = try? JevContentJudgmentBatch.jsonState(StageTwoState(
            request: text,
            skills: catalog,
            candidate: String(skillBody(skill.template).prefix(Policy.skillBodyChars))
        )), let secondBatch = try? JevContentJudgmentBatch(
            state: secondState,
            questions: Policy.stageTwoQuestions()
        ) else { return outcome(.fallback, inputTokens: firstUsage.inputTokens, latencyMs: firstUsage.latencyMs) }
        let second = await service.judge(batch: secondBatch, budget: Policy.stageBudget, consumer: consumer)
        guard case let .applied(secondAnswers, secondUsage) = second else {
            return outcome(.unavailable, inputTokens: firstUsage.inputTokens, latencyMs: firstUsage.latencyMs)
        }
        let tokens = firstUsage.inputTokens + secondUsage.inputTokens
        let latency = firstUsage.latencyMs + secondUsage.latencyMs
        guard case let .noul(fit)? = secondAnswers[Policy.fitQuestionID], fit >= Policy.fitThreshold else {
            return outcome(.fallback, probability: whichProbability, inputTokens: tokens, latencyMs: latency)
        }
        return outcome(.selected, skill: skill, probability: whichProbability, inputTokens: tokens, latencyMs: latency)
    }
}
