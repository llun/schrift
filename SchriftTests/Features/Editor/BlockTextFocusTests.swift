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
            _ = fixture.isFocused
            _ = fixture.request
            return BlockTextView(
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

    private func textViews(in view: UIView) -> [EditorUITextView] {
        if let text = view as? EditorUITextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
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
        try await withDetachedRow { fixture, _, text, window in
            // Cancellation must be read on attachment without a coincidental
            // SwiftUI update of the manually detached UIKit view.
            fixture.isFocused = false
            let other = UITextField(frame: CGRect(x: 0, y: 250, width: 370, height: 44))
            window.addSubview(other)
            XCTAssertTrue(other.becomeFirstResponder())
            window.addSubview(text)
            XCTAssertFalse(text.isFirstResponder)
            XCTAssertTrue(other.isFirstResponder, "a stale attachment callback must not steal focus")
            XCTAssertEqual(fixture.focusEvents, 0)
        }
    }

    func testFocusOnlyCancellationResignsAttachedRow() async throws {
        let fixture = Fixture()
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
        await waitUntil { self.textView(in: host.view)?.isFirstResponder == true && fixture.request == nil }
        let text = try XCTUnwrap(textView(in: host.view))
        fixture.isFocused = false
        await waitUntil { !text.isFirstResponder }
        XCTAssertNil(fixture.request)
    }

    func testCursorOnlyRequestUpdatesExistingRow() async throws {
        try await withRow(text: "abc") { vm, _, text, _ in
            let block = vm.blocks[0]
            text.selectedRange = NSRange(location: 0, length: 0)
            vm.cursorRequest = .init(blockID: block.id, offset: 2)
            await waitUntil { vm.cursorRequest == nil }
            XCTAssertEqual(text.selectedRange, NSRange(location: 2, length: 0))
            XCTAssertEqual(vm.blocks, [block])
            XCTAssertEqual(vm.focusedBlockID, block.id)
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

    func testMarkedCompositionImmediatelyAfterMidParagraphReturnUsesDestination() async throws {
        try await withRow(text: "lead tail") { vm, _, text, _ in
            let sourceID = vm.blocks[0].id
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            // No yield or destination render between Return and the native IME call.
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID])
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に tail"])
            XCTAssertEqual(vm.focusedBlockID, targetID)
            XCTAssertEqual(vm.selection, NSRange(location: 1, length: 0))
            text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "日本 tail"])
            text.unmarkText()
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "日本 tail"])
            XCTAssertEqual(vm.currentMarkdown(), "lead\n\n日本 tail\n")
        }
    }

    func testOrdinaryMarkedCompositionKeepsUIKitReplacementAndUTF16Selection() async throws {
        try await withRow(text: "lead 😀tail") { vm, _, text, _ in
            let id = vm.blocks[0].id
            text.selectedRange = NSRange(location: 5, length: 2)
            text.setMarkedText("に😀", selectedRange: NSRange(location: 1, length: 2))
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertEqual(text.text, "lead に😀tail")
            XCTAssertEqual(text.selectedRange, NSRange(location: 6, length: 2))
            text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
            text.insertText("日本語")
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.id), [id])
            XCTAssertEqual(vm.blocks[0].text, "lead 日本語tail")
            XCTAssertEqual(text.selectedRange, NSRange(location: 8, length: 0))
            let range = NSRange(location: 5, length: 3)
            let allowed = text.delegate?.textView?(text, shouldChangeTextIn: range, replacementText: "Japanese") ?? true
            if allowed {
                text.text = (text.text as NSString).replacingCharacters(in: range, with: "Japanese")
                text.delegate?.textViewDidChange?(text)
            }
            XCTAssertEqual(vm.blocks[0].text, "lead Japanesetail")
        }
    }

    func testPendingCompositionCancelAndRapidReturnsKeepSuffixOnce() async throws {
        try await withRow(text: "lead 😀tail") { vm, _, text, _ in
            let sourceID = vm.blocks[0].id
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("に😀", selectedRange: NSRange(location: 1, length: 2))
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に😀 😀tail"])
            XCTAssertEqual(vm.selection, NSRange(location: 1, length: 2))
            text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            text.unmarkText()
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", " 😀tail"])
            self.type("\n", in: text)
            let thirdID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
            text.insertText("仮名")
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID, thirdID])
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "", "仮名 😀tail"])
            self.type("\n", in: text)
            text.deleteBackward()
            self.type("X", in: text)
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID, targetID, thirdID])
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "", "仮名X 😀tail"])
            XCTAssertEqual(vm.selection, NSRange(location: 3, length: 0))
        }
    }

    func testDestinationAttachmentDoesNotCommitOrStealPendingComposition() async throws {
        try await withRow(text: "lead tail", canvas: true) { vm, host, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            await waitUntil { self.textViews(in: host.view).count == 2 }
            let retainedSource = try XCTUnwrap(self.textViews(in: host.view).first { $0 !== text })
            let target = text
            XCTAssertTrue(text.isFirstResponder)
            XCTAssertFalse(retainedSource.isFirstResponder)
            XCTAssertEqual(retainedSource.text, "lead")
            XCTAssertEqual(target.text, "に tail")
            XCTAssertNotNil(text.markedTextRange, "destination arrival must leave native composition active")
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に tail"])
            text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
            text.insertText("日本語")
            await waitUntil { target.isFirstResponder }
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.focusedBlockID, targetID)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "日本語 tail"])
            XCTAssertEqual(target.text, "日本語 tail")
            XCTAssertEqual(target.selectedRange, NSRange(location: 3, length: 0))
            XCTAssertEqual(vm.selection, NSRange(location: 3, length: 0))
            self.type("X", in: target)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "日本語X tail"])
        }
    }

    func testAttachedCompositionCancellationLeavesDestinationCaretReady() async throws {
        try await withRow(text: "lead tail", canvas: true) { vm, host, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            await waitUntil { self.textViews(in: host.view).count == 2 }
            XCTAssertTrue(text.isFirstResponder)
            text.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
            text.unmarkText()
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", " tail"])
            XCTAssertEqual(vm.focusedBlockID, targetID)
            XCTAssertEqual(vm.selection, NSRange(location: 0, length: 0))
            self.type("X", in: text)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "X tail"])
        }
    }

    func testPendingSameRowCompositionReplacesUTF16SelectionWithoutConsumingShortcut() async throws {
        try await withRow(text: "[]teh😀") { vm, _, text, _ in
            let id = vm.blocks[0].id
            text.selectedRange = NSRange(location: 2, length: 0)
            self.type(" ", in: text)
            XCTAssertEqual(vm.blocks[0].kind, .checklistItem(checked: false))
            // A same-row request can precede UIKit applying the new source coordinates.
            vm.cursorRequest = .init(blockID: id, offset: 3, length: 2)
            text.setMarkedText("に😀", selectedRange: NSRange(location: 1, length: 2))
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.text), ["tehに😀"])
            XCTAssertEqual(vm.selection, NSRange(location: 4, length: 2))
            text.insertText("日本語")
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(vm.blocks.map(\.id), [id])
            XCTAssertEqual(vm.blocks.map(\.text), ["teh日本語"])
            XCTAssertEqual(vm.selection, NSRange(location: 6, length: 0))
            XCTAssertEqual(text.selectedRange, NSRange(location: 6, length: 0))
        }
    }

    func testRapidPendingRowsKeepNativeCompositionBeyondOriginalViewport() async throws {
        try await withRow(text: "lead tail", canvas: true) { vm, host, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            for _ in 0..<24 {
                self.type("row", in: text)
                self.type("\n", in: text)
            }
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertEqual(vm.blocks.first?.text, "lead")
            XCTAssertEqual(vm.blocks.last?.text, "に tail")
            // Force body/layout reconciliation, including lazy realization/scroll work.
            _ = host.sizeThatFits(in: CGSize(width: 370, height: 600))
            host.view.layoutIfNeeded()
            await waitUntil {
                guard let coordinator = text.delegate as? BlockTextView.Coordinator else { return false }
                return coordinator.parent.blockID == targetID && coordinator.handoffBlockID == nil
            }
            XCTAssertTrue(self.textViews(in: host.view).contains { $0 === text })
            await waitUntil { host.view.bounds.intersects(text.convert(text.bounds, to: host.view)) }
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertTrue(text.isFirstResponder)
            text.insertText("日本語")
            XCTAssertEqual(vm.focusedBlockID, targetID)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead"] + Array(repeating: "row", count: 24) + ["日本語 tail"])
            XCTAssertEqual(Set(vm.blocks.map { vm.inputRowID(for: $0.id) }).count, vm.blocks.count)
        }
    }

    func testCompositionCommitAfterExplicitFocusCancellationDoesNotRestoreFocus() async throws {
        try await withRow(text: "lead tail") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            vm.focusedBlockID = nil
            vm.cursorRequest = nil
            vm.selection = nil
            text.unmarkText()
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に tail"])
            XCTAssertNil(vm.focusedBlockID)
            XCTAssertNil(vm.cursorRequest)
            XCTAssertNil(vm.selection)
            XCTAssertFalse(text.isFirstResponder)
        }
    }

    func testPendingMergeCompositionUsesRetainedBlockAndNativeInputIdentity() async throws {
        try await withRow(text: "lead tail", canvas: true) { vm, host, text, _ in
            let sourceID = vm.blocks[0].id
            let inputRowID = vm.inputRowID(for: sourceID)
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            await waitUntil { self.textViews(in: host.view).count == 2 && text.text == " tail" }
            text.deleteBackward()
            XCTAssertEqual(vm.blocks.map(\.id), [sourceID])
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            await waitUntil {
                (text.delegate as? BlockTextView.Coordinator)?.parent.blockID == sourceID
                    && self.textView(in: host.view) === text
            }
            XCTAssertTrue(self.textView(in: host.view) === text)
            XCTAssertEqual(vm.focusedBlockID, sourceID)
            XCTAssertEqual((text.delegate as? BlockTextView.Coordinator)?.parent.blockID, sourceID)
            XCTAssertTrue(text.isFirstResponder)
            XCTAssertNotNil(text.markedTextRange)
            XCTAssertTrue(self.textViews(in: host.view).filter { $0 !== text }.allSatisfy { !$0.isFirstResponder })
            XCTAssertEqual(vm.inputRowID(for: sourceID), inputRowID)
            text.unmarkText()
            XCTAssertEqual(vm.blocks.map(\.text), ["leadに tail"])
            XCTAssertEqual(vm.selection, NSRange(location: 5, length: 0))
        }
    }

    func testDividerShortcutAndHeadingSplitKeepNativeCompositionInParagraph() async throws {
        for source in ["---", "Heading tail"] {
            try await withRow(text: source, canvas: true) { vm, host, text, _ in
                if source != "---" { vm.blocks[0].kind = .heading(level: 1) }
                let offset = source == "---" ? 3 : 7
                text.selectedRange = NSRange(location: offset, length: 0)
                self.type("\n", in: text)
                let targetID = try XCTUnwrap(vm.focusedBlockID)
                text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
                await waitUntil {
                    guard let coordinator = text.delegate as? BlockTextView.Coordinator else { return false }
                    return coordinator.parent.blockID == targetID && coordinator.handoffBlockID == nil
                }
                XCTAssertTrue(self.textViews(in: host.view).contains { $0 === text })
                XCTAssertTrue(text.isFirstResponder)
                XCTAssertNotNil(text.markedTextRange)
                XCTAssertEqual(vm.blocks[1].kind, .paragraph)
                XCTAssertEqual(text.font?.pointSize, blockTextStyling(for: vm.blocks[1]).font.pointSize)
                text.insertText("日本語")
                XCTAssertEqual(vm.blocks.map(\.text), source == "---" ? ["", "日本語"] : ["Heading", "日本語 tail"])
                XCTAssertEqual(vm.selection, NSRange(location: 3, length: 0))
            }
        }
    }

    func testInputRowIdentityRemainsUniqueWhenRemovedStableIDReturns() async throws {
        try await withRow(text: "lead tail") { vm, _, text, _ in
            let original = vm.blocks[0]
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let target = vm.blocks[1]
            vm.blocks.removeFirst()
            // A remote update can reintroduce the original stable model identity.
            vm.blocks.insert(original, at: 0)
            vm.focusedBlockID = target.id
            vm.cursorRequest = .init(blockID: target.id, offset: 0)
            self.type("\n", in: text)
            XCTAssertEqual(Set(vm.blocks.map { vm.inputRowID(for: $0.id) }).count, vm.blocks.count)
            XCTAssertNotEqual(vm.inputRowID(for: original.id), vm.inputRowID(for: target.id))
        }
    }

    func testCommittedCompositionBeforeRowReconciliationKeepsDestinationCorrections() async throws {
        try await withRow(text: "lead tail") { vm, _, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            text.insertText("日本語")
            XCTAssertNil(text.markedTextRange)
            XCTAssertEqual(text.text, "日本語 tail")
            let correction = NSRange(location: 0, length: 3)
            let allowed =
                text.delegate?.textView?(text, shouldChangeTextIn: correction, replacementText: "Japanese") ?? true
            if allowed {
                text.text = (text.text as NSString).replacingCharacters(in: correction, with: "Japanese")
                text.delegate?.textViewDidChange?(text)
            }
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "Japanese tail"])
            XCTAssertEqual(text.text, "Japanese tail")
            text.selectedRange = NSRange(location: 8, length: 0)
            text.delegate?.textViewDidChangeSelection?(text)
            self.type("\n", in: text)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            text.unmarkText()
            XCTAssertEqual(vm.blocks.first?.text, "lead")
            XCTAssertEqual(vm.blocks.last?.text, "に tail")
        }
    }

    func testUnchangedCompositionCommitProcessesMarkdownShortcutAndSlashQuery() async throws {
        for input in ["- ", "# ", "/table"] {
            try await withRow(text: "lead") { vm, _, text, _ in
                text.selectedRange = NSRange(location: 4, length: 0)
                self.type("\n", in: text)
                text.setMarkedText(input, selectedRange: NSRange(location: (input as NSString).length, length: 0))
                XCTAssertNotNil(text.markedTextRange)
                XCTAssertEqual(vm.blocks[1].kind, .paragraph, "marked input is not shortcut syntax yet")
                text.unmarkText()
                XCTAssertNil(text.markedTextRange)
                if input == "/table" {
                    XCTAssertEqual(vm.slashQueryText, "table")
                    XCTAssertEqual(vm.blocks[1].text, input)
                } else {
                    XCTAssertEqual(vm.blocks[1].kind, input == "- " ? .bulletItem : .heading(level: 1))
                    XCTAssertEqual(vm.blocks[1].text, "")
                    XCTAssertEqual(vm.selection, NSRange(location: 0, length: 0))
                }
            }
        }
    }

    func testNativeResignationDuringCompositionPreservesCommitAndClearsFocus() async throws {
        try await withRow(text: "lead tail", canvas: true) { vm, _, text, _ in
            text.selectedRange = NSRange(location: 4, length: 0)
            self.type("\n", in: text)
            let targetID = try XCTUnwrap(vm.focusedBlockID)
            text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            await waitUntil {
                guard let coordinator = text.delegate as? BlockTextView.Coordinator else { return false }
                return coordinator.parent.blockID == targetID && coordinator.handoffBlockID == nil
            }
            text.resignFirstResponder()
            XCTAssertFalse(text.isFirstResponder)
            XCTAssertNil(vm.focusedBlockID)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に tail"])
            text.unmarkText()
            XCTAssertNil(vm.focusedBlockID)
            XCTAssertEqual(vm.blocks.map(\.text), ["lead", "に tail"])
        }
    }

    func testSourceKeepsKeyboardUntilPendingDestinationAttaches() async throws {
        try await withRow(text: "---") { vm, host, text, row in
            text.selectedRange = NSRange(location: 3, length: 0)
            self.type("\n", in: text)
            let destination = vm.blocks[1].id
            host.rootView = AnyView(row.environment(LocalizationStore()))
            _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
            XCTAssertTrue(self.textView(in: host.view) === text)
            XCTAssertTrue(text.isFirstResponder, "keep a keyboard recipient while the destination has no window")
            self.type("af", in: text)
            XCTAssertEqual(vm.blocks.map(\.text), ["", "af"])
            XCTAssertEqual(vm.focusedBlockID, destination)
            let targetRow = BlockEditorRow(
                viewModel: vm, block: vm.blocks[1], index: 1, serverOrigin: "https://docs.example.org", isOffline: true)
            host.rootView = AnyView(targetRow.id(destination).environment(LocalizationStore()))
            await waitUntil {
                guard let target = self.textView(in: host.view) else { return false }
                return target !== text && target.isFirstResponder && target.text == "af"
            }
            let target = try XCTUnwrap(self.textView(in: host.view))
            XCTAssertFalse(target === text)
            XCTAssertEqual(target.text, "af")
            XCTAssertEqual(target.selectedRange, NSRange(location: 2, length: 0))
            vm.focusedBlockID = nil
            host.rootView = AnyView(targetRow.id(destination).environment(LocalizationStore()))
            _ = host.sizeThatFits(in: CGSize(width: 370, height: 200))
            XCTAssertFalse(target.isFirstResponder, "clearing focus ends the handoff immediately")
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
        canvas: Bool = false,
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
        let root: AnyView
        if canvas {
            root = AnyView(
                BlockEditorView(
                    viewModel: vm, serverOrigin: "https://docs.example.org", isOffline: true,
                    scrollAnchor: EditorScrollAnchorStore(), header: { EmptyView() }
                ).environment(LocalizationStore(userDefaults: defaults)))
        } else {
            root = AnyView(row.environment(LocalizationStore(userDefaults: defaults)))
        }
        let host = UIHostingController(rootView: root)
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
