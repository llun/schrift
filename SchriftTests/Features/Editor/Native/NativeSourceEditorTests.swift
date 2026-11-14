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
}
