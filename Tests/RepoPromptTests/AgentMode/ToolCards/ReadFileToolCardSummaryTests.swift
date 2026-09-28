@testable import RepoPromptApp
import XCTest

final class ReadFileToolCardSummaryTests: XCTestCase {
    func testWindowedReadSummaryUsesExactRanges() throws {
        let summary = try XCTUnwrap(AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: "read_file",
            statusWord: "completed",
            rawObject: [
                "display_path": "Sources/File.swift",
                "first_line": 12,
                "last_line": 101,
                "total_lines": 300,
                "line_ranges": [
                    ["start": 12, "end": 40],
                    ["start": 88, "end": 101]
                ]
            ],
            argsObject: ["path": "Sources/File.swift"]
        ))

        XCTAssertEqual(summary.subtitle, "File.swift • Lines 12-40, 88-101 of 300")
    }
}
