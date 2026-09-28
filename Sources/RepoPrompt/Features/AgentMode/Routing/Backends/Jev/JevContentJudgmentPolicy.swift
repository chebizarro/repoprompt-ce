import Foundation

/// A feature that submits content judgments. The raw value is the stable ledger/DTO identifier.
enum JevContentJudgmentConsumer: String, CaseIterable, Codable {
    case fileSearch = "file_search"
    case readFile = "read_file"
    case contextBuilder = "context_builder"
    case skillSuggestion = "skill_suggestion"
    case approvalAdvisory = "approval_advisory"

    var policyVersion: String {
        switch self {
        case .fileSearch: JevContentJudgmentPolicy.fileSearchRerank
        case .readFile: JevContentJudgmentPolicy.readFileWindows
        case .contextBuilder: JevContentJudgmentPolicy.contextBuilderPrePass
        case .skillSuggestion: JevContentJudgmentPolicy.skillSuggestion
        case .approvalAdvisory: JevContentJudgmentPolicy.approvalAdvisory
        }
    }
}

/// Pinned content-judgment policies.
///
/// Question wording, state shape, thresholds, and budgets are all part of a consumer's policy.
/// Any change to them must advance that consumer's version; `JevContentJudgmentPolicyTests` pins
/// the wire fixture and tuning of every version so an unversioned change fails.
enum JevContentJudgmentPolicy {
    static let fileSearchRerank = "jev-1.13.0-rpce-content-file-search-v1"
    static let readFileWindows = "jev-1.13.0-rpce-content-read-file-v1"
    static let contextBuilderPrePass = "jev-1.13.0-rpce-content-context-builder-v1"
    static let skillSuggestion = "jev-1.13.0-rpce-content-skill-suggestion-v1"
    static let approvalAdvisory = "jev-1.13.0-rpce-content-approval-advisory-v1"

    /// Presence bands measured by the `rpce-jev` live calibration on this repository.
    static let presenceHighThreshold = 0.70
    static let presenceLowThreshold = 0.35

    /// Per-request state budget in UTF-8 bytes (~28k tokens at ~1.6 chars/token), leaving headroom
    /// under the documented 32k-token limit for the longest question.
    static let stateCharBudget = 45000

    /// Process-wide egress guard: requests and submitted state bytes per sliding window.
    static let spendWindow: Duration = .seconds(300)
    static let maxRequestsPerSpendWindow = 60
    static let maxStateCharsPerSpendWindow = 2_000_000

