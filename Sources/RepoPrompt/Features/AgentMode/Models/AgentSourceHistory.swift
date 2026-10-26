import Foundation

/// Independent of display retention: removal/regrouping never deletes captured chat.
struct AgentSourceHistory: Codable, Equatable {
    struct Change: Codable, Equatable {
        let occurrenceID: UUID
        let ordinal: Int
        let kind: String
        let text: String
        let append: Bool
        let isStreaming: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.occurrenceID == rhs.occurrenceID && lhs.ordinal == rhs.ordinal && lhs.kind == rhs.kind
                && lhs.append == rhs.append && lhs.isStreaming == rhs.isStreaming
                && Array(lhs.text.utf8) == Array(rhs.text.utf8)
        }
    }

    struct Record: Codable, Equatable {
        let occurrenceID: UUID
        let ordinal: Int
        let kind: String
        var text: String
        var revision: Int
        var isStreaming: Bool
    }

    var version = 1
    var feedID = UUID()
    var coverage = "complete_since_creation"
    private(set) var changes: [Change] = []
    private(set) var failure: String?
    private var current: [UUID: Record] = [:]
    var revision: Int {
        changes.count
    }

    enum CodingKeys: String, CodingKey { case version, feedID, coverage, changes, failure }

    init(coverage: String = "complete_since_creation") {
        self.coverage = coverage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        feedID = try values.decode(UUID.self, forKey: .feedID)
        coverage = try values.decode(String.self, forKey: .coverage)
        changes = try values.decode([Change].self, forKey: .changes)
        failure = try values.decodeIfPresent(String.self, forKey: .failure)
        current = try materialize(through: revision)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.feedID == rhs.feedID && lhs.coverage == rhs.coverage
            && lhs.changes == rhs.changes && lhs.failure == rhs.failure
    }

    /// Called synchronously at source mutations, before retention or derived projections.
    mutating func capture(_ items: [AgentChatItem]) {
        guard failure == nil else { return }
        var seen = Set<UUID>()
        for item in items {
            let kind: String
            switch item.kind {
            case .user: kind = "user"
            case .assistant, .assistantInline: kind = "assistant"
            default: continue
            }
            guard seen.insert(item.id).inserted else { failure = "duplicate source occurrence ID"
                return
            }
            let previous = current[item.id]
            guard previous == nil || previous?.kind == kind else { failure = "source occurrence changed role"
                return
            }
            let bytes = Array(item.text.utf8)
            let old = Array((previous?.text ?? "").utf8)
            if previous != nil && old == bytes && previous?.isStreaming == item.isStreaming { continue }
            let append = previous != nil && bytes.starts(with: old)
            let text = append ? String(decoding: bytes.dropFirst(old.count), as: UTF8.self) : item.text
            let ordinal = previous?.ordinal ?? (current.count + 1)
            changes.append(Change(
                occurrenceID: item.id,
                ordinal: ordinal,
                kind: kind,
                text: text,
                append: append,
                isStreaming: item.isStreaming
            ))
            current[item.id] = Record(
                occurrenceID: item.id,
                ordinal: ordinal,
                kind: kind,
                text: item.text,
                revision: revision,
                isStreaming: item.isStreaming
            )
        }
    }

    func materialize(through head: Int) throws -> [UUID: Record] {
        guard version == 1, ["complete_since_creation", "retained_at_upgrade"].contains(coverage),
              failure == nil, head >= 0, head <= revision
        else { throw SourceHistoryError.invalidHistory }
        var records: [UUID: Record] = [:]
        for (index, change) in changes.prefix(head).enumerated() {
            let previous = records[change.occurrenceID]
            guard ["user", "assistant"].contains(change.kind),
                  change.ordinal == (previous?.ordinal ?? (records.count + 1)),
                  previous == nil ? !change.append : previous?.kind == change.kind
            else { throw SourceHistoryError.invalidHistory }
            records[change.occurrenceID] = Record(
                occurrenceID: change.occurrenceID, ordinal: change.ordinal, kind: change.kind,
                text: change.append ? (previous?.text ?? "") + change.text : change.text,
                revision: index + 1, isStreaming: change.isStreaming
            )
        }
        return records
    }

    /// Stale compatible saves retain the longer lineage; divergence is never overwritten.
    static func merged(_ incoming: Self?, with stored: Self?) throws -> Self? {
        guard let stored else { return incoming }
        guard let incoming else { return stored }
        guard incoming.feedID == stored.feedID, incoming.coverage == stored.coverage,
              incoming.version == stored.version, incoming.failure == stored.failure,
              incoming.changes.prefix(min(incoming.revision, stored.revision))
              == stored.changes.prefix(min(incoming.revision, stored.revision))
        else { throw SourceHistoryError.divergentHistory }
        return incoming.revision >= stored.revision ? incoming : stored
    }
}

