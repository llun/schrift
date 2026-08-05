import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The save-status row sits directly above the canvas in a `VStack(spacing: 0)`,
/// so a height it *insists* on is not clipped — it is taken out of the canvas.
///
/// `.frame(maxHeight: .infinity)` on the Save/retry label — the technique that
/// got them to a 44pt tap target — made the row answer any proposal in full,
/// because a flexible frame's unspecified bound defaults to whatever its child
/// says. The enclosing `.frame(minHeight:)` is a floor, not a cap, so nothing
/// bounded it: SwiftUI saw two greedy children and split the free height, which
/// parked the title and the first line of content mid-screen with the keyboard
/// up.
///
/// A `minHeight` floor buys the same tap target without ever claiming a
/// proposal, so these tests pin both halves at once — the row is content-sized,
/// and it is still at least as tall as the tap target, including when the
/// proposal is smaller than the floor and when the text scales.
@MainActor
final class SaveStatusIndicatorTests: XCTestCase {

    /// The proposal the editing surface hands the row on an iPhone 17.
    private let screen = CGSize(width: 402, height: 874)

    /// Every state that draws something; `.none` renders `EmptyView`.
    private let visibleDisplays: [SaveStatusDisplay] = [.save, .saving, .saved, .savedOnDevice, .retry]

    /// One point of slack, as in `EditorFormattingBarTests`: the failure this
    /// guards against was hundreds of points, not a sub-pixel.
    private let roundingSlack: CGFloat = 1

    private func height(
        of display: SaveStatusDisplay,
        proposing size: CGSize,
        typeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let host = UIHostingController(
            rootView: SaveStatusIndicator(display: display, onTap: {})
                .dynamicTypeSize(typeSize)
                .environment(LocalizationStore()))
        return host.sizeThatFits(in: size).height
    }

    /// The regression itself. Offered a whole screen, no state may take more than
    /// the row it lives in: everything past the floor comes out of the canvas.
    func testNoStateAbsorbsTheProposedHeight() {
        for display in visibleDisplays {
            let height = height(of: display, proposing: screen)
            XCTAssertLessThanOrEqual(
                height, DocsSpacing.rowMinHeight + roundingSlack,
                "\(display) answers \(height)pt to an \(screen.height)pt proposal")
        }
    }

    /// Uniform height across states, which is why the floor is on all five and
    /// not just the two that carry a button: sized per-state, the canvas below
    /// would jump as the status moved Save → Saving → Saved.
    func testEveryVisibleStateReportsTheSameHeight() {
        let heights = visibleDisplays.map { height(of: $0, proposing: screen) }
        guard let reference = heights.first else { return XCTFail("no visible displays to compare") }
        for (display, height) in zip(visibleDisplays, heights) {
            XCTAssertEqual(
                height, reference, accuracy: 0.5,
                "\(display) is \(height)pt where \(visibleDisplays[0]) is \(reference)pt")
        }
        XCTAssertGreaterThanOrEqual(reference, DocsSpacing.rowMinHeight)
    }

    /// The tap target is the component's own floor, not something an ancestor
    /// supplies — offered less than the floor it still asks for the floor.
    /// Guards against "fixing" the greed by letting the label shrink to its line.
    func testEveryVisibleStateKeepsItsFloorUnderASmallProposal() {
        for display in visibleDisplays {
            let height = height(of: display, proposing: CGSize(width: screen.width, height: 10))
            XCTAssertGreaterThanOrEqual(
                height, DocsSpacing.rowMinHeight,
                "\(display) shrank to \(height)pt when offered 10pt")
        }
    }

    /// A floor, never a cap: a fixed `height:` would hold the row at 44pt and
    /// clip the label at the sizes where the extra room matters most.
    func testTheFloorGrowsWithDynamicTypeRatherThanClippingTheLabel() {
        for display in visibleDisplays {
            let standard = height(of: display, proposing: screen)
            let accessible = height(of: display, proposing: screen, typeSize: .accessibility5)
            XCTAssertGreaterThan(
                accessible, standard,
                "\(display) stayed at \(standard)pt at the largest accessibility size")
        }
    }

    /// `.none` draws nothing. `EditorView.saveStatusRow` also omits the row
    /// entirely for it; this pins that no floor leaks onto the `EmptyView` arm.
    func testNoneRendersNothing() {
        let height = height(of: .none, proposing: screen)
        XCTAssertLessThan(height, DocsSpacing.rowMinHeight, "the empty state occupies \(height)pt")
    }
}
