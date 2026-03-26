import Foundation
import Security
import CryptoKit

/// Secure persistence for Ed25519 keys in the iOS Keychain.
enum KeychainStore {
    private static let serviceName = "\(NetworkConfig.keychainPrefix).keys"

    enum KeyTag: String {
        case accountPrivate = "com.mycellm.account.private"
        case devicePrivate = "com.mycellm.device.private"
        // Note: raw values are fixed strings (Keychain identifiers can't change after first use
        // or existing keys become inaccessible). Forks should update these before first launch.
    }

    // MARK: - Save

    static func saveAccountKey(_ key: AccountKey) throws {
        try save(
            tag: .accountPrivate,
            data: Data(key.privateKey.rawRepresentation)
        )
    }

    static func saveDeviceKey(_ key: DeviceKey) throws {
        try save(
            tag: .devicePrivate,
            data: Data(key.privateKey.rawRepresentation)
        )
    }

    // MARK: - Load

    static func loadAccountKey() -> AccountKey? {
        guard let data = load(tag: .accountPrivate),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return AccountKey(privateKey: pk)
    }

    static func loadDeviceKey() -> DeviceKey? {
        guard let data = load(tag: .devicePrivate),
              let pk = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return DeviceKey(privateKey: pk)
    }

    // MARK: - Delete

    static func deleteKey(tag: KeyTag) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tag.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        deleteKey(tag: .accountPrivate)
        deleteKey(tag: .devicePrivate)
    }

    // MARK: - Internals

    private static func save(tag: KeyTag, data: Data) throws {
        // Delete existing first
        deleteKey(tag: tag)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tag.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MycellmError.keychainError(status)
        }
    }

    private static func load(tag: KeyTag) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tag.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
