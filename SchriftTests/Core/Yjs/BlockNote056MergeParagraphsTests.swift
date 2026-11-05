import XCTest

@testable import Schrift

/// Merging paragraphs with Backspace.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - keyboardShortcut Backspace at second paragraph start
final class BlockNote056MergeParagraphsTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "AREBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMFSGVsbG8oAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3CXAtZC1maXJzdIcBAQMOYmxvY2tDb250YWluZXIHAAENAwlwYXJhZ3JhcGgHAAEOBgQAAQ8FV29ybGQoAAEOD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEOCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEODXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABDQJpZAF3CnAtZC1zZWNvbmQA",
                xml:
                    #"<blockgroup><blockcontainer id="p-d-first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hello</paragraph></blockcontainer><blockcontainer id="p-d-second"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "keyboardShortcut Backspace at second paragraph start",
                updateBase64: "AQECAIQBCAVXb3JsZAEBAQ0M",
                xml:
                    #"<blockgroup><blockcontainer id="p-d-first"><paragraph backgroundColor="default" textAlignment="left" textColor="default">HelloWorld</paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "d-merge-paragraphs / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
