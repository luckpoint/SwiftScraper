import Foundation

public enum CLIParser {
    public static func parse(arguments: [String]) throws -> CLICommand {
        let normalizedArguments = stripSwiftRunArgumentSeparator(from: arguments)

        if normalizedArguments.contains("--help") || normalizedArguments.contains("-h") {
            return .help(usage)
        }

        var url: URL?
        var cookies: [CookieDefinition] = []
        var cookieFiles: [URL] = []
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
        var extractionFlagCount = 0
        var prettyPrint = false
        var verbose = false

        var index = 0
        while index < normalizedArguments.count {
            let argument = normalizedArguments[index]

            switch argument {
            case "--url":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                try ensureSingleURL(existing: url)
                url = try parseURL(raw)
            case "--cookie":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                cookies.append(try parseCookie(raw))
            case "--cookie-file":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                cookieFiles.append(resolvePath(raw))
            case "--persistent-store":
                dataStoreMode = .persistent
            case "--visibility":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                guard let parsed = VisibilityMode(rawValue: raw) else {
                    throw ScraperError.invalidArgument(
                        "--visibility は \(VisibilityMode.allCases.map(\.rawValue).joined(separator: ", ")) のいずれかを指定してください"
                    )
                }
                visibility = parsed
            case "--viewport":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                viewport = try parseViewport(raw)
            case "--wait-delay":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                waitDelay = try parseSeconds(raw, option: argument, allowZero: true)
            case "--auto-scroll":
                autoScrollEnabled = true
            case "--wait-selector":
                waitSelectors.append(try nextValue(after: &index, arguments: normalizedArguments, option: argument))
            case "--wait-text":
                waitTexts.append(try nextValue(after: &index, arguments: normalizedArguments, option: argument))
            case "--poll-interval":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                pollInterval = try parseSeconds(raw, option: argument, allowZero: false)
            case "--dom-stable-delay":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                domStableDelay = try parseSeconds(raw, option: argument, allowZero: true)
            case "--load-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                timeouts = Timeouts(
                    load: try parseSeconds(raw, option: argument, allowZero: false),
                    render: timeouts.render,
                    javaScript: timeouts.javaScript
                )
            case "--wait-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                timeouts = Timeouts(
                    load: timeouts.load,
                    render: try parseSeconds(raw, option: argument, allowZero: false),
                    javaScript: timeouts.javaScript
                )
            case "--js-timeout":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                timeouts = Timeouts(
                    load: timeouts.load,
                    render: timeouts.render,
                    javaScript: try parseSeconds(raw, option: argument, allowZero: false)
                )
            case "--sitemap":
                try ensureSingleBatchInput(existing: batchInput, incomingOption: argument)
                batchInput = .sitemap
            case "--concurrency", "--sitemap-concurrency":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                concurrency = try parsePositiveInt(raw, option: argument)
                concurrencySpecified = true
            case "--url-file":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                try ensureSingleBatchInput(existing: batchInput, incomingOption: argument)
                batchInput = .urlFile(resolvePath(raw))
            case "--output":
                let raw = try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                output = .file(resolvePath(raw))
            case "--markdown":
                outputFormat = .markdown
            case "--body-text":
                extractionFlagCount += 1
                extraction = .bodyText
            case "--selector-inner-html":
                extractionFlagCount += 1
                extraction = .selectorInnerHTML(
                    try nextValue(after: &index, arguments: normalizedArguments, option: argument)
                )
            case "--content-only":
                extractionFlagCount += 1
                extraction = .contentOnly
            case "--inspect-structure":
                extractionFlagCount += 1
                extraction = .structureInspection
            case "--pretty-print":
                prettyPrint = true
            case "--verbose":
                verbose = true
            default:
                if argument.hasPrefix("-") {
                    throw ScraperError.unknownOption(argument)
                }

                try ensureSingleURL(existing: url)
                url = try parseURL(argument)
            }

            index += 1
        }

        if extractionFlagCount > 1 {
            throw ScraperError.invalidArgument(
                "抽出モードは `--body-text` / `--selector-inner-html` / `--content-only` / `--inspect-structure` のうち 1 つだけ指定できます"
            )
        }

        if outputFormat == .markdown && prettyPrint {
            throw ScraperError.invalidArgument("`--markdown` と `--pretty-print` は同時に指定できません")
        }

        if outputFormat == .markdown && !supportsMarkdown(extraction) {
            throw ScraperError.invalidArgument("`--markdown` は HTML を返す抽出モードでだけ指定できます")
        }

        if concurrencySpecified && batchInput == nil {
            throw ScraperError.invalidArgument("`--concurrency` は `--sitemap` または `--url-file` と一緒に指定してください")
        }

        for cookieFile in cookieFiles {
            cookies.append(contentsOf: try loadCookies(from: cookieFile))
        }

        if case .urlFile = batchInput, url != nil {
            throw ScraperError.invalidArgument("`--url-file` を使う場合は URL を同時に指定できません")
        }

        if case .sitemap = batchInput, url == nil {
            throw ScraperError.invalidArgument("`--sitemap` を使う場合は対象サイトの URL を指定してください")
        }

        if let batchInput, url == nil {
            switch batchInput {
            case .sitemap:
                break
            case .urlFile(let fileURL):
                url = fileURL
            }
        }

        guard let url else {
            throw ScraperError.usage(usage)
        }

        let wait = WaitConfiguration(
            fixedDelay: waitDelay,
            selectorConditions: waitSelectors,
            textConditions: waitTexts,
            pollInterval: pollInterval,
            domStableDelay: domStableDelay,
            autoScrollEnabled: autoScrollEnabled
        )

        let batch = batchInput.map { BatchMode(input: $0, concurrency: concurrency) }

        return .run(
            ScraperConfiguration(
                url: url,
                cookies: cookies,
                dataStoreMode: dataStoreMode,
                visibility: visibility,
                viewport: viewport,
                wait: wait,
                timeouts: timeouts,
                batch: batch,
                output: output,
                outputFormat: outputFormat,
                extraction: extraction,
                prettyPrint: prettyPrint,
                verbose: verbose
            )
        )
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

    Options:
      --url <url>                    対象 URL を明示指定
      --cookie <spec>                Cookie を 1 件追加
      --cookie-file <path>           Cookie JSON を読み込む
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
      --body-text                    document.body.innerText を抽出
      --selector-inner-html <css>    特定要素の innerHTML を抽出
      --content-only                 ヘッダ・フッタ・サイドバー等を除いた本文候補の HTML を抽出
      --inspect-structure            ページ構成と本文候補だけを確認し、HTML はダンプしない
      --markdown                     HTML 系抽出結果を Markdown に変換して出力
      --pretty-print                 HTML 系の出力を SwiftSoup で整形
      --verbose                      stderr に進行ログを出す
      --help                         ヘルプを表示

    Cookie spec format:
      name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true;expires=2026-12-31T00:00:00Z

    Cookie file format:
      JSON array or object with keys:
      name, value, domain, path, secure, httpOnly, expires
    """

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

    private static func parsePositiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ScraperError.invalidArgument("\(option) は整数で指定してください")
        }

        guard value > 0 else {
            throw ScraperError.invalidArgument("\(option) は 1 以上で指定してください")
        }

        return value
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
