import XCTest

@testable import Schrift

final class AttachmentCardViewTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/22222222-2222-4222-8222-222222222222.pdf")
    private let serverOrigin = "https://docs.example.org"

    private func attachment(ext: String, unsafe: Bool = false) throws -> AttachmentDisplay {
        let url =
            "\(serverOrigin)/media/11111111-1111-4111-8111-111111111111/attachments/"
            + "22222222-2222-4222-8222-222222222222\(unsafe ? "-unsafe" : "").\(ext)"
        return try XCTUnwrap(parseAttachmentLink("[f](\(url))", serverOrigin: serverOrigin))
    }

    // MARK: - Online

    func testNoStateYetReadsAsDownloading() {
        // The card's own `.task` is about to start it; showing a failure here
        // would flash an error the app never encountered.
        XCTAssertEqual(attachmentCardState(loaderState: nil, isOffline: false), .downloading)
    }

    func testDownloadingStaysDownloading() {
        XCTAssertEqual(attachmentCardState(loaderState: .downloading, isOffline: false), .downloading)
    }

    func testCachedShowsTheFile() {
        XCTAssertEqual(attachmentCardState(loaderState: .cached(file), isOffline: false), .cached(file))
    }

    func testFailedOfferesRetry() {
        XCTAssertEqual(attachmentCardState(loaderState: .failed, isOffline: false), .failed)
    }

    // MARK: - Offline

    /// The point of caching: an attachment downloaded earlier opens in airplane
    /// mode. Offline must never outrank cached bytes.
    func testCachedWinsOverOffline() {
        XCTAssertEqual(attachmentCardState(loaderState: .cached(file), isOffline: true), .cached(file))
    }

    func testOfflineAndUncachedIsItsOwnState() {
        // Not `.failed`: nothing was attempted, so "couldn't download · tap to
        // retry" would be both untrue and useless.
        XCTAssertEqual(attachmentCardState(loaderState: nil, isOffline: true), .offlineAndUncached)
    }

    func testOfflineOutranksAFailureAndAnInFlightDownload() {
        // Going offline mid-download, or after one failed, should say the honest
        // thing rather than keep spinning or keep offering a doomed retry.
        XCTAssertEqual(attachmentCardState(loaderState: .failed, isOffline: true), .offlineAndUncached)
        XCTAssertEqual(attachmentCardState(loaderState: .downloading, isOffline: true), .offlineAndUncached)
    }

    // MARK: - What may be handed to QuickLook

    /// QuickLook renders HTML through WebKit, which fetches remote subresources
    /// — reopening, by another route, exactly the IP/User-Agent/timing
    /// disclosure the origin gate and `imageLoadPolicy` exist to close.
    func testMarkupTypesAreNeverPreviewable() throws {
        for ext in [
            "html", "htm", "xhtml", "xht", "shtml", "svg", "svgz", "xml", "xsl", "xslt",
            "mht", "mhtml", "webarchive", "epub", "webloc", "url",
        ] {
            XCTAssertFalse(attachmentIsPreviewable(try attachment(ext: ext)), "\(ext) must not be previewable")
        }
    }

    func testAnUppercaseMarkupExtensionIsAlsoRefused() throws {
        XCTAssertFalse(attachmentIsPreviewable(try attachment(ext: "HTML")))
        XCTAssertFalse(attachmentIsPreviewable(try attachment(ext: "SVG")))
    }

    /// The rule keys on the extension, not the `-unsafe` flag: a `.docx` sniffs
    /// as `zip` server-side and is flagged routinely, so keying on the flag
    /// would refuse to preview most ordinary Office attachments.
    func testOrdinaryDocumentTypesStayPreviewableIncludingUnsafeKeys() throws {
        for ext in ["pdf", "docx", "xlsx", "pptx", "odt", "png", "jpg", "zip", "txt", "csv"] {
            XCTAssertTrue(attachmentIsPreviewable(try attachment(ext: ext)), "\(ext) must stay previewable")
        }
        XCTAssertTrue(attachmentIsPreviewable(try attachment(ext: "docx", unsafe: true)))
    }

    // MARK: - Title

    func testTitleFallsBackToTheServerFileNameWhenTheLabelIsEmpty() throws {
        let origin = "https://docs.example.org"
        let url =
            "\(origin)/media/11111111-1111-4111-8111-111111111111/attachments/"
            + "22222222-2222-4222-8222-222222222222.pdf"
        let unnamed = try XCTUnwrap(parseAttachmentLink("[](\(url))", serverOrigin: origin))
        let named = try XCTUnwrap(parseAttachmentLink("[Q3 report.pdf](\(url))", serverOrigin: origin))

        XCTAssertEqual(attachmentDisplayTitle(unnamed), "22222222-2222-4222-8222-222222222222.pdf")
        XCTAssertEqual(attachmentDisplayTitle(named), "Q3 report.pdf")
    }
}
