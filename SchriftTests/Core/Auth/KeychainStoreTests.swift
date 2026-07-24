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

    func testSavedItemIsThisDeviceOnlyAndNotSynchronized() throws {
        // Session credentials must not ride an encrypted backup onto another
        // device, and must never sync through iCloud. Read the attributes the
        // item was actually stored with rather than trusting the save query.
        try store.save("secret".data(using: .utf8)!, forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func testOverwriteKeepsTheThisDeviceOnlyAccessibility() throws {
        // `save` deletes then adds, so the second write must re-apply the
        // accessibility class — an add that inherited the default would silently
        // downgrade a session stored by an earlier build.
        try store.save("first".data(using: .utf8)!, forKey: key)
        try store.save("second".data(using: .utf8)!, forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
