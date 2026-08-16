import CommonCrypto
import Foundation
import Security
import SQLite3

struct ChromeCookieReader: BrowserCookieReader {
    private let source: BrowserCookieSource
    private let keyProvider: any ChromeSafeStorageKeyProvider

    init(
        source: BrowserCookieSource,
        keyProvider: any ChromeSafeStorageKeyProvider = SystemChromeSafeStorageKeyProvider()
    ) {
        self.source = source
        self.keyProvider = keyProvider
    }

    init(
        profileDirectory: URL,
        keyProvider: any ChromeSafeStorageKeyProvider = SystemChromeSafeStorageKeyProvider()
    ) {
        self.source = BrowserCookieSource(
            browser: .chrome,
            profile: profileDirectory.path
        )
        self.keyProvider = keyProvider
    }

    func read() throws -> [BrowserCookieRecord] {
        let profileDirectory = try BrowserProfilePathResolver.chromeProfileDirectory(for: source.profile)
        let databaseCandidates = [
            profileDirectory.appendingPathComponent("Cookies", isDirectory: false),
            profileDirectory.appendingPathComponent("Network/Cookies", isDirectory: false),
        ]
        guard let databaseURL = databaseCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw BrowserCookieError.cookieDatabaseNotFound(databaseCandidates[0].path)
        }

        return try BrowserCookieDatabaseReader.read(at: databaseURL) { database in
            try database.readChromeCookies(keyProvider: keyProvider)
        }
    }
}

struct FirefoxCookieReader: BrowserCookieReader {
    private let source: BrowserCookieSource

    init(source: BrowserCookieSource) {
        self.source = source
    }

    init(profileDirectory: URL) {
        self.source = BrowserCookieSource(
            browser: .firefox,
            profile: profileDirectory.path
        )
    }

    func read() throws -> [BrowserCookieRecord] {
        let profileDirectory = try BrowserProfilePathResolver.firefoxProfileDirectory(for: source.profile)
        let databaseURL = profileDirectory.appendingPathComponent("cookies.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw BrowserCookieError.cookieDatabaseNotFound(databaseURL.path)
        }

        return try BrowserCookieDatabaseReader.read(at: databaseURL) { database in
            try database.readFirefoxCookies()
        }
    }
}

protocol ChromeSafeStorageKeyProvider: Sendable {
    func key() throws -> Data
}

struct SystemChromeSafeStorageKeyProvider: ChromeSafeStorageKeyProvider {
    func key() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecItemNotFound {
                throw BrowserCookieError.keychainAccessDenied
            }
            throw BrowserCookieError.keychainDataUnavailable
        }

        guard let data = result as? Data, !data.isEmpty else {
            throw BrowserCookieError.keychainDataUnavailable
        }
        return data
    }
}

enum ChromeCookieDecryptor {
    static func isSupported(encryptedValue: Data) -> Bool {
        encryptedValue.starts(with: Data([0x76, 0x31, 0x30]))
    }

    static func validate(encryptedValue: Data) throws {
        guard isSupported(encryptedValue: encryptedValue) else {
            throw BrowserCookieError.unsupportedEncryptionFormat
        }
        let ciphertext = encryptedValue.dropFirst(3)
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw BrowserCookieError.cookieDecryptionFailed
        }
    }

    static func decrypt(
        encryptedValue: Data,
        safeStorageKey: Data,
        hostKey: String? = nil
    ) throws -> String {
        try validate(encryptedValue: encryptedValue)

        let ciphertext = Data(encryptedValue.dropFirst(3))
        guard !safeStorageKey.isEmpty else {
            throw BrowserCookieError.cookieDecryptionFailed
        }

        var derivedKey = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derivationStatus: Int32 = safeStorageKey.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress,
                    safeStorageKey.count,
                    saltBuffer.baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003,
                    &derivedKey,
                    derivedKey.count
                )
            }
        }

        guard derivationStatus == kCCSuccess else {
            throw BrowserCookieError.cookieDecryptionFailed
        }

        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var plaintextLength = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let cryptStatus: CCCryptorStatus = derivedKey.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBufferPointer { ivBuffer in
                ciphertext.withUnsafeBytes { ciphertextBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        derivedKey.count,
                        ivBuffer.baseAddress,
                        ciphertextBuffer.baseAddress,
                        ciphertext.count,
                        &plaintext,
                        plaintext.count,
                        &plaintextLength
                    )
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            throw BrowserCookieError.cookieDecryptionFailed
        }

        var data = Data(plaintext.prefix(plaintextLength))
        if let hostKey {
            let hostHash = Self.sha256(Data(hostKey.utf8))
            if data.starts(with: hostHash) {
                data.removeFirst(hostHash.count)
            }
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw BrowserCookieError.cookieDecryptionFailed
        }
        return value
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

