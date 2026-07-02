import Foundation

func addingRecentServer(_ url: URL, to existing: [URL], limit: Int = 5) -> [URL] {
    var updated = existing.filter { $0 != url }
    updated.insert(url, at: 0)
    if updated.count > limit {
        updated = Array(updated.prefix(limit))
    }
    return updated
}

@Observable
final class RecentServersStore {
    private static let key = "dev.llun.Schrift.recentServers"

    private let userDefaults: UserDefaults
    private(set) var servers: [URL]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.array(forKey: Self.key) as? [String] {
            self.servers = raw.compactMap(URL.init(string:))
        } else {
            self.servers = []
        }
    }

    func addServer(_ url: URL) {
        servers = addingRecentServer(url, to: servers)
        userDefaults.set(servers.map(\.absoluteString), forKey: Self.key)
    }
}
