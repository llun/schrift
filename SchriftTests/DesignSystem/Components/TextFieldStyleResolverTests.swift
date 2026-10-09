import XCTest

@testable import Schrift

final class TextFieldStyleResolverTests: XCTestCase {
    private let states: [TextFieldState] = [.normal, .focused, .error, .disabled]

    func testEveryStateResolvesToADistinctStyleWithBothModesPopulated() {
        let styles = states.map { TextFieldStyleResolver.style(state: $0) }
        for (index, style) in styles.enumerated() {
            XCTAssertFalse(styles[(index + 1)...].contains(style), "\(states[index]) collides with a later state")
            XCTAssertNotEqual(style.borderLightHex, style.borderDarkHex, "\(states[index])")
            XCTAssertNotEqual(style.labelLightHex, style.labelDarkHex, "\(states[index])")
        }
    }

    /// Focus and error are conveyed by the border alone; only disabled dims the label.
    func testOnlyFocusAndErrorMoveTheBorderAndOnlyDisabledMovesTheLabel() {
        let normal = TextFieldStyleResolver.style(state: .normal)
        let focused = TextFieldStyleResolver.style(state: .focused)
        let error = TextFieldStyleResolver.style(state: .error)
        let disabled = TextFieldStyleResolver.style(state: .disabled)

        XCTAssertNotEqual(focused.borderLightHex, normal.borderLightHex)
        XCTAssertNotEqual(error.borderLightHex, normal.borderLightHex)
        XCTAssertNotEqual(focused.borderLightHex, error.borderLightHex)
        XCTAssertEqual(disabled.borderLightHex, normal.borderLightHex)
        XCTAssertEqual(disabled.borderDarkHex, normal.borderDarkHex)

        XCTAssertEqual(focused.labelLightHex, normal.labelLightHex)
        XCTAssertEqual(error.labelLightHex, normal.labelLightHex)
        XCTAssertNotEqual(disabled.labelLightHex, normal.labelLightHex)
        XCTAssertNotEqual(disabled.labelDarkHex, normal.labelDarkHex)
    }

    func testActiveLabelIsReadableOnThePageInBothModes() {
        for state in [TextFieldState.normal, .focused, .error] {
            let style = TextFieldStyleResolver.style(state: state)
            XCTAssertGreaterThanOrEqual(contrastRatio(style.labelLightHex, DocsColorHex.surfacePage), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(style.labelDarkHex, DocsColorHexDark.surfacePage), 4.5)
        }
    }
}
