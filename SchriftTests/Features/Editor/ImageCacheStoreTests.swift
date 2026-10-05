import XCTest

@testable import Schrift

final class ImageCacheStoreTests: XCTestCase {
    private var directory: URL!
    private let scope = ImageCacheScope(serverOrigin: "https://docs.example.org", sessionID: UUID())
    private let url = URL(string: "https://docs.example.org/media/photo.png?revision=1")!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testColdStoreReadsPreviouslyWrittenBytesAndExcludesBackups() throws {
        let cache = ImageCacheStore(directory: directory)
        let file = try XCTUnwrap(cache.store(testPNGData(width: 10, height: 10), for: url, scope: scope))
        let cold = ImageCacheStore(directory: directory)
        XCTAssertEqual(cold.cachedFileURL(for: url, scope: scope), file)
        XCTAssertEqual(try Data(contentsOf: file), testPNGData(width: 10, height: 10))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testServerAccountAndEntireURLArePartOfIdentity() {
        let cache = ImageCacheStore(directory: directory)
        XCTAssertNotNil(cache.store(testPNGData(width: 10, height: 10), for: url, scope: scope))
        let otherAccount = ImageCacheScope(serverOrigin: scope.serverOrigin, sessionID: UUID())
        let otherServer = ImageCacheScope(serverOrigin: "https://other.example.org", sessionID: scope.sessionID)
        XCTAssertNil(cache.cachedFileURL(for: url, scope: otherAccount))
        XCTAssertNil(cache.cachedFileURL(for: url, scope: otherServer))
        XCTAssertNil(
            cache.cachedFileURL(for: URL(string: "https://docs.example.org/media/photo.png?revision=2")!, scope: scope))
    }

    func testStrictByteAndCountCapsEvictOldEntries() throws {
        let bytes = testPNGData(width: 10, height: 10)
        let cache = ImageCacheStore(directory: directory, countLimit: 2, byteLimit: bytes.count * 2)
        let first = try XCTUnwrap(cache.store(bytes, for: url, scope: scope))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: first.path)
        let secondURL = URL(string: "https://docs.example.org/second")!
        let second = try XCTUnwrap(cache.store(bytes, for: secondURL, scope: scope))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: second.path)
        XCTAssertNotNil(cache.store(bytes, for: URL(string: "https://docs.example.org/third")!, scope: scope))
        XCTAssertNil(cache.cachedFileURL(for: url, scope: scope))
        XCTAssertNotNil(cache.cachedFileURL(for: secondURL, scope: scope))
        XCTAssertNil(cache.store(Data(repeating: 4, count: bytes.count * 2 + 1), for: url, scope: scope))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 2)
        XCTAssertLessThanOrEqual(
            try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }, bytes.count * 2)
    }

    func testReadTouchesRecencyAndRemovedFileIsAMiss() throws {
        let cache = ImageCacheStore(directory: directory)
        let file = try XCTUnwrap(cache.store(testPNGData(width: 10, height: 10), for: url, scope: scope))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        XCTAssertNotNil(cache.cachedFileURL(for: url, scope: scope))
        XCTAssertGreaterThan(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!, .distantPast)
        cache.removeAll()
        XCTAssertNil(cache.cachedFileURL(for: url, scope: scope))
    }
}
