import Observation
import SwiftUI
import UIKit
import XCTest

@testable import Schrift

@MainActor
final class BlockTextFocusTests: XCTestCase {
    @MainActor @Observable final class Fixture {
        var text = "Tail 😀"
        var isFocused = true
        var request: EditorViewModel.CursorRequest? = .init(blockID: UUID(), offset: 5)
        var focusEvents = 0
    }

    private struct Probe: View {
        @Bindable var fixture: Fixture

        var body: some View {
            BlockTextView(
                text: { fixture.text },
                styling: blockTextStyling(for: EditorBlock(kind: .paragraph, text: fixture.text)),
                isFocused: { fixture.isFocused },
                cursorRequest: { fixture.request },
                onEvent: { event in
                    if case .textChanged(let text) = event { fixture.text = text }
                    switch event {
                    case .beganEditing, .endedEditing: fixture.focusEvents += 1
                    default: break
                    }
                },
                onCursorRequestHandled: { token in
                    if fixture.request?.token == token { fixture.request = nil }
                }
            )
        }
    }

    private func textView(in view: UIView) -> EditorUITextView? {
        if let text = view as? EditorUITextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func withDetachedRow(
        _ body: @MainActor (Fixture, UIHostingController<Probe>, EditorUITextView, UIWindow) async throws -> Void
    ) async throws {
        let fixture = Fixture()
        fixture.isFocused = false
        fixture.request = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Probe(fixture: fixture))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        await waitUntil { self.textView(in: host.view) != nil }
        let text = try XCTUnwrap(textView(in: host.view))

        host.view.removeFromSuperview()
        XCTAssertNil(text.window)
        fixture.isFocused = true
        fixture.request = .init(blockID: UUID(), offset: 5)
        _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
        host.view.layoutIfNeeded()
        await waitUntil { fixture.request == nil }
        XCTAssertNil(text.window)
        XCTAssertFalse(text.isFirstResponder)
        XCTAssertEqual(text.selectedRange, NSRange(location: 5, length: 0))

        // Attach the realized UIKit row directly so SwiftUI cannot supply a coincidental
        // update after attachment. The observed failure is precisely the absence of one.
        text.removeFromSuperview()
        text.frame = CGRect(x: 0, y: 100, width: 370, height: 100)
        try await body(fixture, host, text, window)
    }

    /// The lazy canvas may consume the caret request and re-render before the new row
    /// attaches. Attaching must fulfill the latest focus intent without another update.
    func testFocusSurvivesCursorConsumptionBeforeWindowAttachment() async throws {
        try await withDetachedRow { fixture, _, text, window in
            window.addSubview(text)
            XCTAssertTrue(text.isFirstResponder, "The row attached after its last focus update")
            XCTAssertEqual(text.selectedRange, NSRange(location: 5, length: 0))
            XCTAssertEqual(fixture.focusEvents, 0, "programmatic focus must suppress delegate echoes")
            text.insertText("continued ")
            await waitUntil { fixture.text == "Tail continued 😀" }
        }
    }

    func testAttachmentDoesNotReplayCancelledFocusIntent() async throws {
        try await withDetachedRow { fixture, host, text, window in
            // Consuming another request proves the coordinator received the cancelled
            // focus value while the row was still detached.
            fixture.isFocused = false
            fixture.request = .init(blockID: UUID(), offset: 0)
            _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
            await waitUntil { fixture.request == nil }
            let other = UITextField(frame: CGRect(x: 0, y: 250, width: 370, height: 44))
            window.addSubview(other)
            XCTAssertTrue(other.becomeFirstResponder())
            window.addSubview(text)
            XCTAssertFalse(text.isFirstResponder)
            XCTAssertTrue(other.isFirstResponder, "a stale attachment callback must not steal focus")
            XCTAssertEqual(fixture.focusEvents, 0)
        }
    }

    func testTypingBeforeSplitRowAttachmentReachesNewParagraph() async throws {
        try await checkImmediateTypingAfterReturn(text: "Before", expectedKind: .paragraph)
        try await checkImmediateTypingAfterReturn(text: "---", expectedKind: .divider)
    }

