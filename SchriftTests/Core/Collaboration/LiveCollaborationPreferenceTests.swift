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

    /// Live collaboration is opt-in: it stays off until the Profile toggle writes the key.
    func testDefaultsOffAndReadsTheStoredChoice() {
        XCTAssertFalse(LiveCollaborationPreference.isEnabled(defaults))
        defaults.set(true, forKey: LiveCollaborationPreference.key)
        XCTAssertTrue(LiveCollaborationPreference.isEnabled(defaults))
    }
}
