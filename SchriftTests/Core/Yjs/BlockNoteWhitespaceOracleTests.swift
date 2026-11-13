import XCTest

@testable import Schrift

/// Edge whitespace against real BlockNote 0.56 (`BlockNoteWhitespaceCaptures`):
/// a block whose text starts or ends with spaces, tabs or NBSP, or whose marks
/// or link do, has a save shadow, and it is the exporter's own Markdown.
/// `htmlToMarkdown` keeps a block's edge whitespace and trims only the
/// document's ends; bold and italic move their trailing whitespace out of the
/// delimiters, strike, code and links keep it inside.
final class BlockNoteWhitespaceOracleTests: XCTestCase {
    /// The shadow spells each flagged root block on its own, so a list it
    /// splits restarts its numbering and turns loose, which the conflict
    /// comparison does not see.
    private static let canonicalOnly: Set<String> = ["lists"]

    func testEveryFixtureHasAShadowThatIsTheExport() throws {
        for fixture in BlockNoteWhitespaceCaptures.fixtures {
            let doc = YDoc(clientID: 9, gc: false)
            defer { doc.destroy() }
            try doc.applyUpdate(YUpdateDecoder.decode(try XCTUnwrap(Data(base64Encoded: fixture.update))))
            XCTAssertEqual(YXMLString.fragment(doc), fixture.xml, fixture.name)
            XCTAssertTrue(NativeBlockProjection.project(doc).isFullyModeled, fixture.name)
            guard let shadow = NativeBlockProjection.markdownShadow(doc) else {
                XCTFail("\(fixture.name): no shadow")
                continue
            }
            if Self.canonicalOnly.contains(fixture.name) {
                XCTAssertNotEqual(shadow, fixture.markdown, "\(fixture.name) is no longer canonical-only")
                XCTAssertEqual(syncCanonicalMarkdown(shadow), syncCanonicalMarkdown(fixture.markdown), fixture.name)
            } else {
                XCTAssertEqual(shadow, fixture.markdown, fixture.name)
            }
        }
    }
}
