import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// `PagesTreeDrawer.treeRow` is the app's one place where a `maxHeight:
/// .infinity` label sits beside a *shorter* sibling: a node with children
/// reserves a 44pt disclosure button in the leading column, a leaf reserves a
/// 22pt transparent placeholder in the same column. That asymmetry reads like a
/// leaf could open from only a 22pt strip through the middle of a 44pt-looking
/// row, and it has twice been raised as one.
///
/// It can't. `.frame(minHeight:)` is not merely a floor on the size a row
/// *reports*: a `ScrollView` proposes `nil` along its scroll axis, and a
/// flexible frame given only a minimum clamps an unspecified proposal **up to**
/// that minimum and proposes *that* to its child. The proposal therefore arrives
/// down the row rather than across the `HStack`, and the sibling in the
/// disclosure column never enters into it. These tests hold that rule to the
/// numbers, in the row's own shape, including the `ScrollView` that makes the
/// proposal unspecified in the first place.
///
/// **What this measures, and what it doesn't.** The subject is a replica of
/// `treeRow`'s shape built from the same tokens, not the shipping row: that row
/// is a private `@ViewBuilder` nested inside the drawer's `ScrollView`, and
/// neither instrument available here reaches it. `sizeThatFits` reports the
/// *row* — 44pt with the fill or without it, since the row floors either way,
/// which is exactly why the defect would be invisible to it — and a hosted
/// view's accessibility frames, which do track the label's own bounds, are not
/// materialized on a simulator with no accessibility client, so they measure
/// nothing on CI. **Keep this replica in step with `treeRow`.** The shipping
/// view was measured the other way at the time of writing, on an
/// accessibility-enabled simulator: every row shape reported 44.0pt, and
/// deleting the fill dropped every row — parents included — to 21.0pt.
@MainActor
final class PagesTreeDrawerTests: XCTestCase {

    /// Carries a measurement out of the view tree.
    private final class Measured {
        var label: CGSize = .zero
        var row: CGSize = .zero
    }

    // MARK: - The row's shape

    /// `treeRow`'s geometry, reproduced: the disclosure column, the filled label
    /// that takes the tap shape, the row's floor, and the `ScrollView` whose
    /// unspecified proposal is what that floor clamps.
    private struct RowUnderTest: View {
        /// 44pt for a node with children (its disclosure button), 22pt for a leaf
        /// (its `Color.clear` placeholder).
        let siblingHeight: CGFloat
        /// The modifier under test. `false` is the defect these tests rule out.
        var fillsTheRow: Bool = true
        let measured: Measured

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DocsSpacing.space3xs) {
                        Color.clear
                            .frame(width: PagesTreeLayout.disclosureWidth, height: siblingHeight)

                        Button {
                        } label: {
                            label
                                .contentShape(Rectangle())
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.onAppear { measured.label = proxy.size }
                                    })
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DocsSpacing.space3xs)
                    .frame(minHeight: DocsSpacing.rowMinHeight)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onAppear { measured.row = proxy.size }
                        })
                }
            }
        }

        @ViewBuilder private var label: some View {
            let content = HStack(spacing: DocsSpacing.spaceXS) {
                DocIcon(size: 16)
                Text("Leaf page")
                    .font(DocsFont.subhead)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if fillsTheRow { content.frame(maxHeight: .infinity) } else { content }
        }
    }

    // MARK: - Measurement

    private func measure(
        siblingHeight: CGFloat, fillsTheRow: Bool = true, typeSize: DynamicTypeSize = .large
    ) -> Measured {
        let measured = Measured()
        let host = UIHostingController(
            rootView: RowUnderTest(
                siblingHeight: siblingHeight, fillsTheRow: fillsTheRow, measured: measured
            )
            .dynamicTypeSize(typeSize))
        host.view.frame = CGRect(x: 0, y: 0, width: PagesTreeLayout.panelWidth, height: 700)
        // A `GeometryReader` reports nothing until the view is in a window and
        // laid out — without one both measurements come back `.zero`.
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return measured
    }

    // MARK: - Tests

    /// The claim this file exists to settle. A leaf's 22pt placeholder governs
    /// the disclosure column's width, never the label's height.
    func testALeafRowsLabelCoversTheWholeRow() {
        let measured = measure(siblingHeight: 22)

        XCTAssertEqual(measured.row.height, DocsSpacing.rowMinHeight, accuracy: 0.01)
        XCTAssertEqual(
            measured.label.height, measured.row.height, accuracy: 0.01,
            "a leaf opens from \(measured.label.height)pt of a \(measured.row.height)pt row")
    }

    /// The same row with a node's 44pt disclosure button beside it, which is the
    /// shape the leaf was suspected of falling short of.
    func testARowWithChildrenIsNoMoreTappableThanALeaf() {
        let leaf = measure(siblingHeight: 22)
        let parent = measure(siblingHeight: PagesTreeLayout.disclosureWidth)

        XCTAssertEqual(leaf.label.height, parent.label.height, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(leaf.label.height, DocsSpacing.rowMinHeight)
    }

    /// Dynamic Type grows the row past its floor rather than clipping it, and the
    /// label keeps covering it — the reason a short label is floored with a
    /// `minHeight:` and never a fixed `height:`.
    func testTheLabelKeepsCoveringTheRowAtAccessibilityTextSizes() {
        for typeSize in [DynamicTypeSize.xxxLarge, .accessibility3, .accessibility5] {
            let measured = measure(siblingHeight: 22, typeSize: typeSize)

            XCTAssertGreaterThanOrEqual(
                measured.row.height, DocsSpacing.rowMinHeight, "row at \(typeSize)")
            XCTAssertEqual(
                measured.label.height, measured.row.height, accuracy: 0.01, "label at \(typeSize)")
        }
    }

    /// The control. Without the fill the label is only as tall as its text, which
    /// is both the defect the tests above rule out and the proof that they are
    /// measuring the label rather than the row: the row floors at 44pt either
    /// way, so a measurement that could not report this would report nothing.
    func testWithoutTheFillTheLabelOnlyCoversItsText() {
        let measured = measure(siblingHeight: 22, fillsTheRow: false)

        XCTAssertEqual(measured.row.height, DocsSpacing.rowMinHeight, accuracy: 0.01)
        XCTAssertLessThan(
            measured.label.height, DocsSpacing.rowMinHeight,
            "the measurement tracks the row, not the label — the tests above prove nothing")
    }
}
