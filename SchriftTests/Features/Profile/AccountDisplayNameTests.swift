import XCTest

@testable import Schrift

/// The Profile row's own title, which is the email and not `accountDisplayName` (the handoff
/// puts the address there). Blank-vs-absent is the whole point: a server sending `""` used to
/// render a visually empty row, since `?? "—"` only covers nil.
final class AccountRowTitleTests: XCTestCase {
    func testUsesTheEmail() {
        XCTAssertEqual(accountRowEmail(CurrentUser(email: "ada@example.org")), "ada@example.org")
    }

    func testTreatsABlankOrMissingEmailAsAbsentSoTheRowShowsItsPlaceholder() {
        XCTAssertNil(accountRowEmail(CurrentUser(email: "   ")))
        XCTAssertNil(accountRowEmail(CurrentUser(email: "")))
        XCTAssertNil(accountRowEmail(nil))
        XCTAssertNil(accountRowEmail(CurrentUser(fullName: "Ada Lovelace")))
    }
}

/// `accountDisplayName` decides whether there is an account to show at all, so
/// its `nil` cases are the ones that matter: returning a placeholder instead
/// would render a person named "Untitled" that reads as real data.
final class AccountDisplayNameTests: XCTestCase {
    private func user(full: String? = nil, short: String? = nil, email: String? = nil) -> CurrentUser {
        CurrentUser(id: UUID(), email: email, fullName: full, shortName: short, language: "en")
    }

    func testPrefersTheFullName() {
        XCTAssertEqual(
            accountDisplayName(user(full: "Camille Moreau", short: "Camille", email: "c@example.org")),
            "Camille Moreau")
    }

    func testFallsBackToTheShortNameThenTheEmail() {
        XCTAssertEqual(accountDisplayName(user(short: "Camille", email: "c@example.org")), "Camille")
        XCTAssertEqual(accountDisplayName(user(email: "c@example.org")), "c@example.org")
    }

    /// No user means the account has not loaded — offline, or a failed
    /// `/users/me/`. The screen must say so rather than invent a name.
    func testNoUserOrAUserWithNothingUsableHasNoDisplayName() {
        XCTAssertNil(accountDisplayName(nil))
        XCTAssertNil(accountDisplayName(user()))
    }

    /// The server can return present-but-blank fields; those are as empty as a
    /// missing one, and must not become a whitespace "name".
    func testBlankAndWhitespaceFieldsAreSkipped() {
        XCTAssertNil(accountDisplayName(user(full: "", short: "   ", email: "\n")))
        XCTAssertEqual(accountDisplayName(user(full: "  ", short: "", email: "c@example.org")), "c@example.org")
    }
}
