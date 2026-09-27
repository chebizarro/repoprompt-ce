import Foundation

/// Shapes a projected read only after the workspace gate has been resolved by the provider.
@MainActor
enum MCPReadFileSemanticFilter {
    struct Result {
        let reply: ToolResultDTOs.ReadFileReply
        let returnedLineCount: Int
    }

    static func filter(
        _ original: ToolResultDTOs.ReadFileReply,
        relevantTo: String,
        judge: (any JevContentJudging)?
    ) async -> Result {
        func unchanged(reason: String, tokens: Int? = nil, windows: Int? = nil) -> Result {
            Result(
                reply: original.withSemanticFilter(.init(
                    applied: false,
                    reason: reason,
                    jevInputTokens: tokens,
                    windowsConsidered: windows,
                    windowsKept: nil,
                    policyVersion: JevContentJudgmentPolicy.readFileWindows
                ), relevantTo: relevantTo),
                returnedLineCount: original.lineRanges?.reduce(0) { $0 + $1.end - $1.start + 1 }
                    ?? max(0, original.lastLine - original.firstLine + 1)
            )
        }

        guard !Task.isCancelled else { return unchanged(reason: "cancelled") }
        guard let judge else { return unchanged(reason: JevContentJudgmentUnavailableReason.keyNotReady.rawValue) }
        guard original.errorMessage == nil,
              !original.content.contains("\0"),
              !original.content.contains("\u{FFFD}")
        else { return unchanged(reason: "invalid_text") }

        let policy = JevContentJudgmentPolicy.ReadFile.self
        let windows = MCPReadFileToolProjection.windows(in: original)
        guard !windows.isEmpty else { return unchanged(reason: JevContentJudgmentUnavailableReason.noCandidates.rawValue) }
        guard windows.count <= JevContentJudgmentBatch.maxChoiceCriteria else {
            return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue, windows: windows.count)
        }
        let state = policy.state(relevantTo: relevantTo, windows: windows)
        guard state.utf8.count <= JevContentJudgmentPolicy.stateCharBudget else {
            return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue, windows: windows.count)
        }
        let windowIDs = windows.indices.map(policy.windowID)
        guard let presenceBatch = try? JevContentJudgmentBatch(
            state: state,
            questions: policy.presenceQuestions(windowIDs: windowIDs)
        ) else {
            return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue, windows: windows.count)
        }
        let presence = await judge.judge(batch: presenceBatch, budget: policy.presenceBudget, consumer: .readFile)
        guard !Task.isCancelled else { return unchanged(reason: "cancelled", windows: windows.count) }
        guard case let .applied(presenceAnswers, presenceUsage) = presence else {
            return unchanged(reason: presence.reasonCode ?? "unavailable", windows: windows.count)
        }
        let qualifying = windows.indices.filter { index in
            guard case let .noul(value)? = presenceAnswers[policy.presenceQuestionID(windowID: windowIDs[index])] else {
                return false
            }
            return value >= JevContentJudgmentPolicy.presenceLowThreshold
        }
        guard !qualifying.isEmpty else {
            return unchanged(reason: "no_relevant_windows", tokens: presenceUsage.inputTokens, windows: windows.count)
        }

        let choiceQuestions = qualifying.compactMap { index -> JevContentJudgmentQuestion? in
            let window = windows[index]
            guard window.lines.count >= JevContentJudgmentBatch.minChoiceCriteria else { return nil }
            let lineIDs = window.lines.indices.map { policy.lineID(window.firstLine + $0) }
            return policy.choiceQuestion(windowID: windowIDs[index], lineIDs: lineIDs)
        }
        var choiceAnswers: [String: JevContentJudgmentInterpreter.Answer] = [:]
        var tokens = presenceUsage.inputTokens
        var reason: String?
        if !choiceQuestions.isEmpty {
            guard let choiceBatch = try? JevContentJudgmentBatch(state: state, questions: choiceQuestions) else {
                return unchanged(reason: JevContentJudgmentUnavailableReason.overBudget.rawValue, tokens: tokens, windows: windows.count)
            }
            let choice = await judge.judge(batch: choiceBatch, budget: policy.choiceBudget, consumer: .readFile)
            guard !Task.isCancelled else { return unchanged(reason: "cancelled", tokens: tokens, windows: windows.count) }
            switch choice {
            case let .applied(answers, usage):
                choiceAnswers = answers
                tokens += usage.inputTokens
            case let .failed(.timeout, usage):
                tokens += usage.inputTokens
                reason = "choice_timeout"
            case .failed, .unavailable:
                return unchanged(reason: choice.reasonCode ?? "unavailable", tokens: tokens, windows: windows.count)
            }
        }
        guard let windowed = MCPReadFileToolProjection.assembleWindowedReply(
            from: original,
            windows: windows,
            presenceAnswers: presenceAnswers,
            choiceAnswers: choiceAnswers,
            relevantTo: relevantTo,
            jevInputTokens: tokens,
            reason: reason
        ) else {
            return unchanged(reason: "no_relevant_windows", tokens: tokens, windows: windows.count)
        }
        await judge.recordBytesAvoided(windowed.bytesAvoidedEstimate, consumer: .readFile)
        return Result(reply: windowed.reply, returnedLineCount: windowed.returnedLineCount)
    }
}

private extension ToolResultDTOs.ReadFileReply {
    func withSemanticFilter(
        _ filter: SemanticFilter,
        relevantTo: String
    ) -> Self {
        Self(
            content: content,
            totalLines: totalLines,
            firstLine: firstLine,
            lastLine: lastLine,
            message: message,
            displayPath: displayPath,
            worktreeScope: worktreeScope,
            errorMessage: errorMessage,
            errorCode: errorCode,
            retryable: retryable,
            retryAfterMilliseconds: retryAfterMilliseconds,
            lineRanges: lineRanges,
            relevantTo: relevantTo,
            semanticFilter: filter
        )
    }
}
