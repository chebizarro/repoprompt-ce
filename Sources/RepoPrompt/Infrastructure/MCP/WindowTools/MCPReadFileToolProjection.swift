import Foundation

/// Sendable read-file slicing and reply projection used by the MainActor provider.
enum MCPReadFileToolProjection {
    struct PreparedReply {
        let reply: ToolResultDTOs.ReadFileReply
        let returnedLineCount: Int
    }

    struct WindowedReply {
        let reply: ToolResultDTOs.ReadFileReply
        let returnedLineCount: Int
        let bytesAvoidedEstimate: Int
    }

    /// Splits a contiguous projected read into windows without changing the file's line numbers.
    static func windows(in reply: ToolResultDTOs.ReadFileReply) -> [JevContentJudgmentPolicy.ReadFile.Window] {
        guard reply.lineRanges == nil, reply.firstLine > 0, reply.lastLine >= reply.firstLine else { return [] }
        let lines = String.splitContentPreservingAllLineEndings(reply.content).map(\.line)
        guard lines.count == reply.lastLine - reply.firstLine + 1 else { return [] }
        let windowSize = JevContentJudgmentPolicy.ReadFile.maxWindowLines
        return stride(from: 0, to: lines.count, by: windowSize).map { offset in
            JevContentJudgmentPolicy.ReadFile.Window(
                firstLine: reply.firstLine + offset,
                lines: Array(lines[offset ..< min(offset + windowSize, lines.count)])
            )
        }
    }

    /// Assembles judged windows in file order. `nil` means no window passed the presence gate:
    /// the caller must return the original full read instead.
    static func assembleWindowedReply(
        from original: ToolResultDTOs.ReadFileReply,
        windows: [JevContentJudgmentPolicy.ReadFile.Window],
        presenceAnswers: [String: JevContentJudgmentInterpreter.Answer],
        choiceAnswers: [String: JevContentJudgmentInterpreter.Answer] = [:],
        relevantTo: String,
        jevInputTokens: Int?,
        reason: String? = nil
    ) -> WindowedReply? {
        guard !windows.isEmpty, windows == self.windows(in: original) else { return nil }
        let policy = JevContentJudgmentPolicy.ReadFile.self
        var selected: [ToolResultDTOs.ReadFileReply.LineRange] = []
        for (index, window) in windows.enumerated() {
            let windowID = policy.windowID(index)
            guard case let .noul(presence)? = presenceAnswers[policy.presenceQuestionID(windowID: windowID)],
                  presence.isFinite, presence >= JevContentJudgmentPolicy.presenceLowThreshold
            else { continue }

            let first = window.firstLine
            let last = first + window.lines.count - 1
            let radius = presence >= JevContentJudgmentPolicy.presenceHighThreshold
                ? policy.highPresenceTrimRadius
                : policy.midPresenceTrimRadius
            if let bestLine = bestLine(
                in: window,
                answer: choiceAnswers[policy.choiceQuestionID(windowID: windowID)]
            ) {
                selected.append(.init(start: max(first, bestLine - radius), end: min(last, bestLine + radius)))
            } else {
                selected.append(.init(start: first, end: last))
            }
        }
        guard !selected.isEmpty else { return nil }

        let ranges = mergedRanges(selected)
        let sourceLines = String.splitContentPreservingAllLineEndings(original.content)
            .map { $0.line + $0.ending }
        var content = ""
        for (index, range) in ranges.enumerated() {
            if index > 0 {
                let previous = ranges[index - 1]
                if !content.hasSuffix("\n"), !content.hasSuffix("\r") { content += "\n" }
                content += "… [lines \(previous.end + 1)–\(range.start - 1) omitted; pass relevant_to=nil or start_line/limit to read them] …\n"
            }
            let startOffset = range.start - original.firstLine
            let endOffset = range.end - original.firstLine
            content += sourceLines[startOffset ... endOffset].joined()
        }

        let returnedLineCount = ranges.reduce(0) { $0 + $1.end - $1.start + 1 }
        return WindowedReply(
            reply: ToolResultDTOs.ReadFileReply(
                content: content,
                totalLines: original.totalLines,
                firstLine: ranges[0].start,
                lastLine: ranges[ranges.count - 1].end,
                message: original.message,
                displayPath: original.displayPath,
                worktreeScope: original.worktreeScope,
                errorMessage: original.errorMessage,
                errorCode: original.errorCode,
                retryable: original.retryable,
                retryAfterMilliseconds: original.retryAfterMilliseconds,
                lineRanges: ranges,
                relevantTo: relevantTo,
                semanticFilter: .init(
                    applied: true,
                    reason: reason,
                    jevInputTokens: jevInputTokens,
                    windowsConsidered: windows.count,
                    windowsKept: selected.count,
                    policyVersion: JevContentJudgmentPolicy.readFileWindows
                )
            ),
            returnedLineCount: returnedLineCount,
            bytesAvoidedEstimate: original.content.utf8.count - content.utf8.count
        )
    }

