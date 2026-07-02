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
    func testColorHexMatchesExpectedPaletteIndex() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorPalette[6])
        XCTAssertEqual(avatarColorHex(for: "Amandine Salambo"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Desirae Dokidis"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Alfredo Levin"), avatarColorPalette[3])
        XCTAssertEqual(avatarColorHex(for: "Charlie Saris"), avatarColorPalette[0])
    }

    func testColorHexFallsBackToFirstPaletteEntryForEmptyName() {
        XCTAssertEqual(avatarColorHex(for: ""), avatarColorPalette[0])
    }
}
