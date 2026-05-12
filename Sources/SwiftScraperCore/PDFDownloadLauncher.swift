import AppKit
import Foundation

public struct PDFLinkCandidate: Codable, Equatable, Sendable {
    public let url: URL
    public let text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

public struct PDFLinkCollection: Equatable, Sendable {
    public let sourceURL: URL
    public let links: [PDFLinkCandidate]
    public let userAgent: String?
    public let cookies: [CookieDefinition]

    public init(sourceURL: URL, links: [PDFLinkCandidate], userAgent: String?, cookies: [CookieDefinition]) {
        self.sourceURL = sourceURL
        self.links = links
        self.userAgent = userAgent
        self.cookies = cookies
    }
}

struct PDFDownloadRunResult: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let url: String
        let directory: String
    }

    struct File: Codable, Equatable, Sendable {
        let pdfURL: String
        let linkText: String
        let originalFilename: String
        let outputPath: String?
        let success: Bool
        let error: String?

        static func succeeded(
            link: PDFLinkCandidate,
            originalFilename: String,
            outputURL: URL
        ) -> Self {
            Self(
                pdfURL: link.url.absoluteString,
                linkText: link.text,
                originalFilename: originalFilename,
                outputPath: outputURL.path,
                success: true,
                error: nil
            )
        }

        static func failed(
            link: PDFLinkCandidate,
            originalFilename: String,
            outputURL: URL,
            error: String
        ) -> Self {
            Self(
                pdfURL: link.url.absoluteString,
                linkText: link.text,
                originalFilename: originalFilename,
                outputPath: outputURL.path,
                success: false,
                error: error
            )
        }
    }

    let source: Source
    let outputDirectory: String
    let pdfCount: Int
    let successCount: Int
    let failureCount: Int
    let files: [File]

    init(sourceURL: URL, sourceDirectory: URL, outputDirectory: URL, files: [File]) {
        self.source = Source(url: sourceURL.absoluteString, directory: sourceDirectory.path)
        self.outputDirectory = outputDirectory.path
        self.pdfCount = files.count
        self.successCount = files.filter(\.success).count
        self.failureCount = files.count - self.successCount
        self.files = files
    }
}

enum PDFDownloadFormatter {
    static func format(_ result: PDFDownloadRunResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            let data = try encoder.encode(result)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ScraperError.outputFailed("PDF ダウンロード JSON を生成できません: \(error.localizedDescription)")
        }
    }
}

enum PDFDownloadFileNaming {
    static func sourceDirectory(for sourceURL: URL, under outputDirectory: URL) -> URL {
        let sourceName = sanitizePathComponent(sourceURL.host ?? sourceURL.scheme ?? "source")
        var directory = outputDirectory.appendingPathComponent(sourceName, isDirectory: true)

        for component in sourceURL.pathComponents where component != "/" {
            directory.appendPathComponent(sanitizePathComponent(component), isDirectory: true)
        }

        return directory
    }

    static func originalFilename(from url: URL) -> String {
        let decoded = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let sanitized = sanitizeFileName(decoded, fallback: "document.pdf")
        if sanitized.lowercased().hasSuffix(".pdf") {
            return sanitized
        }

        return "\(sanitized).pdf"
    }

    static func suggestedFileName(linkText: String, originalFilename: String) -> String {
        let prefix = linkTextPrefix(linkText)
        guard !prefix.isEmpty else {
            return originalFilename
        }

        return sanitizeFileName("\(prefix)-\(originalFilename)", fallback: originalFilename)
    }

