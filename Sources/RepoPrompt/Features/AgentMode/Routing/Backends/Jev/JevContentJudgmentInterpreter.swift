import Foundation

/// Tolerant per-question interpretation of a content-judgment response.
///
/// Unlike `JevRoutingResponseInterpreter`, one malformed answer never fails the whole response:
/// it becomes `.invalid` and consumers treat that question as unjudged. Only evaluator identity and
/// usage are validated for the response as a whole. Choice distributions may cover a subset of the
/// submitted keys and have no argmax-uniqueness requirement, because consumers order by the
/// distribution instead of acting on a single decision.
struct JevContentJudgmentInterpreter {
    enum InvalidReason: String, Equatable {
        case missingAnswer = "missing_answer"
        case wrongType = "wrong_type"
        case missingValue = "missing_value"
        case valueOutOfRange = "value_out_of_range"
        case unknownKey = "unknown_key"
        case invalidConfidence = "invalid_confidence"
    }

    enum Answer: Equatable {
        case choice(selectedKey: String, probabilities: [String: Double], confidence: Double)
        case noul(value: Double)
        /// `level` is the most probable level; `weighted` the probability-weighted level.
        case score(level: Int, weighted: Double)
        case invalid(reason: InvalidReason)
    }

    struct Interpretation: Equatable {
        let answers: [String: Answer]
        let inputTokens: Int
        let outputTokens: Int
    }

    enum ResponseError: Error, Equatable {
        case wrongEvaluator
        case invalidUsage
    }

    func interpret(
        _ response: JevRoutingWireResponse,
        batch: JevContentJudgmentBatch,
        pinnedModel: String = JevRouterCredentialService.pinnedModel
    ) throws -> Interpretation {
        guard response.model == pinnedModel else { throw ResponseError.wrongEvaluator }
        guard response.usage.inputTokens >= 0, response.usage.outputTokens >= 0 else {
            throw ResponseError.invalidUsage
        }
        // Answers for questions that were never submitted are ignored rather than trusted.
        var answers: [String: Answer] = [:]
        for question in batch.questions {
            guard let answer = response.answers[question.id] else {
                answers[question.id] = .invalid(reason: .missingAnswer)
                continue
            }
            answers[question.id] = interpret(answer, for: question)
        }
        return Interpretation(
            answers: answers,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens
        )
    }

    private func interpret(
        _ answer: JevRoutingWireResponse.Answer,
        for question: JevContentJudgmentQuestion
    ) -> Answer {
        guard answer.type == question.wireType else { return .invalid(reason: .wrongType) }
        switch question.kind {
        case let .choice(_, criteria):
            return interpretChoice(answer, submittedKeys: Set(criteria.map(\.opaqueKey)))
        case .noul:
            guard let value = answer.noul else { return .invalid(reason: .missingValue) }
            guard Self.isProbability(value) else { return .invalid(reason: .valueOutOfRange) }
            return .noul(value: value)
        case let .score(_, levels):
            return interpretScore(answer, levels: levels)
        }
    }

    private func interpretChoice(_ answer: JevRoutingWireResponse.Answer, submittedKeys: Set<String>) -> Answer {
        guard let choice = answer.choice,
              let probabilities = answer.probabilities,
              !probabilities.isEmpty
        else { return .invalid(reason: .missingValue) }
        guard submittedKeys.contains(choice),
              Set(probabilities.keys).isSubset(of: submittedKeys)
        else { return .invalid(reason: .unknownKey) }
        guard probabilities.values.allSatisfy(Self.isProbability) else {
            return .invalid(reason: .valueOutOfRange)
        }
        guard let confidence = answer.confidence, Self.isProbability(confidence) else {
            return .invalid(reason: .invalidConfidence)
        }
        return .choice(selectedKey: choice, probabilities: probabilities, confidence: confidence)
    }

    private func interpretScore(_ answer: JevRoutingWireResponse.Answer, levels: [String]) -> Answer {
        let maximumLevel = Double(levels.count - 1)
        if let score = answer.score, !(score.isFinite && (0 ... maximumLevel).contains(score)) {
            return .invalid(reason: .valueOutOfRange)
        }
        if let distribution = answer.probabilities.flatMap({
            Self.levelDistribution($0, levels: levels, legend: answer.legend)
        }) {
            let total = distribution.values.reduce(0, +)
            if total > 0 {
                let weighted = distribution.reduce(0) { $0 + Double($1.key) * $1.value } / total
                // Ties resolve to the lower level so the result is deterministic.
                let level = distribution.max { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
                }?.key ?? Int(weighted.rounded())
                return .score(level: level, weighted: weighted)
            }
        }
        guard let score = answer.score else { return .invalid(reason: .missingValue) }
        return .score(level: Int(score.rounded()), weighted: score)
    }

    /// Maps probability keys to level indices. Keys may be level indices ("0"...), legend entries,
    /// or the submitted level descriptions. Any unmappable, duplicate, or non-probability entry
    /// makes the distribution unusable, and the caller falls back to the reported `score`.
    private static func levelDistribution(
        _ probabilities: [String: Double],
        levels: [String],
        legend: [String]?
    ) -> [Int: Double]? {
        guard !probabilities.isEmpty else { return nil }
        var distribution: [Int: Double] = [:]
        for (key, probability) in probabilities {
            guard isProbability(probability) else { return nil }
            let index = Int(key).flatMap { levels.indices.contains($0) ? $0 : nil }
                ?? legend?.firstIndex(of: key).flatMap { levels.indices.contains($0) ? $0 : nil }
                ?? levels.firstIndex(of: key)
            guard let index, distribution[index] == nil else { return nil }
            distribution[index] = probability
        }
        return distribution
    }

    private static func isProbability(_ value: Double) -> Bool {
        value.isFinite && (0 ... 1).contains(value)
    }
}
