import Foundation
import XCTest
@testable import SwiftScraperCore

final class CLIParserTests: XCTestCase {
    func testMinimalInvocationParsesDefaults() throws {
        let command = try CLIParser.parse(arguments: ["https://example.com"])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.url.absoluteString, "https://example.com")
        XCTAssertEqual(configuration.visibility, .windowless)
        XCTAssertEqual(configuration.dataStoreMode, .ephemeral)
        XCTAssertEqual(configuration.viewport, .default)
        XCTAssertEqual(configuration.wait, .default)
        XCTAssertEqual(configuration.timeouts, .default)
        XCTAssertEqual(configuration.output, .stdout)
        XCTAssertEqual(configuration.outputFormat, .plain)
        XCTAssertEqual(configuration.extraction, .outerHTML)
        XCTAssertEqual(configuration.imageExtraction, .disabled)
        XCTAssertNil(configuration.cookieJar)
        XCTAssertNil(configuration.batch)
        XCTAssertFalse(configuration.prettyPrint)
        XCTAssertFalse(configuration.verbose)
        XCTAssertEqual(configuration.wait.domStableDelay, 0.5)
    }

    func testLeadingSwiftRunSeparatorIsIgnored() throws {
        let command = try CLIParser.parse(arguments: [
            "--",
            "https://example.com",
            "--output", "out/output.html",
            "--pretty-print",
            "--verbose",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.url.absoluteString, "https://example.com")
        XCTAssertTrue(configuration.prettyPrint)
        XCTAssertTrue(configuration.verbose)

        guard case .file(let outputURL) = configuration.output else {
            return XCTFail("file output expected")
        }

        XCTAssertTrue(outputURL.path.hasSuffix("/out/output.html"))
    }

    func testBiDiServerParsesDefaults() throws {
        let command = try CLIParser.parse(arguments: ["--bidi-server"])

        guard case .bidiServer(let configuration) = command else {
            return XCTFail("bidi server configuration expected")
        }

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 9222)
        XCTAssertNil(configuration.initialURL)
        XCTAssertEqual(configuration.visibility, .windowless)
        XCTAssertEqual(configuration.dataStoreMode, .ephemeral)
        XCTAssertEqual(configuration.viewport, .default)
        XCTAssertEqual(configuration.timeouts, .default)
        XCTAssertTrue(configuration.cookies.isEmpty)
        XCTAssertTrue(configuration.customHeaders.isEmpty)
        XCTAssertFalse(configuration.verbose)
    }

    func testBiDiServerParsesInitialURLAndOptions() throws {
        let command = try CLIParser.parse(arguments: [
            "--bidi-server",
            "--bidi-host", "0.0.0.0",
            "--bidi-port", "9333",
            "--url", "https://example.com/app",
            "--visibility", "hidden-window",
            "--viewport", "1024x768",
            "--load-timeout", "20",
            "--js-timeout", "12",
            "--header", "User-Agent: SwiftScraper",
            "--cookie", "name=session;value=abc;domain=example.com",
            "--persistent-store",
            "--verbose",
        ])

        guard case .bidiServer(let configuration) = command else {
            return XCTFail("bidi server configuration expected")
        }

        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.port, 9333)
        XCTAssertEqual(configuration.initialURL?.absoluteString, "https://example.com/app")
        XCTAssertEqual(configuration.visibility, .hiddenWindow)
        XCTAssertEqual(configuration.viewport, Viewport(width: 1024, height: 768))
        XCTAssertEqual(configuration.timeouts.load, 20)
        XCTAssertEqual(configuration.timeouts.javaScript, 12)
        XCTAssertEqual(configuration.customHeaders["User-Agent"], "SwiftScraper")
        XCTAssertEqual(configuration.cookies.count, 1)
        XCTAssertEqual(configuration.dataStoreMode, .persistent)
        XCTAssertTrue(configuration.verbose)
    }

    func testBiDiHostPortRequireBiDiServer() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--bidi-port", "9333",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--bidi-host` / `--bidi-port` は `--bidi-server` と一緒に指定してください")
            )
        }
    }

    func testBiDiServerRejectsOutputOptions() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "--bidi-server",
                "--output", "out/page.html",
            ])
        ) { error in
            XCTAssertEqual(error as? ScraperError, .invalidArgument("`--output` は `--bidi-server` では使用できません"))
        }
    }

    func testCookieAndWaitOptionsParse() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/app",
            "--cookie", "name=session;value=abc;domain=example.com;path=/app;secure=true;httpOnly=true",
            "--wait-delay", "1.5",
            "--wait-selector", "#ready",
            "--wait-text", "Complete",
            "--poll-interval", "0.25",
            "--dom-stable-delay", "1.25",
            "--load-timeout", "12",
            "--wait-timeout", "33",
            "--js-timeout", "8",
            "--visibility", "hidden-window",
            "--viewport", "1280x720",
            "--output", "tmp/result.html",
            "--selector-inner-html", "#app",
            "--pretty-print",
            "--persistent-store",
            "--verbose",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.visibility, .hiddenWindow)
        XCTAssertEqual(configuration.viewport, Viewport(width: 1280, height: 720))
        XCTAssertEqual(configuration.wait.fixedDelay, 1.5)
        XCTAssertEqual(configuration.wait.selectorConditions, ["#ready"])
        XCTAssertEqual(configuration.wait.textConditions, ["Complete"])
        XCTAssertEqual(configuration.wait.pollInterval, 0.25)
        XCTAssertEqual(configuration.wait.domStableDelay, 1.25)
        XCTAssertEqual(configuration.timeouts.load, 12)
        XCTAssertEqual(configuration.timeouts.render, 33)
        XCTAssertEqual(configuration.timeouts.javaScript, 8)
        XCTAssertEqual(configuration.dataStoreMode, .persistent)
        XCTAssertEqual(configuration.extraction, .selectorInnerHTML("#app"))
        XCTAssertTrue(configuration.prettyPrint)
        XCTAssertTrue(configuration.verbose)

        guard case .file(let outputURL) = configuration.output else {
            return XCTFail("file output expected")
        }

        XCTAssertTrue(outputURL.path.hasSuffix("/tmp/result.html"))

        XCTAssertEqual(configuration.cookies.count, 1)
        XCTAssertEqual(
            configuration.cookies[0],
            CookieDefinition(
                name: "session",
                value: "abc",
                domain: "example.com",
                path: "/app",
                secure: true,
                httpOnly: true
            )
        )
    }

    func testCookieFileLoadsSingleObject() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let json = """
        {
          "name": "session",
          "value": "xyz",
          "domain": "example.com",
          "path": "/",
          "secure": true,
          "httpOnly": false
        }
        """

        try json.write(to: tempURL, atomically: true, encoding: .utf8)

        let command = try CLIParser.parse(arguments: [
            "https://example.com",
            "--cookie-file", tempURL.path,
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.cookies.count, 1)
        XCTAssertEqual(configuration.cookies[0].name, "session")
        XCTAssertEqual(configuration.cookies[0].value, "xyz")
        XCTAssertEqual(configuration.cookies[0].domain, "example.com")
        XCTAssertTrue(configuration.cookies[0].secure)
    }

    func testCookieJarOptionParsesWithoutLoadingFile() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com",
            "--cookie-jar", "tmp/cookies.json",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        let expected = URL(
            fileURLWithPath: "tmp/cookies.json",
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL

        XCTAssertEqual(configuration.cookieJar, expected)
        XCTAssertTrue(configuration.cookies.isEmpty)
    }

    func testCookieJarCannotBeCombinedWithSitemapBatch() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--sitemap",
                "--cookie-jar", "cookies.json",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--cookie-jar` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            )
        }
    }

    func testCookieJarCannotBeCombinedWithURLFileBatch() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "--url-file", "urls.txt",
                "--cookie-jar", "cookies.json",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--cookie-jar` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            )
        }
    }

    func testDuplicateCookieJarOptionFails() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--cookie-jar", "cookies.json",
                "--cookie-jar", "other-cookies.json",
            ])
        ) { error in
            XCTAssertEqual(error as? ScraperError, .invalidArgument("`--cookie-jar` は 1 つだけ指定してください"))
        }
    }

    func testCookieJarStoreLoadsMissingFileAsEmpty() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        XCTAssertEqual(try CookieJarStore.loadIfPresent(from: tempURL), [])
    }

    func testCookieJarStoreSavesAndLoadsDefinitions() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let definitions = [
            CookieDefinition(
                name: "prefs",
                value: "dark",
                domain: "example.com",
                path: "/",
                secure: false,
                httpOnly: false
            ),
            CookieDefinition(
                name: "session",
                value: "abc",
                domain: "example.com",
                path: "/",
                secure: true,
                httpOnly: true,
                expires: Date(timeIntervalSince1970: 1_798_675_200)
            ),
        ]

        try CookieJarStore.save(definitions: definitions, to: tempURL)

        XCTAssertEqual(try CookieJarStore.loadIfPresent(from: tempURL), definitions)
    }

    func testCookieDefinitionCanBeCreatedFromHTTPCookie() throws {
        let expires = Date(timeIntervalSince1970: 1_798_675_200)
        let definition = CookieDefinition(
            name: "session",
            value: "abc",
            domain: "example.com",
            path: "/app",
            secure: true,
            httpOnly: true,
            expires: expires
        )

        let cookie = try definition.makeHTTPCookie()
        XCTAssertEqual(CookieDefinition(cookie: cookie), definition)
    }

    func testAutoScrollOptionParses() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--auto-scroll",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertTrue(configuration.wait.autoScrollEnabled)
    }

    func testContentOnlyOptionParses() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--content-only",
            "--pretty-print",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.extraction, .contentOnly)
        XCTAssertTrue(configuration.prettyPrint)
    }

    func testMarkdownOptionParses() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--content-only",
            "--markdown",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.extraction, .contentOnly)
        XCTAssertEqual(configuration.outputFormat, .markdown)
    }

    func testImageExtractionOptionsParse() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--content-only",
            "--extract-images",
            "--image-filter", "article-only",
            "--image-score-threshold", "0.72",
            "--image-include-maybe",
            "--image-debug",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.extraction, .contentOnly)
        XCTAssertEqual(
            configuration.imageExtraction,
            ImageExtractionConfiguration(
                enabled: true,
                filter: .articleOnly,
                scoreThreshold: 0.72,
                includeMaybe: true,
                debug: true
            )
        )
    }

    func testInspectStructureOptionParses() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--inspect-structure",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.extraction, .structureInspection)
    }

    func testSitemapOptionsParse() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/docs/article",
            "--sitemap",
            "--concurrency", "8",
            "--content-only",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.url.absoluteString, "https://example.com/docs/article")
        XCTAssertEqual(configuration.batch, BatchMode(input: .sitemap, concurrency: 8))
        XCTAssertEqual(configuration.extraction, .contentOnly)
    }

    func testURLFileOptionsParse() throws {
        let command = try CLIParser.parse(arguments: [
            "--url-file", "tmp/urls.txt",
            "--concurrency", "3",
            "--inspect-structure",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.url.path, URL(fileURLWithPath: "tmp/urls.txt", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path)
        XCTAssertEqual(
            configuration.batch,
            BatchMode(
                input: .urlFile(URL(fileURLWithPath: "tmp/urls.txt", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL),
                concurrency: 3
            )
        )
        XCTAssertEqual(configuration.extraction, .structureInspection)
    }

    func testConcurrencyWithoutBatchInputFails() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--concurrency", "4",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--concurrency` は `--sitemap` または `--url-file` と一緒に指定してください")
            )
        }
    }

    func testConcurrencyMustBePositive() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--sitemap",
                "--concurrency", "0",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("--concurrency は 1 以上で指定してください")
            )
        }
    }

    func testLegacySitemapConcurrencyAliasStillWorks() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/docs/article",
            "--sitemap",
            "--sitemap-concurrency", "2",
        ])

        guard case .run(let configuration) = command else {
            return XCTFail("run configuration expected")
        }

        XCTAssertEqual(configuration.batch, BatchMode(input: .sitemap, concurrency: 2))
    }

    func testURLFileCannotBeCombinedWithURL() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--url-file", "tmp/urls.txt",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--url-file` を使う場合は URL を同時に指定できません")
            )
        }
    }

    func testMultipleExtractionModesFail() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--body-text",
                "--content-only",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument(
                    "抽出モードは `--body-text` / `--selector-inner-html` / `--content-only` / `--inspect-structure` のうち 1 つだけ指定できます"
                )
            )
        }
    }

    func testMarkdownCannotBeCombinedWithPrettyPrint() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--markdown",
                "--pretty-print",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--markdown` と `--pretty-print` は同時に指定できません")
            )
        }
    }

    func testMarkdownRequiresHTMLExtractionMode() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--body-text",
                "--markdown",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--markdown` は HTML を返す抽出モードでだけ指定できます")
            )
        }
    }

    func testImageExtractionRequiresHTMLExtractionMode() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--body-text",
                "--extract-images",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--extract-images` は HTML を返す抽出モードでだけ指定できます")
            )
        }
    }

    func testImageScoreThresholdMustBeWithinUnitInterval() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--extract-images",
                "--image-score-threshold", "1.5",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("--image-score-threshold は 0.0 以上 1.0 以下で指定してください")
            )
        }
    }

    func testUnknownOptionFails() {
        XCTAssertThrowsError(try CLIParser.parse(arguments: ["https://example.com", "--wat"])) { error in
            XCTAssertEqual(error as? ScraperError, .unknownOption("--wat"))
        }
    }

    func testPDFBasicParsing() throws {
        let command = try CLIParser.parse(arguments: ["--pdf", "notes.md"])

        guard case .pdf(let config) = command else {
            return XCTFail("pdf command expected")
        }

        XCTAssertTrue(config.inputFile.path.hasSuffix("/notes.md"))
        XCTAssertTrue(config.outputFile.path.hasSuffix("/notes.pdf"))
        XCTAssertFalse(config.verbose)
    }

    func testPDFCustomOutputPath() throws {
        let command = try CLIParser.parse(arguments: ["--pdf", "notes.md", "--output", "out/custom.pdf"])

        guard case .pdf(let config) = command else {
            return XCTFail("pdf command expected")
        }

        XCTAssertTrue(config.inputFile.path.hasSuffix("/notes.md"))
        XCTAssertTrue(config.outputFile.path.hasSuffix("/out/custom.pdf"))
    }

    func testPDFVerboseFlagPropagated() throws {
        let command = try CLIParser.parse(arguments: ["--pdf", "notes.md", "--verbose"])

        guard case .pdf(let config) = command else {
            return XCTFail("pdf command expected")
        }

        XCTAssertTrue(config.verbose)
    }

    func testPDFMissingArgumentFails() {
        XCTAssertThrowsError(try CLIParser.parse(arguments: ["--pdf"])) { error in
            XCTAssertEqual(error as? ScraperError, .missingOptionValue("--pdf"))
        }
    }

    func testPDFAutoNamingWithoutExtension() throws {
        let command = try CLIParser.parse(arguments: ["--pdf", "README"])

        guard case .pdf(let config) = command else {
            return XCTFail("pdf command expected")
        }

        XCTAssertEqual(config.outputFile.lastPathComponent, "README.pdf")
    }

    func testDownloadPDFsParsing() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/legal/trust/",
            "--download-pdfs", "downloads",
            "--auto-scroll",
            "--wait-selector", ".reports",
            "--header", "Accept-Language: ja",
            "--cookie", "name=session;value=abc;domain=example.com",
            "--verbose",
        ])

        guard case .downloadPDFs(let config) = command else {
            return XCTFail("downloadPDFs command expected")
        }

        XCTAssertEqual(config.url.absoluteString, "https://example.com/legal/trust/")
        XCTAssertTrue(config.outputDirectory.path.hasSuffix("/downloads"))
        XCTAssertTrue(config.wait.autoScrollEnabled)
        XCTAssertEqual(config.wait.selectorConditions, [".reports"])
        XCTAssertEqual(config.customHeaders["Accept-Language"], "ja")
        XCTAssertEqual(config.cookies.count, 1)
        XCTAssertTrue(config.verbose)
    }

    func testDownloadPDFsParsesSitemapBatch() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/legal/",
            "--sitemap",
            "--concurrency", "2",
            "--download-pdfs", "downloads",
        ])

        guard case .downloadPDFs(let config) = command else {
            return XCTFail("downloadPDFs command expected")
        }

        XCTAssertEqual(config.url.absoluteString, "https://example.com/legal/")
        XCTAssertEqual(config.batch, BatchMode(input: .sitemap, concurrency: 2))
        XCTAssertTrue(config.outputDirectory.path.hasSuffix("/downloads"))
    }

    func testDownloadPDFsParsesURLFileBatch() throws {
        let command = try CLIParser.parse(arguments: [
            "--url-file", "tmp/urls.txt",
            "--download-pdfs", "downloads",
            "--concurrency", "3",
        ])

        guard case .downloadPDFs(let config) = command else {
            return XCTFail("downloadPDFs command expected")
        }

        let expectedURLFile = URL(
            fileURLWithPath: "tmp/urls.txt",
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL

        XCTAssertEqual(config.url.path, expectedURLFile.path)
        XCTAssertEqual(config.batch, BatchMode(input: .urlFile(expectedURLFile), concurrency: 3))
    }

    func testDownloadLinkedPDFsParsesWithNormalScrapeOptions() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/article",
            "--content-only",
            "--markdown",
            "--output", "out/pages.json",
            "--download-linked-pdfs", "downloads",
        ])

        guard case .run(let config) = command else {
            return XCTFail("run command expected")
        }

        XCTAssertEqual(config.extraction, .contentOnly)
        XCTAssertEqual(config.outputFormat, .markdown)
        XCTAssertTrue(config.linkedPDFDownloadDirectory?.path.hasSuffix("/downloads") == true)
    }

    func testDownloadLinkedPDFsParsesSitemapBatch() throws {
        let command = try CLIParser.parse(arguments: [
            "https://example.com/docs",
            "--sitemap",
            "--concurrency", "2",
            "--content-only",
            "--download-linked-pdfs", "downloads",
        ])

        guard case .run(let config) = command else {
            return XCTFail("run command expected")
        }

        XCTAssertEqual(config.url.absoluteString, "https://example.com/docs")
        XCTAssertEqual(config.batch, BatchMode(input: .sitemap, concurrency: 2))
        XCTAssertEqual(config.extraction, .contentOnly)
        XCTAssertTrue(config.linkedPDFDownloadDirectory?.path.hasSuffix("/downloads") == true)
    }

    func testDownloadPDFsCannotCombineWithPDFGeneration() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "--pdf", "notes.md",
                "--download-pdfs", "downloads",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--pdf` と `--download-pdfs` は同時に指定できません")
            )
        }
    }

    func testDownloadLinkedPDFsCannotCombineWithPDFGeneration() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "--pdf", "notes.md",
                "--download-linked-pdfs", "downloads",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--pdf` と `--download-linked-pdfs` は同時に指定できません")
            )
        }
    }

    func testDownloadPDFsRejectsOutputOptions() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--download-pdfs", "downloads",
                "--output", "out/result.json",
            ])
        ) { error in
            XCTAssertEqual(error as? ScraperError, .invalidArgument("`--output` は `--download-pdfs` では使用できません"))
        }
    }

    func testDownloadPDFsBatchRejectsCookieJar() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--download-pdfs", "downloads",
                "--sitemap",
                "--cookie-jar", "cookies.json",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--cookie-jar` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            )
        }
    }

    func testDownloadModesCannotBeCombined() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: [
                "https://example.com",
                "--download-pdfs", "downloads",
                "--download-linked-pdfs", "linked-downloads",
            ])
        ) { error in
            XCTAssertEqual(
                error as? ScraperError,
                .invalidArgument("`--download-pdfs` と `--download-linked-pdfs` は同時に指定できません")
            )
        }
    }
}

