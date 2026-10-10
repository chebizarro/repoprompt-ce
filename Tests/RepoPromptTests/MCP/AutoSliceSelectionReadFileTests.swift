@testable import RepoPromptApp
import XCTest

final class AutoSliceSelectionReadFileTests: XCTestCase {
    func testWindowedReplyKeepsEveryRangeEvenWhenOverallSpanCoversWholeFile() {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "first\n… omitted …\nlast",
            totalLines: 100,
            firstLine: 1,
            lastLine: 100,
            displayPath: "Sources/File.swift",
            lineRanges: [.init(start: 1, end: 12), .init(start: 88, end: 100)]
        )

        XCTAssertEqual(
            AutoSliceSelection.readFileSelection(from: reply),
            .slice(.init(
                path: "Sources/File.swift",
                ranges: [LineRange(start: 1, end: 12), LineRange(start: 88, end: 100)]
            ))
        )
    }

    func testWindowedReplyUsesFallbackPathAndDoesNotSpanElidedLines() {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "selected",
            totalLines: 300,
            firstLine: 12,
            lastLine: 101,
            lineRanges: [.init(start: 12, end: 40), .init(start: 88, end: 101)]
        )

        XCTAssertEqual(
            AutoSliceSelection.readFileSelection(from: reply, fallbackPath: "fallback.swift"),
            .slice(.init(
                path: "fallback.swift",
                ranges: [LineRange(start: 12, end: 40), LineRange(start: 88, end: 101)]
            ))
        )
    }

    func testLegacyWholeReadStillSelectsFullFile() {
        let reply = ToolResultDTOs.ReadFileReply(
            content: "all",
            totalLines: 10,
            firstLine: 1,
            lastLine: 10,
            displayPath: "file.swift"
        )
        XCTAssertEqual(AutoSliceSelection.readFileSelection(from: reply), .full(path: "file.swift"))
    }
}
