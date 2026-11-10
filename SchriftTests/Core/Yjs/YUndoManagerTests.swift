import XCTest

@testable import Schrift

/// `YUndoManager` behaviour the yjs oracle (`YUndoManagerOracleTests`) does not
/// pin: origin/scope filters, events and `meta`, `keep`/gc, and the undo
/// transaction's own update.
final class YUndoManagerTests: XCTestCase {

    private func text(_ type: YType) -> String {
        var out: [UInt16] = []
        var item = type.start
        while let current = item {
            if !current.deleted, case .string(let units) = current.content { out += units }
            item = current.right
        }
        return String(decoding: out, as: UTF16.self)
    }

    func testOnlyTrackedOriginsInScopeAreCaptured() throws {
        let doc = YDoc(clientID: 1)
        defer { doc.destroy() }
        let tracked = doc.getText("t")
        let other = doc.getText("other")
        let um = YUndoManager(doc: doc, scope: [tracked])

        try doc.transact(origin: .remote) { tx in
            try YTextOps.insertText(tx, tracked, try YTextOps.findPosition(tx, tracked, index: 0), .text("r"), [:])
        }
        try doc.transact(origin: .localUser) { tx in
            try YTextOps.insertText(tx, tracked, try YTextOps.findPosition(tx, tracked, index: 0), .text("l"), [:])
        }
        try other.insert(0, "out of scope")
        XCTAssertFalse(um.canUndo)

        um.trackedOrigins.insert(.localUser)
        try doc.transact(origin: .localUser) { tx in
            try YTextOps.insertText(tx, tracked, try YTextOps.findPosition(tx, tracked, index: 0), .text("x"), [:])
        }
        XCTAssertEqual(um.undoStack.count, 1)
        try um.undo()
        XCTAssertEqual(text(tracked), "lr")
        XCTAssertEqual(text(other), "out of scope")
    }

    func testCaptureTransactionAndDeleteFilter() throws {
        let doc = YDoc(clientID: 1)
        defer { doc.destroy() }
        let t = doc.getText("t")
        let um = YUndoManager(doc: doc, scope: [t], captureTimeout: 0, deleteFilter: { _ in false })
        um.captureTransaction = { _ in false }
        try t.insert(0, "kept")
        XCTAssertFalse(um.canUndo)
        um.captureTransaction = { _ in true }
        try t.insert(0, "is ")
        XCTAssertEqual(um.undoStack.count, 1)
        // The filter refuses the deletion, so nothing changed and nothing is popped.
        XCTAssertNil(try um.undo())
        XCTAssertEqual(text(t), "is kept")
        XCTAssertFalse(um.canUndo)
    }

    func testEventsAndMetaSurviveAPop() throws {
        let doc = YDoc(clientID: 1)
        defer { doc.destroy() }
        let t = doc.getText("t")
        let um = YUndoManager(doc: doc, scope: [t], captureTimeout: .infinity)
        var log: [String] = []
        um.onStackItemAdded = { event in
            log.append("added \(event.type) \(event.origin == um.origin)")
            event.stackItem.meta["selection"] = 3
        }
        um.onStackItemUpdated = { log.append("updated \($0.type)") }
        um.onStackItemPopped = { log.append("popped \($0.type) \($0.stackItem.meta["selection"] as? Int ?? -1)") }
        um.onStackCleared = { log.append("cleared \($0) \($1)") }

        try t.insert(0, "a")
        try t.insert(1, "b")  // merged: within the capture timeout
        try um.undo()
        try um.redo()
        try um.clear()
        XCTAssertEqual(
            log,
            [
                "added undo false", "updated undo", "added redo true", "popped undo 3",
                "added undo true", "popped redo 3", "cleared true true",
            ])
    }

    func testKeepHoldsDeletionsUntilClear() throws {
        let doc = YDoc(clientID: 1)
        defer { doc.destroy() }
        let t = doc.getText("t")
        try t.insert(0, "abc")
        let um = YUndoManager(doc: doc, scope: [t])
        try t.delete(0, 3)
        let deleted = try XCTUnwrap(doc.store.clients[1]?.structs.first as? YItem)
        XCTAssertTrue(deleted.deleted)
        XCTAssertTrue(deleted.keep)
        guard case .string = deleted.content else { return XCTFail("a kept item must not be gc'd") }

        // destroy() only unsubscribes (yjs): the stack and its keep marks stay.
        um.destroy()
        try t.insert(0, "x")
        XCTAssertEqual(um.undoStack.count, 1)
        XCTAssertTrue(deleted.keep)

        try um.clear()
        XCTAssertFalse(deleted.keep)
        try YDoc.tryGcDeleteSet(YDeleteSet.from(store: doc.store), doc.store)
        guard case .deleted = deleted.content else { return XCTFail("released item should gc") }
    }

    /// Schrift's bounded-history addition: only the oldest items go, and their
    /// `keep` marks are released like `clear()`'s.
    func testTrimDropsTheOldestItemsAndReleasesTheirKeep() throws {
        let doc = YDoc(clientID: 1)
        defer { doc.destroy() }
        let t = doc.getText("t")
        try t.insert(0, "abc")
        let um = YUndoManager(doc: doc, scope: [t], captureTimeout: 0)
        try t.delete(0, 3)
        let deleted = try XCTUnwrap(doc.store.clients[1]?.structs.first as? YItem)
        try t.insert(0, "x")
        try t.insert(1, "y")
        XCTAssertEqual(um.undoStack.count, 3)
        XCTAssertTrue(deleted.keep)

        try um.trimUndoStack(to: 2)
        XCTAssertEqual(um.undoStack.count, 2)
        XCTAssertFalse(deleted.keep, "the dropped deletion may be gc'd")
        try um.undo()
        try um.undo()
        XCTAssertFalse(um.canUndo)
        XCTAssertEqual(text(t), "", "the dropped step is never undone")
        try um.trimUndoStack(to: 5)
        XCTAssertTrue(um.canRedo, "trim never touches the redo stack")
    }

    func testUndoIsALocalTransactionAPeerCanApply() throws {
        let doc1 = YDoc(clientID: 1)
        let doc2 = YDoc(clientID: 2)
        defer {
            doc1.destroy()
            doc2.destroy()
        }
        let t1 = doc1.getText("t")
        let t2 = doc2.getText("t")
        try t1.insert(0, "Hello")
        let um = YUndoManager(doc: doc1, scope: [t1])
        try t1.insert(5, " World")
        try doc2.applyUpdate(try YUpdateDecoder.decode(try YStateEncoder.encodeStateAsUpdate(doc1)))

        var updates: [Data] = []
        doc1.onUpdate = { origin, encode in
            if origin == um.origin, let data = encode() { updates.append(data) }
        }
        try um.undo()
        XCTAssertEqual(doc1.lastTransactionOrigin, um.origin)
        XCTAssertEqual(updates.count, 1)
        try doc2.applyUpdate(try YUpdateDecoder.decode(updates[0]))
        XCTAssertEqual(text(t2), "Hello")

        updates = []
        try um.redo()
        try doc2.applyUpdate(try YUpdateDecoder.decode(updates[0]))
        XCTAssertEqual(text(t2), "Hello World")
    }
}
