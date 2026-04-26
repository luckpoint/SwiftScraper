import Foundation
import XCTest
@testable import SwiftScraperCore

final class BatchRunFormatterTests: XCTestCase {
    func testFormatEncodesBatchResultAsJSON() throws {
        let result = BatchRunResult(
            sourceKind: "url-file",
            sourceLocation: "/tmp/urls.txt",
            pages: [
                .succeeded(url: URL(string: "https://example.com/one")!, output: "<html>one</html>"),
                .failed(url: URL(string: "https://example.com/two")!, error: "ページロードに失敗しました"),
            ]
        )

        let json = try BatchRunFormatter.format(result)
        let decoded = try JSONDecoder().decode(BatchRunResult.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.source.kind, "url-file")
        XCTAssertEqual(decoded.source.location, "/tmp/urls.txt")
        XCTAssertEqual(decoded.pageCount, 2)
        XCTAssertEqual(decoded.successCount, 1)
        XCTAssertEqual(decoded.failureCount, 1)
        XCTAssertEqual(decoded.pages.count, 2)
        XCTAssertEqual(decoded.pages[0].url, "https://example.com/one")
        XCTAssertEqual(decoded.pages[0].output, "<html>one</html>")
        XCTAssertNil(decoded.pages[0].error)
        XCTAssertEqual(decoded.pages[1].url, "https://example.com/two")
        XCTAssertNil(decoded.pages[1].output)
        XCTAssertEqual(decoded.pages[1].error, "ページロードに失敗しました")
    }
}
