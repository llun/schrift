import XCTest

@testable import Schrift

/// Tests the `WebLoginView.Coordinator` completion logic in isolation from
/// WebKit by driving its navigation-observation core (`handleNavigation(to:)`)
/// directly and injecting the cookie read as a closure seam.
///
/// These lock in the fix for the 2FA sign-in bug: completion must be reported as
/// soon as *any* observed navigation returns to the chosen server host on a
/// non-API path (a `didCommit` OR a `didFinish`), not only on a single final
/// full page load — which a multi-step 2FA / SPA-redirect flow can drop, leaving
/// the login sheet stuck open.
@MainActor
final class WebLoginCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        serverHost: String = "docs.llun.dev",
        onLoginComplete: @escaping @MainActor () -> Void
    ) -> WebLoginView.Coordinator {
        WebLoginView.Coordinator(
            serverHost: serverHost,
            onLoginComplete: onLoginComplete,
            // Skip the live WebKit cookie store; just run the completion.
            captureCookies: { completion in Task { @MainActor in completion() } }
        )
    }

    func testCommittedNavigationBackToAppReportsCompletion() async {
        var completed = false
        let coordinator = makeCoordinator { completed = true }

        coordinator.handleNavigation(to: URL(string: "https://docs.llun.dev/home/"))

        await waitUntil { completed }
        XCTAssertTrue(completed)
    }

    func testLandingOnBareServerRootReportsCompletion() async {
        var completed = false
        let coordinator = makeCoordinator { completed = true }

        // The docs backend's default LOGIN_REDIRECT_URL is the bare host with no
        // trailing slash (`https://docs.llun.dev`), whose path is "".
        coordinator.handleNavigation(to: URL(string: "https://docs.llun.dev"))

        await waitUntil { completed }
        XCTAssertTrue(completed)
    }

    func testNavigationStillOnIdentityProviderDoesNotComplete() async {
        var completed = false
        let coordinator = makeCoordinator { completed = true }

        coordinator.handleNavigation(
            to: URL(string: "https://idp.example.com/realms/docs/login-actions/authenticate?execution=OTP"))

        await waitUntil(timeout: 0.3) { completed }
        XCTAssertFalse(completed)
    }

    func testNavigationOnApiCallbackDoesNotComplete() async {
        var completed = false
        let coordinator = makeCoordinator { completed = true }

        coordinator.handleNavigation(to: URL(string: "https://docs.llun.dev/api/v1.0/callback/?code=abc&state=xyz"))

        await waitUntil(timeout: 0.3) { completed }
        XCTAssertFalse(completed)
    }

    func testNilNavigationURLDoesNotComplete() async {
        var completed = false
        let coordinator = makeCoordinator { completed = true }

        coordinator.handleNavigation(to: nil)

        await waitUntil(timeout: 0.3) { completed }
        XCTAssertFalse(completed)
    }

    func testReportsCompletionOnlyOnceAcrossMultipleNavigations() async {
        var completionCount = 0
        let coordinator = makeCoordinator { completionCount += 1 }

        // A real post-login landing fires both didCommit and didFinish (and the
        // SPA then client-redirects `/` -> `/home/`); completion must fire once.
        coordinator.handleNavigation(to: URL(string: "https://docs.llun.dev/"))
        coordinator.handleNavigation(to: URL(string: "https://docs.llun.dev/home/"))

        await waitUntil { completionCount >= 1 }
        await waitUntil(timeout: 0.3) { completionCount > 1 }
        XCTAssertEqual(completionCount, 1)
    }
}
