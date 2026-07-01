import XCTest
@testable import DocsIOS

final class DocRowTests: XCTestCase {
    func testRestrictedShowsNoIndicator() {
        XCTAssertNil(docRowReachIndicatorSystemImage(reach: .restricted))
    }

    func testAuthenticatedShowsNetworkIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .authenticated), "network")
    }

    func testPublicShowsGlobeIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .public), "globe")
    }
}
