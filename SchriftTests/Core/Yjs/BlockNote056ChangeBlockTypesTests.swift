import XCTest

@testable import Schrift

/// Changing paragraph and list block types.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - updateBlock paragraph to heading level 2
/// - updateBlock bullet to checkListItem
final class BlockNote056ChangeBlockTypesTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "ARcBAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgHAAECBgQAAQMFVGl0bGUoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3A3AtZYcBAQMOYmxvY2tDb250YWluZXIHAAENAw5idWxsZXRMaXN0SXRlbQcAAQ4GBAABDwRUYXNrKAABDg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAABDgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAABDg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAQ0CaWQBdwRsaS1lhwENAw5ibG9ja0NvbnRhaW5lcgcAARgDCXBhcmFncmFwaCgAARkPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAARkJdGV4dENvbG9yAXcHZGVmYXVsdCgAARkNdGV4dEFsaWdubWVudAF3BGxlZnQoAAEYAmlkAXcGdGFpbC1lAA==",
                xml:
                    #"<blockgroup><blockcontainer id="p-e"><paragraph backgroundColor="default" textAlignment="left" textColor="default">Title</paragraph></blockcontainer><blockcontainer id="li-e"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">Task</bulletlistitem></blockcontainer><blockcontainer id="tail-e"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "updateBlock paragraph to heading level 2",
                updateBase64:
                    "AQgCAEcBAgMHaGVhZGluZwcAAgAGBAACAQVUaXRsZSgAAgAPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAgAJdGV4dENvbG9yAXcHZGVmYXVsdCgAAgANdGV4dEFsaWdubWVudAF3BGxlZnQoAAIABWxldmVsAX0CKAACAAxpc1RvZ2dsZWFibGUBeQEBAQIK",
                xml:
                    #"<blockgroup><blockcontainer id="p-e"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">Title</heading></blockcontainer><blockcontainer id="li-e"><bulletlistitem backgroundColor="default" textAlignment="left" textColor="default">Task</bulletlistitem></blockcontainer><blockcontainer id="tail-e"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "updateBlock bullet to checkListItem",
                updateBase64:
                    "AQcCDEcBDgMNY2hlY2tMaXN0SXRlbQcAAgwGBAACDQRUYXNrKAACDA9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACDAl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACDA10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAgwHY2hlY2tlZAF5AQECAgoOCQ==",
                xml:
                    #"<blockgroup><blockcontainer id="p-e"><heading backgroundColor="default" isToggleable="false" level="2" textAlignment="left" textColor="default">Title</heading></blockcontainer><blockcontainer id="li-e"><checklistitem backgroundColor="default" checked="false" textAlignment="left" textColor="default">Task</checklistitem></blockcontainer><blockcontainer id="tail-e"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "e-change-block-types / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
