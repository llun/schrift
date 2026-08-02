import Foundation

/// The signed-in account's server id, remembered across launches.
///
/// **This exists because offline document creation cannot work without it.** A record minted by
/// `DocumentSaveCoordinator.createLocalDocument` carries a non-optional `ownerUserID`, and that
/// id is what `belongsToSession` tests before the replay will either *list* a local document or
/// *send* it — so a record whose owner is unknown is kept and protected but shown to nobody and
/// replayed never. The id itself is only ever learned from `/users/me/`, which is a network
/// call. Launching in airplane mode — the entire point of the feature — would therefore yield
/// no id, no mintable record, and an empty list.
///
/// Failing closed there is correct (see `isReplayable`: "I don't know whose this is" must never
/// resolve to "anyone may send it"), so the fix is not to relax that test but to make the
/// answer available offline. Anything that successfully fetches the current user writes it
/// through here.
///
/// Not in the Keychain, deliberately. This is an account *identifier*, not a credential: it
/// grants nothing, it is already stored in plain UserDefaults on the server-URL side
/// (`dev.llun.Schrift.serverURL`), and putting it behind `…WhenUnlockedThisDeviceOnly` would
/// make it unreadable exactly when a background launch needs it. The credential — the session
/// cookies — stays in the Keychain where it belongs.
/// Deliberately **not** `@Observable`, and deliberately not caching the value in memory. Nothing
/// renders it, and it has several writers (any successful `/users/me/`) and several readers
/// (whoever is about to mint or list a local document), built at different times. A cached
/// `private(set) var` would let a reader constructed before the first write keep answering nil
/// forever — the same "two instances of one store silently disagree" shape that costs content
/// elsewhere in this subsystem. Reading through on every access makes that unrepresentable, and
/// the read is one `UserDefaults` string lookup on a path that already does file I/O.
struct SignedInUserStore {
    private static let key = "dev.llun.Schrift.signedInUserID"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var userID: UUID? {
        userDefaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:))
    }

    /// Write through from any successful `/users/me/`. Idempotent, and a nil id (the field is
    /// Optional on the wire) is ignored rather than clearing a good value — a server that omits
    /// it on one response has told us nothing about the account.
    func remember(_ id: UUID?) {
        guard let id else { return }
        userDefaults.set(id.uuidString, forKey: Self.key)
    }

    /// Sign-out only. Records outlive a sign-out on purpose — for a document that exists
    /// nowhere else, the record and its draft are the only copies — and what makes that safe is
    /// the record's *own* `ownerUserID`, which is compared against whoever signs in next. This
    /// store answering nil afterwards is exactly right: the next session must learn the id from
    /// the server before anything of the previous user's is listed or sent.
    func clear() {
        userDefaults.removeObject(forKey: Self.key)
    }
}
