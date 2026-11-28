import XCTest

@testable import Schrift

final class LiveCollaborationPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "LiveCollaborationPreferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Live collaboration is on until the Profile toggle writes an explicit off, which wins.
    func testDefaultsOnAndAnExplicitOffWins() {
        XCTAssertTrue(LiveCollaborationPreference.isEnabled(defaults))
        defaults.set(false, forKey: LiveCollaborationPreference.key)
        XCTAssertFalse(LiveCollaborationPreference.isEnabled(defaults))
        defaults.set(true, forKey: LiveCollaborationPreference.key)
        XCTAssertTrue(LiveCollaborationPreference.isEnabled(defaults))
    }

    /// The registered default is what `@AppStorage` and a fresh install read; a stored
    /// choice from a user who turned it off still wins over it.
    func testTheRegisteredDefaultKeepsAStoredOff() {
        defaults.set(false, forKey: LiveCollaborationPreference.key)
        LiveCollaborationPreference.registerDefault(in: defaults)
        XCTAssertFalse(LiveCollaborationPreference.isEnabled(defaults))
        defaults.removeObject(forKey: LiveCollaborationPreference.key)
        XCTAssertTrue(defaults.bool(forKey: LiveCollaborationPreference.key))
    }
}
