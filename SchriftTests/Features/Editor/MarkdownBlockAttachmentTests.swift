import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// Proves `MarkdownBlockView` actually *renders* a card for a classified
/// attachment paragraph.
///
/// `attachmentDisplay` is thoroughly tested on its own, but nothing asserted the
/// view consults it: reverting the paragraph arm to the unconditional
/// `Text(markdownInlineText(...))` left the whole feature gone with a green
/// suite. Which subview SwiftUI chose is not directly observable, so this
/// measures the thing that differs — a card is a 40pt thumbnail box plus two
/// lines of text inside a 12pt-padded row, several times the height of one line
/// of body prose — using the geometry instrument `SaveStatusIndicatorTests` and
/// `EditorFormattingBarTests` already use.
///
/// Every assertion carries a **negative control**: the same view given an
/// off-origin url of the identical shape, which must stay prose. Without one, a
/// height assertion only says the instrument reports *something*, and a
/// measurement that cannot fail is not evidence.
@MainActor
final class MarkdownBlockAttachmentTests: XCTestCase {
    private let serverOrigin = "https://docs.example.org"
    private let documentUUID = "11111111-1111-4111-8111-111111111111"
    private let fileUUID = "22222222-2222-4222-8222-222222222222"
    private let proposal = CGSize(width: 370, height: 4000)
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MarkdownBlockAttachmentTests")
        defaults.removePersistentDomain(forName: "MarkdownBlockAttachmentTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "MarkdownBlockAttachmentTests")
        defaults = nil
        super.tearDown()
    }

    private func english() -> LocalizationStore {
        let store = LocalizationStore(userDefaults: defaults)
        store.language = .english
        return store
    }

    private func attachmentURL(origin: String? = nil) -> String {
        "\(origin ?? serverOrigin)/media/\(documentUUID)/attachments/\(fileUUID).pdf"
    }

    /// Hosted with an **inert** loader: it refuses every attachment (empty
    /// server origin) and so issues no request, which keeps these tests
    /// hermetic. The card still renders — as its downloading/failed chrome —
    /// and that is what is being measured.
    private func height(of text: String, isOffline: Bool = false) -> CGFloat {
        let host = UIHostingController(
            rootView: MarkdownBlockView(
                block: EditorBlock(kind: .paragraph, text: text),
                serverOrigin: serverOrigin,
                isOffline: isOffline
            )
            .environment(english())
            .environment(AttachmentLoader.inert()))
        return host.sizeThatFits(in: proposal).height
    }

    func testAClassifiedAttachmentParagraphRendersTallerThanTheProseItWouldOtherwiseBe() {
        let card = height(of: "[Q3 report.pdf](\(attachmentURL()))")
        // Negative control: identical markdown, foreign host — must stay prose.
        let prose = height(of: "[Q3 report.pdf](\(attachmentURL(origin: "https://files.example")))")

        XCTAssertGreaterThanOrEqual(
            card, DocsSpacing.rowMinHeight,
            "a classified attachment must render as a card, not a line of link text")
        XCTAssertGreaterThan(
            card, prose * 1.5,
            "the card must be visibly taller than the prose fallback (card \(card), prose \(prose))")
    }

    func testAnOffOriginLinkOfTheSameShapeStaysProse() {
        let prose = height(of: "[Q3 report.pdf](\(attachmentURL(origin: "https://files.example")))")
        let plain = height(of: "Q3 report.pdf")

        // A one-line link and a one-line paragraph are the same height; if the
        // off-origin link had become a card this would fail.
        XCTAssertEqual(prose, plain, accuracy: 1)
    }

    func testTheOfflineFlagReachesTheCard() {
        // Offline is chrome, so the card still renders at card height. The
        // interesting part is that it renders *at all* while offline — the state
        // resolver's offline branch is covered by AttachmentCardViewTests.
        XCTAssertGreaterThanOrEqual(height(of: "[f](\(attachmentURL()))", isOffline: true), DocsSpacing.rowMinHeight)
    }

    func testAnAttachmentLineInsideAMultiLineUnknownBlockStaysVerbatim() {
        // The adjacency contract, measured: one `.unknown` block of two lines is
        // prose-height, not card-height.
        let host = UIHostingController(
            rootView: MarkdownBlockView(
                block: EditorBlock(kind: .unknown, text: "Attached:\n[f](\(attachmentURL()))"),
                serverOrigin: serverOrigin
            )
            .environment(english())
            .environment(AttachmentLoader.inert()))
        let unknown = host.sizeThatFits(in: proposal).height
        let card = height(of: "[f](\(attachmentURL()))")

        XCTAssertLessThan(unknown, card)
    }
}
