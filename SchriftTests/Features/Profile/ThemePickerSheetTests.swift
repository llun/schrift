import SwiftUI
import XCTest

@testable import Schrift

final class ThemePickerSheetTests: XCTestCase {
    func testStackedSpecimenFillsRowInsteadOfKeepingScaledWidth() {
        // Caption at AX5 scales 124pt to about 445pt, wider than any phone row.
        XCTAssertNil(themeSpecimenFixedWidth(scaledWidth: 445, stacked: true))
    }

    func testSideBySideSpecimenKeepsScaledWidth() {
        XCTAssertEqual(themeSpecimenFixedWidth(scaledWidth: 124, stacked: false), 124)
    }
}
