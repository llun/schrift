import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class ControlGeometryTests: XCTestCase {
    private func measured<V: View>(_ view: V, width: CGFloat = 300) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    func testEveryIconButtonVariantHasTheSameSquare44ptSurface() {
        for size in [IconButtonSize.small, .medium, .large] {
            for variant in [IconButtonVariant.ghost, .soft, .outline] {
                for disabled in [false, true] {
                    let box = measured(
                        IconButton(
                            icon: .share, label: "Share", variant: variant, size: size,
                            isDisabled: disabled, action: {}))
                    XCTAssertEqual(box.width, 44, accuracy: 0.5)
                    XCTAssertEqual(box.height, 44, accuracy: 0.5)
                }
            }
        }
    }

    func testSoftIconButtonPaintsACircleRatherThanRoundedSquare() throws {
        try assertCircularSurface(IconButton(icon: .share, label: "Share", variant: .soft, action: {}))
    }

    func testIconOnlySwipeActionsKeepCircularSurfacesAtAccessibilitySizes() throws {
        for role in [SwipeActionRole.neutral, .brand, .destructive] {
            for scheme in [ColorScheme.light, .dark] {
                try assertCircularSurface(
                    SwipeRevealActionLabel(
                        action: SwipeRevealAction(id: "action", icon: .share, label: "Share", role: role) {},
                        showsCaption: false
                    )
                    .dynamicTypeSize(.accessibility5),
                    colorScheme: scheme)
            }
        }
    }

    private func assertCircularSurface<V: View>(
        _ view: V,
        colorScheme: ColorScheme = .light,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first as? UIWindowScene, file: file, line: line)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = style
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        let fitted = host.sizeThatFits(in: CGSize(width: 300, height: 300))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.backgroundColor = .clear
        window.isOpaque = false
        window.frame = CGRect(origin: .zero, size: fitted)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = CGRect(origin: .zero, size: fitted)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let image = try XCTUnwrap(rendered.cgImage, file: file, line: line)
        XCTAssertEqual(image.width, 44, file: file, line: line)
        XCTAssertEqual(image.height, 44, file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: 44 * 44 * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: 44, height: 44, bitsPerComponent: 8, bytesPerRow: 44 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            file: file, line: line)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertTrue(
            stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 },
            "rendered surface must not be blank", file: file, line: line)
        // (5, 5) lies inside the old rounded rectangle and outside a 44pt circle.
        XCTAssertEqual(pixels[(5 * 44 + 5) * 4 + 3], 0, file: file, line: line)
        XCTAssertGreaterThan(pixels[(22 * 44 + 6) * 4 + 3], 240, file: file, line: line)
    }

    func testTextButtonsAndInputFieldsShare44ptMinimumHeight() {
        for size in [ButtonSize.small, .medium, .large] {
            XCTAssertEqual(measured(DocsButton(title: "Save", size: size, action: {})).height, 44, accuracy: 0.5)
        }
        XCTAssertEqual(measured(DocsTextField(text: .constant(""))).height, 44, accuracy: 0.5)
        for query in ["", "query"] {
            XCTAssertEqual(
                measured(SearchField(text: .constant(query)).environment(LocalizationStore())).height,
                44, accuracy: 0.5)
        }
    }

    func testRecentSearchAndEditorNoticeActionsShareTheControlHeight() {
        let recent = RecentSearchesFlow(terms: ["Roadmap"], onSelect: { _ in })
        let notice = EditorNoticeLabel(icon: .warning, title: "Review local changes", foreground: DocsColor.danger)
        XCTAssertEqual(measured(recent).height, 44, accuracy: 0.5)
        XCTAssertEqual(measured(notice).height, 44, accuracy: 0.5)
        XCTAssertGreaterThan(measured(recent.dynamicTypeSize(.accessibility5)).height, 44)
        XCTAssertGreaterThan(measured(notice.dynamicTypeSize(.accessibility5)).height, 44)
    }

    func testTextControlsCanGrowAtAccessibilitySizes() {
        let button = measured(DocsButton(title: "Save", action: {}).dynamicTypeSize(.accessibility5))
        let field = measured(DocsTextField(text: .constant("Document")).dynamicTypeSize(.accessibility5))
        XCTAssertGreaterThan(button.height, 44)
        XCTAssertGreaterThan(field.height, 44)
    }
}
