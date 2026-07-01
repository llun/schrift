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

@Observable
final class RecentSearchesStore {
    private static let key = "dev.llun.Schrift.recentSearches"

    private let userDefaults: UserDefaults
    private(set) var searches: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.array(forKey: Self.key) as? [String] {
            self.searches = raw
        } else {
            self.searches = []
        }
    }

    func add(_ query: String) {
        searches = addingRecentSearch(query, to: searches)
        userDefaults.set(searches, forKey: Self.key)
    }

    func clear() {
        searches = []
        userDefaults.removeObject(forKey: Self.key)
    }
}
