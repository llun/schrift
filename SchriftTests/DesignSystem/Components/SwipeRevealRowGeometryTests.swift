import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// `SwipeRevealRow` wraps a row that is already laid out and already sized. The property
/// that matters is that wrapping changes **neither** dimension: the action strip is drawn as
/// a `background` of the content, so if it ever contributed to the row's own size it would
/// either inflate every document row's height or widen the list past the screen — the
/// failure `EditorFormattingBar` shipped once, where a row of fixed-minimum controls demanded
/// more width than the device had and pushed the nav bar's back chevron off the leading edge.
///
/// `sizeThatFits` can see that class of defect, unlike the tap-shape questions it cannot;
/// see `PagesTreeDrawerTests` for the other instrument.
@MainActor
final class SwipeRevealRowGeometryTests: XCTestCase {

    /// An iPhone 17's content column, less the list's own gutters.
    private let screen = CGSize(width: 402 - 2 * DocsSpacing.gutter, height: 874)
    /// One point of slack, as in `SaveStatusIndicatorTests`: what these guard against is
    /// tens or hundreds of points, not a sub-pixel.
    private let roundingSlack: CGFloat = 1

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SwipeRevealRowGeometryTests")
        defaults.removePersistentDomain(forName: "SwipeRevealRowGeometryTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SwipeRevealRowGeometryTests")
        defaults = nil
        super.tearDown()
    }

    /// English through an isolated suite, so this neither reads nor writes the host's
    /// `schrift.language` — the captions are localized and their width is part of what is
    /// being measured.
    private func english() -> LocalizationStore {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        return store
    }

    private func actions() -> [SwipeRevealAction] {
        [
            SwipeRevealAction(id: "pin", icon: .push_pin, label: "Pin", role: .brand) {},
            SwipeRevealAction(id: "delete", icon: .delete, label: "Delete", role: .destructive) {},
        ]
    }

    private func bareRowSize(typeSize: DynamicTypeSize = .large) -> CGSize {
        let host = UIHostingController(
            rootView: DocRow(title: "Q3 Planning", date: "3 days ago")
                .dynamicTypeSize(typeSize)
                .environment(english()))
        return host.sizeThatFits(in: screen)
    }

    private func wrappedRowSize(typeSize: DynamicTypeSize = .large) -> CGSize {
        let host = UIHostingController(
            rootView: SwipeRevealRow(
                id: "row",
                state: .constant(SwipeRevealState<String>()),
                actions: actions(),
                accessibilityLabel: "Q3 Planning, 3 days ago",
                onActivate: {}
            ) {
                DocRow(title: "Q3 Planning", date: "3 days ago")
            }
            .dynamicTypeSize(typeSize)
            .environment(english()))
        return host.sizeThatFits(in: screen)
    }

    // MARK: - Wrapping must not resize the row

    func testWrappingARowDoesNotChangeItsHeight() {
        XCTAssertEqual(
            wrappedRowSize().height, bareRowSize().height, accuracy: roundingSlack,
            "the action strip must not inflate every document row")
    }

    func testWrappingARowDoesNotChangeItsWidth() {
        XCTAssertEqual(
            wrappedRowSize().width, bareRowSize().width, accuracy: roundingSlack,
            "a strip that widened the row would widen the whole list past the screen")
    }

    /// The strip's buttons scale with Dynamic Type, so this is where an inflating strip
    /// would show up first.
    func testWrappingHoldsAtAnAccessibilityTextSize() {
        XCTAssertEqual(
            wrappedRowSize(typeSize: .accessibility3).height,
            bareRowSize(typeSize: .accessibility3).height,
            accuracy: roundingSlack)
    }

    func testAWrappedRowStillClearsTheTapTargetFloor() {
        XCTAssertGreaterThanOrEqual(
            wrappedRowSize().height, DocsSpacing.rowMinHeight - roundingSlack)
    }

    /// **The negative control.** Without it the assertions above pass just as happily on a
    /// strip that never rendered at all — and a measurement that cannot fail is not evidence
    /// (CLAUDE.md's rule, learned from `PagesTreeDrawerTests`). Hosting the same buttons
    /// alone proves the instrument can see the strip's width, so "the composed row measures
    /// the content's width" is a statement about composition rather than about an empty view.
    func testTheActionStripAloneMeasuresItsOwnWidth() {
        let expected = swipeActionStripWidth(
            actionCount: 2,
            buttonWidth: swipeActionButtonWidth(
                actionCount: 2, scaledBase: SwipeRevealMetrics.actionButtonBaseWidth,
                rowWidth: screen.width))

        let host = UIHostingController(
            rootView: HStack(spacing: 0) {
                ForEach(actions()) { action in
                    VStack(spacing: DocsSpacing.space3xs) {
                        MaterialSymbol(action.icon, size: 22)
                        Text(action.label)
                            .font(DocsFont.caption.weight(.semibold))
                    }
                    .frame(width: expected / 2)
                }
            }
            .environment(english()))

        XCTAssertEqual(host.sizeThatFits(in: screen).width, expected, accuracy: roundingSlack)
        XCTAssertGreaterThan(expected, 0, "a zero-width control would make this vacuous")
    }

    // MARK: - The strip may not paint outside the row

    /// Renders a row with clear margins above and below it and reports whether anything was
    /// painted into those margins in the **trailing** column — where the action strip sits.
    ///
    /// `sizeThatFits` cannot see this: the strip is a `background`, so it contributes nothing
    /// to the row's measured size no matter how tall it draws. Only a render can.
    private func paintsOutsideTheRow<Row: View>(
        margin: CGFloat = 20, rowHeight: CGFloat, typeSize: DynamicTypeSize = .large,
        @ViewBuilder row: () -> Row
    ) -> Bool {
        let view = VStack(spacing: 0) {
            Color.clear.frame(height: margin)
            row()
            Color.clear.frame(height: margin)
        }
        .frame(width: 300)
        .background(DocsColor.surfacePage)
        .dynamicTypeSize(typeSize)
        .environment(english())

        let renderer = ImageRenderer(content: view)
        let scale = 3
        renderer.scale = CGFloat(scale)
        guard let cg = renderer.uiImage?.cgImage else {
            XCTFail("the row could not be rendered")
            return false
        }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard
            let context = CGContext(
                data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            XCTFail("could not build a sampling context")
            return false
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        // 5pt in from the trailing edge — inside the strip, whose narrowest button is the
        // 44pt tap-target floor.
        let x = cg.width - 5 * scale
        // The margins, less one pixel at each row boundary: a row edge that lands mid-pixel
        // blends legitimately, and what this guards against is a whole point of fill.
        let rowTop = Int(margin) * scale
        let rowBottom = rowTop + Int((rowHeight * CGFloat(scale)).rounded())
        let outside = Array(0..<(rowTop - 1)) + Array((rowBottom + 1)..<cg.height)
        return outside.contains { y in
            let i = (y * cg.width + x) * 4
            // Anything at all that is not the page colour the margins are drawn on.
            return data[i] != 255 || data[i + 1] != 255 || data[i + 2] != 255
        }
    }

    private func wrappedRow(height: CGFloat) -> some View {
        SwipeRevealRow(
            id: "row", state: .constant(SwipeRevealState<String>()), actions: actions(),
            accessibilityLabel: "Q3 Planning", onActivate: {}
        ) {
            Text("Q3 Planning")
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
    }

    /// **The strip is chrome behind the row, and chrome may not spill onto the row's
    /// neighbours.**
    ///
    /// A `background` is *proposed* the size of the view it decorates, which reads as a
    /// guarantee that the strip can never be taller than its row. It is not one: each action
    /// button's `.frame(maxHeight: .infinity)` clamps a proposal *down* only as far as its own
    /// label's ideal height, and a 22pt glyph over a caption is ~45.7pt at the Large content
    /// size. So a row sitting at the 44pt tap-target floor — `SubpageRow` and every
    /// `PagesTreeDrawer` row — had ~0.8pt of the destructive fill painted above and below it,
    /// drawn as a hairline between rows even while every row was closed. `DocRow` is ~58pt and
    /// swallowed the overflow, which is why the Home list never showed it.
    func testTheStripDoesNotPaintAboveOrBelowARowAtTheTapTargetFloor() {
        XCTAssertFalse(
            paintsOutsideTheRow(rowHeight: DocsSpacing.rowMinHeight) {
                wrappedRow(height: DocsSpacing.rowMinHeight)
            },
            "the action strip is painting outside the row it decorates")
    }

    /// The same property where the overflow is largest: the glyph scales with Dynamic Type
    /// while a row is free not to, so an accessibility size turns a hairline into points of
    /// fill over the neighbouring rows.
    func testTheStripDoesNotPaintOutsideTheRowAtAnAccessibilityTextSize() {
        XCTAssertFalse(
            paintsOutsideTheRow(rowHeight: DocsSpacing.rowMinHeight, typeSize: .accessibility3) {
                wrappedRow(height: DocsSpacing.rowMinHeight)
            },
            "the action strip is painting outside the row at an accessibility text size")
    }

    /// A row taller than the strip never had the defect, and must not acquire one from the
    /// fix — this is the Home list's own geometry.
    func testATallRowStillPaintsNothingOutsideItself() {
        XCTAssertFalse(paintsOutsideTheRow(rowHeight: 58) { wrappedRow(height: 58) })
    }

    /// **The negative control.** Every assertion above is a claim that a scanner found
    /// *nothing*, which is exactly what a scanner pointed at the wrong column, or at an image
    /// that never rendered, also reports. This paints the same fill deliberately over the
    /// margins and requires the scanner to say so.
    func testTheOverflowScannerSeesAFillThatDoesEscapeTheRow() {
        XCTAssertTrue(
            paintsOutsideTheRow(rowHeight: DocsSpacing.rowMinHeight) {
                Text("Q3 Planning")
                    .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                    .background(alignment: .trailing) {
                        Color(lightHex: DocsColorHex.danger, darkHex: DocsColorHexDark.danger)
                            .frame(width: 72, height: DocsSpacing.rowMinHeight + 8)
                    }
            },
            "the scanner cannot see an overflowing fill, so the assertions above prove nothing")
    }

    // MARK: - The SwiftUI semantic the reveal depends on

    /// **The strip is pinned while the content slides, and that rests on one SwiftUI rule:
    /// a `background` applied *after* an `.offset` is laid out in the view's own unshifted
    /// bounds and does not follow it.**
    ///
    /// The component has no way to state that in its own types, and getting it backwards is
    /// invisible to every size assertion above — the row measures identically either way,
    /// while the strip slides the wrong direction at twice the speed. So it is pinned here
    /// by rendering: white content 100pt wide shifted 50pt left over a red strip pinned
    /// trailing. If the rule holds, the trailing edge is red; if it ever stops holding, this
    /// fails and the compensation has to come back.
    func testABackgroundDoesNotFollowAPriorOffset() {
        let view = Color.white
            .frame(width: 100, height: 40)
            .offset(x: -50)
            .background(alignment: .trailing) { Color.red.frame(width: 50, height: 40) }
            .frame(width: 100, height: 40)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.uiImage?.cgImage else {
            return XCTFail("the row could not be rendered")
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return XCTFail("could not build a sampling context") }
        // Sample 10pt in from the trailing edge, vertically centred.
        context.draw(
            cg,
            in: CGRect(
                x: -Double(cg.width) + 10, y: -Double(cg.height) / 2,
                width: Double(cg.width), height: Double(cg.height)))

        XCTAssertGreaterThan(
            Int(pixel[0]), 200,
            "the trailing edge should be the pinned red strip, not the slid-away content")
        XCTAssertLessThan(
            Int(pixel[2]), 150,
            "a white pixel here means the background followed the offset — see this test's "
                + "doc comment, and restore the compensating offset in SwipeRevealRow")
    }
}
