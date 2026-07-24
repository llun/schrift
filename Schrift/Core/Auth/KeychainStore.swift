import Foundation
import Security

protocol KeychainStoring {
    func save(_ data: Data, forKey key: String) throws
    func load(forKey key: String) throws -> Data?
    func delete(forKey key: String) throws
}

enum KeychainError: Error, Equatable {
    case unhandled(status: OSStatus)
}

struct KeychainStore: KeychainStoring {
    /// The accessibility class every item is stored with. Computed, not a stored
    /// `static let`, because `CFString` is not `Sendable` under Swift 6.
    ///
    /// Everything stored here is session credential material (the authenticated
    /// flag and the server cookie snapshot), which is meaningful only on the
    /// device that obtained it. `…ThisDeviceOnly` keeps it out of encrypted
    /// backups and device transfers, so a restored backup can't carry a live
    /// session onto another device; the cost is one re-login after a migration.
    /// `WhenUnlocked` (rather than a first-unlock class) is enough because the
    /// app only reads it while the user is in the foreground. Never add
    /// `kSecAttrSynchronizable` — that would sync sessions through iCloud.
    private static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    func save(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    func load(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
        return result as? Data
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }
}
