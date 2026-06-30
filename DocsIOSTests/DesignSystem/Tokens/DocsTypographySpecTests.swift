import XCTest
import SwiftUI
@testable import DocsIOS

final class DocsTypographySpecTests: XCTestCase {
    func testLargeTitleMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.largeTitle, TypographySpec(size: 34, weight: .bold))
    }

    func testTitle1MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title1, TypographySpec(size: 28, weight: .bold))
    }

    func testTitle2MatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.title2, TypographySpec(size: 22, weight: .bold))
    }

    func testHeadlineMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.headline, TypographySpec(size: 17, weight: .semibold))
    }

    func testBodyMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.body, TypographySpec(size: 17, weight: .regular))
    }

    func testCalloutMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.callout, TypographySpec(size: 16, weight: .regular))
    }

    func testSubheadMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.subhead, TypographySpec(size: 15, weight: .regular))
    }

    func testFootnoteMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.footnote, TypographySpec(size: 13, weight: .regular))
    }

    func testCaptionMatchesDesignSpec() {
        XCTAssertEqual(DocsTypographySpec.caption, TypographySpec(size: 12, weight: .regular))
    }
}
