import SwiftUI
import XCTest

@testable import Schrift

/// Hosted coverage for Search's system field when it is a pushed destination. This catches
/// lifecycle changes (including search dismissal clearing text) that a model-only test misses.
@MainActor
final class SearchScreenNavigationTests: XCTestCase {
    @Observable
    final class Navigation {
        var path = NavigationPath()
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    func testPushedSearchExposesLocalizedFieldAndKeepsQueryAfterReturningFromDocumentAndHome() async throws {
        let suiteName = "SearchScreenNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("{\"count\":0,\"results\":[]}".utf8), error: nil)
        }
        let viewModel = SearchViewModel(client: client, store: RecentSearchesStore(userDefaults: defaults))
        viewModel.query = "Roadmap"
        viewModel.recordSearch()
        @Bindable var navigation = Navigation()
        let loc = LocalizationStore(userDefaults: defaults)
        let host = UIHostingController(
            rootView: NavigationStack(path: $navigation.path) {
                Text("Home")
                    .navigationTitle(loc[.home_title])
                    .navigationDestination(for: HomeRoute.self) { _ in
                        SearchScreen(viewModel: viewModel, serverHost: "docs.example.org") { document in
                            navigation.path.append(DocumentEditorRoute(document: document))
                        }
                    }
                    // Only Search's lifecycle is under test; the editor has its own hosted tests.
                    .navigationDestination(for: DocumentEditorRoute.self) { route in
                        Text(route.document.title ?? "")
                    }
            }
            .environment(loc)
            .defaultAppStorage(defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        navigation.path.append(HomeRoute.search)
        await waitUntil {
            self.navigationController(in: host)?.topViewController?.navigationItem.searchController != nil
        }
        let controller = try XCTUnwrap(navigationController(in: host))
        let field = try XCTUnwrap(controller.topViewController?.navigationItem.searchController?.searchBar)
        XCTAssertEqual(field.placeholder, loc[.search_placeholder])
        XCTAssertEqual(field.text, "Roadmap")
        XCTAssertFalse(controller.topViewController!.navigationItem.hidesSearchBarWhenScrolling)
        XCTAssertEqual(controller.topViewController?.navigationItem.title, loc[.search_title])
        XCTAssertEqual(controller.viewControllers.count, 2, "Search must have a native Home back destination")

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Pushed Search with native Home back button"
        attachment.lifetime = .keepAlways
        add(attachment)

        await waitUntil { controller.transitionCoordinator == nil }
        field.searchTextField.becomeFirstResponder()
        await waitUntil { field.searchTextField.isFirstResponder }
        await waitUntil { controller.transitionCoordinator == nil }

        let document = Document(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, title: "Roadmap",
            excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted, linkRole: .reader,
            isFavorite: false, depth: 1, numchild: 0, path: "0001", createdAt: Date(), updatedAt: Date(),
            userRole: nil, creator: nil)
        navigation.path.append(DocumentEditorRoute(document: document))
        await waitUntil { controller.viewControllers.count >= 3 }
        XCTAssertEqual(controller.viewControllers.count, 3)
        XCTAssertEqual(navigation.path.count, 2)
        navigation.path.removeLast()
        await waitUntil { controller.viewControllers.count == 2 }
        await waitUntil { controller.transitionCoordinator == nil }
        XCTAssertEqual(viewModel.query, "Roadmap")
        navigation.path.removeLast()
        await waitUntil { controller.viewControllers.count == 1 }
        // UIKit removes the popped controller before its animation completes.
        // Re-pushing during that transition can be dropped by NavigationStack.
        await waitUntil { controller.transitionCoordinator == nil }
        navigation.path.append(HomeRoute.search)
        await waitUntil { controller.topViewController?.navigationItem.searchController != nil }
        XCTAssertEqual(controller.topViewController?.navigationItem.searchController?.searchBar.text, "Roadmap")
        XCTAssertEqual(viewModel.recentSearches, ["Roadmap"])
    }
}
