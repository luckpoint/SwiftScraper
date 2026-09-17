import XCTest
@testable import SwiftScraperCore

final class StructureInspectionFormatterTests: XCTestCase {
    func testRenderFormatsInspectionReport() throws {
        let json = """
        {
          "title": "Example Article",
          "url": "https://example.com/article",
          "landmarks": {
            "header": 1,
            "footer": 1,
            "nav": 2,
            "aside": 1,
            "main": 1,
            "article": 1
          },
          "candidate": "main#content.article-body",
          "candidateTextLength": 4200,
          "testedCandidates": 6,
          "fallbackToBody": false,
          "contentOnlyRemoval": {
            "header": 1,
            "footer": 1,
            "nav": 2,
            "aside": 1,
            "sidebarLike": 3,
            "hidden": 4,
            "scriptLike": 2
          }
        }
        """

        let rendered = try StructureInspectionFormatter.render(json: json)

        XCTAssertEqual(
            rendered,
            """
            title: Example Article
            url: https://example.com/article
            landmarks: header=1 footer=1 nav=2 aside=1 main=1 article=1
            contentCandidate: main#content.article-body
            candidateTextLength: 4200
            testedCandidates: 6
            fallbackToBody: false
            contentOnlyRemoval: header=1 footer=1 nav=2 aside=1 sidebarLike=3 hidden=4 scriptLike=2
            """
        )
    }

    func testRenderFailsForInvalidJSON() {
        XCTAssertThrowsError(try StructureInspectionFormatter.render(json: "{")) { error in
            guard case .extractionFailed(let message) = error as? ScraperError else {
                return XCTFail("extractionFailed expected")
            }

            XCTAssertTrue(message.contains("Unable to parse the structure report JSON"))
        }
    }
}
