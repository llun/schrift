import SwiftUI
import UIKit
import XCTest

@testable import Schrift

private struct ThemeEditingHarness: View {
    let theme: ThemeStore
    let model: EditorViewModel
    let loc: LocalizationStore

    var body: some View {
        BlockEditorRow(
            viewModel: model, block: model.blocks[0], index: 0,
            serverOrigin: "https://docs.example.org", isOffline: true
        )
        .environment(loc)
        .environment(\.docsTheme, theme.selected)
        .background(theme.selected.colors.surfacePage)
    }
}

@MainActor
final class EditorThemeTests: XCTestCase {
    private func textView(in view: UIView) -> EditorUITextView? {
        if let view = view as? EditorUITextView { return view }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    func testLiveThemeChangeRepaintsTheMountedEditorWithoutChangingItsState() async {
        let suite = "EditorThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DocsAPIClient(baseURL: URL(string: "https://docs.example.org/api/v1.0/")!)
        let drafts = PendingDraftStore(userDefaults: defaults)
        let coordinator = DocumentSaveCoordinator(client: client, draftStore: drafts, backgroundTasks: .noop)
        let model = EditorViewModel(client: client, documentID: UUID(), title: "Doc", saveCoordinator: coordinator)
        let source = "A [link](https://docs.example.org/) and **bold** text"
        model.blocks = [EditorBlock(kind: .paragraph, text: source)]
        model.mode = .blocks
        model.focusedBlockID = model.blocks[0].id
        let theme = ThemeStore(userDefaults: defaults)
        let loc = LocalizationStore(userDefaults: defaults)
        let host = UIHostingController(rootView: ThemeEditingHarness(theme: theme, model: model, loc: loc))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("The rendering test requires the application's window scene")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        await waitUntil { self.textView(in: host.view) != nil }
        guard let view = textView(in: host.view) else { return }
        await waitUntil { view.isFirstResponder }
        let selection = NSRange(location: 4, length: 2)
        view.selectedRange = selection
        let originalID = model.blocks[0].id
        let originalText = view.text
        let wasDirty = model.isDirty
        let saveState = coordinator.state(for: model.documentID)
        let font = view.font
        let oldColor = view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! UIColor
        for option in [AppTheme.paper, .mist, .white] {
            theme.selected = option
            let expected = UIColor(option.colors.textPrimary).resolvedColor(with: view.traitCollection)
            await waitUntil {
                guard let actual = view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
                else { return false }
                return actual.resolvedColor(with: view.traitCollection) == expected
            }
            XCTAssertTrue(textView(in: host.view) === view)
            XCTAssertEqual(view.text, originalText)
            XCTAssertEqual(view.selectedRange, selection)
            XCTAssertTrue(view.isFirstResponder)
            XCTAssertEqual(
                view.tintColor.resolvedColor(with: view.traitCollection),
                UIColor(option.colors.brandFill).resolvedColor(with: view.traitCollection))
            XCTAssertEqual(view.font?.pointSize, font?.pointSize)
            XCTAssertEqual(view.font?.fontName, font?.fontName)
            XCTAssertEqual(view.font?.fontDescriptor.symbolicTraits, font?.fontDescriptor.symbolicTraits)
            XCTAssertEqual(model.blocks[0].id, originalID)
            XCTAssertEqual(model.blocks[0].text, source)
            XCTAssertEqual(model.isDirty, wasDirty)
            XCTAssertEqual(coordinator.state(for: model.documentID), saveState)
            XCTAssertNil(drafts.draft(for: model.documentID))
            let link = view.textStorage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as! UIColor
            XCTAssertEqual(
                link.resolvedColor(with: view.traitCollection),
                UIColor(option.colors.textBrand).resolvedColor(with: view.traitCollection))
        }
        let restoredColor = view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(
            restoredColor?.resolvedColor(with: view.traitCollection), oldColor.resolvedColor(with: view.traitCollection)
        )
    }

    func testReadingAndTypingUseTheSameThemeForEveryTextBlock() {
        let kinds: [BlockKind] = [
            .paragraph, .heading(level: 1), .quote, .checklistItem(checked: true), .codeBlock(language: "swift"),
            .unknown,
        ]
        for theme in AppTheme.allCases {
            for kind in kinds {
                let block = EditorBlock(kind: kind, text: "Some text")
                let reading = blockTextAppearance(for: kind, text: block.text, theme: theme)
                let typing = blockTextStyling(for: block, theme: theme)
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let traits = UITraitCollection(userInterfaceStyle: style)
                    XCTAssertEqual(
                        UIColor(reading.color).resolvedColor(with: traits), typing.textColor.resolvedColor(with: traits)
                    )
                }
                XCTAssertEqual(typing.theme, theme)
            }
        }
    }
}
