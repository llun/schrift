import XCTest

@testable import Schrift

/// Tests for the first local mutation primitive, `YWrite` (B6). Two layers:
/// fast, oracle-free structural assertions over the resulting child list, and a
/// byte-exact round trip through `YStateEncoder` pinned to hex captured from the
/// yjs 13.6.31 oracle (`new Y.Doc()`, `gc` on).
final class YWriteTests: XCTestCase {

    /// Visible text of an xmlText-like type's child list (concatenated
    /// `ContentString` units of undeleted children).
    private func text(of type: YType) -> String {
        var out: [UInt16] = []
        var item = type.start
        while let cur = item {
            if !cur.deleted, case .string(let u) = cur.content { out += u }
            item = cur.right
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: - Structural

    func testInsertAtHeadIntoEmptyType() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in
            try YWrite.insert(tx, into: root, at: 0, [.string(Array("hello".utf16))])
        }
        XCTAssertEqual(text(of: root), "hello")
        XCTAssertEqual(root.length, 5)
    }

    func testInsertInMiddleSplitsAndChains() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("hexo".utf16))]) }
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 2, [.string(Array("LL".utf16))]) }
        XCTAssertEqual(text(of: root), "heLLxo")
        XCTAssertEqual(root.length, 6)
    }

    func testInsertAppendsAtTail() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("ab".utf16))]) }
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 2, [.string(Array("cd".utf16))]) }
        XCTAssertEqual(text(of: root), "abcd")
        XCTAssertEqual(root.length, 4)
    }

    func testInsertAfterReturnsLastItem() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in
            let last = try YWrite.insertAfter(
                tx, into: root, after: nil, parentSub: nil,
                [.string(Array("ab".utf16)), .string(Array("cd".utf16))])
            XCTAssertNotNil(last)
            // The last minted item carries the second string and sits at clock 2.
            if case .string(let u) = last!.content {
                XCTAssertEqual(String(decoding: u, as: UTF16.self), "cd")
            } else {
                XCTFail("expected a ContentString")
            }
            XCTAssertEqual(last!.id.clock, 2)
        }
        XCTAssertEqual(text(of: root), "abcd")
    }

    func testInsertBeyondLengthThrows() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("ab".utf16))]) }
        do {
            try doc.transact { tx in try YWrite.insert(tx, into: root, at: 3, [.string(Array("x".utf16))]) }
            XCTFail("expected an out-of-range index to throw")
        } catch let error as YIntegrationError {
            XCTAssertEqual(error, .unexpectedCase)
        }
        // The rejected insert left the type untouched.
        XCTAssertEqual(text(of: root), "ab")
    }

    // MARK: - Oracle byte round trip

    /// Byte-exact against yjs 13.6.31. Regenerate with:
    ///
    ///     node -e "const Y=require('yjs');const d=new Y.Doc();d.clientID=7;\
    ///     const t=d.getText('t');Y.transact(d,()=>t.insert(0,'hexo'));\
    ///     Y.transact(d,()=>t.insert(2,'LL'));\
    ///     console.log(Buffer.from(Y.encodeStateAsUpdate(d)).toString('hex'))"
    ///
    /// The two same-client inserts settle as three `ContentString` items — `he`
    /// (7,0), `xo` (7,2), `LL` (7,4) — because the middle insert splits `hexo` and
    /// the linked-list order no longer matches clock order, so no cleanup merge
    /// applies (yjs behaves identically). Schrift's `doc.get("t")` bare root maps to
    /// yjs's `getText('t')` root, referenced by name.
    func testTwoInsertsMatchOracleBytes() throws {
        let expected = "010307000401017402686584070102786fc407010702024c4c00"
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("hexo".utf16))]) }
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 2, [.string(Array("LL".utf16))]) }
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc).hexString, expected)
    }
}
