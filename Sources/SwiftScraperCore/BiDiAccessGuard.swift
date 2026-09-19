import Foundation

enum BiDiAccessGuard {
    static let endpointPath = "/session"

    // Resolve no user-supplied DNS names at bind time.
    static func loopbackHost(_ host: String) throws -> String {
        switch host.lowercased() {
        case "localhost", "127.0.0.1": return "127.0.0.1"
        case "::1": return "::1"
        default:
            throw ScraperError.invalidArgument("BiDi requires 127.0.0.1, ::1, or localhost; use an SSH tunnel for remote access")
        }
    }

    static func allowsUpgrade(uri: String, origin: String?, host: String?, bindHost: String) -> Bool {
        guard uri == endpointPath, origin == nil else {
            return false
        }

        guard let host else {
            return false
        }

        return allowsHostname(hostname(from: host), bindHost: bindHost)
    }

    static func allowsNavigation(to url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "about":
            return true
        default:
            return false
        }
    }

    private static func hostname(from header: String) -> String {
        if header.hasPrefix("["), let end = header.firstIndex(of: "]") {
            return String(header[header.index(after: header.startIndex)..<end])
        }

        let components = header.split(separator: ":")
        return components.count == 2 ? String(components[0]) : header
    }

    private static func allowsHostname(_ name: String, bindHost: String) -> Bool {
        name == bindHost
            || name.caseInsensitiveCompare("localhost") == .orderedSame
            || name == "127.0.0.1" || name == "::1"
    }
}
