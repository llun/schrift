import Foundation

@testable import Schrift

final class FakeKeychainStore: KeychainStoring {
    private var storage: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func load(forKey key: String) throws -> Data? {
        storage[key]
    }

    func delete(forKey key: String) throws {
        storage.removeValue(forKey: key)
    }
}
