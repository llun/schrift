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

final class RecentSearchesStore {
    private static let key = "dev.llun.Schrift.recentSearches"

    private let userDefaults: UserDefaults
    /// Read from storage each time: `SessionStore` clears it from another instance on an
    /// account change, and the search screen re-reads it when the session changes.
    var searches: [String] { userDefaults.array(forKey: Self.key) as? [String] ?? [] }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func add(_ query: String) {
        userDefaults.set(addingRecentSearch(query, to: searches), forKey: Self.key)
    }

    func clear() {
        userDefaults.removeObject(forKey: Self.key)
    }
}
