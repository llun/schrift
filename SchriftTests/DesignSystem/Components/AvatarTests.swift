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

    func testInitialsHandlesEmptyName() {
        XCTAssertEqual(avatarInitials(for: ""), "?")
    }

    func testColorHexIsDeterministicForSameName() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorHex(for: "Camille Moreau"))
    }

    // Indices mirror the prototype's ACCENTS hash (h = h*31 + charCode, mod 8).
    // `avatarColorHex` returns the LIGHT hex, so the mapping is unchanged in light mode.
    func testColorHexMatchesExpectedPaletteIndex() {
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

    /// The brandFill slot (index 6) is the one palette entry whose dark hex
    /// differs from its light hex, so a name hashing there must now adapt.
    func testBrandFillSlotAdaptsToDarkMode() {
        let pair = avatarColorHexPair(for: "Camille Moreau")  // hashes to index 6
        XCTAssertEqual(pair.light, DocsColorHex.brandFill)
        XCTAssertEqual(pair.dark, DocsColorHexDark.brandFill)
        XCTAssertNotEqual(pair.light, pair.dark, "brandFill must differ between light and dark")
    }

    /// An accent slot pairs to itself: the accent hues are identical in dark, so
    /// this slot is visually unchanged — the fix is a no-op for accents.
    func testAnAccentSlotPairsToItself() {
        let pair = avatarColorHexPair(for: "Charlie Saris")  // hashes to index 0, accentBlue1
        XCTAssertEqual(pair.light, DocsColorHex.accentBlue1)
        XCTAssertEqual(pair.dark, DocsColorHexDark.accentBlue1)
        XCTAssertEqual(pair.light, pair.dark)
    }
}
