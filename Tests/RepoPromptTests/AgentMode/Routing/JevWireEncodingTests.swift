import Foundation
@testable import RepoPromptApp
import XCTest

/// Protects the shared `/v1/systemone` wire types after widening them for content judgments:
/// routing request bytes must not change, and `noul`/`score` answers must decode.
final class JevWireEncodingTests: XCTestCase {
    func testChoiceCriteriaEncodingIsByteIdenticalToRoutingShape() throws {
        let batch = try JevJudgmentBatch(questions: [
            JevJudgmentQuestion(id: "route", instructions: "Choose one.", criteria: [
                JevJudgmentCriterion(opaqueKey: "opaque-a", description: "Explore"),
                JevJudgmentCriterion(opaqueKey: "opaque-b", description: "Engineer")
            ])
        ])
        let widened = JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "TASK:\nfix it",
            questions: batch.wireQuestions()
        )
        let legacy = LegacyRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "TASK:\nfix it",
            questions: ["route": .init(
                type: "choice",
                instructions: "Choose one.",
                criteria: ["opaque-a": "Explore", "opaque-b": "Engineer"]
            )]
        )

        let widenedBytes = try Self.sortedEncoder.encode(widened)
        XCTAssertEqual(widenedBytes, try Self.sortedEncoder.encode(legacy))
        XCTAssertEqual(
            String(decoding: widenedBytes, as: UTF8.self),
            #"{"model":"jev-1.13.0","questions":{"route":{"criteria":{"opaque-a":"Explore","opaque-b":"Engineer"},"instructions":"Choose one.","type":"choice"}},"state":"TASK:\nfix it"}"#
        )
    }

    func testScoreLevelsEncodeAsOrderedArray() throws {
        let batch = try JevContentJudgmentBatch(state: "task", questions: [
            .score(id: "f000", instructions: "How relevant?", levels: ["Unrelated", "Useful", "Central"])
        ])
        let encoded = try String(decoding: Self.sortedEncoder.encode(batch.wireRequest()), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""f000":{"criteria":["Unrelated","Useful","Central"],"#), encoded)
        XCTAssertTrue(encoded.contains(#""type":"score""#), encoded)
    }

    func testNoulCriteriaEncodeTrueFalseMap() throws {
        let batch = try JevContentJudgmentBatch(state: "task", questions: [
            .noul(id: "present", instructions: "Is it present?", trueDescription: "Yes.", falseDescription: "No.")
        ])
        let encoded = try String(decoding: Self.sortedEncoder.encode(batch.wireRequest()), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""criteria":{"false":"No.","true":"Yes."}"#), encoded)
        XCTAssertTrue(encoded.contains(#""type":"noul""#), encoded)
    }

    func testContentBatchTransmitsEveryQuestionTypeInOneRequest() async throws {
        let transport = RecordingWireTransport(body: #"{"model":"jev-1.13.0","answers":{"present":{"type":"noul","noul":0.9}},"usage":{"input_tokens":3,"output_tokens":0}}"#)
        let batch = try JevContentJudgmentBatch(state: "QUERY: q", questions: [
            .choice(id: "rank", instructions: "Pick.", criteria: [
                .init(opaqueKey: "m000", description: "m000"),
                .init(opaqueKey: "m001", description: "m001")
            ]),
            .noul(id: "present", instructions: "Present?", trueDescription: "Yes.", falseDescription: "No."),
            .score(id: "score", instructions: "Rate.", levels: ["low", "high"])
        ])
        _ = try await JevRoutingClient(transport: transport)
            .judge(request: batch.wireRequest(), apiKey: "secret", timeout: .seconds(2))

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["rank"]?["criteria"] as? [String: String], ["m000": "m000", "m001": "m001"])
        XCTAssertEqual(questions["present"]?["criteria"] as? [String: String], ["true": "Yes.", "false": "No."])
        XCTAssertEqual(questions["score"]?["criteria"] as? [String], ["low", "high"])
        XCTAssertEqual(object["model"] as? String, JevRouterCredentialService.pinnedModel)
    }

    func testNoulAnswerDecodes() throws {
        let response = try decode(#"{"model":"jev-1.13.0","answers":{"present":{"type":"noul","noul":0.82}},"usage":{"input_tokens":7,"output_tokens":0}}"#)
        XCTAssertEqual(response.answers["present"], .init(type: "noul", noul: 0.82))
        XCTAssertNil(response.answers["present"]?.choice)
    }

    func testScoreAnswerDecodes() throws {
        let response = try decode(#"{"model":"jev-1.13.0","answers":{"f000":{"type":"score","score":2.35,"probabilities":{"0":0.05,"1":0.1,"2":0.3,"3":0.55},"legend":["Unrelated","Tangential","Useful context","Central"],"confidence":0.7}},"usage":{"input_tokens":40,"output_tokens":0}}"#)
        let answer = try XCTUnwrap(response.answers["f000"])
        XCTAssertEqual(answer.type, "score")
        XCTAssertEqual(answer.score, 2.35)
        XCTAssertEqual(answer.legend?.count, 4)
        XCTAssertEqual(answer.probabilities?["3"], 0.55)
        XCTAssertEqual(answer.confidence, 0.7)
    }

    func testRoutingInterpreterStillAcceptsChoiceOnlyResponse() throws {
        let response = try decode(#"{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.7,"b":0.3},"confidence":0.8}},"usage":{"input_tokens":4,"output_tokens":1}}"#)
        let validated = try JevRoutingResponseInterpreter().validate(response, batch: routeBatch())
        XCTAssertEqual(validated.answer(forQuestionID: "route"), .init(
            selectedOpaqueKey: "a",
            probabilities: ["a": 0.7, "b": 0.3],
            confidence: 0.8
        ))
    }

    /// Before widening, a non-choice answer failed decoding; it must still never validate as a route.
    func testRoutingInterpreterRejectsNoulShapedRouteAnswer() throws {
        let response = try decode(#"{"model":"jev-1.13.0","answers":{"route":{"type":"noul","noul":0.9}},"usage":{"input_tokens":4,"output_tokens":0}}"#)
        XCTAssertThrowsError(try JevRoutingResponseInterpreter().validate(response, batch: routeBatch())) {
            XCTAssertEqual($0 as? JevRoutingResponseInterpreter.ValidationError, .wrongAnswerShape)
        }
    }

    func testRoutingInterpreterRejectsChoiceAnswerWithoutConfidence() throws {
        let response = try decode(#"{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.7,"b":0.3}}},"usage":{"input_tokens":4,"output_tokens":0}}"#)
        XCTAssertThrowsError(try JevRoutingResponseInterpreter().validate(response, batch: routeBatch())) {
            XCTAssertEqual($0 as? JevRoutingResponseInterpreter.ValidationError, .invalidConfidence)
        }
    }

    private static var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decode(_ json: String) throws -> JevRoutingWireResponse {
        try JSONDecoder().decode(JevRoutingWireResponse.self, from: Data(json.utf8))
    }

    private func routeBatch() throws -> JevJudgmentBatch {
        try JevJudgmentBatch(questions: [
            JevJudgmentQuestion(id: "route", instructions: "route", criteria: [
                JevJudgmentCriterion(opaqueKey: "a", description: "A"),
                JevJudgmentCriterion(opaqueKey: "b", description: "B")
            ])
        ])
    }
}

/// The routing request type exactly as it was before `JevWireCriteria` existed.
private struct LegacyRoutingWireRequest: Encodable {
    struct Question: Encodable {
        let type: String
        let instructions: String
        let criteria: [String: String]
    }

    let model: String
    let state: String
    let questions: [String: Question]
}

private final class RecordingWireTransport: JevHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var bodies: [Data] = []

    init(body: String) {
        self.body = Data(body.utf8)
    }

    var lastBody: Data? {
        lock.withLock { bodies.last }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { bodies.append(request.httpBody ?? Data()) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}
