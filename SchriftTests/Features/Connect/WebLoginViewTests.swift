import WebKit
import XCTest

@testable import Schrift

@MainActor
final class WebLoginViewTests: XCTestCase {
    func testLoginWebViewIsInspectableOnlyInDebugBuilds() {
        let webView = makeLoginWebView()
        #if DEBUG
            XCTAssertTrue(webView.isInspectable)
        #else
            XCTAssertFalse(webView.isInspectable)
        #endif
    }
}
