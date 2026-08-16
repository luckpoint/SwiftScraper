import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import SwiftScraperCore

final class BrowserCookieTests: XCTestCase {
    func testChromeOldSchemaReadsPlaintextAndConvertsChromeExpiry() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let profile = fixture.directory.appendingPathComponent("Chrome Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("Cookies")
        let expires = Int64((Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)

        try SQLiteFixture.createDatabase(at: databaseURL, statements: [
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, encrypted_value BLOB)",
            "INSERT INTO cookies VALUES ('.example.com', 'session', 'old-value', '/app', \(expires), 1, 1, X'')",
        ])

        let records = try ChromeCookieReader(profileDirectory: profile).read()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].definition, CookieDefinition(
            name: "session",
            value: "old-value",
            domain: ".example.com",
            path: "/app",
            secure: true,
            httpOnly: true,
            expires: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    func testChromeNewSchemaExcludesPartitionedCookiesAndDecryptsV10() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let profile = fixture.directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("Cookies")
        let encrypted = try Self.encryptChromeValue("encrypted-value", safeStorageKey: Data("peanuts".utf8))
        let encryptedHex = encrypted.map { String(format: "%02x", $0) }.joined()

        try SQLiteFixture.createDatabase(at: databaseURL, statements: [
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, encrypted_value BLOB, is_partitioned INTEGER, top_frame_site_key TEXT)",
            "INSERT INTO cookies VALUES ('example.com', 'session', '', '/', 0, 0, 0, X'\(encryptedHex)', 0, '')",
            "INSERT INTO cookies VALUES ('example.com', 'other', 'other-value', '/', 0, 0, 0, X'', 1, 'https://other.example')",
        ])

