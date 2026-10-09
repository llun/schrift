import XCTest

@testable import Schrift

final class AvatarTests: XCTestCase {
    func testInitialsUsesFirstLetterOfFirstTwoWords() {
        XCTAssertEqual(avatarInitials(for: "Camille Moreau"), "CM")
        XCTAssertEqual(avatarInitials(for: "Alfredo Levin"), "AL")
    }

    func testInitialsHandlesSingleWord() {
        XCTAssertEqual(avatarInitials(for: "Cher"), "C")
    }

    func testInitialsUsesFirstAndLastWordForThreeParts() {
        XCTAssertEqual(avatarInitials(for: "Jean Pierre Dupont"), "JD")
    }

    func testInitialsFallBackToAQuestionMarkWhenThereIsNoLetterToShow() {
        XCTAssertEqual(avatarInitials(for: ""), "?")
        XCTAssertEqual(avatarInitials(for: "   "), "?")
    }

    func testInitialsIgnoreExtraSpacesAndUppercaseLowercaseNames() {
        XCTAssertEqual(avatarInitials(for: "  ada    byron   lovelace "), "AL")
    }

    func testInitialsTakeTheFirstUserPerceivedCharacterOfNonLatinNames() {
        XCTAssertEqual(avatarInitials(for: "😀 Smile"), "😀S")
        XCTAssertEqual(avatarInitials(for: "สมชาย ใจดี"), "สใ")
        XCTAssertEqual(avatarInitials(for: "王小明"), "王")
        XCTAssertEqual(avatarInitials(for: "李 雷"), "李雷")
    }

    // Indices mirror the prototype's ACCENTS hash (h = h*31 + charCode, mod 8).
    // `avatarColorHex` returns the LIGHT hex, so the mapping is unchanged in light mode.
    func testColorHexMatchesExpectedPaletteIndexAndIsDeterministic() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorHex(for: "Camille Moreau"))
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorPalette[6].light)
        XCTAssertEqual(avatarColorHex(for: "Amandine Salambo"), avatarColorPalette[4].light)
        XCTAssertEqual(avatarColorHex(for: "Desirae Dokidis"), avatarColorPalette[4].light)
        XCTAssertEqual(avatarColorHex(for: "Alfredo Levin"), avatarColorPalette[3].light)
        XCTAssertEqual(avatarColorHex(for: "Charlie Saris"), avatarColorPalette[0].light)
    }

    func testColorHexFallsBackToFirstPaletteEntryForEmptyName() {
        XCTAssertEqual(avatarColorHex(for: ""), avatarColorPalette[0].light)
    }

    // The `#rrggbb` string is what we broadcast as our live-collaboration
    // awareness colour; it must be the same hue as the avatar, six lowercase
    // hex digits, zero-padded.
    func testColorHexStringMatchesTheAvatarLightHex() {
        let name = "Camille Moreau"
        XCTAssertEqual(avatarColorHexString(for: name), String(format: "#%06x", avatarColorHex(for: name) & 0xFF_FFFF))
    }

    func testColorHexStringIsSixLowercaseHexDigits() {
        let hex = avatarColorHexString(for: "Alfredo Levin")
        XCTAssertEqual(hex.count, 7)  // "#" + 6 digits
        XCTAssertEqual(hex.first, "#")
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertTrue(hex.dropFirst().allSatisfy { $0.isHexDigit })
    }

    // The pair accessor is what the view renders through `Color(lightHex:darkHex:)`.
    func testColorHexPairMatchesTheSameIndexAsTheLightHex() {
        XCTAssertEqual(avatarColorHexPair(for: "Camille Moreau").light, avatarColorPalette[6].light)
        XCTAssertEqual(avatarColorHexPair(for: "Camille Moreau").dark, avatarColorPalette[6].dark)
    }

    /// Regression: the brand-fill slot is the palette entry whose dark hex differs from its light hex, so
    /// it must carry the brand fill's own dark counterpart rather than reusing the light hex in dark mode.
    func testTheBrandFillSlotUsesTheBrandFillDarkCounterpart() {
        let slots = avatarColorPalette.filter { $0.light == DocsColorHex.brandFill }
        XCTAssertFalse(slots.isEmpty, "the palette must keep a brand-fill slot")
        for slot in slots {
            XCTAssertEqual(slot.dark, DocsColorHexDark.brandFill)
        }
    }
}