    private func checkImmediateTypingAfterReturn(text source: String, expectedKind: BlockKind) async throws {
        try await withRow(text: source) { vm, host, text, _ in
            let sourceID = vm.blocks[0].id
            text.selectedRange = NSRange(location: (source as NSString).length, length: 0)
            type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            type("a", in: text)
            type("f", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID])
            XCTAssertEqual(vm.blocks[0].kind, expectedKind)
            XCTAssertEqual(vm.blocks[0].text, expectedKind == .divider ? "" : source)
            XCTAssertEqual(try XCTUnwrap(vm.blocks.last).text, "af")
            XCTAssertEqual(vm.cursorRequest?.offset, 2)
            XCTAssertEqual(vm.selection, NSRange(location: 2, length: 0))
            XCTAssertEqual(vm.currentMarkdown(), "\(expectedKind == .divider ? "---" : source)\n\naf\n")
            let target = try XCTUnwrap(vm.blocks.last)
            host.rootView = AnyView(
                BlockEditorRow(
                    viewModel: vm, block: target, index: 1, serverOrigin: "https://docs.example.org", isOffline: true
                )
                .id(target.id).environment(LocalizationStore()))
            await waitUntil {
                guard let attached = self.textView(in: host.view) else { return false }
                return attached !== text && attached.isFirstResponder && attached.text == "af"
            }
            let attached = try XCTUnwrap(self.textView(in: host.view))
            XCTAssertEqual(attached.selectedRange, NSRange(location: 2, length: 0))
            self.type("ter", in: attached)
            XCTAssertEqual(vm.blocks[1].text, "after")
            XCTAssertEqual(attached.text, "after")
        }
    }

    func testPendingSplitPreservesEmojiSuffixAndBackspaceDeletesWholeCharacter() async throws {
        try await withRow(text: "lead 😀tail") { vm, _, text, _ in
            let sourceID = vm.blocks[0].id
            text.selectedRange = NSRange(location: 7, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            self.type("😀", in: text)
            text.deleteBackward()
            self.type("X", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID])
            XCTAssertEqual(vm.blocks.map(\.text), ["lead 😀", "Xtail"])
            XCTAssertEqual(vm.cursorRequest?.offset, 1)
            XCTAssertEqual(vm.currentMarkdown(), "lead 😀\n\nXtail\n")
        }
    }

    func testPendingReturnsAndBackspaceUseCurrentDestination() async throws {
        try await withRow(text: "---") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 3, length: 0)
            self.type("\n", in: text)
            self.type("a", in: text)
            let paragraphID = try XCTUnwrap(vm.focusedBlockID)
            self.type("\n", in: text)
            text.deleteBackward()  // Merge the empty target into the preceding paragraph.
            text.deleteBackward()  // Delete "a" at the model caret, not at the old divider.
            text.deleteBackward()  // Remove the preceding divider as a unit.
            self.type("rest", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [paragraphID])
            XCTAssertEqual(vm.blocks.map(\.text), ["rest"])
            XCTAssertEqual(vm.blocks[0].kind, .paragraph)
            XCTAssertEqual(vm.cursorRequest?.offset, 4)
            XCTAssertEqual(vm.currentMarkdown(), "rest\n")
        }
    }

    func testPendingReplacementAndCodeReturnPreserveSelectionSemantics() async throws {
        try await withRow(text: "Before") { vm, _, text, _ in
            let id = vm.blocks[0].id
            vm.cursorRequest = .init(blockID: id, offset: 1, length: 2)
            self.type("X", in: text)
            XCTAssertEqual(vm.blocks[0].text, "BXore")
            vm.blocks[0].kind = .codeBlock(language: "")
            vm.cursorRequest = .init(blockID: id, offset: 0)
            self.type("\n", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [id])
            XCTAssertEqual(vm.blocks[0].text, "\nBXore")
            let applied = try XCTUnwrap(vm.cursorRequest)
            XCTAssertEqual(applied.offset, 1)
            XCTAssertFalse(vm.applyPendingKeyboardInput(from: id, text: "ordinary", consumedCursorToken: applied.token))
            XCTAssertEqual(vm.blocks[0].text, "\nBXore")
        }
    }

    func testPendingBackspaceSkipsHiddenLinkSyntax() async throws {
        try await withRow(text: "[Review](https://example.org)") { vm, _, text, _ in
            let id = vm.blocks[0].id
            vm.cursorRequest = .init(blockID: id, offset: (vm.blocks[0].text as NSString).length)
            text.deleteBackward()
            XCTAssertEqual(vm.blocks[0].id, id)
            XCTAssertEqual(vm.blocks[0].text, "[Revie](https://example.org)")
            XCTAssertEqual(vm.cursorRequest?.offset, 6)
        }
    }

    func testCorrectionOfSourceWordDuringSplitDoesNotBecomeDestinationInput() async throws {
        try await withRow(text: "teh tail") { vm, _, text, _ in
            let sourceID = vm.blocks[0].id
            text.selectedRange = NSRange(location: 3, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            let correction = NSRange(location: 0, length: 3)
            let allowed = text.delegate?.textView?(text, shouldChangeTextIn: correction, replacementText: "the") ?? true
            if allowed {
                text.text = (text.text as NSString).replacingCharacters(in: correction, with: "the")
                text.delegate?.textViewDidChange?(text)
            }
            XCTAssertEqual(vm.blocks.map(\.text), ["the", " tail"])
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID])
            XCTAssertEqual(vm.cursorRequest?.offset, 0)
            XCTAssertEqual(vm.selection, NSRange(location: 0, length: 0))
        }
    }

    func testObsoleteSourceCorrectionCannotRestoreLeafSyntaxOrMovedText() async throws {
        try await withRow(text: "---") { vm, _, text, _ in
            let id = vm.blocks[0].id
            text.selectedRange = NSRange(location: 3, length: 0)
            self.type("\n", in: text)
            let allowed = text.delegate?.textView?(
                text, shouldChangeTextIn: NSRange(location: 0, length: 3), replacementText: "the")
            XCTAssertEqual(allowed, false)
            XCTAssertEqual(vm.blocks[0].id, id)
            XCTAssertEqual(vm.blocks[0].kind, .divider)
            XCTAssertEqual(vm.blocks.map(\.text), ["", ""])
        }
        try await withRow(text: "teh tail") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 3, length: 0)
            self.type("\n", in: text)
            let allowed = text.delegate?.textView?(
                text, shouldChangeTextIn: NSRange(location: 0, length: 8), replacementText: "the tail")
            XCTAssertEqual(allowed, false)
            XCTAssertEqual(vm.blocks.map(\.text), ["teh", " tail"])
        }
    }

    func testPendingPrefixCorrectionUsesCoordinatesAfterConsumedSyntax() async throws {
        try await withRow(text: "[]teh") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 2, length: 0)
            self.type(" ", in: text)
            // Recreate the older UIKit snapshot while a fresh caret token is
            // unapplied; publication reconciliation may already have run here.
            vm.cursorRequest = .init(blockID: vm.blocks[0].id, offset: 0)
            let coordinator = try XCTUnwrap(text.delegate as? BlockTextView.Coordinator)
            coordinator.consumedCursorToken = nil
            text.text = "[] teh"
            text.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertEqual(vm.blocks[0].text, "teh")
            XCTAssertEqual(vm.focusedBlockID, vm.blocks[0].id)
            XCTAssertNotEqual(vm.cursorRequest?.token, coordinator.consumedCursorToken)
            let range = NSRange(location: 3, length: 3)
            let allowed = text.delegate?.textView?(text, shouldChangeTextIn: range, replacementText: "the") ?? true
            if allowed {
                text.text = (text.text as NSString).replacingCharacters(in: range, with: "the")
                text.delegate?.textViewDidChange?(text)
            }
            XCTAssertEqual(vm.blocks[0].kind, .checklistItem(checked: false))
            XCTAssertEqual(vm.blocks[0].text, "the")
            XCTAssertEqual(vm.cursorRequest?.offset, 0)
            XCTAssertEqual(vm.currentMarkdown(), "- [ ] the\n")
        }
    }

    func testConsecutiveSourceCorrectionsRejectObsoleteCoordinates() async throws {
        try await withRow(text: "cant adn") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 8, length: 0)
            self.type("\n", in: text)
            XCTAssertEqual(
                text.delegate?.textView?(
                    text, shouldChangeTextIn: NSRange(location: 0, length: 4), replacementText: "can't"), false)
            // The rejected UIKit edit leaves the old buffer's offsets intact.
            // A second old-coordinate correction must not edit the shifted model.
            XCTAssertEqual(
                text.delegate?.textView?(
                    text, shouldChangeTextIn: NSRange(location: 5, length: 3), replacementText: "and"), false)
            XCTAssertEqual(vm.blocks.map(\.text), ["can't adn", ""])
            XCTAssertEqual(vm.cursorRequest?.offset, 0)
        }
    }

    func testShorteningRepeatedSourceTextInvalidatesOlderCorrectionCoordinates() async throws {
        try await withRow(text: "aaaa tail") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            XCTAssertEqual(
                text.delegate?.textView?(
                    text, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementText: ""), false)
            // Keep the still-pending UIKit snapshot. Its prefix happens to match
            // the shortened model even though its later offsets are obsolete.
            text.text = "aaaa tail"
            XCTAssertEqual(
                text.delegate?.textView?(
                    text, shouldChangeTextIn: NSRange(location: 2, length: 1), replacementText: "x"), false)
            XCTAssertEqual(vm.blocks.map(\.text), ["aaa", " tail"])
        }
    }

    func testTypedTextIsPublishedBeforeStylingCanReenterModelUpdates() async throws {
        try await withRow(text: "a") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 1, length: 0)
            let seen = Fixture()
            seen.focusEvents = 0
            seen.text = ""
            let observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: text.textStorage, queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    seen.focusEvents += 1
                    // The native character edit is first; the following attribute
                    // pass can reenter SwiftUI through UIKit layout/notifications.
                    if seen.focusEvents == 2 { seen.text = vm.blocks[0].text }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            self.type("f", in: text)
            XCTAssertGreaterThanOrEqual(seen.focusEvents, 2)
            XCTAssertEqual(seen.text, "af", "publish the delegate's buffer before attribute edits")
        }
    }

    func testObservationWillSetCannotRestoreOlderTextDuringDelegatePublication() async throws {
        try await withRow(text: "a") { vm, host, text, row in
            text.selectedRange = NSRange(location: 1, length: 0)
            let observed = Fixture()
            observed.focusEvents = 0
            withObservationTracking {
                _ = vm.blocks[0].text
            } onChange: {
                MainActor.assumeIsolated {
                    observed.focusEvents += 1
                    // Observation notifies before the model write finishes. UIKit
                    // can run this queued row update during that notification.
                    host.rootView = AnyView(row.environment(LocalizationStore()))
                    _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
                }
            }
            self.type("f", in: text)
            XCTAssertEqual(observed.focusEvents, 1)
            XCTAssertTrue(self.textView(in: host.view) === text)
            XCTAssertEqual(vm.blocks[0].text, "af")
            XCTAssertEqual(text.text, "af")
            XCTAssertEqual(text.selectedRange, NSRange(location: 2, length: 0))
        }
    }

    func testTypingBeforeShortcutCaretUpdateUsesCorrectedOffset() async throws {
        try await withRow(text: "[]") { vm, _, text, _ in
            let id = vm.blocks[0].id
            text.selectedRange = NSRange(location: 2, length: 0)
            type(" ", in: text)
            type("T", in: text)
            type("ask", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [id])
            XCTAssertEqual(vm.blocks[0].kind, .checklistItem(checked: false))
            XCTAssertEqual(vm.blocks[0].text, "Task")
            XCTAssertEqual(text.selectedRange, NSRange(location: 4, length: 0))
            XCTAssertEqual(vm.selection, NSRange(location: 4, length: 0))
            XCTAssertEqual(vm.currentMarkdown(), "- [ ] Task\n")
        }
    }

    func testQueuedRowSnapshotDoesNotOverwriteNewerTypedText() async throws {
        try await withRow(text: "a") { vm, host, text, row in
            let id = vm.blocks[0].id
            text.selectedRange = NSRange(location: 1, length: 0)
            text.insertText("f")
            XCTAssertEqual(vm.blocks[0].text, "af")
            // Re-render the row snapshot queued before the latest delegate event.
            host.rootView = AnyView(row.environment(LocalizationStore()))
            _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
            await waitAndConfirmNever { text.text != "af" }
            XCTAssertEqual(vm.blocks[0].id, id)
            XCTAssertEqual(text.selectedRange, NSRange(location: 2, length: 0))
            XCTAssertEqual(vm.currentMarkdown(), "af\n")
        }
    }

    private func type(_ value: String, in text: EditorUITextView) {
        let allowed =
            text.delegate?.textView?(text, shouldChangeTextIn: text.selectedRange, replacementText: value) ?? true
        if allowed {
            text.insertText(value)
            text.delegate?.textViewDidChangeSelection?(text)
        }
    }

    private func withRow(
        text source: String,
        _ body:
            @MainActor (EditorViewModel, UIHostingController<AnyView>, EditorUITextView, BlockEditorRow) async throws ->
            Void
    ) async throws {
        let suiteName = "BlockTextFocusTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!,
            session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let cache = DocumentContentCacheStore(directory: directory)
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), contentCache: cache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults), backgroundTasks: .noop)
        let vm = EditorViewModel(
            client: client, documentID: UUID(), title: "Disposable", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: cache,
            childrenCache: DocumentChildrenCacheStore(userDefaults: defaults))
        let queuedBlock = EditorBlock(kind: .paragraph, text: source)
        vm.blocks = [queuedBlock]
        vm.mode = .blocks
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let row = BlockEditorRow(
            viewModel: vm, block: queuedBlock, index: 0, serverOrigin: "https://docs.example.org", isOffline: true)
        let host = UIHostingController(rootView: AnyView(row.environment(LocalizationStore(userDefaults: defaults))))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        await waitUntil { self.textView(in: host.view) != nil }
        let text = try XCTUnwrap(textView(in: host.view))
        text.becomeFirstResponder()
        try await body(vm, host, text, row)
    }
}
