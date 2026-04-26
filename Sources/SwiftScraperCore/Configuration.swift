import Foundation

public enum VisibilityMode: String, CaseIterable, Sendable {
    case windowless = "windowless"
    case hiddenWindow = "hidden-window"
    case visibleWindow = "visible-window"
}

public enum DataStoreMode: String, CaseIterable, Sendable {
    case ephemeral
    case persistent
}

public enum ExtractionMode: Equatable, Sendable {
    case outerHTML
    case bodyText
    case selectorInnerHTML(String)
    case contentOnly
    case structureInspection
}

public struct Viewport: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public static let `default` = Viewport(width: 1440, height: 900)

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct WaitConfiguration: Equatable, Sendable {
    public let fixedDelay: TimeInterval
    public let selectorConditions: [String]
    public let textConditions: [String]
    public let pollInterval: TimeInterval
    public let domStableDelay: TimeInterval
    public let autoScrollEnabled: Bool

    public static let `default` = WaitConfiguration(
        fixedDelay: 0,
        selectorConditions: [],
        textConditions: [],
        pollInterval: 0.5,
        domStableDelay: 0.5,
        autoScrollEnabled: false
    )

    public init(
        fixedDelay: TimeInterval,
        selectorConditions: [String],
        textConditions: [String],
        pollInterval: TimeInterval,
        domStableDelay: TimeInterval,
        autoScrollEnabled: Bool
    ) {
        self.fixedDelay = fixedDelay
        self.selectorConditions = selectorConditions
        self.textConditions = textConditions
        self.pollInterval = pollInterval
        self.domStableDelay = domStableDelay
        self.autoScrollEnabled = autoScrollEnabled
    }
}

public struct Timeouts: Equatable, Sendable {
    public let load: TimeInterval
    public let render: TimeInterval
    public let javaScript: TimeInterval

    public static let `default` = Timeouts(
        load: 30,
        render: 15,
        javaScript: 10
    )

    public init(load: TimeInterval, render: TimeInterval, javaScript: TimeInterval) {
        self.load = load
        self.render = render
        self.javaScript = javaScript
    }
}

public enum BatchInputSource: Equatable, Sendable {
    case sitemap
    case urlFile(URL)
}

public struct BatchMode: Equatable, Sendable {
    public let input: BatchInputSource
    public let concurrency: Int

    public init(input: BatchInputSource, concurrency: Int) {
        self.input = input
        self.concurrency = concurrency
    }
}

public enum OutputDestination: Equatable, Sendable {
    case stdout
    case file(URL)
}

public enum OutputFormat: Equatable, Sendable {
    case plain
    case markdown
}

public struct CookieDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let expires: Date?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        secure: Bool = false,
        httpOnly: Bool = false,
        expires: Date? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
    }

    public func makeHTTPCookie() throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]

        if secure {
            properties[.secure] = "TRUE"
        }

        if httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        if let expires {
            properties[.expires] = expires
        }

        guard let cookie = HTTPCookie(properties: properties) else {
            throw ScraperError.invalidCookieSpec(
                "HTTPCookie を生成できませんでした: name=\(name), domain=\(domain), path=\(path)"
            )
        }

        return cookie
    }
}

public struct ScraperConfiguration: Equatable, Sendable {
    public let url: URL
    public let cookies: [CookieDefinition]
    public let dataStoreMode: DataStoreMode
    public let visibility: VisibilityMode
    public let viewport: Viewport
    public let wait: WaitConfiguration
    public let timeouts: Timeouts
    public let batch: BatchMode?
    public let output: OutputDestination
    public let outputFormat: OutputFormat
    public let extraction: ExtractionMode
    public let prettyPrint: Bool
    public let verbose: Bool

    public init(
        url: URL,
        cookies: [CookieDefinition],
        dataStoreMode: DataStoreMode,
        visibility: VisibilityMode,
        viewport: Viewport,
        wait: WaitConfiguration,
        timeouts: Timeouts,
        batch: BatchMode? = nil,
        output: OutputDestination,
        outputFormat: OutputFormat = .plain,
        extraction: ExtractionMode,
        prettyPrint: Bool,
        verbose: Bool
    ) {
        self.url = url
        self.cookies = cookies
        self.dataStoreMode = dataStoreMode
        self.visibility = visibility
        self.viewport = viewport
        self.wait = wait
        self.timeouts = timeouts
        self.batch = batch
        self.output = output
        self.outputFormat = outputFormat
        self.extraction = extraction
        self.prettyPrint = prettyPrint
        self.verbose = verbose
    }
}

extension ScraperConfiguration {
    func replacing(url: URL, batch: BatchMode?) -> ScraperConfiguration {
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
    }
}

public enum CLICommand: Equatable {
    case help(String)
    case run(ScraperConfiguration)
}

public enum ScraperError: LocalizedError, Equatable, Sendable {
    case usage(String)
    case invalidArgument(String)
    case unknownOption(String)
    case invalidURL(String)
    case missingOptionValue(String)
    case invalidCookieSpec(String)
    case invalidCookieFile(String)
    case loadFailed(String)
    case timedOut(phase: String, timeout: TimeInterval)
    case javaScriptFailed(String)
    case unexpectedJavaScriptResult(phase: String, expected: String)
    case extractionFailed(String)
    case sitemapFetchFailed(String)
    case sitemapParseFailed(String)
    case urlFileFailed(String)
    case markdownFailed(String)
    case prettyPrintFailed(String)
    case outputFailed(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .invalidArgument(let message):
            return message
        case .unknownOption(let option):
            return "未知のオプションです: \(option)"
        case .invalidURL(let raw):
            return "URL として解釈できません: \(raw)"
        case .missingOptionValue(let option):
            return "オプションの値が不足しています: \(option)"
        case .invalidCookieSpec(let message):
            return "Cookie 指定が不正です: \(message)"
        case .invalidCookieFile(let message):
            return "Cookie ファイルを読み込めません: \(message)"
        case .loadFailed(let message):
            return "ページロードに失敗しました: \(message)"
        case .timedOut(let phase, let timeout):
            return "\(phase) が \(timeout)s でタイムアウトしました"
        case .javaScriptFailed(let message):
            return "JavaScript 実行に失敗しました: \(message)"
        case .unexpectedJavaScriptResult(let phase, let expected):
            return "\(phase) の戻り値が想定外です。期待型: \(expected)"
        case .extractionFailed(let message):
            return "抽出に失敗しました: \(message)"
        case .sitemapFetchFailed(let message):
            return "sitemap を取得できません: \(message)"
        case .sitemapParseFailed(let message):
            return "sitemap を解釈できません: \(message)"
        case .urlFileFailed(let message):
            return "URL リストファイルを読み込めません: \(message)"
        case .markdownFailed(let message):
            return "Markdown 変換に失敗しました: \(message)"
        case .prettyPrintFailed(let message):
            return "整形に失敗しました: \(message)"
        case .outputFailed(let message):
            return "出力に失敗しました: \(message)"
        }
    }
}