    static func uniqueFileURL(
        suggestedFileName: String,
        in directory: URL,
        usedFileNames: inout Set<String>
    ) -> URL {
        let sanitized = sanitizeFileName(suggestedFileName, fallback: "document.pdf")
        let suggestedURL = directory.appendingPathComponent(sanitized, isDirectory: false)
        let extensionName = suggestedURL.pathExtension
        let stem = suggestedURL.deletingPathExtension().lastPathComponent

        var candidateName = sanitized
        var counter = 2
        while usedFileNames.contains(candidateName.lowercased())
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidateName).path) {
            if extensionName.isEmpty {
                candidateName = "\(stem)-\(counter)"
            } else {
                candidateName = "\(stem)-\(counter).\(extensionName)"
            }
            counter += 1
        }

        usedFileNames.insert(candidateName.lowercased())
        return directory.appendingPathComponent(candidateName, isDirectory: false)
    }

    static func linkTextPrefix(_ linkText: String) -> String {
        let normalized = normalizeWhitespace(linkText)
        let truncated = String(normalized.prefix(30))
        return sanitizeFileName(truncated, fallback: "")
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        sanitizeFileName(value, fallback: "_")
    }

    private static func sanitizeFileName(_ value: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        var scalars = String.UnicodeScalarView()

        for scalar in normalizeWhitespace(value).unicodeScalars {
            if invalidCharacters.contains(scalar) {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }

        let sanitized = String(scalars)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum PDFDownloadRequestBuilder {
    static func makeRequest(
        url: URL,
        timeout: TimeInterval,
        customHeaders: [String: String],
        cookies: [CookieDefinition],
        userAgent: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        for (name, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if request.value(forHTTPHeaderField: "User-Agent") == nil,
           let userAgent = sanitizedUserAgent(userAgent) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let cookieHeader = cookieHeader(for: url, cookies: cookies) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        return request
    }

    private static func sanitizedUserAgent(_ userAgent: String?) -> String? {
        guard let userAgent else {
            return nil
        }

        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cookieHeader(for url: URL, cookies: [CookieDefinition]) -> String? {
        let matchingCookies = cookies.filter { cookieMatches($0, url: url) }
        guard !matchingCookies.isEmpty else {
            return nil
        }

        return matchingCookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookieMatches(_ cookie: CookieDefinition, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        if let expires = cookie.expires, expires <= Date() {
            return false
        }

        if cookie.secure && url.scheme?.lowercased() != "https" {
            return false
        }

        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix(".\(domain)") else {
            return false
        }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return requestPath.hasPrefix(cookiePath)
    }
}

@MainActor
public final class PDFDownloadLauncher {
    private let configuration: PDFDownloadConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?

    public init(configuration: PDFDownloadConfiguration) {
        self.configuration = configuration
        self.logger = StderrLogger(verbose: configuration.verbose)
    }

    public func run() -> Int32 {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(configuration.visibility.activationPolicy)
        application.finishLaunching()
        runLoop = CFRunLoopGetCurrent()

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                Task { @MainActor in
                    await self.execute()
                    self.stopApplicationLoop()
                }
            }
            CFRunLoopWakeUp(runLoop)
        }

        CFRunLoopRun()
        return exitCode
    }

    private func execute() async {
        do {
            let result = try await makeRunResult()
            let output = try PDFDownloadFormatter.format(result)
            write(output, to: FileHandle.standardOutput)
            exitCode = result.failureCount > 0 ? 1 : 0
        } catch {
            exitCode = 1
            logger.error(error.localizedDescription)
        }
    }

    private func makeRunResult() async throws -> PDFDownloadRunResult {
        let scraper = WebScraper(configuration: scraperConfiguration(), logger: logger)
        let collection = try await scraper.collectPDFLinks()
        let sourceDirectory = PDFDownloadFileNaming.sourceDirectory(
            for: collection.sourceURL,
            under: configuration.outputDirectory
        )

        do {
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw ScraperError.pdfDownloadFailed("\(sourceDirectory.path): \(error.localizedDescription)")
        }

        logger.info("PDF 保存先: \(sourceDirectory.path)")

        var usedFileNames: Set<String> = []
        var files: [PDFDownloadRunResult.File] = []

        for link in collection.links {
            let originalFilename = PDFDownloadFileNaming.originalFilename(from: link.url)
            let suggestedName = PDFDownloadFileNaming.suggestedFileName(
                linkText: link.text,
                originalFilename: originalFilename
            )
            let outputURL = PDFDownloadFileNaming.uniqueFileURL(
                suggestedFileName: suggestedName,
                in: sourceDirectory,
                usedFileNames: &usedFileNames
            )

            do {
                try await download(
                    link.url,
                    to: outputURL,
                    cookies: collection.cookies,
                    userAgent: collection.userAgent
                )
                logger.info("PDF 保存完了: \(outputURL.path)")
                files.append(.succeeded(link: link, originalFilename: originalFilename, outputURL: outputURL))
            } catch {
                logger.error("\(link.url.absoluteString): \(error.localizedDescription)")
                files.append(
                    .failed(
                        link: link,
                        originalFilename: originalFilename,
                        outputURL: outputURL,
                        error: error.localizedDescription
                    )
                )
            }
        }

        return PDFDownloadRunResult(
            sourceURL: collection.sourceURL,
            sourceDirectory: sourceDirectory,
            outputDirectory: configuration.outputDirectory,
            files: files
        )
    }

    private func scraperConfiguration() -> ScraperConfiguration {
        ScraperConfiguration(
            url: configuration.url,
            cookies: configuration.cookies,
            cookieJar: configuration.cookieJar,
            customHeaders: configuration.customHeaders,
            dataStoreMode: configuration.dataStoreMode,
            visibility: configuration.visibility,
            viewport: configuration.viewport,
            wait: configuration.wait,
            timeouts: configuration.timeouts,
            batch: nil,
            output: .stdout,
            outputFormat: .plain,
            extraction: .outerHTML,
            imageExtraction: .disabled,
            prettyPrint: false,
            verbose: configuration.verbose
        )
    }

    private func download(
        _ url: URL,
        to outputURL: URL,
        cookies: [CookieDefinition],
        userAgent: String?
    ) async throws {
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: outputURL)
            return
        }

        let request = PDFDownloadRequestBuilder.makeRequest(
            url: url,
            timeout: configuration.timeouts.load,
            customHeaders: configuration.customHeaders,
            cookies: cookies,
            userAgent: userAgent
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ScraperError.pdfDownloadFailed(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ScraperError.pdfDownloadFailed("HTTP \(httpResponse.statusCode)")
        }

        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw ScraperError.pdfDownloadFailed("\(outputURL.path): \(error.localizedDescription)")
        }
    }

    private func write(_ text: String, to handle: FileHandle) {
        var output = text
        if !output.hasSuffix("\n") {
            output.append("\n")
        }

        handle.write(Data(output.utf8))
    }

    private func stopApplicationLoop() {
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }
}

private extension VisibilityMode {
    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .windowless:
            return .accessory
        case .hiddenWindow:
            return .accessory
        case .visibleWindow:
            return .regular
        }
    }
}
