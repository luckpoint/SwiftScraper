import Foundation

struct ResolvedSitemap: Equatable, Sendable {
    let sitemapURL: URL
    let pageURLs: [URL]
}

enum SitemapDocument: Equatable {
    case urlset([URL])
    case sitemapIndex([URL])
}

struct SitemapResolver: Sendable {
    let timeout: TimeInterval
    let logger: StderrLogger

    init(timeout: TimeInterval, logger: StderrLogger) {
        self.timeout = timeout
        self.logger = logger
    }

    func resolve(startingFrom inputURL: URL) async throws -> ResolvedSitemap {
        let sitemapURL = Self.resolveSitemapURL(from: inputURL)
        logger.info("Fetching the sitemap: \(sitemapURL.absoluteString)")

        var pendingSitemaps = [sitemapURL]
        var visitedSitemaps: Set<String> = []
        var seenPageURLs: Set<String> = []
        var pageURLs: [URL] = []

        while !pendingSitemaps.isEmpty {
            let currentSitemap = pendingSitemaps.removeFirst()
            let currentKey = currentSitemap.absoluteURL.absoluteString

            guard visitedSitemaps.insert(currentKey).inserted else {
                continue
            }

            switch try await fetchDocument(from: currentSitemap) {
            case .urlset(let urls):
                for url in urls {
                    let urlKey = url.absoluteURL.absoluteString
                    if seenPageURLs.insert(urlKey).inserted {
                        pageURLs.append(url.absoluteURL)
                    }
                }
            case .sitemapIndex(let nestedSitemaps):
                pendingSitemaps.append(contentsOf: nestedSitemaps)
            }
        }

        guard !pageURLs.isEmpty else {
            throw ScraperError.sitemapParseFailed("No URLs found: \(sitemapURL.absoluteString)")
        }

        return ResolvedSitemap(sitemapURL: sitemapURL, pageURLs: pageURLs)
    }

    static func resolveSitemapURL(from inputURL: URL) -> URL {
        let lowercasedPath = inputURL.lastPathComponent.lowercased()
        if lowercasedPath.hasSuffix(".xml") || lowercasedPath.hasSuffix(".xml.gz") {
            return inputURL
        }

        if inputURL.isFileURL {
            if inputURL.hasDirectoryPath {
                return inputURL.appendingPathComponent("sitemap.xml")
            }

            return inputURL.deletingLastPathComponent().appendingPathComponent("sitemap.xml")
        }

        guard var components = URLComponents(url: inputURL, resolvingAgainstBaseURL: false) else {
            return inputURL
        }

        components.path = "/sitemap.xml"
        components.query = nil
        components.fragment = nil
        return components.url ?? inputURL
    }

    private func fetchDocument(from sitemapURL: URL) async throws -> SitemapDocument {
        let data = try await loadData(from: sitemapURL)

        if data.starts(with: [0x1f, 0x8b]) {
            throw ScraperError.sitemapParseFailed("gzip-compressed sitemaps are not supported: \(sitemapURL.absoluteString)")
        }

        return try SitemapDocumentParser.parse(data: data, baseURL: sitemapURL)
    }

    private func loadData(from url: URL) async throws -> Data {
        if url.isFileURL {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw ScraperError.sitemapFetchFailed("\(url.path): \(error.localizedDescription)")
            }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw ScraperError.sitemapFetchFailed("\(url.absoluteString): HTTP \(httpResponse.statusCode)")
            }

            return data
        } catch let error as ScraperError {
            throw error
        } catch {
            throw ScraperError.sitemapFetchFailed("\(url.absoluteString): \(error.localizedDescription)")
        }
    }
}

final class SitemapDocumentParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var elementStack: [String] = []
    private var currentText = ""
    private var urlLocations: [URL] = []
    private var sitemapLocations: [URL] = []
    private var invalidLocations: [String] = []
    private var parserErrorMessage: String?

    private init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parse(data: Data, baseURL: URL) throws -> SitemapDocument {
        let delegate = SitemapDocumentParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else {
            let message = delegate.parserErrorMessage
                ?? parser.parserError?.localizedDescription
                ?? "Unknown XML error"
            throw ScraperError.sitemapParseFailed("\(baseURL.absoluteString): \(message)")
        }

        return try delegate.makeDocument()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(from: qName ?? elementName)
        elementStack.append(name)

        if name == "loc" {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elementStack.last == "loc" {
            currentText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(from: qName ?? elementName)

        if name == "loc" {
            let parent = elementStack.dropLast().last
            appendLocation(from: currentText, parent: parent)
            currentText = ""
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserErrorMessage = parseError.localizedDescription
    }

    private func makeDocument() throws -> SitemapDocument {
        if let invalidLocation = invalidLocations.first {
            throw ScraperError.sitemapParseFailed(
                "\(baseURL.absoluteString): A loc could not be interpreted as a URL: \(invalidLocation)"
            )
        }

        if !sitemapLocations.isEmpty {
            return .sitemapIndex(sitemapLocations)
        }

        return .urlset(urlLocations)
    }

    private func appendLocation(from rawValue: String, parent: String?) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            invalidLocations.append(trimmed)
            return
        }

        switch parent {
        case "url":
            urlLocations.append(url)
        case "sitemap":
            sitemapLocations.append(url)
        default:
            break
        }
    }

    private func localName(from rawName: String) -> String {
        rawName.split(separator: ":").last.map(String.init) ?? rawName
    }
}
