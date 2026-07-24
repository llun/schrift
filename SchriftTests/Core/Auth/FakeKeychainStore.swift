import Foundation

@testable import Schrift

final class FakeKeychainStore: KeychainStoring {
    private var storage: [String: Data] = [:]
    /// Keys passed to `upgradeAccessibility`, in call order — lets a test assert
    /// the launch-time migration fires for exactly the right keys.
    private(set) var upgradedKeys: [String] = []

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func load(forKey key: String) throws -> Data? {
        storage[key]
    }

    func delete(forKey key: String) throws {
        storage.removeValue(forKey: key)
    }

    func upgradeAccessibility(forKey key: String) {
        upgradedKeys.append(key)
    }
}
