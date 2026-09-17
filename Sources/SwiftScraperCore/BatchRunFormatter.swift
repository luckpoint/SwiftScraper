import Foundation

struct BatchRunResult: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let kind: String
        let location: String
    }

    struct Page: Codable, Equatable, Sendable {
        let url: String
        let success: Bool
        let output: String?
        let error: String?

        static func succeeded(url: URL, output: String) -> Self {
            Self(url: url.absoluteString, success: true, output: output, error: nil)
        }

        static func failed(url: URL, error: String) -> Self {
            Self(url: url.absoluteString, success: false, output: nil, error: error)
        }
    }

    let source: Source
    let pageCount: Int
    let successCount: Int
    let failureCount: Int
    let pages: [Page]

    init(sourceKind: String, sourceLocation: String, pages: [Page]) {
        self.source = Source(kind: sourceKind, location: sourceLocation)
        self.pageCount = pages.count
        self.successCount = pages.filter(\.success).count
        self.failureCount = pages.count - self.successCount
        self.pages = pages
    }
}

enum BatchRunFormatter {
    static func format(_ result: BatchRunResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            let data = try encoder.encode(result)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ScraperError.outputFailed("Unable to generate the batch JSON: \(error.localizedDescription)")
        }
    }
}
