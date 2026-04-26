import AppKit
import Foundation
import XCTest
@testable import SwiftScraperCore

@MainActor
final class WebScraperIntegrationTests: XCTestCase {
    func testRunWaitsForDynamicDOMBeforeExtractingOuterHTML() async throws {
        prepareApplicationIfNeeded()

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>Dynamic Fixture</title>
          </head>
          <body>
            <main id="app">
              <div id="state">initial</div>
            </main>
            <script>
              setTimeout(() => {
                const app = document.getElementById('app');
                const ready = document.createElement('div');
                ready.id = 'ready';
                ready.textContent = 'phase-1';
                app.appendChild(ready);
              }, 60);

              setTimeout(() => {
                document.getElementById('state').textContent = 'phase-2';
                document.getElementById('ready').textContent = 'final-ready';
              }, 120);
            </script>
          </body>
        </html>
        """

        let fileURL = try makeHTMLFixture(html)
        let scraper = WebScraper(
            configuration: makeConfiguration(
                url: fileURL,
                wait: WaitConfiguration(
                    fixedDelay: 0,
                    selectorConditions: ["#ready"],
                    textConditions: [],
                    pollInterval: 0.05,
                    domStableDelay: 0.15,
                    autoScrollEnabled: false
                ),
                timeouts: Timeouts(load: 5, render: 2, javaScript: 1),
                extraction: .outerHTML
            ),
            logger: StderrLogger(verbose: false)
        )

        let output = try await scraper.run()

        XCTAssertTrue(output.contains("<title>Dynamic Fixture</title>"))
        XCTAssertTrue(output.contains("id=\"state\">phase-2<"))
        XCTAssertTrue(output.contains("id=\"ready\">final-ready<"))
        XCTAssertFalse(output.contains("<script"))
        try await allowWebKitToSettle()
    }

    func testRunContentOnlyExtractionRemovesChrome() async throws {
        prepareApplicationIfNeeded()

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>Article Fixture</title>
          </head>
          <body>
            <header>Site Header</header>
            <nav>Global Navigation</nav>
            <main id="content">
              <article>
                <h1>Important Article</h1>
                <p>Main body paragraph.</p>
              </article>
              <aside>Related Links</aside>
            </main>
            <footer>Site Footer</footer>
          </body>
        </html>
        """

        let fileURL = try makeHTMLFixture(html)
        let scraper = WebScraper(
            configuration: makeConfiguration(
                url: fileURL,
                wait: WaitConfiguration(
                    fixedDelay: 0,
                    selectorConditions: [],
                    textConditions: [],
                    pollInterval: 0.05,
                    domStableDelay: 0,
                    autoScrollEnabled: false
                ),
                timeouts: Timeouts(load: 5, render: 1, javaScript: 1),
                extraction: .contentOnly
            ),
            logger: StderrLogger(verbose: false)
        )

        let output = try await scraper.run()

        XCTAssertTrue(output.contains("Important Article"))
        XCTAssertTrue(output.contains("Main body paragraph."))
        XCTAssertFalse(output.contains("Site Header"))
        XCTAssertFalse(output.contains("Global Navigation"))
        XCTAssertFalse(output.contains("Related Links"))
        XCTAssertFalse(output.contains("Site Footer"))
        try await allowWebKitToSettle()
    }

    func testRunTimesOutWhenWaitSelectorNeverAppears() async throws {
        prepareApplicationIfNeeded()

        let html = """
        <!doctype html>
        <html>
          <body>
            <main>
              <p>Static page</p>
            </main>
          </body>
        </html>
        """

        let fileURL = try makeHTMLFixture(html)
        let scraper = WebScraper(
            configuration: makeConfiguration(
                url: fileURL,
                wait: WaitConfiguration(
                    fixedDelay: 0,
                    selectorConditions: ["#missing"],
                    textConditions: [],
                    pollInterval: 0.05,
                    domStableDelay: 0,
                    autoScrollEnabled: false
                ),
                timeouts: Timeouts(load: 5, render: 0.3, javaScript: 1),
                extraction: .outerHTML
            ),
            logger: StderrLogger(verbose: false)
        )

        do {
            _ = try await scraper.run()
            XCTFail("timedOut expected")
        } catch let error as ScraperError {
            XCTAssertEqual(error, .timedOut(phase: "描画待機", timeout: 0.3))
        }

        try await allowWebKitToSettle()
    }

    private func makeConfiguration(
        url: URL,
        wait: WaitConfiguration,
        timeouts: Timeouts,
        extraction: ExtractionMode,
        visibility: VisibilityMode = .windowless
    ) -> ScraperConfiguration {
        ScraperConfiguration(
            url: url,
            cookies: [],
            dataStoreMode: .ephemeral,
            visibility: visibility,
            viewport: .default,
            wait: wait,
            timeouts: timeouts,
            output: .stdout,
            outputFormat: .plain,
            extraction: extraction,
            prettyPrint: false,
            verbose: false
        )
    }

    private func makeHTMLFixture(_ html: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftScraperTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("fixture.html")
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func prepareApplicationIfNeeded() {
        TestApplicationBootstrap.prepare()
    }

    private func allowWebKitToSettle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

@MainActor
private enum TestApplicationBootstrap {
    private static var isPrepared = false

    static func prepare() {
        guard !isPrepared else {
            return
        }

        let application = NSApplication.shared
        _ = application.setActivationPolicy(.accessory)
        application.finishLaunching()
        isPrepared = true
    }
}
