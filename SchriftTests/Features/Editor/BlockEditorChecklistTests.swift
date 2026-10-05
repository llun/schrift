import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class BlockEditorChecklistTests: XCTestCase {

    // MARK: - Tap target geometry

    /// Dense checklist targets grow horizontally, but their vertical growth is
    /// limited to the existing gap so adjacent buttons cannot steal taps.
    /// This measures the positive padding before layout cancellation, not taps.
    func testCheckboxButtonTargetFitsDenseRows() {
        let button = Button(action: {}) {
            MaterialSymbol(.check_box, size: 24)
                .padding(.horizontal, EditorBlockMetrics.checkboxHitPadding)
                .padding(.vertical, EditorBlockMetrics.checkboxVerticalHitPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        let host = UIHostingController(rootView: button)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))

        XCTAssertGreaterThanOrEqual(size.width, DocsSpacing.rowMinHeight)
        let bare = UIHostingController(rootView: MaterialSymbol(.check_box, size: 24))
            .sizeThatFits(in: CGSize(width: 200, height: 200))
        XCTAssertGreaterThan(size.height, bare.height)
        XCTAssertLessThanOrEqual(size.height, bare.height + EditorBlockMetrics.blockSpacing + 0.5)
    }

    /// Symmetric negative padding shrinks the layout footprint back to the glyph's
    /// natural layout frame (~29pt for the 24pt symbol font) so that the row's
    /// alignment with the adjacent text is preserved without inflating the row.
    func testCheckboxSymmetricPaddingPreservesLayoutFootprint() {
        let symbolOnly = MaterialSymbol(.check_box, size: 24)
        let symbolHost = UIHostingController(rootView: symbolOnly)
        let symbolSize = symbolHost.sizeThatFits(in: CGSize(width: 200, height: 200))

        let adornment = Button(action: {}) {
            MaterialSymbol(.check_box, size: 24)
                .padding(.horizontal, EditorBlockMetrics.checkboxHitPadding)
                .padding(.vertical, EditorBlockMetrics.checkboxVerticalHitPadding)
                .contentShape(Rectangle())
                .padding(.horizontal, -EditorBlockMetrics.checkboxHitPadding)
                .padding(.vertical, -EditorBlockMetrics.checkboxVerticalHitPadding)
        }
        .buttonStyle(.plain)

        let host = UIHostingController(rootView: adornment)
        let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))

        // Footprint matches the symbol's own footprint within sub-pixel rounding
        XCTAssertEqual(size.width, symbolSize.width, accuracy: 1)
        XCTAssertEqual(size.height, symbolSize.height, accuracy: 1)
    }

    // MARK: - MarkdownBlockView checklist rendering & callbacks

    func testMarkdownBlockViewRendersChecklistItem() {
        let uncheckedBlock = EditorBlock(kind: .checklistItem(checked: false), text: "Buy milk")
        let checkedBlock = EditorBlock(kind: .checklistItem(checked: true), text: "Done task")

        var toggleCount = 0
        var tapTextCount = 0

        let view = MarkdownBlockView(
            block: uncheckedBlock,
            serverOrigin: "https://docs.llun.dev",
            onToggleChecklist: { toggleCount += 1 },
            onTapText: { tapTextCount += 1 }
        )
        .environment(LocalizationStore())

        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 800))
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)

        // Verify checked block also renders
        let checkedView = MarkdownBlockView(
            block: checkedBlock,
            serverOrigin: "https://docs.llun.dev"
        )
        .environment(LocalizationStore())

        let checkedHost = UIHostingController(rootView: checkedView)
        let checkedSize = checkedHost.sizeThatFits(in: CGSize(width: 320, height: 800))
        XCTAssertGreaterThan(checkedSize.width, 0)
        XCTAssertGreaterThan(checkedSize.height, 0)
    }

    func testMarkdownBlockViewToggleCallbackFires() {
        var toggled = false
        let view = MarkdownBlockView(
            block: EditorBlock(kind: .checklistItem(checked: false), text: "Todo"),
            serverOrigin: "https://docs.llun.dev",
            onToggleChecklist: { toggled = true }
        )

        view.onToggleChecklist?()
        XCTAssertTrue(toggled)
    }

    func testMarkdownBlockViewTapTextCallbackFires() {
        var textTapped = false
        let view = MarkdownBlockView(
            block: EditorBlock(kind: .checklistItem(checked: false), text: "Todo"),
            serverOrigin: "https://docs.llun.dev",
            onTapText: { textTapped = true }
        )

        view.onTapText?()
        XCTAssertTrue(textTapped)
    }
}
