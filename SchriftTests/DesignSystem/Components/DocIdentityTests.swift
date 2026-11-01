import SwiftUI
import XCTest

@testable import Schrift

final class DocIdentityTests: XCTestCase {
    // MARK: - Leading emoji

    func testLeadingEmojiIsSplitFromTitle() {
        XCTAssertEqual(
            docTitleParts("🚀 Release checklist"), DocTitleParts(emoji: "🚀", title: "Release checklist"))
    }

    func testLeadingEmojiWithoutSpaceIsSplit() {
        XCTAssertEqual(docTitleParts("📝Notes"), DocTitleParts(emoji: "📝", title: "Notes"))
    }

    func testZWJSequenceAndFlagStayWholeEmoji() {
        XCTAssertEqual(
            docTitleParts("👩‍💻 Standup"), DocTitleParts(emoji: "👩‍💻", title: "Standup"))
        XCTAssertEqual(docTitleParts("🇹🇭 Trip"), DocTitleParts(emoji: "🇹🇭", title: "Trip"))
    }

    func testVariationSelectorAndKeycapEmojiAreRecognised() {
        XCTAssertEqual(docTitleParts("❤️ Love"), DocTitleParts(emoji: "❤️", title: "Love"))
        XCTAssertEqual(docTitleParts("1️⃣ First"), DocTitleParts(emoji: "1️⃣", title: "First"))
    }

    func testDigitsAndPunctuationAreNotEmoji() {
        XCTAssertEqual(docTitleParts("2024 plan"), DocTitleParts(emoji: nil, title: "2024 plan"))
        XCTAssertEqual(docTitleParts("#todo"), DocTitleParts(emoji: nil, title: "#todo"))
        XCTAssertEqual(docTitleParts("*bold*"), DocTitleParts(emoji: nil, title: "*bold*"))
    }

    func testEmojiNotAtTheStartIsKept() {
        XCTAssertEqual(docTitleParts("Trip ✈️ plan"), DocTitleParts(emoji: nil, title: "Trip ✈️ plan"))
    }

    func testEmojiOnlyTitleIsLeftWhole() {
        XCTAssertEqual(docTitleParts("🚀"), DocTitleParts(emoji: nil, title: "🚀"))
        XCTAssertEqual(docTitleParts("🚀  "), DocTitleParts(emoji: nil, title: "🚀  "))
    }

    func testNilAndEmptyTitles() {
        XCTAssertEqual(docTitleParts(nil), DocTitleParts(emoji: nil, title: ""))
        XCTAssertEqual(docTitleParts(""), DocTitleParts(emoji: nil, title: ""))
    }

    // MARK: - Tile tint

    func testTintIsDeterministicForAnId() throws {
        let id = try XCTUnwrap(UUID(uuidString: "E0B8A8B0-1C2D-4F3A-9A7B-0123456789AB"))
        XCTAssertEqual(docTileTintIndex(for: id), docTileTintIndex(for: id))
        XCTAssertEqual(docTileTintIndex(for: id), 5)
        let again = try XCTUnwrap(UUID(uuidString: "e0b8a8b0-1c2d-4f3a-9a7b-0123456789ab"))
        XCTAssertEqual(docTileTintIndex(for: again), docTileTintIndex(for: id))
    }

    func testTintIndexesMatchTheAvatarPalette() throws {
        for (suffix, expected) in [("1", 1), ("2", 2), ("3", 3)] {
            let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(suffix)"))
            XCTAssertEqual(docTileTintIndex(for: id), expected)
            XCTAssertEqual(docTileTint(for: id).light, avatarColorPalette[expected].light)
            XCTAssertEqual(docTileTint(for: id).dark, avatarColorPalette[expected].dark)
        }
    }

    func testTintAlwaysComesFromThePaletteAndSpreads() {
        var seen = Set<Int>()
        for _ in 0..<200 {
            let index = docTileTintIndex(for: UUID())
            XCTAssertTrue((0..<avatarColorPalette.count).contains(index))
            seen.insert(index)
        }
        XCTAssertGreaterThan(seen.count, 4, "random ids should land on most of the palette")
    }

    // MARK: - Row text helpers

    func testExcerptCollapsesWhitespaceAndDropsBlank() {
        XCTAssertEqual(docRowExcerptText("Decided to ship\n\nthe  chips   Friday "), "Decided to ship the chips Friday")
        XCTAssertNil(docRowExcerptText(nil))
        XCTAssertNil(docRowExcerptText(""))
        XCTAssertNil(docRowExcerptText(" \n\t "))
    }

