import XCTest
@testable import SwiftScraperCore

final class MarkdownHTMLConverterTests: XCTestCase {
    func testConvertHeadingProducesH1Tag() {
        let result = MarkdownHTMLConverter.convert(markdown: "# Hello")

        XCTAssertTrue(result.contains("<h1>Hello</h1>"))
    }

    func testConvertProducesFullHTMLDocument() {
        let result = MarkdownHTMLConverter.convert(markdown: "Hello")

        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        XCTAssertTrue(result.contains("<html>"))
        XCTAssertTrue(result.contains("<head>"))
        XCTAssertTrue(result.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(result.contains("<body>"))
        XCTAssertTrue(result.contains("</html>"))
    }

    func testConvertIncludesCSSStyles() {
        let result = MarkdownHTMLConverter.convert(markdown: "Hello")

        XCTAssertTrue(result.contains("<style>"))
        XCTAssertTrue(result.contains("font-family"))
        XCTAssertTrue(result.contains("max-width: 800px"))
    }

    func testConvertCodeBlockProducesPreTag() {
        let markdown = """
        ```
        let x = 1
        ```
        """
        let result = MarkdownHTMLConverter.convert(markdown: markdown)

        XCTAssertTrue(result.contains("<pre><code>"))
    }

    func testConvertEmptyInputProducesValidDocument() {
        let result = MarkdownHTMLConverter.convert(markdown: "")

        XCTAssertTrue(result.contains("<!DOCTYPE html>"))
        XCTAssertTrue(result.contains("<body>"))
        XCTAssertTrue(result.contains("</body>"))
    }

    func testConvertLinkProducesAnchorTag() {
        let result = MarkdownHTMLConverter.convert(markdown: "[Example](https://example.com)")

        XCTAssertTrue(result.contains("<a href=\"https://example.com\">Example</a>"))
    }
}
