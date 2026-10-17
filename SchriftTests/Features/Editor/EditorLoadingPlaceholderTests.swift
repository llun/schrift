import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The editor paints its page colour behind the column the loading placeholder sits in, so
/// it has to claim the whole proposal. Sized to the spinner, the column was a
/// spinner wide and a Paper theme showed its colour only as a narrow strip down the middle
/// of the screen while a new document loaded.
///
/// Scope: this pins the placeholder. `EditorView.mainContent` carries its own full-screen
/// frame as the second half of the fix, which is private to `EditorView` and not hosted
/// here, so a future content-sized loading view would be caught only by this file's rule.
@MainActor
final class EditorLoadingPlaceholderTests: XCTestCase {
    /// An iPhone 17 screen.
    private let screen = CGSize(width: 402, height: 874)

    private func measuredSize(of view: some View) -> CGSize {
        UIHostingController(rootView: view.environment(LocalizationStore(userDefaults: defaults)))
            .sizeThatFits(in: screen)
    }

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EditorLoadingPlaceholderTests")
        defaults.removePersistentDomain(forName: "EditorLoadingPlaceholderTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "EditorLoadingPlaceholderTests")
        defaults = nil
        super.tearDown()
    }

    func testThePlaceholderFillsTheWholeProposal() {
        let size = measuredSize(of: EditorLoadingPlaceholder())

        XCTAssertEqual(size.width, screen.width, accuracy: 1)
        XCTAssertEqual(size.height, screen.height, accuracy: 1)
    }

    /// Negative control: the spinner the placeholder replaced is content-sized, which is
    /// what makes the assertion above able to fail.
    func testABarePaddedSpinnerIsNarrowerThanTheScreen() {
        let size = measuredSize(of: ProgressView().padding(DocsSpacing.spaceBase))

        XCTAssertLessThan(size.width, screen.width / 2)
    }
}
