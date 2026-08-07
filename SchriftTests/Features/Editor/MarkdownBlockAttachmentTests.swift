import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// Proves `MarkdownBlockView` actually *renders* a card for an attachment block.
///
/// Blocks come from the real `parseEditorBlocks`, so this covers the whole chain
/// the app uses — classify, then draw — rather than either half in isolation.
/// Which subview SwiftUI chose is not directly observable, so this measures the
/// thing that differs: a card is a 40pt thumbnail box plus two lines of text in
/// a 12pt-padded row, several times the height of one line of body prose. Same
/// geometry instrument as `SaveStatusIndicatorTests` and
/// `EditorFormattingBarTests`.
///
/// Every assertion carries a **negative control** — the same markdown parsed
/// against a foreign origin, which stays prose. Without one, a height assertion
/// only says the instrument reports *something*, and a measurement that cannot
/// fail is not evidence.
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
    /// server origin) and so issues no request, which keeps these hermetic. The
    /// card still renders — as its downloading/failed chrome — and that is what
    /// is being measured.
    private func height(of block: EditorBlock, isOffline: Bool = false) -> CGFloat {
        let host = UIHostingController(
            rootView: MarkdownBlockView(
                block: block, serverOrigin: serverOrigin, isOffline: isOffline
            )
            .environment(english())
            .environment(AttachmentLoader.inert()))
        return host.sizeThatFits(in: proposal).height
    }

    /// The one block the markdown parses into, with attachment classification on.
    private func block(_ markdown: String, origin: String? = nil) throws -> EditorBlock {
        let blocks = parseEditorBlocks(markdown, serverOrigin: origin ?? serverOrigin)
        XCTAssertEqual(blocks.count, 1, "fixture should parse to exactly one block")
        return try XCTUnwrap(blocks.first)
    }

    func testAnAttachmentBlockRendersTallerThanTheProseItWouldOtherwiseBe() throws {
        let markdown = "[Q3 report.pdf](\(attachmentURL()))"
        let card = height(of: try block(markdown))
        // Negative control: identical markdown, foreign host — parses to a
        // paragraph and must render as one line of link text.
        let prose = height(of: try block("[Q3 report.pdf](\(attachmentURL(origin: "https://files.example")))"))

        XCTAssertGreaterThanOrEqual(
            card, DocsSpacing.rowMinHeight, "an attachment block must render as a card, not a line of link text")
        XCTAssertGreaterThan(
            card, prose * 1.5, "the card must be visibly taller than the prose fallback (card \(card), prose \(prose))")
    }

    func testAnOffOriginLinkOfTheSameShapeStaysProse() throws {
        let prose = height(of: try block("[Q3 report.pdf](\(attachmentURL(origin: "https://files.example")))"))
        let plain = height(of: EditorBlock(kind: .paragraph, text: "Q3 report.pdf"))

        // A one-line link and a one-line paragraph are the same height; had the
        // off-origin link become a card, this would fail.
        XCTAssertEqual(prose, plain, accuracy: 1)
    }

    /// A url that no longer belongs to this server — a document opened after
    /// switching servers — must degrade to link text rather than render a card
    /// that could never load.
    func testAnAttachmentBlockFromAnotherServerRendersAsText() {
        let foreign = EditorBlock(kind: .attachment(name: "x.pdf", url: attachmentURL(origin: "https://files.example")))
        let card = EditorBlock(kind: .attachment(name: "x.pdf", url: attachmentURL()))

        XCTAssertLessThan(height(of: foreign), height(of: card))
    }

    /// A card renders offline too — an attachment that is merely uncached must
    /// still be shown and named rather than vanishing.
    ///
    /// Deliberately **not** asserted here: that `isOffline` reaches the card.
    /// Geometry cannot see it — `.offlineAndUncached` and `.downloading` draw
    /// the same row, differing only in a subtitle string and a `ProgressView`
    /// inside a height already set by the 40pt thumbnail box — so an assertion
    /// on height would pass with the parameter deleted. The flag's real
    /// consequences are pinned where they are observable: `attachmentCardState`
    /// in `AttachmentCardViewTests`, and `allowsNetwork` in
    /// `AttachmentLoaderTests`.
    func testACardStillRendersWhileOffline() throws {
        let markdown = "[f](\(attachmentURL()))"
        XCTAssertGreaterThanOrEqual(height(of: try block(markdown), isOffline: true), DocsSpacing.rowMinHeight)
    }

    func testAnAttachmentLineInsideAMultiLineUnknownBlockStaysVerbatim() throws {
        // The adjacency contract, measured: one `.unknown` block of two lines is
        // prose-height, not card-height.
        let unknown = try block("Attached:\n[f](\(attachmentURL()))")
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertLessThan(height(of: unknown), height(of: try block("[f](\(attachmentURL()))")))
    }
}
