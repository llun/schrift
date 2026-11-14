import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// Step 3 of PR14: exact `.source` block previews (labelled as source, no
/// rendering, no syntax-validity claims) and `.math` inline chips (Dynamic Type,
/// VoiceOver, clipboard, and tap hit-testing in prose, columns, and tables).
@MainActor
final class NativeSourcePreviewTests: NativeEditingTestCase {
    @discardableResult
    private func host(_ view: NativeTextView, width: CGFloat = 390, height: CGFloat = 1_200) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    @discardableResult
    private func hostController(_ controller: UIViewController, width: CGFloat = 390, height: CGFloat = 844) -> UIWindow
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func block(_ node: String, _ id: String, text: String) -> BlockNoteBlock {
        BlockNoteBlock(node: node, props: [], runs: text.isEmpty ? [] : [InlineRun(text)], id: id)
    }

    private func realized(_ session: NativeEditorSession, _ id: String) -> NativeAttachmentView? {
        session.textView.blockControls.visibleAttachmentViews.first { $0.content.blockID == id }
    }

    private func attachment(_ session: NativeEditorSession, _ id: String) throws -> NativeBlockAttachment {
        let entry = try XCTUnwrap(session.surface.rangeIndex.entry(for: id))
        return try XCTUnwrap(
            session.textView.textStorage.attribute(.attachment, at: entry.range.location, effectiveRange: nil)
                as? NativeBlockAttachment)
    }

