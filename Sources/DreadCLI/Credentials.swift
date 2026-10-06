import Foundation
import DreadcastKit
#if canImport(Security)
import Security
#endif

/// Xweather credentials come from the environment (for CI) or the login Keychain.
/// They are never written to the config file, cache, logs or JSON output.
public enum Credentials {
    static let service = "dreadcast-cli"
    static let idAccount = "xweather.client-id"
    static let secretAccount = "xweather.client-secret"

    public static func xweather(environment: [String: String] = ProcessInfo.processInfo.environment) -> LightningCredentials? {
        let id = environment["DREADCAST_XWEATHER_CLIENT_ID"] ?? environment["XWEATHER_CLIENT_ID"]
        let secret = environment["DREADCAST_XWEATHER_CLIENT_SECRET"] ?? environment["XWEATHER_CLIENT_SECRET"]
        if let id, let secret, !id.isEmpty, !secret.isEmpty {
            return LightningCredentials(clientID: id, clientSecret: secret)
        }
        guard let storedID = read(idAccount), let storedSecret = read(secretAccount),
              !storedID.isEmpty, !storedSecret.isEmpty else { return nil }
        return LightningCredentials(clientID: storedID, clientSecret: storedSecret)
    }

    public static func source(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if (environment["DREADCAST_XWEATHER_CLIENT_ID"] ?? environment["XWEATHER_CLIENT_ID"]) != nil { return "environment" }
        #if canImport(Security)
        return read(idAccount) != nil ? "Keychain" : nil
        #else
        return read(idAccount) != nil ? "credentials file" : nil
        #endif
    }

    public static func saveXweather(_ credentials: LightningCredentials) throws {
        try write(credentials.clientID, account: idAccount)
        try write(credentials.clientSecret, account: secretAccount)
    }

    public static func removeXweather() {
        delete(idAccount)
        delete(secretAccount)
    }

    enum KeychainError: LocalizedError {
        case status(Int32)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .status(let status): status == -1 ? "The credentials file couldn’t be written." : "The Keychain refused the change (status \(status))."
            case .unsupported: "Saving credentials needs the macOS Keychain. Set DREADCAST_XWEATHER_CLIENT_ID and DREADCAST_XWEATHER_CLIENT_SECRET instead."
            }
        }
    }

    #if canImport(Security)
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) throws {
        delete(account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "dreadcast \(account)",
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
    #else
    /// Without a Keychain, credentials live in their own file, created with owner-only
    /// permissions. They are still never written to config.json, the cache or output.
    static var credentialsFile: URL {
        Paths.resolve().configDirectory.appendingPathComponent("credentials.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: credentialsFile),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    static func save(_ values: [String: String]) throws {
        let directory = credentialsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(values)
        let temporary = directory.appendingPathComponent(".credentials-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw KeychainError.status(-1)
        }
        _ = try? FileManager.default.removeItem(at: credentialsFile)
        try FileManager.default.moveItem(at: temporary, to: credentialsFile)
    }

    static func read(_ account: String) -> String? { load()[account] }

    static func write(_ value: String, account: String) throws {
        var values = load()
        values[account] = value
        try save(values)
    }

    static func delete(_ account: String) {
        var values = load()
        guard values.removeValue(forKey: account) != nil else { return }
        if values.isEmpty {
            try? FileManager.default.removeItem(at: credentialsFile)
        } else {
            try? save(values)
        }
    }
    #endif
}
