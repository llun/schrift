import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class NewDocumentToolbarButtonTests: XCTestCase {
    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// This fixture has exactly one toolbar action. Find its outermost surface
    /// by size and trailing placement, without naming UIKit's private wrappers
    /// or depending on accessibility bundles being loaded on a fresh simulator.
    private func buttonSurface(in root: UIView) -> UIView? {
        guard let bar = views(in: root).first(where: { $0 is UINavigationBar }) else { return nil }
        return views(in: bar).first { view in
            let bounds = view.bounds
            return bounds.width >= 44 && bounds.height >= 44
                && bounds.width < 100 && bounds.height < 100
                && view.convert(bounds, to: bar).midX > bar.bounds.midX
        }
    }

    func testNativeToolbarButtonIsCircularAtNormalAndAccessibilitySizes() async throws {
        let suite = "NewDocumentToolbarButtonTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(userDefaults: defaults)
        localization.language = .english
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        for size in [DynamicTypeSize.large, .accessibility3] {
            for scheme in [ColorScheme.light, .dark] {
                let host = UIHostingController(
                    rootView: NavigationStack {
                        Color.clear
                            .navigationTitle("Schrift")
                            .navigationSubtitle("docs.example.org")
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    NewDocumentToolbarButton(action: {})
                                }
                            }
                    }
                    .environment(localization)
                    .environment(\.dynamicTypeSize, size)
                    .preferredColorScheme(scheme))
                window.rootViewController = host
                window.makeKeyAndVisible()
                await waitUntil { self.buttonSurface(in: host.view) != nil }
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Create button \(size) \(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)

                let surface = try XCTUnwrap(buttonSurface(in: host.view))
                XCTAssertEqual(surface.bounds.width, surface.bounds.height, accuracy: 1, "\(size), \(scheme)")
                XCTAssertLessThan(surface.bounds.width, 100, "measure the button, not the whole bar")
            }
        }
    }
}
