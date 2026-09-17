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

struct PDFDownloadBatchRunResult: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let kind: String
        let location: String
    }

    struct Page: Codable, Equatable, Sendable {
        let url: String
        let sourceDirectory: String?
        let success: Bool
        let pdfCount: Int
        let successCount: Int
        let failureCount: Int
        let files: [PDFDownloadRunResult.File]
        let error: String?

        static func succeeded(_ result: PDFDownloadRunResult) -> Self {
            Self(
                url: result.source.url,
                sourceDirectory: result.source.directory,
                success: result.failureCount == 0,
                pdfCount: result.pdfCount,
                successCount: result.successCount,
                failureCount: result.failureCount,
                files: result.files,
                error: nil
            )
        }

        static func failed(url: URL, error: String) -> Self {
            Self(
                url: url.absoluteString,
                sourceDirectory: nil,
                success: false,
                pdfCount: 0,
                successCount: 0,
                failureCount: 0,
                files: [],
                error: error
            )
        }
    }

    let source: Source
    let outputDirectory: String
    let pageCount: Int
    let pageSuccessCount: Int
    let pageFailureCount: Int
    let pdfCount: Int
    let successCount: Int
    let failureCount: Int
    let pages: [Page]

    init(sourceKind: String, sourceLocation: String, outputDirectory: URL, pages: [Page]) {
        self.source = Source(kind: sourceKind, location: sourceLocation)
        self.outputDirectory = outputDirectory.path
        self.pageCount = pages.count
        self.pageSuccessCount = pages.filter(\.success).count
        self.pageFailureCount = pages.count - self.pageSuccessCount
        self.pdfCount = pages.reduce(0) { $0 + $1.pdfCount }
        self.successCount = pages.reduce(0) { $0 + $1.successCount }
        self.failureCount = pages.reduce(0) { $0 + $1.failureCount }
        self.pages = pages
    }

    var hasFailures: Bool {
        pageFailureCount > 0 || failureCount > 0
    }
}

enum PDFDownloadFormatter {
    static func format(_ result: PDFDownloadRunResult) throws -> String {
        try encode(result)
    }

    static func format(_ result: PDFDownloadBatchRunResult) throws -> String {
        try encode(result)
    }

    private static func encode(_ result: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            let data = try encoder.encode(result)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ScraperError.outputFailed("Unable to generate the PDF download JSON: \(error.localizedDescription)")
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
        usedFileNames: inout Set<String>,
        overwriteExisting: Bool = false
    ) -> URL {
        let sanitized = sanitizeFileName(suggestedFileName, fallback: "document.pdf")
        let suggestedURL = directory.appendingPathComponent(sanitized, isDirectory: false)
        let extensionName = suggestedURL.pathExtension
        let stem = suggestedURL.deletingPathExtension().lastPathComponent

        var candidateName = sanitized
        var counter = 2
        while usedFileNames.contains(candidateName.lowercased())
            || (!overwriteExisting
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidateName).path)) {
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
        let matchingCookies = cookies.filter { $0.matches(url: url) }
        guard !matchingCookies.isEmpty else {
            return nil
        }

        return matchingCookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

}

public enum PDFDownloadResponseGuard {
    public static let defaultMaximumMegabytes = 100

    static let bytesPerMegabyte = 1_048_576
    static let maximumMegabytesLimit = 4096

    private static let header = Array("%PDF-".utf8)

    enum Failure: Equatable {
        case notPDF
        case tooLarge(byteCount: Int, maximumBytes: Int)

        var message: String {
            switch self {
            case .notPDF:
                return "Response is not a PDF (missing %PDF- header)"
            case .tooLarge(let byteCount, let maximumBytes):
                return "Response is \(byteCount) bytes, above the \(maximumBytes) byte limit (--max-pdf-size)"
            }
        }
    }

    static func maximumBytes(forMegabytes megabytes: Int) -> Int {
        megabytes * bytesPerMegabyte
    }

    static func failure(for data: Data, maximumBytes: Int) -> Failure? {
        guard data.starts(with: header) else {
            return .notPDF
        }

        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count, maximumBytes: maximumBytes)
        }

        return nil
    }
}

