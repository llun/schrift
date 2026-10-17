import XCTest

@testable import Schrift

final class RelativeDateFormatterCacheTests: XCTestCase {
    func testSameLocaleSharesOneFormatterAndDifferentLocalesDoNot() {
        let cache = RelativeDateFormatterCache()
        let english = Locale(identifier: "en")
        let french = Locale(identifier: "fr")
        XCTAssertTrue(cache.formatter(for: english) === cache.formatter(for: Locale(identifier: "en")))
        XCTAssertFalse(cache.formatter(for: english) === cache.formatter(for: french))
        XCTAssertEqual(cache.formatter(for: french).locale.identifier, "fr")
    }

    func testStringMatchesAFreshAbbreviatedFormatter() {
        let cache = RelativeDateFormatterCache()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = now.addingTimeInterval(-3 * 3600)
        for identifier in ["en", "fr", "de"] {
            let locale = Locale(identifier: identifier)
            let fresh = RelativeDateTimeFormatter()
            fresh.unitsStyle = .abbreviated
            fresh.locale = locale
            XCTAssertEqual(
                cache.string(for: date, relativeTo: now, locale: locale),
                fresh.localizedString(for: date, relativeTo: now))
        }
    }
}