enum BrowserProfilePathResolver {
    static func chromeProfileDirectory(
        for profile: String?,
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    ) throws -> URL {

        guard let profile, !profile.isEmpty else {
            return try requireDirectory(root.appendingPathComponent("Default", isDirectory: true), label: "Default")
        }

        if isPathArgument(profile) {
            let direct = resolvePathArgument(profile)
            return try requireDirectory(direct, label: profile)
        }

        return try requireDirectory(root.appendingPathComponent(profile, isDirectory: true), label: profile)
    }

    static func firefoxProfileDirectory(
        for profile: String?,
        root firefoxRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
    ) throws -> URL {

        if let profile, !profile.isEmpty, isPathArgument(profile) {
            return try requireDirectory(resolvePathArgument(profile), label: profile)
        }

        let profilesURL = firefoxRoot.appendingPathComponent("profiles.ini", isDirectory: false)
        let entries = try FirefoxProfilesINI.read(from: profilesURL)

        if let profile, !profile.isEmpty {
            if let entry = entries.first(where: { $0.name == profile || $0.path == profile }) {
                return try requireDirectory(entry.resolve(relativeTo: profilesURL), label: profile)
            }

            let direct = resolvePathArgument(profile)
            if FileManager.default.fileExists(atPath: direct.path) {
                return try requireDirectory(direct, label: profile)
            }
            throw BrowserCookieError.profileNotFound(profile)
        }

        guard let entry = entries.first(where: \.isDefault) ?? entries.first else {
            throw BrowserCookieError.profileConfigurationUnreadable(profilesURL.path)
        }
        return try requireDirectory(entry.resolve(relativeTo: profilesURL), label: entry.name)
    }

    private static func isPathArgument(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../") || raw.contains("/")
    }

    private static func resolvePathArgument(_ raw: String) -> URL {
        URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    private static func requireDirectory(_ url: URL, label: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrowserCookieError.profileNotFound(label)
        }
        return url
    }
}

private struct FirefoxProfileEntry: Sendable {
    let name: String
    let path: String
    let isRelative: Bool
    let isDefault: Bool

    func resolve(relativeTo profilesURL: URL) -> URL {
        if isRelative {
            return URL(fileURLWithPath: path, relativeTo: profilesURL.deletingLastPathComponent()).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

private enum FirefoxProfilesINI {
    static func read(from url: URL) throws -> [FirefoxProfileEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BrowserCookieError.profileConfigurationUnreadable(url.path)
        }

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BrowserCookieError.profileConfigurationUnreadable(url.path)
        }

        var entries: [FirefoxProfileEntry] = []
        var section = ""
        var values: [String: String] = [:]

        func flush() {
            guard section.hasPrefix("Profile"),
                  let path = values["Path"],
                  !path.isEmpty else {
                return
            }

            let name = values["Name"] ?? path
            let isRelative = values["IsRelative"] == "1"
            let isDefault = values["Default"] == "1"
            entries.append(
                FirefoxProfileEntry(
                    name: name,
                    path: path,
                    isRelative: isRelative,
                    isDefault: isDefault
                )
            )
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                section = String(line.dropFirst().dropLast())
                values = [:]
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        flush()

        return entries
    }
}

private enum BrowserCookieDatabaseReader {
    static func read<T>(
        at databaseURL: URL,
        body: (SQLiteDatabase) throws -> T
    ) throws -> T {
        do {
            let database = try SQLiteDatabase(url: databaseURL)
            return try body(database)
        } catch let error as BrowserCookieError {
            switch error {
            case .databaseOpenFailed, .databaseQueryFailed, .unsupportedSchema:
                break
            default:
                throw error
            }
            return try readSnapshot(databaseURL: databaseURL, body: body)
        } catch {
            return try readSnapshot(databaseURL: databaseURL, body: body)
        }
    }

    private static func readSnapshot<T>(
        databaseURL: URL,
        body: (SQLiteDatabase) throws -> T
    ) throws -> T {
        try SQLiteDatabaseSnapshot.withSnapshot(at: databaseURL) { snapshotURL in
            let database = try SQLiteDatabase(url: snapshotURL)
            return try body(database)
        }
    }
}

private struct SQLiteDatabaseSnapshot {
    private struct FileStamp: Equatable {
        let size: UInt64
        let modificationDate: Date?
    }

    static func withSnapshot<T>(
        at databaseURL: URL,
        body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-scraper-cookie-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = directory.appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            try copyConsistentDatabase(from: databaseURL, to: snapshotURL)
            // Keep the directory and all sidecars alive until the SQLite body has returned.
            return try body(snapshotURL)
        } catch let error as BrowserCookieError {
            throw error
        } catch {
            throw BrowserCookieError.databaseSnapshotFailed(databaseURL.path)
        }

    }

    private static func copyConsistentDatabase(from source: URL, to destination: URL) throws {
        let sidecars = [
            (suffix: "-wal", required: false),
            (suffix: "-shm", required: false),
        ]

        for _ in 0..<3 {
            let before = try stamps(for: source, sidecars: sidecars)
            try? FileManager.default.removeItem(at: destination)
            for sidecar in sidecars {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: destination.path + sidecar.suffix))
            }

            try FileManager.default.copyItem(at: source, to: destination)
            for sidecar in sidecars {
                let sourceSidecar = URL(fileURLWithPath: source.path + sidecar.suffix)
                let destinationSidecar = URL(fileURLWithPath: destination.path + sidecar.suffix)
                if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                    try FileManager.default.copyItem(at: sourceSidecar, to: destinationSidecar)
                }
            }

