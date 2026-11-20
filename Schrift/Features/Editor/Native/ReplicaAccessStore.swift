import Foundation

/// Records the last-opened timestamp per replica scope (keyed by `scope.directoryName()`)
/// so LRU eviction can drop least-recently-opened clean replicas without changing
/// `ReplicaManifest`. Missing entries sort as `.distantPast` and are evicted first.
@MainActor
final class ReplicaAccessStore {
    private static let key = "dev.llun.Schrift.replicaLastOpened"

    private let userDefaults: UserDefaults
    private var timestamps: [String: TimeInterval]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.dictionary(forKey: Self.key) as? [String: TimeInterval] {
            self.timestamps = raw
        } else {
            self.timestamps = [:]
        }
    }

    func recordOpened(_ scope: ReplicaScope, at date: Date = Date()) {
        guard scope.isValid, let name = try? scope.directoryName() else { return }
        timestamps[name] = date.timeIntervalSinceReferenceDate
        userDefaults.set(timestamps, forKey: Self.key)
    }

    func lastOpened(directoryName: String) -> Date {
        timestamps[directoryName].map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
    }

    func lastOpened(_ scope: ReplicaScope) -> Date {
        guard scope.isValid, let name = try? scope.directoryName() else { return .distantPast }
        return lastOpened(directoryName: name)
    }

    func remove(_ scope: ReplicaScope) {
        guard scope.isValid, let name = try? scope.directoryName() else { return }
        guard timestamps.removeValue(forKey: name) != nil else { return }
        userDefaults.set(timestamps, forKey: Self.key)
    }

    func snapshot() -> [String: Date] {
        timestamps.mapValues(Date.init(timeIntervalSinceReferenceDate:))
    }
}
