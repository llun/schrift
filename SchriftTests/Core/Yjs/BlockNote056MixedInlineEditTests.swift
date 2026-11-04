import XCTest

@testable import Schrift

/// Editing text beside mention, interlink and math inline nodes.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - insertText ! in middle of middle text run
final class BlockNote056MixedInlineEditTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "ARoBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMHQmVmb3JlIIcBAwMRdXNlck1lbnRpb25JbmxpbmUoAAELBnVzZXJJZAF3BnVzZXItMSgAAQsIZnVsbE5hbWUBdwxBZGEgTG92ZWxhY2WHAQsGBAABDgggbWlkZGxlIIcBDgMWaW50ZXJsaW5raW5nTGlua0lubGluZSgAARcFZG9jSWQBdwVkb2MtMSgAARcHYmxvY2tJZAF3CHRhcmdldC0xKAABFwhkaXNhYmxlZAF5KAABFwd0cmlnZ2VyAXcBL4cBFwYEAAEcBiBtYXRoIIcBHAMEbWF0aAcAASMGBAABJAN4XjKHASMGBAABKAYgYWZ0ZXIoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3A3AtZwA=",
                xml:
                    #"<blockgroup><blockcontainer id="p-g"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Before <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> middle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "insertText ! in middle of middle text run",
                updateBase64: "AQECAMQBEgETASEA",
                xml:
                    #"<blockgroup><blockcontainer id="p-g"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Before <usermentioninline fullName="Ada Lovelace" userId="user-1"></usermentioninline> mid!dle <interlinkinglinkinline blockId="target-1" disabled="false" docId="doc-1" trigger="/"></interlinkinglinkinline> math <math>x^2</math> after</paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "g-mixed-inline-edit / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