final class ExtractionScriptTests: XCTestCase {
    func testAutoScrollScriptBuildsScrollProbe() {
        let script = WebScraper.makeAutoScrollScriptForTesting()

        XCTAssertTrue(script.contains("document.scrollingElement"))
        XCTAssertTrue(script.contains("window.scrollTo(0, nextTop)"))
        XCTAssertTrue(script.contains("clientHeight"))
        XCTAssertTrue(script.contains("reachedBottom"))
        XCTAssertTrue(script.contains("JSON.stringify"))
    }

    func testOuterHTMLExtractionRemovesScriptTags() {
        let script = WebScraper.makeExtractionScriptForTesting(.outerHTML)

        XCTAssertTrue(script.contains("cloneNode(true)"))
        XCTAssertTrue(script.contains("querySelectorAll('script, noscript')"))
        XCTAssertTrue(script.contains("querySelectorAll('iframe')"))
        XCTAssertTrue(script.contains("iframe.hidden"))
        XCTAssertTrue(script.contains("style.display === 'none'"))
        XCTAssertTrue(script.contains("rect.width === 0 || rect.height === 0"))
        XCTAssertTrue(script.contains("return clone.outerHTML"))
    }

    func testSelectorInnerHTMLExtractionRemovesNestedScriptTags() {
        let script = WebScraper.makeExtractionScriptForTesting(.selectorInnerHTML("#app"))

        XCTAssertTrue(script.contains("document.querySelector"))
        XCTAssertTrue(script.contains("['script', 'noscript'].includes"))
        XCTAssertTrue(script.contains("querySelectorAll('script, noscript')"))
        XCTAssertTrue(script.contains("element.tagName.toLowerCase() === 'iframe'"))
        XCTAssertTrue(script.contains("querySelectorAll('iframe')"))
        XCTAssertTrue(script.contains("style.visibility === 'hidden'"))
        XCTAssertTrue(script.contains("return clone.innerHTML"))
    }

