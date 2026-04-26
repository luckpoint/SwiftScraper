import XCTest
@testable import SwiftScraperCore

final class SitemapResolverTests: XCTestCase {
    func testResolveSitemapURLUsesExplicitXMLPath() {
        let input = URL(string: "https://example.com/sitemap-index.xml")!

        let resolved = SitemapResolver.resolveSitemapURL(from: input)

        XCTAssertEqual(resolved.absoluteString, "https://example.com/sitemap-index.xml")
    }

    func testResolveSitemapURLFallsBackToSiteRoot() {
        let input = URL(string: "https://example.com/docs/article?id=1")!

        let resolved = SitemapResolver.resolveSitemapURL(from: input)

        XCTAssertEqual(resolved.absoluteString, "https://example.com/sitemap.xml")
    }

    func testParseURLSetDocument() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/one</loc></url>
          <url><loc>/two</loc></url>
        </urlset>
        """

        let document = try SitemapDocumentParser.parse(
            data: Data(xml.utf8),
            baseURL: URL(string: "https://example.com/sitemap.xml")!
        )

        XCTAssertEqual(
            document,
            .urlset([
                URL(string: "https://example.com/one")!,
                URL(string: "https://example.com/two")!,
            ])
        )
    }

    func testParseSitemapIndexDocument() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns:sm="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sm:sitemap><sm:loc>https://example.com/sitemap-1.xml</sm:loc></sm:sitemap>
          <sm:sitemap><sm:loc>https://example.com/sitemap-2.xml</sm:loc></sm:sitemap>
        </sitemapindex>
        """

        let document = try SitemapDocumentParser.parse(
            data: Data(xml.utf8),
            baseURL: URL(string: "https://example.com/sitemap.xml")!
        )

        XCTAssertEqual(
            document,
            .sitemapIndex([
                URL(string: "https://example.com/sitemap-1.xml")!,
                URL(string: "https://example.com/sitemap-2.xml")!,
            ])
        )
    }

    func testParseInvalidLocationFails() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset>
          <url><loc>https://example.com/ok</loc></url>
          <url><loc>http://[</loc></url>
        </urlset>
        """

        XCTAssertThrowsError(
            try SitemapDocumentParser.parse(
                data: Data(xml.utf8),
                baseURL: URL(string: "https://example.com/sitemap.xml")!
            )
        ) { error in
            guard case .sitemapParseFailed(let message) = error as? ScraperError else {
                return XCTFail("sitemapParseFailed expected")
            }

            XCTAssertTrue(message.contains("URL として解釈できない loc"))
        }
    }
}
