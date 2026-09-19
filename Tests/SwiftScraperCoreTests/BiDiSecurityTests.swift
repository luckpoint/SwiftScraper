import Foundation
import XCTest
@testable import SwiftScraperCore

final class BiDiSecurityTests: XCTestCase {
    func testTokenFileIsPrivateUniqueAndRemoved() throws {
        var authentication: BiDiAuthentication? = try BiDiAuthentication()
        let other = try BiDiAuthentication()
        let file = try XCTUnwrap(authentication?.fileURL)
        XCTAssertNotEqual(authentication?.token, other.token)
        XCTAssertEqual(authentication?.token.count, 64)
        for (url, permissions) in [(file, 0o600), (file.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), authentication?.token)
        authentication = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExternalBindRejectedByCLI() throws {
        for host in ["0.0.0.0", "::", "192.168.1.2", "example.com", "127.0.0.1.example.com"] {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["--bidi-server", "--bidi-host", host]))
        }
        XCTAssertEqual(try BiDiAccessGuard.loopbackHost("localhost"), "127.0.0.1")
        XCTAssertEqual(try BiDiAccessGuard.loopbackHost("::1"), "::1")
    }

    @MainActor
    private func makeServer(token: String, bindHost: String = "127.0.0.1") throws -> BiDiWebSocketServer {
        guard case .bidiServer(let configuration) = try CLIParser.parse(arguments: ["--bidi-server"]) else {
            throw ScraperError.invalidArgument("Unexpected command")
        }
        let host = BiDiWebViewHost(configuration: configuration, logger: StderrLogger(verbose: false))
        return BiDiWebSocketServer(host: bindHost, port: 0, dispatcher: BiDiDispatcher(host: host), token: token)
    }

    @MainActor
    func testServerAlsoRejectsExternalBind() throws {
        let auth = try BiDiAuthentication()
        let server = try makeServer(token: auth.token, bindHost: "0.0.0.0")
        defer { server.stop() }
        XCTAssertThrowsError(try server.start())
    }

    @MainActor
    func testRealWebSocketAuthenticationAndFrameLimit() async throws {
        let auth = try BiDiAuthentication()
        let server = try makeServer(token: auth.token)
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.listeningPort)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Even a cookie request must never reach the dispatcher without authentication.
        for headers in [[:], ["Authorization": "Bearer incorrect"],
                        ["Authorization": "Bearer \(auth.token)", "Origin": "https://example.com"]] {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/session")!)
            request.allHTTPHeaderFields = headers
            let socket = session.webSocketTask(with: request)
            socket.resume()
            do {
                try await socket.send(.string("{\"id\":1,\"method\":\"storage.getCookies\"}"))
                _ = try await socket.receive()
                XCTFail("Unauthorized request received a response")
            } catch { /* Expected handshake rejection. */ }
            socket.cancel(with: .goingAway, reason: nil)
        }

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/session")!)
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try await socket.send(.string("{\"id\":2,\"method\":\"session.status\"}"))
        let response = try await socket.receive()
        guard case .string(let json) = response else { return XCTFail("Expected JSON") }
        XCTAssertTrue(json.contains("success"))
        do {
            try await socket.send(.string(String(repeating: "x", count: 20 * 1024)))
            _ = try await socket.receive()
            XCTFail("Oversized frame accepted")
        } catch { /* Expected protocol rejection. */ }
    }
}
