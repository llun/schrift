import XCTest

@testable import Schrift

/// The native editor is on unless the user turned it off. These fail against the
/// old `bool(forKey:)` default: an absent key read as off.
final class NativeEditorPreferenceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "NativeEditorPreferenceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        // What `SchriftApp.init` does, so this suite does not lean on the host app's launch.
        NativeEditorPreference.registerDefault(in: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNoStoredKeyIsEnabledAndTheSettingsToggleReadsOn() {
        // `setUp` registers the on-by-default value; a suite that never stored the key reads it.
        XCTAssertTrue(NativeEditorPreference.isEnabled(defaults), "an absent key must mean on")
        XCTAssertTrue(defaults.bool(forKey: NativeEditorPreference.key), "the Settings toggle reads on")
    }

    func testExplicitOffStaysOff() {
        defaults.set(false, forKey: NativeEditorPreference.key)
        XCTAssertFalse(NativeEditorPreference.isEnabled(defaults), "an explicit off must win over the default")
        XCTAssertFalse(defaults.bool(forKey: NativeEditorPreference.key))
    }
}