enum SourceHistoryError: Error, LocalizedError {
    case invalidHistory, divergentHistory, invalidCursor, oversizedRecord
    var errorDescription: String? {
        switch self {
        case .invalidHistory: "Source chat history is invalid; continuity was not reset."
        case .divergentHistory: "Source chat history diverged; refusing to overwrite its lineage."
        case .invalidCursor: "Invalid source chat cursor or lineage; continuity was not reset."
        case .oversizedRecord: "A complete source chat record does not fit max_bytes; increase the page budget."
        }
    }
}

struct AgentSourceHistoryPage: Codable {
    let version = 1
    let sessionID: UUID
    let feedID: UUID
    let coverage: String
    let view: String
    let headRevision: Int
    let afterRevision: Int?
    var records: [AgentSourceHistory.Record]
    var nextCursor: String?
    var complete: Bool

    struct Cursor: Codable {
        let version: Int
        let sessionID: UUID
        let feedID: UUID
        let head: Int
        let after: Int?
        let position: Int
    }

    static func make(history: AgentSourceHistory, sessionID: UUID, cursor: String?, after: Int?, limit: Int, maxBytes: Int) throws -> Self {
        guard (1 ... 256).contains(limit), (1024 ... 8_388_608).contains(maxBytes), after == nil || after! >= 0,
              cursor == nil || after == nil
        else { throw SourceHistoryError.invalidCursor }
        var head = history.revision
        var start = 0
        var lower = after
        if let cursor {
            guard cursor.utf8.count <= 2048, let data = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode(Cursor.self, from: data), decoded.version == 1,
                  decoded.sessionID == sessionID, decoded.feedID == history.feedID,
                  decoded.head >= 0, decoded.head <= history.revision, decoded.position >= 0,
                  decoded.after == nil || (decoded.after! >= 0 && decoded.after! <= decoded.head)
            else { throw SourceHistoryError.invalidCursor }
            head = decoded.head
            start = decoded.position
            lower = decoded.after
        }
        guard lower == nil || lower! <= head else { throw SourceHistoryError.invalidCursor }
        let snapshot = try history.materialize(through: head)
        let all = snapshot.values.filter { lower == nil || $0.revision > lower! }.sorted {
            lower == nil ? $0.ordinal < $1.ordinal : $0.revision < $1.revision
        }
        guard start <= all.count else { throw SourceHistoryError.invalidCursor }
        var page = Self(
            sessionID: sessionID,
            feedID: history.feedID,
            coverage: history.coverage,
            view: lower == nil ? "snapshot" : "changes",
            headRevision: head,
            afterRevision: lower,
            records: [],
            nextCursor: nil,
            complete: false
        )
        func finish(_ candidate: inout Self, count: Int) throws {
            candidate.complete = start + count == all.count
            candidate.nextCursor = candidate.complete ? nil : try JSONEncoder().encode(Cursor(
                version: 1, sessionID: sessionID, feedID: history.feedID, head: head, after: lower, position: start + count
            )).base64EncodedString()
        }
        for record in all.dropFirst(start).prefix(limit) {
            var next = page
            next.records.append(record)
            try finish(&next, count: next.records.count)
            if try wireEncoder().encode(next).count > maxBytes {
                if page.records.isEmpty { throw SourceHistoryError.oversizedRecord }
                break
            }
            page = next
        }
        try finish(&page, count: page.records.count)
        guard try wireEncoder().encode(page).count <= maxBytes else { throw SourceHistoryError.oversizedRecord }
        return page
    }

    static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
