import XCTest
@testable import DocsIOS

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore()
    private let key = "dev.llun.DocsIOS.test.keychainSmokeTest"

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
        let loaded = try store.load(forKey: "dev.llun.DocsIOS.test.doesNotExist")
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
        XCTAssertNoThrow(try store.delete(forKey: "dev.llun.DocsIOS.test.neverExisted"))
    }
}
