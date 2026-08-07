import XCTest

@testable import Schrift

final class AttachmentDisplayTests: XCTestCase {
    private let serverOrigin = "https://docs.example.org"
    private let documentUUID = "11111111-1111-4111-8111-111111111111"
    private let fileUUID = "22222222-2222-4222-8222-222222222222"

    private func url(_ fileName: String, origin: String? = nil, document: String? = nil) -> String {
        "\(origin ?? serverOrigin)/media/\(document ?? documentUUID)/attachments/\(fileName)"
    }

    private func link(_ fileName: String, label: String = "f") -> String {
        "[\(label)](\(url(fileName)))"
    }

    private func display(_ text: String, serverOrigin origin: String? = nil) -> AttachmentDisplay? {
        parseAttachmentLink(text, serverOrigin: origin ?? serverOrigin)
    }

    // MARK: - What an attachment link looks like

    func testClassifiesAnUploadedPDF() {
        let result = display(link("\(fileUUID).pdf", label: "Report.pdf"))
        XCTAssertEqual(result?.name, "Report.pdf")
        XCTAssertEqual(result?.urlString, url("\(fileUUID).pdf"))
        XCTAssertEqual(result?.documentUUID, documentUUID)
        XCTAssertEqual(result?.fileUUID, fileUUID)
        XCTAssertEqual(result?.fileExtension, "pdf")
        XCTAssertEqual(result?.isUnsafeKey, false)
    }

    func testClassifiesEveryOrdinaryAttachmentExtension() {
        for ext in ["docx", "xlsx", "pptx", "odt", "zip", "csv", "txt", "png", "mp4", "7z"] {
            XCTAssertNotNil(display(link("\(fileUUID).\(ext)")), "\(ext) must classify")
        }
    }

    func testClassifiesAnUnsafeKey() throws {
        // A .docx sniffs as zip server-side and is stored "-unsafe". The bytes
        // still download; only the server's Content-Disposition differs.
        let result = try XCTUnwrap(display(link("\(fileUUID)-unsafe.docx", label: "Notes.docx")))
        XCTAssertTrue(result.isUnsafeKey)
        XCTAssertEqual(result.fileUUID, fileUUID)
        XCTAssertEqual(attachmentFileName(for: result), "\(fileUUID)-unsafe.docx")
    }

    func testClassifiesAnEmptyLabel() throws {
        // What a `file` block with no name exports.
        let result = try XCTUnwrap(display(link("\(fileUUID).pdf", label: "")))
        XCTAssertEqual(result.name, "")
        XCTAssertEqual(attachmentDisplayTitle(result), "\(fileUUID).pdf")
    }

    func testTitlePrefersTheLabel() throws {
        let result = try XCTUnwrap(display(link("\(fileUUID).pdf", label: "Q3 plan.pdf")))
        XCTAssertEqual(attachmentDisplayTitle(result), "Q3 plan.pdf")
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertNotNil(display("   \(link("\(fileUUID).pdf"))  "))
    }

    func testLabelMayContainParenthesesAndSpaces() {
        XCTAssertEqual(
            display(link("\(fileUUID).pdf", label: "Report (final) v2.pdf"))?.name, "Report (final) v2.pdf")
    }

