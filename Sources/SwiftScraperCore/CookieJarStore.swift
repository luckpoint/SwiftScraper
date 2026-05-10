import Foundation

enum CookieJarStore {
    static func loadIfPresent(from fileURL: URL) throws -> [CookieDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ScraperError.cookieJarFailed("\(fileURL.path): \(error.localizedDescription)")
        }

        do {
            return try decodeCookies(from: data)
        } catch {
            throw ScraperError.cookieJarFailed("\(fileURL.path): \(error.localizedDescription)")
        }
    }

    static func save(cookies: [HTTPCookie], to fileURL: URL) throws {
        let now = Date()
        let definitions = cookies
            .map(CookieDefinition.init(cookie:))
            .filter { definition in
                guard let expires = definition.expires else {
                    return true
                }

                return expires > now
            }

        try save(definitions: definitions, to: fileURL)
    }

    static func save(definitions: [CookieDefinition], to fileURL: URL) throws {
        let sortedDefinitions = definitions.sorted { lhs, rhs in
            if lhs.domain != rhs.domain {
                return lhs.domain < rhs.domain
            }

            if lhs.path != rhs.path {
                return lhs.path < rhs.path
            }

            return lhs.name < rhs.name
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(sortedDefinitions)
        } catch {
            throw ScraperError.cookieJarFailed("JSON を生成できません: \(error.localizedDescription)")
        }

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ScraperError.cookieJarFailed("\(fileURL.path): \(error.localizedDescription)")
        }
    }

    private static func decodeCookies(from data: Data) throws -> [CookieDefinition] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let array = try? decoder.decode([CookieDefinition].self, from: data) {
            return array
        }

        return [try decoder.decode(CookieDefinition.self, from: data)]
    }
}
