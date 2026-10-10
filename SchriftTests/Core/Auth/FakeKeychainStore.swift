import Foundation

@testable import Schrift

final class FakeKeychainStore: KeychainStoring {
    var failingSaveKeys: Set<String> = []
    private var storage: [String: Data] = [:]
    /// Keys passed to `upgradeAccessibility`, in call order — lets a test assert
    /// the launch-time migration fires for exactly the right keys.
    private(set) var upgradedKeys: [String] = []
    /// Successful `save` calls per key — lets a test assert a write was skipped.
    private(set) var saveCounts: [String: Int] = [:]

    func save(_ data: Data, forKey key: String) throws {
        if failingSaveKeys.contains(key) { throw NSError(domain: "FakeKeychain", code: 1) }
        storage[key] = data
        saveCounts[key, default: 0] += 1
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
