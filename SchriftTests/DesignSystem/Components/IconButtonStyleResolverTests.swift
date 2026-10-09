import XCTest

@testable import Schrift

final class IconButtonStyleResolverTests: XCTestCase {
    private let variants: [IconButtonVariant] = [.ghost, .soft, .outline]
    private let colors: [IconButtonColor] = [.neutral, .brand, .danger]

    func testGlyphIsReadableOnTheFillInBothModes() throws {
        for variant in variants where variant != .ghost {
            for color in colors {
                let style = IconButtonStyleResolver.style(variant: variant, color: color)
                let lightFill = try XCTUnwrap(style.backgroundLightHex)
                let darkFill = try XCTUnwrap(style.backgroundDarkHex)
                let label = "\(variant)/\(color)"
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundLightHex, lightFill), 4, label)
                XCTAssertGreaterThanOrEqual(contrastRatio(style.foregroundDarkHex, darkFill), 4, label)
            }
        }
    }

    func testGhostHasNoBackgroundOrBorderAndOnlyOutlineDrawsABorder() {
        for color in colors {
            for variant in variants {
                let style = IconButtonStyleResolver.style(variant: variant, color: color)
                XCTAssertEqual(style.backgroundLightHex == nil, variant == .ghost, "\(variant)/\(color)")
                XCTAssertEqual(style.backgroundDarkHex == nil, variant == .ghost, "\(variant)/\(color)")
                XCTAssertEqual(style.borderLightHex != nil, variant == .outline, "\(variant)/\(color)")
                XCTAssertEqual(style.borderDarkHex != nil, variant == .outline, "\(variant)/\(color)")
                XCTAssertNotEqual(style.foregroundLightHex, style.foregroundDarkHex, "\(variant)/\(color)")
            }
        }
    }

    func testVariantsAndColorsResolveToDistinctStyles() {
        for color in colors {
            let styles = variants.map { IconButtonStyleResolver.style(variant: $0, color: color) }
            for (index, style) in styles.enumerated() {
                XCTAssertFalse(styles[(index + 1)...].contains(style), "\(color) variants collide")
            }
        }
        for variant in variants {
            let styles = colors.map { IconButtonStyleResolver.style(variant: variant, color: $0) }
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
                    IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: true),
                    IconButtonStyleResolver.style(variant: variant, color: color, isDisabled: false))
            }
        }
    }
}
