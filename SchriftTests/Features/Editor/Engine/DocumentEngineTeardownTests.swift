import XCTest

@testable import Schrift

/// The owner destroys the replica on a fail-safe and on a suspend teardown.
/// The engine borrowed it, so it must let go: no hook into a destroyed store,
/// no patch built from one, and no crash on a later call.
@MainActor
final class DocumentEngineTeardownTests: DocumentEngineTestCase {
    func testDestroyingTheReplicaDetachesTheEngine() throws {
        let doc = try makeDoc(clientID: 1)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)

        doc.destroy()

        XCTAssertTrue(engine.isDetached)
        XCTAssertNil(doc.afterTransaction)
        XCTAssertNil(doc.afterAllTransactions)
        XCTAssertNil(doc.onDestroy)
    }

    func testADetachedEngineDeliversNothingAndDoesNotTouchTheStore() throws {
        let doc = try makeDoc(clientID: 1)
        let surface = HeadlessSurface(blocks: projection(doc))
        let engine = DocumentEngine(doc: doc, surface: surface)
        let patchesBefore = surface.appliedPatches.count

        doc.destroy()
        // A remote update after teardown is a no-op, not a use-after-destroy.
        try engine.applyRemoteUpdate(Data([0, 0]))

        XCTAssertEqual(surface.appliedPatches.count, patchesBefore)
        XCTAssertTrue(surface.blocks.isEmpty == false, "the surface keeps what it was showing")
    }

    func testDetachIsIdempotentAndRestoresThePreviousHook() throws {
        let doc = try makeDoc(clientID: 1)
        var seen = 0
        doc.afterTransaction = { _ in seen += 1 }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface(blocks: projection(doc)))

        engine.detach()
        engine.detach()

        XCTAssertTrue(engine.isDetached)
        XCTAssertNotNil(doc.afterTransaction, "the engine restores the hook it borrowed over")
        try doc.transact { _ in }
        XCTAssertEqual(seen, 1)
        doc.destroy()
    }
}
