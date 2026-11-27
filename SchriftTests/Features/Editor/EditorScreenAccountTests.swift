import XCTest

@testable import Schrift

@MainActor
final class EditorScreenAccountTests: EditorViewModelTestCase {
    /// A document only this device holds was the previous account's: the screen closes, and the
    /// model is replaced either way so its content never stays on screen under the new account.
    func testAnotherAccountReplacesTheModelAndClosesALocalDocument() throws {
        let env = makeLocalEnvironment()
        let suiteName = "EditorScreenAccountTests.availability.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let availabilityDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var deleted = false
        let screen = EditorScreen(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            documentID: env.document.id,
            title: env.document.title ?? "Untitled document",
            saveCoordinator: env.coordinator,
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            childrenCache: env.children,
            availability: OnlineAvailability(userDefaults: availabilityDefaults),
            reach: .restricted,
            serverHost: "docs.example.org",
            serverOrigin: "https://docs.example.org",
            onDeleted: { deleted = true })
        let old = screen.viewModel
        // The same store the coordinator's drafts read, so the screen sees the new account.
        env.viewModel.signedInUser.clear()
        env.viewModel.signedInUser.remember(UUID())

        let replaced = screen.replaceIfAnotherAccount()

        XCTAssertTrue(deleted)
        let installed = try XCTUnwrap(replaced)
        XCTAssertFalse(installed === old, "the old model's content must not stay on screen")
    }
}
