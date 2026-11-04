import XCTest

@testable import Schrift

/// Splitting a paragraph with Enter.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - keyboardShortcut Enter at Hello|World
final class BlockNote056SplitParagraphTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMKSGVsbG9Xb3JsZCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcDcC1jAA==",
                xml:
                    #"<blockgroup><blockcontainer id="p-c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">HelloWorld</paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "keyboardShortcut Enter at Hello|World",
                updateBase64:
                    "AQgCAIcBAQMOYmxvY2tDb250YWluZXIHAAIAAwlwYXJhZ3JhcGgHAAIBBgQAAgIFV29ybGQoAAIBD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAIBCXRleHRDb2xvcgF3B2RlZmF1bHQoAAIBDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAACAAJpZAF3ATEBAQEJBQ==",
                xml:
                    #"<blockgroup><blockcontainer id="p-c"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hello</paragraph></blockcontainer><blockcontainer id="1"><paragraph backgroundColor="default" textAlignment="left" textColor="default">World</paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "c-split-paragraph / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
