import CommonCrypto
import Foundation
import Security
import SQLite3

final class BrowserCookieExporter {
    struct PreparedFile {
        let url: URL
        let cookieCount: Int
    }

    private struct ChromiumConfiguration {
        let browserName: String
        let applicationSupportFolder: String
        let safeStorageService: String
    }

    private struct CookieRow {
        let hostKey: String
        let path: String
        let isSecure: Bool
        let isHTTPOnly: Bool
        let expiresUTC: Int64
        let name: String
        let value: String
        let encryptedValue: Data
    }

    private enum ExportError: LocalizedError {
        case browserCookieProfileMissing(String)
        case browserCookieDatabaseMissing(String)
        case browserCookieKeyUnavailable(String)
        case browserCookieQueryFailed(String)
        case browserCookieWriteFailed(String)
        case browserCookieEmpty(String)
        case browserCookieDecryptFailed(String)

        var errorDescription: String? {
            switch self {
            case .browserCookieProfileMissing(let browser):
                return "\(browser) browser cookie profile could not be found."
            case .browserCookieDatabaseMissing(let browser):
                return "\(browser) browser cookie database could not be found."
            case .browserCookieKeyUnavailable(let browser):
                return "\(browser) browser cookie key could not be read from Keychain."
            case .browserCookieQueryFailed(let detail):
                return "Browser cookie export failed: \(detail)"
            case .browserCookieWriteFailed(let detail):
                return "Browser cookie export file could not be written: \(detail)"
            case .browserCookieEmpty(let browser):
                return "\(browser) browser cookie export produced no usable cookies."
            case .browserCookieDecryptFailed(let detail):
                return "Browser cookie decrypt failed: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let diagnostics = AppDiagnostics.shared
    private let keySalt = Data("saltysalt".utf8)
    private let aesIV = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    func exportCookies(
        for source: BrowserCookieSource,
        urlString: String,
        taskID: UUID? = nil
    ) throws -> PreparedFile {
        guard let configuration = chromiumConfiguration(for: source) else {
            throw ExportError.browserCookieProfileMissing(source.rawValue)
        }
        guard let requestHost = URL(string: urlString)?.host?.lowercased(), !requestHost.isEmpty else {
            throw ExportError.browserCookieQueryFailed("invalid URL")
        }

        let profileDirectory = try resolveProfileDirectory(for: configuration)
        let databaseURL = profileDirectory.appendingPathComponent("Cookies", isDirectory: false)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw ExportError.browserCookieDatabaseMissing(configuration.browserName)
        }

        let snapshotDirectory = try makeTemporaryDirectory(prefix: "cookie-db")
        defer { try? fileManager.removeItem(at: snapshotDirectory) }

        let snapshotDatabaseURL = try snapshotCookieDatabase(
            from: databaseURL,
            snapshotDirectory: snapshotDirectory
        )
        let safeStoragePassword = try loadSafeStoragePassword(service: configuration.safeStorageService)
        let decryptionKey = try deriveChromiumKey(from: safeStoragePassword)
        let candidateHosts = relatedHosts(for: requestHost)
        let candidateDomainSuffixes = relatedDomainSuffixes(for: requestHost)
        let candidateHostFragments = relatedHostFragments(for: requestHost)

        var exportedLines: [String] = []
        let now = Int64(Date().timeIntervalSince1970)

        for cookie in try loadCookies(from: snapshotDatabaseURL) {
            guard shouldExport(
                cookie: cookie,
                candidateHosts: candidateHosts,
                candidateDomainSuffixes: candidateDomainSuffixes,
                candidateHostFragments: candidateHostFragments
            ) else {
                continue
            }
            let expiry = chromiumTimestampToUnix(cookie.expiresUTC)
            guard expiry == 0 || expiry > now else {
                continue
            }
            guard let value = try decryptedValue(for: cookie, key: decryptionKey), !value.isEmpty else {
                continue
            }
            exportedLines.append(netscapeLine(for: cookie, value: value, expiry: expiry))
        }

        guard !exportedLines.isEmpty else {
            throw ExportError.browserCookieEmpty(configuration.browserName)
        }

        let cookieFileURL = try writeCookieFile(
            lines: exportedLines,
            prefix: source.rawValue
        )

        diagnostics.log(
            .info,
            "Prepared \(configuration.browserName) cookie export; task=\(taskID?.uuidString ?? "-") cookies=\(exportedLines.count) file=\(cookieFileURL.path)"
        )

        return PreparedFile(url: cookieFileURL, cookieCount: exportedLines.count)
    }

    private func chromiumConfiguration(for source: BrowserCookieSource) -> ChromiumConfiguration? {
        switch source {
        case .comet:
            return ChromiumConfiguration(
                browserName: "Comet",
                applicationSupportFolder: "Comet",
                safeStorageService: "Comet Safe Storage"
            )
        default:
            return nil
        }
    }

    private func resolveProfileDirectory(for configuration: ChromiumConfiguration) throws -> URL {
        let supportRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(configuration.applicationSupportFolder, isDirectory: true)

        let profileName = preferredProfileName(in: supportRoot) ?? "Default"
        let profileDirectory = supportRoot.appendingPathComponent(profileName, isDirectory: true)
        if fileManager.fileExists(atPath: profileDirectory.path) {
            return profileDirectory
        }

        let defaultDirectory = supportRoot.appendingPathComponent("Default", isDirectory: true)
        guard fileManager.fileExists(atPath: defaultDirectory.path) else {
            throw ExportError.browserCookieProfileMissing(configuration.browserName)
        }
        return defaultDirectory
    }

    private func preferredProfileName(in supportRoot: URL) -> String? {
        let localStateURL = supportRoot.appendingPathComponent("Local State", isDirectory: false)
        guard let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let lastUsed = profile["last_used"] as? String,
              !lastUsed.isEmpty else {
            return nil
        }
        return lastUsed
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Link2Download", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func snapshotCookieDatabase(from databaseURL: URL, snapshotDirectory: URL) throws -> URL {
        let snapshotDatabaseURL = snapshotDirectory.appendingPathComponent(databaseURL.lastPathComponent)
        try fileManager.copyItem(at: databaseURL, to: snapshotDatabaseURL)

        for suffix in ["-journal", "-wal", "-shm"] {
            let sourceSidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecarURL.path) else { continue }
            let destinationSidecarURL = URL(fileURLWithPath: snapshotDatabaseURL.path + suffix)
            try? fileManager.copyItem(at: sourceSidecarURL, to: destinationSidecarURL)
        }

        return snapshotDatabaseURL
    }

