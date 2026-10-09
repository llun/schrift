import Foundation

@testable import Schrift

/// A hand-driven network path for tests that need `OnlineAvailability.isOffline` to flip
/// without touching `NWPathMonitor`. Hand it to a view model, then `setSatisfied(false)` and
/// `waitUntil { availability.isOffline }` — the monitor hops to the main actor to apply it.
@MainActor
final class FakeNetworkPath {
    private final class Box: @unchecked Sendable {
        var update: (@Sendable (Bool) -> Void)?
    }

    private let box = Box()
    let availability: OnlineAvailability

    init(userDefaults: UserDefaults) {
        let box = box
        let connectivity = ConnectivityMonitor(
            monitoring: NetworkPathMonitoring { update in
                box.update = update
                return {}
            })
        availability = OnlineAvailability(connectivity: connectivity, userDefaults: userDefaults)
    }

    func setSatisfied(_ satisfied: Bool) {
        box.update?(satisfied)
    }
}
