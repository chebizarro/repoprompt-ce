import MCP
@testable import RepoPromptApp
import XCTest

final class ToolResultDTOsContentJudgmentsTests: XCTestCase {
    func testNilMetadataKeepsExistingWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let search = ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: []
        )
        XCTAssertEqual(
            try String(decoding: encoder.encode(search), as: UTF8.self),
            #"{"content_match_groups":[],"content_matches":0,"limit_hit":false,"path_match_lines":[],"path_matches":0,"per_file_counts":[],"total_files":0,"total_matches":0}"#
        )

        let read = ToolResultDTOs.ReadFileReply(content: "hello", totalLines: 1, firstLine: 1, lastLine: 1)
        XCTAssertEqual(
            try String(decoding: encoder.encode(read), as: UTF8.self),
            #"{"content":"hello","first_line":1,"last_line":1,"total_lines":1}"#
        )
    }

    func testSemanticMetadataRoundTripsAndWindowedRangePassesFormatterValidation() throws {
        let search = ToolResultDTOs.SearchResultDTO(
            totalMatches: 2,
            totalFiles: 1,
            contentMatches: 2,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            semanticRerank: .init(
                applied: true,
                reason: nil,
                presence: 0.9,
                jevInputTokens: 12,
                judgedMatchCount: 2,
                reorderedMatchCount: 1,
                prioritizedChars: 20,
                policyVersion: "jev-1.13.0-rpce-content-file-search-v1"
            )
        )
        let read = ToolResultDTOs.ReadFileReply(
            content: "alpha\n… [lines 2–8 omitted] …\nomega",
            totalLines: 9,
            firstLine: 1,
            lastLine: 9,
            lineRanges: [.init(start: 1, end: 1), .init(start: 9, end: 9)],
            relevantTo: "entry points",
            semanticFilter: .init(
                applied: true,
                reason: nil,
                jevInputTokens: 18,
                windowsConsidered: 2,
                windowsKept: 2,
                policyVersion: "jev-1.13.0-rpce-content-read-file-v1"
            )
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ToolResultDTOs.SearchResultDTO.self, from: encoder.encode(search)), search)
        XCTAssertEqual(try decoder.decode(ToolResultDTOs.ReadFileReply.self, from: encoder.encode(read)), read)

        let formatted = try ToolOutputFormatter.formatReadFile(args: ["path": .string("sample.txt")], value: Value(read))
        XCTAssertTrue(formatted.contains { content in
            guard case let .text(text, _, _) = content else { return false }
            return text.contains("## File Read ✅") && text.contains("… [lines 2–8 omitted] …")
        })
    }
}
