import XCTest
@testable import Schrift

final class TextFieldStyleResolverTests: XCTestCase {
    func testNormalStateUsesDefaultBorder() {
        let style = TextFieldStyleResolver.style(state: .normal)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textSecondary))
    }

    func testFocusedStateUsesBrandBorderAndNeutralLabel() {
        let style = TextFieldStyleResolver.style(state: .focused)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.brandFill, labelHex: DocsColorHex.textSecondary))
    }

    func testErrorStateUsesDangerBorderAndNeutralLabel() {
        let style = TextFieldStyleResolver.style(state: .error)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.danger, labelHex: DocsColorHex.textSecondary))
    }

    func testDisabledStateUsesDefaultBorderWithDisabledLabel() {
        let style = TextFieldStyleResolver.style(state: .disabled)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textDisabled))
    }
}