        let reader = ChromeCookieReader(
            profileDirectory: profile,
            keyProvider: FixedChromeKeyProvider(safeKey: Data("peanuts".utf8))
        )
        let records = try reader.read()
        XCTAssertEqual(records.map(\.definition), [CookieDefinition(name: "session", value: "encrypted-value", domain: "example.com", hostOnly: true)])
    }

    func testChromeV10StripsMatchingHostHashAfterDecryption() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let profile = fixture.directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("Cookies")
        let host = "example.com"
        let hostData = Data(host.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        hostData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(hostData.count), &digest)
        }
        let plaintext = Data(digest) + Data("hashed-value".utf8)
        let encrypted = try Self.encryptChromePayload(plaintext, safeStorageKey: Data("peanuts".utf8))
        let encryptedHex = encrypted.map { String(format: "%02x", $0) }.joined()

        try SQLiteFixture.createDatabase(at: databaseURL, statements: [
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, encrypted_value BLOB)",
            "INSERT INTO cookies VALUES ('\(host)', 'session', '', '/', 0, 1, 1, X'\(encryptedHex)')",
        ])

        let reader = ChromeCookieReader(
            profileDirectory: profile,
            keyProvider: FixedChromeKeyProvider(safeKey: Data("peanuts".utf8))
        )
        let records = try reader.read()
        XCTAssertEqual(records.map(\.value), ["hashed-value"])
    }

    func testChromeUnsupportedFormatAndKeychainRejectionNeverExposeValue() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let profile = fixture.directory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("Cookies")
        try SQLiteFixture.createDatabase(at: databaseURL, statements: [
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, secure INTEGER, httponly INTEGER, encrypted_value BLOB)",
            "INSERT INTO cookies VALUES ('example.com', 'session', '', '/', 0, 0, 0, X'763131deadbeef')",
        ])

        XCTAssertThrowsError(try ChromeCookieReader(
            profileDirectory: profile,
            keyProvider: RejectingChromeKeyProvider()
        ).read()) { error in
            XCTAssertEqual(error as? BrowserCookieError, .unsupportedEncryptionFormat)
            XCTAssertFalse(error.localizedDescription.contains("deadbeef"))
            XCTAssertFalse(error.localizedDescription.contains("session"))
        }

        try SQLiteFixture.createDatabase(at: databaseURL, statements: [
            "DROP TABLE cookies",
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, path TEXT, expires_utc INTEGER, secure INTEGER, httponly INTEGER, encrypted_value BLOB)",
            "INSERT INTO cookies VALUES ('example.com', 'session', '', '/', 0, 0, 0, X'7631300102030405060708090a0b0c0d0e0f10')",
        ])
        XCTAssertThrowsError(try ChromeCookieReader(
            profileDirectory: profile,
            keyProvider: RejectingChromeKeyProvider()
        ).read()) { error in
            XCTAssertEqual(error as? BrowserCookieError, .keychainAccessDenied)
            XCTAssertFalse(error.localizedDescription.contains("010203"))
        }
    }

    func testFirefoxProfilesINIResolvesRelativeAbsoluteAndSelectedProfiles() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("Firefox", isDirectory: true)
        let relative = root.appendingPathComponent("Profiles/relative", isDirectory: true)
        let absolute = fixture.directory.appendingPathComponent("absolute", isDirectory: true)
        try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: absolute, withIntermediateDirectories: true)
        let profilesINI = """
        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/relative
        Default=1

        [Profile1]
        Name=absolute-profile
        IsRelative=0
        Path=\(absolute.path)
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try profilesINI.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try BrowserProfilePathResolver.firefoxProfileDirectory(for: nil, root: root),
            relative.standardizedFileURL
        )
        XCTAssertEqual(
            try BrowserProfilePathResolver.firefoxProfileDirectory(for: "absolute-profile", root: root),
            absolute.standardizedFileURL
        )
    }

    func testFirefoxReaderHandlesWALSHMAndExcludesContainerAttributes() throws {
        let fixture = try TemporaryCookieFixture()
        defer { fixture.remove() }
        let profile = fixture.directory.appendingPathComponent("Firefox Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("cookies.sqlite")
        let liveDatabase = try SQLiteFixture.openWALDatabase(at: databaseURL, statements: [
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, originAttributes TEXT)",
            "INSERT INTO moz_cookies VALUES ('.example.com', 'default', 'firefox-value', '/', 1800000000, 1, 1, '')",
            "INSERT INTO moz_cookies VALUES ('.example.com', 'container', 'container-value', '/', 1800000000, 0, 0, 'userContextId=2')",
        ])
        defer { liveDatabase.close() }

        let records = try FirefoxCookieReader(profileDirectory: profile).read()
        XCTAssertEqual(records.map(\.name), ["default"])
        XCTAssertEqual(records[0].value, "firefox-value")
        XCTAssertEqual(records[0].expires, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testCookieMatchingHonorsDomainPathExpirySecureAndHttpOnlyIndependently() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://sub.example.com/app/page")!

        XCTAssertTrue(CookieDefinition(name: "a", value: "x", domain: ".example.com", path: "/app", httpOnly: true).matches(url: url, at: now))
        XCTAssertFalse(CookieDefinition(name: "a", value: "x", domain: ".example.com", path: "/apple").matches(url: url, at: now))
        XCTAssertFalse(CookieDefinition(name: "a", value: "x", domain: "example.com", hostOnly: true).matches(url: url, at: now))
        XCTAssertFalse(CookieDefinition(name: "a", value: "x", domain: "other.com").matches(url: url, at: now))
        XCTAssertFalse(CookieDefinition(name: "a", value: "x", domain: ".example.com", secure: true).matches(url: URL(string: "http://sub.example.com/app")!, at: now))
        XCTAssertFalse(CookieDefinition(name: "a", value: "x", domain: ".example.com", expires: now).matches(url: url, at: now))
    }

    func testExplicitCookiesOverrideBrowserCookiesByNameDomainAndPath() {
        let browser = [
            CookieDefinition(name: "session", value: "browser-value", domain: ".example.com"),
            CookieDefinition(name: "other", value: "other-value", domain: "example.com"),
        ]
        let explicit = [
            CookieDefinition(name: "session", value: "explicit-value", domain: ".example.com"),
        ]

        let merged = BrowserCookieLoader.merge(browserCookies: browser, explicitCookies: explicit)
        XCTAssertEqual(merged, [browser[1], explicit[0]])
    }

    func testConfiguredCookieRetainsHostOnlySemanticsForPDFLinks() {
        let configured = CookieDefinition(
            name: "session",
            value: "configured-value",
            domain: "example.com",
            hostOnly: true
        )
        let store = CookieDefinition(
            name: "session",
            value: "store-value",
            domain: "example.com"
        )

        XCTAssertEqual(
            BrowserCookieLoader.mergeConfiguredCookiesWithStore(
                configuredCookies: [configured],
                storeCookies: [store]
            ),
            [configured]
        )
    }

    func testCLIReadsBrowserReaderOnceAndPropagatesToRunPDFLinkedPDFAndBiDi() throws {
        let state = ReaderState()
        let reader = StubBrowserCookieReader(state: state)
        let urlFile = try makeURLFile()
        defer { try? FileManager.default.removeItem(at: urlFile) }
        let arguments = [
            "https://example.com",
            "--browser-cookies", "chrome",
            "--browser-profile", "Profile 1",
            "--cookie", "name=session;value=explicit-value;domain=example.com",
        ]

        guard case .run(let run) = try CLIParser.parse(arguments: arguments, browserCookieReader: reader) else {
            return XCTFail("run configuration expected")
        }
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(run.cookies.last?.value, "explicit-value")

        guard case .run(let linked) = try CLIParser.parse(
            arguments: ["https://example.com", "--download-linked-pdfs", "downloads", "--browser-cookies", "chrome"],
            browserCookieReader: reader
        ) else {
            return XCTFail("linked PDF configuration expected")
        }
        XCTAssertNotNil(linked.linkedPDFDownloadDirectory)
        XCTAssertEqual(linked.cookies, reader.records.map(\.definition))
        XCTAssertEqual(state.count, 2)

        guard case .run(let batch) = try CLIParser.parse(
            arguments: ["--url-file", urlFile.path, "--browser-cookies", "firefox"],
            browserCookieReader: reader
        ) else {
            return XCTFail("batch configuration expected")
        }
        XCTAssertEqual(state.count, 3)
        XCTAssertNotNil(batch.batch)

        guard case .downloadPDFs(let pdf) = try CLIParser.parse(
            arguments: ["https://example.com", "--download-pdfs", "downloads", "--browser-cookies", "chrome"],
            browserCookieReader: reader
        ) else {
            return XCTFail("pdf configuration expected")
        }
        XCTAssertEqual(pdf.cookies, reader.records.map(\.definition))
        XCTAssertEqual(state.count, 4)

        guard case .bidiServer(let bidi) = try CLIParser.parse(
            arguments: ["--bidi-server", "--browser-cookies", "firefox"],
            browserCookieReader: reader
        ) else {
            return XCTFail("bidi configuration expected")
        }
        XCTAssertEqual(bidi.cookies, reader.records.map(\.definition))
        XCTAssertEqual(state.count, 5)
    }

    func testBrowserCookiesRejectCookieJarAndUnsupportedBrowser() {
        let reader = StubBrowserCookieReader(state: ReaderState())
        XCTAssertThrowsError(try CLIParser.parse(
            arguments: ["https://example.com", "--browser-cookies", "chrome", "--cookie-jar", "cookies.json"],
            browserCookieReader: reader
        )) { error in
            XCTAssertEqual(error as? ScraperError, .invalidArgument("`--browser-cookies` と `--cookie-jar` は併用できません"))
        }

        XCTAssertThrowsError(try CLIParser.parse(arguments: ["https://example.com", "--browser-cookies", "brave"])) { error in
            guard case .invalidArgument(let message) = error as? ScraperError else {
                return XCTFail("invalid browser argument expected")
            }
            XCTAssertTrue(message.contains("Brave"))
            XCTAssertFalse(message.contains("browser-value"))
        }
    }

    private func makeURLFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "https://example.com/one\nhttps://example.com/two\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func encryptChromeValue(_ value: String, safeStorageKey: Data) throws -> Data {
        try encryptChromePayload(Data(value.utf8), safeStorageKey: safeStorageKey)
    }

    private static func encryptChromePayload(_ plaintext: Data, safeStorageKey: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivationStatus: Int32 = safeStorageKey.withUnsafeBytes { password in
            salt.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, safeStorageKey.count,
                    saltBuffer.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003, &key, key.count
                )
            }
        }
        XCTAssertEqual(derivationStatus, Int32(kCCSuccess))

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var encrypted = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var encryptedLength = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBufferPointer { ivBuffer in
                plaintext.withUnsafeBytes { plaintextBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                        plaintextBuffer.baseAddress, plaintext.count, &encrypted, encrypted.count, &encryptedLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TestError.encryptionFailed
        }
        return Data([0x76, 0x31, 0x30]) + Data(encrypted.prefix(encryptedLength))
    }
}

private struct FixedChromeKeyProvider: ChromeSafeStorageKeyProvider {
    let safeKey: Data

    func key() throws -> Data { safeKey }
}

private struct RejectingChromeKeyProvider: ChromeSafeStorageKeyProvider {
    func key() throws -> Data { throw BrowserCookieError.keychainAccessDenied }
}

private final class ReaderState: @unchecked Sendable {
    var count = 0
}

private struct StubBrowserCookieReader: BrowserCookieReader {
    let state: ReaderState
    let records: [BrowserCookieRecord] = [
        BrowserCookieRecord(name: "session", value: "browser-value", domain: "example.com", path: "/", secure: true, httpOnly: true, expires: nil),
    ]

    func read() throws -> [BrowserCookieRecord] {
        state.count += 1
        return records
    }
}

private final class TemporaryCookieFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-scraper-browser-cookie-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SQLiteLiveDatabase {
    private var handle: OpaquePointer?
    private let url: URL

    init(handle: OpaquePointer?, url: URL) {
        self.handle = handle
        self.url = url
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    deinit { close() }
}

private enum SQLiteFixture {
    static func createDatabase(at url: URL, statements: [String]) throws {
        let live = try openWALDatabase(at: url, statements: statements)
        live.close()
    }

    static func openWALDatabase(at url: URL, statements: [String]) throws -> SQLiteLiveDatabase {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw TestError.databaseFailed
        }
        do {
            try execute(handle, "PRAGMA journal_mode=WAL")
            for statement in statements {
                try execute(handle, statement)
            }
            return SQLiteLiveDatabase(handle: handle, url: url)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw TestError.databaseFailed
        }
    }
}

private enum TestError: Error {
    case databaseFailed
    case encryptionFailed
}
