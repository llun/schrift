import XCTest

@testable import Schrift

final class ButtonStyleResolverTests: XCTestCase {
    private let variants: [ButtonVariant] = [.primary, .secondary, .tertiary, .outline]
    private let colors: [ButtonColor] = [.brand, .neutral, .danger]

    func testInkIsReadableOnTheFillInBothModes() throws {
        for variant in variants where variant != .tertiary {
            for color in colors {
                let style = ButtonStyleResolver.style(variant: variant, color: color)
                let lightFill = try XCTUnwrap(style.backgroundLightHex)
                let darkFill = try XCTUnwrap(style.backgroundDarkHex)
                let label = "\(variant)/\(color)"
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundLightHex, lightFill), 4, label)
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundDarkHex, darkFill), 4, label)
            }
        }
    }

    func testTertiaryIsBackgroundlessAndOnlyOutlineDrawsABorder() {
        for color in colors {
            for variant in variants {
                let style = ButtonStyleResolver.style(variant: variant, color: color)
                XCTAssertEqual(style.backgroundLightHex == nil, variant == .tertiary, "\(variant)/\(color)")
                XCTAssertEqual(style.backgroundDarkHex == nil, variant == .tertiary, "\(variant)/\(color)")
                XCTAssertEqual(style.borderLightHex != nil, variant == .outline, "\(variant)/\(color)")
                XCTAssertEqual(style.borderDarkHex != nil, variant == .outline, "\(variant)/\(color)")
            }
        }
    }

    func testLightAndDarkHalvesDifferForEveryVariantAndColor() {
        for variant in variants {
            for color in colors {
                let style = ButtonStyleResolver.style(variant: variant, color: color)
                XCTAssertNotEqual(style.foregroundLightHex, style.foregroundDarkHex, "\(variant)/\(color)")
                XCTAssertEqual(style.backgroundLightHex != style.backgroundDarkHex, variant != .tertiary)
            }
        }
    }

    func testVariantsAndColorsResolveToDistinctStyles() {
        for color in colors {
            let styles = variants.map { ButtonStyleResolver.style(variant: $0, color: color) }
            for (index, style) in styles.enumerated() {
                XCTAssertFalse(styles[(index + 1)...].contains(style), "\(color) variants collide")
            }
        }
        for variant in variants {
            let styles = colors.map { ButtonStyleResolver.style(variant: variant, color: $0) }
            for (index, style) in styles.enumerated() {
                XCTAssertFalse(styles[(index + 1)...].contains(style), "\(variant) colors collide")
            }
        }
    }

    /// Disabled is rendered by lowering opacity at the view level, so the resolved colors stay identical
    /// to the enabled state.
    func testDisabledKeepsVariantColors() {
        for variant in variants {
            for color in colors {
                XCTAssertEqual(
                    ButtonStyleResolver.style(variant: variant, color: color, isDisabled: true),
                    ButtonStyleResolver.style(variant: variant, color: color, isDisabled: false))
            }
        }
    }
}