struct PDFDownloadSaver {
    let outputDirectory: URL
    let timeout: TimeInterval
    let customHeaders: [String: String]
    let overwriteExistingFiles: Bool
    let maximumSizeMegabytes: Int
    let logger: StderrLogger

    func save(_ collection: PDFLinkCollection) async throws -> PDFDownloadRunResult {
        let sourceDirectory = PDFDownloadFileNaming.sourceDirectory(
            for: collection.sourceURL,
            under: outputDirectory
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

        logger.info("PDF output directory: \(sourceDirectory.path)")

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
                usedFileNames: &usedFileNames,
                overwriteExisting: overwriteExistingFiles
            )

            do {
                try await download(
                    link.url,
                    to: outputURL,
                    cookies: collection.cookies,
                    userAgent: collection.userAgent
                )
                logger.info("PDF saved: \(outputURL.path)")
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
            outputDirectory: outputDirectory,
            files: files
        )
    }

    private func download(
        _ url: URL,
        to outputURL: URL,
        cookies: [CookieDefinition],
        userAgent: String?
    ) async throws {
        if url.isFileURL {
            try copyLocalFile(url, to: outputURL)
            return
        }

        let request = PDFDownloadRequestBuilder.makeRequest(
            url: url,
            timeout: timeout,
            customHeaders: customHeaders,
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

        if let failure = PDFDownloadResponseGuard.failure(
            for: data,
            maximumBytes: PDFDownloadResponseGuard.maximumBytes(forMegabytes: maximumSizeMegabytes)
        ) {
            throw ScraperError.pdfDownloadFailed(failure.message)
        }

        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw ScraperError.pdfDownloadFailed("\(outputURL.path): \(error.localizedDescription)")
        }
    }

    private func copyLocalFile(_ url: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default

        guard overwriteExistingFiles, fileManager.fileExists(atPath: outputURL.path) else {
            do {
                try fileManager.copyItem(at: url, to: outputURL)
            } catch {
                throw ScraperError.pdfDownloadFailed("\(outputURL.path): \(error.localizedDescription)")
            }
            return
        }

        let temporaryURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(outputURL.lastPathComponent)", isDirectory: false)

        do {
            try fileManager.copyItem(at: url, to: temporaryURL)
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ScraperError.pdfDownloadFailed("\(outputURL.path): \(error.localizedDescription)")
        }
    }
}

@MainActor
public final class PDFDownloadLauncher {
    private let configuration: PDFDownloadConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?

    private struct LaunchResult {
        let output: String
        let exitCode: Int32
    }

