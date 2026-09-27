import CryptoKit
import Foundation
@testable import RepoPromptApp
import XCTest

/// Question wording, state shape, thresholds, and budgets are a consumer's policy. Each policy
/// version pins a digest of its deterministic wire fixture plus tuning, so any change must either
/// advance the version (and add a digest) or fail here.
final class JevContentJudgmentPolicyTests: XCTestCase {
    /// Update only together with a policy version bump. The failure message prints the new digest
    /// and the canonical fixture so the change can be reviewed.
    private static let pinnedDigests: [String: String] = [
        "jev-1.13.0-rpce-content-file-search-v1": "f3457e087c27da725b9046e879205f05f19b597e8d72a50316bd336ab8006f0a",
        "jev-1.13.0-rpce-content-read-file-v1": "44035602f79f4e145e0a66d5d548cff04e95b3e61ae354c3459c402b3f2411f3",
        "jev-1.13.0-rpce-content-context-builder-v1": "841e53b872dc279b6ad7b8961bd0e4fe692377dd4f4ee198de6f22dd576308b2",
        "jev-1.13.0-rpce-content-skill-suggestion-v1": "909c482ac7583c00bcb780357e6dfe7c5271df9761917e8f9333f4edbfc112b2",
        "jev-1.13.0-rpce-content-approval-advisory-v1": "f70807ca6355bdc56314f8619c0bf39d3d05197b11155c92b7ca1496e3ea8a81"
    ]

    func testEveryConsumerHasAUniquePinnedModelPolicyVersion() {
        let versions = JevContentJudgmentConsumer.allCases.map(\.policyVersion)
        XCTAssertEqual(Set(versions).count, versions.count)
        for version in versions {
            XCTAssertTrue(version.hasPrefix("\(JevRouterCredentialService.pinnedModel)-rpce-content-"), version)
        }
        XCTAssertEqual(JevContentJudgmentConsumer.fileSearch.policyVersion, JevContentJudgmentPolicy.fileSearchRerank)
        XCTAssertEqual(JevContentJudgmentConsumer.readFile.policyVersion, JevContentJudgmentPolicy.readFileWindows)
        XCTAssertEqual(JevContentJudgmentConsumer.contextBuilder.policyVersion, JevContentJudgmentPolicy.contextBuilderPrePass)
        XCTAssertEqual(JevContentJudgmentConsumer.skillSuggestion.policyVersion, JevContentJudgmentPolicy.skillSuggestion)
        XCTAssertEqual(JevContentJudgmentConsumer.approvalAdvisory.policyVersion, JevContentJudgmentPolicy.approvalAdvisory)
    }

