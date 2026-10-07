import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// A scrolling action row must fit the editor's offered width while keeping
/// each button 44pt square, rather than shrinking icons or widening the screen.
@MainActor
final class EditorFormattingBarTests: XCTestCase {

    /// Logical widths, narrowest first: iPhone SE/mini, iPhone 14/15, iPhone 17.
    private let screenWidths: [CGFloat] = [375, 390, 393, 402, 430]

    private func makeViewModel(focused: Bool = true) -> EditorViewModel {
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!)
        let viewModel = EditorViewModel(
            client: client, documentID: UUID(), title: "Doc",
            saveCoordinator: DocumentSaveCoordinator(client: client, backgroundTasks: .noop))
        viewModel.mode = .blocks
        viewModel.blocks = [EditorBlock(kind: .paragraph, text: "text")]
        if focused { viewModel.focusedBlockID = viewModel.blocks[0].id }
        return viewModel
    }

    private func barWidth(_ viewModel: EditorViewModel, offered column: CGFloat) -> CGFloat {
        let host = UIHostingController(
            rootView: EditorFormattingBar(viewModel: viewModel).environment(LocalizationStore()))
        return host.sizeThatFits(in: CGSize(width: column, height: 100)).width
    }

    /// One point of slack: SwiftUI divides the row into equal shares and rounds each
    /// share up, so a fraction of a point can accumulate on some widths. The
    /// failure this guards against was 54 points, not a sub-pixel.
    private let roundingSlack: CGFloat = 1

    func testTheBarNeverDemandsMoreWidthThanItIsOffered() {
        let viewModel = makeViewModel()
        for screen in screenWidths {
            let column = screen - 2 * DocsSpacing.gutter
            let width = barWidth(viewModel, offered: column)
            XCTAssertLessThanOrEqual(
                width, column + roundingSlack,
                "on a \(screen)pt screen the bar wants \(width) but only has \(column)")
        }
    }

    /// Disabled buttons must not change the geometry either — with no focused block
    /// every action is disabled, the widest the row's disabled state ever gets.
    func testTheBarFitsWhenEveryButtonIsDisabled() {
        let viewModel = makeViewModel(focused: false)
        let column: CGFloat = 375 - 2 * DocsSpacing.gutter
        XCTAssertLessThanOrEqual(barWidth(viewModel, offered: column), column + roundingSlack)
    }

    /// The scrolling row keeps a single 44pt control height plus its padding.
    func testTheBarKeepsTheStandardTapHeight() {
        let viewModel = makeViewModel()
        let host = UIHostingController(
            rootView: EditorFormattingBar(viewModel: viewModel).environment(LocalizationStore()))
        let height = host.sizeThatFits(in: CGSize(width: 343, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertEqual(height, DocsSpacing.rowMinHeight + 2 * DocsSpacing.space3xs, accuracy: 0.5)
    }

    /// Standalone and formatting icons share the same square target.
    func testAStandaloneIconButtonKeepsIts44ptMinimumWidth() {
        let host = UIHostingController(
            rootView: IconButton(icon: .link, label: "Link", size: .small, action: {}))
        let size = host.sizeThatFits(in: CGSize(width: 0, height: 0))
        XCTAssertGreaterThanOrEqual(size.width, DocsSpacing.rowMinHeight)
        XCTAssertGreaterThanOrEqual(size.height, DocsSpacing.rowMinHeight)
    }

    // MARK: - Photo availability

    /// Photo is no longer withheld offline: a photo picked with no network is stored on the
    /// device and uploaded by the attachment replay, exactly as an offline text edit is queued
    /// and pushed. The parameters are gone rather than ignored, so the gate cannot quietly
    /// return — this test would stop compiling, not silently pass.
    func testPhotoIsOfferedWithAFocusedBlockAndNoUploadInFlight() {
        XCTAssertTrue(canOfferPhotoInsertion(hasTarget: true, canInsertPhoto: true))
    }

    /// The pre-existing reasons still stand on their own: nothing to insert into, or an
    /// upload already running (which `canInsertPhoto` also uses to mean "content loaded").
    func testPhotoStillNeedsATargetAndAnIdleUploader() {
        XCTAssertFalse(canOfferPhotoInsertion(hasTarget: false, canInsertPhoto: true))
        XCTAssertFalse(canOfferPhotoInsertion(hasTarget: true, canInsertPhoto: false))
        XCTAssertFalse(canOfferPhotoInsertion(hasTarget: false, canInsertPhoto: false))
    }
}
