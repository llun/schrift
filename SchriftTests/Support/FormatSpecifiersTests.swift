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

    func testATrailingLonePercentDoesNotTrap() {
        XCTAssertNoThrow(kinds("ends with %"))
        XCTAssertNoThrow(kinds("%"))
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

    // MARK: - Never weaker than counting `%`

    /// The regression that matters most: a truncated specifier trailing a valid
    /// one used to vanish, so a corrupted string compared equal to a clean one.
    /// Counting `%` — the gate this replaced — caught that, so dropping it here
    /// would have made the new gate weaker in a dimension nobody was watching.
    func testATruncatedSpecifierAfterAValidOneIsStillRecorded() {
        XCTAssertEqual(kinds("%d files: %0"), [.integer, .unknown])
        XCTAssertNotEqual(formatArgumentList(of: "%d files: %0"), formatArgumentList(of: "%d files"))
    }

    func testATruncatedSpecifierIsRecordedWhereverItAppears() {
        XCTAssertEqual(kinds("%q"), [.unknown])
        XCTAssertEqual(kinds("%-12"), [.unknown])
        XCTAssertEqual(kinds("ends with %"), [.unknown])
        XCTAssertEqual(kinds("%"), [.unknown])
    }

    /// One position used with two different kinds contradicts itself: the
    /// argument cannot be both, so one of the uses renders garbage. Resolving it
    /// last-write-wins made it compare equal to the correct string.
    func testOnePositionUsedWithTwoKindsIsConflictedNotLastWins() {
        XCTAssertEqual(formatArgumentList(of: "%1$d %1$@ x %2$d")[1], .conflicted)
        XCTAssertNotEqual(
            formatArgumentList(of: "%1$d %1$@ x %2$d"),
            formatArgumentList(of: "%1$@ x %2$d"))
    }

    func testAConflictOnceRecordedIsNotRedeemedByALaterAgreement() {
        XCTAssertEqual(formatArgumentList(of: "%1$@ %1$d %1$@")[1], .conflicted)
    }

    /// The whole property, stated directly: anything the old counting gate would
    /// have flagged, this one flags too.
    func testEveryDivergenceTheOldCountingGateCaughtIsStillCaught() {
        // (english, translation) pairs the old gate failed on by raw `%` count.
        let divergences = [
            ("%d files remain", "%d files: %0"),
            ("%1$@ x %2$d", "%1$d %1$@ x %2$d"),
            ("Search %@", "Search"),
            ("%@ and %@", "%@"),
            ("100%% sure", "100% sure"),
        ]
        for (english, translation) in divergences {
            XCTAssertNotEqual(
                formatArgumentList(of: english), formatArgumentList(of: translation),
                "the argument lists of \"\(english)\" and \"\(translation)\" must differ")
        }
    }

    // MARK: - Arguments consumed by width and precision

    /// `%*d` takes the width from an argument *before* the value, so it consumes
    /// two. Skipping the star as punctuation made it compare equal to `%d`,
    /// which then renders the wrong number entirely.
    func testStarWidthAndPrecisionConsumeTheirOwnArguments() {
        XCTAssertEqual(kinds("%*d"), [.integer, .integer])
        XCTAssertEqual(kinds("%.*f"), [.integer, .double])
        XCTAssertEqual(kinds("%*.*f"), [.integer, .integer, .double])
        XCTAssertNotEqual(formatArgumentList(of: "%*d"), formatArgumentList(of: "%d"))
    }

    // MARK: - Malformed positions

    /// Positions are 1-based, so `%0$@` and an overflowing index are malformed.
    /// Neither is quietly re-read as a plain `%@`: they record `.unknown`, which
    /// is what stops a malformed string comparing equal to a well-formed one.
    func testAZeroOrUnparseablePositionIsMalformedRatherThanRenumbered() {
        XCTAssertEqual(kinds("%0$@"), [.unknown])
        XCTAssertEqual(kinds("%99999999999999999999$@"), [.unknown])
        XCTAssertNotEqual(formatArgumentList(of: "%0$@"), formatArgumentList(of: "%@"))
    }

    /// `Int(_:)` parses ASCII digits only, so a full-width digit must not be
    /// consumed as a position and then silently dropped.
    func testNonASCIIDigitsAreNotReadAsAPosition() {
        XCTAssertEqual(kinds("%１$@"), [.unknown])
    }

    // MARK: - Pointer kinds

    /// `%s` and `%S` are both pointers, but to different element types, so one
    /// read as the other is garbage rather than a respelling.
    func testCStringAndUnicharStringAreDifferentKinds() {
        XCTAssertNotEqual(formatArgumentList(of: "%s"), formatArgumentList(of: "%S"))
    }

    // MARK: - Real strings from the catalog

    /// A property over the whole catalog rather than two hand-picked strings, so
    /// a copy rewrite can't fail this for a reason unrelated to the parser: no
    /// shipped English string may contain a specifier this parser cannot read.
    func testNoShippedEnglishStringContainsAnUnreadableSpecifier() {
        for key in L10nKey.allCases {
            guard let string = Strings_en.table[key] else { continue }
            for specifier in formatSpecifiers(in: string) {
                XCTAssertNotEqual(
                    specifier.kind, .unknown,
                    "\(key.rawValue) has a specifier the gate cannot read: \(string)")
                XCTAssertNotEqual(
                    specifier.kind, .conflicted,
                    "\(key.rawValue) uses one position with two kinds: \(string)")
            }
        }
    }
}
