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

    /// The row's `abilities.update` is the previous account's answer. A swapped screen must fail
    /// closed — no live socket, read-only — until a fresh fetch says otherwise.
    func testAnotherAccountDropsTheRowsAbilities() throws {
        let env = makeLocalEnvironment()
        let suiteName = "EditorScreenAccountTests.pinRow.\(UUID().uuidString)"
        draftSuiteNames.append(suiteName)
        let availabilityDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var abilities = DocumentAbilities()
        abilities.update = true
        let row = Document(
            id: env.document.id, title: "Doc", excerpt: nil, abilities: abilities,
            linkReach: .restricted, linkRole: .editor, isFavorite: false,
            depth: 1, numchild: 0, path: "0001",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            userRole: nil, creator: nil)
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
            pinRow: row)
        XCTAssertEqual(screen.pinRow.row?.abilities.update, true)

        env.viewModel.signedInUser.clear()
        env.viewModel.signedInUser.remember(UUID())
        XCTAssertNotNil(screen.replaceIfAnotherAccount())

        XCTAssertNil(screen.pinRow.row, "the previous account's abilities must not survive the swap")
    }
}