            let after = try stamps(for: source, sidecars: sidecars)
            if before == after {
                return
            }
        }

        throw BrowserCookieError.databaseSnapshotFailed(source.path)
    }

    private static func stamps(
        for source: URL,
        sidecars: [(suffix: String, required: Bool)]
    ) throws -> [String: FileStamp?] {
        var result: [String: FileStamp?] = ["main": try stamp(source)]
        for sidecar in sidecars {
            result[sidecar.suffix] = try stamp(URL(fileURLWithPath: source.path + sidecar.suffix))
        }
        return result
    }

    private static func stamp(_ url: URL) throws -> FileStamp? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return FileStamp(
            size: size.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}

private final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw BrowserCookieError.databaseOpenFailed
        }
        handle = database
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func readChromeCookies(keyProvider: any ChromeSafeStorageKeyProvider) throws -> [BrowserCookieRecord] {
        let columns = try tableColumns(named: "cookies")
        guard columns.contains("name"), columns.contains("host_key"), columns.contains("path"),
              columns.contains("value") || columns.contains("encrypted_value") else {
            throw BrowserCookieError.unsupportedSchema("Chrome")
        }

        var whereClauses: [String] = []
        if columns.contains("is_partitioned") {
            whereClauses.append("(is_partitioned = 0 OR is_partitioned IS NULL)")
        }
        if columns.contains("top_frame_site_key") {
            whereClauses.append("(top_frame_site_key IS NULL OR top_frame_site_key = '')")
        }

        let secureColumn = columns.contains("is_secure") ? "is_secure" : "secure"
        let httpOnlyColumn = columns.contains("is_httponly") ? "is_httponly" : "httponly"
        let query = """
        SELECT \(selectExpression("host_key", columns: columns)) AS host_key,
               \(selectExpression("name", columns: columns)) AS name,
               \(selectExpression("value", columns: columns)) AS value,
               \(selectExpression("path", columns: columns)) AS path,
               \(selectExpression("expires_utc", columns: columns)) AS expires_utc,
               \(selectExpression(secureColumn, columns: columns)) AS secure,
               \(selectExpression(httpOnlyColumn, columns: columns)) AS httponly,
               \(selectExpression("encrypted_value", columns: columns)) AS encrypted_value
        FROM cookies
        \(whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND "))
        """

        var key: Data?
        var records: [BrowserCookieRecord] = []
        try forEachRow(query) { row in
            guard let name = row.string("name"),
                  let domain = row.string("host_key"),
                  let path = row.string("path") else {
                return
            }

            let encryptedValue = row.data("encrypted_value") ?? Data()
            let value: String
            if encryptedValue.isEmpty {
                value = row.string("value") ?? ""
            } else {
                try ChromeCookieDecryptor.validate(encryptedValue: encryptedValue)
                if key == nil {
                    key = try keyProvider.key()
                }
                value = try ChromeCookieDecryptor.decrypt(
                    encryptedValue: encryptedValue,
                    safeStorageKey: key ?? Data(),
                    hostKey: domain
                )
            }

            records.append(
                BrowserCookieRecord(
                    name: name,
                    value: value,
                    domain: domain,
                    path: path,
                    secure: row.bool("secure"),
                    httpOnly: row.bool("httponly"),
                    expires: chromeDate(row.int64("expires_utc")),
                    hostOnly: !domain.hasPrefix(".")
                )
            )
        }
        return records
    }

    func readFirefoxCookies() throws -> [BrowserCookieRecord] {
        let columns = try tableColumns(named: "moz_cookies")
        guard columns.contains("name"), columns.contains("host"), columns.contains("path"), columns.contains("value") else {
            throw BrowserCookieError.unsupportedSchema("Firefox")
        }

        var whereClause = ""
        if columns.contains("originAttributes") {
            // Empty originAttributes is the only safe value. This excludes
            // userContext/container and partitioned cookies from other contexts.
            whereClause = "WHERE (originAttributes IS NULL OR originAttributes = '')"
        }

        let query = """
        SELECT \(selectExpression("host", columns: columns)) AS host,
               \(selectExpression("name", columns: columns)) AS name,
               \(selectExpression("value", columns: columns)) AS value,
               \(selectExpression("path", columns: columns)) AS path,
               \(selectExpression("expiry", columns: columns)) AS expiry,
               \(selectExpression("isSecure", columns: columns)) AS isSecure,
               \(selectExpression("isHttpOnly", columns: columns)) AS isHttpOnly
        FROM moz_cookies
        \(whereClause)
        """

        var records: [BrowserCookieRecord] = []
        try forEachRow(query) { row in
            guard let name = row.string("name"),
                  let domain = row.string("host"),
                  let path = row.string("path") else {
                return
            }

            let value = row.string("value") ?? ""
            let expiry = row.int64("expiry").flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            records.append(
                BrowserCookieRecord(
                    name: name,
                    value: value,
                    domain: domain,
                    path: path,
                    secure: row.bool("isSecure"),
                    httpOnly: row.bool("isHttpOnly"),
                    expires: expiry,
                    hostOnly: !domain.hasPrefix(".")
                )
            )
        }
        return records
    }

    private func tableColumns(named table: String) throws -> Set<String> {
        var columns = Set<String>()
        try forEachRow("PRAGMA table_info(\(table))") { row in
            if let name = row.string("name") {
                columns.insert(name)
            }
        }
        guard !columns.isEmpty else {
            throw BrowserCookieError.unsupportedSchema(table == "cookies" ? "Chrome" : "Firefox")
        }
        return columns
    }

    private func selectExpression(_ column: String, columns: Set<String>) -> String {
        columns.contains(column) ? "\"\(column)\"" : "NULL"
    }

    private func forEachRow(_ sql: String, body: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BrowserCookieError.databaseQueryFailed
        }
        defer {
            sqlite3_finalize(statement)
        }

        let columnNames = (0..<sqlite3_column_count(statement)).reduce(into: [String: Int32]()) { result, index in
            if let name = sqlite3_column_name(statement, index) {
                result[String(cString: name)] = index
            }
        }

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                try body(SQLiteRow(statement: statement, columnNames: columnNames))
            } else if status == SQLITE_DONE {
                return
            } else {
                throw BrowserCookieError.databaseQueryFailed
            }
        }
    }
}

private struct SQLiteRow {
    let statement: OpaquePointer
    let columnNames: [String: Int32]

    func string(_ name: String) -> String? {
        guard let index = columnNames[name], sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func data(_ name: String) -> Data? {
        guard let index = columnNames[name], sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: length)
    }

    func int64(_ name: String) -> Int64? {
        guard let index = columnNames[name], sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, index)
    }

    func bool(_ name: String) -> Bool {
        guard let value = int64(name) else {
            return false
        }
        return value != 0
    }
}

private func chromeDate(_ value: Int64?) -> Date? {
    guard let value, value > 0 else {
        return nil
    }
    return Date(timeIntervalSince1970: (Double(value) / 1_000_000) - 11_644_473_600)
}
