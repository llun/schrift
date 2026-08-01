import XCTest

@testable import Schrift

/// The localization gate is only as good as this parser, and the gate it
/// replaces looked right while being unable to tell `%d` from `%@` — so the
/// parser is tested directly rather than trusted.
final class FormatSpecifiersTests: XCTestCase {
    private func kinds(_ s: String) -> [FormatArgumentKind] {
        formatSpecifiers(in: s).map(\.kind)
    }

    // MARK: - The distinction the old gate could not make

    func testAnObjectAndAnIntegerAreDifferentKinds() {
        XCTAssertEqual(kinds("%@"), [.object])
        XCTAssertEqual(kinds("%d"), [.integer])
        XCTAssertNotEqual(formatArgumentList(of: "%@"), formatArgumentList(of: "%d"))
    }

    /// The failure this exists to catch: same count, incompatible arguments.
    /// `%@` handed an `Int` dereferences an integer as an object pointer.
    func testSameCountDifferentKindsDoNotMatch() {
        XCTAssertNotEqual(formatArgumentList(of: "Shared by %@"), formatArgumentList(of: "Shared by %d"))
    }

    // MARK: - Escapes

    func testEscapedPercentIsNotAnArgument() {
        XCTAssertEqual(kinds("100%% done"), [])
        XCTAssertEqual(kinds("%d%% of %@"), [.integer, .object])
    }

    func testATrailingLonePercentIsIgnoredRatherThanTrapping() {
        XCTAssertEqual(kinds("ends with %"), [])
        XCTAssertEqual(kinds("%"), [])
    }

    // MARK: - Interchangeable spellings

    /// A translator writing `%i` where English has `%d`, or `%lld` for a count,
    /// has not broken anything — the argument is an integer either way.
    func testIntegerSpellingsAreInterchangeable() {
        XCTAssertEqual(formatArgumentList(of: "%d"), formatArgumentList(of: "%i"))
        XCTAssertEqual(formatArgumentList(of: "%d"), formatArgumentList(of: "%lld"))
        XCTAssertEqual(formatArgumentList(of: "%d"), formatArgumentList(of: "%3d"))
        XCTAssertEqual(formatArgumentList(of: "%d"), formatArgumentList(of: "%-03ld"))
    }

    func testFloatSpellingsAreInterchangeable() {
        XCTAssertEqual(formatArgumentList(of: "%f"), formatArgumentList(of: "%g"))
        XCTAssertEqual(formatArgumentList(of: "%f"), formatArgumentList(of: "%.2f"))
    }

    // MARK: - Positional arguments

    /// Positional specifiers exist so a translation can reorder. Comparing the
    /// order they appear in would fail a *correct* translation, which is why the
    /// gate compares position → kind.
    func testReorderingPositionalArgumentsIsNotAMismatch() {
        let english = formatArgumentList(of: "%1$@ in %2$@")
        let translated = formatArgumentList(of: "%2$@ / %1$@")
        XCTAssertEqual(english, translated)
    }

    func testReorderingPositionalArgumentsOfDifferentKindsIsStillNotAMismatch() {
        XCTAssertEqual(formatArgumentList(of: "%1$@ has %2$d"), formatArgumentList(of: "%2$d — %1$@"))
    }

    /// Without positional markers the order *is* the argument order, so swapping
    /// two different kinds genuinely is a mismatch.
    func testReorderingNonPositionalArgumentsOfDifferentKindsIsAMismatch() {
        XCTAssertNotEqual(formatArgumentList(of: "%@ has %d"), formatArgumentList(of: "%d — %@"))
    }

    func testPositionsAreReadFromTheExplicitIndex() {
        XCTAssertEqual(
            formatSpecifiers(in: "%2$d %1$@"),
            [FormatSpecifier(position: 2, kind: .integer), FormatSpecifier(position: 1, kind: .object)])
    }

    func testImplicitPositionsCountUpFromOne() {
        XCTAssertEqual(
            formatSpecifiers(in: "%@ %d"),
            [FormatSpecifier(position: 1, kind: .object), FormatSpecifier(position: 2, kind: .integer)])
    }

    /// Referencing one argument twice is legal and still needs one argument, so
    /// a translation may repeat what English states once.
    func testRepeatingOnePositionalArgumentStillNeedsOneArgument() {
        XCTAssertEqual(formatArgumentList(of: "%1$@ … %1$@"), formatArgumentList(of: "%1$@"))
    }

    // MARK: - Unrecognised input

    /// An unfamiliar conversion must not read as "no argument here" — that is
    /// how a weak gate lets a real mismatch through.
    func testAnUnknownConversionIsRecordedRatherThanDropped() {
        XCTAssertEqual(kinds("%y"), [.unknown])
        XCTAssertNotEqual(formatArgumentList(of: "%y"), formatArgumentList(of: ""))
    }

    /// `q` is a *length* modifier (`%qd`, BSD quad), not a conversion — so it
    /// belongs to the specifier that follows it rather than being one. Worth
    /// pinning: the obvious choice of `%q` as an "unknown conversion" example
    /// reads as a truncated `%qd` instead, which is how this parser first got
    /// tested against the wrong assumption.
    func testLengthModifiersBelongToTheConversionTheyPrefix() {
        XCTAssertEqual(kinds("%qd"), [.integer])
        XCTAssertEqual(kinds("%zu"), [.integer])
        XCTAssertEqual(kinds("%Lf"), [.double])
    }

    /// A `%` that runs off the end of the string — prose, or a truncated
    /// specifier — consumes nothing rather than trapping or inventing an
    /// argument.
    func testATruncatedSpecifierConsumesNothing() {
        XCTAssertEqual(kinds("%q"), [])
        XCTAssertEqual(kinds("%-12"), [])
    }

    // MARK: - Real strings from the catalog

    func testTheAppsOwnFormattedStringsParseAsExpected() {
        XCTAssertEqual(kinds(Strings_en.table[.home_search_placeholder] ?? ""), [.object])
        XCTAssertEqual(kinds(Strings_en.table[.shared_count_other] ?? ""), [.integer])
    }
}
