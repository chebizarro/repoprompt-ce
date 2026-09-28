import Foundation
@testable import RepoPromptApp
import XCTest

/// A batch is the last local gate before content leaves the machine, so every documented API limit
/// must be rejected before a request can be built.
final class JevContentJudgmentBatchTests: XCTestCase {
    func testStateAtBudgetIsAcceptedAndOneByteOverIsRejected() throws {
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: String(repeating: "a", count: 10), questions: [presence()], charBudget: 10))
        assertRejection(.stateOverBudget(11)) {
            try JevContentJudgmentBatch(state: String(repeating: "a", count: 11), questions: [presence()], charBudget: 10)
        }
    }

    func testStateBudgetCountsUTF8BytesNotCharacters() {
        // Four characters, twelve UTF-8 bytes: the conservative measure must reject it.
        assertRejection(.stateOverBudget(12)) {
            try JevContentJudgmentBatch(state: "日本語日", questions: [presence()], charBudget: 10)
        }
    }

    func testDefaultBudgetIsThePolicyStateBudget() throws {
        let fits = String(repeating: "a", count: JevContentJudgmentPolicy.stateCharBudget)
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: fits, questions: [presence()]))
        assertRejection(.stateOverBudget(JevContentJudgmentPolicy.stateCharBudget + 1)) {
            try JevContentJudgmentBatch(state: fits + "a", questions: [presence()])
        }
    }

    func testBlankStateIsRejected() {
        assertRejection(.emptyState) { try JevContentJudgmentBatch(state: " \n\t", questions: [presence()]) }
    }

    func testEmptyQuestionsAreRejected() {
        assertRejection(.emptyQuestions) { try JevContentJudgmentBatch(state: "s", questions: []) }
    }

    func testQuestionIDsMustBeNonEmptyAndUnique() {
        assertRejection(.emptyQuestionID) { try JevContentJudgmentBatch(state: "s", questions: [presence(id: "")]) }
        assertRejection(.duplicateQuestionID("p")) {
            try JevContentJudgmentBatch(state: "s", questions: [presence(id: "p"), presence(id: "p")])
        }
    }

    func testChoiceAcceptsTwoTo255CriteriaAndRejectsMore() throws {
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: "s", questions: [choice(count: 2)]))
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: "s", questions: [choice(count: 255)]))
        assertRejection(.tooManyChoiceCriteria(256)) { try JevContentJudgmentBatch(state: "s", questions: [choice(count: 256)]) }
        assertRejection(.tooFewChoiceCriteria(questionID: "c")) {
            try JevContentJudgmentBatch(state: "s", questions: [choice(count: 1)])
        }
    }

    func testChoiceRejectsEmptyAndDuplicateKeys() {
        assertRejection(.invalidChoiceCriterion(questionID: "c")) {
            try JevContentJudgmentBatch(state: "s", questions: [.choice(id: "c", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"), .init(opaqueKey: "a", description: "B")
            ])])
        }
        assertRejection(.invalidChoiceCriterion(questionID: "c")) {
            try JevContentJudgmentBatch(state: "s", questions: [.choice(id: "c", instructions: "i", criteria: [
                .init(opaqueKey: "a", description: "A"), .init(opaqueKey: "", description: "B")
            ])])
        }
    }

    func testNoulRequiresBothDescriptions() {
        assertRejection(.invalidNoulCriteria(questionID: "n")) {
            try JevContentJudgmentBatch(state: "s", questions: [
                .noul(id: "n", instructions: "i", trueDescription: "", falseDescription: "No.")
            ])
        }
        assertRejection(.invalidNoulCriteria(questionID: "n")) {
            try JevContentJudgmentBatch(state: "s", questions: [
                .noul(id: "n", instructions: "i", trueDescription: "Yes.", falseDescription: "")
            ])
        }
    }

    func testScoreAcceptsTwoToTenLevels() throws {
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: "s", questions: [score(levels: 2)]))
        XCTAssertNoThrow(try JevContentJudgmentBatch(state: "s", questions: [score(levels: 10)]))
        assertRejection(.invalidScoreLevels(1)) { try JevContentJudgmentBatch(state: "s", questions: [score(levels: 1)]) }
        assertRejection(.invalidScoreLevels(11)) { try JevContentJudgmentBatch(state: "s", questions: [score(levels: 11)]) }
    }

    func testWireRequestUsesPinnedModelAndPerTypeCriteria() throws {
        let batch = try JevContentJudgmentBatch(state: "state", questions: [choice(count: 2), presence(), score(levels: 2)])
        let wire = batch.wireRequest()
        XCTAssertEqual(wire.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(wire.state, "state")
        XCTAssertEqual(wire.questions["c"], .init(type: "choice", instructions: "i", criteria: ["k0": "K0", "k1": "K1"]))
        XCTAssertEqual(wire.questions["p"], .init(type: "noul", instructions: "i", criteria: ["true": "Yes.", "false": "No."]))
        XCTAssertEqual(wire.questions["s"], .init(type: "score", instructions: "i", criteria: .levels(["L0", "L1"])))
        XCTAssertEqual(batch.questionIDs, ["c", "p", "s"])
        XCTAssertEqual(batch.stateCharCount, 5)
    }

    func testJSONStateIsDeterministicWithSortedKeys() throws {
        struct State: Encodable {
            let task: String
            let files: [String: String]
        }
        let state = try JevContentJudgmentBatch.jsonState(State(task: "t/x", files: ["f001": "b", "f000": "a"]))
        XCTAssertEqual(state, #"{"files":{"f000":"a","f001":"b"},"task":"t/x"}"#)
    }

    private func presence(id: String = "p") -> JevContentJudgmentQuestion {
        .noul(id: id, instructions: "i", trueDescription: "Yes.", falseDescription: "No.")
    }

    private func choice(count: Int) -> JevContentJudgmentQuestion {
        .choice(id: "c", instructions: "i", criteria: (0 ..< count).map { .init(opaqueKey: "k\($0)", description: "K\($0)") })
    }

    private func score(levels: Int) -> JevContentJudgmentQuestion {
        .score(id: "s", instructions: "i", levels: (0 ..< levels).map { "L\($0)" })
    }

    private func assertRejection(
        _ expected: JevContentJudgmentRejection,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ build: () throws -> JevContentJudgmentBatch
    ) {
        XCTAssertThrowsError(try build(), file: file, line: line) {
            XCTAssertEqual($0 as? JevContentJudgmentRejection, expected, file: file, line: line)
        }
    }
}
