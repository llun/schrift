import Foundation
import Security

protocol KeychainStoring {
    func save(_ data: Data, forKey key: String) throws
    func load(forKey key: String) throws -> Data?
    func delete(forKey key: String) throws
    /// Re-applies the store's current accessibility class to an item written by
    /// an earlier build. Best-effort and silent: a missing item, or a backend
    /// that refuses, must never block launch. Default no-op so test doubles and
    /// non-Keychain conformances don't have to model it.
    func upgradeAccessibility(forKey key: String)
}

extension KeychainStoring {
    func upgradeAccessibility(forKey key: String) {}
}

enum KeychainError: Error, Equatable {
    case unhandled(status: OSStatus)
}

struct KeychainStore: KeychainStoring {
    /// Stores under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
    ///
    /// Everything here is session credential material (the authenticated flag and
    /// the server cookie snapshot), meaningful only on the device that obtained
    /// it. `…ThisDeviceOnly` keeps it out of encrypted backups and device
    /// transfers, so a restored backup can't carry a live session onto another
    /// device; the cost is one re-login after a migration. The lock-state half is
    /// unchanged — `SecItemAdd`'s default was already `WhenUnlocked` — and it is
    /// enough because every read happens while the app is foreground
    /// (`SessionStore.init`, during scene setup). **If a Keychain write or read
    /// ever moves onto a background-task path** (the only background assertion
    /// today is `DocumentSaveCoordinator`'s, which touches cookies already
    /// resident in `HTTPCookieStorage`, not the Keychain) **this must become
    /// `…AfterFirstUnlockThisDeviceOnly`.** Never add `kSecAttrSynchronizable` —
    /// that would sync sessions through iCloud.
    ///
    /// The class is re-applied on *every* save because `save` is delete-then-add:
    /// an add that inherited the default would silently downgrade the item.
    func save(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    /// Migrates an item written before the `ThisDeviceOnly` baseline existed.
    ///
    /// Without this the hardening would only ever apply to *new* writes, and an
    /// already-signed-in user would keep a backup-eligible session indefinitely —
    /// Django sessions are long-lived, so nothing re-saves until an explicit
    /// sign-out or a 401. `SecItemUpdate` rewrites the attribute in place, so
    /// there is no window where the credential is absent (unlike delete-then-add).
    func upgradeAccessibility(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
