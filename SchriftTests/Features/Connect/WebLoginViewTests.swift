import WebKit
import XCTest

@testable import Schrift

@MainActor
final class WebLoginViewTests: XCTestCase {
    func testLoginWebViewIsInspectableInDebugBuilds() {
        // Tests only build in Debug (`@testable import` needs testability), so this pins the
        // Debug half. Release safety rests on the `#if DEBUG` in `makeLoginWebView()`.
        #if DEBUG
            XCTAssertTrue(makeLoginWebView().isInspectable)
        #endif
    }
}
