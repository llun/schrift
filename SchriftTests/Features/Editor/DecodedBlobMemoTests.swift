import XCTest

@testable import Schrift

/// The memo is what makes a store read cheap, and it is only safe because it answers for the
/// exact bytes it decoded — these pin both halves.
final class DecodedBlobMemoTests: XCTestCase {
    private func decodeInt(_ data: Data) -> Int? {
        Int(String(decoding: data, as: UTF8.self))
    }

    func testEqualBytesAreDecodedOnce() {
        let memo = DecodedBlobMemo<Int>()
        var decodes = 0

        let first = memo.value(for: Data("42".utf8)) {
            decodes += 1
            return decodeInt($0)
        }
        // A separately built Data with the same contents — what a fresh UserDefaults read returns.
        let second = memo.value(for: Data("42".utf8)) {
            decodes += 1
            return decodeInt($0)
        }

        XCTAssertEqual(first, 42)
        XCTAssertEqual(second, 42)
        XCTAssertEqual(decodes, 1)
    }

    func testChangedBytesAreDecodedAgain() {
        let memo = DecodedBlobMemo<Int>()
        var decodes = 0
        let decode: (Data) -> Int? = { [self] data in
            decodes += 1
            return decodeInt(data)
        }

        XCTAssertEqual(memo.value(for: Data("1".utf8), decode: decode), 1)
        XCTAssertEqual(memo.value(for: Data("2".utf8), decode: decode), 2)
        XCTAssertEqual(memo.value(for: Data("1".utf8), decode: decode), 1, "never answers for other bytes")
        XCTAssertEqual(decodes, 3)
    }

    /// Undecodable is remembered as undecodable — never as an empty value — so a store's
    /// "unknown, not absent" check stays true on every read until the bytes change.
    func testUndecodableBytesStayUndecodable() {
        let memo = DecodedBlobMemo<Int>()
        var decodes = 0
        let decode: (Data) -> Int? = { [self] data in
            decodes += 1
            return decodeInt(data)
        }

        XCTAssertNil(memo.value(for: Data("not a number".utf8), decode: decode))
        XCTAssertNil(memo.value(for: Data("not a number".utf8), decode: decode))
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(memo.value(for: Data("7".utf8), decode: decode), 7)
    }
}
