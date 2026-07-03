import XCTest
@testable import Schrift

final class EditorViewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testUnderAMinuteIsSyncedJustNow() {
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base), "Synced just now")
        XCTAssertEqual(syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(59)), "Synced just now")
    }

    func testOlderThanAMinuteUsesRelativeWording() {
        let caption = syncStatusCaption(lastSyncedAt: base, now: base.addingTimeInterval(5 * 60))
        // RelativeDateTimeFormatter output is locale-dependent; pin the shape,
        // not the exact words.
        XCTAssertTrue(caption.hasPrefix("Synced "))
        XCTAssertNotEqual(caption, "Synced just now")
    }
}
