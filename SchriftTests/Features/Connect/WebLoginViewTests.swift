import WebKit
import XCTest

@testable import Schrift

@MainActor
final class WebLoginViewTests: XCTestCase {
    func testLoginWebViewIsInspectableInDebugBuilds() {
        // CI tests the Debug configuration only; Release safety rests on the `#if DEBUG`
        // in `makeLoginWebView()`, and the `#else` half guards any Release-configured run.
        let webView = makeLoginWebView()
        #if DEBUG
            XCTAssertTrue(webView.isInspectable)
        #else
            XCTAssertFalse(webView.isInspectable)
        #endif
    }
}
