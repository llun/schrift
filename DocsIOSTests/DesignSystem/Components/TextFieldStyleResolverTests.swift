import XCTest
@testable import DocsIOS

final class TextFieldStyleResolverTests: XCTestCase {
    func testNormalStateUsesDefaultBorder() {
        let style = TextFieldStyleResolver.style(state: .normal)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textSecondary))
    }

    func testFocusedStateUsesBrandBorder() {
        let style = TextFieldStyleResolver.style(state: .focused)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderFocus, labelHex: DocsColorHex.textBrandSecondary))
    }

    func testErrorStateUsesDangerBorder() {
        let style = TextFieldStyleResolver.style(state: .error)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.danger, labelHex: DocsColorHex.danger))
    }

    func testDisabledStateUsesDefaultBorderWithDisabledLabel() {
        let style = TextFieldStyleResolver.style(state: .disabled)
        XCTAssertEqual(style, TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textDisabled))
    }
}
