import AppKit
import Foundation

private struct LaunchResult {
    let output: String
    let exitCode: Int32
}

private struct BatchPageWorkResult {
    let page: BatchRunResult.Page
    let pdfPage: PDFDownloadBatchRunResult.Page?
}

private struct ResolvedBatchSource {
    let kind: String
    let location: String
    let pageURLs: [URL]
}

public struct StderrLogger: Sendable {
    public let verbose: Bool

    public init(verbose: Bool) {
        self.verbose = verbose
    }

    public func info(_ message: String, force: Bool = false) {
        guard verbose || force else {
            return
        }

        write("info: \(message)")
    }

    public func error(_ message: String) {
        write("error: \(message)")
    }

    public func raw(_ message: String) {
        write(message)
    }

    private func write(_ message: String) {
        var line = message
        if !line.hasSuffix("\n") {
            line.append("\n")
        }

        FileHandle.standardError.write(Data(line.utf8))
    }
}

@MainActor
public final class ScraperLauncher {
    private let configuration: ScraperConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?

    public init(configuration: ScraperConfiguration) {
        self.configuration = configuration
        self.logger = StderrLogger(verbose: configuration.verbose)
    }

    public func run() -> Int32 {
        logger.info("Initializing the launcher")
        logger.info("Creating NSApplication")
        let application = NSApplication.shared
        logger.info("Setting ActivationPolicy: \(configuration.visibility.activationPolicy.rawValue)")
        _ = application.setActivationPolicy(configuration.visibility.activationPolicy)
        logger.info("Calling NSApplication.finishLaunching")
        application.finishLaunching()
        logger.info("NSApplication.finishLaunching returned")
        runLoop = CFRunLoopGetCurrent()
        logger.info("Submitting the scraper task to the run loop")

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                logger.info("Starting the scraper task on the run loop")

                Task { @MainActor in
                    do {
                        let result = try await self.makeLaunchResult()
                        try self.write(result.output)
                        self.exitCode = result.exitCode
                    } catch {
                        self.exitCode = 1
                        self.logger.error(error.localizedDescription)
                    }

                    self.stopApplicationLoop()
                }
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            Task { @MainActor in
                do {
                    let result = try await self.makeLaunchResult()
                    try self.write(result.output)
                    self.exitCode = result.exitCode
                } catch {
                    self.exitCode = 1
                    self.logger.error(error.localizedDescription)
                }

                self.stopApplicationLoop()
            }
        }

