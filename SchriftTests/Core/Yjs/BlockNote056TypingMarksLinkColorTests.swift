import XCTest

@testable import Schrift

/// Typing with bold, a link and a text-color run.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - insertText Hi
/// - toggleStyles bold on; type there; bold off
/// - insert space and createLink
/// - type textColor run
final class BlockNote056TypingMarksLinkColorTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "AQcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3A3AtYQA=",
                xml:
                    #"<blockgroup><blockcontainer id="p-a"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "insertText Hi ",
                updateBase64: "AQICAAcAAQIGBAACAANIaSAA",
                xml:
                    #"<blockgroup><blockcontainer id="p-a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hi </paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "toggleStyles bold on; type there; bold off",
                updateBase64: "AQMCBIQCAwV0aGVyZcYCAwIEBGJvbGQCe32GAggEYm9sZARudWxsAA==",
                xml:
                    #"<blockgroup><blockcontainer id="p-a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hi <bold>there</bold></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "insert space and createLink",
                updateBase64:
                    "AQUCC8QCCAIKASDGAggCCwRib2xkBG51bGyEAgoEbGlua8YCCgINBGxpbmsfeyJocmVmIjoiaHR0cHM6Ly9leGFtcGxlLmNvbS8ifYYCEARsaW5rBG51bGwBAgEKAQ==",
                xml:
                    #"<blockgroup><blockcontainer id="p-a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hi <bold>there</bold> <link href="https://example.com/">link</link></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "type textColor run",
                updateBase64:
                    "AQQCE8QCEAISBCByZWTGAhACEwRsaW5rBG51bGzGAhcCEwl0ZXh0Q29sb3IVeyJzdHJpbmdWYWx1ZSI6InJlZCJ9hgISCXRleHRDb2xvcgRudWxsAQICCgESAQ==",
                xml:
                    #"<blockgroup><blockcontainer id="p-a"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Hi <bold>there</bold> <link href="https://example.com/">link</link><textColor stringValue="red"> red</textColor></paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "a-typing-marks-link-color / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
