import UniformTypeIdentifiers
import XCTest

@testable import Schrift

final class AttachmentPreparationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentPreparationTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    // MARK: - File-name sanitizing

    func testAnOrdinaryNameIsLeftAlone() {
        XCTAssertEqual(sanitizedAttachmentFileName("Q3 report.pdf"), "Q3 report.pdf")
        XCTAssertEqual(
            sanitizedAttachmentFileName("Bericht über Q3 – Änderungen.docx"), "Bericht über Q3 – Änderungen.docx")
        XCTAssertEqual(sanitizedAttachmentFileName("notes 📎.txt"), "notes 📎.txt")
    }

    /// The name is interpolated into a multipart `Content-Disposition` header,
    /// so a quote, CR or LF could break out of it.
    func testTheResultIsAlwaysASafeMultipartToken() {
        for hostile in [
            "a\"b.pdf", "a\r\nX-Evil: 1.pdf", "a\nb.pdf", "a\rb.pdf", "\"\"\".pdf", "a\u{0}b.pdf",
        ] {
            XCTAssertTrue(
                isSafeMultipartToken(sanitizedAttachmentFileName(hostile)),
                "\(hostile.debugDescription) must sanitize to a safe multipart token")
        }
    }

    /// The name is also the markdown link's label, and the block serializes to
    /// `[name](url)`. A bracket or paren there would stop that line parsing back
    /// as one link — the insert would fail its own verification, or the document
    /// would round-trip into something else.
    func testTheResultAlwaysRoundTripsAsAMarkdownLinkLabel() throws {
        let origin = "https://docs.example.org"
        let url =
            "\(origin)/media/11111111-1111-4111-8111-111111111111/attachments/"
            + "22222222-2222-4222-8222-222222222222.pdf"
        for hostile in [
            "a[b].pdf", "a(b).pdf", "](evil) [x.pdf", "[[[.pdf", ")))(((.pdf", "a]b[c.pdf",
        ] {
            let name = sanitizedAttachmentFileName(hostile)
            let parsed = parseAttachmentLink("[\(name)](\(url))", serverOrigin: origin)
            XCTAssertEqual(
                parsed?.name, name, "\(hostile.debugDescription) did not round-trip as a link label")
        }
    }

    func testSeparatorsAndLeadingDotsAreStripped() {
        XCTAssertEqual(sanitizedAttachmentFileName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(sanitizedAttachmentFileName("/absolute/path.pdf"), "absolutepath.pdf")
        XCTAssertEqual(sanitizedAttachmentFileName(".hidden.pdf"), "hidden.pdf")
        XCTAssertFalse(sanitizedAttachmentFileName("a/b\\c:d.pdf").contains(where: { "/\\:".contains($0) }))
    }

    func testAnEmptyOrFullyStrippedNameFallsBackToFile() {
        XCTAssertEqual(sanitizedAttachmentFileName(""), "file")
        XCTAssertEqual(sanitizedAttachmentFileName("   "), "file")
        XCTAssertEqual(sanitizedAttachmentFileName("[]()"), "file")
        XCTAssertEqual(sanitizedAttachmentFileName("..."), "file")
    }

    /// The cap must not eat the extension: the server derives the stored key's
    /// extension from this name, and a key without one makes `parseAttachmentLink`
    /// decline — so the insert would fail *after* a successful upload and leave
    /// an orphan on the server.
    func testALongNameIsCappedButKeepsItsExtension() {
        let name = sanitizedAttachmentFileName(String(repeating: "a", count: 500) + ".pdf")
        XCTAssertEqual(name.count, 120)
        XCTAssertTrue(name.hasSuffix(".pdf"), "the extension must survive the cap, got: \(name)")
    }

    func testALongNameWithNoExtensionIsStillCapped() {
        XCTAssertEqual(sanitizedAttachmentFileName(String(repeating: "a", count: 500)).count, 120)
    }

    // MARK: - Content type

    func testCommonExtensionsMapToTheirRealMIMEType() {
        XCTAssertEqual(attachmentContentType(forFileExtension: "pdf"), "application/pdf")
        XCTAssertEqual(attachmentContentType(forFileExtension: "PDF"), "application/pdf")
        XCTAssertEqual(attachmentContentType(forFileExtension: "png"), "image/png")
        XCTAssertEqual(
            attachmentContentType(forFileExtension: "docx"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    }

    func testAnUnknownOrMissingExtensionFallsBackToOctetStream() {
        XCTAssertEqual(attachmentContentType(forFileExtension: ""), "application/octet-stream")
        XCTAssertEqual(attachmentContentType(forFileExtension: "zzzznotathing"), "application/octet-stream")
    }

    // MARK: - Reading a picked file

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testReadsBytesNameAndTypeFromAPickedFile() throws {
        let payload = Data("%PDF-1.4\ncontent".utf8)
        let file = try loadPickedAttachmentFile(at: try write(payload, named: "Q3 report.pdf"))

        XCTAssertEqual(file.data, payload)
        XCTAssertEqual(file.fileName, "Q3 report.pdf")
        XCTAssertEqual(file.contentType, "application/pdf")
    }

    func testThePickedNameIsSanitizedOnTheWayIn() throws {
        let file = try loadPickedAttachmentFile(at: try write(Data([1]), named: "a[b](c).pdf"))
        XCTAssertEqual(file.fileName, "abc.pdf")
    }

    /// The limit holds. Which of the two guards caught it is not observable
    /// from here — they throw the same error — so this pins the rule, not the
    /// ordering; see `loadPickedAttachmentFile`.
    func testAnOversizedFileIsRefused() throws {
        let url = try write(Data(repeating: 0, count: 4096), named: "big.bin")
        do {
            _ = try loadPickedAttachmentFile(at: url, byteLimit: 1024)
            XCTFail("expected AttachmentImportError.tooLarge")
        } catch let error as AttachmentImportError {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    func testAFileExactlyAtTheLimitIsAccepted() throws {
        let url = try write(Data(repeating: 0, count: 1024), named: "exact.bin")
        XCTAssertEqual(try loadPickedAttachmentFile(at: url, byteLimit: 1024).data.count, 1024)
    }

    func testAMissingFileIsUnreadableRatherThanACrash() {
        let missing = directory.appendingPathComponent("nope.pdf")
        do {
            _ = try loadPickedAttachmentFile(at: missing)
            XCTFail("expected AttachmentImportError.unreadable")
        } catch let error as AttachmentImportError {
            XCTAssertEqual(error, .unreadable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
