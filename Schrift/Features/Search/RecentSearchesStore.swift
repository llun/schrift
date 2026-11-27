import Foundation

func addingRecentSearch(_ query: String, to existing: [String], limit: Int = 8) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return existing }
    var updated = existing.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
    updated.insert(trimmed, at: 0)
    if updated.count > limit {
        updated = Array(updated.prefix(limit))
    }
    return updated
}

/// One list per signed-in account (`<prefix>.<user id>`); with no known account nothing is
/// shown or stored, so a session whose account is not yet confirmed never sees, or adds to,
/// someone else's list. `SessionStore` clears every list on an account change and sign-out.
final class RecentSearchesStore {
    private static let keyPrefix = "dev.llun.Schrift.recentSearches"

    private let userDefaults: UserDefaults
    private let signedInUser: SignedInUserStore

    /// Read from storage each time: the search screen re-reads it when the session changes.
    var searches: [String] {
        guard let key else { return [] }
        return userDefaults.array(forKey: key) as? [String] ?? []
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.signedInUser = SignedInUserStore(userDefaults: userDefaults)
    }

    func add(_ query: String) {
        guard let key else { return }
        userDefaults.set(addingRecentSearch(query, to: searches), forKey: key)
    }

    /// Every account's list, and the one earlier builds kept for everyone.
    func clear() {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    private var key: String? {
        signedInUser.userID.map { "\(Self.keyPrefix).\($0.uuidString.lowercased())" }
    }
}
