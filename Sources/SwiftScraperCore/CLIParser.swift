import Foundation

public enum CLIParser {
    public static func parse(arguments: [String]) throws -> CLICommand {
        try parse(arguments: arguments, browserCookieReader: nil)
    }

    static func parse(
        arguments: [String],
        browserCookieReader: (any BrowserCookieReader)?
    ) throws -> CLICommand {
        let normalizedArguments = stripSwiftRunArgumentSeparator(from: arguments)

        if normalizedArguments.contains("--help") || normalizedArguments.contains("-h") {
            return .help(usage)
        }

        if normalizedArguments.contains("--version") {
            return .version(SwiftScraperVersion.current)
        }

        var state = ParseState()

        var index = 0
        while index < normalizedArguments.count {
            let argument = normalizedArguments[index]

            switch argument {
            case "--bidi-server":
                state.bidiServer = true
            case "--bidi-host":
                state.bidiHostSpecified = true
                state.bidiHost = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
            case "--bidi-port":
                state.bidiPortSpecified = true
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.bidiPort = try parsePort(raw, option: argument)
            case "--pdf":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.pdfInputPath = raw
            case "--download-pdfs":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.pdfDownloadDirectory == nil else {
                    throw ScraperError.invalidArgument("`--download-pdfs` may be specified only once")
                }
                state.pdfDownloadDirectory = resolvePath(raw)
            case "--download-linked-pdfs":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.linkedPDFDownloadDirectory == nil else {
                    throw ScraperError.invalidArgument("`--download-linked-pdfs` may be specified only once")
                }
                state.linkedPDFDownloadDirectory = resolvePath(raw)
            case "--overwrite-pdfs":
                state.overwritePDFs = true
            case "--max-pdf-size":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.maxPDFSizeSpecified = true
                state.maxPDFSizeMegabytes = try parseMaxPDFSize(raw, option: argument)
            case "--url":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                try ensureSingleURL(existing: state.url)
                state.url = try parseURL(raw)
            case "--cookie":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.cookies.append(try parseCookie(raw))
            case "--cookie-file":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.cookieFiles.append(resolvePath(raw))
            case "--cookie-jar":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.cookieJar == nil else {
                    throw ScraperError.invalidArgument("`--cookie-jar` may be specified only once")
                }
                state.cookieJar = resolvePath(raw)
            case "--browser-cookies":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.browserCookieBrowser == nil else {
                    throw ScraperError.invalidArgument("`--browser-cookies` may be specified only once")
                }
                guard let browser = BrowserCookieBrowser(rawValue: raw.lowercased()) else {
                    throw ScraperError.invalidArgument(
                        "`--browser-cookies` supports chrome or firefox only. Brave, Windows/Linux and Firefox containers are out of scope"
                    )
                }
                state.browserCookieBrowser = browser
            case "--browser-profile":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.browserProfile == nil, !raw.isEmpty else {
                    throw ScraperError.invalidArgument("`--browser-profile` may be specified only once and cannot be empty")
                }
                state.browserProfile = raw
            case "--header":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                let (name, value) = try parseHeader(raw)
                state.customHeaders[name] = value
            case "--persistent-store":
                state.dataStoreMode = .persistent
            case "--visibility":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard let parsed = VisibilityMode(rawValue: raw) else {
                    throw ScraperError.invalidArgument(
                        "--visibility must be one of \(VisibilityMode.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                state.visibility = parsed
            case "--viewport":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.viewport = try parseViewport(raw)
            case "--wait-delay":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.waitDelay = try parseSeconds(raw, option: argument, allowZero: true)
            case "--auto-scroll":
                state.autoScrollEnabled = true
            case "--wait-selector":
                state.waitSelectors.append(try nextValue(after: &index, arguments: normalizedArguments, option: argument))
            case "--wait-text":
                state.waitTexts.append(try nextValue(after: &index, arguments: normalizedArguments, option: argument))
            case "--poll-interval":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.pollInterval = try parseSeconds(raw, option: argument, allowZero: false)
            case "--dom-stable-delay":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.domStableDelay = try parseSeconds(raw, option: argument, allowZero: true)
            case "--load-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.timeouts = Timeouts(
                    load: try parseSeconds(raw, option: argument, allowZero: false),
                    render: state.timeouts.render,
                    javaScript: state.timeouts.javaScript
                )
            case "--wait-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.timeouts = Timeouts(
                    load: state.timeouts.load,
                    render: try parseSeconds(raw, option: argument, allowZero: false),
                    javaScript: state.timeouts.javaScript
                )
            case "--js-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.timeouts = Timeouts(
                    load: state.timeouts.load,
                    render: state.timeouts.render,
                    javaScript: try parseSeconds(raw, option: argument, allowZero: false)
                )
            case "--sitemap":
                try ensureSingleBatchInput(existing: state.batchInput, incomingOption: argument)
                state.batchInput = .sitemap
            case "--concurrency", "--sitemap-concurrency":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.concurrency = try parsePositiveInt(raw, option: argument)
                state.concurrencySpecified = true
            case "--url-file":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                try ensureSingleBatchInput(existing: state.batchInput, incomingOption: argument)
                state.batchInput = .urlFile(resolvePath(raw))
            case "--output":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.output = .file(resolvePath(raw))
            case "--markdown":
                state.outputFormat = .markdown
            case "--extract-images":
                state.imageExtractionEnabled = true
            case "--image-filter":
                state.imageExtractionEnabled = true
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard let parsed = ImageFilterMode(rawValue: raw) else {
                    throw ScraperError.invalidArgument(
                        "--image-filter must be one of \(ImageFilterMode.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                state.imageFilter = parsed
            case "--image-score-threshold":
                state.imageExtractionEnabled = true
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                state.imageScoreThreshold = try parseUnitDouble(raw, option: argument)
            case "--image-include-maybe":
                state.imageExtractionEnabled = true
                state.imageIncludeMaybe = true
            case "--image-debug":
                state.imageExtractionEnabled = true
                state.imageDebug = true
            case "--body-text":
                state.extractionFlagCount += 1
                state.extraction = .bodyText
            case "--selector-inner-html":
                state.extractionFlagCount += 1
                state.extraction = .selectorInnerHTML(
                    try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                )
            case "--content-only":
                state.extractionFlagCount += 1
                state.extraction = .contentOnly
            case "--inspect-structure":
                state.extractionFlagCount += 1
                state.extraction = .structureInspection
            case "--pretty-print":
                state.prettyPrint = true
            case "--verbose":
                state.verbose = true
            default:
                if argument.hasPrefix("-") {
                    throw ScraperError.unknownOption(argument)
                }

                try ensureSingleURL(existing: state.url)
                state.url = try parseURL(argument)
            }

            index += 1
        }

        return try state.makeCommand(browserCookieReader: browserCookieReader)
    }

    private struct ParseState {
        var pdfInputPath: String?
        var pdfDownloadDirectory: URL?
        var linkedPDFDownloadDirectory: URL?
        var bidiServer = false
        var bidiHost = "127.0.0.1"
        var bidiPort = 9222
        var bidiHostSpecified = false
        var bidiPortSpecified = false
        var url: URL?
        var cookies: [CookieDefinition] = []
        var cookieFiles: [URL] = []
        var cookieJar: URL?
        var browserCookieBrowser: BrowserCookieBrowser?
        var browserProfile: String?
        var customHeaders: [String: String] = [:]
        var dataStoreMode: DataStoreMode = .ephemeral
        var visibility: VisibilityMode = .windowless
        var viewport = Viewport.default
        var waitDelay: TimeInterval = WaitConfiguration.default.fixedDelay
        var waitSelectors: [String] = []
        var waitTexts: [String] = []
        var pollInterval: TimeInterval = WaitConfiguration.default.pollInterval
        var domStableDelay: TimeInterval = WaitConfiguration.default.domStableDelay
        var autoScrollEnabled: Bool = WaitConfiguration.default.autoScrollEnabled
        var timeouts = Timeouts.default
        var batchInput: BatchInputSource?
        var concurrency = 4
        var concurrencySpecified = false
        var output: OutputDestination = .stdout
        var outputFormat: OutputFormat = .plain
        var extraction: ExtractionMode = .outerHTML
        var imageExtractionEnabled = false
        var imageFilter: ImageFilterMode = .all
        var imageScoreThreshold = ImageExtractionConfiguration.disabled.scoreThreshold
        var imageIncludeMaybe = false
        var imageDebug = false
        var extractionFlagCount = 0
        var overwritePDFs = false
        var maxPDFSizeMegabytes = PDFDownloadResponseGuard.defaultMaximumMegabytes
        var maxPDFSizeSpecified = false
        var prettyPrint = false
        var verbose = false

        mutating func makeCommand(browserCookieReader: (any BrowserCookieReader)?) throws -> CLICommand {
            if browserProfile != nil && browserCookieBrowser == nil {
                throw ScraperError.invalidArgument("`--browser-profile` requires `--browser-cookies chrome|firefox`")
            }

            if browserCookieBrowser != nil && cookieJar != nil {
                throw ScraperError.invalidArgument("`--browser-cookies` cannot be combined with `--cookie-jar`")
            }

            if overwritePDFs && pdfDownloadDirectory == nil && linkedPDFDownloadDirectory == nil {
                throw ScraperError.invalidArgument("`--overwrite-pdfs` requires `--download-pdfs` or `--download-linked-pdfs`")
            }

            if maxPDFSizeSpecified && pdfDownloadDirectory == nil && linkedPDFDownloadDirectory == nil {
                throw ScraperError.invalidArgument("`--max-pdf-size` requires `--download-pdfs` or `--download-linked-pdfs`")
            }

            if bidiServer && pdfInputPath != nil {
                throw ScraperError.invalidArgument("`--bidi-server` and `--pdf` cannot be used together")
            }

            if bidiServer && pdfDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--bidi-server` and `--download-pdfs` cannot be used together")
            }

            if bidiServer && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--bidi-server` and `--download-linked-pdfs` cannot be used together")
            }

            if pdfInputPath != nil && pdfDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--pdf` and `--download-pdfs` cannot be used together")
            }

            if pdfInputPath != nil && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--pdf` and `--download-linked-pdfs` cannot be used together")
            }

            if pdfInputPath != nil && browserCookieBrowser != nil {
                throw ScraperError.invalidArgument("`--browser-cookies` cannot be used with `--pdf`")
            }

            if pdfDownloadDirectory != nil && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--download-pdfs` and `--download-linked-pdfs` cannot be used together")
            }

            if !bidiServer && (bidiHostSpecified || bidiPortSpecified) {
                throw ScraperError.invalidArgument("`--bidi-host` / `--bidi-port` require `--bidi-server`")
            }

            if let pdfInputPath {
                return makePDFCommand(inputPath: pdfInputPath)
            }

            if bidiServer { _ = try BiDiAccessGuard.loopbackHost(bidiHost) }
            try loadCookieFiles()
            try loadBrowserCookies(using: browserCookieReader)

            if let pdfDownloadDirectory {
                return try makePDFDownloadCommand(outputDirectory: pdfDownloadDirectory)
            }

            if bidiServer {
                return try makeBiDiServerCommand()
            }

            return try makeRunCommand()
        }

        private mutating func loadCookieFiles() throws {
            for cookieFile in cookieFiles {
                cookies.append(contentsOf: try CLIParser.loadCookies(from: cookieFile))
            }
        }

        private mutating func loadBrowserCookies(using suppliedReader: (any BrowserCookieReader)?) throws {
            guard let browserCookieBrowser else {
                return
            }

            let source = BrowserCookieSource(browser: browserCookieBrowser, profile: browserProfile)
            let reader = suppliedReader ?? source.makeReader()
            do {
                let browserCookies = try BrowserCookieLoader.load(source: source, reader: reader)
                cookies = BrowserCookieLoader.merge(
                    browserCookies: browserCookies,
                    explicitCookies: cookies
                )
            } catch let error as BrowserCookieError {
                throw ScraperError.browserCookieFailed(error.localizedDescription)
            } catch {
                throw ScraperError.browserCookieFailed("Unable to read the database")
            }
        }

        private func makePDFCommand(inputPath: String) -> CLICommand {
            let inputFile = CLIParser.resolvePath(inputPath)
            let outputFile: URL
            if case .file(let fileURL) = output {
                outputFile = fileURL
            } else {
                let base = inputFile.deletingPathExtension()
                outputFile = base.appendingPathExtension("pdf")
            }

            return .pdf(PDFConfiguration(inputFile: inputFile, outputFile: outputFile, verbose: verbose))
        }

        private func makePDFDownloadCommand(outputDirectory: URL) throws -> CLICommand {
            try validatePDFDownloadOptions()
            let resolvedURL = try resolvedOperationURL()
            let batch = batchInput.map { BatchMode(input: $0, concurrency: concurrency) }

            let wait = WaitConfiguration(
                fixedDelay: waitDelay,
                selectorConditions: waitSelectors,
                textConditions: waitTexts,
                pollInterval: pollInterval,
                domStableDelay: domStableDelay,
                autoScrollEnabled: autoScrollEnabled
            )

            return .downloadPDFs(
                PDFDownloadConfiguration(
                    url: resolvedURL,
                    outputDirectory: outputDirectory,
                    cookies: cookies,
                    cookieJar: cookieJar,
                    customHeaders: customHeaders,
                    dataStoreMode: dataStoreMode,
                    visibility: visibility,
                    viewport: viewport,
                    wait: wait,
                    timeouts: timeouts,
                    batch: batch,
                    overwritePDFs: overwritePDFs,
                    maxPDFSizeMegabytes: maxPDFSizeMegabytes,
                    verbose: verbose
                )
            )
        }

        private func makeBiDiServerCommand() throws -> CLICommand {
            _ = try BiDiAccessGuard.loopbackHost(bidiHost)
            if batchInput != nil {
                throw ScraperError.invalidArgument("`--bidi-server` cannot be used with batch execution (`--sitemap` / `--url-file`)")
            }

            if concurrencySpecified {
                throw ScraperError.invalidArgument("`--concurrency` cannot be used with `--bidi-server`")
            }

            if cookieJar != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` cannot be used with `--bidi-server`")
            }

