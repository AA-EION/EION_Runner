import Foundation
import Security

/// Secrets, in the macOS Keychain. Never in forge.json, never in a file, never
/// in an image.
///
/// Items are `kSecClassGenericPassword` with service `com.runnerforge.secrets`
/// and the key name as the account. The Windows twin uses Credential Manager
/// with target `RunnerForge:{keyName}`.
public struct SecretStore: Sendable {
    public static let service = "com.runnerforge.secrets"

    private let logBus: LogBus

    public init(logBus: LogBus) { self.logBus = logBus }

    /// The complete set of secret names this product stores.
    public static let keyNames = [
        "githubAppPrivateKey",
        "paceAccount",
        "pacePassword",
        "azureClientId",
        "azureClientSecret",
        "azureTenantId",
        "appleDevIdP12",
        "appleDevIdP12Password",
        "appleAscIssuerId",
        "appleAscKeyId",
        "appleAscPrivateKey",
    ]

    @discardableResult
    public func write(_ keyName: String, _ secret: String) async -> Bool {
        let data = Data(secret.utf8)

        // Replace rather than add-or-fail, so re-entering a credential works.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keyName,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Available after first unlock, and never synced to other devices: a
        // build credential has no business in iCloud Keychain.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)

        if status == errSecSuccess {
            // Registered so it can never appear in a log line from here on.
            await logBus.registerSecret(secret)
            await logBus.info("secrets", "stored '\(keyName)' in the Keychain")
            return true
        }

        await logBus.error("secrets", "could not store '\(keyName)': OSStatus \(status)")
        return false
    }

    public func read(_ keyName: String) async -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keyName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }

        await logBus.registerSecret(secret)
        return secret
    }

    @discardableResult
    public func delete(_ keyName: String) async -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keyName,
        ]

        let status = SecItemDelete(query as CFDictionary)
        await logBus.info("secrets", status == errSecSuccess
            ? "deleted '\(keyName)'"
            : "nothing to delete for '\(keyName)'")
        return status == errSecSuccess
    }

    public func has(_ keyName: String) async -> Bool {
        await read(keyName) != nil
    }

    /// Which secrets are present, for the Credentials page and the secrets
    /// checklist. Returns presence only — never a value.
    public func presence() async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for name in Self.keyNames { result[name] = await has(name) }
        return result
    }
}
