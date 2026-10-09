import XCTest

@testable import Schrift

final class BadgeStyleResolverTests: XCTestCase {
    private let tones: [BadgeTone] = [.accent, .neutral, .danger, .success, .warning, .info]

    func testInkIsReadableOnTheChipInBothModes() {
        for tone in tones {
            let style = BadgeStyleResolver.style(tone: tone)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(style.foregroundLightHex, style.backgroundLightHex), 4.5, "\(tone) light")
            XCTAssertGreaterThanOrEqual(
                contrastRatio(style.foregroundDarkHex, style.backgroundDarkHex), 4.5, "\(tone) dark")
        }
    }

    func testEveryToneIsDistinctAndDarkDiffersFromLight() {
        let styles = tones.map { BadgeStyleResolver.style(tone: $0) }
        for (index, style) in styles.enumerated() {
            XCTAssertFalse(styles[(index + 1)...].contains(style), "\(tones[index]) collides with a later tone")
            XCTAssertNotEqual(style.backgroundLightHex, style.backgroundDarkHex, "\(tones[index])")
            XCTAssertNotEqual(style.foregroundLightHex, style.foregroundDarkHex, "\(tones[index])")
        }
    }
}
