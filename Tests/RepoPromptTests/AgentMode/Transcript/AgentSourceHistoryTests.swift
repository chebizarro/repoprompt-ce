import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class AgentSourceHistoryTests: XCTestCase {
    func testCaptureRetainsIdentityThroughRemovalRevisionAndRestart() throws {
        var history = AgentSourceHistory()
        let user = AgentChatItem.user("  hello 🌍\n", sequenceIndex: 0)
        var assistant = AgentChatItem.assistant("first", sequenceIndex: 1)
        assistant.isStreaming = true
        history.capture([user, .thinking("private", sequenceIndex: 2), assistant])
        XCTAssertEqual(history.revision, 2)
        history.capture([user, assistant])
        XCTAssertEqual(history.revision, 2)
        history.capture([]) // retention is not deletion
        assistant.text = "first 🐱"
        history.capture([assistant])
        var restored = try JSONDecoder().decode(AgentSourceHistory.self, from: JSONEncoder().encode(history))
        assistant.text = "a non-prefix edit"
        assistant.kind = .assistantInline
        restored.capture([assistant])
        assistant.isStreaming = false
        restored.capture([assistant])
        let records = try restored.materialize(through: restored.revision)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[user.id]?.text, user.text)
        XCTAssertEqual(records[assistant.id]?.text, assistant.text)
        XCTAssertEqual(records[assistant.id]?.ordinal, 2)
        XCTAssertEqual(restored.revision, 5)
        XCTAssertEqual(try restored.materialize(through: 2)[assistant.id]?.text, "first")
    }

    func testFixedPagesSurviveLaterEditsAndJSONByteBounds() throws {
        var history = AgentSourceHistory()
        let one = AgentChatItem.user("same", sequenceIndex: 0)
        var two = AgentChatItem.assistant("same", sequenceIndex: 1)
        history.capture([one, two])
        let session = UUID()
        let first = try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: nil, limit: 1, maxBytes: 4096)
        XCTAssertFalse(first.complete)
        two.text = "changed"
        history.capture([two])
        let second = try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: first.nextCursor, after: nil, limit: 1, maxBytes: 4096)
        XCTAssertTrue(second.complete)
        XCTAssertEqual(second.headRevision, 2)
        XCTAssertEqual(second.records.first?.text, "same")
        let changes = try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: 2, limit: 100, maxBytes: 4096)
        XCTAssertEqual(changes.records.map(\.occurrenceID), [two.id])
        XCTAssertEqual(changes.records.first?.text, "changed")
        XCTAssertThrowsError(try AgentSourceHistoryPage.make(history: history, sessionID: UUID(), cursor: first.nextCursor, after: nil, limit: 1, maxBytes: 4096))
        two.text = String(repeating: "\"🌍\n", count: 500)
        history.capture([two])
        XCTAssertThrowsError(try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: 3, limit: 100, maxBytes: 1024))
        let page = try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: 3, limit: 100, maxBytes: 16384)
        let data = try AgentSourceHistoryPage.wireEncoder().encode(page)
        XCTAssertLessThanOrEqual(data.count, 16384)
        let raw = try ToolOutputFormatter.rawJSONString(JSONDecoder().decode(Value.self, from: data))
        XCTAssertEqual(raw.utf8.count, data.count)
        let exact = try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: 3, limit: 100, maxBytes: data.count)
        XCTAssertEqual(try AgentSourceHistoryPage.wireEncoder().encode(exact).count, data.count)
        XCTAssertThrowsError(try AgentSourceHistoryPage.make(history: history, sessionID: session, cursor: nil, after: 3, limit: 100, maxBytes: data.count - 1))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["feed_id"])
        XCTAssertEqual((json["records"] as? [[String: Any]])?.first?["text"] as? String, two.text)
    }

    func testByteExactRevisionsAndIntegrityRefusal() throws {
        var history = AgentSourceHistory()
        var item = AgentChatItem.assistant("é", sequenceIndex: 0)
        history.capture([item])
        item.text = "e\u{301}"
        history.capture([item])
        XCTAssertEqual(history.revision, 2)
        let stale = history
        item.text = "next"
        history.capture([item])
        XCTAssertEqual(try AgentSourceHistory.merged(stale, with: history)?.revision, 3)
        var divergent = stale
        item.text = "different"
        divergent.capture([item])
        XCTAssertThrowsError(try AgentSourceHistory.merged(divergent, with: history))
        item.kind = .user
        history.capture([item])
        XCTAssertThrowsError(try history.materialize(through: history.revision))
    }

    func testCanonicallyEquivalentBytesCannotReplaceAnExposedRevision() throws {
        let item = AgentChatItem.assistant("é", sequenceIndex: 0)
        var a = AgentSourceHistory()
        a.capture([item])
        var bytes = try XCTUnwrap(String(data: JSONEncoder().encode(a), encoding: .utf8))
        bytes = bytes.replacingOccurrences(of: "é", with: "e\u{301}")
        let b = try JSONDecoder().decode(AgentSourceHistory.self, from: Data(bytes.utf8))
        XCTAssertThrowsError(try AgentSourceHistory.merged(a, with: b))
    }

    func testDuplicateIDRepairIsSharedByFeedAndTranscript() throws {
        let a = AgentChatItem.assistant("one", sequenceIndex: 0)
        var b = a
        b.text = "two"
        b.sequenceIndex = 1
        let legacy = AgentSession(serializationVersion: 9, sourceHistory: nil).withItems([a, b])
        XCTAssertEqual(legacy.sourceHistory?.revision, 2)
        XCTAssertEqual(legacy.sourceHistory?.coverage, "retained_at_upgrade")
        let session = AgentSession().withItems([a, b])
        let rows = try XCTUnwrap(session.transcript).turns.flatMap(\.allActivities).map { $0.toItem() }
        let history = try XCTUnwrap(session.sourceHistory)
        XCTAssertEqual(try Set(history.materialize(through: history.revision).keys), Set(rows.map(\.id)))
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        let next = restored.withItems(rows)
        XCTAssertEqual(next.sourceHistory?.revision, 2)
    }

    func testLegacyDuplicateRepairKeepsFeedAndRestoredRowsAligned() async throws {
        let service = AgentSessionDataService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceModel(name: "legacy repair", repoPaths: ["/tmp/repo"], customStoragePath: dir)
        let a = AgentChatItem.assistant("one", sequenceIndex: 0)
        var b = a
        b.text = "two"
        b.sequenceIndex = 1
        let session = AgentSession(serializationVersion: 9, items: [AgentChatItemPersist(from: a), AgentChatItemPersist(from: b)], sourceHistory: nil)
        let url = try await service.saveAgentSession(session, for: workspace)
        let loaded = try await service.loadAgentSession(from: url)
        let history = try XCTUnwrap(loaded.sourceHistory)
        let sourceIDs = try Set(history.materialize(through: history.revision).keys)
        let rowIDs = try Set(XCTUnwrap(loaded.transcript).turns.flatMap(\.allActivities).map(\.id))
        XCTAssertEqual(sourceIDs, rowIDs)
        XCTAssertEqual(loaded.withItems(loaded.items.map { $0.toItem() }).sourceHistory?.revision, history.revision)
    }

    func testSessionPersistenceRetainsLongerHistoryAndLegacyCoverage() async throws {
        let service = AgentSessionDataService()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceModel(name: "source feed", repoPaths: ["/tmp/repo"], customStoragePath: dir)
        let user = AgentChatItem.user("one", sequenceIndex: 0)
        var session = AgentSession(name: "chat").withItems([user])
        let stale = session
        let url = try await service.saveAgentSession(session, for: workspace)
        session = session.withItems([user, .assistant("later", sequenceIndex: 1)])
        _ = try await service.saveAgentSession(session, for: workspace)
        _ = try await service.saveAgentSession(stale, for: workspace)
        let loaded = try await service.loadAgentSession(from: url)
        XCTAssertEqual(loaded.sourceHistory?.revision, 2)
        XCTAssertEqual(loaded.sourceHistory?.feedID, session.sourceHistory?.feedID)
        var legacy = AgentSession(serializationVersion: 9, items: [AgentChatItemPersist(from: user)])
        legacy.sourceHistory = nil
        let legacyURL = try await service.saveAgentSession(legacy, for: workspace)
        let migrated = try await service.loadAgentSession(from: legacyURL)
        XCTAssertEqual(migrated.sourceHistory?.coverage, "retained_at_upgrade")
        XCTAssertEqual(migrated.sourceHistory?.revision, 1)
    }
}
