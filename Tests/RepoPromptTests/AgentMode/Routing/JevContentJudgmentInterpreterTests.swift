import Foundation
@testable import RepoPromptApp
import XCTest

/// Content judgments salvage what they can: one malformed answer must degrade only that question,
/// while evaluator identity and usage still gate the whole response.
final class JevContentJudgmentInterpreterTests: XCTestCase {
    func testChoiceAcceptsPartialCoverageWithoutUniqueArgmax() throws {
        let result = try interpret([
            "rank": .init(type: "choice", choice: "m001", probabilities: ["m000": 0.4, "m001": 0.4], confidence: 0.5)
        ])
        XCTAssertEqual(
            result.answers["rank"],
            .choice(selectedKey: "m001", probabilities: ["m000": 0.4, "m001": 0.4], confidence: 0.5)
        )
    }

    func testChoiceWithUnknownKeyIsInvalidWithoutFailingSiblingQuestions() throws {
        let result = try interpret([
            "rank": .init(type: "choice", choice: "m000", probabilities: ["m000": 0.6, "smuggled": 0.4], confidence: 0.5),
            "present": .init(type: "noul", noul: 0.8),
            "score": .init(type: "score", score: 1)
        ])
        XCTAssertEqual(result.answers["rank"], .invalid(reason: .unknownKey))
        XCTAssertEqual(result.answers["present"], .noul(value: 0.8))
        XCTAssertEqual(result.answers["score"], .score(level: 1, weighted: 1))
    }

    func testChoiceRejectsUnsubmittedSelectionMissingFieldsAndBadValues() throws {
        let cases: [(JevRoutingWireResponse.Answer, JevContentJudgmentInterpreter.InvalidReason)] = [
            (.init(type: "choice", choice: "zzz", probabilities: ["m000": 1], confidence: 0.5), .unknownKey),
            (.init(type: "choice", probabilities: ["m000": 1], confidence: 0.5), .missingValue),
            (.init(type: "choice", choice: "m000", probabilities: [:], confidence: 0.5), .missingValue),
            (.init(type: "choice", choice: "m000", probabilities: ["m000": 1.2], confidence: 0.5), .valueOutOfRange),
            (.init(type: "choice", choice: "m000", probabilities: ["m000": .nan], confidence: 0.5), .valueOutOfRange),
            (.init(type: "choice", choice: "m000", probabilities: ["m000": 1]), .invalidConfidence),
            (.init(type: "choice", choice: "m000", probabilities: ["m000": 1], confidence: -0.1), .invalidConfidence)
        ]
        for (answer, reason) in cases {
            XCTAssertEqual(try interpret(["rank": answer]).answers["rank"], .invalid(reason: reason), "\(answer)")
        }
    }

    func testNoulMustBeAFiniteProbability() throws {
        XCTAssertEqual(try interpret(["present": .init(type: "noul", noul: 0)]).answers["present"], .noul(value: 0))
        XCTAssertEqual(try interpret(["present": .init(type: "noul", noul: 1)]).answers["present"], .noul(value: 1))
        XCTAssertEqual(
            try interpret(["present": .init(type: "noul", noul: 1.01)]).answers["present"],
            .invalid(reason: .valueOutOfRange)
        )
        XCTAssertEqual(
            try interpret(["present": .init(type: "noul", noul: .infinity)]).answers["present"],
            .invalid(reason: .valueOutOfRange)
        )
        XCTAssertEqual(
            try interpret(["present": .init(type: "noul")]).answers["present"],
            .invalid(reason: .missingValue)
        )
    }

    func testScoreUsesProbabilityWeightedLevelAndArgmax() throws {
        let answer = try interpret([
            "score": .init(type: "score", probabilities: ["0": 0.1, "1": 0.2, "2": 0.3, "3": 0.4], confidence: 0.6, score: 2)
        ]).answers["score"]
        guard case let .score(level, weighted) = answer else { return XCTFail("Expected a score, got \(String(describing: answer))") }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(weighted, 2.0, accuracy: 1e-9)
    }

