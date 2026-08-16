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
                    throw ScraperError.invalidArgument("`--download-pdfs` は 1 つだけ指定してください")
                }
                state.pdfDownloadDirectory = resolvePath(raw)
            case "--download-linked-pdfs":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.linkedPDFDownloadDirectory == nil else {
                    throw ScraperError.invalidArgument("`--download-linked-pdfs` は 1 つだけ指定してください")
                }
                state.linkedPDFDownloadDirectory = resolvePath(raw)
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
                    throw ScraperError.invalidArgument("`--cookie-jar` は 1 つだけ指定してください")
                }
                state.cookieJar = resolvePath(raw)
            case "--browser-cookies":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.browserCookieBrowser == nil else {
                    throw ScraperError.invalidArgument("`--browser-cookies` は 1 つだけ指定してください")
                }
                guard let browser = BrowserCookieBrowser(rawValue: raw.lowercased()) else {
                    throw ScraperError.invalidArgument(
                        "`--browser-cookies` は chrome または firefox のみ対応しています。Brave、Windows/Linux、Firefox コンテナは対象外です"
                    )
                }
                state.browserCookieBrowser = browser
            case "--browser-profile":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard state.browserProfile == nil, !raw.isEmpty else {
                    throw ScraperError.invalidArgument("`--browser-profile` は 1 つだけ指定し、空にできません")
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
                        "--visibility は \(VisibilityMode.allCases.map(\.rawValue).joined(separator: ", ")) のいずれかを指定してください"
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
                        "--image-filter は \(ImageFilterMode.allCases.map(\.rawValue).joined(separator: ", ")) のいずれかを指定してください"
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
        var prettyPrint = false
        var verbose = false

        mutating func makeCommand(browserCookieReader: (any BrowserCookieReader)?) throws -> CLICommand {
            if browserProfile != nil && browserCookieBrowser == nil {
                throw ScraperError.invalidArgument("`--browser-profile` は `--browser-cookies chrome|firefox` と一緒に指定してください")
            }

            if browserCookieBrowser != nil && cookieJar != nil {
                throw ScraperError.invalidArgument("`--browser-cookies` と `--cookie-jar` は併用できません")
            }

            if bidiServer && pdfInputPath != nil {
                throw ScraperError.invalidArgument("`--bidi-server` と `--pdf` は同時に指定できません")
            }

            if bidiServer && pdfDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--bidi-server` と `--download-pdfs` は同時に指定できません")
            }

            if bidiServer && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--bidi-server` と `--download-linked-pdfs` は同時に指定できません")
            }

            if pdfInputPath != nil && pdfDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--pdf` と `--download-pdfs` は同時に指定できません")
            }

            if pdfInputPath != nil && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--pdf` と `--download-linked-pdfs` は同時に指定できません")
            }

            if pdfInputPath != nil && browserCookieBrowser != nil {
                throw ScraperError.invalidArgument("`--browser-cookies` は `--pdf` では使用できません")
            }

            if pdfDownloadDirectory != nil && linkedPDFDownloadDirectory != nil {
                throw ScraperError.invalidArgument("`--download-pdfs` と `--download-linked-pdfs` は同時に指定できません")
            }

            if !bidiServer && (bidiHostSpecified || bidiPortSpecified) {
                throw ScraperError.invalidArgument("`--bidi-host` / `--bidi-port` は `--bidi-server` と一緒に指定してください")
            }

            if let pdfInputPath {
                return makePDFCommand(inputPath: pdfInputPath)
            }

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
                throw ScraperError.browserCookieFailed("データベースの読み取りに失敗しました")
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
                    verbose: verbose
                )
            )
        }

        private func makeBiDiServerCommand() throws -> CLICommand {
            if batchInput != nil {
                throw ScraperError.invalidArgument("`--bidi-server` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            }

            if concurrencySpecified {
                throw ScraperError.invalidArgument("`--concurrency` は `--bidi-server` では使用できません")
            }

            if cookieJar != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` は `--bidi-server` では使用できません")
            }

            if case .file = output {
                throw ScraperError.invalidArgument("`--output` は `--bidi-server` では使用できません")
            }

            if extractionFlagCount > 0 || outputFormat != .plain || imageExtractionEnabled || prettyPrint {
                throw ScraperError.invalidArgument("抽出・整形・変換オプションは `--bidi-server` では使用できません")
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
                    prettyPrint: prettyPrint,
                    verbose: verbose
                )
            )
        }

        private func validateRunOptions() throws {
            if extractionFlagCount > 1 {
                throw ScraperError.invalidArgument(
                    "抽出モードは `--body-text` / `--selector-inner-html` / `--content-only` / `--inspect-structure` のうち 1 つだけ指定できます"
                )
            }

            if outputFormat == .markdown && prettyPrint {
                throw ScraperError.invalidArgument("`--markdown` と `--pretty-print` は同時に指定できません")
            }

            if outputFormat == .markdown && !CLIParser.supportsMarkdown(extraction) {
                throw ScraperError.invalidArgument("`--markdown` は HTML を返す抽出モードでだけ指定できます")
            }

            if imageExtractionEnabled && !CLIParser.supportsImageExtraction(extraction) {
                throw ScraperError.invalidArgument("`--extract-images` は HTML を返す抽出モードでだけ指定できます")
            }

            if concurrencySpecified && batchInput == nil {
                throw ScraperError.invalidArgument("`--concurrency` は `--sitemap` または `--url-file` と一緒に指定してください")
            }

            if cookieJar != nil && batchInput != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            }

            if case .urlFile = batchInput, url != nil {
                throw ScraperError.invalidArgument("`--url-file` を使う場合は URL を同時に指定できません")
            }

            if case .sitemap = batchInput, url == nil {
                throw ScraperError.invalidArgument("`--sitemap` を使う場合は対象サイトの URL を指定してください")
            }
        }

        private func validatePDFDownloadOptions() throws {
            if concurrencySpecified && batchInput == nil {
                throw ScraperError.invalidArgument("`--concurrency` は `--download-pdfs` では使用できません")
            }

            if cookieJar != nil && batchInput != nil {
                throw ScraperError.invalidArgument("`--cookie-jar` は batch 実行（`--sitemap` / `--url-file`）では使用できません")
            }

            if case .urlFile = batchInput, url != nil {
                throw ScraperError.invalidArgument("`--url-file` を使う場合は URL を同時に指定できません")
            }

            if case .sitemap = batchInput, url == nil {
                throw ScraperError.invalidArgument("`--sitemap` を使う場合は対象サイトの URL を指定してください")
            }

            if case .file = output {
                throw ScraperError.invalidArgument("`--output` は `--download-pdfs` では使用できません")
            }

            if extractionFlagCount > 0 || outputFormat != .plain || imageExtractionEnabled || prettyPrint {
                throw ScraperError.invalidArgument("抽出・整形・変換オプションは `--download-pdfs` では使用できません")
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
      --bidi-server                 WKWebView BiDi bridge server を起動
      --bidi-host <host>            BiDi server の bind host。既定 127.0.0.1
      --bidi-port <port>            BiDi server の bind port。既定 9222
      --url <url>                    対象 URL を明示指定
      --cookie <spec>                Cookie を 1 件追加
      --cookie-file <path>           Cookie JSON を読み込む
      --cookie-jar <path>            CookieJar JSON を読み込み、実行後に保存する
      --browser-cookies <browser>    macOS Chrome または Firefox の Cookie を読み込む
      --browser-profile <name|path>  ブラウザプロファイル名またはパス。未指定時は既定プロファイル
      --header <Name: Value>         HTTP ヘッダーを追加。複数指定可
      --persistent-store             永続 DataStore を使う
      --visibility <mode>            windowless | hidden-window | visible-window
      --viewport <width>x<height>    WebView サイズ。既定 1440x900
      --wait-delay <seconds>         didFinish 後の固定待機
      --auto-scroll                  lazy load 補助のため下方向へ自動スクロール
      --wait-selector <css>          CSS セレクタ出現待機。複数指定可
      --wait-text <text>             テキスト出現待機。複数指定可
      --poll-interval <seconds>      条件待機のポーリング間隔。既定 0.5
      --dom-stable-delay <seconds>   DOM が変化せず安定したとみなす時間。既定 0.5
      --load-timeout <seconds>       ロード段階タイムアウト。既定 30
      --wait-timeout <seconds>       描画待機タイムアウト。既定 15
      --js-timeout <seconds>         evaluateJavaScript のタイムアウト。既定 10
      --sitemap                      対象サイトの sitemap.xml をたどって複数 URL を取得
      --url-file <path>              1 行 1 URL のファイルを読み込んで複数 URL を取得
      --concurrency <count>          batch 取得時の並列数。既定 4
      --output <path>                標準出力ではなくファイルへ保存
      --download-pdfs <directory>    ページ内の PDF リンクを保存
      --download-linked-pdfs <dir>   通常抽出と同時にページ内の PDF リンクを保存
      --body-text                    document.body.innerText を抽出
      --selector-inner-html <css>    特定要素の innerHTML を抽出
      --content-only                 ヘッダ・フッタ・サイドバー等を除いた本文候補の HTML を抽出
      --inspect-structure            ページ構成と本文候補だけを確認し、HTML はダンプしない
      --markdown                     HTML 系抽出結果を Markdown に変換して出力
      --extract-images               画像 heuristic を適用して HTML 系出力の画像を絞り込む
      --image-filter <mode>          all | article-only
      --image-score-threshold <0-1>  keep 判定の閾値。既定 0.65
      --image-include-maybe          maybe 判定の画像も出力に残す
      --image-debug                  画像スコアと理由を stderr に JSON で出す
      --pretty-print                 HTML 系の出力を SwiftSoup で整形
      --pdf <file.md>                Markdown ファイルを PDF に変換
      --verbose                      stderr に進行ログを出す
      --help                         ヘルプを表示

    Cookie spec format:
      name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true;expires=2026-12-31T00:00:00Z

    Cookie file format:
      JSON array or object with keys:
      name, value, domain, path, secure, httpOnly, expires
      --cookie-jar は同じ JSON 形式を使い、保存時は JSON array で書き出します。
      --browser-cookies は chrome|firefox のみ対応（Brave、Windows/Linux、Firefox コンテナは対象外）。
      --browser-cookies と --cookie-jar は併用できません。--cookie / --cookie-file が優先されます。
    """

    static func parseHeader(_ raw: String) throws -> (String, String) {
        guard let colonIndex = raw.firstIndex(of: ":") else {
            throw ScraperError.invalidArgument("--header は 'Name: Value' 形式で指定してください")
        }

        let name = raw[raw.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        let value = raw[raw.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else {
            throw ScraperError.invalidArgument("--header のヘッダー名が空です")
        }

        return (name, value)
    }

    public static func parseCookie(_ raw: String) throws -> CookieDefinition {
        var values: [String: String] = [:]

        for segment in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ScraperError.invalidCookieSpec("`key=value` 形式ではない要素があります: \(segment)")
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else {
                throw ScraperError.invalidCookieSpec("キーが空です")
            }

            values[key] = value
        }

        guard let name = values.removeValue(forKey: "name"), !name.isEmpty else {
            throw ScraperError.invalidCookieSpec("name が必要です")
        }

        guard let value = values.removeValue(forKey: "value") else {
            throw ScraperError.invalidCookieSpec("value が必要です")
        }

        guard let domain = values.removeValue(forKey: "domain"), !domain.isEmpty else {
            throw ScraperError.invalidCookieSpec("domain が必要です")
        }

        let path = values.removeValue(forKey: "path") ?? "/"
        let secure = try parseBoolean(values.removeValue(forKey: "secure") ?? "false", key: "secure")
        let httpOnly = try parseBoolean(
            values.removeValue(forKey: "httpOnly") ?? values.removeValue(forKey: "http-only") ?? "false",
            key: "httpOnly"
        )

        let expires = try parseDate(values.removeValue(forKey: "expires"))

        if !values.isEmpty {
            throw ScraperError.invalidCookieSpec("未対応キーがあります: \(values.keys.sorted().joined(separator: ", "))")
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
            throw ScraperError.invalidArgument("URL は 1 つだけ指定してください")
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

        throw ScraperError.invalidArgument("`\(existingOption)` と `\(incomingOption)` は同時に指定できません")
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
            throw ScraperError.invalidArgument("--viewport は 1440x900 のように指定してください")
        }

        return Viewport(width: width, height: height)
    }

    private static func parseSeconds(_ raw: String, option: String, allowZero: Bool) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite else {
            throw ScraperError.invalidArgument("\(option) は数値で指定してください")
        }

        if allowZero {
            guard value >= 0 else {
                throw ScraperError.invalidArgument("\(option) は 0 以上で指定してください")
            }
        } else {
            guard value > 0 else {
                throw ScraperError.invalidArgument("\(option) は 0 より大きい値で指定してください")
            }
        }

        return value
    }

    private static func parseUnitDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw ScraperError.invalidArgument("\(option) は数値で指定してください")
        }

        guard (0...1).contains(value) else {
            throw ScraperError.invalidArgument("\(option) は 0.0 以上 1.0 以下で指定してください")
        }

        return value
    }

    private static func parsePositiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ScraperError.invalidArgument("\(option) は整数で指定してください")
        }

        guard value > 0 else {
            throw ScraperError.invalidArgument("\(option) は 1 以上で指定してください")
        }

        return value
    }

    private static func parsePort(_ raw: String, option: String) throws -> Int {
        let port = try parsePositiveInt(raw, option: option)
        guard port <= 65_535 else {
            throw ScraperError.invalidArgument("\(option) は 1 以上 65535 以下で指定してください")
        }

        return port
    }

    private static func parseBoolean(_ raw: String, key: String) throws -> Bool {
        switch raw.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            throw ScraperError.invalidCookieSpec("\(key) は true/false で指定してください")
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

        throw ScraperError.invalidCookieSpec("expires は ISO8601 で指定してください")
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