            if case .file = output {
                throw ScraperError.invalidArgument("`--output` cannot be used with `--bidi-server`")
            }

            if extractionFlagCount > 0 || outputFormat != .plain || imageExtractionEnabled || prettyPrint {
                throw ScraperError.invalidArgument("Extraction, formatting and conversion options cannot be used with `--bidi-server`")
            }

            return .bidiServer(
                BiDiServerConfiguration(
                    host: bidiHost,
                    port: bidiPort,
                    initialURL: url,
                    cookies: cookies,
                    customHeaders: customHeaders,
                    dataStoreMode: dataStoreMode,
                    visibility: visibility,
                    viewport: viewport,
                    timeouts: timeouts,
                    verbose: verbose
                )
            )
        }

        private mutating func makeRunCommand() throws -> CLICommand {
            try validateRunOptions()
            let resolvedURL = try resolveRunURL()

            let wait = WaitConfiguration(
                fixedDelay: waitDelay,
                selectorConditions: waitSelectors,
                textConditions: waitTexts,
                pollInterval: pollInterval,
                domStableDelay: domStableDelay,
                autoScrollEnabled: autoScrollEnabled
            )

            let batch = batchInput.map { BatchMode(input: $0, concurrency: concurrency) }
            let imageExtraction = ImageExtractionConfiguration(
                enabled: imageExtractionEnabled,
                filter: imageFilter,
                scoreThreshold: imageScoreThreshold,
                includeMaybe: imageIncludeMaybe,
                debug: imageDebug
            )

            return .run(
                ScraperConfiguration(
                    url: resolvedURL,
                    cookies: cookies,
                    cookieJar: cookieJar,
                    customHeaders: customHeaders,
                    dataStoreMode: dataStoreMode,
                    visibility: visibility,
                    viewport: viewport,
                    wait: wait,
                    timeouts: timeouts,
                    batch: batch,
                    output: output,
                    outputFormat: outputFormat,
                    extraction: extraction,
                    imageExtraction: imageExtraction,
                    linkedPDFDownloadDirectory: linkedPDFDownloadDirectory,
                    overwritePDFs: overwritePDFs,
                    maxPDFSizeMegabytes: maxPDFSizeMegabytes,
                    prettyPrint: prettyPrint,
                    verbose: verbose
                )
            )
        }

        private func validateRunOptions() throws {
            if extractionFlagCount > 1 {
                throw ScraperError.invalidArgument(
                    "Only one extraction mode may be specified among `--body-text` / `--selector-inner-html` / `--content-only` / `--inspect-structure`"
                )
            }

            if outputFormat == .markdown && prettyPrint {
                throw ScraperError.invalidArgument("`--markdown` and `--pretty-print` cannot be used together")
            }

            if outputFormat == .markdown && !CLIParser.supportsMarkdown(extraction) {
                throw ScraperError.invalidArgument("`--markdown` requires an extraction mode that returns HTML")
            }

            if imageExtractionEnabled && !CLIParser.supportsImageExtraction(extraction) {
                throw ScraperError.invalidArgument("`--extract-images` requires an extraction mode that returns HTML")
            }

            if concurrencySpecified && batchInput == nil {
                throw ScraperError.invalidArgument("`--concurrency` requires `--sitemap` or `--url-file`")
            }

            if cookieJar != nil && batchInput != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` cannot be used with batch execution (`--sitemap` / `--url-file`)")
            }

            if case .urlFile = batchInput, url != nil {
                throw ScraperError.invalidArgument("A URL cannot be specified together with `--url-file`")
            }

            if case .sitemap = batchInput, url == nil {
                throw ScraperError.invalidArgument("`--sitemap` requires the target site URL")
            }
        }

        private func validatePDFDownloadOptions() throws {
            if concurrencySpecified && batchInput == nil {
                throw ScraperError.invalidArgument("`--concurrency` cannot be used with `--download-pdfs`")
            }

            if cookieJar != nil && batchInput != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` cannot be used with batch execution (`--sitemap` / `--url-file`)")
            }

            if case .urlFile = batchInput, url != nil {
                throw ScraperError.invalidArgument("A URL cannot be specified together with `--url-file`")
            }

            if case .sitemap = batchInput, url == nil {
                throw ScraperError.invalidArgument("`--sitemap` requires the target site URL")
            }

            if case .file = output {
                throw ScraperError.invalidArgument("`--output` cannot be used with `--download-pdfs`")
            }

            if extractionFlagCount > 0 || outputFormat != .plain || imageExtractionEnabled || prettyPrint {
                throw ScraperError.invalidArgument("Extraction, formatting and conversion options cannot be used with `--download-pdfs`")
            }
        }

        private mutating func resolveRunURL() throws -> URL {
            let resolved = try resolvedOperationURL()
            url = resolved
            return resolved
        }

        private func resolvedOperationURL() throws -> URL {
            if let batchInput, url == nil {
                switch batchInput {
                case .sitemap:
                    break
                case .urlFile(let fileURL):
                    return fileURL
                }
            }

            guard let url else {
                throw ScraperError.usage(CLIParser.usage)
            }

            return url
        }
    }

    private static func stripSwiftRunArgumentSeparator(from arguments: [String]) -> [String] {
        var normalizedArguments = arguments

        if normalizedArguments.first == "--" {
            normalizedArguments.removeFirst()
        }

        return normalizedArguments
    }

    public static let usage = """
    Usage:
      swift-scraper <url> [options]
      swift-scraper <url> --download-pdfs <directory> [options]
      swift-scraper --pdf <file.md> [--output <file.pdf>] [--verbose]
      swift-scraper --bidi-server [url] [--bidi-host <host>] [--bidi-port <port>] [options]

    Options:
      --bidi-server                  Start the WKWebView BiDi bridge (Bearer token file path printed on startup)
      --bidi-host <host>             Loopback only: 127.0.0.1 (default), ::1, localhost
      --bidi-port <port>             BiDi server bind port; defaults to 9222
      --url <url>                    Set the target URL explicitly
      --cookie <spec>                Add one cookie
      --cookie-file <path>           Load cookies from JSON
      --cookie-jar <path>            Load CookieJar JSON and save it after execution
      --browser-cookies <browser>    Load cookies from macOS Chrome or Firefox
      --browser-profile <name|path>  Browser profile name or path; defaults to the default profile
      --header <Name: Value>         Add an HTTP header; may be specified multiple times
      --persistent-store             Use a persistent DataStore
      --visibility <mode>            windowless | hidden-window | visible-window
      --viewport <width>x<height>    WebView size; defaults to 1440x900
      --wait-delay <seconds>         Fixed wait after didFinish
      --auto-scroll                  Scroll downward to help trigger lazy loading
      --wait-selector <css>          Wait for a CSS selector; may be specified multiple times
      --wait-text <text>             Wait for text; may be specified multiple times
      --poll-interval <seconds>      Condition polling interval; defaults to 0.5
      --dom-stable-delay <seconds>   Time before the DOM is considered stable; defaults to 0.5
      --load-timeout <seconds>       Load-stage timeout; defaults to 30
      --wait-timeout <seconds>       Rendering wait timeout; defaults to 15
      --js-timeout <seconds>         evaluateJavaScript timeout; defaults to 10
      --sitemap                      Follow the target site's sitemap.xml for multiple URLs
      --url-file <path>              Read one URL per line from a file
      --concurrency <count>          Batch concurrency; defaults to 4
      --output <path>                Save to a file instead of standard output
      --download-pdfs <directory>    Save PDF links found on the page
      --download-linked-pdfs <dir>   Save PDF links alongside normal extraction
      --overwrite-pdfs               Replace existing PDFs instead of avoiding name collisions
      --max-pdf-size <megabytes>     Reject PDFs above this size before writing; defaults to 100 (1 MB = 1048576 bytes)
      --body-text                    Extract document.body.innerText
      --selector-inner-html <css>    Extract innerHTML from selected elements
      --content-only                 Extract content HTML without header, footer or sidebar
      --inspect-structure            Inspect page structure and content candidates without dumping HTML
      --markdown                     Convert HTML extraction results to Markdown
      --extract-images               Apply image heuristics to narrow images in HTML output
      --image-filter <mode>          all | article-only
      --image-score-threshold <0-1>  Keep threshold; defaults to 0.65
      --image-include-maybe          Keep images classified as maybe
      --image-debug                  Write image scores and reasons as JSON to stderr
      --pretty-print                 Format HTML output with SwiftSoup
      --pdf <file.md>                Convert a Markdown file to PDF
      --verbose                      Write progress logs to stderr
      --version                      Show the version
      --help                         Show this help

    Cookie spec format:
      name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true;expires=2026-12-31T00:00:00Z

    Cookie file format:
      JSON array or object with keys:
      name, value, domain, path, secure, httpOnly, expires
      --cookie-jar uses the same JSON format and writes a JSON array when saving.
      --browser-cookies supports chrome|firefox only (Brave, Windows/Linux and Firefox containers are out of scope).
      --browser-cookies cannot be combined with --cookie-jar. --cookie / --cookie-file take precedence.
    """

    static func parseHeader(_ raw: String) throws -> (String, String) {
        guard let colonIndex = raw.firstIndex(of: ":") else {
            throw ScraperError.invalidArgument("--header must use the 'Name: Value' format")
        }

        let name = raw[raw.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        let value = raw[raw.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else {
            throw ScraperError.invalidArgument("--header has an empty header name")
        }

        return (name, value)
    }

    public static func parseCookie(_ raw: String) throws -> CookieDefinition {
        var values: [String: String] = [:]

        for segment in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ScraperError.invalidCookieSpec("A segment is not in `key=value` form: \(segment)")
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else {
                throw ScraperError.invalidCookieSpec("A key is empty")
            }

            values[key] = value
        }

        guard let name = values.removeValue(forKey: "name"), !name.isEmpty else {
            throw ScraperError.invalidCookieSpec("name is required")
        }

        guard let value = values.removeValue(forKey: "value") else {
            throw ScraperError.invalidCookieSpec("value is required")
        }

        guard let domain = values.removeValue(forKey: "domain"), !domain.isEmpty else {
            throw ScraperError.invalidCookieSpec("domain is required")
        }

        let path = values.removeValue(forKey: "path") ?? "/"
        let secure = try parseBoolean(values.removeValue(forKey: "secure") ?? "false", key: "secure")
        let httpOnly = try parseBoolean(
            values.removeValue(forKey: "httpOnly") ?? values.removeValue(forKey: "http-only") ?? "false",
            key: "httpOnly"
        )

        let expires = try parseDate(values.removeValue(forKey: "expires"))

        if !values.isEmpty {
            throw ScraperError.invalidCookieSpec("Unsupported keys: \(values.keys.sorted().joined(separator: ", "))")
        }

        return CookieDefinition(
            name: name,
            value: value,
            domain: domain,
            path: path,
            secure: secure,
            httpOnly: httpOnly,
            expires: expires
        )
    }

    private static func supportsMarkdown(_ extraction: ExtractionMode) -> Bool {
        switch extraction {
        case .outerHTML, .selectorInnerHTML, .contentOnly:
            return true
        case .bodyText, .structureInspection:
            return false
        }
    }

    private static func supportsImageExtraction(_ extraction: ExtractionMode) -> Bool {
        supportsMarkdown(extraction)
    }

    private static func parseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
            throw ScraperError.invalidURL(raw)
        }

        return url
    }

    private static func ensureSingleURL(existing: URL?) throws {
        if existing != nil {
            throw ScraperError.invalidArgument("Only one URL may be specified")
        }
    }

    private static func ensureSingleBatchInput(existing: BatchInputSource?, incomingOption: String) throws {
        guard let existing else {
            return
        }

        let existingOption: String
        switch existing {
        case .sitemap:
            existingOption = "--sitemap"
        case .urlFile:
            existingOption = "--url-file"
        }

        throw ScraperError.invalidArgument("`\(existingOption)` and `\(incomingOption)` cannot be used together")
    }

    private static func nextValue(after index: inout Int, arguments: [String], option: String) throws -> String {
        let nextIndex = index + 1
        guard nextIndex < arguments.count else {
            throw ScraperError.missingOptionValue(option)
        }

        index = nextIndex
        return arguments[nextIndex]
    }

    private static func parseViewport(_ raw: String) throws -> Viewport {
        let components = raw.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]),
              width > 0,
              height > 0 else {
            throw ScraperError.invalidArgument("--viewport must look like 1440x900")
        }

        return Viewport(width: width, height: height)
    }

    private static func parseSeconds(_ raw: String, option: String, allowZero: Bool) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite else {
            throw ScraperError.invalidArgument("\(option) must be a number")
        }

        if allowZero {
            guard value >= 0 else {
                throw ScraperError.invalidArgument("\(option) must be 0 or greater")
            }
        } else {
            guard value > 0 else {
                throw ScraperError.invalidArgument("\(option) must be greater than 0")
            }
        }

        return value
    }

    private static func parseUnitDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw ScraperError.invalidArgument("\(option) must be a number")
        }

        guard (0...1).contains(value) else {
            throw ScraperError.invalidArgument("\(option) must be between 0.0 and 1.0")
        }

        return value
    }

    private static func parsePositiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ScraperError.invalidArgument("\(option) must be an integer")
        }

        guard value > 0 else {
            throw ScraperError.invalidArgument("\(option) must be 1 or greater")
        }

        return value
    }

    private static func parsePort(_ raw: String, option: String) throws -> Int {
        let port = try parsePositiveInt(raw, option: option)
        guard port <= 65_535 else {
            throw ScraperError.invalidArgument("\(option) must be between 1 and 65535")
        }

        return port
    }

    private static func parseMaxPDFSize(_ raw: String, option: String) throws -> Int {
        let megabytes = try parsePositiveInt(raw, option: option)

        guard megabytes <= PDFDownloadResponseGuard.maximumMegabytesLimit else {
            throw ScraperError.invalidArgument(
                "\(option) must be between 1 and \(PDFDownloadResponseGuard.maximumMegabytesLimit)"
            )
        }

        return megabytes
    }

    private static func parseBoolean(_ raw: String, key: String) throws -> Bool {
        switch raw.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            throw ScraperError.invalidCookieSpec("\(key) must be true or false")
        }
    }

    private static func parseDate(_ raw: String?) throws -> Date? {
        guard let raw else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: raw) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        if let date = fallback.date(from: raw) {
            return date
        }

        throw ScraperError.invalidCookieSpec("expires must be an ISO8601 timestamp")
    }

    private static func resolvePath(_ raw: String) -> URL {
        let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL
    }

    private static func loadCookies(from fileURL: URL) throws -> [CookieDefinition] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ScraperError.invalidCookieFile("\(fileURL.path): \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let array = try? decoder.decode([CookieDefinition].self, from: data) {
            return array
        }

        do {
            return [try decoder.decode(CookieDefinition.self, from: data)]
        } catch {
            throw ScraperError.invalidCookieFile("\(fileURL.path): \(error.localizedDescription)")
        }
    }
}
