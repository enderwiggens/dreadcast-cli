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
        return read(idAccount) != nil ? "Keychain" : nil
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
            case .status(let status): "The Keychain refused the change (status \(status))."
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
    static func read(_ account: String) -> String? { nil }
    static func write(_ value: String, account: String) throws { throw KeychainError.unsupported }
    static func delete(_ account: String) {}
    #endif
}
