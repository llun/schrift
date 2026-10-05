import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class ThemeRenderingTests: XCTestCase {
    private func pixels<V: View>(_ view: V, theme: AppTheme, isDark: Bool) throws -> (CGImage, [UInt8]) {
        let renderer = ImageRenderer(
            content: view.environment(\.docsTheme, theme).environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image, bytes)
    }

    func testTheClosedSwipeMaskMatchesTheActualSidebarSurfaceRatherThanPaintingPageStrips() throws {
        for theme in [AppTheme.mist, .paper] {
            for isDark in [false, true] {
                for role in [DocsCanvasRole.sidebar, .page] {
                    let row = SwipeRevealRow(
                        id: "row", state: .constant(SwipeRevealState<String>()),
                        actions: [SwipeRevealAction(id: "pin", icon: .push_pin, label: "Pin", role: .brand) {}],
                        accessibilityLabel: "Row", onActivate: {}
                    ) {
                        Color.clear.frame(width: 300, height: 60)
                    }
                    .environment(\.docsCanvasRole, role)
                    let (image, bytes) = try pixels(row, theme: theme, isDark: isDark)
                    let offset = ((image.height / 2) * image.width + image.width - 10) * 4
                    let p = DocsPalette(theme: theme, isDark: isDark)
                    let expected = role == .sidebar ? p.surfaceSunken : p.surfacePage
                    XCTAssertEqual(Double(bytes[offset]), Double((expected >> 16) & 0xFF), accuracy: 1)
                    XCTAssertEqual(Double(bytes[offset + 1]), Double((expected >> 8) & 0xFF), accuracy: 1)
                    XCTAssertEqual(Double(bytes[offset + 2]), Double(expected & 0xFF), accuracy: 1)
                }
            }
        }
    }

    func testOffOriginAttachmentFallbackKeepsItsLinkInkWhenSwitchingToEditing() throws {
        let suite = "ThemeRenderingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!)
        let model = EditorViewModel(
            client: client, documentID: UUID(), title: "Doc",
            saveCoordinator: DocumentSaveCoordinator(client: client, backgroundTasks: .noop))
        let block = EditorBlock(
            kind: .attachment(name: "Report.pdf", url: "https://other.example.org/report.pdf"), text: "")
        model.blocks = [block]
        let loc = LocalizationStore(userDefaults: defaults)
        loc.language = .english
        for theme in [AppTheme.mist, .paper] {
            for isDark in [false, true] {
                let reading = MarkdownBlockView(block: block, serverOrigin: "https://docs.example.org")
                    .environment(loc).frame(width: 300, height: 60, alignment: .leading)
                    .background(theme.colors.surfacePage)
                let editing = BlockEditorRow(
                    viewModel: model, block: block, index: 0,
                    serverOrigin: "https://docs.example.org", isOffline: true
                )
                .environment(loc).frame(width: 300, height: 60, alignment: .leading)
                .background(theme.colors.surfacePage)
                let (_, readPixels) = try pixels(reading, theme: theme, isDark: isDark)
                let (_, editPixels) = try pixels(editing, theme: theme, isDark: isDark)
                XCTAssertEqual(readPixels, editPixels, "\(theme)-\(isDark) attachment link changed on edit")
            }
        }
    }
}
