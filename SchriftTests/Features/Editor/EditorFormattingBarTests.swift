import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// The formatting bar sits in a `safeAreaInset`, so a width it *insists* on does
/// not get clipped — it propagates outwards and makes the editor's whole VStack
/// wider than the screen, dragging the nav bar off the left edge with it.
///
/// `IconButton`'s default 44pt minimum width does not compress, so nine of them
/// demanded a fixed 424pt: 54pt more than an iPhone 17's content column, 81pt
/// more than a 375pt phone's. These tests pin the bar to whatever width it is
/// offered, on the narrowest device the app supports.
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

    /// One point of slack: SwiftUI divides the row into ninths and rounds each
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

    /// The 44pt tap *height* is what the buttons must never give up; the width is
    /// shared. Guards against "fixing" the overflow by shrinking the row.
    func testTheBarKeepsTheStandardTapHeight() {
        let viewModel = makeViewModel()
        let host = UIHostingController(
            rootView: EditorFormattingBar(viewModel: viewModel).environment(LocalizationStore()))
        let height = host.sizeThatFits(in: CGSize(width: 343, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThanOrEqual(height, DocsSpacing.rowMinHeight)
    }

    /// `IconButton`'s default is unchanged — only the bar opts out.
    func testAStandaloneIconButtonKeepsIts44ptMinimumWidth() {
        let host = UIHostingController(
            rootView: IconButton(systemImage: "link", label: "Link", size: .small, action: {}))
        let size = host.sizeThatFits(in: CGSize(width: 0, height: 0))
        XCTAssertGreaterThanOrEqual(size.width, DocsSpacing.rowMinHeight)
        XCTAssertGreaterThanOrEqual(size.height, DocsSpacing.rowMinHeight)
    }
}
