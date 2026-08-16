import Foundation

public enum BrowserCookieBrowser: String, CaseIterable, Sendable {
    case chrome
    case firefox
}

/// A browser-cookie input source. The source is intentionally limited to the
/// macOS Chrome and Firefox profile layouts supported by this package.
public struct BrowserCookieSource: Equatable, Sendable {
    public let browser: BrowserCookieBrowser
    public let profile: String?

    public init(browser: BrowserCookieBrowser, profile: String? = nil) {
        self.browser = browser
        self.profile = profile
    }

    public func read() throws -> [CookieDefinition] {
        try BrowserCookieLoader.load(source: self, reader: makeReader())
    }

    func makeReader() -> any BrowserCookieReader {
        switch browser {
        case .chrome:
            return ChromeCookieReader(source: self)
        case .firefox:
            return FirefoxCookieReader(source: self)
        }
    }
}

public enum BrowserCookieError: LocalizedError, Equatable, Sendable {
    case unsupportedBrowser(String)
    case profileNotFound(String)
    case cookieDatabaseNotFound(String)
    case profileConfigurationUnreadable(String)
    case databaseSnapshotFailed(String)
    case databaseOpenFailed
    case databaseQueryFailed
    case unsupportedSchema(String)
    case keychainAccessDenied
    case keychainDataUnavailable
    case unsupportedEncryptionFormat
    case cookieDecryptionFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedBrowser:
            return "ブラウザ Cookie は macOS 13 以上の Chrome または Firefox のみ対応しています（Brave、Windows/Linux、Firefox コンテナは対象外です）"
        case .profileNotFound(let profile):
            return "ブラウザプロファイルが見つかりません: " + profile
        case .cookieDatabaseNotFound(let path):
            return "ブラウザ Cookie データベースが見つかりません: " + path
        case .profileConfigurationUnreadable(let path):
            return "Firefox profiles.ini を読み込めません: " + path
        case .databaseSnapshotFailed(let path):
            return "ブラウザ Cookie データベースのスナップショットを作成できません: " + path
        case .databaseOpenFailed:
            return "ブラウザ Cookie データベースを読み込めません"
        case .databaseQueryFailed:
            return "ブラウザ Cookie データベースの読み取りに失敗しました"
        case .unsupportedSchema(let browser):
            return browser + " の Cookie データベーススキーマに必要な列がありません"
        case .keychainAccessDenied:
            return "Chrome Safe Storage へのアクセスが拒否されました"
        case .keychainDataUnavailable:
            return "Chrome Safe Storage の鍵情報を取得できません"
        case .unsupportedEncryptionFormat:
            return "Chrome Cookie の暗号化形式には対応していません"
        case .cookieDecryptionFailed:
            return "Chrome Cookie の復号に失敗しました"
        }
    }
}

/// Common browser-database record. Values are converted to CookieDefinition
/// in memory before they enter the existing scraper configuration paths.
struct BrowserCookieRecord: Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let expires: Date?
    let hostOnly: Bool

    init(
        name: String,
        value: String,
        domain: String,
        path: String,
        secure: Bool,
        httpOnly: Bool,
        expires: Date?,
        hostOnly: Bool? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
        self.hostOnly = hostOnly ?? !domain.hasPrefix(".")
    }

    var definition: CookieDefinition {
        CookieDefinition(
            name: name,
            value: value,
            domain: hostOnly
                ? domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                : "." + domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            path: path,
            secure: secure,
            httpOnly: httpOnly,
            expires: expires,
            hostOnly: hostOnly ? true : nil
        )
    }
}

protocol BrowserCookieReader: Sendable {
    func read() throws -> [BrowserCookieRecord]
}

enum BrowserCookieLoader {
    static func load(
        source: BrowserCookieSource,
        reader: any BrowserCookieReader
    ) throws -> [CookieDefinition] {
        do {
            return try reader.read().map(\.definition)
        } catch let error as BrowserCookieError {
            throw error
        } catch {
            throw BrowserCookieError.databaseQueryFailed
        }
    }

    static func merge(
        browserCookies: [CookieDefinition],
        explicitCookies: [CookieDefinition]
    ) -> [CookieDefinition] {
        let explicitKeys = Set(explicitCookies.map(cookieIdentity))
        var result: [CookieDefinition] = []
        var browserKeys = Set<CookieIdentity>()

        for cookie in browserCookies {
            let key = cookieIdentity(cookie)
            guard !explicitKeys.contains(key), browserKeys.insert(key).inserted else {
                continue
            }
            result.append(cookie)
        }

        result.append(contentsOf: explicitCookies)
        return result
    }

    static func mergeConfiguredCookiesWithStore(
        configuredCookies: [CookieDefinition],
        storeCookies: [CookieDefinition]
    ) -> [CookieDefinition] {
        let configuredKeys = Set(configuredCookies.map(cookieIdentityIgnoringHostOnly))
        return configuredCookies + storeCookies.filter {
            !configuredKeys.contains(cookieIdentityIgnoringHostOnly($0))
        }
    }

    private static func cookieIdentity(_ cookie: CookieDefinition) -> CookieIdentity {
        CookieIdentity(
            name: cookie.name,
            domain: cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            path: cookie.path.isEmpty ? "/" : cookie.path,
            hostOnly: cookie.hostOnly ?? false
        )
    }

    private static func cookieIdentityIgnoringHostOnly(_ cookie: CookieDefinition) -> CookieIdentityIgnoringHostOnly {
        CookieIdentityIgnoringHostOnly(
            name: cookie.name,
            domain: cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            path: cookie.path.isEmpty ? "/" : cookie.path
        )
    }

    private struct CookieIdentity: Hashable {
        let name: String
        let domain: String
        let path: String
        let hostOnly: Bool
    }

    private struct CookieIdentityIgnoringHostOnly: Hashable {
        let name: String
        let domain: String
        let path: String
    }
}

extension CookieDefinition {
    func matches(url: URL, at now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }

        if let expires, expires <= now {
            return false
        }

        if secure && url.scheme?.lowercased() != "https" {
            return false
        }

        let rawDomain = domain.lowercased()
        let normalizedDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else {
            return false
        }

        if hostOnly != true {
            guard host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") else {
                return false
            }
        } else if host != normalizedDomain {
            return false
        }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        if cookiePath == "/" || requestPath == cookiePath {
            return true
        }

        guard requestPath.hasPrefix(cookiePath) else {
            return false
        }

        guard cookiePath.endIndex < requestPath.endIndex else {
            return false
        }

        return requestPath[cookiePath.endIndex] == "/"
    }
}
