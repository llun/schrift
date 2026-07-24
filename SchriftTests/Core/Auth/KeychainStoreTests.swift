import XCTest

@testable import Schrift

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore()
    private let key = "dev.llun.Schrift.test.keychainSmokeTest"

    override func tearDownWithError() throws {
        try store.delete(forKey: key)
        try super.tearDownWithError()
    }

    func testSaveThenLoadRoundTripsInRealSimulatorKeychain() throws {
        let data = "hello-keychain".data(using: .utf8)!
        try store.save(data, forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertEqual(loaded, data)
    }

    func testLoadMissingKeyReturnsNil() throws {
        let loaded = try store.load(forKey: "dev.llun.Schrift.test.doesNotExist")
        XCTAssertNil(loaded)
    }

    func testSaveOverwritesExistingValue() throws {
        try store.save("first".data(using: .utf8)!, forKey: key)
        try store.save("second".data(using: .utf8)!, forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertEqual(loaded, "second".data(using: .utf8))
    }

    func testDeleteRemovesValue() throws {
        try store.save("temp".data(using: .utf8)!, forKey: key)
        try store.delete(forKey: key)
        let loaded = try store.load(forKey: key)
        XCTAssertNil(loaded)
    }

    func testDeleteOnMissingKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete(forKey: "dev.llun.Schrift.test.neverExisted"))
    }

    /// Reads back the attributes the item at `key` was actually stored with.
    /// `kSecAttrSynchronizableAny` makes the synchronizable attribute reliably
    /// present in the result so an assertion on it can't be vacuous.
    private func storedAttributes() throws -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testSavedItemIsThisDeviceOnlyAndNotSynchronized() throws {
        // Session credentials must not ride an encrypted backup onto another
        // device, and must never sync through iCloud.
        try store.save("secret".data(using: .utf8)!, forKey: key)
        let attributes = try storedAttributes()
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testOverwriteKeepsTheThisDeviceOnlyAccessibility() throws {
        // `save` deletes then adds, so the second write must re-apply the
        // accessibility class — an add that inherited the default would silently
        // downgrade a session stored by an earlier build.
        try store.save("first".data(using: .utf8)!, forKey: key)
        try store.save("second".data(using: .utf8)!, forKey: key)
        XCTAssertEqual(
            try storedAttributes()[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testUpgradeAccessibilityMigratesAnItemStoredWithTheOldDefault() throws {
        // Seed an item the way a build predating the ThisDeviceOnly baseline did:
        // a raw SecItemAdd under kSecAttrAccessibleWhenUnlocked (backup-eligible).
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: "legacy".data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(
            try storedAttributes()[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlocked as String,
            "precondition: item starts on the weaker class")

        store.upgradeAccessibility(forKey: key)

        XCTAssertEqual(
            try storedAttributes()[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        // The value must survive the in-place attribute rewrite.
        XCTAssertEqual(try store.load(forKey: key), "legacy".data(using: .utf8))
    }

    func testUpgradeAccessibilityOnMissingKeyDoesNotCreateAnItem() throws {
        // Best-effort: a user who was never signed in has no item to migrate.
        // SecItemUpdate must never *create* the item — that would materialise a
        // phantom credential.
        let missing = "dev.llun.Schrift.test.neverExisted"
        store.upgradeAccessibility(forKey: missing)
        XCTAssertNil(try store.load(forKey: missing))
    }
}
