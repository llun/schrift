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
                tx, into: root, after: nil,
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

    // MARK: - Structural (delete)

    func testDeleteMiddleRange() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 2, length: 2) }  // remove "cd"
        XCTAssertEqual(text(of: root), "abef")
        XCTAssertEqual(root.length, 4)
    }

    func testDeleteToTail() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 4, length: 2) }
        XCTAssertEqual(text(of: root), "abcd")
        XCTAssertEqual(root.length, 4)
    }

    func testDeleteFromHead() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 0, length: 2) }  // remove "ab"
        XCTAssertEqual(text(of: root), "cdef")
        XCTAssertEqual(root.length, 4)
    }

    func testDeleteEntireContent() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 0, length: 6) }
        XCTAssertEqual(text(of: root), "")
        XCTAssertEqual(root.length, 0)
    }

    func testDeleteZeroLengthIsNoOp() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 2, length: 0) }
        XCTAssertEqual(text(of: root), "abcdef")
        XCTAssertEqual(root.length, 6)
    }

    // MARK: - Structural (map set)

    func testMapSetCreatesAndOverwrites() throws {
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.mapSet(tx, on: root, key: "k", .any([.string("v1")])) }
        let old = root.map["k"]
        XCTAssertEqual(old?.content, .any([.string("v1")]))
        try doc.transact { tx in try YWrite.mapSet(tx, on: root, key: "k", .any([.string("v2")])) }
        XCTAssertEqual(root.map["k"]?.content, .any([.string("v2")]))
        XCTAssertEqual(root.map["k"]?.deleted, false)
        XCTAssertEqual(old?.deleted, true)
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

    /// Byte-exact against yjs 13.6.31. Regenerate with:
    ///
    ///     node -e "const Y=require('yjs');const d=new Y.Doc();d.clientID=7;\
    ///     const t=d.getText('t');Y.transact(d,()=>t.insert(0,'abcdef'));\
    ///     Y.transact(d,()=>t.delete(2,2));\
    ///     console.log(Buffer.from(Y.encodeStateAsUpdate(d)).toString('hex'))"
    ///
    /// Building `abcdef` then deleting the visible range `[2, 2)` ("cd") splits
    /// the single `ContentString` into `ab` (7,0) / `cd` (7,2) / `ef` (7,4), marks
    /// `cd` deleted, and records `[2, 2)` on the delete set — so the update carries
    /// the two surviving strings plus a one-range delete set. yjs's `ytext.delete`
    /// runs `deleteText`, but for pure strings (no `ContentFormat`) it is
    /// byte-identical to the `typeListDelete` that `YWrite.delete` transliterates.
    func testDeleteMatchesOracleBytes() throws {
        let expected = "0103070004010174026162810701028407030265660107010202"
        let doc = YDoc(clientID: 7)
        defer { doc.destroy() }
        let root = doc.get("t")
        try doc.transact { tx in try YWrite.insert(tx, into: root, at: 0, [.string(Array("abcdef".utf16))]) }
        try doc.transact { tx in try YWrite.delete(tx, from: root, at: 2, length: 2) }
        XCTAssertEqual(try YStateEncoder.encodeStateAsUpdate(doc).hexString, expected)
    }
}
