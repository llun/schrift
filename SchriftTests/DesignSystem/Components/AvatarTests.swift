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

    func testInitialsHandlesEmptyName() {
        XCTAssertEqual(avatarInitials(for: ""), "")
    }

    func testColorHexIsDeterministicForSameName() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorHex(for: "Camille Moreau"))
    }

    func testColorHexMatchesExpectedPaletteIndex() {
        XCTAssertEqual(avatarColorHex(for: "Camille Moreau"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Amandine Salambo"), avatarColorPalette[2])
        XCTAssertEqual(avatarColorHex(for: "Desirae Dokidis"), avatarColorPalette[4])
        XCTAssertEqual(avatarColorHex(for: "Alfredo Levin"), avatarColorPalette[3])
    }

    func testColorHexFallsBackToFirstPaletteEntryForEmptyName() {
        XCTAssertEqual(avatarColorHex(for: ""), avatarColorPalette[0])
    }
}
