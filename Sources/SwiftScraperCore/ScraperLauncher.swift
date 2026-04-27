import AppKit
import Foundation

private struct LaunchResult {
    let output: String
    let exitCode: Int32
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
        logger.info("ランチャーを初期化します")
        logger.info("NSApplication を生成します")
        let application = NSApplication.shared
        logger.info("ActivationPolicy を設定します: \(configuration.visibility.activationPolicy.rawValue)")
        _ = application.setActivationPolicy(configuration.visibility.activationPolicy)
        logger.info("NSApplication.finishLaunching を呼びます")
        application.finishLaunching()
        logger.info("NSApplication.finishLaunching が返りました")
        runLoop = CFRunLoopGetCurrent()
        logger.info("スクレイパータスクを run loop へ投入します")

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                logger.info("run loop 上でスクレイパータスクを開始します")

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

        logger.info("CFRunLoopRun に入ります")
        CFRunLoopRun()
        logger.info("CFRunLoopRun を抜けました")
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
        let output = try await scraper.run()
        let formattedOutput = try OutputFormatter.format(
            output,
            sourceURL: configuration.url,
            extraction: configuration.extraction,
            outputFormat: configuration.outputFormat,
            prettyPrint: configuration.prettyPrint
        )
        return LaunchResult(output: formattedOutput, exitCode: 0)
    }

    private func makeBatchLaunchResult(_ batchMode: BatchMode) async throws -> LaunchResult {
        let resolved = try await resolveBatchSource(batchMode)
        logger.info("\(resolved.kind) から \(resolved.pageURLs.count) 件の URL を解決しました")

        let concurrency = min(batchMode.concurrency, max(resolved.pageURLs.count, 1))
        let limiter = AsyncSemaphore(limit: concurrency)
        let baseConfiguration = configuration
        let logger = self.logger

        let pages = await withTaskGroup(of: (Int, BatchRunResult.Page).self, returning: [BatchRunResult.Page].self) { group in
            for (index, url) in resolved.pageURLs.enumerated() {
                group.addTask {
                    let page = await limiter.withPermit {
                        await ScraperLauncher.scrapeBatchPage(
                            url: url,
                            baseConfiguration: baseConfiguration,
                            logger: logger
                        )
                    }
                    return (index, page)
                }
            }

            var indexedPages: [(Int, BatchRunResult.Page)] = []
            for await indexedPage in group {
                indexedPages.append(indexedPage)
            }

            return indexedPages
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        let batchResult = BatchRunResult(sourceKind: resolved.kind, sourceLocation: resolved.location, pages: pages)
        let output = try BatchRunFormatter.format(batchResult)
        let exitCode: Int32 = batchResult.failureCount > 0 ? 1 : 0
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
    ) async -> BatchRunResult.Page {
        let pageConfiguration = baseConfiguration.replacing(url: url, batch: nil)
        logger.info("batch page start: \(url.absoluteString)")

        do {
            let scraper = WebScraper(configuration: pageConfiguration, logger: logger)
            let output = try await scraper.run()
            let formattedOutput = try OutputFormatter.format(
                output,
                sourceURL: pageConfiguration.url,
                extraction: pageConfiguration.extraction,
                outputFormat: pageConfiguration.outputFormat,
                prettyPrint: pageConfiguration.prettyPrint
            )
            logger.info("batch page done: \(url.absoluteString)")
            return .succeeded(url: url, output: formattedOutput)
        } catch {
            logger.info("batch page failed: \(url.absoluteString): \(error.localizedDescription)")
            return .failed(url: url, error: error.localizedDescription)
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
                logger.info("抽出結果を保存しました: \(fileURL.path)")
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
