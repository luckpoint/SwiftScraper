import AppKit
import Foundation

@MainActor
public final class PDFLauncher {
    private let configuration: PDFConfiguration
    private let logger: StderrLogger
    private var exitCode: Int32 = 0
    private var runLoop: CFRunLoop?

    public init(configuration: PDFConfiguration) {
        self.configuration = configuration
        self.logger = StderrLogger(verbose: configuration.verbose)
    }

    public func run() -> Int32 {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.accessory)
        application.finishLaunching()
        runLoop = CFRunLoopGetCurrent()

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                do {
                    try self.executePDFConversion()
                } catch {
                    self.exitCode = 1
                    self.logger.error(error.localizedDescription)
                }
                self.stopApplicationLoop()
            }
            CFRunLoopWakeUp(runLoop)
        }

        CFRunLoopRun()
        return exitCode
    }

    private func executePDFConversion() throws {
        let markdownString = try readMarkdownFile(configuration.inputFile)
        logger.info("読み込み完了: \(configuration.inputFile.path)")

        let html = MarkdownHTMLConverter.convert(markdown: markdownString)
        logger.info("HTML 変換完了")

        let outputDir = configuration.outputFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let renderer = PDFRenderer(logger: logger)
        try renderer.render(html: html, outputURL: configuration.outputFile)
        logger.info("保存完了: \(configuration.outputFile.path)", force: true)
    }

    private func readMarkdownFile(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScraperError.pdfInputNotFound(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func stopApplicationLoop() {
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }
}
