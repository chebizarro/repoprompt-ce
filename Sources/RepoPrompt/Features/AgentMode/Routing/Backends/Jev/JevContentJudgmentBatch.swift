import Foundation

enum JevContentJudgmentRejection: Error, Equatable {
    case emptyState
    /// UTF-8 byte count of the rejected state.
    case stateOverBudget(Int)
    case stateEncodingFailed
    case emptyQuestions
    case emptyQuestionID
    case duplicateQuestionID(String)
    case tooFewChoiceCriteria(questionID: String)
    case tooManyChoiceCriteria(Int)
    case invalidChoiceCriterion(questionID: String)
    case invalidNoulCriteria(questionID: String)
    case invalidScoreLevels(Int)
}

/// One content-judgment question of any documented Jev type.
struct JevContentJudgmentQuestion: Equatable {
    enum Kind: Equatable {
        case choice(instructions: String, criteria: [JevJudgmentCriterion])
        case noul(instructions: String, trueDescription: String, falseDescription: String)
        /// `levels[i]` describes level `i`; answers report a level in `0..<levels.count`.
        case score(instructions: String, levels: [String])
    }

    let id: String
    let kind: Kind

    static func choice(id: String, instructions: String, criteria: [JevJudgmentCriterion]) -> Self {
        Self(id: id, kind: .choice(instructions: instructions, criteria: criteria))
    }

    static func noul(id: String, instructions: String, trueDescription: String, falseDescription: String) -> Self {
        Self(id: id, kind: .noul(
            instructions: instructions,
            trueDescription: trueDescription,
            falseDescription: falseDescription
        ))
    }

    static func score(id: String, instructions: String, levels: [String]) -> Self {
        Self(id: id, kind: .score(instructions: instructions, levels: levels))
    }

    var wireType: String {
        switch kind {
        case .choice: "choice"
        case .noul: "noul"
        case .score: "score"
        }
    }

    var wireQuestion: JevRoutingWireRequest.Question {
        switch kind {
        case let .choice(instructions, criteria):
            JevRoutingWireRequest.Question(
                type: wireType,
                instructions: instructions,
                criteria: .labeled(Dictionary(uniqueKeysWithValues: criteria.map { ($0.opaqueKey, $0.description) }))
            )
        case let .noul(instructions, trueDescription, falseDescription):
            JevRoutingWireRequest.Question(
                type: wireType,
                instructions: instructions,
                criteria: .labeled(["true": trueDescription, "false": falseDescription])
            )
        case let .score(instructions, levels):
            JevRoutingWireRequest.Question(type: wireType, instructions: instructions, criteria: .levels(levels))
        }
    }
}

/// One validated `/v1/systemone` content-judgment request.
///
/// Deliberately a sibling of `JevJudgmentBatch`: routing stays choice-only with 2–12 criteria,
/// while content judgments accept `noul` and `score` questions and up to 255 choice options.
/// Callers chunk content themselves; this type validates exactly one request and never truncates.
struct JevContentJudgmentBatch: Equatable {
    static let maxChoiceCriteria = 255
    static let minChoiceCriteria = 2
    static let scoreLevelRange = 2 ... 10

    let state: String
    let questions: [JevContentJudgmentQuestion]

    /// - Parameter charBudget: maximum state size in UTF-8 bytes. Bytes over-approximate characters
    ///   for non-ASCII text, keeping the token estimate conservative.
    init(
        state: String,
        questions: [JevContentJudgmentQuestion],
        charBudget: Int = JevContentJudgmentPolicy.stateCharBudget
    ) throws {
        guard !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JevContentJudgmentRejection.emptyState
        }
        let stateBytes = state.utf8.count
        guard stateBytes <= charBudget else { throw JevContentJudgmentRejection.stateOverBudget(stateBytes) }
        guard !questions.isEmpty else { throw JevContentJudgmentRejection.emptyQuestions }
        var seenIDs: Set<String> = []
        for question in questions {
            guard !question.id.isEmpty else { throw JevContentJudgmentRejection.emptyQuestionID }
            guard seenIDs.insert(question.id).inserted else {
                throw JevContentJudgmentRejection.duplicateQuestionID(question.id)
            }
            try Self.validate(question)
        }
        self.state = state
        self.questions = questions
    }

    /// Encodes a structured state deterministically (sorted keys) so wire fixtures stay stable.
    static func jsonState(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let state = String(data: data, encoding: .utf8) else {
            throw JevContentJudgmentRejection.stateEncodingFailed
        }
        return state
    }

    var stateCharCount: Int {
        state.utf8.count
    }

    var questionIDs: [String] {
        questions.map(\.id)
    }

    func wireRequest(model: String = JevRouterCredentialService.pinnedModel) -> JevRoutingWireRequest {
        JevRoutingWireRequest(
            model: model,
            state: state,
            questions: Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.wireQuestion) })
        )
    }

    private static func validate(_ question: JevContentJudgmentQuestion) throws {
        switch question.kind {
        case let .choice(_, criteria):
            guard criteria.count >= minChoiceCriteria else {
                throw JevContentJudgmentRejection.tooFewChoiceCriteria(questionID: question.id)
            }
            guard criteria.count <= maxChoiceCriteria else {
                throw JevContentJudgmentRejection.tooManyChoiceCriteria(criteria.count)
            }
            var seenKeys: Set<String> = []
            for criterion in criteria {
                guard !criterion.opaqueKey.isEmpty, seenKeys.insert(criterion.opaqueKey).inserted else {
                    throw JevContentJudgmentRejection.invalidChoiceCriterion(questionID: question.id)
                }
            }
        case let .noul(_, trueDescription, falseDescription):
            guard !trueDescription.isEmpty, !falseDescription.isEmpty else {
                throw JevContentJudgmentRejection.invalidNoulCriteria(questionID: question.id)
            }
        case let .score(_, levels):
            guard scoreLevelRange.contains(levels.count) else {
                throw JevContentJudgmentRejection.invalidScoreLevels(levels.count)
            }
        }
    }
}