    func testUppercaseSchemeAndHostStillClassify() {
        // The author's byte-for-byte spelling is preserved, and siteOrigin
        // lowercases both sides — the same rule imageLoadPolicy relies on.
        let shouted = "HTTPS://DOCS.Example.ORG/media/\(documentUUID)/attachments/\(fileUUID).pdf"
        let result = display("[f](\(shouted))")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.urlString, shouted)
    }

    func testMatchingNonDefaultPortClassifies() {
        let origin = "https://docs.example.org:8443"
        XCTAssertNotNil(
            display("[f](\(url("\(fileUUID).pdf", origin: origin)))", serverOrigin: origin))
    }

    func testAnotherDocumentsAttachmentStillClassifies() {
        // Copy-paste between documents is legitimate; a 403 on download is the
        // server's call to make, not the classifier's.
        let other = "33333333-3333-4333-8333-333333333333"
        XCTAssertEqual(display("[f](\(url("\(fileUUID).pdf", document: other)))")?.documentUUID, other)
    }

    // MARK: - Origin: an off-origin url is never an attachment

    func testForeignHostDeclines() {
        XCTAssertNil(display("[f](https://evil.com/media/\(documentUUID)/attachments/\(fileUUID).pdf)"))
    }

    func testUserinfoHostSpoofDeclines() {
        // Hosted at evil.com. A string prefix comparison would be fooled.
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", origin: "https://docs.example.org@evil.com")))"))
    }

    func testSuffixHostSpoofDeclines() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", origin: "https://docs.example.org.evil.com")))"))
    }

    func testSubdomainDeclines() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", origin: "https://cdn.docs.example.org")))"))
    }

    func testSchemeDowngradeDeclines() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", origin: "http://docs.example.org")))"))
    }

    func testDifferentPortDeclines() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", origin: "https://docs.example.org:8443")))"))
    }

    func testRelativeAndProtocolRelativeURLsDecline() {
        XCTAssertNil(display("[f](/media/\(documentUUID)/attachments/\(fileUUID).pdf)"))
        XCTAssertNil(display("[f](//docs.example.org/media/\(documentUUID)/attachments/\(fileUUID).pdf)"))
    }

    func testEmptyServerOriginNeverClassifies() {
        // Fail closed: an unknown server must not make everything an attachment.
        XCTAssertNil(display(link("\(fileUUID).pdf"), serverOrigin: ""))
    }

    // MARK: - Path shape

    func testNonAttachmentPathsOnTheServerDecline() {
        for path in [
            "/media/\(documentUUID)/other/\(fileUUID).pdf",
            "/media/\(documentUUID)/attachments/\(fileUUID).pdf/extra",
            "/media/\(documentUUID)/attachments",
            "/media/\(fileUUID).pdf",
            "/docs/\(documentUUID)/",
            "/api/v1.0/documents/\(documentUUID)/",
            "/attachments/\(fileUUID).pdf",
        ] {
            XCTAssertNil(display("[f](https://docs.example.org\(path))"), "\(path) must decline")
        }
    }

    func testNonUUIDComponentsDecline() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", document: "not-a-uuid")))"))
        XCTAssertNil(display(link("not-a-uuid.pdf")))
        XCTAssertNil(display(link("\(fileUUID)-other.pdf")))
    }

    func testMissingOrMalformedExtensionDeclines() {
        XCTAssertNil(display(link(fileUUID)))
        XCTAssertNil(display(link("\(fileUUID).")))
        XCTAssertNil(display(link("\(fileUUID).tar.gz")))
        XCTAssertNil(display(link("\(fileUUID).pdf!")))
        XCTAssertNil(display(link("\(fileUUID).abcdefghijk")))
    }

    func testQueryOrFragmentDeclines() {
        // The server's storage pattern is anchored at the extension.
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf"))?v=2)"))
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf"))#page=2)"))
    }

    func testTrailingSlashDeclines() {
        // pathComponents drops it; the re-composed-path identity check is what
        // catches this.
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf"))/)"))
    }

    func testEncodedTraversalDeclines() {
        // %2e%2e%2f decodes into extra path components — nothing that reaches
        // the cache's file naming can be anything but a UUID and an extension.
        XCTAssertNil(display(link("%2e%2e%2f%2e%2e%2fetc%2fpasswd.pdf")))
        XCTAssertNil(display(link("%2e%2e.pdf")))
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf", document: "%2e%2e")))"))
    }

    // MARK: - Link shape

    func testAnImageLineIsNotAnAttachment() {
        XCTAssertNil(display("![alt](\(url("\(fileUUID).pdf")))"))
    }

    func testTrailingOrLeadingTextDeclines() {
        XCTAssertNil(display("See \(link("\(fileUUID).pdf"))"))
        XCTAssertNil(display("\(link("\(fileUUID).pdf")) — attached"))
    }

    func testTwoLinksOnOneLineDecline() {
        let attachment = url("\(fileUUID).pdf")
        XCTAssertNil(display("[a](\(attachment))[b](\(attachment))"))
        XCTAssertNil(display("[a](\(attachment)) [b](\(attachment))"))
    }

    func testBracketsInTheLabelDecline() {
        XCTAssertNil(display("[a]b](\(url("\(fileUUID).pdf")))"))
        XCTAssertNil(display("[a[b](\(url("\(fileUUID).pdf")))"))
    }

    func testWhitespaceInTheURLDeclines() {
        XCTAssertNil(display("[f](\(url("\(fileUUID).pdf")) )"))
    }

    func testEmptyURLDeclines() {
        XCTAssertNil(display("[f]()"))
    }

    func testPlainProseAndOrdinaryLinksDecline() {
        XCTAssertNil(display("Just a paragraph."))
        XCTAssertNil(display("[Docs](https://docs.example.org/docs/\(documentUUID)/)"))
        XCTAssertNil(display(""))
    }

    // MARK: - Block-level classification

    func testOnlyParagraphBlocksClassify() {
        let text = link("\(fileUUID).pdf")
        XCTAssertNotNil(attachmentDisplay(for: EditorBlock(kind: .paragraph, text: text), serverOrigin: serverOrigin))
        for kind: BlockKind in [
            .unknown, .quote, .bulletItem, .numberedItem, .checklistItem(checked: false),
            .heading(level: 1), .codeBlock(language: ""), .divider,
        ] {
            XCTAssertNil(
                attachmentDisplay(for: EditorBlock(kind: kind, text: text), serverOrigin: serverOrigin),
                "\(kind) must not classify")
        }
    }

    func testAnAttachmentLineInsideAMultiLineUnknownBlockDoesNotClassify() throws {
        // The adjacency contract: with no blank line between, the parser makes
        // one .unknown block, and a card must not misrepresent it.
        let blocks = parseEditorBlocks("Attached:\n\(link("\(fileUUID).pdf"))")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .unknown)
        XCTAssertNil(attachmentDisplay(for: try XCTUnwrap(blocks.first), serverOrigin: serverOrigin))
    }

    func testAStandaloneAttachmentLineParsesAsAParagraphAndClassifies() {
        // PR1's whole premise: the parser is untouched, so the card has to be
        // reachable from the .paragraph the existing parser already mints.
        let blocks = parseEditorBlocks("Intro\n\n\(link("\(fileUUID).pdf"))\n\nOutro")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph, .paragraph])
        XCTAssertNotNil(attachmentDisplay(for: blocks[1], serverOrigin: serverOrigin))
        XCTAssertNil(attachmentDisplay(for: blocks[0], serverOrigin: serverOrigin))
    }

    // MARK: - Derived values

    func testMediaPathIsRootedSameOriginAndRebuiltFromValidatedParts() throws {
        let result = try XCTUnwrap(display(link("\(fileUUID).pdf")))
        let path = try XCTUnwrap(attachmentMediaPath(for: result, serverOrigin: serverOrigin))
        XCTAssertEqual(path, "/media/\(documentUUID)/attachments/\(fileUUID).pdf")
        XCTAssertTrue(isSameOriginPath(path))
    }

    func testMediaPathKeepsTheUnsafeSuffix() throws {
        let result = try XCTUnwrap(display(link("\(fileUUID)-unsafe.docx")))
        XCTAssertEqual(
            attachmentMediaPath(for: result, serverOrigin: serverOrigin),
            "/media/\(documentUUID)/attachments/\(fileUUID)-unsafe.docx")
    }

    func testMediaPathReChecksTheOrigin() throws {
        // An AttachmentDisplay is freely constructible, so the derivation must
        // not assume the classifier vouched for this one.
        let result = try XCTUnwrap(display(link("\(fileUUID).pdf")))
        XCTAssertNil(attachmentMediaPath(for: result, serverOrigin: "https://other.example.org"))
        XCTAssertNil(attachmentMediaPath(for: result, serverOrigin: ""))
    }

    func testCacheFileNameNeverContainsTheAuthorsLabel() throws {
        // The label is the one author-controlled string here; it must not reach
        // the filesystem.
        let result = try XCTUnwrap(display(link("\(fileUUID).pdf", label: "../../etc/passwd")))
        let fileName = attachmentFileName(for: result)
        XCTAssertEqual(fileName, "\(fileUUID).pdf")
        XCTAssertFalse(fileName.contains("/"))
        XCTAssertFalse(fileName.contains(".."))
    }
}
