import Foundation

/// The signed-in account's profile — email, names, server language — remembered across
/// launches so Profile has something to show without a network round trip.
///
/// **This exists because `/users/me/` is the only source of those fields, and it is a network
/// call.** `ProfileViewModel` fetched it on every visit and held it in memory only, so with no
/// connection the user row rendered its "—" placeholder and the account detail was unreachable
/// — on a screen whose other rows (appearance, language, server host, app version) all render
/// fine offline. The document lists already read from disk when the network is gone
/// (`DocumentCacheStore`); this is the same treatment for the one row that did not.
///
/// Distinct from `SignedInUserStore`, deliberately, and the
/// two must not be merged. That store answers *whose session is this* — a question the offline
/// create/replay machinery gates on, where a wrong answer sends one user's documents into
/// another's account — so it is written only from a live fetch and fails closed. This one
/// answers *what do we show on the Profile screen*, where the cost of staleness is a name that
/// is one rename out of date. `ProfileViewModel` therefore seeds its display from here but
/// never lets a cached id stand in for a fetched one.
///
/// Not in the Keychain: this is display data, not a credential, and the same background-launch
/// readability argument as `SignedInUserStore` applies. Cleared at sign-in *and* sign-out (see
/// `SessionStore.signIn`) — unlike pending-create records, which survive a sign-out because
/// they may be a document's only copy, this is re-fetchable server data whose only use is
/// naming the current account. Keeping it past sign-in would put the previous user's email on
/// the new user's screen, indefinitely if they are offline.
///
/// Read-through on every access, like `SignedInUserStore` and for the same reason: writers
/// (any successful `/users/me/`) and readers are built at different times, and a cached
/// `private(set) var` would let a reader constructed before the first write keep answering nil.
struct CurrentUserCacheStore {
    private static let key = "dev.llun.Schrift.currentUser"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The last profile a successful fetch stored, or nil when there is none — including when
    /// this build cannot decode what an earlier one wrote. Both readers already render "we have
    /// nothing" for nil (the row's placeholder, the detail's unavailable state), so a schema
    /// change degrades to exactly the pre-cache behavior rather than throwing.
    /// The **bare** coder pair is deliberate on both sides, and they have to stay a pair: this
    /// is our own on-disk record, not an API payload, so the keys are `CurrentUser`'s own
    /// camelCase `CodingKeys` and the "never a bare `JSONDecoder`" rule (which is about
    /// *responses*) does not apply. Reading it back with `JSONDecoder.docsAPI` would in fact
    /// still work — `.convertFromSnakeCase` leaves an underscore-less key alone — but giving
    /// the **encoder** a `.convertToSnakeCase` strategy would not: the keys become
    /// `full_name`/`short_name` while the decode stays camelCase, and since every field is
    /// `decodeIfPresent` those two would read back nil forever with no error anywhere.
    /// `testRemembersEveryFieldAcrossLaunches` is what catches it.
    var user: CurrentUser? {
        guard let data = userDefaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(CurrentUser.self, from: data)
    }

    /// Write through from any successful `/users/me/`. A nil user is ignored rather than
    /// clearing a good value — a failed fetch has told us nothing about the account, and
    /// blanking the row on it is the bug this store exists to fix.
    ///
    /// A user carrying **no** account detail is ignored for exactly the same reason. Every
    /// field of `CurrentUser` is `decodeIfPresent`, so a `200` answering `{}` — a proxy, a
    /// serializer change — is a perfectly valid all-nil user that would sail past a bare
    /// `if let` and destroy a good profile. It is as uninformative as a failure, so it is
    /// treated as one.
    func remember(_ user: CurrentUser?) {
        guard let user, user.carriesAccountDetail, let data = try? JSONEncoder().encode(user) else { return }
        userDefaults.set(data, forKey: Self.key)
    }

    func clear() {
        userDefaults.removeObject(forKey: Self.key)
    }
}

extension CurrentUser {
    /// Whether this response says anything at all about an account, and so whether it is worth
    /// showing or storing. An id with no name or email still counts — that is *this* account,
    /// and a row falling back to "—" is honest where forgetting the account is not.
    /// `language` is deliberately **not** in the list: it is a preference, not identity, so a
    /// payload carrying only that would be one junk field short of `{}` and would destroy a
    /// good profile through the very guard written to prevent it.
    var carriesAccountDetail: Bool {
        if id != nil { return true }
        return [email, fullName, shortName].contains { field in
            guard let field else { return false }
            return !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
