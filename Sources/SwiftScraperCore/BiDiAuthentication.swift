import Foundation
import Security

/// A new capability per server run, shared only through an owner-readable file.
final class BiDiAuthentication {
    let token: String
    let fileURL: URL
    private let directory: URL

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ScraperError.invalidArgument("Unable to generate BiDi authentication token")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftscraper-bidi-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("token")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: fileURL.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw ScraperError.invalidArgument("Unable to write BiDi authentication token file")
        }
    }

    deinit {
        removeFiles()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Publish discovery information only after the listener has successfully bound.
    func publish(host: String, port: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "host": host, "port": port, "pid": ProcessInfo.processInfo.processIdentifier
        ])
        guard FileManager.default.createFile(
            atPath: directory.appendingPathComponent("server.json").path,
            contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw ScraperError.invalidArgument("Unable to publish BiDi discovery information")
        }
    }

    static func accepts(_ authorization: String?, token: String) -> Bool {
        guard token.utf8.count == 64, let authorization else { return false }
        let expected = Array("Bearer \(token)".utf8)
        let supplied = Array(authorization.utf8)
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(expected, supplied) { difference |= a ^ b }
        return difference == 0
    }
}
