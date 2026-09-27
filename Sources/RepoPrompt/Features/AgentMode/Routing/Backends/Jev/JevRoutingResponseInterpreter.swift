import Foundation

struct JevRoutingResponseInterpreter {
    struct ValidatedAnswer: Equatable {
        let selectedOpaqueKey: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct ValidatedResponse: Equatable {
        let answersByQuestionID: [String: ValidatedAnswer]
        let inputTokens: Int
        let outputTokens: Int

        func answer(forQuestionID questionID: String) -> ValidatedAnswer? {
            answersByQuestionID[questionID]
        }
    }

    enum ValidationError: Error, Equatable {
        case wrongEvaluator
        case wrongAnswerShape
        case missingAnswer(questionID: String)
        case unexpectedAnswer(questionID: String)
        case unknownOrMissingCandidates
        case invalidProbability
        case nonUniqueWinningChoice
        case invalidConfidence
        case invalidUsage
    }

    /// Validates the documented Jev response shape without making an acceptance decision.
    ///
    /// Every submitted question is validated independently and must be answered exactly once, and
    /// an answer may reference only the opaque keys of its own question. Batching therefore never
    /// weakens the single-question guarantees: a key that belongs to a sibling question is rejected
    /// exactly like an unknown key. Confidence and winning probability remain separate evidence;
    /// neither is a threshold here.
    func validate(
        _ response: JevRoutingWireResponse,
        batch: JevJudgmentBatch,
        pinnedModel: String = JevRouterCredentialService.pinnedModel
    ) throws -> ValidatedResponse {
        guard response.model == pinnedModel else { throw ValidationError.wrongEvaluator }
        if let unexpected = Set(response.answers.keys).subtracting(batch.questionIDs).sorted().first {
            throw ValidationError.unexpectedAnswer(questionID: unexpected)
        }
        var validatedAnswers: [String: ValidatedAnswer] = [:]
        for question in batch.questions {
            guard let answer = response.answers[question.id] else {
                throw ValidationError.missingAnswer(questionID: question.id)
            }
            validatedAnswers[question.id] = try validate(
                answer,
                submittedOpaqueKeys: question.submittedOpaqueKeys
            )
        }
        guard response.usage.inputTokens >= 0, response.usage.outputTokens >= 0 else {
            throw ValidationError.invalidUsage
        }
        return ValidatedResponse(
            answersByQuestionID: validatedAnswers,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens
        )
    }

    private func validate(
        _ answer: JevRoutingWireResponse.Answer,
        submittedOpaqueKeys: Set<String>
    ) throws -> ValidatedAnswer {
        // The wire answer type is shared with non-routing question types, so the choice fields are
        // optional at decode time. Routing requires all three, exactly as before the widening.
        guard answer.type == JevJudgmentQuestion.choiceType,
              let choice = answer.choice,
              submittedOpaqueKeys.contains(choice)
        else { throw ValidationError.wrongAnswerShape }
        guard let probabilities = answer.probabilities,
              Set(probabilities.keys) == submittedOpaqueKeys
        else {
            throw ValidationError.unknownOrMissingCandidates
        }
        guard probabilities.values.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else {
            throw ValidationError.invalidProbability
        }
        let sum = probabilities.values.reduce(0, +)
        guard abs(sum - 1) <= 0.000_1 else { throw ValidationError.invalidProbability }
        guard let maximum = probabilities.values.max() else {
            throw ValidationError.invalidProbability
        }
        let winners = probabilities.filter { $0.value == maximum }.map(\.key)
        guard winners == [choice] else { throw ValidationError.nonUniqueWinningChoice }
        guard let confidence = answer.confidence, confidence.isFinite, (0 ... 1).contains(confidence) else {
            throw ValidationError.invalidConfidence
        }
        return ValidatedAnswer(
            selectedOpaqueKey: choice,
            probabilities: probabilities,
            confidence: confidence
        )
    }
}
