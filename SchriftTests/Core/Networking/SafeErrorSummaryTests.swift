import XCTest

@testable import Schrift

final class SafeErrorSummaryTests: XCTestCase {
    private struct Probe: Decodable {
        let title: String
        let items: [Item]
        struct Item: Decodable { let when: Date }
    }

    private func summary(of json: String) -> String {
        do {
            _ = try JSONDecoder.docsAPI.decode(Probe.self, from: Data(json.utf8))
            return "<decoded>"
        } catch { return safeErrorSummary(error) }
    }

    func testDecodingKindsReportThePathAndNoValues() {
        XCTAssertEqual(summary(of: #"{"title": "x"}"#), "keyNotFound(items) at (root)")
        XCTAssertEqual(summary(of: #"{"title": 7, "items": []}"#), "typeMismatch(String) at title")
        XCTAssertEqual(summary(of: "not json"), "dataCorrupted at (root)")
    }

    /// `docsAPI`'s date strategy puts the server's string in its `debugDescription`.
    func testADecodingDescriptionNeverCarriesThePayload() {
        let text = summary(of: #"{"title": "x", "items": [{"when": "SECRET-PAYLOAD"}]}"#)
        XCTAssertEqual(text, "dataCorrupted at items › [0] › when")
        XCTAssertFalse(text.contains("SECRET"))
    }

    func testIDShapedPathKeysAreElided() {
        let id = UUID().uuidString
        let error = DecodingError.keyNotFound(
            AnyKey(id), .init(codingPath: [AnyKey(id)], debugDescription: "leaks \(id)"))
        XCTAssertEqual(safeErrorSummary(error), "keyNotFound(…) at …")
    }

    func testOtherErrorsReportTypeAndCaseOnly() {
        XCTAssertEqual(
            safeErrorSummary(DocsAPIError.network("https://host/documents/\(UUID())")), "DocsAPIError.network")
        XCTAssertEqual(safeErrorSummary(DocsAPIError.server(statusCode: 502)), "DocsAPIError.server(502)")
        XCTAssertEqual(safeErrorSummary(DocsAPIError.forbidden), "DocsAPIError.forbidden")
        XCTAssertEqual(safeErrorSummary(URLError(.notConnectedToInternet)), "URLError(-1009)")
        XCTAssertEqual(safeErrorSummary(ReplicaSaveError.pendingCreate), "ReplicaSaveError.pendingCreate")
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