    private static func bestLine(
        in window: JevContentJudgmentPolicy.ReadFile.Window,
        answer: JevContentJudgmentInterpreter.Answer?
    ) -> Int? {
        guard case let .choice(_, probabilities, _)? = answer else { return nil }
        let candidates = window.lines.indices.compactMap { offset -> (Int, Double)? in
            let line = window.firstLine + offset
            guard let probability = probabilities[JevContentJudgmentPolicy.ReadFile.lineID(line)],
                  probability.isFinite, (0 ... 1).contains(probability)
            else { return nil }
            return (line, probability)
        }
        guard let highest = candidates.map(\.1).max() else { return nil }
        let best = candidates.filter { $0.1 == highest }
        return best.count == 1 ? best[0].0 : nil
    }

    private static func mergedRanges(
        _ ranges: [ToolResultDTOs.ReadFileReply.LineRange]
    ) -> [ToolResultDTOs.ReadFileReply.LineRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [ToolResultDTOs.ReadFileReply.LineRange] = []
        for range in sorted {
            if let previous = merged.last, range.start <= previous.end + 1 {
                merged[merged.count - 1] = .init(start: previous.start, end: max(previous.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    @MainActor
    static func makeBaseReply(
        preparedContent: WorkspaceInteractiveReadPreparedContent,
        startLine1Based: Int?,
        lineCount: Int?,
        displayPath: String,
        lineRanges: [ToolResultDTOs.ReadFileReply.LineRange]? = nil,
        relevantTo: String? = nil,
        semanticFilter: ToolResultDTOs.ReadFileReply.SemanticFilter? = nil
    ) async throws -> PreparedReply {
        try await MCPProviderProjectionWorker.run(
            toolName: MCPWindowToolName.readFile,
            phase: "prepared_slice_dto"
        ) {
            let slice = try WorkspaceInteractiveReadProcessor.slice(
                preparedContent,
                startLine1Based: startLine1Based,
                lineCount: lineCount
            )
            return PreparedReply(
                reply: ToolResultDTOs.ReadFileReply(
                    content: slice.content,
                    totalLines: slice.totalLines,
                    firstLine: slice.firstLine,
                    lastLine: slice.lastLine,
                    message: slice.startExceededFileLength
                        ? "Requested start_line exceeds file length."
                        : nil,
                    displayPath: displayPath,
                    lineRanges: lineRanges,
                    relevantTo: relevantTo,
                    semanticFilter: semanticFilter
                ),
                returnedLineCount: lineRanges?.reduce(0) { $0 + $1.end - $1.start + 1 }
                    ?? slice.returnedLineCount
            )
        }
    }

    @MainActor
    static func projectReply(
        _ reply: ToolResultDTOs.ReadFileReply,
        displayPath: String?,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO?
    ) async throws -> ToolResultDTOs.ReadFileReply {
        try await MCPProviderProjectionWorker.run(
            toolName: MCPWindowToolName.readFile,
            phase: "reply_projection"
        ) {
            ToolResultDTOs.ReadFileReply(
                content: reply.content,
                totalLines: reply.totalLines,
                firstLine: reply.firstLine,
                lastLine: reply.lastLine,
                message: reply.message,
                displayPath: displayPath,
                worktreeScope: worktreeScope,
                lineRanges: reply.lineRanges,
                relevantTo: reply.relevantTo,
                semanticFilter: reply.semanticFilter
            )
        }
    }
}
