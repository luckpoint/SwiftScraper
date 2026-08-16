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
    /// `true` is used for browser cookies restricted to the exact host.
    /// `nil` preserves the legacy explicit-cookie domain semantics.
    public let hostOnly: Bool?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        secure: Bool = false,
        httpOnly: Bool = false,
        expires: Date? = nil,
        hostOnly: Bool? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
        self.hostOnly = hostOnly
    }

    public init(cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly,
            expires: cookie.expiresDate
        )
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
    public let cookieJar: URL?
    public let customHeaders: [String: String]
    public let dataStoreMode: DataStoreMode
    public let visibility: VisibilityMode
    public let viewport: Viewport
    public let wait: WaitConfiguration
    public let timeouts: Timeouts
    public let batch: BatchMode?
    public let output: OutputDestination
    public let outputFormat: OutputFormat
    public let extraction: ExtractionMode
    public let imageExtraction: ImageExtractionConfiguration
    public let linkedPDFDownloadDirectory: URL?
    public let prettyPrint: Bool
    public let verbose: Bool

    public init(
        url: URL,
        cookies: [CookieDefinition],
        cookieJar: URL? = nil,
        customHeaders: [String: String] = [:],
        dataStoreMode: DataStoreMode,
        visibility: VisibilityMode,
        viewport: Viewport,
        wait: WaitConfiguration,
        timeouts: Timeouts,
        batch: BatchMode? = nil,
        output: OutputDestination,
        outputFormat: OutputFormat = .plain,
        extraction: ExtractionMode,
        imageExtraction: ImageExtractionConfiguration = .disabled,
        linkedPDFDownloadDirectory: URL? = nil,
        prettyPrint: Bool,
        verbose: Bool
    ) {
        self.url = url
        self.cookies = cookies
        self.cookieJar = cookieJar
        self.customHeaders = customHeaders
        self.dataStoreMode = dataStoreMode
        self.visibility = visibility
        self.viewport = viewport
        self.wait = wait
        self.timeouts = timeouts
        self.batch = batch
        self.output = output
        self.outputFormat = outputFormat
        self.extraction = extraction
        self.imageExtraction = imageExtraction
        self.linkedPDFDownloadDirectory = linkedPDFDownloadDirectory
        self.prettyPrint = prettyPrint
        self.verbose = verbose
    }
}

extension ScraperConfiguration {
    func replacing(url: URL, batch: BatchMode?) -> ScraperConfiguration {
        ScraperConfiguration(
            url: url,
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
    }
}

public struct PDFConfiguration: Equatable, Sendable {
    public let inputFile: URL
    public let outputFile: URL
    public let verbose: Bool

    public init(inputFile: URL, outputFile: URL, verbose: Bool) {
        self.inputFile = inputFile
        self.outputFile = outputFile
        self.verbose = verbose
    }
}

public struct PDFDownloadConfiguration: Equatable, Sendable {
    public let url: URL
    public let outputDirectory: URL
    public let cookies: [CookieDefinition]
    public let cookieJar: URL?
    public let customHeaders: [String: String]
    public let dataStoreMode: DataStoreMode
    public let visibility: VisibilityMode
    public let viewport: Viewport
    public let wait: WaitConfiguration
    public let timeouts: Timeouts
    public let batch: BatchMode?
    public let verbose: Bool

    public init(
        url: URL,
        outputDirectory: URL,
        cookies: [CookieDefinition],
        cookieJar: URL? = nil,
        customHeaders: [String: String] = [:],
        dataStoreMode: DataStoreMode,
        visibility: VisibilityMode,
        viewport: Viewport,
        wait: WaitConfiguration,
        timeouts: Timeouts,
        batch: BatchMode? = nil,
        verbose: Bool
    ) {
        self.url = url
        self.outputDirectory = outputDirectory
        self.cookies = cookies
        self.cookieJar = cookieJar
        self.customHeaders = customHeaders
        self.dataStoreMode = dataStoreMode
        self.visibility = visibility
        self.viewport = viewport
        self.wait = wait
        self.timeouts = timeouts
        self.batch = batch
        self.verbose = verbose
    }
}

public struct BiDiServerConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let initialURL: URL?
    public let cookies: [CookieDefinition]
    public let customHeaders: [String: String]
    public let dataStoreMode: DataStoreMode
    public let visibility: VisibilityMode
    public let viewport: Viewport
    public let timeouts: Timeouts
    public let verbose: Bool

    public init(
        host: String,
        port: Int,
        initialURL: URL?,
        cookies: [CookieDefinition],
        customHeaders: [String: String],
        dataStoreMode: DataStoreMode,
        visibility: VisibilityMode,
        viewport: Viewport,
        timeouts: Timeouts,
        verbose: Bool
    ) {
        self.host = host
        self.port = port
        self.initialURL = initialURL
        self.cookies = cookies
        self.customHeaders = customHeaders
        self.dataStoreMode = dataStoreMode
        self.visibility = visibility
        self.viewport = viewport
        self.timeouts = timeouts
        self.verbose = verbose
    }
}

public enum CLICommand: Equatable {
    case help(String)
    case run(ScraperConfiguration)
    case pdf(PDFConfiguration)
    case downloadPDFs(PDFDownloadConfiguration)
    case bidiServer(BiDiServerConfiguration)
}

public enum ScraperError: LocalizedError, Equatable, Sendable {
    case usage(String)
    case invalidArgument(String)
    case unknownOption(String)
    case invalidURL(String)
    case missingOptionValue(String)
    case invalidCookieSpec(String)
    case invalidCookieFile(String)
    case browserCookieFailed(String)
    case cookieJarFailed(String)
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
    case pdfInputNotFound(String)
    case pdfRenderFailed(String)
    case pdfDownloadFailed(String)

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
        case .browserCookieFailed(let message):
            return "ブラウザ Cookie を読み込めません: \(message)"
        case .cookieJarFailed(let message):
            return "CookieJar を扱えません: \(message)"
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
        case .pdfInputNotFound(let message):
            return "入力ファイルが見つかりません: \(message)"
        case .pdfRenderFailed(let message):
            return "PDF 生成に失敗しました: \(message)"
        case .pdfDownloadFailed(let message):
            return "PDF ダウンロードに失敗しました: \(message)"
        }
    }
}