    static func paddedID(prefix: String, index: Int, width: Int = 3) -> String {
        let digits = String(index)
        return prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: - file_search

    enum FileSearch {
        struct Match: Equatable {
            let displayPath: String
            let line: Int
            let text: String
        }

        static let budget: Duration = .seconds(2)
        static let maxLineChars = 400
        static let rankQuestionID = "rank"
        static let presenceQuestionID = "present"

        static func matchID(_ index: Int) -> String {
            paddedID(prefix: "m", index: index)
        }

        /// Display paths only; callers must never pass absolute physical paths.
        static func state(query: String, matches: [Match]) -> String {
            let lines = matches.enumerated().map { index, match in
                "\(matchID(index))|\(match.displayPath):\(match.line): \(String(match.text.prefix(maxLineChars)))"
            }
            return "QUERY: \(query)\nMATCHES:\n" + lines.joined(separator: "\n")
        }

        static func questions(matchIDs: [String]) -> [JevContentJudgmentQuestion] {
            [
                .choice(
                    id: rankQuestionID,
                    instructions: "Each match in `MATCHES` is prefixed with an id and `|`. Rank which matches most directly help answer or advance `QUERY`. Choose the id.",
                    criteria: matchIDs.map { JevJudgmentCriterion(opaqueKey: $0, description: $0) }
                ),
                .noul(
                    id: presenceQuestionID,
                    instructions: "Does any match in `MATCHES` address `QUERY`?",
                    trueDescription: "At least one hit is the code or text the query is looking for.",
                    falseDescription: "Every hit is a false positive, an unrelated mention, or only superficially related."
                )
            ]
        }
    }

    // MARK: - read_file

    enum ReadFile {
        struct Window: Equatable {
            /// 1-based line number of the first line in `lines`.
            let firstLine: Int
            let lines: [String]
        }

        static let budget: Duration = .seconds(2)
        static let presenceBudget: Duration = .milliseconds(1200)
        static let choiceBudget: Duration = .milliseconds(800)
        static let maxWindowLines = 128
        static let highPresenceTrimRadius = 32
        static let midPresenceTrimRadius = 16

        static func windowID(_ index: Int) -> String {
            "w\(index)"
        }

        static func lineID(_ lineNumber: Int) -> String {
            paddedID(prefix: "L", index: lineNumber, width: 5)
        }

        static func presenceQuestionID(windowID: String) -> String {
            "present_\(windowID)"
        }

        static func choiceQuestionID(windowID: String) -> String {
            "best_\(windowID)"
        }

        static func state(relevantTo: String, windows: [Window]) -> String {
            let lines = windows.enumerated().flatMap { index, window in
                window.lines.enumerated().map { offset, text in
                    "\(windowID(index))|\(lineID(window.firstLine + offset))|\(text)"
                }
            }
            return "relevant_to: \(relevantTo)\nLINES:\n" + lines.joined(separator: "\n")
        }

        static func presenceQuestions(windowIDs: [String]) -> [JevContentJudgmentQuestion] {
            windowIDs.map { windowID in
                .noul(
                    id: presenceQuestionID(windowID: windowID),
                    instructions: "Does any line of window `\(windowID)` in `LINES` address, implement, or directly imply content relevant to `relevant_to`?",
                    trueDescription: "At least one line states, implements, or directly implies relevant content.",
                    falseDescription: "No line addresses the intent; the closest lines are only loosely related."
                )
            }
        }

        static func choiceQuestion(windowID: String, lineIDs: [String]) -> JevContentJudgmentQuestion {
            .choice(
                id: choiceQuestionID(windowID: windowID),
                instructions: "Each line in `LINES` is prefixed with its window id and line id. Which line of window `\(windowID)` most directly answers `relevant_to`? Choose the line id.",
                criteria: lineIDs.map { JevJudgmentCriterion(opaqueKey: $0, description: $0) }
            )
        }
    }

    // MARK: - Context Builder (PR 2)

    enum ContextBuilder {
        struct File: Encodable {
            let path: String
            let excerpt: String
        }

        private struct State: Encodable {
            let task: String
            let files: [String: File]
        }

        static func state(task: String, files: [String: File]) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(State(task: task, files: files)) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func section(central: [String], useful: [String], unranked: [String]) -> String {
            var lines = ["Likely relevant files", "central:"]
            lines += central.map { "- \($0)" }
            lines.append("useful context:")
            lines += useful.map { "- \($0)" }
            if !unranked.isEmpty {
                lines.append("unranked selected files:")
                lines += unranked.map { "- \($0)" }
            }
            lines.append("Other selected files may be unranked or ranked low.")
            return lines.joined(separator: "\n")
        }

        static let budgetPerBatch: Duration = .seconds(3)
        static let filesPerBatch = 40
        static let maxBatches = 2
        static let excerptLines = 40
        static let centralThreshold = 2.5
        static let centralLimit = 10
        static let usefulThreshold = 1.5
        static let usefulLimit = 15
        static let relevanceLevels = [
            "Unrelated: the file does not touch the task's concepts, symbols, or data flow.",
            "Tangential: shares vocabulary or is a distant dependency; reading it would not change how the task is done.",
            "Useful context: defines a type, protocol, or helper the task must use correctly; likely read, unlikely edited.",
            "Central: the task almost certainly requires reading and probably editing this file."
        ]

        static func fileID(_ index: Int) -> String {
            paddedID(prefix: "f", index: index)
        }

        static func questions(fileIDs: [String]) -> [JevContentJudgmentQuestion] {
            fileIDs.map { fileID in
                .score(
                    id: fileID,
                    instructions: "How relevant is the file `files.\(fileID)` (path `files.\(fileID).path`, excerpt in `files.\(fileID).excerpt`) to completing `task`? Judge from the excerpt and the path; the excerpt may be only the head.",
                    levels: relevanceLevels
                )
            }
        }
    }

    // MARK: - Composer skill suggestion (PR 3)

    enum SkillSuggestion {
        struct Skill: Equatable {
            let name: String
            let description: String
        }

        static let stageBudget: Duration = .milliseconds(1500)
        static let debounce: Duration = .milliseconds(600)
        static let catalogLimit = 30
        static let descriptionChars = 160
        static let skillBodyChars = 700
        static let gateThreshold = 0.30
        static let fitThreshold = 0.30
        static let minimumWhichProbability = 0.40
        static let noneKey = "none"
        static let whichQuestionID = "which"
        static let actsQuestionID = "acts"
        static let procedureQuestionID = "procedure"
        static let proseQuestionID = "prose"
        static let fitQuestionID = "fit"

        static func stageOneQuestions(skills: [Skill]) -> [JevContentJudgmentQuestion] {
            let skillCriteria = skills.map {
                JevJudgmentCriterion(opaqueKey: $0.name, description: String($0.description.prefix(descriptionChars)))
            }
            return [
                .choice(
                    id: whichQuestionID,
                    instructions: "Which entry in `skills` (name -> description) is the documented procedure the agent should load to handle `request`? Choose `none` if no listed skill applies.",
                    criteria: skillCriteria + [JevJudgmentCriterion(
                        opaqueKey: noneKey,
                        description: "No listed skill is a good fit; the agent should proceed without loading one."
                    )]
                ),
                .noul(
                    id: actsQuestionID,
                    instructions: "Does `request` require the agent to act on the repository, tooling, or system (edit, run, validate, release), rather than only explain?",
                    trueDescription: "The request asks for changes, commands, validation, or other actions.",
                    falseDescription: "The request only asks for an explanation or information."
                ),
                .noul(
                    id: procedureQuestionID,
                    instructions: "Would a documented, repository-specific procedure or checklist materially improve how `request` is handled?",
                    trueDescription: "A repository-specific procedure would change or improve the outcome.",
                    falseDescription: "General knowledge is enough; a procedure would not change the outcome."
                ),
                .noul(
                    id: proseQuestionID,
                    instructions: "Can `request` be fully satisfied with a direct prose answer, with no tool use or procedure?",
                    trueDescription: "A direct written answer fully satisfies the request.",
                    falseDescription: "The request needs tool use, repository work, or a procedure."
                )
            ]
        }

        static func stageTwoQuestions() -> [JevContentJudgmentQuestion] {
            [
                .noul(
                    id: fitQuestionID,
                    instructions: "Does the candidate specifically cover the kind of work described in `request`, such that following it would be appropriate?",
                    trueDescription: "The candidate's procedure is written for this kind of request.",
                    falseDescription: "The candidate is only loosely related or covers different work."
                )
            ]
        }
    }

    // MARK: - Approval advisory (PR 3)

    enum ApprovalAdvisory {
        static let budget: Duration = .milliseconds(1500)
        static let threshold = 0.70
        static let questionID = "irreversible"

        static func questions() -> [JevContentJudgmentQuestion] {
            [
                .noul(
                    id: questionID,
                    instructions: "Is this action practically irreversible?",
                    trueDescription: "Undoing it requires manual recovery beyond ordinary version control or the Trash — for example deleting untracked files, external/network side effects, or unrecoverable overwrites.",
                    falseDescription: "The effect is recoverable through Git, the Trash, or safely re-running a step."
                )
            ]
        }
    }
}