        logger.info("Entering CFRunLoopRun")
        CFRunLoopRun()
        logger.info("Exited CFRunLoopRun")
        return exitCode
    }

    private func makeLaunchResult() async throws -> LaunchResult {
        if let batch = configuration.batch {
            return try await makeBatchLaunchResult(batch)
        }

        return try await makeSinglePageLaunchResult(configuration: configuration)
    }

    private func makeSinglePageLaunchResult(configuration: ScraperConfiguration) async throws -> LaunchResult {
        let scraper = WebScraper(configuration: configuration, logger: logger)
        let scrapeResult: WebScraperRunResult
        if configuration.linkedPDFDownloadDirectory != nil {
            scrapeResult = try await scraper.runWithPDFLinks()
        } else {
            scrapeResult = WebScraperRunResult(output: try await scraper.run(), pdfLinks: nil)
        }

        let formattedOutput = try OutputFormatter.format(
            scrapeResult.output,
            sourceURL: configuration.url,
            extraction: configuration.extraction,
            outputFormat: configuration.outputFormat,
            prettyPrint: configuration.prettyPrint
        )

        let pdfExitCode = try await saveLinkedPDFManifestIfNeeded(
            sourceKind: "single",
            sourceLocation: configuration.url.absoluteString,
            sourceURL: configuration.url,
            pdfLinks: scrapeResult.pdfLinks,
            configuration: configuration
        )

        return LaunchResult(output: formattedOutput, exitCode: pdfExitCode)
    }

    private func makeBatchLaunchResult(_ batchMode: BatchMode) async throws -> LaunchResult {
        let resolved = try await resolveBatchSource(batchMode)
        logger.info("Resolved \(resolved.pageURLs.count) URLs from \(resolved.kind)")

        let concurrency = min(batchMode.concurrency, max(resolved.pageURLs.count, 1))
        let limiter = AsyncSemaphore(limit: concurrency)
        let baseConfiguration = configuration
        let logger = self.logger

        let workResults = await withTaskGroup(
            of: (Int, BatchPageWorkResult).self,
            returning: [BatchPageWorkResult].self
        ) { group in
            for (index, url) in resolved.pageURLs.enumerated() {
                group.addTask {
                    let result = await limiter.withPermit {
                        await ScraperLauncher.scrapeBatchPage(
                            url: url,
                            baseConfiguration: baseConfiguration,
                            logger: logger
                        )
                    }
                    return (index, result)
                }
            }

            var indexedResults: [(Int, BatchPageWorkResult)] = []
            for await indexedResult in group {
                indexedResults.append(indexedResult)
            }

            return indexedResults
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        let pages = workResults.map(\.page)
        let batchResult = BatchRunResult(sourceKind: resolved.kind, sourceLocation: resolved.location, pages: pages)
        let pdfExitCode = try saveLinkedPDFBatchManifestIfNeeded(
            sourceKind: resolved.kind,
            sourceLocation: resolved.location,
            pdfPages: workResults.compactMap(\.pdfPage)
        )
        let output = try BatchRunFormatter.format(batchResult)
        let exitCode: Int32 = batchResult.failureCount > 0 || pdfExitCode != 0 ? 1 : 0
        return LaunchResult(output: output, exitCode: exitCode)
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

    private static func scrapeBatchPage(
        url: URL,
        baseConfiguration: ScraperConfiguration,
        logger: StderrLogger
    ) async -> BatchPageWorkResult {
        let pageConfiguration = baseConfiguration.replacing(url: url, batch: nil)
        logger.info("batch page start: \(url.absoluteString)")

        do {
            let scraper = WebScraper(configuration: pageConfiguration, logger: logger)
            let scrapeResult: WebScraperRunResult
            if pageConfiguration.linkedPDFDownloadDirectory != nil {
                scrapeResult = try await scraper.runWithPDFLinks()
            } else {
                scrapeResult = WebScraperRunResult(output: try await scraper.run(), pdfLinks: nil)
            }

            let formattedOutput = try OutputFormatter.format(
                scrapeResult.output,
                sourceURL: pageConfiguration.url,
                extraction: pageConfiguration.extraction,
                outputFormat: pageConfiguration.outputFormat,
                prettyPrint: pageConfiguration.prettyPrint
            )
            let pdfPage = await saveLinkedPDFsIfNeeded(
                sourceURL: pageConfiguration.url,
                pdfLinks: scrapeResult.pdfLinks,
                configuration: pageConfiguration,
                logger: logger
            )
            logger.info("batch page done: \(url.absoluteString)")
            return BatchPageWorkResult(page: .succeeded(url: url, output: formattedOutput), pdfPage: pdfPage)
        } catch {
            logger.info("batch page failed: \(url.absoluteString): \(error.localizedDescription)")
            let pdfPage: PDFDownloadBatchRunResult.Page?
            if pageConfiguration.linkedPDFDownloadDirectory != nil {
                pdfPage = .failed(url: url, error: error.localizedDescription)
            } else {
                pdfPage = nil
            }
            return BatchPageWorkResult(page: .failed(url: url, error: error.localizedDescription), pdfPage: pdfPage)
        }
    }

    private func saveLinkedPDFManifestIfNeeded(
        sourceKind: String,
        sourceLocation: String,
        sourceURL: URL,
        pdfLinks: PDFLinkCollection?,
        configuration: ScraperConfiguration
    ) async throws -> Int32 {
        guard configuration.linkedPDFDownloadDirectory != nil else {
            return 0
        }

        let pdfPage = await Self.saveLinkedPDFsIfNeeded(
            sourceURL: sourceURL,
            pdfLinks: pdfLinks,
            configuration: configuration,
            logger: logger
        ) ?? .failed(url: sourceURL, error: "No PDF link collection result")

        let result = PDFDownloadBatchRunResult(
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            outputDirectory: configuration.linkedPDFDownloadDirectory!,
            pages: [pdfPage]
        )
        try writeLinkedPDFManifest(result, to: configuration.linkedPDFDownloadDirectory!)
        return result.hasFailures ? 1 : 0
    }

    private func saveLinkedPDFBatchManifestIfNeeded(
        sourceKind: String,
        sourceLocation: String,
        pdfPages: [PDFDownloadBatchRunResult.Page]
    ) throws -> Int32 {
        guard let outputDirectory = configuration.linkedPDFDownloadDirectory else {
            return 0
        }

        let result = PDFDownloadBatchRunResult(
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            outputDirectory: outputDirectory,
            pages: pdfPages
        )
        try writeLinkedPDFManifest(result, to: outputDirectory)
        return result.hasFailures ? 1 : 0
    }

    private static func saveLinkedPDFsIfNeeded(
        sourceURL: URL,
        pdfLinks: PDFLinkCollection?,
        configuration: ScraperConfiguration,
        logger: StderrLogger
    ) async -> PDFDownloadBatchRunResult.Page? {
        guard let outputDirectory = configuration.linkedPDFDownloadDirectory else {
            return nil
        }

        guard let pdfLinks else {
            return .failed(url: sourceURL, error: "No PDF link collection result")
        }

        do {
            let saver = PDFDownloadSaver(
                outputDirectory: outputDirectory,
                timeout: configuration.timeouts.load,
                customHeaders: configuration.customHeaders,
                overwriteExistingFiles: configuration.overwritePDFs,
                maximumSizeMegabytes: configuration.maxPDFSizeMegabytes,
                logger: logger
            )
            let result = try await saver.save(pdfLinks)
            return .succeeded(result)
        } catch {
            return .failed(url: sourceURL, error: error.localizedDescription)
        }
    }

    private func writeLinkedPDFManifest(_ result: PDFDownloadBatchRunResult, to outputDirectory: URL) throws {
        let manifestURL = outputDirectory.appendingPathComponent("pdf-downloads.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let json = try PDFDownloadFormatter.format(result)
            try json.write(to: manifestURL, atomically: true, encoding: .utf8)
            logger.info("Saved the PDF download result: \(manifestURL.path)")
        } catch let error as ScraperError {
            throw error
        } catch {
            throw ScraperError.outputFailed("\(manifestURL.path): \(error.localizedDescription)")
        }
    }

    private func write(_ output: String) throws {
        switch configuration.output {
        case .stdout:
            var finalOutput = output
            if !finalOutput.hasSuffix("\n") {
                finalOutput.append("\n")
            }

            FileHandle.standardOutput.write(Data(finalOutput.utf8))
        case .file(let fileURL):
            do {
                let directoryURL = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try output.write(to: fileURL, atomically: true, encoding: .utf8)
                logger.info("Saved the extraction result: \(fileURL.path)")
            } catch {
                throw ScraperError.outputFailed("\(fileURL.path): \(error.localizedDescription)")
            }
        }
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
