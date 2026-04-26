import Foundation
import HTMLToMarkdown
import SwiftSoup

enum OutputFormatter {
    private static let indentAmount: UInt = 2

    static func format(
        _ output: String,
        sourceURL: URL,
        extraction: ExtractionMode,
        outputFormat: OutputFormat,
        prettyPrint: Bool
    ) throws -> String {
        switch outputFormat {
        case .plain:
            return try formatPlainOutput(output, extraction: extraction, prettyPrint: prettyPrint)
        case .markdown:
            return try renderMarkdown(output, sourceURL: sourceURL, extraction: extraction)
        }
    }

    private static func formatPlainOutput(
        _ output: String,
        extraction: ExtractionMode,
        prettyPrint: Bool
    ) throws -> String {
        guard prettyPrint else {
            return output
        }

        switch extraction {
        case .bodyText:
            return output
        case .structureInspection:
            return output
        case .outerHTML:
            return try prettyPrintDocument(output)
        case .selectorInnerHTML, .contentOnly:
            return try prettyPrintFragment(output)
        }
    }

    private static func renderMarkdown(
        _ html: String,
        sourceURL: URL,
        extraction: ExtractionMode
    ) throws -> String {
        switch extraction {
        case .bodyText, .structureInspection:
            throw ScraperError.markdownFailed("この抽出モードでは Markdown に変換できません")
        case .outerHTML, .selectorInnerHTML, .contentOnly:
            do {
                return try HTMLToMarkdown.convert(
                    html,
                    plugins: [BasePlugin(), CommonmarkPlugin(), GFMPlugin()],
                    options: markdownOptions(for: sourceURL)
                )
            } catch {
                throw ScraperError.markdownFailed(error.localizedDescription)
            }
        }
    }

    private static func markdownOptions(for sourceURL: URL) -> [ConverterOption] {
        guard let scheme = sourceURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return []
        }

        return [.domain(sourceURL.absoluteString)]
    }

    private static func prettyPrintDocument(_ html: String) throws -> String {
        do {
            let document = try SwiftSoup.parse(html)
            configurePrettyPrint(for: document)
            return try document.outerHtml()
        } catch {
            throw ScraperError.prettyPrintFailed(error.localizedDescription)
        }
    }

    private static func prettyPrintFragment(_ html: String) throws -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            configurePrettyPrint(for: document)
            if let body = document.body() {
                return try body.html()
            }

            return html
        } catch {
            throw ScraperError.prettyPrintFailed(error.localizedDescription)
        }
    }

    private static func configurePrettyPrint(for document: Document) {
        document.outputSettings()
            .prettyPrint(pretty: true)
            .outline(outlineMode: true)
            .indentAmount(indentAmount: indentAmount)
    }
}