    func testBodyTextExtractionDoesNotNeedSanitizer() {
        let script = WebScraper.makeExtractionScriptForTesting(.bodyText)

        XCTAssertEqual(script, "document.body ? document.body.innerText : ''")
    }

    func testContentOnlyExtractionBuildsContentCandidateScript() {
        let script = WebScraper.makeExtractionScriptForTesting(.contentOnly)

        XCTAssertTrue(script.contains("const selectors = ["))
        XCTAssertTrue(script.contains("'main'"))
        XCTAssertTrue(script.contains("'article'"))
        XCTAssertTrue(script.contains("sidebarLike"))
        XCTAssertTrue(script.contains("describeNode"))
        XCTAssertTrue(script.contains("return analysis.clone ? analysis.clone.outerHTML : ''"))
    }

    func testStructureInspectionExtractionBuildsReportScript() {
        let script = WebScraper.makeExtractionScriptForTesting(.structureInspection)

        XCTAssertTrue(script.contains("JSON.stringify"))
        XCTAssertTrue(script.contains("contentOnlyRemoval"))
        XCTAssertTrue(script.contains("candidateTextLength"))
        XCTAssertTrue(script.contains("querySelectorAll('header, [role=\"banner\"]')"))
        XCTAssertTrue(script.contains("querySelectorAll('main, [role=\"main\"]')"))
    }

    func testImageCandidateScriptBuildsCollectionProbe() {
        let script = WebScraper.makeImageCandidateScriptForTesting()

        XCTAssertTrue(script.contains("Array.from(document.images)"))
        XCTAssertTrue(script.contains("img.currentSrc || img.src"))
        XCTAssertTrue(script.contains("collectAncestors"))
        XCTAssertTrue(script.contains("nearestTextBlockLength"))
        XCTAssertTrue(script.contains("linkedToRoot"))
        XCTAssertTrue(script.contains("JSON.stringify"))
    }

    func testPDFLinkExtractionScriptBuildsAnchorProbe() {
        let script = WebScraper.makePDFLinkExtractionScriptForTesting()

        XCTAssertTrue(script.contains("querySelectorAll('a[href]')"))
        XCTAssertTrue(script.contains("new URL(anchor.getAttribute('href'), document.baseURI)"))
        XCTAssertTrue(script.contains("pathname.toLowerCase().endsWith('.pdf')"))
        XCTAssertTrue(script.contains("firstNonEmpty"))
        XCTAssertTrue(script.contains("navigator.userAgent"))
        XCTAssertTrue(script.contains("JSON.stringify"))
    }
}