    private func labelTexts(in view: UIView) -> [String] {
        var result: [String] = []
        var queue = view.subviews
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let label = next as? UILabel, let text = label.text { result.append(text) }
            queue += next.subviews
        }
        return result
    }

    private func inlineAttachments(in attributed: NSAttributedString) -> [(NSRange, NativeInlineChipAttachment)] {
        var result: [(NSRange, NativeInlineChipAttachment)] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) {
            value, range, _ in
            if let chip = value as? NativeInlineChipAttachment {
                for offset in 0..<range.length {
                    result.append((NSRange(location: range.location + offset, length: 1), chip))
                }
            }
        }
        return result
    }

    private func ensureInlineChipFrame(in textView: NativeTextView, utf16Offset: Int) async throws -> CGRect {
        textView.layoutIfNeeded()
        for _ in 0..<20 {
            if let frame = textView.inlineChipFrame(atUTF16: utf16Offset) {
                return frame
            }
            textView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(textView.inlineChipFrame(atUTF16: utf16Offset))
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

    private enum InlineChild {
        case text(String)
        case inline(NativeInlineObject)
    }

    @discardableResult
    private func insertContainer(
        _ tx: YTransaction, into group: YType, after: inout YItem?, id: String, node: String,
        props: [(String, YAnyValue)] = [], children: [InlineChild]
    ) throws -> YItem? {
        let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
        after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
        try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
        let element = YType(typeRef: .xmlElement(nodeName: node))
        try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
        for (key, value) in props {
            try YWrite.mapSet(tx, on: element, key: key, .any([value]))
        }
        var childAfter: YItem?
        for child in children {
            switch child {
            case .text(let s):
                let xmlText = YType(typeRef: .xmlText)
                childAfter = try YWrite.insertAfter(tx, into: element, after: childAfter, [.type(xmlText)])
                if !s.isEmpty {
                    try xmlText.insert(0, s, nil)
                }
            case .inline(let obj):
                let inlineElement = YType(typeRef: .xmlElement(nodeName: obj.nodeName))
                childAfter = try YWrite.insertAfter(tx, into: element, after: childAfter, [.type(inlineElement)])
                for (key, value) in obj.canonicalProps {
                    try YWrite.mapSet(tx, on: inlineElement, key: key, .any([value]))
                }
                if case .math(let source) = obj, !source.isEmpty {
                    let xmlText = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: inlineElement, after: nil, [.type(xmlText)])
                    try xmlText.insert(0, source, nil)
                }
            }
        }
        return after
    }

    // MARK: - Block .source Previews

    func testExactSourceBlockPreviewsPreserveIndentationBlankLinesEmptyStateAndSourceLabels() async throws {
        let harness = try await makeHarness([
            block("mathBlock", "m-empty", text: ""),
            block("mathBlock", "m-indent", text: "  \\frac{1}{\n\n    x + 1\n"),
            block("diagram", "d-empty", text: ""),
            block("diagram", "d-invalid", text: "not valid mermaid @@@\n  line 2\n  line 3\n  line 4\n  line 5"),
        ])
        addTeardownBlock { await harness.close() }
        let window = host(harness.view, height: 1_600)
        defer { window.isHidden = true }

        // Empty source blocks: lines = [], lineCount = 0, explicit "Empty source" placeholder.
        XCTAssertEqual(
            try attachment(harness.session, "m-empty").content.preview,
            .source(node: "mathBlock", lines: [], lineCount: 0))
        XCTAssertEqual(
            try attachment(harness.session, "d-empty").content.preview,
            .source(node: "diagram", lines: [], lineCount: 0))

        // Indentation on line 1, internal blank lines, and trailing blank line are preserved verbatim.
        XCTAssertEqual(
            try attachment(harness.session, "m-indent").content.preview,
            .source(node: "mathBlock", lines: ["  \\frac{1}{", "", "    x + 1", ""], lineCount: 4))

        // Invalid syntax renders verbatim as source without syntax-validity claims.
        XCTAssertEqual(
            try attachment(harness.session, "d-invalid").content.preview,
            .source(
                node: "diagram", lines: ["not valid mermaid @@@", "  line 2", "  line 3", "  line 4"], lineCount: 5))

        let emptyMathView = try XCTUnwrap(realized(harness.session, "m-empty"))
        XCTAssertEqual(emptyMathView.accessibilityLabel, "Math source")
        XCTAssertEqual(emptyMathView.accessibilityValue, "Empty source")
        XCTAssertEqual(labelTexts(in: emptyMathView), ["Math source", "Empty source"])

        let indentMathView = try XCTUnwrap(realized(harness.session, "m-indent"))
        XCTAssertEqual(indentMathView.accessibilityLabel, "Math source")
        XCTAssertEqual(indentMathView.accessibilityValue, "  \\frac{1}{\n\n    x + 1\n")
        XCTAssertEqual(labelTexts(in: indentMathView), ["Math source", "  \\frac{1}{\n\n    x + 1\n"])

        let emptyDiagramView = try XCTUnwrap(realized(harness.session, "d-empty"))
        XCTAssertEqual(emptyDiagramView.accessibilityLabel, "Diagram source")
        XCTAssertEqual(emptyDiagramView.accessibilityValue, "Empty source")
        XCTAssertEqual(labelTexts(in: emptyDiagramView), ["Diagram source", "Empty source"])

        let invalidDiagramView = try XCTUnwrap(realized(harness.session, "d-invalid"))
        XCTAssertEqual(invalidDiagramView.accessibilityLabel, "Diagram source")
        XCTAssertEqual(
            invalidDiagramView.accessibilityValue,
            "not valid mermaid @@@\n  line 2\n  line 3\n  line 4\n… more")
        let diagramTexts = labelTexts(in: invalidDiagramView)
        XCTAssertEqual(
            diagramTexts, ["Diagram source", "not valid mermaid @@@\n  line 2\n  line 3\n  line 4", "… more"])
        for chromeText in [diagramTexts.first, diagramTexts.last, invalidDiagramView.accessibilityLabel].compactMap({
            $0
        }) {
            XCTAssertFalse(chromeText.localizedCaseInsensitiveContains("error"))
            XCTAssertFalse(chromeText.localizedCaseInsensitiveContains("valid"))
        }

        // Dynamic Type scaling updates card heights without writing Yjs.
        let smallHeight = try attachment(harness.session, "m-indent").content.size.height
        harness.session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge),
            labels: harness.session.surface.labels)
        harness.view.layoutIfNeeded()
        XCTAssertGreaterThan(try attachment(harness.session, "m-indent").content.size.height, smallHeight)
        try await assertConsistent(harness, localCommands: 0)
    }

    func testUnfamiliarAndClassicSourceBlocksRouteToPreservedNeverSource() throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "m-props", node: "mathBlock",
                props: [("engine", .string("katex"))], children: [.text("x^2")])
            let badText = YType(typeRef: .xmlText)
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("m-marked")]))
            let mathEl = YType(typeRef: .xmlElement(nodeName: "mathBlock"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(mathEl)])
            try YWrite.insertAfter(tx, into: mathEl, after: nil, [.type(badText)])
            try badText.insert(0, "x^2", ["bold": "{}"])
            try insertContainer(
                tx, into: group, after: &after, id: "d-ok", node: "diagram", children: [.text("  A --> B")])
        }
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(try YUpdateDecoder.decode(state))

        let nativeProj = NativeBlockProjection.project(doc, nativeMarks: true)
        let byID = Dictionary(uniqueKeysWithValues: nativeProj.blocks.map { ($0.id, $0) })
        XCTAssertTrue(byID["m-props"]?.block.fidelity.isOpaque == true)
        XCTAssertEqual(byID["m-props"]?.preview, .preserved(node: "mathBlock", summary: "x^2"))
        XCTAssertTrue(byID["m-marked"]?.block.fidelity.isOpaque == true)
        XCTAssertEqual(byID["m-marked"]?.preview, .preserved(node: "mathBlock", summary: "x^2"))
        XCTAssertEqual(byID["d-ok"]?.preview, .source(node: "diagram", lines: ["  A --> B"], lineCount: 1))

        // Classic projection (nativeMarks: false) keeps mathBlock/diagram opaque and routed to .preserved.
        let classicProj = NativeBlockProjection.project(doc, nativeMarks: false)
        let classicDiagram = try XCTUnwrap(classicProj.blocks.first { $0.id == "d-ok" })
        XCTAssertTrue(classicDiagram.block.fidelity.isOpaque)
        XCTAssertEqual(classicDiagram.preview, .preserved(node: "diagram", summary: "A --> B"))
    }

    func testSourceBlockCardTapAndVoiceOverActivateInvokeOnOpenSource() async throws {
        let harness = try await makeHarness([
            block("mathBlock", "m1", text: "E = mc^2"),
            block("diagram", "d1", text: "graph TD"),
        ])
        addTeardownBlock { await harness.close() }
        var requests: [NativeSourceRequest] = []
        harness.view.blockControls.onOpenSource = { requests.append($0) }
        let window = host(harness.view)
        defer { window.isHidden = true }

        let mathView = try XCTUnwrap(realized(harness.session, "m1"))
        let diagView = try XCTUnwrap(realized(harness.session, "d1"))
        XCTAssertTrue(mathView.accessibilityTraits.contains(.button))
        XCTAssertTrue(diagView.accessibilityTraits.contains(.button))
        XCTAssertTrue(mathView.accessibilityActivate())
        XCTAssertTrue(diagView.accessibilityActivate())
        XCTAssertEqual(requests, [.block(blockID: "m1"), .block(blockID: "d1")])
    }

    // MARK: - Inline .math Chips (Projection, Dynamic Type, Cache, VoiceOver, Clipboard, Hit-Testing)

    func testInlineMathChipStylingDynamicTypeCacheAndVoiceOver() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "plain", node: "paragraph", children: [.text("Plain")])
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("Let "),
                    .inline(.math(source: "a^2 + b^2 = c^2")),
                    .text(" "),
                    .inline(.math(source: "")),
                    .text(" "),
                    .inline(.math(source: "   ")),
                    .inline(.math(source: "x")),
                    .inline(.math(source: "x")),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        host(harness.view, width: 600)

        let chips = inlineAttachments(in: harness.view.textStorage)
        XCTAssertEqual(chips.count, 5)
        XCTAssertEqual(chips[0].1.content.kind, .math)
        XCTAssertEqual(chips[0].1.content.displayLabel, "a^2 + b^2 = c^2")
        XCTAssertEqual(chips[0].1.content.accessibilityLabel, "Math source: a^2 + b^2 = c^2")
        XCTAssertFalse(chips[0].1.content.isPlaceholder)

        // Empty and whitespace-only math chips show explicit "Math source" label.
        for emptyChip in [chips[1].1, chips[2].1] {
            XCTAssertTrue(emptyChip.content.isPlaceholder)
            XCTAssertEqual(emptyChip.content.displayLabel, "Math source")
            XCTAssertEqual(emptyChip.content.accessibilityLabel, "Math source")
        }

        // Line height stays strictly inside DocumentLinkChipIconBand.
        let plainEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "plain"))
        let p1Entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        let layout = try XCTUnwrap(harness.view.textLayoutManager)
        let plainLoc = try XCTUnwrap(
            layout.location(layout.documentRange.location, offsetBy: plainEntry.range.location))
        let p1Loc = try XCTUnwrap(layout.location(layout.documentRange.location, offsetBy: p1Entry.range.location))
        layout.ensureLayout(for: try XCTUnwrap(NSTextRange(location: plainLoc)))
        layout.ensureLayout(for: try XCTUnwrap(NSTextRange(location: p1Loc)))
        let plainFrag = try XCTUnwrap(layout.textLayoutFragment(for: plainLoc))
        let p1Frag = try XCTUnwrap(layout.textLayoutFragment(for: p1Loc))
        XCTAssertEqual(
            p1Frag.textLineFragments[0].typographicBounds.height,
            plainFrag.textLineFragments[0].typographicBounds.height,
            accuracy: 0.5)

        // VoiceOver accessibilityValue expands adjacent identical math chips and omits U+FFFC.
        let axValue = try XCTUnwrap(harness.view.accessibilityValue)
        XCTAssertFalse(axValue.contains("\u{FFFC}"))
        XCTAssertEqual(
            axValue,
            "Plain\nLet Math source: a^2 + b^2 = c^2 Math source Math sourceMath source: xMath source: x\n")

        // Dynamic Type scaling & width clamping without writing Yjs.
        let beforeVector = await harness.session.replicaDoc { YStateEncoder.encodeStateVector($0) }
        let smallSize = chips[0].1.content.size
        harness.session.surface.updateAttachmentWidth(140)
        let clamped = inlineAttachments(in: harness.view.textStorage)[0].1
        XCTAssertLessThanOrEqual(clamped.content.size.width, 140)
        harness.session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge),
            labels: harness.session.surface.labels)
        let scaled = inlineAttachments(in: harness.view.textStorage)[0].1
        XCTAssertGreaterThan(scaled.content.size.height, smallSize.height)
        XCTAssertGreaterThan(scaled.content.fontSize, chips[0].1.content.fontSize)
        XCTAssertLessThanOrEqual(scaled.content.size.width, 140)
        let afterVector = await harness.session.replicaDoc { YStateEncoder.encodeStateVector($0) }
        XCTAssertEqual(beforeVector, afterVector)

        // Image cache renders distinct PNGs for light/dark and themes, and differentiates placeholder vs text.
        let font = UIFont.preferredFont(forTextStyle: .body)
        let geometry = NativeAttachmentGeometry(width: 320)
        let labels = NativeEditorLabels()
        let nonEmptyContent = NativeInlineChipAttachment.content(
            for: .math(source: "x^2"), font: font, labels: labels, geometry: geometry)
        let whiteLight = NativeInlineChipImageCache.image(
            content: nonEmptyContent, font: font, theme: .white, isDark: false, scale: 2)
        let whiteDark = NativeInlineChipImageCache.image(
            content: nonEmptyContent, font: font, theme: .white, isDark: true, scale: 2)
        let paperLight = NativeInlineChipImageCache.image(
            content: nonEmptyContent, font: font, theme: .paper, isDark: false, scale: 2)
        XCTAssertNotEqual(whiteLight.pngData(), whiteDark.pngData())
        XCTAssertNotEqual(whiteLight.pngData(), paperLight.pngData())
    }

    func testInlineMathChipClipboardCopyCutPasteInProseAndCodeBlock() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("A "),
                    .inline(.math(source: "x^2 + y^2")),
                    .text(" "),
                    .inline(.math(source: "")),
                    .text(" B"),
                ])
            try insertContainer(tx, into: group, after: &after, id: "dest", node: "paragraph", children: [.text("XY")])
            try insertContainer(
                tx, into: group, after: &after, id: "code1", node: "codeBlock",
                props: [("language", .string("swift"))], children: [.text("let v = ")])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let p1Entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        // Copy "A <math(x^2 + y^2)> ": plain text has exact source and no U+FFFC, plus lossless inline payload.
        harness.view.selectedRange = NSRange(location: p1Entry.textRange.location, length: 4)
        harness.input.copySelection()
        await harness.settle()
        XCTAssertEqual(harness.pasteboard.string, "A x^2 + y^2 ")
        XCTAssertFalse((harness.pasteboard.string ?? "").contains("\u{FFFC}"))
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteInlinePayload.pasteboardType))

        // Paste into prose preserves inline .math chip.
        let destEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "dest"))
        harness.view.selectedRange = NSRange(location: destEntry.textRange.location + 1, length: 0)
        let pastedToProse = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pastedToProse)
        let destBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "dest" })
        XCTAssertEqual(destBlock.runs.compactMap(\.inlineObject), [.math(source: "x^2 + y^2")])

        // Paste into codeBlock degrades .math chip to plain source text without inline element.
        let codeEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "code1"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(codeEntry.textRange), length: 0)
        let pastedToCode = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pastedToCode)
        let codeBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "code1" })
        XCTAssertFalse(codeBlock.hasInlineObjects)
        XCTAssertEqual(codeBlock.runs.map(\.text).joined(), "let v = A x^2 + y^2 ")

        // Copy only empty <math></math>: plain text is nil, lossless inline payload is kept and pastes.
        let p1Again = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        // p1: "A "(2) + math(1) + " "(1) + emptyMath(1) + " B"(2) -> offset 4
        harness.view.selectedRange = NSRange(location: p1Again.textRange.location + 4, length: 1)
        harness.input.copySelection()
        await harness.settle()
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteInlinePayload.pasteboardType))
        let destAgain = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "dest"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(destAgain.textRange), length: 0)
        let pastedEmptyMath = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(pastedEmptyMath)
        let destAfterEmpty = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "dest" })
        XCTAssertEqual(destAfterEmpty.runs.compactMap(\.inlineObject), [.math(source: "x^2 + y^2"), .math(source: "")])

        // Peer-authored <math> containing U+FFFC never leaks U+FFFC into plainText copy.
        let dirty = BlockSnapshot(
            id: "dirty", node: "paragraph", props: [],
            runs: [InlineRun(inlineObject: .math(source: "a\u{FFFC}b"))])
        let dirtySurface = NativeTextSurface(blocks: [dirty], storage: NSTextStorage())
        XCTAssertEqual(
            NativeClipboard.plainText(for: NSRange(location: 0, length: 1), surface: dirtySurface),
            "ab")
    }

    func testInlineMathChipTapHitTestingSideOffsetsAndVoiceOverInProse() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("See "),
                    .inline(.math(source: "x^2")),
                    .text(" and "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" end"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        host(harness.view)

        var requests: [NativeSourceRequest] = []
        harness.view.blockControls.onOpenSource = { requests.append($0) }

        let mathRange = try XCTUnwrap(
            inlineAttachments(in: harness.view.textStorage).first { $0.1.content.kind == .math }?.0)
        let mentionRange = try XCTUnwrap(
            inlineAttachments(in: harness.view.textStorage).first { $0.1.content.kind == .mention }?.0)

        for editable in [false, true] {
            harness.view.isEditable = editable
            let frame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: mathRange.location)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(harness.view.chipTapShouldBegin(at: center), "editable=\(editable)")
            XCTAssertTrue(harness.view.handleChipTap(at: center), "editable=\(editable)")
            XCTAssertEqual(requests.last, .inlineMath(blockID: "p1", utf16Offset: 4))

            // Side taps outside chip bounds do not trigger and keep left/right caret placement.
            let left = CGPoint(x: frame.minX - 2, y: frame.midY)
            let right = CGPoint(x: frame.maxX + 2, y: frame.midY)
            XCTAssertFalse(harness.view.chipTapShouldBegin(at: left))
            XCTAssertFalse(harness.view.handleChipTap(at: left))
            XCTAssertFalse(harness.view.chipTapShouldBegin(at: right))
            XCTAssertFalse(harness.view.handleChipTap(at: right))
            let leftPos = try XCTUnwrap(harness.view.closestPosition(to: left))
            let rightPos = try XCTUnwrap(harness.view.closestPosition(to: right))
            XCTAssertEqual(harness.view.offset(from: harness.view.beginningOfDocument, to: leftPos), mathRange.location)
            XCTAssertEqual(
                harness.view.offset(from: harness.view.beginningOfDocument, to: rightPos), mathRange.location + 1)

            // Mention chip never triggers onOpenSource.
            let mentionFrame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: mentionRange.location)
            XCTAssertFalse(harness.view.chipTapShouldBegin(at: CGPoint(x: mentionFrame.midX, y: mentionFrame.midY)))

            // VoiceOver custom action appears only when selection touches the .math chip.
            harness.view.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertFalse(
                (harness.view.accessibilityCustomActions ?? []).contains { $0.name == "Open math source" })
            for sel in [
                NSRange(location: mathRange.location, length: 0),
                NSRange(location: mathRange.location + 1, length: 0),
                NSRange(location: mathRange.location, length: 1),
            ] {
                harness.view.selectedRange = sel
                let action = try XCTUnwrap(
                    harness.view.accessibilityCustomActions?.first { $0.name == "Open math source" })
                XCTAssertTrue(action.actionHandler?(action) ?? false)
            }
            harness.view.selectedRange = NSRange(location: mentionRange.location, length: 1)
            XCTAssertFalse(
                (harness.view.accessibilityCustomActions ?? []).contains { $0.name == "Open math source" })
        }
        XCTAssertEqual(requests.count, 8)

        // IME marked text suppresses chip tap.
        let frame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: mathRange.location)
        harness.view.selectedRange = NSRange(location: 0, length: 0)
        harness.view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertFalse(harness.view.chipTapShouldBegin(at: CGPoint(x: frame.midX, y: frame.midY)))
        harness.view.unmarkText()
    }

    func testInlineMathChipTapHitTestingInColumnsAndTables() async throws {
        // 1. Columns: ColumnEditorScreen forwards onOpenSource to column NativeTextViews.
        let colState = try makeYDocState { tx, group in
            let list = YType(typeRef: .xmlElement(nodeName: "columnList"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(list)])
            try YWrite.mapSet(tx, on: list, key: "id", .any([.string("cl")]))

            var colAfter: YItem?
            for (colID, blockID, children) in [
                ("c1", "cp1", [InlineChild.text("Col "), .inline(.math(source: "\\pi"))]),
                ("c2", "cp2", [InlineChild.text("Right")]),
            ] {
                let col = YType(typeRef: .xmlElement(nodeName: "column"))
                colAfter = try YWrite.insertAfter(tx, into: list, after: colAfter, [.type(col)])
                try YWrite.mapSet(tx, on: col, key: "id", .any([.string(colID)]))
                try YWrite.mapSet(tx, on: col, key: "width", .any([.int(1)]))
                var blockAfter: YItem?
                try insertContainer(
                    tx, into: col, after: &blockAfter, id: blockID, node: "paragraph", children: children)
            }
        }
        let colHarness = try await makeHarness(state: colState)
        addTeardownBlock { await colHarness.close() }
        var colRequests: [NativeSourceRequest] = []
        let colModel = ColumnEditorModel(document: colHarness.session, groupID: "cl")
        addTeardownBlock { colModel.close() }
        let colHost = UIHostingController(
            rootView: ColumnEditorScreen(
                model: colModel, serverOrigin: "https://example.test",
                onOpenSource: { colRequests.append($0) }
            ).environment(LocalizationStore()))
        let colWindow = hostController(colHost)
        defer { colWindow.isHidden = true }
        for _ in 0..<300 where colModel.columns.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let leftSession = try XCTUnwrap(colModel.columns.first)
        let colChipOffset = try XCTUnwrap(
            inlineAttachments(in: leftSession.textView.textStorage).first { $0.1.content.kind == .math }?.0.location)
        let colFrame = try await ensureInlineChipFrame(in: leftSession.textView, utf16Offset: colChipOffset)
        let colPoint = CGPoint(x: colFrame.midX, y: colFrame.midY)
        XCTAssertTrue(leftSession.textView.chipTapShouldBegin(at: colPoint))
        XCTAssertTrue(leftSession.textView.handleChipTap(at: colPoint))
        XCTAssertEqual(colRequests, [.inlineMath(blockID: "cp1", utf16Offset: 4)])

        // 2. Tables: TableEditorViewController forwards onOpenSource to active cellSession.textView,
        //    and inactive TableCellView clamps long math chips to column width.
        let longMath = String(repeating: "x^2 + y^2 + ", count: 8)
        let tblState = try makeYDocState { tx, group in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            var rowCursor: YItem?
            for r in 0..<2 {
                let row = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                rowCursor = try YWrite.insertAfter(tx, into: table, after: rowCursor, [.type(row)])
                var cellCursor: YItem?
                for c in 0..<2 {
                    let cell = YType(typeRef: .xmlElement(nodeName: "tableCell"))
                    cellCursor = try YWrite.insertAfter(tx, into: row, after: cellCursor, [.type(cell)])
                    try YWrite.mapSet(tx, on: cell, key: "colspan", .any([.int(1)]))
                    try YWrite.mapSet(tx, on: cell, key: "rowspan", .any([.int(1)]))
                    try YWrite.mapSet(tx, on: cell, key: "colwidth", .any([.array([.int(120)])]))
                    let para = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
                    try YWrite.insertAfter(tx, into: cell, after: nil, [.type(para)])
                    if r == 0 && c == 0 {
                        let txt = YType(typeRef: .xmlText)
                        let tItem = try YWrite.insertAfter(tx, into: para, after: nil, [.type(txt)])
                        try txt.insert(0, "Eq ", nil)
                        let math = YType(typeRef: .xmlElement(nodeName: "math"))
                        try YWrite.insertAfter(tx, into: para, after: tItem, [.type(math)])
                        let mathTxt = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: math, after: nil, [.type(mathTxt)])
                        try mathTxt.insert(0, longMath, nil)
                    } else {
                        let txt = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: para, after: nil, [.type(txt)])
                        try txt.insert(0, "ok", nil)
                    }
                }
            }
        }
        let tblHarness = try await makeHarness(state: tblState)
        addTeardownBlock { await tblHarness.close() }
        var tblRequests: [NativeSourceRequest] = []
        let tableEditor = TableEditorViewController(document: tblHarness.session, tableID: "tbl")
        tableEditor.onOpenSource = { tblRequests.append($0) }
        let tblWindow = hostController(tableEditor)
        defer { tblWindow.isHidden = true }
        await tableEditor.load()
        for _ in 0..<300 where !tableEditor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        let cellSession = try XCTUnwrap(tableEditor.cellSession)
        addTeardownBlock { await cellSession.close().value }
        let cellMathOffset = try XCTUnwrap(
            inlineAttachments(in: cellSession.textView.textStorage).first { $0.1.content.kind == .math }?.0.location)
        let cellFrame = try await ensureInlineChipFrame(in: cellSession.textView, utf16Offset: cellMathOffset)
        let cellPoint = CGPoint(x: cellFrame.midX, y: cellFrame.midY)
        XCTAssertTrue(cellSession.textView.chipTapShouldBegin(at: cellPoint))
        XCTAssertTrue(cellSession.textView.handleChipTap(at: cellPoint))
        XCTAssertEqual(tblRequests.count, 1)
        if case .inlineMath(let blockID, let offset)? = tblRequests.first {
            XCTAssertTrue(TableGrid.isParagraphID(blockID))
            XCTAssertEqual(offset, 3)
        } else {
            XCTFail("expected inlineMath request")
        }

        // Switch active cell so (0, 0) renders as an inactive TableCellView clamped to 120pt column width.
        XCTAssertTrue(tableEditor.activate(TableGrid.CellRef(row: 1, index: 1)))
        tableEditor.view.layoutIfNeeded()
        let cellView = try XCTUnwrap(tableEditor.cellViews[TableGrid.CellRef(row: 0, index: 0)])
        let cellChips = inlineAttachments(in: try XCTUnwrap(cellView.label.attributedText))
        XCTAssertEqual(cellChips.count, 1)
        let maxContentWidth = 120 - TableEditorViewController.padding * 2
        XCTAssertLessThanOrEqual(cellChips[0].1.content.size.width, maxContentWidth + 0.5)
    }
}