    private func loadSafeStoragePassword(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            throw ExportError.browserCookieKeyUnavailable(service.replacingOccurrences(of: " Safe Storage", with: ""))
        }
        return password
    }

    private func deriveChromiumKey(from password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)
        let derivedKeyLength = derivedKey.count

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            keySalt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        keySalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw ExportError.browserCookieDecryptFailed("key derivation status \(status)")
        }
        return derivedKey
    }

    private func loadCookies(from databaseURL: URL) throws -> [CookieRow] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw ExportError.browserCookieQueryFailed("unable to open cookie database")
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT host_key, path, is_secure, is_httponly, expires_utc, name, value, encrypted_value
        FROM cookies
        ORDER BY host_key, name
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let message = String(cString: sqlite3_errmsg(database))
            throw ExportError.browserCookieQueryFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [CookieRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            cookies.append(
                CookieRow(
                    hostKey: textColumn(statement, index: 0),
                    path: textColumn(statement, index: 1),
                    isSecure: intColumn(statement, index: 2) != 0,
                    isHTTPOnly: intColumn(statement, index: 3) != 0,
                    expiresUTC: int64Column(statement, index: 4),
                    name: textColumn(statement, index: 5),
                    value: textColumn(statement, index: 6),
                    encryptedValue: dataColumn(statement, index: 7)
                )
            )
        }

        return cookies
    }

    private func textColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func intColumn(_ statement: OpaquePointer, index: Int32) -> Int32 {
        sqlite3_column_int(statement, index)
    }

    private func int64Column(_ statement: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private func dataColumn(_ statement: OpaquePointer, index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func relatedHosts(for requestHost: String) -> Set<String> {
        var hosts: Set<String> = [requestHost.lowercased()]

        let parts = requestHost.split(separator: ".")
        if parts.count > 2 {
            for start in 1..<(parts.count - 1) {
                let suffix = parts[start...].joined(separator: ".")
                if suffix.contains(".") {
                    hosts.insert(suffix)
                }
            }
        }

        if requestHost.contains("youtube.com") || requestHost.contains("youtu.be") {
            hosts.formUnion(["youtube.com", "youtu.be", "google.com", "accounts.google.com"])
        } else if requestHost.contains("google.com") {
            hosts.formUnion(["google.com", "youtube.com"])
        }

        return hosts
    }

    private func relatedDomainSuffixes(for requestHost: String) -> Set<String> {
        if requestHost.contains("youtube.com") || requestHost.contains("youtu.be") {
            return ["youtube.com", "google.com"]
        }
        if requestHost.contains("google.com") {
            return ["google.com", "youtube.com"]
        }
        return []
    }

    private func relatedHostFragments(for requestHost: String) -> Set<String> {
        if requestHost.contains("youtube.com") || requestHost.contains("youtu.be") {
            return ["youtube.com", "google.com"]
        }
        if requestHost.contains("google.com") {
            return ["google.com", "youtube.com"]
        }
        return []
    }

    private func shouldExport(
        cookie: CookieRow,
        candidateHosts: Set<String>,
        candidateDomainSuffixes: Set<String>,
        candidateHostFragments: Set<String>
    ) -> Bool {
        if candidateHosts.contains(where: { host in
            cookieHost(cookie.hostKey, matches: host)
        }) {
            return true
        }

        return candidateDomainSuffixes.contains { suffix in
            cookieHost(cookie.hostKey, hasDomainSuffix: suffix)
        } || candidateHostFragments.contains { fragment in
            cookieHost(cookie.hostKey, containsDomainFragment: fragment)
        }
    }

    private func cookieHost(_ cookieHost: String, matches host: String) -> Bool {
        let normalizedCookieHost = cookieHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let normalizedHost = host.lowercased()
        return normalizedHost == normalizedCookieHost || normalizedHost.hasSuffix("." + normalizedCookieHost)
    }

    private func cookieHost(_ cookieHost: String, hasDomainSuffix suffix: String) -> Bool {
        let normalizedCookieHost = cookieHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let normalizedSuffix = suffix.lowercased()
        return normalizedCookieHost == normalizedSuffix || normalizedCookieHost.hasSuffix("." + normalizedSuffix)
    }

    private func cookieHost(_ cookieHost: String, containsDomainFragment fragment: String) -> Bool {
        let normalizedCookieHost = cookieHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalizedCookieHost.contains(fragment.lowercased())
    }

    private func chromiumTimestampToUnix(_ timestamp: Int64) -> Int64 {
        guard timestamp > 0 else { return 0 }
        return max(0, timestamp / 1_000_000 - 11_644_473_600)
    }

    private func decryptedValue(for cookie: CookieRow, key: Data) throws -> String? {
        if !cookie.value.isEmpty {
            return cookie.value
        }
        guard !cookie.encryptedValue.isEmpty else {
            return nil
        }

        let prefix = cookie.encryptedValue.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
            return nil
        }

        var decrypted = try decryptAES128CBC(Data(cookie.encryptedValue.dropFirst(3)), key: key)
        let hostDigest = sha256(of: Data(cookie.hostKey.utf8))
        if decrypted.starts(with: hostDigest) {
            decrypted.removeFirst(hostDigest.count)
        }

        return String(data: decrypted, encoding: .utf8)
    }

    private func decryptAES128CBC(_ ciphertext: Data, key: Data) throws -> Data {
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count

        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    aesIV.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw ExportError.browserCookieDecryptFailed("AES status \(status)")
        }

        output.removeSubrange(outputLength...)
        return output
    }

    private func sha256(of data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes { digestBytes in
            data.withUnsafeBytes { dataBytes in
                CC_SHA256(
                    dataBytes.baseAddress,
                    CC_LONG(data.count),
                    digestBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return digest
    }

    private func netscapeLine(for cookie: CookieRow, value: String, expiry: Int64) -> String {
        let domain = cookie.isHTTPOnly ? "#HttpOnly_\(cookie.hostKey)" : cookie.hostKey
        let includesSubdomains = cookie.hostKey.hasPrefix(".") ? "TRUE" : "FALSE"
        let secure = cookie.isSecure ? "TRUE" : "FALSE"
        let sanitizedValue = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "%09")

        return [
            domain,
            includesSubdomains,
            cookie.path,
            secure,
            String(expiry),
            cookie.name,
            sanitizedValue
        ].joined(separator: "\t")
    }

    private func writeCookieFile(lines: [String], prefix: String) throws -> URL {
        let directory = try makeTemporaryDirectory(prefix: "cookies")
        let fileURL = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).txt", isDirectory: false)
        let contents = "# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n"

        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            throw ExportError.browserCookieWriteFailed(error.localizedDescription)
        }
    }
}
