import XCTest

@testable import Schrift

/// Creating and editing a table, adding rows and columns, and toggling its header.
/// Captured from yjs 13.6.33 + BlockNote 0.56.0 with the session-local S3 harness.
/// Step labels:
/// - create 2x2 table with insertBlocks
/// - insertText Cell in first cell
/// - addRowAfter first row
/// - addColumnAfter first column
/// - toggleHeaderRow
final class BlockNote056TableOperationsTests: XCTestCase {
    func testEveryStepIntegratesAndMatchesYjsXML() throws {
        continueAfterFailure = false
        // The source peers use default gc:true; gc:false must preserve the same visible XML.
        let doc = YDoc(clientID: 9, gc: false)
        defer { doc.destroy() }

        let checkpoints: [(label: String, updateBase64: String, xml: String)] = [
            (
                label: "seed",
                updateBase64:
                    "AQ0BAAcBDmRvY3VtZW50LXN0b3JlAwpibG9ja0dyb3VwBwABAAMOYmxvY2tDb250YWluZXIHAAEBAwlwYXJhZ3JhcGgoAAECD2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAECCXRleHRDb2xvcgF3B2RlZmF1bHQoAAECDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABAQJpZAF3BmxlYWQtaIcBAQMOYmxvY2tDb250YWluZXIHAAEHAwlwYXJhZ3JhcGgoAAEID2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAEICXRleHRDb2xvcgF3B2RlZmF1bHQoAAEIDXRleHRBbGlnbm1lbnQBdwRsZWZ0KAABBwJpZAF3BnRhaWwtaAA=",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "create 2x2 table with insertBlocks",
                updateBase64:
                    "ASICAMcBAQEHAw5ibG9ja0NvbnRhaW5lcgcAAgADBXRhYmxlBwACAQMIdGFibGVSb3cHAAICAwl0YWJsZUNlbGwHAAIDAw50YWJsZVBhcmFncmFwaCgAAgMJdGV4dENvbG9yAXcHZGVmYXVsdCgAAgMPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAgMNdGV4dEFsaWdubWVudAF3BGxlZnQoAAIDB2NvbHNwYW4BfQEoAAIDB3Jvd3NwYW4BfQGHAgMDCXRhYmxlQ2VsbAcAAgoDDnRhYmxlUGFyYWdyYXBoKAACCgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACCg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACCg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAgoHY29sc3BhbgF9ASgAAgoHcm93c3BhbgF9AYcCAgMIdGFibGVSb3cHAAIRAwl0YWJsZUNlbGwHAAISAw50YWJsZVBhcmFncmFwaCgAAhIJdGV4dENvbG9yAXcHZGVmYXVsdCgAAhIPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAhINdGV4dEFsaWdubWVudAF3BGxlZnQoAAISB2NvbHNwYW4BfQEoAAISB3Jvd3NwYW4BfQGHAhIDCXRhYmxlQ2VsbAcAAhkDDnRhYmxlUGFyYWdyYXBoKAACGQl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACGQ9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACGQ10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAhkHY29sc3BhbgF9ASgAAhkHcm93c3BhbgF9ASgAAgEJdGV4dENvbG9yAXcHZGVmYXVsdCgAAgACaWQBdwd0YWJsZS1oAA==",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="table-h"><table textColor="default"><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow></table></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "insertText Cell in first cell",
                updateBase64: "AQICIgcAAgQGBAACIgRDZWxsAA==",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="table-h"><table textColor="default"><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph>Cell</tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow></table></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "addRowAfter first row",
                updateBase64:
                    "AQ8CJ4cCEQMIdGFibGVSb3cHAAInAwl0YWJsZUNlbGwHAAIoAw50YWJsZVBhcmFncmFwaCgAAigJdGV4dENvbG9yAXcHZGVmYXVsdCgAAigPYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAigNdGV4dEFsaWdubWVudAF3BGxlZnQoAAIoB2NvbHNwYW4BfQEoAAIoB3Jvd3NwYW4BfQGHAigDCXRhYmxlQ2VsbAcAAi8DDnRhYmxlUGFyYWdyYXBoKAACLwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACLw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACLw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAi8HY29sc3BhbgF9ASgAAi8Hcm93c3BhbgF9AQA=",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="table-h"><table textColor="default"><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph>Cell</tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow></table></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "addColumnAfter first column",
                updateBase64:
                    "ARUCNocCCgMJdGFibGVDZWxsBwACNgMOdGFibGVQYXJhZ3JhcGgoAAI2CXRleHRDb2xvcgF3B2RlZmF1bHQoAAI2D2JhY2tncm91bmRDb2xvcgF3B2RlZmF1bHQoAAI2DXRleHRBbGlnbm1lbnQBdwRsZWZ0KAACNgdjb2xzcGFuAX0BKAACNgdyb3dzcGFuAX0BhwIvAwl0YWJsZUNlbGwHAAI9Aw50YWJsZVBhcmFncmFwaCgAAj0JdGV4dENvbG9yAXcHZGVmYXVsdCgAAj0PYmFja2dyb3VuZENvbG9yAXcHZGVmYXVsdCgAAj0NdGV4dEFsaWdubWVudAF3BGxlZnQoAAI9B2NvbHNwYW4BfQEoAAI9B3Jvd3NwYW4BfQGHAhkDCXRhYmxlQ2VsbAcAAkQDDnRhYmxlUGFyYWdyYXBoKAACRAl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACRA9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACRA10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAkQHY29sc3BhbgF9ASgAAkQHcm93c3BhbgF9AQA=",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="table-h"><table textColor="default"><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph>Cell</tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow></table></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
            (
                label: "toggleHeaderRow",
                updateBase64:
                    "ARcCS0cCAwMLdGFibGVIZWFkZXIHAAJLAw50YWJsZVBhcmFncmFwaAcAAkwGBAACTQRDZWxsKAACSwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACSw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACSw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAksHY29sc3BhbgF9ASgAAksHcm93c3BhbgF9AccCSwIDAwt0YWJsZUhlYWRlcgcAAlcDDnRhYmxlUGFyYWdyYXBoKAACVwl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACVw9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACVw10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAlcHY29sc3BhbgF9ASgAAlcHcm93c3BhbgF9AccCVwIDAwt0YWJsZUhlYWRlcgcAAl4DDnRhYmxlUGFyYWdyYXBoKAACXgl0ZXh0Q29sb3IBdwdkZWZhdWx0KAACXg9iYWNrZ3JvdW5kQ29sb3IBdwdkZWZhdWx0KAACXg10ZXh0QWxpZ25tZW50AXcEbGVmdCgAAl4HY29sc3BhbgF9ASgAAl4Hcm93c3BhbgF9AQECAwMOIgU2Bw==",
                xml:
                    #"<blockgroup><blockcontainer id="lead-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer><blockcontainer id="table-h"><table textColor="default"><tablerow><tableheader backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph>Cell</tableparagraph></tableheader><tableheader backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tableheader><tableheader backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tableheader></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow><tablerow><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell><tablecell backgroundColor="default" colspan="1" rowspan="1" textAlignment="left" textColor="default"><tableparagraph></tableparagraph></tablecell></tablerow></table></blockcontainer><blockcontainer id="tail-h"><paragraph backgroundColor="default" textAlignment="left" textColor="default"></paragraph></blockcontainer></blockgroup>"#
            ),
        ]

        for checkpoint in checkpoints {
            let context = "h-table-operations / \(checkpoint.label)"
            let update = try XCTUnwrap(Data(base64Encoded: checkpoint.updateBase64), context)
            try doc.applyUpdate(try YUpdateDecoder.decode(update))
            XCTAssertEqual(YXMLString.fragment(doc), checkpoint.xml, context)
            XCTAssertNil(doc.store.pendingStructs, "\(context): pending structs")
            XCTAssertNil(doc.store.pendingDs, "\(context): pending deletes")
        }
    }
}
