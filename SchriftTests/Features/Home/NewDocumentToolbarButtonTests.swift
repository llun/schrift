import SwiftUI
import XCTest

@testable import Schrift

@MainActor
final class NewDocumentToolbarButtonTests: XCTestCase {
    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// The glass surface encloses the accessible label's host. Measure the first
    /// enclosing view with a full tap-target size, without naming UIKit's private
    /// toolbar wrapper classes (which differ between OS releases).
    private func buttonSurface(enclosing label: UIView) -> UIView? {
        var candidate: UIView? = label
        while let view = candidate {
            if view.bounds.width >= 44 && view.bounds.height >= 44 { return view }
            candidate = view.superview
        }
        return nil
    }

    func testNativeToolbarButtonIsCircularAtNormalAndAccessibilitySizes() async throws {
        let suite = "NewDocumentToolbarButtonTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
                    .environment(LocalizationStore(userDefaults: defaults))
                    .environment(\.dynamicTypeSize, size)
                    .preferredColorScheme(scheme))
                window.rootViewController = host
                window.makeKeyAndVisible()
                await waitUntil {
                    self.views(in: host.view).contains { $0.accessibilityLabel == "New doc" && $0.bounds.height > 0 }
                }
                host.view.layoutIfNeeded()
                let label = try XCTUnwrap(views(in: host.view).first { $0.accessibilityLabel == "New doc" })
                let surface = try XCTUnwrap(buttonSurface(enclosing: label))
                XCTAssertEqual(surface.bounds.width, surface.bounds.height, accuracy: 1, "\(size), \(scheme)")
                XCTAssertLessThan(surface.bounds.width, 100, "measure the button, not the whole bar")

                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Create button \(size) \(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