    private struct ResolvedBatchSource {
        let kind: String
        let location: String
        let pageURLs: [URL]
    }

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
            let result = try await makeLaunchResult()
            write(result.output, to: FileHandle.standardOutput)
            exitCode = result.exitCode
        } catch {
            exitCode = 1
            logger.error(error.localizedDescription)
        }
    }

    private func makeLaunchResult() async throws -> LaunchResult {
        if let batch = configuration.batch {
            let result = try await makeBatchRunResult(batch)
            return LaunchResult(
                output: try PDFDownloadFormatter.format(result),
                exitCode: result.hasFailures ? 1 : 0
            )
        }

        let result = try await makeSingleRunResult(url: configuration.url)
        return LaunchResult(
            output: try PDFDownloadFormatter.format(result),
            exitCode: result.failureCount > 0 ? 1 : 0
        )
    }

    private func makeSingleRunResult(url: URL) async throws -> PDFDownloadRunResult {
        let scraper = WebScraper(configuration: scraperConfiguration(url: url), logger: logger)
        let collection = try await scraper.collectPDFLinks()
        return try await makeSaver().save(collection)
    }

    private func makeBatchRunResult(_ batchMode: BatchMode) async throws -> PDFDownloadBatchRunResult {
        let resolved = try await resolveBatchSource(batchMode)
        logger.info("Resolved \(resolved.pageURLs.count) URLs from \(resolved.kind)")

        let concurrency = min(batchMode.concurrency, max(resolved.pageURLs.count, 1))
        let limiter = AsyncSemaphore(limit: concurrency)
        let baseConfiguration = configuration
        let logger = self.logger

        let pages = await withTaskGroup(
            of: (Int, PDFDownloadBatchRunResult.Page).self,
            returning: [PDFDownloadBatchRunResult.Page].self
        ) { group in
            for (index, url) in resolved.pageURLs.enumerated() {
                group.addTask {
                    let page = await limiter.withPermit {
                        await PDFDownloadLauncher.downloadBatchPage(
                            url: url,
                            baseConfiguration: baseConfiguration,
                            logger: logger
                        )
                    }
                    return (index, page)
                }
            }

            var indexedPages: [(Int, PDFDownloadBatchRunResult.Page)] = []
            for await indexedPage in group {
                indexedPages.append(indexedPage)
            }

            return indexedPages
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        return PDFDownloadBatchRunResult(
            sourceKind: resolved.kind,
            sourceLocation: resolved.location,
            outputDirectory: configuration.outputDirectory,
            pages: pages
        )
    }

    private func resolveBatchSource(_ batchMode: BatchMode) async throws -> ResolvedBatchSource {
        switch batchMode.input {
        case .sitemap:
            let resolver = SitemapResolver(timeout: configuration.timeouts.load, logger: logger)
            let resolved = try await resolver.resolve(startingFrom: configuration.url)
            return ResolvedBatchSource(
                kind: "sitemap",
                location: resolved.sitemapURL.absoluteString,
                pageURLs: resolved.pageURLs
            )
        case .urlFile(let fileURL):
            let resolved = try URLFileResolver.resolve(from: fileURL)
            return ResolvedBatchSource(
                kind: "url-file",
                location: fileURL.path,
                pageURLs: resolved.pageURLs
            )
        }
    }

    private static func downloadBatchPage(
        url: URL,
        baseConfiguration: PDFDownloadConfiguration,
        logger: StderrLogger
    ) async -> PDFDownloadBatchRunResult.Page {
        logger.info("PDF batch page start: \(url.absoluteString)")

        do {
            let pageConfiguration = baseConfiguration.replacing(url: url, batch: nil)
            let scraper = WebScraper(configuration: pageConfiguration.scraperConfiguration(), logger: logger)
            let collection = try await scraper.collectPDFLinks()
            let result = try await pageConfiguration.makeSaver(logger: logger).save(collection)
            logger.info("PDF batch page done: \(url.absoluteString)")
            return .succeeded(result)
        } catch {
            logger.info("PDF batch page failed: \(url.absoluteString): \(error.localizedDescription)")
            return .failed(url: url, error: error.localizedDescription)
        }
    }

    private func scraperConfiguration(url: URL) -> ScraperConfiguration {
        configuration.replacing(url: url, batch: nil).scraperConfiguration()
    }

    private func makeSaver() -> PDFDownloadSaver {
        configuration.makeSaver(logger: logger)
    }
}

extension PDFDownloadConfiguration {
    func replacing(url: URL, batch: BatchMode?) -> PDFDownloadConfiguration {
        PDFDownloadConfiguration(
            url: url,
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
    }

    func scraperConfiguration() -> ScraperConfiguration {
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
            batch: nil,
            output: .stdout,
            outputFormat: .plain,
            extraction: .outerHTML,
            imageExtraction: .disabled,
            overwritePDFs: overwritePDFs,
            maxPDFSizeMegabytes: maxPDFSizeMegabytes,
            prettyPrint: false,
            verbose: verbose
        )
    }

    func makeSaver(logger: StderrLogger) -> PDFDownloadSaver {
        PDFDownloadSaver(
            outputDirectory: outputDirectory,
            timeout: timeouts.load,
            customHeaders: customHeaders,
            overwriteExistingFiles: overwritePDFs,
            maximumSizeMegabytes: maxPDFSizeMegabytes,
            logger: logger
        )
    }
}

private extension PDFDownloadLauncher {
    func write(_ text: String, to handle: FileHandle) {
        var output = text
        if !output.hasSuffix("\n") {
            output.append("\n")
        }

        handle.write(Data(output.utf8))
    }

    func stopApplicationLoop() {
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
