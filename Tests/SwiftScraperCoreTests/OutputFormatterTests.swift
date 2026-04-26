import XCTest
@testable import SwiftScraperCore

final class OutputFormatterTests: XCTestCase {
    func testPrettyPrintDisabledReturnsOriginalHTML() throws {
        let html = "<html><body><div><p>Hello</p></div></body></html>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .outerHTML,
            outputFormat: .plain,
            prettyPrint: false
        )

        XCTAssertEqual(formatted, html)
    }

    func testPrettyPrintFormatsDocumentHTML() throws {
        let html = "<html><head><meta charset=\"utf-8\"><meta name=\"x\" content=\"y\"></head><body><span>One</span><span>Two</span></body></html>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .outerHTML,
            outputFormat: .plain,
            prettyPrint: true
        )

        XCTAssertNotEqual(formatted, html)
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("\n  <head>"))
        XCTAssertTrue(formatted.contains("\n    <meta"))
        XCTAssertTrue(formatted.contains("\n    <span>"))
    }

    func testPrettyPrintFormatsHTMLFragment() throws {
        let html = "<span>One</span><span>Two</span>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .selectorInnerHTML("#app"),
            outputFormat: .plain,
            prettyPrint: true
        )

        XCTAssertNotEqual(formatted, html)
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("<span>One</span>"))
        XCTAssertTrue(formatted.contains("<span>Two</span>"))
    }

    func testPrettyPrintFormatsContentOnlyFragment() throws {
        let html = "<main><article><p>Hello</p><p>World</p></article></main>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .contentOnly,
            outputFormat: .plain,
            prettyPrint: true
        )

        XCTAssertNotEqual(formatted, html)
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("<main>"))
        XCTAssertTrue(formatted.contains("<article>"))
    }

    func testPrettyPrintDoesNotTouchBodyText() throws {
        let text = "Hello\nWorld"

        let formatted = try OutputFormatter.format(
            text,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .bodyText,
            outputFormat: .plain,
            prettyPrint: true
        )

        XCTAssertEqual(formatted, text)
    }

    func testPrettyPrintDoesNotTouchStructureInspection() throws {
        let report = """
        title: Example
        url: https://example.com/article
        landmarks: header=1 footer=1 nav=2 aside=1 main=1 article=1
        """

        let formatted = try OutputFormatter.format(
            report,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .structureInspection,
            outputFormat: .plain,
            prettyPrint: true
        )

        XCTAssertEqual(formatted, report)
    }

    func testMarkdownConvertsRelativeLinksToAbsoluteURLs() throws {
        let html = "<article><p><a href=\"/about\">About</a></p></article>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/docs/article")!,
            extraction: .contentOnly,
            outputFormat: .markdown,
            prettyPrint: false
        )

        XCTAssertTrue(formatted.contains("[About](https://example.com/about)"))
    }

    func testMarkdownUsesGFMPluginForStrikethrough() throws {
        let html = "<p><del>Deleted</del></p>"

        let formatted = try OutputFormatter.format(
            html,
            sourceURL: URL(string: "https://example.com/article")!,
            extraction: .contentOnly,
            outputFormat: .markdown,
            prettyPrint: false
        )

        XCTAssertTrue(formatted.contains("~~Deleted~~"))
    }
}
