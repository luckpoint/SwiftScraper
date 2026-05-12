import Foundation
import SwiftScraperCore

@main
struct SwiftScraperCLI {
    @MainActor
    static func main() {
        do {
            switch try CLIParser.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
            case .help(let usage):
                write(usage, to: FileHandle.standardOutput)
                Foundation.exit(0)
            case .run(let configuration):
                let logger = StderrLogger(verbose: configuration.verbose)
                logger.info("CLI を開始します")
                let exitCode = ScraperLauncher(configuration: configuration).run()
                Foundation.exit(exitCode)
            case .pdf(let pdfConfiguration):
                let exitCode = PDFLauncher(configuration: pdfConfiguration).run()
                Foundation.exit(exitCode)
            case .downloadPDFs(let configuration):
                let exitCode = PDFDownloadLauncher(configuration: configuration).run()
                Foundation.exit(exitCode)
            case .bidiServer(let configuration):
                let exitCode = BiDiServerLauncher(configuration: configuration).run()
                Foundation.exit(exitCode)
            }
        } catch {
            write(error.localizedDescription, to: FileHandle.standardError)
            Foundation.exit(2)
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        var output = text
        if !output.hasSuffix("\n") {
            output.append("\n")
        }

        handle.write(Data(output.utf8))
    }
}
