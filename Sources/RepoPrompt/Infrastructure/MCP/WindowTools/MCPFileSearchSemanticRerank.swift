import Foundation

/// Orders already-projected search matches before the provider's size cap. The service never sees
/// physical paths, and a missing gate is handled by the caller without constructing this result.
@MainActor
enum MCPFileSearchSemanticRerank {
    static let capBudget = max(0, 50000 - 2000)

    static func shouldAttempt(query: String?, countOnly: Bool) -> Bool {
        !countOnly && !(query?.isEmpty ?? true)
    }

    struct Result {
        let order: [Int]
        let metadata: ToolResultDTOs.SearchResultDTO.SemanticRerank
    }

    static func rerank(
        matches: [SearchMatch],
        query: String,
        judge: (any JevContentJudging)?
    ) async -> Result {
        let originalOrder = Array(matches.indices)
        func unchanged(reason: String, tokens: Int? = nil, presence: Double? = nil) -> Result {
            Result(
                order: originalOrder,
                metadata: .init(
                    applied: false,
                    reason: reason,
                    presence: presence,
                    jevInputTokens: tokens,
                    judgedMatchCount: nil,
                    reorderedMatchCount: nil,
                    prioritizedChars: nil,
                    policyVersion: JevContentJudgmentPolicy.fileSearchRerank
                )
            )
        }

        guard matches.count >= 2 else { return unchanged(reason: JevContentJudgmentUnavailableReason.noCandidates.rawValue) }
        guard let judge else { return unchanged(reason: JevContentJudgmentUnavailableReason.keyNotReady.rawValue) }
        // The display resolver normally yields relative paths. Refuse egress if it did not.
        guard matches.allSatisfy({ !$0.filePath.hasPrefix("/") }) else {
            return unchanged(reason: "unsafe_display_path")
        }

        var candidates: [JevContentJudgmentPolicy.FileSearch.Match] = []
        var state = ""
        for match in matches.prefix(JevContentJudgmentBatch.maxChoiceCriteria) {
            let candidate = JevContentJudgmentPolicy.FileSearch.Match(
                displayPath: match.filePath,
                line: match.lineNumber + 1,
                text: match.lineText
            )
            let proposed = candidates + [candidate]
            let proposedState = JevContentJudgmentPolicy.FileSearch.state(query: query, matches: proposed)
            guard proposedState.utf8.count <= JevContentJudgmentPolicy.stateCharBudget else { break }
            candidates = proposed
            state = proposedState
        }
        guard candidates.count >= 2 else { return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue) }

        let ids = candidates.indices.map(JevContentJudgmentPolicy.FileSearch.matchID)
        guard let batch = try? JevContentJudgmentBatch(
            state: state,
            questions: JevContentJudgmentPolicy.FileSearch.questions(matchIDs: ids)
        ) else {
            return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue)
        }
        guard !Task.isCancelled else { return unchanged(reason: JevContentJudgmentUnavailableReason.cancelled.rawValue) }
        let result = await judge.judge(batch: batch, budget: JevContentJudgmentPolicy.FileSearch.budget, consumer: .fileSearch)
        guard !Task.isCancelled else { return unchanged(reason: JevContentJudgmentUnavailableReason.cancelled.rawValue) }
        guard case let .applied(answers, usage) = result else {
            return unchanged(reason: result.reasonCode ?? "unavailable")
        }
        let presence: Double? = if case let .some(.noul(value)) = answers[JevContentJudgmentPolicy.FileSearch.presenceQuestionID] {
            value
        } else {
            nil
        }
        guard case let .some(.choice(_, probabilities, _)) = answers[JevContentJudgmentPolicy.FileSearch.rankQuestionID] else {
            return unchanged(reason: "invalid_answer", tokens: usage.inputTokens, presence: presence)
        }

        let ranked = candidates.indices.sorted { left, right in
            let leftScore = probabilities[ids[left]]
            let rightScore = probabilities[ids[right]]
            switch (leftScore, rightScore) {
            case let (.some(a), .some(b)): a == b ? left < right : a > b
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): left < right
            }
        }
        let order = ranked + Array(candidates.count ..< matches.count)
        let originalIncluded = Set(cappedIndices(order: originalOrder, matches: matches))
        let prioritizedChars = cappedIndices(order: order, matches: matches)
            .filter { !originalIncluded.contains($0) }
            .reduce(0) { $0 + cappedLineCost(matches[$1]) }
        let metadata = ToolResultDTOs.SearchResultDTO.SemanticRerank(
            applied: true,
            reason: candidates.count < matches.count ? "partial_rerank" : nil,
            presence: presence,
            jevInputTokens: usage.inputTokens,
            judgedMatchCount: probabilities.count,
            reorderedMatchCount: ranked.enumerated().count(where: { $0.offset != $0.element }),
            prioritizedChars: prioritizedChars,
            policyVersion: JevContentJudgmentPolicy.fileSearchRerank
        )
        return Result(order: order, metadata: metadata)
    }

    private static func cappedIndices(order: [Int], matches: [SearchMatch]) -> [Int] {
        var used = 0
        var included: [Int] = []
        for index in order {
            let cost = cappedLineCost(matches[index])
            guard used + cost <= capBudget else { break }
            used += cost
            included.append(index)
        }
        return included
    }

    private static func cappedLineCost(_ match: SearchMatch) -> Int {
        "\(match.filePath):\(match.lineNumber + 1): \(match.lineText)".count + 3
    }
}