    func testScoreMapsLegendKeyedProbabilities() throws {
        let answer = try interpret([
            "score": .init(
                type: "score",
                probabilities: ["Zero": 0.5, "One": 0.0, "Two": 0.0, "Three": 0.5],
                legend: ["Zero", "One", "Two", "Three"]
            )
        ]).answers["score"]
        // Equal top probabilities resolve to the lower level.
        XCTAssertEqual(answer, .score(level: 0, weighted: 1.5))
    }

    func testScoreFallsBackToReportedLevelWhenDistributionIsUnusable() throws {
        let answer = try interpret([
            "score": .init(type: "score", probabilities: ["unmapped": 1], score: 2.35)
        ]).answers["score"]
        XCTAssertEqual(answer, .score(level: 2, weighted: 2.35))
    }

    func testScoreOutsideSubmittedLevelsOrMissingIsInvalid() throws {
        XCTAssertEqual(
            try interpret(["score": .init(type: "score", score: 3.5)]).answers["score"],
            .invalid(reason: .valueOutOfRange)
        )
        XCTAssertEqual(
            try interpret(["score": .init(type: "score", score: -1)]).answers["score"],
            .invalid(reason: .valueOutOfRange)
        )
        XCTAssertEqual(
            try interpret(["score": .init(type: "score")]).answers["score"],
            .invalid(reason: .missingValue)
        )
    }

    func testMissingWrongTypeAndUnsubmittedAnswers() throws {
        let result = try interpret([
            "rank": .init(type: "noul", noul: 0.5),
            "smuggled": .init(type: "noul", noul: 0.5)
        ])
        XCTAssertEqual(result.answers["rank"], .invalid(reason: .wrongType))
        XCTAssertEqual(result.answers["present"], .invalid(reason: .missingAnswer))
        XCTAssertEqual(result.answers["score"], .invalid(reason: .missingAnswer))
        XCTAssertNil(result.answers["smuggled"])
        XCTAssertEqual(Set(result.answers.keys), ["rank", "present", "score"])
    }

    func testUsageIsReported() throws {
        let result = try interpret(["present": .init(type: "noul", noul: 0.5)], usage: .init(inputTokens: 123, outputTokens: 0))
        XCTAssertEqual(result.inputTokens, 123)
        XCTAssertEqual(result.outputTokens, 0)
    }

    func testWrongEvaluatorAndNegativeUsageFailTheWholeResponse() throws {
        let batch = try makeBatch()
        XCTAssertThrowsError(try JevContentJudgmentInterpreter().interpret(
            .init(model: "jev-9", answers: [:], usage: .init(inputTokens: 1, outputTokens: 0)),
            batch: batch
        )) { XCTAssertEqual($0 as? JevContentJudgmentInterpreter.ResponseError, .wrongEvaluator) }
        XCTAssertThrowsError(try JevContentJudgmentInterpreter().interpret(
            .init(model: JevRouterCredentialService.pinnedModel, answers: [:], usage: .init(inputTokens: -1, outputTokens: 0)),
            batch: batch
        )) { XCTAssertEqual($0 as? JevContentJudgmentInterpreter.ResponseError, .invalidUsage) }
    }

    private func makeBatch() throws -> JevContentJudgmentBatch {
        try JevContentJudgmentBatch(state: "QUERY: q", questions: [
            .choice(id: "rank", instructions: "i", criteria: [
                .init(opaqueKey: "m000", description: "m000"),
                .init(opaqueKey: "m001", description: "m001"),
                .init(opaqueKey: "m002", description: "m002")
            ]),
            .noul(id: "present", instructions: "i", trueDescription: "Yes.", falseDescription: "No."),
            .score(id: "score", instructions: "i", levels: ["L0", "L1", "L2", "L3"])
        ])
    }

    private func interpret(
        _ answers: [String: JevRoutingWireResponse.Answer],
        usage: JevRoutingWireResponse.Usage = .init(inputTokens: 10, outputTokens: 0)
    ) throws -> JevContentJudgmentInterpreter.Interpretation {
        try JevContentJudgmentInterpreter().interpret(
            .init(model: JevRouterCredentialService.pinnedModel, answers: answers, usage: usage),
            batch: makeBatch()
        )
    }
}
