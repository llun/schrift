import XCTest

@testable import Schrift

/// Toggling bold on and off over a selected text range.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - toggleStyles bold on over cdef
/// - toggleStyles bold off over cdef
final class BlockNote056ToggleBoldOnOffTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "AQkBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMJYWJjZGVmZ2hpKAABAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQECaWQBdwNwLWIA",
                xml:
                    #"<blockgroup><blockcontainer id="p-b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">abcdefghi</paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "toggleStyles bold on over cdef",
                updateBase64: "AQICAMYBBQEGBGJvbGQCe33GAQkBCgRib2xkBG51bGwA",
                xml:
                    #"<blockgroup><blockcontainer id="p-b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">ab<bold>cdef</bold>ghi</paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "toggleStyles bold off over cdef",
                updateBase64: "AAECAQAC",
                xml:
                    #"<blockgroup><blockcontainer id="p-b"><paragraph backgroundColor="default" textAlignment="left" textColor="default">abcdefghi</paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "b-toggle-bold-on-off / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
