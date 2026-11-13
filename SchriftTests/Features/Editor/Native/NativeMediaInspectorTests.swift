import XCTest

@testable import Schrift

/// The media inspector's pure parts (PR13a review): its name and caption
/// fields never write a stale value back (F1), what Open opens (S3), and
/// what it shows of a peer's huge or odd values (S1, S4).
final class NativeMediaInspectorTests: XCTestCase {
    private func props(name: String = "", caption: String = "") -> [ProjectedProp] {
        [ProjectedProp(key: "name", value: .string(name)), ProjectedProp(key: "caption", value: .string(caption))]
    }

    /// Opened on an empty block, then an upload commits "photo.jpg": the
    /// untouched name field follows, so Done writes nothing.
    func testAnUploadsNameIsNotWipedByDone() {
        var draft = NativeMediaTextDraft()
        draft.follow(props())
        draft.follow(props(name: "photo.jpg"))
        XCTAssertEqual(draft.name, "photo.jpg")
        XCTAssertEqual(draft.edits(props(name: "photo.jpg")), [])
    }

    /// A peer's caption edit while the inspector is open survives Done; only
    /// the field the user changed is written.
    func testAPeersCaptionSurvivesAndOnlyTheUsersFieldIsWritten() {
        var draft = NativeMediaTextDraft()
        draft.follow(props(name: "a.png", caption: "Old"))
        draft.name = "mine.png"
        draft.follow(props(name: "a.png", caption: "From a peer"))
        XCTAssertEqual(draft.caption, "From a peer")
        XCTAssertEqual(draft.name, "mine.png", "the user's typing is kept")
        XCTAssertEqual(
            draft.edits(props(name: "a.png", caption: "From a peer")),
            [ProjectedProp(key: "name", value: .string("mine.png"))])
        // A field the user edited keeps their text when a peer changes it too.
        draft.caption = "Mine"
        draft.follow(props(name: "a.png", caption: "Again"))
        XCTAssertEqual(draft.caption, "Mine")
    }

    /// A peer's name or caption longer than a native edit may write is not
    /// editable (and never written back); display clips it by scalars, so a
    /// million combining marks in one character stay small.
    func testHugeValuesAreReadOnlyAndClipped() {
        var draft = NativeMediaTextDraft()
        let huge = String(repeating: "n", count: MediaBlock.maxName + 1)
        draft.follow(props(name: huge, caption: "c"))
        XCTAssertFalse(draft.canEditName)
        XCTAssertTrue(draft.canEditCaption)
        draft.name = "x"
        XCTAssertEqual(draft.edits(props(name: huge, caption: "c")), [])
        let marks = "e" + String(repeating: "\u{301}", count: 1_000_000)
        XCTAssertLessThanOrEqual(MediaBlock.clipped(marks).unicodeScalars.count, 301)
        XCTAssertEqual(MediaBlock.clipped("short"), "short")
    }

    /// A peer's width a native edit could not write (1e20, -1e19, 0.4) shows
    /// as unset and never traps; one in range is whole points.
    func testDisplayWidthNeverTraps() {
        func width(_ value: Double) -> Int? {
            MediaBlock.displayWidth([ProjectedProp(key: "previewWidth", value: BlockNoteWriter.number(value))])
        }
        XCTAssertNil(width(1e20))
        XCTAssertNil(width(-1e19))
        XCTAssertNil(width(0.4))
        XCTAssertEqual(width(320), 320)
        XCTAssertEqual(width(250.5), 251)
        XCTAssertNil(MediaBlock.displayWidth([]))
    }

    /// Open opens only what a native edit could write, and names its host:
    /// userinfo that disguises the host, a script or a relative path is refused.
    func testOpenRefusesDisguisedAndNonWebURLs() {
        XCTAssertEqual(NativeMediaInspector.openTarget("https://docs.example/a.pdf")?.host, "docs.example")
        for url in [
            "https://docs.example@evil.example/a.pdf", "https://user:pw@evil.example/", "javascript:alert(1)",
            "data:text/html,x", "/media/a.pdf", "https://exämple.com/a",
        ] {
            XCTAssertNil(NativeMediaInspector.openTarget(url), url)
        }
    }
}
