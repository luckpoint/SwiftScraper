import Foundation
import XCTest
@testable import SwiftScraperCore

final class BiDiAccessGuardTests: XCTestCase {
    func testAllowsClientWithoutOrigin() {
        XCTAssertTrue(
            BiDiAccessGuard.allowsUpgrade(
                uri: "/session",
                origin: nil,
                host: "127.0.0.1:9222",
                bindHost: "127.0.0.1"
            )
        )
    }

    func testRejectsBrowserOrigin() {
        XCTAssertFalse(
            BiDiAccessGuard.allowsUpgrade(
                uri: "/session",
                origin: "https://example.com",
                host: "127.0.0.1:9222",
                bindHost: "127.0.0.1"
            )
        )
    }

    func testRejectsUnknownPath() {
        XCTAssertFalse(
            BiDiAccessGuard.allowsUpgrade(
                uri: "/",
                origin: nil,
                host: "127.0.0.1:9222",
                bindHost: "127.0.0.1"
            )
        )
    }

    func testRejectsRebindingHostname() {
        XCTAssertFalse(
            BiDiAccessGuard.allowsUpgrade(
                uri: "/session",
                origin: nil,
                host: "attacker.example.com:9222",
                bindHost: "127.0.0.1"
            )
        )
    }

    func testAllowsLocalhostAndIPLiteralHosts() {
        for host in ["localhost:9222", "LOCALHOST", "127.0.0.1:9222", "[::1]:9222", "192.168.1.4:9222"] {
            XCTAssertTrue(
                BiDiAccessGuard.allowsUpgrade(
                    uri: "/session",
                    origin: nil,
                    host: host,
                    bindHost: "127.0.0.1"
                ),
                "expected \(host) to be allowed"
            )
        }
    }

    func testAllowsConfiguredBindHostname() {
        XCTAssertTrue(
            BiDiAccessGuard.allowsUpgrade(
                uri: "/session",
                origin: nil,
                host: "scraper.internal:9222",
                bindHost: "scraper.internal"
            )
        )
    }

    func testAllowsWebAndAboutNavigation() throws {
        for raw in ["http://example.com", "https://example.com/a", "about:blank"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertTrue(BiDiAccessGuard.allowsNavigation(to: url), "expected \(raw) to be allowed")
        }
    }

    func testRejectsLocalFileNavigation() throws {
        for raw in ["file:///etc/passwd", "FILE:///etc/passwd", "data:text/html,<b>x</b>"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(BiDiAccessGuard.allowsNavigation(to: url), "expected \(raw) to be rejected")
        }
    }
}
