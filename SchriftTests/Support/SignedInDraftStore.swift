import Foundation

@testable import Schrift

/// The account `signedInDraftStore` signs in, for a fixture that does not care which.
let fixtureSignedInUserID = UUID(uuidString: "5E5E5E5E-5E5E-4E5E-8E5E-5E5E5E5E5E5E")!

/// A draft store whose suite has a signed-in account. Drafts are scoped to the account they
/// belong to, and while none is known a page is read-only and nothing is saved or sent — so a
/// fixture that edits or saves has to name one.
func signedInDraftStore(_ defaults: UserDefaults, account: UUID = fixtureSignedInUserID) -> PendingDraftStore {
    SignedInUserStore(userDefaults: defaults).remember(account)
    return PendingDraftStore(userDefaults: defaults)
}
