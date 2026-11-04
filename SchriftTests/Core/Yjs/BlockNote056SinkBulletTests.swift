import XCTest

@testable import Schrift

/// Sinking a bullet into a nested list.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - prosemirror-schema-list sinkListItem(blockContainer)
final class BlockNote056SinkBulletTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "ARcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAw5idWxsZXRMaXN0SXRlbQcAAQIGBAABAwVGaXJzdCgAAQIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAQIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAQINdGV4dEFsaWdubWVudAF3BGxlZnQoAAEBAmlkAXcKbGktZi1maXJzdIcBAQMOYmxvY2tDb250YWluZXIHAAENAw5idWxsZXRMaXN0SXRlbQcAAQ4GBAABDwZTZWNvbmQoAAEOD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEOCXRleHRDb2xvcgF3B2RlZmF1bHQoAAEODXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABDQJpZAF3C2xpLWYtc2Vjb25khwENAw5ibG9ja0NvbnRhaW5lcgcAARoDCXBhcmFncmFwaCgAARsPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARsJdGV4dENvbG9yAXcHZGVmYXVsdCgAARsNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEaAmlkAXcGdGFpbC1mAA==",
                xml:
                    #"<blockgroup><blockcontainer id="li-f-first"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">First</bulletlistitem></blockcontainer><blockcontainer id="li-f-second"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">Second</bulletlistitem></blockcontainer><blockcontainer id="tail-f"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "prosemirror-schema-list sinkListItem(blockContainer)",
                updateBase64:
                    "AQkCAIcBAgMKYmxvY2tHcm91cAcAAgADDmJsb2NrQ29udGFpbmVyBwACAQMOYnVsbGV0TGlzdEl0ZW0HAAICBgQAAgMGU2Vjb25kKAACAg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACAgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACAg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAgECaWQBdwtsaS1mLXNlY29uZAEBAQ0N",
                xml:
                    #"<blockgroup><blockcontainer id="li-f-first"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">First</bulletlistitem><blockgroup><blockcontainer id="li-f-second"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">Second</bulletlistitem></blockcontainer></blockgroup></blockcontainer><blockcontainer id="tail-f"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "f-sink-bullet / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
