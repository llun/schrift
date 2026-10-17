import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The editor paints its page colour behind the column the loading spinner sits in, so
/// the placeholder has to claim the whole proposal. Sized to the spinner, the column was a
/// spinner wide and a Paper theme showed its colour only as a narrow strip down the middle
/// of the screen while a new document loaded.
@MainActor
final class EditorLoadingPlaceholderTests: XCTestCase {
    /// An iPhone 17 screen.
    private let screen = CGSize(width: 402, height: 874)

    private func measuredSize(of view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: screen)
    }

    func testThePlaceholderFillsTheWholeProposal() {
        let size = measuredSize(of: EditorLoadingPlaceholder())

        XCTAssertEqual(size.width, screen.width, accuracy: 1)
        XCTAssertEqual(size.height, screen.height, accuracy: 1)
    }

    /// Negative control: the spinner the placeholder used to be is content-sized, which is
    /// what makes the assertion above able to fail.
    func testABarePaddedSpinnerIsNarrowerThanTheScreen() {
        let size = measuredSize(of: ProgressView().padding(DocsSpacing.spaceBase))

        XCTAssertLessThan(size.width, screen.width / 2)
    }
}
