import Foundation

struct ResolvedURLFile: Equatable, Sendable {
    let fileURL: URL
    let pageURLs: [URL]
}

enum URLFileResolver {
    static func resolve(from fileURL: URL) throws -> ResolvedURLFile {
        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ScraperError.urlFileFailed("\(fileURL.path): \(error.localizedDescription)")
        }

        var pageURLs: [URL] = []
        var seen: Set<String> = []

        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
                throw ScraperError.urlFileFailed("\(fileURL.path): line \(index + 1) is not a valid URL: \(trimmed)")
            }

            let normalized = url.absoluteURL
            let key = normalized.absoluteString
            if seen.insert(key).inserted {
                pageURLs.append(normalized)
            }
        }

        guard !pageURLs.isEmpty else {
            throw ScraperError.urlFileFailed("\(fileURL.path): No URLs found")
        }

        return ResolvedURLFile(fileURL: fileURL, pageURLs: pageURLs)
    }
}
