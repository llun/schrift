import XCTest

@testable import Schrift

/// The scroll handoff's state machine, which is the part of it that *can* be
/// tested.
///
/// The mechanism shipped broken twice before this — `.scrollPosition(id:)` never
/// aligning on free-scrolling content, then a `LazyVStack` clamping the restore
/// — and neither was reachable from here; both needed a build and a real
/// document. What *is* reachable is the contract this store keeps, and the last
/// test below is the one that matters: it pins the invariant the second bug was
/// about, where a torn-down `ScrollView`'s final geometry report of zero
/// overwrote the anchor with "the top" at exactly the moment it was read.
@MainActor
final class EditorScrollAnchorStoreTests: XCTestCase {

    func testSnapshotThenConsumeReturnsTheOffsetLastScrolledTo() {
        let store = EditorScrollAnchorStore()
        store.noteScrolled(to: 640)
        store.snapshotForSwap()

        XCTAssertEqual(store.consumePendingOffset(), 640)
    }

    /// Consuming clears it. Without that, a later appearance that is *not* a
    /// swap — popping back to the document, a tab switch — would re-apply an
    /// offset nobody asked for.
    func testASecondConsumeReturnsNothing() {
        let store = EditorScrollAnchorStore()
        store.noteScrolled(to: 640)
        store.snapshotForSwap()

        XCTAssertEqual(store.consumePendingOffset(), 640)
        XCTAssertNil(store.consumePendingOffset())
    }

    /// Nothing to restore until a swap has actually happened, so a surface
    /// appearing for the first time is left where it naturally starts.
    func testThereIsNothingToConsumeBeforeASwap() {
        let store = EditorScrollAnchorStore()
        store.noteScrolled(to: 640)

        XCTAssertNil(store.consumePendingOffset())
    }

    /// A swap from an unscrolled surface restores the top — `0`, not "no
    /// restore". The distinction matters: `nil` would leave the incoming
    /// surface wherever it happened to open.
    func testSwappingFromTheTopRestoresTheTopRatherThanNothing() {
        let store = EditorScrollAnchorStore()
        store.snapshotForSwap()

        XCTAssertEqual(store.consumePendingOffset(), 0)
    }

    /// **The invariant the whole design turns on.** A `ScrollView` being torn
    /// down reports a final geometry of zero, and that report lands *after* the
    /// swap has been snapshotted. It must not reach the pending value, or the
    /// incoming surface opens at the top of the document — which is exactly the
    /// bug this mechanism shipped with, and it looked correct in review because
    /// the offset was being recorded faithfully right up until the moment it
    /// was needed.
    func testATeardownReportOfZeroCannotOverwriteASnapshot() {
        let store = EditorScrollAnchorStore()
        store.noteScrolled(to: 640)
        store.snapshotForSwap()

        // The outgoing ScrollView's parting shot.
        store.noteScrolled(to: 0)

        XCTAssertEqual(store.consumePendingOffset(), 640)
    }

    func testFilteredSwapUsesMeasuredVisibleBlockRatherThanUnrelatedContentOffset() {
        let store = EditorScrollAnchorStore()
        let ids = (0..<4).map { _ in UUID() }
        store.noteScrolled(to: 640)
        store.noteBlockFrames([
            ids[0]: CGRect(x: 0, y: -90, width: 300, height: 40),
            ids[2]: CGRect(x: 0, y: -10, width: 300, height: 40),
            ids[3]: CGRect(x: 0, y: 42, width: 300, height: 40),
        ])
        store.snapshotForSwap(blockOrder: [ids[0], ids[2], ids[3]], restoringAmong: ids)
        store.noteBlockFrames([:])  // outgoing teardown cannot erase the snapshot
        store.noteScrolled(to: 0)
        XCTAssertEqual(store.consumePendingBlock(), ids[2])
        XCTAssertNil(store.consumePendingOffset())
        XCTAssertNil(store.consumePendingBlock())
    }

    func testDoneFromACompletedBlockChoosesTheNextSurvivingVisibleBlock() {
        let store = EditorScrollAnchorStore()
        let ids = (0..<4).map { _ in UUID() }
        store.noteScrolled(to: 300)
        store.noteBlockFrames([ids[1]: CGRect(x: 0, y: -10, width: 300, height: 40)])
        store.snapshotForSwap(blockOrder: ids, restoringAmong: [ids[0], ids[3]])
        XCTAssertEqual(store.consumePendingBlock(), ids[3])
    }

    func testFilteredSwapFallsBackToPreviousSurvivorOrTopForAllHiddenAndHeader() {
        let ids = (0..<3).map { _ in UUID() }
        let store = EditorScrollAnchorStore()
        store.noteScrolled(to: 300)
        store.noteBlockFrames([ids[2]: CGRect(x: 0, y: -10, width: 300, height: 40)])
        store.snapshotForSwap(blockOrder: ids, restoringAmong: [ids[0]])
        XCTAssertEqual(store.consumePendingBlock(), ids[0])
        store.snapshotForSwap(blockOrder: ids, restoringAmong: [])
        XCTAssertNil(store.consumePendingBlock())
        XCTAssertEqual(store.consumePendingOffset(), 0)
        store.noteScrolled(to: 0)
        store.snapshotForSwap(blockOrder: ids, restoringAmong: ids)
        XCTAssertNil(store.consumePendingBlock())
        XCTAssertEqual(store.consumePendingOffset(), 0)
    }
}
