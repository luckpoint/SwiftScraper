import Foundation
import XCTest
@testable import SwiftScraperCore

final class URLFileResolverTests: XCTestCase {
    func testResolveURLFileSkipsBlankLinesCommentsAndDuplicates() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let content = """
        # comment
        https://example.com/one

        https://example.com/two
        https://example.com/one
        """

        try content.write(to: tempURL, atomically: true, encoding: .utf8)

        let resolved = try URLFileResolver.resolve(from: tempURL)

        XCTAssertEqual(
            resolved,
            ResolvedURLFile(
                fileURL: tempURL,
                pageURLs: [
                    URL(string: "https://example.com/one")!,
                    URL(string: "https://example.com/two")!,
                ]
            )
        )
    }

    func testResolveURLFileFailsForInvalidLine() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try """
        https://example.com/one
        not-a-url
        """.write(to: tempURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try URLFileResolver.resolve(from: tempURL)) { error in
            guard case .urlFileFailed(let message) = error as? ScraperError else {
                return XCTFail("urlFileFailed expected")
            }

            XCTAssertTrue(message.contains("2 行目が URL として不正です"))
        }
    }
}
