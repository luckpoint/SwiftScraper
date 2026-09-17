import Foundation

enum BiDiAccessGuard {
    static let endpointPath = "/session"

    static func allowsUpgrade(uri: String, origin: String?, host: String?, bindHost: String) -> Bool {
        guard uri == endpointPath, origin == nil else {
            return false
        }

        guard let host else {
            return true
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
            || isIPLiteral(name)
    }

    private static func isIPLiteral(_ name: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return true
        }

        var v6 = in6_addr()
        return inet_pton(AF_INET6, name, &v6) == 1
    }
}
