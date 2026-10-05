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
                    .dynamicTypeSize(.accessibility5)
                    .preferredColorScheme(scheme))
            }
        }
    }

    private func assertCircularSurface<V: View>(_ view: V) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        XCTAssertEqual(image.width, 44)
        XCTAssertEqual(image.height, 44)
        var pixels = [UInt8](repeating: 0, count: 44 * 44 * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: 44, height: 44, bitsPerComponent: 8, bytesPerRow: 44 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 44, height: 44))
        // (5, 5) lies inside the old rounded rectangle and outside a 44pt circle.
        XCTAssertEqual(pixels[(5 * 44 + 5) * 4 + 3], 0)
        XCTAssertGreaterThan(pixels[(22 * 44 + 6) * 4 + 3], 240)
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

    func testTextControlsCanGrowAtAccessibilitySizes() {
        let button = measured(DocsButton(title: "Save", action: {}).dynamicTypeSize(.accessibility5))
        let field = measured(DocsTextField(text: .constant("Document")).dynamicTypeSize(.accessibility5))
        XCTAssertGreaterThan(button.height, 44)
        XCTAssertGreaterThan(field.height, 44)
    }
}