    func testWireFixtureAndTuningArePinnedPerPolicyVersion() throws {
        for consumer in JevContentJudgmentConsumer.allCases {
            let fixture = try Self.canonicalFixture(for: consumer)
            let digest = SHA256.hash(data: Data(fixture.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                Self.pinnedDigests[consumer.policyVersion],
                digest,
                "\(consumer.rawValue) policy changed without a version bump. If intended, advance \(consumer.policyVersion) and pin \(digest). Fixture:\n\(fixture)"
            )
        }
    }

    func testReadFileWindowAndPresenceBandsMatchCalibratedRecipe() {
        XCTAssertLessThan(JevContentJudgmentPolicy.presenceLowThreshold, JevContentJudgmentPolicy.presenceHighThreshold)
        XCTAssertLessThanOrEqual(JevContentJudgmentPolicy.ReadFile.maxWindowLines, JevContentJudgmentBatch.maxChoiceCriteria)
        XCTAssertEqual(
            JevContentJudgmentPolicy.ReadFile.presenceBudget + JevContentJudgmentPolicy.ReadFile.choiceBudget,
            JevContentJudgmentPolicy.ReadFile.budget
        )
        XCTAssertLessThanOrEqual(
            JevContentJudgmentPolicy.ContextBuilder.relevanceLevels.count,
            JevContentJudgmentBatch.scoreLevelRange.upperBound
        )
    }

    func testFileSearchStateTruncatesLinesAndUsesDisplayPaths() {
        let long = String(repeating: "x", count: JevContentJudgmentPolicy.FileSearch.maxLineChars + 50)
        let state = JevContentJudgmentPolicy.FileSearch.state(query: "q", matches: [
            .init(displayPath: "Sources/A.swift", line: 7, text: long)
        ])
        XCTAssertEqual(
            state,
            "QUERY: q\nMATCHES:\nm000|Sources/A.swift:7: " + String(repeating: "x", count: JevContentJudgmentPolicy.FileSearch.maxLineChars)
        )
    }

    // MARK: - Canonical fixtures

    private static func canonicalFixture(for consumer: JevContentJudgmentConsumer) throws -> String {
        typealias Policy = JevContentJudgmentPolicy
        let shared = "presence=\(Policy.presenceHighThreshold)/\(Policy.presenceLowThreshold) state=\(Policy.stateCharBudget) spend=\(Policy.spendWindow)/\(Policy.maxRequestsPerSpendWindow)/\(Policy.maxStateCharsPerSpendWindow)"
        let tuning: String
        let batches: [JevContentJudgmentBatch]
        switch consumer {
        case .fileSearch:
            typealias P = Policy.FileSearch
            tuning = "budget=\(P.budget) maxLineChars=\(P.maxLineChars)"
            let matches: [P.Match] = [
                .init(displayPath: "Sources/Parser.swift", line: 12, text: "func parse(_ input: String)"),
                .init(displayPath: "Tests/ParserTests.swift", line: 3, text: "final class ParserTests")
            ]
            batches = try [JevContentJudgmentBatch(
                state: P.state(query: "where is input parsed", matches: matches),
                questions: P.questions(matchIDs: matches.indices.map(P.matchID))
            )]
        case .readFile:
            typealias P = Policy.ReadFile
            tuning = "budget=\(P.budget) presence=\(P.presenceBudget) choice=\(P.choiceBudget) window=\(P.maxWindowLines) trim=\(P.highPresenceTrimRadius)/\(P.midPresenceTrimRadius)"
            let windows: [P.Window] = [.init(firstLine: 1, lines: ["import Foundation", "struct Parser {}"])]
            let state = P.state(relevantTo: "parser type", windows: windows)
            let windowID = P.windowID(0)
            batches = try [
                JevContentJudgmentBatch(state: state, questions: P.presenceQuestions(windowIDs: [windowID])),
                JevContentJudgmentBatch(state: state, questions: [
                    P.choiceQuestion(windowID: windowID, lineIDs: [P.lineID(1), P.lineID(2)])
                ])
            ]
        case .contextBuilder:
            typealias P = Policy.ContextBuilder
            tuning = "budget=\(P.budgetPerBatch) files=\(P.filesPerBatch)x\(P.maxBatches) excerpt=\(P.excerptLines) central=\(P.centralThreshold)/\(P.centralLimit) useful=\(P.usefulThreshold)/\(P.usefulLimit)"
            batches = try [JevContentJudgmentBatch(state: "task", questions: P.questions(fileIDs: [P.fileID(0), P.fileID(1)]))]
        case .skillSuggestion:
            typealias P = Policy.SkillSuggestion
            tuning = "budget=\(P.stageBudget) debounce=\(P.debounce) catalog=\(P.catalogLimit) description=\(P.descriptionChars) body=\(P.skillBodyChars) gate=\(P.gateThreshold) fit=\(P.fitThreshold) which=\(P.minimumWhichProbability) none=\(P.noneKey)"
            batches = try [
                JevContentJudgmentBatch(state: "request", questions: P.stageOneQuestions(skills: [
                    .init(name: "release", description: "Cut a release.")
                ])),
                JevContentJudgmentBatch(state: "request", questions: P.stageTwoQuestions())
            ]
        case .approvalAdvisory:
            typealias P = Policy.ApprovalAdvisory
            tuning = "budget=\(P.budget) threshold=\(P.threshold)"
            batches = try [JevContentJudgmentBatch(state: "command: rm -rf build", questions: P.questions())]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let wire = try batches.map { try String(decoding: encoder.encode($0.wireRequest()), as: UTF8.self) }
        return ([consumer.policyVersion, shared, tuning] + wire).joined(separator: "\n")
    }
}
