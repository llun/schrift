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
}
