import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class MainTabViewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MainTabViewTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        MockURLProtocol.stubHandler = { request in
            let body = request.url!.path.contains("config") ? "{}" : "{\"count\":0,\"results\":[]}"
            return .init(statusCode: 200, headers: [:], body: Data(body.utf8), error: nil)
        }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func controllers<T: UIViewController>(in controller: UIViewController, of type: T.Type) -> [T] {
        (controller as? T).map { [$0] } ?? controller.children.flatMap { controllers(in: $0, of: type) }
    }

    func testSystemTabsEndWithTheExistingProfileAndKeepSeparateNavigationControllers() async throws {
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let host = UIHostingController(
            rootView: MainTabView(
                viewModel: HomeViewModel(
                    client: client, cache: DocumentCacheStore(userDefaults: defaults), userDefaults: defaults),
                serverHost: "docs.example.org", serverOrigin: "https://docs.example.org", signInGeneration: 0
            )
            .environment(LocalizationStore(userDefaults: defaults))
            .environment(AppearanceStore(userDefaults: defaults))
            .environment(AttachmentLoader.inert())
            .defaultAppStorage(defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        await waitUntil { !self.controllers(in: host, of: UITabBarController.self).isEmpty }
        let tabs = try XCTUnwrap(controllers(in: host, of: UITabBarController.self).first)
        let loc = LocalizationStore(userDefaults: defaults)
        XCTAssertEqual(tabs.tabBar.items?.map(\.title), [loc[.home_title], loc[.shared_title], loc[.common_profile]])
        // SwiftUI bridges through viewControllers on iOS 26 and through tabs on iOS 27.
        let destinationCount = tabs.tabs.isEmpty ? tabs.viewControllers?.count : tabs.tabs.count
        XCTAssertEqual(destinationCount, 3)
        XCTAssertFalse(tabs.tabs.contains { $0 is UISearchTab }, "Profile must be an ordinary primary tab")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Three native tabs"
        attachment.lifetime = .keepAlways
        add(attachment)

        tabs.selectedIndex = 1
        await waitUntil { !self.controllers(in: tabs.selectedViewController!, of: UINavigationController.self).isEmpty }
        let shared = try XCTUnwrap(controllers(in: tabs.selectedViewController!, of: UINavigationController.self).first)
        tabs.selectedIndex = 2
        await waitUntil { !self.controllers(in: tabs.selectedViewController!, of: UINavigationController.self).isEmpty }
        let profile = try XCTUnwrap(
            controllers(in: tabs.selectedViewController!, of: UINavigationController.self).first)
        XCTAssertFalse(shared === profile)
        XCTAssertNil(
            profile.topViewController?.navigationItem.searchController, "Profile must remain an account destination")
        tabs.selectedIndex = 1
        await waitUntil {
            self.controllers(in: tabs.selectedViewController!, of: UINavigationController.self).first === shared
        }
    }

    func testRegularWidthHomeRetainsSplitViewAndEditableInlineSearch() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Regular-width split sidebar is verified on the iPad simulator")
        }
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let home = HomeViewModel(
            client: client, cache: DocumentCacheStore(userDefaults: defaults), userDefaults: defaults)
        home.searchQuery = "Roadmap"
        let host = UIHostingController(
            rootView: MainTabView(
                viewModel: home, serverHost: "docs.example.org", serverOrigin: "https://docs.example.org",
                signInGeneration: 0
            )
            .environment(LocalizationStore(userDefaults: defaults))
            .environment(AppearanceStore(userDefaults: defaults))
            .environment(AttachmentLoader.inert())
            .environment(\.horizontalSizeClass, .regular)
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
        await waitUntil { !self.controllers(in: host, of: UISplitViewController.self).isEmpty }
        let split = try XCTUnwrap(controllers(in: host, of: UISplitViewController.self).last)
        XCTAssertNotNil(split.viewController(for: .secondary), "Home keeps the document detail alongside its sidebar")
        let loc = LocalizationStore(userDefaults: defaults)
        await waitUntil { self.textFields(in: host.view).contains { $0.placeholder == loc[.home_search_documents] } }
        let field = try XCTUnwrap(textFields(in: host.view).first { $0.placeholder == loc[.home_search_documents] })
        XCTAssertEqual(field.text, "Roadmap")
        XCTAssertTrue(field.isUserInteractionEnabled)
        XCTAssertEqual(home.searchQuery, "Roadmap")
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

}
