import XCTest

@testable import Schrift

final class TextFieldStyleResolverTests: XCTestCase {
    func testNormalStateUsesDefaultBorder() {
        let style = TextFieldStyleResolver.style(state: .normal)
        XCTAssertEqual(
            style,
            TextFieldStyleHex(
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary))
    }

    func testFocusedStateUsesBrandBorderAndNeutralLabel() {
        let style = TextFieldStyleResolver.style(state: .focused)
        XCTAssertEqual(
            style,
            TextFieldStyleHex(
                borderLightHex: DocsColorHex.brandFill, borderDarkHex: DocsColorHexDark.brandFill,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary))
    }

    func testErrorStateUsesDangerBorderAndNeutralLabel() {
        let style = TextFieldStyleResolver.style(state: .error)
        XCTAssertEqual(
            style,
            TextFieldStyleHex(
                borderLightHex: DocsColorHex.danger, borderDarkHex: DocsColorHexDark.danger,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary))
    }

    func testDisabledStateUsesDefaultBorderWithDisabledLabel() {
        let style = TextFieldStyleResolver.style(state: .disabled)
        XCTAssertEqual(
            style,
            TextFieldStyleHex(
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault,
                labelLightHex: DocsColorHex.textDisabled, labelDarkHex: DocsColorHexDark.textDisabled))
    }
}