    func testTitleLineLimit() {
        XCTAssertEqual(docRowTitleLineLimit(hasDetailLine: false, isStacked: false), 1)
        XCTAssertEqual(docRowTitleLineLimit(hasDetailLine: true, isStacked: false), 2)
        XCTAssertEqual(docRowTitleLineLimit(hasDetailLine: true, isStacked: true), 3)
        XCTAssertEqual(docRowTitleLineLimit(hasDetailLine: false, isStacked: true), 3)
    }

    // MARK: - Accessibility label

    func testAccessibilityLabelPlacesExcerptLast() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Trip", excerpt: "Flights booked", reach: .restricted, date: "Thu",
                pageCountLabel: "4 pages", pinned: true, pinnedLabel: "Pinned",
                sharedWithOrganizationLabel: "Shared with organization", publicLabel: "Public"),
            "Trip, Pinned, Thu, 4 pages, Flights booked"
        )
    }

    func testAccessibilityLabelCapsALongExcerpt() {
        // 195 characters. The first 100 hold two whole sentences and the start of a third, so
        // the cut lands on the space after the second sentence's "call." (char 97).
        let sentence = "Decisions and follow-ups from the planning call."
        let excerpt = Array(repeating: sentence, count: 4).joined(separator: " ")
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Trip", excerpt: excerpt, reach: .public, date: "Thu", pinned: false,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Trip, Public, Thu, \(sentence) \(sentence)…"
        )
    }

    func testSpokenExcerptReturnsAnExcerptThatFitsUnchanged() {
        XCTAssertEqual(docRowSpokenExcerpt("Flights booked"), "Flights booked")
        let exactlyTheLimit = String(repeating: "a", count: 100)
        XCTAssertEqual(docRowSpokenExcerpt(exactlyTheLimit), exactlyTheLimit)
    }

    func testSpokenExcerptCutsAtTheLastWordBoundaryWithAnEllipsis() {
        // 149 characters. The first 100 are twenty "word " units, so the last space inside the
        // limit is at index 99 and the cut keeps the twenty whole words before it: 99 characters
        // plus the ellipsis.
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        let expected = Array(repeating: "word", count: 20).joined(separator: " ") + "…"
        XCTAssertEqual(docRowSpokenExcerpt(words), expected)
    }

    func testSpokenExcerptCutsAnUnbrokenRunAtTheLimit() {
        let run = String(repeating: "x", count: 150)
        XCTAssertEqual(docRowSpokenExcerpt(run), String(repeating: "x", count: 100) + "…")
    }

    func testAccessibilityLabelOmitsEmptyExcerptAndPageCount() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Trip", excerpt: "", reach: .public, date: "Thu", pageCountLabel: "",
                pinned: false, pinnedLabel: "Pinned",
                sharedWithOrganizationLabel: "Shared with organization", publicLabel: "Public"),
            "Trip, Public, Thu"
        )
    }

    // MARK: - Pinned shelf

    func testPinnedShelfOnlyOnPageCanvasBelowAccessibilitySizes() {
        XCTAssertTrue(pinnedShelfIsEnabled(canvasRole: .page, dynamicTypeSize: .large))
        XCTAssertTrue(pinnedShelfIsEnabled(canvasRole: .page, dynamicTypeSize: .xxxLarge))
        XCTAssertFalse(pinnedShelfIsEnabled(canvasRole: .page, dynamicTypeSize: .accessibility1))
        XCTAssertFalse(pinnedShelfIsEnabled(canvasRole: .sidebar, dynamicTypeSize: .large))
    }
}

@MainActor
final class DocRowPageCountTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "DocRowPageCountTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testNoBadgeWithoutSubpages() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        XCTAssertNil(docRowPageCountLabel(0, loc: store))
        XCTAssertNil(docRowPageCountLabel(-1, loc: store))
    }

    func testEnglishSingularAndPlural() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        XCTAssertEqual(docRowPageCountLabel(1, loc: store), "1 page")
        XCTAssertEqual(docRowPageCountLabel(4, loc: store), "4 pages")
    }

    func testSlovenePluralForms() {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .slovene
        XCTAssertEqual(docRowPageCountLabel(1, loc: store), "1 stran")
        XCTAssertEqual(docRowPageCountLabel(2, loc: store), "2 strani")
        XCTAssertEqual(docRowPageCountLabel(3, loc: store), "3 strani")
        XCTAssertEqual(docRowPageCountLabel(5, loc: store), "5 strani")
    }
}
