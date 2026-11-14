import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// Step 4 of PR14: focused `NativeSourceEditorViewController` / `NativeSourceEditorScreen`,
/// presentation from prose/columns/tables, slash menu insertion (`mathBlock`, `inlineMath`,
/// `diagram`), Return/Tab/Backspace/Done/Escape/`⌘Return` behavior, peer delete auto-dismiss,
/// read-only/gone states, and IME commit/cancel/interrupt/orphan recovery into `provisional.json`.
@MainActor
final class NativeSourceEditorTests: NativeEditingTestCase {
    @discardableResult
    private func hostController(_ controller: UIViewController, width: CGFloat = 390, height: CGFloat = 844) -> UIWindow
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func waitForSourceLoaded(_ editor: NativeSourceEditorViewController) async {
        for _ in 0..<300 where !editor.isLoaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeYDocState(build: (YTransaction, YType) throws -> Void) throws -> Data {
        let doc = YDoc(clientID: 7, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
        try doc.transact { tx in
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            try build(tx, group)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func inlineChipLocations(in attributed: NSAttributedString) -> [Int] {
        var result: [Int] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            if let chip = value as? NativeInlineChipAttachment, chip.content.kind == .math {
                result.append(range.location)
            }
        }
        return result
    }

    private func viewWithIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let found = viewWithIdentifier(identifier, in: child) { return found }
        }
        return nil
    }

    private func invokeKeyCommand(
        input: String, modifierFlags: UIKeyModifierFlags = [], on responder: UIResponder
    ) -> Bool {
        var current: UIResponder? = responder
        while let target = current {
            if let command = target.keyCommands?.first(where: {
                $0.input == input && $0.modifierFlags == modifierFlags
            }), let action = command.action, target.responds(to: action) {
                target.perform(action, with: command)
                return true
            }
            current = target.next
        }
        return false
    }

    // MARK: - Slash Menu & Return / Tab / Backspace / Slash Suppression

    func testSlashMathBlockAutoOpensAndKeepsNewlinesAndSuppressesTabBackspaceSlash() async throws {
        let harness = try await makeHarness([paragraph("p1", ""), paragraph("after", "Next")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: 0, length: 0))
        harness.view.insertText("/math")
        await harness.settle()
        XCTAssertEqual(harness.input.slashMenuQuery, "math")

        let mathItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mathBlock" })
        let applied = await harness.run { harness.input.applySlashItem(mathItem) }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.input.requestedSource, .block(blockID: "p1"))
        let request = try XCTUnwrap(harness.input.requestedSource)
        harness.input.requestedSource = nil

        var closed = false
        let editor = NativeSourceEditorViewController(document: harness.session, request: request)
        editor.onClose = { closed = true }
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        defer { window.isHidden = true }
        await waitForSourceLoaded(editor)

        XCTAssertEqual(editor.title, "Math source")
        XCTAssertEqual(editor.navigationItem.rightBarButtonItem?.accessibilityIdentifier, "nativeEditor.source.done")
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        XCTAssertEqual(sourceSession.source, .mathBlock)
        XCTAssertEqual(sourceSession.textView.autocorrectionType, .no)
        XCTAssertEqual(sourceSession.textView.autocapitalizationType, .none)

        // Slash token is suppressed inside the source editor.
        sourceSession.textView.insertText("/heading")
        await sourceSession.settle()
        XCTAssertNil(sourceSession.input?.slashMenuQuery)
        XCTAssertEqual(sourceSession.textView.textStorage.string, "/heading\n")

        // Backspace at offset 0 is a quiet no-op.
        sourceSession.textView.selectedRange = NSRange(location: 0, length: 0)
        sourceSession.input?.textViewDidChangeSelection(sourceSession.textView)
        sourceSession.textView.deleteBackward()
        await sourceSession.settle()
        XCTAssertEqual(sourceSession.textView.textStorage.string, "/heading\n")

        // Replace text with multiline LaTeX via Return inside mathBlock.
        _ = sourceSession.input?.replace(range: NSRange(location: 0, length: 8), with: "a = 1")
        await sourceSession.settle()
        sourceSession.textView.selectedRange = NSRange(location: 5, length: 0)
        sourceSession.input?.textViewDidChangeSelection(sourceSession.textView)
        sourceSession.textView.insertText("\n")
        sourceSession.textView.insertText("b = 2")
        await sourceSession.settle()
        XCTAssertFalse(closed, "Return in mathBlock inserts newline instead of closing")

        // Tab/Shift-Tab key commands do not indent/outdent blocks in source editor.
        let keyInputs = sourceSession.textView.keyCommands?.map(\.input) ?? []
        XCTAssertFalse(keyInputs.contains("\t"))

        editor.close()
        XCTAssertTrue(closed)
        await harness.settle()

        // Main document shows updated exact .source preview, and Yjs holds plain unmarked text.
        XCTAssertEqual(
            try block(harness.session, "p1").preview,
            .source(node: "mathBlock", lines: ["a = 1", "b = 2"], lineCount: 2))
        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<mathblock>a = 1\nb = 2</mathblock>") == true, xml ?? "")

        // Refocus after block puts caret at start of "after".
        harness.input.focus(after: request)
        XCTAssertEqual(
            harness.view.selectedRange, NSRange(location: try location(harness.session, "after", 0), length: 0))
    }

    func testSlashDiagramSeedsDefaultWithoutAutoOpenAndAllowsMultilineReturn() async throws {
        let harness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: 0, length: 0))
        harness.view.insertText("/diag")
        await harness.settle()

        let diagramItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "diagram" })
        let applied = await harness.run { harness.input.applySlashItem(diagramItem) }
        XCTAssertTrue(applied)
        XCTAssertNil(harness.input.requestedSource, "diagram seeds default source without auto-opening")
        XCTAssertEqual(
            try block(harness.session, "p1").preview,
            .source(node: "diagram", lines: ["graph TD", "    A[Start] --> B[Stop]"], lineCount: 2))

        // Tapping/opening the diagram opens "Diagram source" where Return inserts newline.
        let editor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "p1"))
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        defer { window.isHidden = true }
        await waitForSourceLoaded(editor)
        XCTAssertEqual(editor.title, "Diagram source")
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        sourceSession.textView.selectedRange = NSRange(
            location: SourceBlock.defaultDiagramSource.utf16.count, length: 0)
        sourceSession.input?.textViewDidChangeSelection(sourceSession.textView)
        sourceSession.textView.insertText("\n")
        sourceSession.textView.insertText("    B --> C")
        await sourceSession.settle()
        editor.close()
        await harness.settle()

        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<diagram>graph TD\n    A[Start] --> B[Stop]\n    B --> C</diagram>") == true)
    }

    func testSlashInlineMathAutoOpensExitsOnReturnAndRefocusesAfterChip() async throws {
        let harness = try await makeHarness([paragraph("p1", "")])
        addTeardownBlock { await harness.close() }
        setSelection(harness, NSRange(location: 0, length: 0))
        harness.view.insertText("/inline")
        await harness.settle()

        let inlineItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "inlineMath" })
        let applied = await harness.run { harness.input.applySlashItem(inlineItem) }
        XCTAssertTrue(applied)
        let request = try XCTUnwrap(harness.input.requestedSource)
        XCTAssertEqual(request, .inlineMath(blockID: "p1", utf16Offset: 0))
        harness.input.requestedSource = nil

        var closeCount = 0
        let editor = NativeSourceEditorViewController(document: harness.session, request: request)
        editor.onClose = { closeCount += 1 }
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        defer { window.isHidden = true }
        await waitForSourceLoaded(editor)
        XCTAssertEqual(editor.title, "Math source")

        let sourceSession = try XCTUnwrap(editor.sourceSession)
        sourceSession.textView.insertText("x^2 + y^2")
        await sourceSession.settle()

        // Selecting part of inline math source and pressing Return via delegate still exits instead of inserting "\n".
        let keepOpen = sourceSession.input?.textView(
            sourceSession.textView, shouldChangeTextIn: NSRange(location: 0, length: 3), replacementText: "\n")
        XCTAssertEqual(keepOpen, false)
        XCTAssertEqual(closeCount, 1)
        await harness.settle()

        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<math>x^2 + y^2</math> ") == true, xml ?? "")

        // focus(after:) places caret right after the inline math chip (at the trailing space, offset 1).
        harness.input.focus(after: request)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 1, length: 0))
    }

    // MARK: - Done / Escape / ⌘Return / Read-Only / Gone

    func testDoneEscapeAndCommandReturnDismissEditableReadOnlyAndGoneStates() async throws {
        // 1. Editable Escape and ⌘Return
        let harness = try await makeHarness([
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("x")], id: "m1")
        ])
        addTeardownBlock { await harness.close() }

        for trigger in ["done", "escape", "cmdReturn"] {
            var closed = 0
            let editor = NativeSourceEditorViewController(
                document: harness.session, request: .block(blockID: "m1"))
            editor.onClose = { closed += 1 }
            let nav = UINavigationController(rootViewController: editor)
            let window = hostController(nav)
            await waitForSourceLoaded(editor)
            let tv = try XCTUnwrap(editor.sourceSession?.textView)
            switch trigger {
            case "done":
                editor.close()
            case "escape":
                XCTAssertTrue(invokeKeyCommand(input: UIKeyCommand.inputEscape, on: tv))
            default:
                XCTAssertTrue(invokeKeyCommand(input: "\r", modifierFlags: .command, on: tv))
            }
            XCTAssertEqual(closed, 1, trigger)
            window.isHidden = true
        }

        // 2. Read-only inspect state (mathBlock + inline math in prose, columns, and table cell)
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("m-ro")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: "mathBlock"))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "\\sum_{i=1}^n i", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("p-ro")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: "math"))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let mathTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(mathTxt)])
            try mathTxt.insert(0, "a+b", nil)
        }
        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }

        var roClosed = 0
        let roEditor = NativeSourceEditorViewController(document: inspected, request: .block(blockID: "m-ro"))
        roEditor.onClose = { roClosed += 1 }
        let roNav = UINavigationController(rootViewController: roEditor)
        let roWindow = hostController(roNav)
        defer { roWindow.isHidden = true }
        await waitForSourceLoaded(roEditor)
        let roSession = try XCTUnwrap(roEditor.sourceSession)
        XCTAssertFalse(roSession.textView.isEditable)
        XCTAssertEqual(roSession.textView.textStorage.string, "\\sum_{i=1}^n i\n")
        XCTAssertTrue(invokeKeyCommand(input: UIKeyCommand.inputEscape, on: roEditor))
        XCTAssertEqual(roClosed, 1)

        let roInline = NativeSourceEditorViewController(
            document: inspected, request: .inlineMath(blockID: "p-ro", utf16Offset: 0))
        let roInlineNav = UINavigationController(rootViewController: roInline)
        let roInlineWin = hostController(roInlineNav)
        defer { roInlineWin.isHidden = true }
        await waitForSourceLoaded(roInline)
        XCTAssertEqual(roInline.sourceSession?.textView.textStorage.string, "a+b\n")
        XCTAssertFalse(roInline.sourceSession?.textView.isEditable ?? true)
        roInline.close()

        // 3. Gone state when target does not exist
        var goneClosed = 0
        let goneEditor = NativeSourceEditorViewController(
            document: harness.session, request: .block(blockID: "missing-id"))
        goneEditor.onClose = { goneClosed += 1 }
        let goneNav = UINavigationController(rootViewController: goneEditor)
        let goneWindow = hostController(goneNav)
        defer { goneWindow.isHidden = true }
        await waitForSourceLoaded(goneEditor)
        XCTAssertTrue(goneEditor.isGone)
        XCTAssertNil(goneEditor.sourceSession)
        XCTAssertNotNil(viewWithIdentifier("nativeEditor.source.gone", in: goneEditor.view))
        XCTAssertTrue(invokeKeyCommand(input: "\r", modifierFlags: .command, on: goneEditor))
        XCTAssertEqual(goneClosed, 1)
    }

    // MARK: - Columns & Tables Presentation

    func testColumnEditorPresentsSourceEditorOverColumnSessionAndTableEditorPresentsOverTableCell() async throws {
        // 1. Column editor presentation via model.openSource & requestedSource
        let colState = try makeYDocState { tx, group in
            let list = YType(typeRef: .xmlElement(nodeName: "columnList"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(list)])
            try YWrite.mapSet(tx, on: list, key: "id", .any([.string("cl")]))
            for (colID, blockID, text) in [("c1", "cp1", "Col "), ("c2", "cp2", "Other")] {
                let col = YType(typeRef: .xmlElement(nodeName: "column"))
                let prev = YBlockProjection.children(of: list, includeFormats: false).last
                try YWrite.insertAfter(tx, into: list, after: prev, [.type(col)])
                try YWrite.mapSet(tx, on: col, key: "id", .any([.string(colID)]))
                try YWrite.mapSet(tx, on: col, key: "width", .any([.int(1)]))
                let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                try YWrite.insertAfter(tx, into: col, after: nil, [.type(container)])
                try YWrite.mapSet(tx, on: container, key: "id", .any([.string(blockID)]))
                let p = YType(typeRef: .xmlElement(nodeName: "paragraph"))
                try YWrite.insertAfter(tx, into: container, after: nil, [.type(p)])
                let txt = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: p, after: nil, [.type(txt)])
                try txt.insert(0, text, nil)
                if colID == "c1" {
                    let math = YType(typeRef: .xmlElement(nodeName: "math"))
                    try YWrite.insertAfter(
                        tx, into: p, after: YBlockProjection.children(of: p, includeFormats: false).last, [.type(math)])
                    let mathTxt = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: math, after: nil, [.type(mathTxt)])
                    try mathTxt.insert(0, "\\alpha", nil)
                }
            }
        }
        let colHarness = try await makeHarness(state: colState)
        addTeardownBlock { await colHarness.close() }
        let colModel = ColumnEditorModel(document: colHarness.session, groupID: "cl")
        addTeardownBlock { colModel.close() }
        let colHost = UIHostingController(
            rootView: ColumnEditorScreen(model: colModel, serverOrigin: "https://example.test")
                .environment(LocalizationStore()))
        let colWindow = hostController(colHost)
        defer { colWindow.isHidden = true }
        for _ in 0..<300 where !colModel.isLoaded { try await Task.sleep(for: .milliseconds(10)) }

        let leftSession = try XCTUnwrap(colModel.columns.first)
        let chipLoc = try XCTUnwrap(inlineChipLocations(in: leftSession.textView.textStorage).first)
        leftSession.textView.blockControls.onOpenSource?(.inlineMath(blockID: "cp1", utf16Offset: chipLoc))
        XCTAssertEqual(colModel.openSource, .inlineMath(blockID: "cp1", utf16Offset: chipLoc))
        colModel.openSource = nil

        // 2. Table editor self-presentation when onOpenSource == nil
        let tblState = try makeYDocState { tx, group in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
            try YWrite.insertAfter(tx, into: table, after: nil, [.type(row)])
            let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
            try YWrite.insertAfter(tx, into: row, after: nil, [.type(cell)])
            try YWrite.mapSet(tx, on: cell, key: "colspan", .any([.int(1)]))
            try YWrite.mapSet(tx, on: cell, key: "rowspan", .any([.int(1)]))
            let para = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
            try YWrite.insertAfter(tx, into: cell, after: nil, [.type(para)])
            let txt = YType(typeRef: .xmlText)
            let tItem = try YWrite.insertAfter(tx, into: para, after: nil, [.type(txt)])
            try txt.insert(0, "Eq ", nil)
            let math = YType(typeRef: .xmlElement(nodeName: "math"))
            try YWrite.insertAfter(tx, into: para, after: tItem, [.type(math)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: math, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "z", nil)
        }
        let tblHarness = try await makeHarness(state: tblState)
        addTeardownBlock { await tblHarness.close() }
        let tableEditor = TableEditorViewController(document: tblHarness.session, tableID: "tbl")
        let tblWindow = hostController(UINavigationController(rootViewController: tableEditor))
        defer { tblWindow.isHidden = true }
        await tableEditor.load()
        for _ in 0..<300 where !tableEditor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        let cellSession = try XCTUnwrap(tableEditor.cellSession)
        let cellChipOffset = try XCTUnwrap(inlineChipLocations(in: cellSession.textView.textStorage).first)
        let cellParaID = try XCTUnwrap(cellSession.surface.blocks.first?.id)
        cellSession.textView.blockControls.onOpenSource?(.inlineMath(blockID: cellParaID, utf16Offset: cellChipOffset))

        for _ in 0..<100 where tableEditor.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let presentedNav = try XCTUnwrap(tableEditor.presentedViewController as? UINavigationController)
        let sourceVC = try XCTUnwrap(presentedNav.topViewController as? NativeSourceEditorViewController)
        await waitForSourceLoaded(sourceVC)
        sourceVC.sourceSession?.textView.insertText("+1")
        await sourceVC.sourceSession?.settle()
        sourceVC.close()
        for _ in 0..<100 where tableEditor.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await tblHarness.settle()

        let xml = await tblHarness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<math>z+1</math>") == true, xml ?? "")
        XCTAssertEqual(cellSession.textView.selectedRange, NSRange(location: cellChipOffset + 1, length: 0))
        tableEditor.close()
    }

    // MARK: - Peer Delete Auto-Dismiss & IME Recovery

    func testPeerDeletingSourceBlockAutoDismissesSourceEditor() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Lead"),
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("x^2")], id: "mx"),
        ])
        addTeardownBlock { await harness.close() }

        var closed = 0
        let editor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        editor.onClose = { closed += 1 }
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        defer { window.isHidden = true }
        await waitForSourceLoaded(editor)
        XCTAssertEqual(editor.sourceSession?.surface.blocks.count, 1)

        // Peer deletes the mathBlock container.
        let seedBytes = try XCTUnwrap(harness.store.restore(for: harness.scope)?.checkpoint)
        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(seedBytes))
        let peerWriter = BlockNoteWriter(doc: peer)
        let deleteUpdate = try peerWriter.deleteBlock(try peerWriter.findSource("mx").item, id: "mx")
        try await harness.session.integrateServerState(deleteUpdate)

        for _ in 0..<100 where closed == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(closed, 1)
    }

    func testIMECommitCancelAndInterruptFlushProvisionalRecoveryAndSurviveColdRelaunch() async throws {
        let harness = try await makeHarness([
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("x")], id: "mx")
        ])

        let editor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        await waitForSourceLoaded(editor)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        let tv = sourceSession.textView

        // 1. Cancel writes nothing and clears provisional.json.
        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["か"])
        tv.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        await sourceSession.settle()
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)

        // 2. Commit writes once and clears provisional.json.
        tv.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        tv.unmarkText()
        await sourceSession.settle()
        await harness.settle()
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)
        let xmlAfterCommit = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xmlAfterCommit?.contains("<mathblock>xに</mathblock>") == true, xmlAfterCommit ?? "")

        // 3. Interrupt on close (resignFirstResponder before close) persists recovery in provisional.json.
        tv.selectedRange = NSRange(location: 2, length: 0)
        tv.setMarkedText("ほ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["ほ"])
        editor.close()
        window.isHidden = true
        await harness.settle()

        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["ほ"])
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["ほ"])
        await harness.session.close().value

        // 4. Cold relaunch restores committed "xに" and uncommitted recovery "ほ".
        let restored = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock {
            await restored.close().value
            try? FileManager.default.removeItem(at: harness.directory)
            UIPasteboard.remove(withName: harness.pasteboard.name)
        }
        restored.enableTyping(persist: nil)
        XCTAssertEqual(restored.input?.composition.pendingRecoveries.map(\.text), ["ほ"])
        XCTAssertEqual(
            restored.surface.blocks.first(where: { $0.id == "mx" })?.preview,
            .source(node: "mathBlock", lines: ["xに"], lineCount: 1))
    }

    func testPeerDeletingTargetDuringActiveCompositionOrphansIntoProvisionalAndAutoDismisses() async throws {
        let harness = try await makeHarness([
            paragraph("lead", "Lead"),
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("x")], id: "mx"),
        ])
        addTeardownBlock { await harness.close() }

        var closed = 0
        let editor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        editor.onClose = { closed += 1 }
        let nav = UINavigationController(rootViewController: editor)
        let window = hostController(nav)
        defer { window.isHidden = true }
        await waitForSourceLoaded(editor)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        let tv = sourceSession.textView

        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(sourceSession.input?.compositionOwnsView, true)

        // Peer deletes mx while IME composition owns the source view.
        let seedBytes = try XCTUnwrap(harness.store.restore(for: harness.scope)?.checkpoint)
        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(YUpdateDecoder.decode(seedBytes))
        let peerWriter = BlockNoteWriter(doc: peer)
        let deleteUpdate = try peerWriter.deleteBlock(try peerWriter.findSource("mx").item, id: "mx")
        try await harness.session.integrateServerState(deleteUpdate)

        XCTAssertEqual(closed, 0, "does not auto-dismiss while compositionOwnsView is true")

        // User confirms composition: target is gone, so recovery is orphaned in provisional.json and editor closes.
        tv.unmarkText()
        for _ in 0..<100 where closed == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await harness.settle()
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["あ"])
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["あ"])
    }

    // MARK: - Step 5 Matrix: Unicode, Blank/Multiline/Paste, Marks/IDs, Peer Replace, IME Recovery & Shared Undo

    func testUnicodeSurrogatesBlankMultilineAndPasteGatingInsideSourceEditor() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("mx")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "𝑎+😀", nil)

            let dContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(dContainer)])
            try YWrite.mapSet(tx, on: dContainer, key: "id", .any([.string("dx")]))
            let dEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.diagram))
            try YWrite.insertAfter(tx, into: dContainer, after: nil, [.type(dEl)])
            let dTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: dEl, after: nil, [.type(dTxt)])
            try dTxt.insert(0, "graph TD", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let math = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(math)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: math, after: nil, [.type(iTxt)])
            try iTxt.insert(0, "𝑏", nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. mathBlock: surrogate selection replacement, blank/whitespace, multiline indentation, unvalidated syntax,
        // and structured/URL paste falling back to plain text instead of doomed structural/interlink commands.
        let mathEditor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        let mathWindow = hostController(UINavigationController(rootViewController: mathEditor))
        defer { mathWindow.isHidden = true }
        await waitForSourceLoaded(mathEditor)
        let mathSession = try XCTUnwrap(mathEditor.sourceSession)
        let mathInput = try XCTUnwrap(mathSession.input)
        let mathTV = mathSession.textView

        // Marks, links and indent/outdent must be blocked while editing a scoped source buffer.
        mathTV.selectedRange = NSRange(location: 0, length: 2)
        XCTAssertFalse(mathInput.toggleMark("bold"))
        XCTAssertFalse(mathInput.setColor("textColor", name: "red"))
        XCTAssertNil(mathInput.linkTarget())
        XCTAssertFalse(mathInput.indent())
        XCTAssertFalse(mathInput.outdent())

        // Replace '😀' (UTF-16 [3..<5]) with ZWJ emoji + blank line + unvalidated LaTeX.
        mathTV.selectedRange = NSRange(location: 3, length: 2)
        mathTV.insertText("👨‍👩‍👧‍👦\n\n  \\unknown{")
        await mathSession.settle()
        XCTAssertEqual(mathTV.text, "𝑎+👨‍👩‍👧‍👦\u{2028}\u{2028}  \\unknown{\n")
        let mathXML = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(mathXML?.contains("<mathblock>𝑎+👨‍👩‍👧‍👦\n\n  \\unknown{</mathblock>") == true, mathXML ?? "")

        // Structured subtree payload + plain-text same-origin URL on pasteboard must paste plain text,
        // NOT try pasteBlocks / pasteInline / interlink on the source surface.
        let subtreeData = try BlockNoteSubtreePayload.encode([
            .element(
                "blockContainer", [("id", .string("tmp"))],
                [.element("paragraph", [], [.text([.run(InlineRun("bad"))])])])
        ])
        mathInput.pasteboard.setItems([
            [
                BlockNoteSubtreePayload.pasteboardType: subtreeData,
                "public.utf8-plain-text": "https://example.test/docs/11111111-1111-4111-8111-111111111111",
            ]
        ])
        mathTV.selectedRange = NSRange(location: max(0, (mathTV.text as NSString).length - 1), length: 0)
        let pastedMath = await mathSession.run { mathInput.pasteFromPasteboard() }
        XCTAssertTrue(pastedMath)
        XCTAssertTrue(
            mathTV.text.hasSuffix("https://example.test/docs/11111111-1111-4111-8111-111111111111\n"),
            mathTV.text ?? "")

        mathEditor.close()
        await harness.settle()

        // 2. inlineMath: astral math, whitespace-only allowed, newlines/Tab/marks/URL-interlink-paste rejected/plain.
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let inlineWindow = hostController(UINavigationController(rootViewController: inlineEditor))
        defer { inlineWindow.isHidden = true }
        await waitForSourceLoaded(inlineEditor)
        let inlineSession = try XCTUnwrap(inlineEditor.sourceSession)
        let inlineInput = try XCTUnwrap(inlineSession.input)
        let inlineTV = inlineSession.textView

        XCTAssertFalse(inlineInput.insertTab(), "inlineMath must not indent or insert tabs")
        XCTAssertFalse(inlineInput.toggleMark("italic"))

        // Pasting multiline text into inlineMath refuses cleanly instead of attempting a doomed whole-block command.
        inlineInput.pasteboard.string = "line1\nline2"
        let pastedNewline = await inlineSession.run { inlineInput.pasteFromPasteboard() }
        XCTAssertFalse(pastedNewline)
        XCTAssertEqual(inlineTV.text, "𝑏\n")

        // Pasting inline payload with a same-origin URL plain-text fallback pastes the plain text inside inlineMath.
        let inlinePayload = try BlockNoteInlinePayload.encode([[.text([.run(InlineRun("𝑐"))])]])
        inlineInput.pasteboard.setItems([
            [
                BlockNoteInlinePayload.pasteboardType: inlinePayload,
                "public.utf8-plain-text": " + https://example.test/docs/11111111-1111-4111-8111-111111111111",
            ]
        ])
        inlineTV.selectedRange = NSRange(location: 2, length: 0)
        let pastedInlinePlain = await inlineSession.run { inlineInput.pasteFromPasteboard() }
        XCTAssertTrue(pastedInlinePlain)
        XCTAssertEqual(inlineTV.text, "𝑏 + https://example.test/docs/11111111-1111-4111-8111-111111111111\n")

        // Blank whitespace-only inline math persists faithfully without crashing or validating.
        inlineTV.selectedRange = NSRange(location: 0, length: max(0, (inlineTV.text as NSString).length - 1))
        inlineTV.insertText("   ")
        await inlineSession.settle()
        inlineEditor.close()
        await harness.settle()

        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<math>   </math>") == true, xml ?? "")
    }

    func testNestedAtomOffsetsAdjacentMarksColumnAndTableEditing() async throws {
        // Root paragraph: "bold" (bold, 0..4) + <math>x</math> (4..5) + "ital" (italic, 5..9) + @Alice (9..10) + <math>y</math> (10..11)
        // Plus column with <math>c</math> and multi-paragraph table cell with "**b**" + <math>t</math> + interlink.
        let interlink = NativeInlineObject.interlink(
            docID: "22222222-2222-4222-8222-222222222222", blockID: nil, title: "Spec", disabled: false, trigger: "@")
        // Encode rich-root directly with columnList and table using YDoc XML so all live in one document.
        let fullState = try makeYDocState { tx, group in
            // 1. rich-root paragraph
            var after: YItem?
            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("rich-root")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let tBold = YType(typeRef: .xmlText)
            var pChild = try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(tBold)])
            try tBold.insert(0, "bold", ["bold": "true"])
            let m1 = YType(typeRef: .xmlElement(nodeName: "math"))
            pChild = try YWrite.insertAfter(tx, into: pEl, after: pChild, [.type(m1)])
            let m1Txt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: m1, after: nil, [.type(m1Txt)])
            try m1Txt.insert(0, "x", nil)
            let tItal = YType(typeRef: .xmlText)
            pChild = try YWrite.insertAfter(tx, into: pEl, after: pChild, [.type(tItal)])
            try tItal.insert(0, "ital", ["italic": "true"])
            let m2 = YType(typeRef: .xmlElement(nodeName: "math"))
            _ = try YWrite.insertAfter(tx, into: pEl, after: pChild, [.type(m2)])
            let m2Txt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: m2, after: nil, [.type(m2Txt)])
            try m2Txt.insert(0, "y", nil)

            // 2. table with multi-paragraph cell: p1 plain, p2 bold + <math>t</math> + interlink
            let tblContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(tblContainer)])
            try YWrite.mapSet(tx, on: tblContainer, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: tblContainer, after: nil, [.type(table)])
            let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
            try YWrite.insertAfter(tx, into: table, after: nil, [.type(row)])
            let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
            try YWrite.insertAfter(tx, into: row, after: nil, [.type(cell)])
            try YWrite.mapSet(tx, on: cell, key: "colspan", .any([.int(1)]))
            try YWrite.mapSet(tx, on: cell, key: "rowspan", .any([.int(1)]))
            let tp1 = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
            let tp1Item = try YWrite.insertAfter(tx, into: cell, after: nil, [.type(tp1)])
            let tp1Txt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: tp1, after: nil, [.type(tp1Txt)])
            try tp1Txt.insert(0, "Header", nil)
            let tp2 = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
            _ = try YWrite.insertAfter(tx, into: cell, after: tp1Item, [.type(tp2)])
            let tp2Bold = YType(typeRef: .xmlText)
            var tp2Child = try YWrite.insertAfter(tx, into: tp2, after: nil, [.type(tp2Bold)])
            try tp2Bold.insert(0, "pre", ["bold": "true"])
            let tm = YType(typeRef: .xmlElement(nodeName: "math"))
            tp2Child = try YWrite.insertAfter(tx, into: tp2, after: tp2Child, [.type(tm)])
            let tmTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: tm, after: nil, [.type(tmTxt)])
            try tmTxt.insert(0, "t", nil)
            let il = YType(typeRef: .xmlElement(nodeName: interlink.nodeName))
            _ = try YWrite.insertAfter(tx, into: tp2, after: tp2Child, [.type(il)])
            try YWrite.mapSet(tx, on: il, key: "docId", .any([.string("22222222-2222-4222-8222-222222222222")]))
            try YWrite.mapSet(tx, on: il, key: "title", .any([.string("Spec")]))
            try YWrite.mapSet(tx, on: il, key: "disabled", .any([.bool(false)]))
            try YWrite.mapSet(tx, on: il, key: "trigger", .any([.string("@")]))
        }

        let harness = try await makeHarness(state: fullState)
        addTeardownBlock { await harness.close() }

        // Edit first chip in rich-root (offset 4, after "bold") and verify second chip at offset 9 & surrounding marks.
        let req1 = NativeSourceRequest.inlineMath(blockID: "rich-root", utf16Offset: 4)
        let editor1 = NativeSourceEditorViewController(document: harness.session, request: req1)
        let win1 = hostController(UINavigationController(rootViewController: editor1))
        defer { win1.isHidden = true }
        await waitForSourceLoaded(editor1)
        editor1.sourceSession?.textView.insertText("^2")
        await editor1.sourceSession?.settle()
        editor1.close()
        await harness.settle()
        harness.input.focus(after: req1)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 5, length: 0))

        // Second chip is still at offset 9 (after "ital" [5..9]).
        let req2 = NativeSourceRequest.inlineMath(blockID: "rich-root", utf16Offset: 9)
        let editor2 = NativeSourceEditorViewController(document: harness.session, request: req2)
        let win2 = hostController(UINavigationController(rootViewController: editor2))
        defer { win2.isHidden = true }
        await waitForSourceLoaded(editor2)
        editor2.sourceSession?.textView.insertText("_0")
        await editor2.sourceSession?.settle()
        editor2.close()
        await harness.settle()
        harness.input.focus(after: req2)
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: 10, length: 0))

        let richBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "rich-root" })
        XCTAssertEqual(
            richBlock.runs.map { $0.marks.map(\.key) },
            [
                ["bold"],
                [],
                ["italic"],
                [],
            ])
        XCTAssertEqual(richBlock.runs[1].inlineObject, .math(source: "x^2"))
        XCTAssertEqual(richBlock.runs[3].inlineObject, .math(source: "y_0"))

        // Edit math chip inside multi-paragraph table cell (second tableParagraph) and verify focus + adjacent marks/interlink.
        let tableEditor = TableEditorViewController(document: harness.session, tableID: "tbl")
        let tblWindow = hostController(UINavigationController(rootViewController: tableEditor))
        defer { tblWindow.isHidden = true }
        await tableEditor.load()
        for _ in 0..<300 where !tableEditor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        let cellSession = try XCTUnwrap(tableEditor.cellSession)
        let tp2Block = try XCTUnwrap(cellSession.surface.blocks.dropFirst().first)
        let cellReq = NativeSourceRequest.inlineMath(blockID: tp2Block.id, utf16Offset: 3)
        let cellEditor = NativeSourceEditorViewController(document: harness.session, request: cellReq)
        let cellWin = hostController(UINavigationController(rootViewController: cellEditor))
        defer { cellWin.isHidden = true }
        await waitForSourceLoaded(cellEditor)
        cellEditor.sourceSession?.textView.insertText("*9")
        await cellEditor.sourceSession?.settle()
        cellEditor.close()
        await harness.settle()

        cellSession.input?.focus(after: cellReq)
        let tp2Entry = try XCTUnwrap(cellSession.surface.rangeIndex.entry(for: tp2Block.id))
        XCTAssertEqual(
            cellSession.textView.selectedRange, NSRange(location: tp2Entry.textRange.location + 4, length: 0))
        let updatedTP2 = try XCTUnwrap(cellSession.surface.blocks.first { $0.id == tp2Block.id })
        XCTAssertEqual(updatedTP2.runs[0].marks.map(\.key), ["bold"])
        XCTAssertEqual(updatedTP2.runs[1].inlineObject, .math(source: "t*9"))
        XCTAssertEqual(updatedTP2.runs[2].inlineObject, interlink)
    }

    func testPeerReplacementAndUnfamiliarEditWhileSourceEditorIsOpen() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("mx")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "a+b", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let math = YType(typeRef: .xmlElement(nodeName: "math"))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(math)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: math, after: nil, [.type(iTxt)])
            try iTxt.insert(0, "x", nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. Peer replaces mx's inner element (new element ID while blockContainer ID "mx" stays the same):
        // NativeSourceEditorViewController auto-dismisses cleanly.
        var mathClosed = 0
        let mathEditor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        mathEditor.onClose = { mathClosed += 1 }
        let mathWindow = hostController(UINavigationController(rootViewController: mathEditor))
        defer { mathWindow.isHidden = true }
        await waitForSourceLoaded(mathEditor)

        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(
            YUpdateDecoder.decode(try XCTUnwrap(harness.store.restore(for: harness.scope)?.checkpoint)))
        let peerWriter = BlockNoteWriter(doc: peer)
        let found = try peerWriter.findSource("mx")
        let old = peerWriter.children(found.container).first
        let replaceUpdate = try peerWriter.transaction { tx in
            old?.delete(tx)
            let replacement = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: found.container, after: nil, [.type(replacement)])
            let t = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: replacement, after: nil, [.type(t)])
            try t.insert(0, "c+d", nil)
        }
        try await harness.session.integrateServerState(replaceUpdate)
        for _ in 0..<100 where mathClosed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(mathClosed, 1)

        // 2. Peer applies unfamiliar child (e.g. a mark) inside open inline <math> while IME is active:
        // stays open during composition, then orphans provisional recovery into provisional.json & dismisses on end.
        var inlineClosed = 0
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        inlineEditor.onClose = { inlineClosed += 1 }
        let inlineWindow = hostController(UINavigationController(rootViewController: inlineEditor))
        defer { inlineWindow.isHidden = true }
        await waitForSourceLoaded(inlineEditor)
        let inlineTV = try XCTUnwrap(inlineEditor.sourceSession?.textView)
        inlineTV.selectedRange = NSRange(location: 1, length: 0)
        inlineTV.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))

        let pFound = try peerWriter.find("px")
        let mathItem = try XCTUnwrap(peerWriter.children(pFound.element).first)
        guard case .type(let mathEl) = mathItem.content else {
            return XCTFail("missing math element")
        }
        let unfamiliarUpdate = try peerWriter.transaction { tx in
            let nested = YType(typeRef: .xmlElement(nodeName: "userMentionInline"))
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(nested)])
        }
        try await harness.session.integrateServerState(unfamiliarUpdate)
        XCTAssertEqual(inlineClosed, 0, "does not auto-dismiss while IME composition owns the source view")

        inlineTV.unmarkText()
        for _ in 0..<100 where inlineClosed == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await harness.settle()
        XCTAssertEqual(inlineClosed, 1)
        XCTAssertEqual(harness.input.composition.pendingRecoveries.map(\.text), ["あ"])
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["あ"])
    }

    func testInlineMathAndDiagramIMECommitCancelInterruptAndColdRecovery() async throws {
        // Tests both inline <math> inside a column and diagram at root through cancel, commit, interrupt,
        // cold restore, and insertRecovery/discardRecovery on the restored main editor.
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let dContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(dContainer)])
            try YWrite.mapSet(tx, on: dContainer, key: "id", .any([.string("dx")]))
            let dEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.diagram))
            try YWrite.insertAfter(tx, into: dContainer, after: nil, [.type(dEl)])
            let dTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: dEl, after: nil, [.type(dTxt)])
            try dTxt.insert(0, "flowchart TD", nil)

            let list = YType(typeRef: .xmlElement(nodeName: "columnList"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(list)])
            try YWrite.mapSet(tx, on: list, key: "id", .any([.string("cl")]))
            for (cid, bid) in [("c1", "cp1"), ("c2", "cp2")] {
                let col = YType(typeRef: .xmlElement(nodeName: "column"))
                let prev = YBlockProjection.children(of: list, includeFormats: false).last
                try YWrite.insertAfter(tx, into: list, after: prev, [.type(col)])
                try YWrite.mapSet(tx, on: col, key: "id", .any([.string(cid)]))
                try YWrite.mapSet(tx, on: col, key: "width", .any([.int(1)]))
                let bc = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                try YWrite.insertAfter(tx, into: col, after: nil, [.type(bc)])
                try YWrite.mapSet(tx, on: bc, key: "id", .any([.string(bid)]))
                let p = YType(typeRef: .xmlElement(nodeName: "paragraph"))
                try YWrite.insertAfter(tx, into: bc, after: nil, [.type(p)])
                if cid == "c1" {
                    let math = YType(typeRef: .xmlElement(nodeName: "math"))
                    try YWrite.insertAfter(tx, into: p, after: nil, [.type(math)])
                    let mt = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: math, after: nil, [.type(mt)])
                    try mt.insert(0, "x", nil)
                } else {
                    let pt = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: p, after: nil, [.type(pt)])
                    try pt.insert(0, "target", nil)
                }
            }
        }
        let harness = try await makeHarness(state: state)

        // 1. Diagram: cancel and commit clear provisional.json.
        let diagEditor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "dx"))
        let diagWindow = hostController(UINavigationController(rootViewController: diagEditor))
        await waitForSourceLoaded(diagEditor)
        let diagTV = try XCTUnwrap(diagEditor.sourceSession?.textView)
        diagTV.selectedRange = NSRange(location: 12, length: 0)
        diagTV.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        diagTV.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        diagTV.unmarkText()
        await diagEditor.sourceSession?.settle()
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)

        diagTV.setMarkedText("\nA-->B", selectedRange: NSRange(location: 6, length: 0))
        diagTV.unmarkText()
        await diagEditor.sourceSession?.settle()
        await harness.settle()
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)
        diagEditor.close()
        diagWindow.isHidden = true

        // 2. Column inline <math>: interrupt leaves pending recovery forwarded to main session and stored in provisional.json.
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "cp1", utf16Offset: 0))
        let inlineWindow = hostController(UINavigationController(rootViewController: inlineEditor))
        await waitForSourceLoaded(inlineEditor)
        let inlineTV = try XCTUnwrap(inlineEditor.sourceSession?.textView)
        inlineTV.selectedRange = NSRange(location: 1, length: 0)
        inlineTV.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["か"])
        inlineEditor.close()
        inlineWindow.isHidden = true
        await harness.settle()
        await harness.session.close().value

        // 3. Cold restore surfaces pending recovery on main session and lets the user discard or insert it.
        let restored = try unwrapped(try await NativeEditorSession.restore(store: harness.store, scope: harness.scope))
        addTeardownBlock {
            await restored.close().value
            try? FileManager.default.removeItem(at: harness.directory)
            UIPasteboard.remove(withName: harness.pasteboard.name)
        }
        restored.enableTyping { command, update in
            try harness.store.append(
                update, for: harness.scope, commandID: command.id, baseRevision: command.baseRevision, origin: .local)
        }
        XCTAssertEqual(restored.input?.composition.pendingRecoveries.map(\.text), ["か"])
        XCTAssertEqual(
            restored.surface.blocks.first(where: { $0.id == "dx" })?.preview,
            .source(node: "diagram", lines: ["flowchart TD", "A-->B"], lineCount: 2))

        let recovery = try XCTUnwrap(restored.input?.composition.pendingRecoveries.first)
        restored.input?.discardRecovery(recovery)
        await restored.settle()
        XCTAssertTrue(restored.input?.composition.pendingRecoveries.isEmpty == true)
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)
    }

    func testSharedUndoRedoInsideSourceEditorAndFromParentDocument() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("mx")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "a", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let math = YType(typeRef: .xmlElement(nodeName: "math"))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(math)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: math, after: nil, [.type(iTxt)])
            try iTxt.insert(0, "z", nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. Inside NativeSourceEditor for mathBlock: edit -> undo -> redo shares the replica history.
        let mathEditor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        let mathWindow = hostController(UINavigationController(rootViewController: mathEditor))
        defer { mathWindow.isHidden = true }
        await waitForSourceLoaded(mathEditor)
        let mathSession = try XCTUnwrap(mathEditor.sourceSession)
        let mathInput = try XCTUnwrap(mathSession.input)
        mathSession.textView.selectedRange = NSRange(location: 1, length: 0)
        mathSession.textView.insertText("+b")
        await mathSession.settle()
        XCTAssertEqual(mathSession.textView.text, "a+b\n")

        let didUndoInSource = await mathSession.run { mathInput.undo() }
        XCTAssertTrue(didUndoInSource)
        XCTAssertEqual(mathSession.textView.text, "a\n")
        let didRedoInSource = await mathSession.run { mathInput.redo() }
        XCTAssertTrue(didRedoInSource)
        XCTAssertEqual(mathSession.textView.text, "a+b\n")
        mathEditor.close()
        await harness.settle()

        // 2. Undo and redo from the parent document reverses/re-applies the closed source editor's edit,
        // while preserving concurrent peer changes on another part of the document.
        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(
            YUpdateDecoder.decode(try XCTUnwrap(harness.store.restore(for: harness.scope)?.checkpoint)))
        let peerWriter = BlockNoteWriter(doc: peer)
        let pFound = try peerWriter.find("px")
        let afterMath = peerWriter.children(pFound.element).last
        let peerUpdate = try peerWriter.transaction { tx in
            let note = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: pFound.element, after: afterMath, [.type(note)])
            try note.insert(0, " peer", nil)
        }
        try await harness.session.integrateServerState(peerUpdate)

        // Edit inline <math> inside source editor, close it, then undo from parent harness.
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let inlineWindow = hostController(UINavigationController(rootViewController: inlineEditor))
        defer { inlineWindow.isHidden = true }
        await waitForSourceLoaded(inlineEditor)
        inlineEditor.sourceSession?.textView.selectedRange = NSRange(location: 1, length: 0)
        inlineEditor.sourceSession?.textView.insertText("+1")
        await inlineEditor.sourceSession?.settle()
        inlineEditor.close()
        await harness.settle()

        let didUndoParent = await harness.run { harness.input.undo() }
        XCTAssertTrue(didUndoParent)
        let xmlAfterUndo = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xmlAfterUndo?.contains("<math>z</math>") == true, xmlAfterUndo ?? "")
        XCTAssertTrue(xmlAfterUndo?.contains("<mathblock>a+b</mathblock>") == true, xmlAfterUndo ?? "")
        XCTAssertTrue(xmlAfterUndo?.contains(" peer") == true, "collaborative peer edit stays intact on local undo")

        let didRedoParent = await harness.run { harness.input.redo() }
        XCTAssertTrue(didRedoParent)
        let xmlAfterRedo = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xmlAfterRedo?.contains("<math>z+1</math>") == true, xmlAfterRedo ?? "")
    }

    // MARK: - Review Round 1 Regression Tests (S1, S2/C3, S4, C1, C2)

    func testS1SourceEditorSelectionAtZeroOnLargeBlockAndRefusalOnOversizedOrFFFC() async throws {
        let largeEditable = String(repeating: "a", count: NativeInlineObject.maxMathUTF16 + 1)
        let oversizedBlock = String(repeating: "b", count: SourceBlock.maxSourceUTF16 + 1)
        let oversizedMath = String(repeating: "c", count: NativeInlineObject.maxMathUTF16 + 1)
        let state = try makeYDocState { tx, group in
            var after: YItem?
            for (id, node, textValue) in [
                ("m-large", SourceBlock.mathBlock, largeEditable),
                ("m-huge", SourceBlock.mathBlock, oversizedBlock),
                ("d-fffc", SourceBlock.diagram, "graph\u{FFFC}TD"),
            ] {
                let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
                try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
                let el = YType(typeRef: .xmlElement(nodeName: node))
                try YWrite.insertAfter(tx, into: container, after: nil, [.type(el)])
                let txt = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: el, after: nil, [.type(txt)])
                try txt.insert(0, textValue, nil)
            }
            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("p-huge")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, oversizedMath, nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. Editable source > maxMathUTF16 (20_001) places initial selection at 0 instead of end.
        let largeEditor = NativeSourceEditorViewController(
            document: harness.session, request: .block(blockID: "m-large"))
        let largeWindow = hostController(UINavigationController(rootViewController: largeEditor))
        defer { largeWindow.isHidden = true }
        await waitForSourceLoaded(largeEditor)
        let largeTV = try XCTUnwrap(largeEditor.sourceSession?.textView)
        XCTAssertEqual(largeTV.selectedRange, NSRange(location: 0, length: 0))
        largeEditor.close()

        // 2. Oversized or U+FFFC targets refuse to open on live editing session (isGone).
        for req: NativeSourceRequest in [
            .block(blockID: "m-huge"),
            .block(blockID: "d-fffc"),
            .inlineMath(blockID: "p-huge", utf16Offset: 0),
        ] {
            let gone = NativeSourceEditorViewController(document: harness.session, request: req)
            let win = hostController(UINavigationController(rootViewController: gone))
            await waitForSourceLoaded(gone)
            XCTAssertTrue(gone.isGone, "\(req)")
            XCTAssertNil(gone.sourceSession, "\(req)")
            win.isHidden = true
        }

        // 3. Read-only inspect session also treats oversized blocks and inline math as unfamiliar/opaque
        // (never opens them or exposes clipped text), while editable m-large still opens read-only.
        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        for req: NativeSourceRequest in [
            .block(blockID: "m-huge"),
            .block(blockID: "d-fffc"),
            .inlineMath(blockID: "p-huge", utf16Offset: 0),
        ] {
            let roGone = NativeSourceEditorViewController(document: inspected, request: req)
            let roWin = hostController(UINavigationController(rootViewController: roGone))
            await waitForSourceLoaded(roGone)
            XCTAssertTrue(roGone.isGone, "\(req)")
            XCTAssertNil(roGone.sourceSession, "\(req)")
            roWin.isHidden = true
        }
        let roLarge = NativeSourceEditorViewController(document: inspected, request: .block(blockID: "m-large"))
        let roLargeWin = hostController(UINavigationController(rootViewController: roLarge))
        defer { roLargeWin.isHidden = true }
        await waitForSourceLoaded(roLarge)
        XCTAssertFalse(roLarge.isGone)
        let roLargeTV = try XCTUnwrap(roLarge.sourceSession?.textView)
        XCTAssertFalse(roLargeTV.isEditable)
        XCTAssertEqual(
            roLarge.sourceSession?.surface.blocks.first?.runs.map(\.text).joined().utf16.count,
            NativeInlineObject.maxMathUTF16 + 1)
        roLarge.close()
    }

    func testS2SourceCoordinatorNormalizesLineBreaksAndCancelsDisallowedCompositionWithoutFreezing() async throws {
        let initialInline = String(repeating: "x", count: NativeInlineObject.maxMathUTF16 - 5)
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("mx")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "a", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(iTxt)])
            try iTxt.insert(0, initialInline, nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. mathBlock normalizes \r\n, \u{2028}, \u{2029} on IME commit and stays unfrozen on \u{000C}.
        let mathEditor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        let mathWin = hostController(UINavigationController(rootViewController: mathEditor))
        defer { mathWin.isHidden = true }
        await waitForSourceLoaded(mathEditor)
        let mathSession = try XCTUnwrap(mathEditor.sourceSession)
        let mathInput = try XCTUnwrap(mathSession.input)
        let mathTV = mathSession.textView

        mathTV.selectedRange = NSRange(location: 1, length: 0)
        mathTV.setMarkedText("1\r\n2\u{2028}3\u{2029}4", selectedRange: NSRange(location: 7, length: 0))
        mathTV.unmarkText()
        await mathSession.settle()
        let xmlNorm = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xmlNorm?.contains("<mathblock>a1\n2\n3\n4</mathblock>") == true, xmlNorm ?? "")

        mathTV.selectedRange = NSRange(location: 1, length: 0)
        mathTV.setMarkedText("bad\u{001B}", selectedRange: NSRange(location: 4, length: 0))
        mathTV.unmarkText()
        await mathSession.settle()
        XCTAssertFalse(mathInput.isFrozen)
        XCTAssertTrue(mathTV.isEditable)
        XCTAssertEqual(mathInput.noticeKey, .native_editor_input_unavailable)
        XCTAssertFalse(mathTV.text.contains("bad"))
        XCTAssertEqual(try harness.store.provisionalRecoveries(for: harness.scope).map(\.text), ["bad\u{001B}"])

        mathTV.insertText("!")
        await mathSession.settle()
        XCTAssertTrue(mathTV.text.contains("!"), mathTV.text ?? "")
        mathEditor.close()

        // 2. inlineMath normalizes \n and \t to space on IME commit and keeps still-refused overflow recoverable.
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let inlineWin = hostController(UINavigationController(rootViewController: inlineEditor))
        defer { inlineWin.isHidden = true }
        await waitForSourceLoaded(inlineEditor)
        let inlineSession = try XCTUnwrap(inlineEditor.sourceSession)
        let inlineInput = try XCTUnwrap(inlineSession.input)
        let inlineTV = inlineSession.textView

        inlineTV.selectedRange = NSRange(location: 0, length: 0)
        inlineTV.setMarkedText("a\nb", selectedRange: NSRange(location: 3, length: 0))
        inlineTV.unmarkText()
        await inlineSession.settle()
        XCTAssertFalse(inlineInput.isFrozen)
        XCTAssertTrue(inlineTV.isEditable)
        XCTAssertTrue(inlineTV.text.hasPrefix("a b"), inlineTV.text ?? "")

        inlineTV.selectedRange = NSRange(location: 0, length: 0)
        inlineTV.setMarkedText("123456", selectedRange: NSRange(location: 6, length: 0))
        inlineTV.unmarkText()
        await inlineSession.settle()
        XCTAssertFalse(inlineInput.isFrozen)
        XCTAssertTrue(inlineTV.isEditable)
        XCTAssertEqual(inlineInput.noticeKey, .native_editor_paste_too_large)
        XCTAssertTrue(
            try harness.store.provisionalRecoveries(for: harness.scope).map(\.text).contains("123456"))

        // Subsequent valid IME commit of 2 chars fits within remaining maxMathUTF16 and succeeds.
        inlineTV.selectedRange = NSRange(location: 0, length: 0)
        inlineTV.setMarkedText("ok", selectedRange: NSRange(location: 2, length: 0))
        inlineTV.unmarkText()
        await inlineSession.settle()
        XCTAssertTrue(inlineTV.text.hasPrefix("ok"))
        inlineEditor.close()
    }

    func testS4SourcePasteControlCharsAndOverflowRouteThroughBarrierWithoutRollbackOrProvisional() async throws {
        let initialInline = String(repeating: "x", count: NativeInlineObject.maxMathUTF16 - 5)
        let state = try makeYDocState { tx, group in
            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(iTxt)])
            try iTxt.insert(0, initialInline, nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let editor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let win = hostController(UINavigationController(rootViewController: editor))
        defer { win.isHidden = true }
        await waitForSourceLoaded(editor)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        let sourceInput = try XCTUnwrap(sourceSession.input)
        let tv = sourceSession.textView

        // 1. Control character paste routes through barrier -> .refused (no rollback, no provisional.json).
        tv.selectedRange = NSRange(location: 0, length: 0)
        sourceInput.pasteboard.string = "bad\u{000C}paste"
        let pastedBad = await sourceSession.run { sourceInput.pasteFromPasteboard() }
        XCTAssertFalse(pastedBad)
        XCTAssertEqual(sourceInput.noticeKey, .native_editor_input_unavailable)
        XCTAssertTrue(sourceInput.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)
        XCTAssertTrue(tv.isEditable)
        XCTAssertFalse(sourceInput.isFrozen)

        // 2. Cumulative overflow paste routes through barrier -> .refused (.payloadTooLarge).
        sourceInput.pasteboard.string = "123456"
        let pastedTooLarge = await sourceSession.run { sourceInput.pasteFromPasteboard() }
        XCTAssertFalse(pastedTooLarge)
        XCTAssertEqual(sourceInput.noticeKey, .native_editor_paste_too_large)
        XCTAssertTrue(sourceInput.composition.pendingRecoveries.isEmpty)
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)

        // 3. No epoch invalidation / barrierOnly lock-out: subsequent keystroke predicts synchronously on surface.
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.insertText("1")
        XCTAssertEqual(sourceSession.surface.blocks.first?.runs.first?.text.first, "1")
        await sourceSession.settle()
        editor.close()
    }

    func testC1SelectAllInSourceEditorSupportsTypingPastingCuttingDeletingAndMarkedText() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            let mContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(mContainer)])
            try YWrite.mapSet(tx, on: mContainer, key: "id", .any([.string("mx")]))
            let mEl = YType(typeRef: .xmlElement(nodeName: SourceBlock.mathBlock))
            try YWrite.insertAfter(tx, into: mContainer, after: nil, [.type(mEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, "abc", nil)

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(iTxt)])
            try iTxt.insert(0, "x+y", nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let editor = NativeSourceEditorViewController(document: harness.session, request: .block(blockID: "mx"))
        let win = hostController(UINavigationController(rootViewController: editor))
        defer { win.isHidden = true }
        await waitForSourceLoaded(editor)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        let sourceInput = try XCTUnwrap(sourceSession.input)
        let tv = sourceSession.textView

        // 1. Select all (0..<storage.length includes trailing "\n") + type replacement.
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 0, length: 4))
        let typed = await sourceSession.run { sourceInput.replace(range: tv.selectedRange, with: "Z") }
        XCTAssertTrue(typed)
        XCTAssertEqual(tv.text, "Z\n")

        // 2. Select all + paste.
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        sourceInput.pasteboard.string = "P"
        let pasted = await sourceSession.run { sourceInput.pasteFromPasteboard() }
        XCTAssertTrue(pasted)
        XCTAssertEqual(tv.text, "P\n")

        // 3. Select all + cut.
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        let cut = await sourceSession.run { sourceInput.cutSelection() }
        XCTAssertTrue(cut)
        XCTAssertEqual(sourceInput.pasteboard.string, "P")
        XCTAssertEqual(tv.text, "\n")

        // 4. Select all on EMPTY source (0..<1) + delete is a clean no-op without refusal.
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 0, length: 1))
        let deletedEmpty = await sourceSession.run { sourceInput.replace(range: tv.selectedRange, with: "") }
        XCTAssertTrue(deletedEmpty)
        XCTAssertNil(sourceInput.noticeKey)
        XCTAssertEqual(tv.text, "\n")
        XCTAssertEqual(tv.selectedRange, NSRange(location: 0, length: 0))

        // 5. Select all + IME setMarkedText.
        _ = await sourceSession.run { sourceInput.replace(range: NSRange(location: 0, length: 0), with: "xy") }
        XCTAssertEqual(tv.text, "xy\n")
        tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length)
        tv.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNil(sourceInput.noticeKey)
        XCTAssertTrue(tv.isEditable)
        tv.unmarkText()
        await sourceSession.settle()
        XCTAssertEqual(tv.text, "あ\n")
        editor.close()

        // 6. Select all + delete on non-empty inlineMath.
        let inlineEditor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let inlineWin = hostController(UINavigationController(rootViewController: inlineEditor))
        defer { inlineWin.isHidden = true }
        await waitForSourceLoaded(inlineEditor)
        let inlineSession = try XCTUnwrap(inlineEditor.sourceSession)
        let inlineInput = try XCTUnwrap(inlineSession.input)
        let inlineTV = inlineSession.textView
        inlineTV.selectedRange = NSRange(location: 0, length: inlineTV.textStorage.length)
        let deletedInline = await inlineSession.run { inlineInput.replace(range: inlineTV.selectedRange, with: "") }
        XCTAssertTrue(deletedInline)
        XCTAssertEqual(inlineTV.text, "\n")
        inlineEditor.close()
        await harness.settle()
        let xml = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertTrue(xml?.contains("<math></math>") == true, xml ?? "")
    }

    func testC2RequestedSourceSetOnlyOnAppliedNeverOnRefusedOrTwiceOnStaleRetry() async throws {
        // 1. .refused: slash /mathBlock inside a heading (canFormat == true, engine refuses non-paragraph).
        let headingBlock = BlockNoteBlock(
            node: "heading",
            props: Self.paragraphProps + [("level", .int(1)), ("isToggleable", .bool(false))],
            runs: [InlineRun("/math")],
            id: "h1")
        let refusedHarness = try await makeHarness([headingBlock])
        addTeardownBlock { await refusedHarness.close() }
        setSelection(refusedHarness, NSRange(location: 5, length: 0))
        let mathItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "mathBlock" })
        let refusedApplied = await refusedHarness.run { refusedHarness.input.applySlashItem(mathItem) }
        XCTAssertFalse(refusedApplied)
        XCTAssertNil(refusedHarness.input.requestedSource, "refused slash command must not set requestedSource")

        // 2. .stale then retry -> .applied: requestedSource stays nil until .applied.
        let initial = [
            paragraph("other", "Other"),
            paragraph("p1", "/math"),
        ]
        let staleHarness = try await makeHarness(initial)
        addTeardownBlock { await staleHarness.close() }
        setSelection(staleHarness, NSRange(location: try location(staleHarness.session, "p1", 5), length: 0))

        let peer = YDoc(clientID: 2, gc: true)
        defer { peer.destroy() }
        try peer.applyUpdate(
            YUpdateDecoder.decode(try XCTUnwrap(staleHarness.store.restore(for: staleHarness.scope)?.checkpoint)))
        let peerWriter = BlockNoteWriter(doc: peer)
        let peerUpdate = try peerWriter.replaceText(block: "other", range: 0..<0, with: "!")
        let replica = try XCTUnwrap(staleHarness.session.replica)
        replica.mailbox.post(.integrate(peerUpdate, reply: nil))

        let posted = staleHarness.input.applySlashItem(mathItem)
        XCTAssertTrue(posted)
        XCTAssertNil(staleHarness.input.requestedSource, "requestedSource must not be set before .applied")
        await staleHarness.settle()
        XCTAssertEqual(staleHarness.input.requestedSource, .block(blockID: "p1"))

        // 3. .stale where peer deleted target block -> retry cannot apply -> requestedSource stays nil.
        let deleteHarness = try await makeHarness([
            paragraph("other", "Other"),
            paragraph("p1", "/inline"),
        ])
        addTeardownBlock { await deleteHarness.close() }
        setSelection(deleteHarness, NSRange(location: try location(deleteHarness.session, "p1", 7), length: 0))

        let peer2 = YDoc(clientID: 3, gc: true)
        defer { peer2.destroy() }
        try peer2.applyUpdate(
            YUpdateDecoder.decode(try XCTUnwrap(deleteHarness.store.restore(for: deleteHarness.scope)?.checkpoint)))
        let peerWriter2 = BlockNoteWriter(doc: peer2)
        let deleteUpdate = try peerWriter2.deleteBlock(try peerWriter2.find("p1").item, id: "p1")
        try XCTUnwrap(deleteHarness.session.replica).mailbox.post(.integrate(deleteUpdate, reply: nil))

        let inlineItem = try XCTUnwrap(NativeInputCoordinator.slashItems.first { $0.id == "inlineMath" })
        _ = deleteHarness.input.applySlashItem(inlineItem)
        XCTAssertNil(deleteHarness.input.requestedSource)
        await deleteHarness.settle()
        XCTAssertNil(deleteHarness.input.requestedSource)
    }

    func testR1R2OversizedSourcesShowAsPreservedNeverCutCopiedLossilyOrOpened() async throws {
        let oversizedBlock = String(repeating: "z", count: SourceBlock.maxSourceUTF16 + 25)
        let oversizedMath = String(repeating: "x", count: NativeInlineObject.maxMathUTF16 + 25)
        let state = try makeYDocState { tx, group in
            var after: YItem?
            for (id, node, value) in [
                ("m-huge", SourceBlock.mathBlock, oversizedBlock),
                ("d-huge", SourceBlock.diagram, oversizedBlock),
            ] {
                let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
                try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
                let el = YType(typeRef: .xmlElement(nodeName: node))
                try YWrite.insertAfter(tx, into: container, after: nil, [.type(el)])
                let txt = YType(typeRef: .xmlText)
                try YWrite.insertAfter(tx, into: el, after: nil, [.type(txt)])
                try txt.insert(0, value, nil)
            }

            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("p-huge")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let mTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(mTxt)])
            try mTxt.insert(0, oversizedMath, nil)

            let tContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(tContainer)])
            try YWrite.mapSet(tx, on: tContainer, key: "id", .any([.string("tbl-huge")]))
            let tEl = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: tContainer, after: nil, [.type(tEl)])
            var prevRow: YItem?
            for r in 0..<2 {
                let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                prevRow = try YWrite.insertAfter(tx, into: tEl, after: prevRow, [.type(row)])
                var prevCell: YItem?
                for c in 0..<2 {
                    let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
                    prevCell = try YWrite.insertAfter(tx, into: row, after: prevCell, [.type(cell)])
                    let para = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
                    _ = try YWrite.insertAfter(tx, into: cell, after: nil, [.type(para)])
                    if r == 0 && c == 0 {
                        let cellMath = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
                        _ = try YWrite.insertAfter(tx, into: para, after: nil, [.type(cellMath)])
                        let cmTxt = YType(typeRef: .xmlText)
                        _ = try YWrite.insertAfter(tx, into: cellMath, after: nil, [.type(cmTxt)])
                        try cmTxt.insert(0, oversizedMath, nil)
                    } else {
                        let cTxt = YType(typeRef: .xmlText)
                        _ = try YWrite.insertAfter(tx, into: para, after: nil, [.type(cTxt)])
                        try cTxt.insert(0, "c\(r)\(c)", nil)
                    }
                }
            }

            let tail = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: after, [.type(tail)])
            try YWrite.mapSet(tx, on: tail, key: "id", .any([.string("p-tail")]))
            let tailEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            _ = try YWrite.insertAfter(tx, into: tail, after: nil, [.type(tailEl)])
            let tailTxt = YType(typeRef: .xmlText)
            _ = try YWrite.insertAfter(tx, into: tailEl, after: nil, [.type(tailTxt)])
            try tailTxt.insert(0, "tail", nil)
        }

        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let beforeXML = await harness.session.replicaDoc { YXMLString.fragment($0) }

        // Surface blocks and attachments treat all oversized targets as preserved/opaque without inline chips.
        for id in ["m-huge", "d-huge", "p-huge"] {
            let block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == id }, id)
            XCTAssertTrue(block.isOpaque, id)
            XCTAssertTrue(block.runs.isEmpty, id)
            guard case .preserved? = block.preview else { return XCTFail("expected .preserved preview for \(id)") }
        }
        XCTAssertTrue(inlineChipLocations(in: harness.view.attributedText).isEmpty)

        // Selection across opaque / oversized blocks never copies clipped text or cuts anything.
        for id in ["m-huge", "d-huge", "p-huge", "tbl-huge"] {
            let entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: id), id)
            setSelection(harness, entry.range)
            harness.input.pasteboard.items = []
            harness.input.copySelection()
            XCTAssertNil(harness.input.pasteboard.string, id)
            let cutResult = await harness.run { harness.input.cutSelection() }
            XCTAssertFalse(cutResult, id)
        }

        // Table containing oversized <math> opens read-only with no cell editor or table copy.
        let openedTable = await harness.session.openTable("tbl-huge")
        XCTAssertNil(openedTable)
        let tableEditor = TableEditorViewController(document: harness.session, tableID: "tbl-huge")
        let tableWin = hostController(tableEditor)
        defer { tableWin.isHidden = true }
        await tableEditor.load()
        XCTAssertNil(tableEditor.cellSession)
        XCTAssertEqual(tableEditor.grid?.familiarity, .unfamiliar("unexpected cell content"))

        // Opening any oversized block or inline math refuses in both edit and read-only inspect modes.
        let inspected = try await NativeEditorSession.inspect(state: state)
        addTeardownBlock { await inspected.close().value }
        for session in [harness.session, inspected] {
            for req: NativeSourceRequest in [
                .block(blockID: "m-huge"),
                .block(blockID: "d-huge"),
                .inlineMath(blockID: "p-huge", utf16Offset: 0),
            ] {
                let vc = NativeSourceEditorViewController(document: session, request: req)
                let win = hostController(UINavigationController(rootViewController: vc))
                await waitForSourceLoaded(vc)
                XCTAssertTrue(vc.isGone, "\(req)")
                XCTAssertNil(vc.sourceSession, "\(req)")
                win.isHidden = true
            }
        }

        let afterXML = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertEqual(afterXML, beforeXML)
    }

    func testR3InlineMathNormalizesNewlineAndTabAndKeepsRefusedCommitsRecoverable() async throws {
        let initialInline = String(repeating: "x", count: NativeInlineObject.maxMathUTF16 - 5)
        let state = try makeYDocState { tx, group in
            let pContainer = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            _ = try YWrite.insertAfter(tx, into: group, after: nil, [.type(pContainer)])
            try YWrite.mapSet(tx, on: pContainer, key: "id", .any([.string("px")]))
            let pEl = YType(typeRef: .xmlElement(nodeName: "paragraph"))
            try YWrite.insertAfter(tx, into: pContainer, after: nil, [.type(pEl)])
            let mathEl = YType(typeRef: .xmlElement(nodeName: NativeInlineObject.mathNodeName))
            try YWrite.insertAfter(tx, into: pEl, after: nil, [.type(mathEl)])
            let iTxt = YType(typeRef: .xmlText)
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(iTxt)])
            try iTxt.insert(0, initialInline, nil)
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let editor = NativeSourceEditorViewController(
            document: harness.session, request: .inlineMath(blockID: "px", utf16Offset: 0))
        let win = hostController(UINavigationController(rootViewController: editor))
        defer { win.isHidden = true }
        await waitForSourceLoaded(editor)
        let sourceSession = try XCTUnwrap(editor.sourceSession)
        let sourceInput = try XCTUnwrap(sourceSession.input)
        let tv = sourceSession.textView

        // 1. IME / dictation commit with \n, \r\n, \u{2028}, and \t normalizes each to a space and commits cleanly.
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.setMarkedText("a\nb\tc", selectedRange: NSRange(location: 5, length: 0))
        tv.unmarkText()
        await sourceSession.settle()
        XCTAssertEqual(sourceInput.composition.pendingRecoveries, [])
        XCTAssertTrue(try harness.store.provisionalRecoveries(for: harness.scope).isEmpty)
        XCTAssertTrue(tv.text.hasPrefix("a b c"), tv.text ?? "")

        // 2. Remaining capacity is now 0; an overflow IME commit refuses cleanly and preserves the composed text.
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.setMarkedText("overflow", selectedRange: NSRange(location: 8, length: 0))
        tv.unmarkText()
        await sourceSession.settle()
        XCTAssertFalse(sourceInput.isFrozen)
        XCTAssertTrue(tv.isEditable)
        XCTAssertEqual(sourceInput.noticeKey, .native_editor_paste_too_large)
        XCTAssertTrue(sourceInput.composition.pendingRecoveries.map(\.text).contains("overflow"))
        XCTAssertTrue(
            try harness.store.provisionalRecoveries(for: harness.scope).map(\.text).contains("overflow"))

        // 3. Disallowed scalar commits (bidi format, control char) refuse and keep text recoverable without freezing.
        tv.selectedRange = NSRange(location: 0, length: 5)
        tv.setMarkedText("ok\u{202E}!", selectedRange: NSRange(location: 4, length: 0))
        tv.unmarkText()
        await sourceSession.settle()
        XCTAssertFalse(sourceInput.isFrozen)
        XCTAssertTrue(tv.isEditable)
        XCTAssertEqual(sourceInput.noticeKey, .native_editor_input_unavailable)
        XCTAssertTrue(sourceInput.composition.pendingRecoveries.map(\.text).contains("ok\u{202E}!"))
        XCTAssertTrue(
            try harness.store.provisionalRecoveries(for: harness.scope).map(\.text).contains("ok\u{202E}!"))
        editor.close()
    }
}
