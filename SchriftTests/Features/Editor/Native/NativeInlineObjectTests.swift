import SwiftUI
import UIKit
import XCTest

@testable import Schrift

/// PR13c1 Step 4: inline chip attachment rendering, TextKit 2 line-height
/// parity, Dynamic Type & width clamping without Yjs writes, light/dark/theme
/// image cache, cached document title display, VoiceOver `accessibilityValue`,
/// `NativeBlockPreview` summaries without `\u{FFFC}`, and Outline/Find title
/// resolution.
@MainActor
final class NativeInlineObjectTests: NativeEditingTestCase {
    private var windows: [UIWindow] = []
    private var directories: [URL] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for window in windows {
            window.endEditing(true)
            window.isHidden = true
        }
        windows = []
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func host(_ view: UIView, width: CGFloat = 390, height: CGFloat = 844) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        windows.append(window)
        return window
    }

    @discardableResult
    private func hostController(_ controller: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
            previous?.makeKey()
        }
        windows.append(window)
        return window
    }

    private func fixtureUpdate(_ name: String) throws -> Data {
        let base64 = try XCTUnwrap(BlockNoteInlineCaptures.fixtures.first { $0.name == name }?.update, name)
        return try XCTUnwrap(Data(base64Encoded: base64), name)
    }

    private func decodeDoc(_ data: Data) throws -> YDoc {
        let doc = YDoc(clientID: 1, gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(data))
        return doc
    }

    private enum YChild {
        case text(String)
        case inline(NativeInlineObject)
    }

    private func makeYDocState(
        clientID: UInt = 1, _ build: (YTransaction, YType) throws -> Void
    ) throws -> Data {
        let doc = YDoc(clientID: clientID, gc: true)
        defer { doc.destroy() }
        try doc.transact { tx in
            let root = doc.get(BlockNoteYjs.fragmentField)
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            try build(tx, group)
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private func insertContainer(
        _ tx: YTransaction, into group: YType, after: inout YItem?, id: String, node: String,
        props: [(String, YAnyValue)] = [],
        children: [YChild]
    ) throws {
        let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
        let element = YType(typeRef: .xmlElement(nodeName: node))
        after = try YWrite.insertAfter(tx, into: group, after: after, [.type(container)])
        try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
        try YWrite.insertAfter(tx, into: container, after: nil, [.type(element)])
        for (key, value) in props { try YWrite.mapSet(tx, on: element, key: key, .any([value])) }
        var childCursor: YItem?
        for child in children {
            switch child {
            case .text(let s):
                let xmlText = YType(typeRef: .xmlText)
                childCursor = try YWrite.insertAfter(tx, into: element, after: childCursor, [.type(xmlText)])
                if !s.isEmpty {
                    try YWrite.insertAfter(tx, into: xmlText, after: nil, [.string(Array(s.utf16))])
                }
            case .inline(let object):
                let el = YType(typeRef: .xmlElement(nodeName: object.nodeName))
                childCursor = try YWrite.insertAfter(tx, into: element, after: childCursor, [.type(el)])
                switch object {
                case .interlink(let docID, let blockID, let title, let disabled, let trigger):
                    try YWrite.mapSet(tx, on: el, key: "docId", .any([.string(docID)]))
                    if let blockID { try YWrite.mapSet(tx, on: el, key: "blockId", .any([.string(blockID)])) }
                    if let title { try YWrite.mapSet(tx, on: el, key: "title", .any([.string(title)])) }
                    try YWrite.mapSet(tx, on: el, key: "disabled", .any([.bool(disabled)]))
                    if let trigger { try YWrite.mapSet(tx, on: el, key: "trigger", .any([.string(trigger)])) }
                case .mention(let userID, let fullName):
                    try YWrite.mapSet(tx, on: el, key: "userId", .any([.string(userID)]))
                    try YWrite.mapSet(tx, on: el, key: "fullName", .any([.string(fullName)]))
                case .mentionSearch(let disabled, let trigger):
                    try YWrite.mapSet(tx, on: el, key: "disabled", .any([.bool(disabled)]))
                    if let trigger { try YWrite.mapSet(tx, on: el, key: "trigger", .any([.string(trigger)])) }
                }
            }
        }
    }

    private func inlineAttachments(in storage: NSAttributedString) -> [(NSRange, NativeInlineChipAttachment)] {
        var result: [(NSRange, NativeInlineChipAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let chip = value as? NativeInlineChipAttachment {
                result.append((range, chip))
            }
        }
        return result
    }

    private func makeViewModel(
        documentID: UUID = UUID(), title: String = "Current Page",
        userID: UUID? = nil
    ) -> (
        viewModel: EditorViewModel, signedInUser: SignedInUserStore,
        listCache: DocumentCacheStore, childrenCache: DocumentChildrenCacheStore
    ) {
        let suite = "NativeInlineObjectTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeInlineObjectTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)

        let signedInUser = SignedInUserStore(userDefaults: defaults)
        if let userID { signedInUser.remember(userID) }
        let listCache = DocumentCacheStore(userDefaults: defaults)
        let childrenCache = DocumentChildrenCacheStore(userDefaults: defaults)
        let contentCache = DocumentContentCacheStore(directory: dir)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client,
            draftStore: PendingDraftStore(userDefaults: defaults),
            contentCache: contentCache,
            createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(userDefaults: defaults, directory: dir),
            listCache: listCache,
            childrenCache: childrenCache,
            serverOrigin: "https://docs.example",
            backgroundTasks: .noop)
        let viewModel = EditorViewModel(
            client: client,
            documentID: documentID,
            title: title,
            saveCoordinator: coordinator,
            serverOrigin: "https://docs.example",
            signedInUser: signedInUser,
            contentCache: contentCache,
            childrenCache: childrenCache,
            listCache: listCache,
            availability: OnlineAvailability(userDefaults: defaults))
        return (viewModel, signedInUser, listCache, childrenCache)
    }

    private func makeDocument(id: UUID = UUID(), title: String?) -> Schrift.Document {
        Schrift.Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    // MARK: - Projection & TextKit 2 Line-Height Parity

    func testProjectionValueEqualityAndLineHeightParity() async throws {
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "plain", node: "paragraph",
                children: [
                    .text("Plain reference line")
                ])
            try insertContainer(
                tx, into: group, after: &after, id: "chips", node: "paragraph",
                children: [
                    .text("See "),
                    .inline(
                        .interlink(docID: targetID.uuidString, blockID: nil, title: nil, disabled: false, trigger: "/")),
                    .text(" "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" "),
                    .inline(.mentionSearch(disabled: true, trigger: "/")),
                    .text(" end"),
                ])
            try insertContainer(
                tx, into: group, after: &after, id: "after", node: "paragraph",
                children: [
                    .text("Trailing line")
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.documentTitle = { id in id == targetID ? "Roadmap" : nil }
        host(harness.view, width: 600)

        let chipsBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "chips" })
        XCTAssertTrue(chipsBlock.hasInlineObjects)
        XCTAssertEqual(
            AttributedDocumentProjection.displayText(for: chipsBlock),
            "See \u{FFFC} \u{FFFC} \u{FFFC} end")

        let traits = harness.session.surface.traits
        let labels = harness.session.surface.labels
        let geometry = harness.session.surface.attachmentGeometry
        let first = AttributedDocumentProjection.attributedString(
            blocks: harness.session.surface.blocks, traits: traits, labels: labels, geometry: geometry)
        let second = AttributedDocumentProjection.attributedString(
            blocks: harness.session.surface.blocks, traits: traits, labels: labels, geometry: geometry)
        XCTAssertTrue(first.isEqual(to: second), "value-equal attachments keep NSAttributedString.isEqual")
        XCTAssertTrue(harness.view.textStorage.isEqual(to: first))

        let plainEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "plain"))
        let chips = inlineAttachments(in: harness.view.textStorage)
        XCTAssertEqual(chips.count, 3)
        let bodyFont = try XCTUnwrap(
            harness.view.textStorage.attribute(.font, at: plainEntry.range.location, effectiveRange: nil) as? UIFont)
        let band = DocumentLinkChipIconBand(font: bodyFont)
        for (range, chip) in chips {
            XCTAssertEqual(range.length, 1)
            XCTAssertFalse(chip.allowsTextAttachmentView)
            XCTAssertEqual(chip.bounds.origin.y, band.baselineOffset, accuracy: 0.01)
            XCTAssertEqual(chip.bounds.height, band.height, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(chip.bounds.minY, bodyFont.descender - 0.01)
            XCTAssertLessThanOrEqual(chip.bounds.maxY, bodyFont.ascender + 0.01)
            XCTAssertEqual(chip.content.band, band)
            XCTAssertEqual(
                harness.view.textStorage.attribute(.nativeInlineObject, at: range.location, effectiveRange: nil)
                    as? NativeInlineObject,
                chip.content.object)
        }

        // Compare TextKit 2 laid-out line fragment height between plain and chip-bearing single-line paragraphs.
        let layout = try XCTUnwrap(harness.view.textLayoutManager)
        let chipsEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "chips"))
        let plainLoc = try XCTUnwrap(
            layout.location(layout.documentRange.location, offsetBy: plainEntry.range.location))
        let chipsLoc = try XCTUnwrap(
            layout.location(layout.documentRange.location, offsetBy: chipsEntry.range.location))
        layout.ensureLayout(for: try XCTUnwrap(NSTextRange(location: plainLoc)))
        layout.ensureLayout(for: try XCTUnwrap(NSTextRange(location: chipsLoc)))
        let plainFrag = try XCTUnwrap(layout.textLayoutFragment(for: plainLoc))
        let chipsFrag = try XCTUnwrap(layout.textLayoutFragment(for: chipsLoc))
        XCTAssertEqual(plainFrag.textLineFragments.count, 1)
        XCTAssertEqual(chipsFrag.textLineFragments.count, 1)
        XCTAssertEqual(
            chipsFrag.textLineFragments[0].typographicBounds.height,
            plainFrag.textLineFragments[0].typographicBounds.height,
            accuracy: 0.5,
            "inline chip stays strictly inside DocumentLinkChipIconBand without inflating line height")
    }

    // MARK: - Dynamic Type & Width Clamping Without Yjs Writes

    func testDynamicTypeAndWidthClampingDoNotWriteYjs() async throws {
        let longTitle = String(repeating: "Quarterly Planning ", count: 6)
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p", node: "paragraph",
                children: [
                    .inline(
                        .interlink(
                            docID: targetID.uuidString, blockID: nil, title: longTitle, disabled: false, trigger: "/"))
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let beforeVector = await harness.session.replicaDoc { YStateEncoder.encodeStateVector($0) }

        harness.session.surface.updateAttachmentWidth(180)
        let clamped = try XCTUnwrap(inlineAttachments(in: harness.view.textStorage).first?.1)
        XCTAssertLessThanOrEqual(clamped.content.size.width, 180)
        XCTAssertLessThanOrEqual(clamped.bounds.width, 180)

        let smallHeight = clamped.content.size.height
        let smallFontSize = clamped.content.fontSize

        let axxxTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)
        harness.session.surface.updatePresentation(traits: axxxTraits, labels: harness.session.surface.labels)
        let scaled = try XCTUnwrap(inlineAttachments(in: harness.view.textStorage).first?.1)
        XCTAssertGreaterThan(scaled.content.fontSize, smallFontSize)
        XCTAssertGreaterThan(scaled.content.size.height, smallHeight)
        XCTAssertLessThanOrEqual(scaled.content.size.width, 180)

        let fresh = AttributedDocumentProjection.attributedString(
            blocks: harness.session.surface.blocks, traits: harness.session.surface.traits,
            labels: harness.session.surface.labels, geometry: harness.session.surface.attachmentGeometry)
        XCTAssertTrue(harness.view.textStorage.isEqual(to: fresh))

        let afterVector = await harness.session.replicaDoc { YStateEncoder.encodeStateVector($0) }
        XCTAssertEqual(beforeVector, afterVector)
        XCTAssertTrue(harness.log.commands.isEmpty)
        try await assertConsistent(harness, localCommands: 0)
    }

    // MARK: - Image Cache (Light / Dark / Themes)

    func testChipImageCacheLightDarkAndThemes() throws {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let geometry = NativeAttachmentGeometry(width: 320)
        let labels = NativeEditorLabels()
        let objects: [NativeInlineObject] = [
            .interlink(
                docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: "Plan", disabled: false,
                trigger: "/"),
            .interlink(
                docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: "Broken", disabled: true,
                trigger: "/"),
            .mention(userID: "u1", fullName: "Ada Lovelace"),
            .mentionSearch(disabled: true, trigger: "/"),
        ]

        for object in objects {
            let content = NativeInlineChipAttachment.content(
                for: object, font: font, labels: labels, geometry: geometry)
            let whiteLight = NativeInlineChipImageCache.image(
                content: content, font: font, theme: .white, isDark: false, scale: 2)
            let whiteDark = NativeInlineChipImageCache.image(
                content: content, font: font, theme: .white, isDark: true, scale: 2)
            let paperLight = NativeInlineChipImageCache.image(
                content: content, font: font, theme: .paper, isDark: false, scale: 2)
            let mistLight = NativeInlineChipImageCache.image(
                content: content, font: font, theme: .mist, isDark: false, scale: 2)

            XCTAssertEqual(whiteLight.size.width, content.size.width, accuracy: 0.5)
            XCTAssertEqual(whiteLight.size.height, content.size.height, accuracy: 0.5)
            XCTAssertEqual(whiteLight.scale, 2)
            XCTAssertEqual(mistLight.scale, 2)
            XCTAssertNotEqual(whiteLight.pngData(), whiteDark.pngData(), "\(object) light vs dark")
            XCTAssertNotEqual(whiteLight.pngData(), paperLight.pngData(), "\(object) white vs paper")
        }

        // Verify attachment.image(for:attributes:location:textContainer:) reads theme from NativeBlockControls.
        let content = NativeInlineChipAttachment.content(
            for: objects[0], font: font, labels: labels, geometry: geometry)
        let lightTraits = UITraitCollection(mutations: {
            $0.userInterfaceStyle = .light
            $0.displayScale = 2
        })
        let attachment = NativeInlineChipAttachment(content: content, font: font, traits: lightTraits)
        let textView = NativeTextView()
        textView.blockControls.theme = .paper
        let layout = try XCTUnwrap(textView.textLayoutManager)
        let drawn = attachment.image(
            for: attachment.bounds, attributes: [:], location: layout.documentRange.location,
            textContainer: textView.textContainer)
        let expectedPaper = NativeInlineChipImageCache.image(
            content: content, font: font, theme: .paper, isDark: textView.traitCollection.userInterfaceStyle == .dark,
            scale: NativeInlineChipImageCache.resolvedScale(for: textView.blockControls.traits))
        XCTAssertEqual(drawn?.pngData(), expectedPaper.pngData())
    }

    // MARK: - Cached Document Title Resolution

    func testCachedDocumentTitleUpdatesDisplayWithoutYjsMutation() async throws {
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let harness = try await makeHarness(state: try fixtureUpdate("interlinkBasic"))
        addTeardownBlock { await harness.close() }
        let beforeXML = await harness.session.replicaDoc { YXMLString.fragment($0) }

        let beforeChip = try XCTUnwrap(inlineAttachments(in: harness.view.textStorage).first?.1)
        XCTAssertEqual(beforeChip.content.displayLabel, targetID.uuidString)

        harness.view.blockControls.documentTitle = { id in id == targetID ? "Architecture Notes" : nil }
        XCTAssertEqual(harness.session.surface.attachmentGeometry.documentTitles[targetID], "Architecture Notes")

        let afterChip = try XCTUnwrap(inlineAttachments(in: harness.view.textStorage).first?.1)
        XCTAssertEqual(afterChip.content.displayLabel, "Architecture Notes")
        XCTAssertEqual(afterChip.content.accessibilityLabel, "Page: Architecture Notes")

        let fresh = AttributedDocumentProjection.attributedString(
            blocks: harness.session.surface.blocks, traits: harness.session.surface.traits,
            labels: harness.session.surface.labels, geometry: harness.session.surface.attachmentGeometry)
        XCTAssertTrue(harness.view.textStorage.isEqual(to: fresh))

        let afterXML = await harness.session.replicaDoc { YXMLString.fragment($0) }
        XCTAssertEqual(beforeXML, afterXML)
        XCTAssertTrue(harness.log.commands.isEmpty)
    }

    func testEditorViewModelCachedDocumentTitleScope() throws {
        let docID = UUID()
        let subpageID = UUID()
        let homeID = UUID()
        let childOfDocID = UUID()
        let childOfSubpageID = UUID()
        let childOfHomeID = UUID()
        let unrelatedParentID = UUID()
        let unrelatedChildID = UUID()
        let signedInID = UUID()
        let otherUserID = UUID()

        let (vm, signedInUser, listCache, childrenCache) = makeViewModel(
            documentID: docID, title: "Root Doc", userID: signedInID)
        vm.subpages = [makeDocument(id: subpageID, title: "Subpage Title")]
        listCache.saveRecentDocuments([makeDocument(id: homeID, title: "Home Recent")], fetchedFor: signedInID)
        childrenCache.save([makeDocument(id: childOfDocID, title: "Child of Doc")], for: docID)
        childrenCache.save([makeDocument(id: childOfSubpageID, title: "Child of Subpage")], for: subpageID)
        childrenCache.save([makeDocument(id: childOfHomeID, title: "Child of Home")], for: homeID)
        childrenCache.save([makeDocument(id: unrelatedChildID, title: "Out of Scope")], for: unrelatedParentID)

        XCTAssertEqual(vm.cachedDocumentTitle(for: docID), "Root Doc")
        XCTAssertEqual(vm.cachedDocumentTitle(for: subpageID), "Subpage Title")
        XCTAssertEqual(vm.cachedDocumentTitle(for: homeID), "Home Recent")
        XCTAssertEqual(vm.cachedDocumentTitle(for: childOfDocID), "Child of Doc")
        XCTAssertEqual(vm.cachedDocumentTitle(for: childOfSubpageID), "Child of Subpage")
        XCTAssertEqual(vm.cachedDocumentTitle(for: childOfHomeID), "Child of Home")
        XCTAssertNil(vm.cachedDocumentTitle(for: unrelatedChildID), "unrelated parent stays out of scope")

        // Signing out or switching account must not leak previous account's home list or its children.
        signedInUser.clear()
        XCTAssertNil(vm.cachedDocumentTitle(for: homeID))
        XCTAssertNil(vm.cachedDocumentTitle(for: childOfHomeID))
        XCTAssertEqual(vm.cachedDocumentTitle(for: subpageID), "Subpage Title")

        signedInUser.remember(otherUserID)
        XCTAssertNil(vm.cachedDocumentTitle(for: homeID))
        XCTAssertNil(vm.cachedDocumentTitle(for: childOfHomeID))
    }

    // MARK: - Accessibility Value (Adjacent Identical Chips & Table Describe)

    func testAccessibilityValueExpandsAdjacentIdenticalChipsAndOmitsFFFC() async throws {
        let resolvedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p", node: "paragraph",
                children: [
                    .text("Hi "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" "),
                    .inline(
                        .interlink(
                            docID: resolvedID.uuidString, blockID: nil, title: nil, disabled: false, trigger: "/")),
                    .text(" "),
                    .inline(.interlink(docID: "", blockID: nil, title: nil, disabled: true, trigger: "/")),
                    .text(" "),
                    .inline(.mentionSearch(disabled: true, trigger: "/")),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.documentTitle = { id in id == resolvedID ? "Project Plan" : nil }

        let value = try XCTUnwrap(harness.view.accessibilityValue)
        XCTAssertFalse(value.contains("\u{FFFC}"))
        XCTAssertEqual(
            value,
            "Hi Mention: @AdaMention: @Ada Page: Project Plan Untitled page Mention: /\n")
    }

    func testTableEditorDescribeUsesVisibleTextAndCachedTitle() async throws {
        let id1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let harness = try await makeHarness(state: try fixtureUpdate("chipsInTable"))
        addTeardownBlock { await harness.close() }

        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        editor.documentTitle = { id in
            if id == id1 { return "Alpha Doc" }
            if id == id2 { return "Beta Doc" }
            return nil
        }
        hostController(editor)
        editor.loadViewIfNeeded()
        await editor.load()
        for _ in 0..<300 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }

        // Move active cell away from (0, 0) so every target cell is described as a TableCellElement.
        XCTAssertTrue(editor.activate(TableGrid.CellRef(row: 2, index: 0)))

        let headerInterlink = try XCTUnwrap(
            editor.gridView.element(TableGrid.CellRef(row: 0, index: 0)) as? TableCellElement)
        editor.describe(headerInterlink)
        XCTAssertEqual(headerInterlink.accessibilityValue, "Col Alpha Doc")
        XCTAssertFalse((headerInterlink.accessibilityValue ?? "").contains("\u{FFFC}"))

        let headerMention = try XCTUnwrap(
            editor.gridView.element(TableGrid.CellRef(row: 0, index: 1)) as? TableCellElement)
        editor.describe(headerMention)
        XCTAssertEqual(headerMention.accessibilityValue, "@Ada")

        let bodyInterlink = try XCTUnwrap(
            editor.gridView.element(TableGrid.CellRef(row: 1, index: 0)) as? TableCellElement)
        editor.describe(bodyInterlink)
        XCTAssertEqual(bodyInterlink.accessibilityValue, "line1\nBeta Doc")

        let zombieCell = try XCTUnwrap(
            editor.gridView.element(TableGrid.CellRef(row: 1, index: 1)) as? TableCellElement)
        editor.describe(zombieCell)
        XCTAssertEqual(zombieCell.accessibilityValue, "x @ y")

        let mixedCell = try XCTUnwrap(
            editor.gridView.element(TableGrid.CellRef(row: 2, index: 1)) as? TableCellElement)
        editor.describe(mixedCell)
        XCTAssertEqual(mixedCell.accessibilityValue, "bold @AdaAlpha Doc")
        XCTAssertFalse((mixedCell.accessibilityValue ?? "").contains("\u{FFFC}"))
    }

    // MARK: - NativeBlockPreview Summaries

    func testNativeBlockPreviewSummariesExpandInlineObjectsAndStripFFFC() throws {
        // Columns fixture
        let columnsDoc = try decodeDoc(try fixtureUpdate("chipsInColumns"))
        defer { columnsDoc.destroy() }
        let columnsProj = NativeBlockProjection.project(columnsDoc)
        let colBlock = try XCTUnwrap(columnsProj.blocks.first { $0.block.node == "columnList" })
        guard case .columns(let colLines, _) = colBlock.preview else {
            return XCTFail("expected columns preview")
        }
        XCTAssertEqual(colLines[0][0].text, "Left 11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(colLines[1][0].text, "Right @Ada @")
        XCTAssertFalse(colLines.flatMap { $0 }.contains { $0.text.contains("\u{FFFC}") })

        // Table fixture
        let tableDoc = try decodeDoc(try fixtureUpdate("chipsInTable"))
        defer { tableDoc.destroy() }
        let tableProj = NativeBlockProjection.project(tableDoc)
        let tableBlock = try XCTUnwrap(tableProj.blocks.first { $0.block.node == "table" })
        guard case .table(let cells, _, _) = tableBlock.preview else {
            return XCTFail("expected table preview")
        }
        XCTAssertEqual(cells[0], ["Col 11111111-1111-4111-8111-111111111111", "@Ada"])
        XCTAssertEqual(cells[1][1], "x @ y")
        XCTAssertEqual(cells[2][1], "bold @Ada11111111-1111-4111-8111-111111111111")
        XCTAssertFalse(cells.flatMap { $0 }.contains { $0.contains("\u{FFFC}") })

        // Preserved unknown block containing inline objects and literal U+FFFC
        let customState = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "custom", node: "customWidget",
                children: [
                    .text("Check\u{FFFC} "),
                    .inline(.mention(userID: "u1", fullName: "Grace")),
                    .text(" on "),
                    .inline(.interlink(docID: "doc-1", blockID: nil, title: "Spec", disabled: false, trigger: "/")),
                ])
        }
        let customDoc = try decodeDoc(customState)
        defer { customDoc.destroy() }
        let customProj = NativeBlockProjection.project(customDoc)
        let customBlock = try XCTUnwrap(customProj.blocks.first)
        guard case .preserved(_, let summary) = customBlock.preview else {
            return XCTFail("expected preserved preview")
        }
        XCTAssertEqual(summary, "Check @Grace on Spec")
        XCTAssertFalse(summary.contains("\u{FFFC}"))
    }

    // MARK: - Outline & Find Resolution

    func testOutlineAndFindResolveInlineObjectsWithEditorViewModelCachedTitle() async throws {
        let targetID = UUID()
        let subpageID = UUID()
        let (viewModel, _, listCache, _) = makeViewModel(title: "Main Doc", userID: UUID())
        let userID = try XCTUnwrap(viewModel.signedInUser.userID)
        viewModel.subpages = [makeDocument(id: subpageID, title: "Architecture")]
        listCache.saveRecentDocuments([makeDocument(id: targetID, title: "Q4 Plan")], fetchedFor: userID)

        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "h1", node: "heading",
                props: [("level", .int(1)), ("isToggleable", .bool(false))],
                children: [
                    .text("Review "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" and "),
                    .inline(
                        .interlink(docID: targetID.uuidString, blockID: nil, title: nil, disabled: false, trigger: "/")),
                ])
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("See "),
                    .inline(.mention(userID: "u2", fullName: "Grace")),
                    .text(" on "),
                    .inline(
                        .interlink(docID: subpageID.uuidString, blockID: nil, title: nil, disabled: false, trigger: "/")
                    ),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let navigation = harness.session.navigation
        navigation.documentTitle = { [viewModel] id in viewModel.cachedDocumentTitle(for: id) }
        await navigation.refresh()

        let planMatches = findMatchingBlockIDs(in: navigation.blocks, query: "Q4 Plan")
        let archMatches = findMatchingBlockIDs(in: navigation.blocks, query: "Architecture")
        let graceMatches = findMatchingBlockIDs(in: navigation.blocks, query: "@Grace")

        let h1NavID = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "h1" }?.key)
        let p1NavID = try XCTUnwrap(navigation.entries.first { $0.value.blockID == "p1" }?.key)
        XCTAssertEqual(planMatches, [h1NavID])
        XCTAssertEqual(archMatches, [p1NavID])
        XCTAssertEqual(graceMatches, [p1NavID])

        let outline = buildOutline(blocks: navigation.blocks, matchingBlockIDs: planMatches)
        XCTAssertEqual(outline.map(\.title), ["Review @Ada and Q4 Plan"])
        XCTAssertEqual(outline.map(\.matchCount), [1])
        XCTAssertFalse(outline.contains { $0.title.contains("\u{FFFC}") })
    }

    // MARK: - Step 5: Surface Input, Marks, IME, Clipboard, and Paste-Interlink

    func testTypingAroundChipsUsesBarrierAndMarkInheritanceFollowsBoundaryRules() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("pre"),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .inline(.mention(userID: "u2", fullName: "Grace")),
                    .text("post"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // Bold "pre" so the run immediately before chip 1 carries a bold mark.
        var ok = await harness.session.run { harness.input.replace(range: NSRange(location: 0, length: 3), with: "") }
        XCTAssertTrue(ok)
        _ = harness.input.toggleMark("bold")
        ok = await harness.session.run { harness.input.replace(range: NSRange(location: 0, length: 0), with: "pre") }
        XCTAssertTrue(ok)

        // Rapid keystrokes immediately before chip 1 stay off the predicted path
        // (barrier + queued intents), never rolling back, and inherit bold.
        let pEntry1 = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        harness.view.selectedRange = NSRange(location: pEntry1.textRange.location + 3, length: 0)
        harness.input.textViewDidChangeSelection(harness.view)
        XCTAssertTrue(harness.input.activeMarks.contains { $0.key == "bold" })

        harness.input.typeKey("!")
        XCTAssertTrue(harness.session.surface.predictions.isEmpty, "chips block skips optimistic prediction")
        harness.input.typeKey("?")
        await harness.settle()

        var block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(block.runs.map(\.text).joined(), "pre!?\u{FFFC}\u{FFFC}post")
        XCTAssertEqual(block.runs.first?.text, "pre!?")
        XCTAssertEqual(block.runs.first?.marks.map(\.key), ["bold"])

        // Immediately after chip 1 (between chip 1 and chip 2): activeMarks is [],
        // typing inherits [] (no mark leakage across chip 1).
        let betweenOffset = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1")).textRange.location + 6
        harness.view.selectedRange = NSRange(location: betweenOffset, length: 0)
        harness.input.textViewDidChangeSelection(harness.view)
        XCTAssertEqual(harness.input.activeMarks, [])

        ok = await harness.session.run {
            harness.input.replace(range: NSRange(location: betweenOffset, length: 0), with: "M")
        }
        XCTAssertTrue(ok)
        block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(block.runs.map(\.text).joined(), "pre!?\u{FFFC}M\u{FFFC}post")
        let betweenRun = try XCTUnwrap(block.runs.first { $0.text == "M" })
        XCTAssertTrue(betweenRun.marks.isEmpty)

        // Immediately after chip 2: activeMarks starts empty, and an explicit
        // toggle arms pendingTypingMarks for the next keystroke.
        let afterChip2 = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1")).textRange.location + 8
        harness.view.selectedRange = NSRange(location: afterChip2, length: 0)
        harness.input.textViewDidChangeSelection(harness.view)
        XCTAssertEqual(harness.input.activeMarks, [])
        XCTAssertTrue(harness.input.toggleMark("italic"))
        XCTAssertEqual(harness.input.activeMarks.map(\.key), ["italic"])

        ok = await harness.session.run {
            harness.input.replace(range: NSRange(location: afterChip2, length: 0), with: "Y")
        }
        XCTAssertTrue(ok)
        block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(block.runs.map(\.text).joined(), "pre!?\u{FFFC}M\u{FFFC}Ypost")
        let afterRun = try XCTUnwrap(block.runs.first { $0.text.contains("Y") })
        XCTAssertEqual(afterRun.text, "Y")
        XCTAssertEqual(afterRun.marks.map(\.key), ["italic"])
    }

    func testBackspaceAndForwardDeleteRemoveChipAsOneUnitAndCoalesceXmlText() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("A"),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text("B"),
                    .inline(.interlink(docID: "doc-1", blockID: nil, title: "Spec", disabled: false, trigger: "/")),
                    .text("C"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // Backspace right after the mention removes it as 1 UTF-16 unit.
        let base = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1")).textRange.location
        harness.view.selectedRange = NSRange(location: base + 2, length: 0)
        harness.view.deleteBackward()
        await harness.settle()

        var block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(block.runs.map(\.text).joined(), "AB\u{FFFC}C")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: base + 1, length: 0))

        // Forward delete (replacing chipOffset..<chipOffset+1 with "") removes the interlink as 1 unit
        // and coalesces "AB" + "C" into one XmlText sibling on the replica.
        let ok = await harness.session.run {
            harness.input.replace(range: NSRange(location: base + 2, length: 1), with: "")
        }
        XCTAssertTrue(ok)
        block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(block.runs.map(\.text).joined(), "ABC")
        XCTAssertFalse(block.hasInlineObjects)

        let childCount = await harness.session.replicaDoc { doc -> Int in
            guard
                let groupItem = YBlockProjection.children(
                    of: doc.get(BlockNoteYjs.fragmentField), includeFormats: false
                ).first,
                case .type(let group) = groupItem.content,
                let p1Item = YBlockProjection.children(of: group, includeFormats: false).first,
                case .type(let p1) = p1Item.content,
                let elItem = YBlockProjection.children(of: p1, includeFormats: false).first,
                case .type(let el) = elItem.content
            else { return -1 }
            return YBlockProjection.children(of: el, includeFormats: false).count
        }
        XCTAssertEqual(childCount, 1)
    }

    func testFormattingSelectionAcrossChipsAndLinkSheetGating() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("one"),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text("two"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let base = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1")).textRange.location
        // Bold both text sides individually ("one" and "two").
        harness.view.selectedRange = NSRange(location: base, length: 3)
        var ok = await harness.session.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(ok)
        harness.view.selectedRange = NSRange(location: base + 4, length: 3)
        ok = await harness.session.run { harness.input.toggleMark("bold") }
        XCTAssertTrue(ok)

        // Selecting across "one<chip>two": common marks skips chip, reports [bold],
        // and linkTarget() returns nil because selection includes an inline object.
        harness.view.selectedRange = NSRange(location: base, length: 7)
        harness.input.textViewDidChangeSelection(harness.view)
        XCTAssertEqual(harness.input.activeMarks.map(\.key), ["bold"])
        XCTAssertNil(harness.input.linkTarget())

        // Toggling italic across the chip formats text on both sides, never the chip.
        ok = await harness.session.run { harness.input.toggleMark("italic") }
        XCTAssertTrue(ok)
        let block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        let mentionRun = try XCTUnwrap(block.runs.first { $0.inlineObject != nil })
        XCTAssertTrue(mentionRun.marks.isEmpty)
        XCTAssertEqual(Set(block.runs.first { $0.text == "one" }?.marks.map(\.key) ?? []), ["bold", "italic"])
        XCTAssertEqual(Set(block.runs.first { $0.text == "two" }?.marks.map(\.key) ?? []), ["bold", "italic"])

        // Selecting solely the chip: activeMarks == [], toggles are no-ops, linkTarget() == nil.
        harness.view.selectedRange = NSRange(location: base + 3, length: 1)
        harness.input.textViewDidChangeSelection(harness.view)
        XCTAssertEqual(harness.input.activeMarks, [])
        let beforeCommands = harness.log.commands.count
        XCTAssertFalse(harness.input.toggleMark("underline"))
        XCTAssertFalse(harness.input.setColor(NativeMark.textColor, name: "red"))
        XCTAssertNil(harness.input.linkTarget())
        await harness.settle()
        XCTAssertEqual(harness.log.commands.count, beforeCommands, "chip-only mark toggles post no commands")

        // Collapsed caret right after the chip allows opening Link sheet for a new link.
        harness.view.selectedRange = NSRange(location: base + 4, length: 0)
        harness.input.textViewDidChangeSelection(harness.view)
        let linkTarget = try XCTUnwrap(harness.input.linkTarget())
        XCTAssertEqual(linkTarget.range, NSRange(location: base + 4, length: 0))
        XCTAssertNil(linkTarget.href)
    }

    func testIMECompositionAroundChipsCommitCancelAndPeerDeletionInvalidation() async throws {
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("ab"),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .inline(.mentionSearch(disabled: false, trigger: "@")),
                    .text("cd"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // 1. IME before chip 1: unpredicted commit reconciles and places caret cleanly.
        let base = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1")).textRange.location
        harness.view.selectedRange = NSRange(location: base + 2, length: 0)
        XCTAssertTrue(harness.input.beginComposition(markedText: "kan"))
        await harness.settle()
        XCTAssertTrue(harness.input.commitComposition(text: "漢"))
        XCTAssertTrue(harness.session.surface.predictions.isEmpty, "chips block does not predict IME commit")
        await harness.settle()

        var p1Text = harness.session.surface.blocks.first { $0.id == "p1" }?.runs.map(\.text).joined()
        XCTAssertEqual(p1Text, "ab漢\u{FFFC}\u{FFFC}cd")
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: base + 3, length: 0))

        // 2. IME between the two chips + held rapid key right after commit.
        let between = base + 4
        harness.view.selectedRange = NSRange(location: between, length: 0)
        XCTAssertTrue(harness.input.beginComposition(markedText: "zi"))
        await harness.settle()
        XCTAssertTrue(harness.input.commitComposition(text: "字"))
        XCTAssertTrue(harness.input.replace(range: NSRange(location: between, length: 0), with: "z"))
        await harness.settle()

        p1Text = harness.session.surface.blocks.first { $0.id == "p1" }?.runs.map(\.text).joined()
        XCTAssertEqual(p1Text, "ab漢\u{FFFC}字z\u{FFFC}cd")

        // 3. Cancel IME next to chip leaves content intact.
        harness.view.selectedRange = NSRange(location: base + 7, length: 0)
        XCTAssertTrue(harness.input.beginComposition(markedText: "tmp"))
        await harness.settle()
        XCTAssertTrue(harness.input.cancelComposition())
        await harness.settle()
        p1Text = harness.session.surface.blocks.first { $0.id == "p1" }?.runs.map(\.text).joined()
        XCTAssertEqual(p1Text, "ab漢\u{FFFC}字z\u{FFFC}cd")

        // 4. Peer deletes the block before commit: unpredicted commit recovers cleanly without crashing.
        harness.view.selectedRange = NSRange(location: base + 7, length: 0)
        XCTAssertTrue(harness.input.beginComposition(markedText: "lose"))
        await harness.settle()

        let currentUpdate: Data? = await harness.session.replicaDoc { doc in
            (try? YStateEncoder.encodeStateAsUpdate(doc)) ?? Data()
        }
        let docSnapshot = try XCTUnwrap(currentUpdate)
        let peer = try decodeDoc(docSnapshot)
        defer { peer.destroy() }
        let peerSVBytes = try YStateEncoder.encodeStateVector(peer)
        let peerSV = try YUpdateDecoder.decodeStateVector(peerSVBytes)
        let sinceMap = Dictionary(peerSV.map { ($0.client, $0.clock) }, uniquingKeysWith: max)
        try peer.transact { tx in
            if let groupItem = YBlockProjection.children(
                of: peer.get(BlockNoteYjs.fragmentField), includeFormats: false
            )
            .first,
                case .type(let group) = groupItem.content,
                let p1Item = YBlockProjection.children(of: group, includeFormats: false).first
            {
                p1Item.delete(tx)
            }
        }
        let deleteDelta = try YStateEncoder.encodeStateAsUpdate(peer, since: sinceMap)
        harness.session.replica?.mailbox.post(.integrate(deleteDelta, reply: nil))
        XCTAssertTrue(harness.input.commitComposition(text: "失"))
        await harness.settle()
        XCTAssertTrue(harness.input.composition.pendingRecoveries.contains { $0.text == "失" })
    }

    func testCopyCutPasteChipsPartialMultiLineWholeBlockTableAndCodeBlockDegradation() async throws {
        let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("Alpha "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" "),
                    .inline(
                        .interlink(
                            docID: docID.uuidString.lowercased(), blockID: "b1", title: "Spec", disabled: false,
                            trigger: "/")),
                    .text(" "),
                    .inline(.interlink(docID: "missing", blockID: nil, title: "Dead", disabled: true, trigger: "/")),
                    .text(" "),
                    .inline(.mentionSearch(disabled: false, trigger: "@")),
                    .text(" Omega"),
                ])
            try insertContainer(
                tx, into: group, after: &after, id: "p2", node: "paragraph",
                children: [.text("Second line")])
            try insertContainer(
                tx, into: group, after: &after, id: "target", node: "paragraph",
                children: [.text("XY")])
            try insertContainer(
                tx, into: group, after: &after, id: "code1", node: "codeBlock",
                props: [("language", .string("swift"))],
                children: [.text("let x = ")])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        // serverOrigin comes from ReplicaScope ("https://example.test").
        XCTAssertEqual(harness.input.serverOrigin, "https://example.test")

        let p1Entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        // 1. Copy partial slice spanning mention + space + enabled interlink: no U+FFFC in plain text.
        harness.view.selectedRange = NSRange(location: p1Entry.textRange.location + 6, length: 3)
        harness.input.copySelection()
        await harness.settle()
        XCTAssertEqual(
            harness.pasteboard.string,
            "@Ada https://example.test/docs/\(docID.uuidString.lowercased())/")
        XCTAssertFalse((harness.pasteboard.string ?? "").contains("\u{FFFC}"))
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteInlinePayload.pasteboardType))

        // Paste inline slice at collapsed caret inside "target" ("XY" -> "X<chip> <interlink>Y").
        let targetEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "target"))
        harness.view.selectedRange = NSRange(location: targetEntry.textRange.location + 1, length: 0)
        var ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        let targetBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "target" })
        XCTAssertEqual(targetBlock.runs.map(\.text).joined(), "X\u{FFFC} \u{FFFC}Y")
        XCTAssertEqual(
            targetBlock.runs.compactMap(\.inlineObject),
            [
                .mention(userID: "u1", fullName: "Ada"),
                .interlink(
                    docID: docID.uuidString.lowercased(), blockID: "b1", title: "Spec", disabled: false, trigger: "/"),
            ])

        // 2. Cut solely the zombie mentionSearchInline: plain text is nil, lossless payload kept, chip deleted.
        let refreshedP1 = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        // In p1: "Alpha "(6) + mention(1) + " "(1) + interlink(1) + " "(1) + disabled(1) + " "(1) + zombie(1) + " Omega"(6)
        harness.view.selectedRange = NSRange(location: refreshedP1.textRange.location + 12, length: 1)
        ok = await harness.session.run { harness.input.cutSelection() }
        XCTAssertTrue(ok)
        XCTAssertNil(harness.pasteboard.string)
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteInlinePayload.pasteboardType))
        let p1AfterCut = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(p1AfterCut.runs.filter { $0.inlineObject != nil }.count, 3)

        // 3. Copy multi-line selection spanning p1 (mention + disabled) through "Sec" of p2.
        let p1Now = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        let p2Now = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p2"))
        let multiStart = p1Now.textRange.location + 6
        let multiEnd = p2Now.textRange.location + 3
        harness.view.selectedRange = NSRange(location: multiStart, length: multiEnd - multiStart)
        harness.input.copySelection()
        await harness.settle()
        XCTAssertTrue((harness.pasteboard.string ?? "").contains("\nSec"))
        XCTAssertFalse((harness.pasteboard.string ?? "").contains("\u{FFFC}"))

        // Pasting multi-line inline payload into "target" splits into 2 prose blocks preserving chips.
        let targetNow = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "target"))
        harness.view.selectedRange = NSRange(location: targetNow.textRange.location, length: 0)
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertTrue(harness.session.surface.blocks.contains { $0.runs.map(\.text).joined().hasPrefix("SecX") })

        // Pasting multi-line inline payload into a codeBlock degrades chips to plain text (no elements in codeBlock).
        let codeEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "code1"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(codeEntry.textRange), length: 0)
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        let codeBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "code1" })
        XCTAssertFalse(codeBlock.hasInlineObjects)
        let codeText = codeBlock.runs.map(\.text).joined()
        XCTAssertTrue(codeText.contains("@Ada"))
        XCTAssertFalse(codeText.contains("\u{FFFC}"))

        // 4. Whole-block copy of p1 copies BlockNoteSubtreePayload and pastes losslessly as a fresh block.
        let p1Whole = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        harness.view.selectedRange = p1Whole.textRange
        harness.input.copySelection()
        await harness.settle()
        XCTAssertNotNil(harness.pasteboard.data(forPasteboardType: BlockNoteSubtreePayload.pasteboardType))
        let p2Latest = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p2"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(p2Latest.textRange), length: 0)
        let countBefore = harness.session.surface.blocks.count
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertEqual(harness.session.surface.blocks.count, countBefore + 1)

        // 5. Crafted subtree putting an inline element inside a codeBlock is rejected.
        let crafted = BlockNoteWriter.Copy.element(
            "blockContainer", [("id", .string("bad"))],
            [
                .element(
                    "codeBlock", [("language", .string("swift"))],
                    [.element("userMentionInline", [("userId", .string("u1")), ("fullName", .string("Ada"))], [])])
            ])
        XCTAssertThrowsError(try BlockNoteSubtreePayload.validate([crafted]))

        // 6. External paste containing U+FFFC strips it; U+FFFC-only external paste is ignored.
        harness.pasteboard.string = "\u{FFFC}"
        let p2Again = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p2"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(p2Again.textRange), length: 0)
        XCTAssertFalse(harness.input.pasteFromPasteboard())

        harness.pasteboard.string = "A\u{FFFC}B"
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertEqual(
            harness.session.surface.blocks.first { $0.id == "p2" }?.runs.map(\.text).joined(),
            "Second lineAB")

        // 7. Table cells inherit serverOrigin and copy/paste inline slices losslessly.
        let tableHarness = try await makeHarness(state: try fixtureUpdate("chipsInTable"))
        addTeardownBlock { await tableHarness.close() }
        let openedTable = await tableHarness.session.openTable("tbl")
        let tableSession = try XCTUnwrap(openedTable)
        addTeardownBlock { await tableSession.close().value }
        let tableInput = try XCTUnwrap(tableSession.input)
        XCTAssertEqual(tableInput.serverOrigin, "https://example.test")

        // Copy mention chip from cell (row 0, index 1) and paste into zombie cell (row 1, index 1).
        let mentionCellID = tableSession.surface.blocks[1].id
        tableSession.surface.setFocus([mentionCellID])
        let mentionCellEntry = try XCTUnwrap(tableSession.surface.rangeIndex.entry(for: mentionCellID))
        tableSession.textView.selectedRange = mentionCellEntry.textRange
        tableInput.copySelection()
        _ = await tableSession.settle()
        XCTAssertEqual(tableHarness.pasteboard.string, "@Ada")
        XCTAssertNotNil(tableHarness.pasteboard.data(forPasteboardType: BlockNoteInlinePayload.pasteboardType))

        let destCellID = tableSession.surface.blocks[3].id
        tableSession.surface.setFocus([destCellID])
        let destCellEntry = try XCTUnwrap(tableSession.surface.rangeIndex.entry(for: destCellID))
        tableSession.textView.selectedRange = NSRange(location: NSMaxRange(destCellEntry.textRange), length: 0)
        ok = await tableSession.run { tableInput.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertEqual(
            tableSession.surface.blocks[3].runs.compactMap(\.inlineObject).last,
            .mention(userID: "user-1", fullName: "Ada"))
    }

    func testPasteSameOriginDocURLCreatesInterlinkOrFallsBackToPlainText() async throws {
        let targetUUID = UUID(uuidString: "AABBCCDD-1111-4222-8333-444455556666")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(tx, into: group, after: &after, id: "p1", node: "paragraph", children: [.text("hi ")])
            try insertContainer(
                tx, into: group, after: &after, id: "p2", node: "paragraph", children: [.text("replace")])
            try insertContainer(
                tx, into: group, after: &after, id: "code1", node: "codeBlock",
                props: [("language", .string("swift"))],
                children: [.text("// ")])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        // Same-origin doc URL with trailing slash & block fragment at collapsed caret -> interlink chip.
        harness.pasteboard.string = "https://example.test/docs/\(targetUUID.uuidString)/#blk1"
        let p1Entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        let caretAt = NSMaxRange(p1Entry.textRange)
        harness.view.selectedRange = NSRange(location: caretAt, length: 0)
        var ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)

        let p1Block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertEqual(p1Block.runs.map(\.text).joined(), "hi \u{FFFC}")
        XCTAssertEqual(
            p1Block.runs.compactMap(\.inlineObject),
            [
                .interlink(
                    docID: targetUUID.uuidString.lowercased(), blockID: "blk1", title: nil, disabled: false,
                    trigger: "/")
            ])
        XCTAssertEqual(harness.view.selectedRange, NSRange(location: caretAt + 1, length: 0))

        // Over a non-empty selection -> pastes plain URL text.
        let p2Entry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p2"))
        harness.view.selectedRange = p2Entry.textRange
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        let p2Block = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p2" })
        XCTAssertFalse(p2Block.hasInlineObjects)
        XCTAssertEqual(
            p2Block.runs.map(\.text).joined(),
            "https://example.test/docs/\(targetUUID.uuidString)/#blk1")

        // Inside a codeBlock -> pastes plain URL text.
        let codeEntry = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "code1"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(codeEntry.textRange), length: 0)
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        let codeBlock = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "code1" })
        XCTAssertFalse(codeBlock.hasInlineObjects)

        // Foreign host or query parameter at collapsed caret -> plain text.
        harness.pasteboard.string = "https://other.test/docs/\(targetUUID.uuidString)"
        let p1Updated = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        harness.view.selectedRange = NSRange(location: NSMaxRange(p1Updated.textRange), length: 0)
        ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        let p1Final = try XCTUnwrap(harness.session.surface.blocks.first { $0.id == "p1" })
        XCTAssertTrue(p1Final.runs.map(\.text).joined().hasSuffix("https://other.test/docs/\(targetUUID.uuidString)"))

        // Same-origin doc URL pasted inside a table cell creates an interlink chip too.
        let tableHarness = try await makeHarness(state: try fixtureUpdate("chipsInTable"))
        addTeardownBlock { await tableHarness.close() }
        let openedTable = await tableHarness.session.openTable("tbl")
        let tableSession = try XCTUnwrap(openedTable)
        addTeardownBlock { await tableSession.close().value }
        let tableInput = try XCTUnwrap(tableSession.input)
        tableHarness.pasteboard.string = "https://example.test/docs/\(targetUUID.uuidString)"
        let firstCellID = tableSession.surface.blocks[0].id
        tableSession.surface.setFocus([firstCellID])
        let firstCell = try XCTUnwrap(tableSession.surface.rangeIndex.entry(for: firstCellID))
        tableSession.textView.selectedRange = NSRange(location: NSMaxRange(firstCell.textRange), length: 0)
        ok = await tableSession.run { tableInput.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertTrue(
            tableSession.surface.blocks[0].runs.compactMap(\.inlineObject).contains(
                .interlink(
                    docID: targetUUID.uuidString.lowercased(), blockID: "", title: nil, disabled: false, trigger: "/")))
    }

    private func ensureInlineChipFrame(in textView: NativeTextView, utf16Offset: Int) async throws -> CGRect {
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        if let manager = textView.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
        for _ in 0..<20 {
            if let frame = textView.inlineChipFrame(atUTF16: utf16Offset), !frame.isEmpty {
                return frame
            }
            textView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(textView.inlineChipFrame(atUTF16: utf16Offset))
    }

    private func inlineChipOffset(
        in storage: NSAttributedString,
        matching predicate: (NativeInlineObject) -> Bool
    ) throws -> Int {
        var matched: Int?
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.nativeInlineObject, in: full) { value, range, stop in
            guard let inline = value as? NativeInlineObject, predicate(inline) else { return }
            matched = range.location
            stop.pointee = true
        }
        return try XCTUnwrap(matched)
    }

    func testChipTapNavigationHitTestingAndSideOffsets() async throws {
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("Alpha "),
                    .inline(
                        .interlink(
                            docID: targetID.uuidString.lowercased(), blockID: "b42", title: "Spec", disabled: false,
                            trigger: "/")),
                    .text(" "),
                    .inline(
                        .interlink(
                            docID: targetID.uuidString.lowercased(), blockID: nil, title: "Off", disabled: true,
                            trigger: "/")),
                    .text(" "),
                    .inline(.interlink(docID: "", blockID: nil, title: "Empty", disabled: false, trigger: "/")),
                    .text(" "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                    .text(" "),
                    .inline(.mentionSearch(disabled: false, trigger: "@")),
                    .text(" Beta"),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        _ = host(harness.view)

        let xmlBefore = await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
        var opened: [(UUID, String)] = []
        harness.view.blockControls.onOpenDocument = { id, blockID in opened.append((id, blockID)) }

        let enabledOffset = try inlineChipOffset(in: harness.view.textStorage) {
            $0
                == .interlink(
                    docID: targetID.uuidString.lowercased(), blockID: "b42", title: "Spec", disabled: false,
                    trigger: "/")
        }
        let disabledOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .interlink(_, _, _, let disabled, _) = $0 { return disabled }
            return false
        }
        let emptyOffset = try inlineChipOffset(in: harness.view.textStorage) {
            $0 == .interlink(docID: "", blockID: nil, title: "Empty", disabled: false, trigger: "/")
        }
        let mentionOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .mention = $0 { return true }
            return false
        }
        let mentionSearchOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .mentionSearch = $0 { return true }
            return false
        }

        for editable in [false, true] {
            harness.view.isEditable = editable
            let chipFrame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: enabledOffset)
            let center = CGPoint(x: chipFrame.midX, y: chipFrame.midY)

            XCTAssertTrue(harness.view.chipTapShouldBegin(at: center), "editable=\(editable)")
            XCTAssertTrue(harness.view.handleChipTap(at: center), "editable=\(editable)")
            XCTAssertEqual(opened.last?.0, targetID)
            XCTAssertEqual(opened.last?.1, "b42")

            // Tapping outside left/right chip bounds never navigates and preserves side caret placement.
            let leftPoint = CGPoint(x: chipFrame.minX - 2, y: chipFrame.midY)
            let rightPoint = CGPoint(x: chipFrame.maxX + 2, y: chipFrame.midY)
            XCTAssertFalse(harness.view.chipTapShouldBegin(at: leftPoint))
            XCTAssertFalse(harness.view.handleChipTap(at: leftPoint))
            XCTAssertFalse(harness.view.chipTapShouldBegin(at: rightPoint))
            XCTAssertFalse(harness.view.handleChipTap(at: rightPoint))
            let leftPos = try XCTUnwrap(harness.view.closestPosition(to: leftPoint))
            let rightPos = try XCTUnwrap(harness.view.closestPosition(to: rightPoint))
            XCTAssertEqual(harness.view.offset(from: harness.view.beginningOfDocument, to: leftPos), enabledOffset)
            XCTAssertEqual(harness.view.offset(from: harness.view.beginningOfDocument, to: rightPos), enabledOffset + 1)

            // Mentions, mentionSearch, disabled interlinks, and empty interlinks never navigate on tap.
            for nonNavOffset in [disabledOffset, emptyOffset, mentionOffset, mentionSearchOffset] {
                let frame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: nonNavOffset)
                let pt = CGPoint(x: frame.midX, y: frame.midY)
                XCTAssertFalse(harness.view.chipTapShouldBegin(at: pt))
                XCTAssertFalse(harness.view.handleChipTap(at: pt))
            }
        }

        // Simultaneous recognition allows internal non-pan/long-press recognizers on textView,
        // while refusing pans, long presses, and superview recognizers.
        let externalTap = UITapGestureRecognizer()
        let internalTap = UITapGestureRecognizer()
        harness.view.addGestureRecognizer(internalTap)
        XCTAssertFalse(
            harness.view.blockControls.gestureRecognizer(
                harness.view.chipTapRecognizer, shouldRecognizeSimultaneouslyWith: externalTap))
        XCTAssertFalse(
            harness.view.blockControls.gestureRecognizer(
                harness.view.chipTapRecognizer, shouldRecognizeSimultaneouslyWith: harness.view.panGestureRecognizer))
        XCTAssertTrue(
            harness.view.blockControls.gestureRecognizer(
                harness.view.chipTapRecognizer, shouldRecognizeSimultaneouslyWith: internalTap))

        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(harness.log.commands, [])
        let xmlAfter = await harness.session.replicaDoc { YXMLString.fragment($0) } ?? ""
        XCTAssertEqual(xmlAfter, xmlBefore)

        // IME composition suppresses chip tap initiation.
        let enabledFrame = try await ensureInlineChipFrame(in: harness.view, utf16Offset: enabledOffset)
        harness.view.selectedRange = NSRange(location: 0, length: 0)
        harness.view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertFalse(harness.view.chipTapShouldBegin(at: CGPoint(x: enabledFrame.midX, y: enabledFrame.midY)))
        harness.view.unmarkText()
        XCTAssertEqual(opened.count, 2)
    }

    func testVoiceOverOpenLinkCustomActionOnlyOnNavigableInterlink() async throws {
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "p1", node: "paragraph",
                children: [
                    .text("Plain "),
                    .inline(
                        .interlink(
                            docID: targetID.uuidString.lowercased(), blockID: "b9", title: "Spec", disabled: false,
                            trigger: "/")),
                    .text(" "),
                    .inline(
                        .interlink(
                            docID: targetID.uuidString.lowercased(), blockID: nil, title: "Off", disabled: true,
                            trigger: "/")),
                    .text(" "),
                    .inline(.mention(userID: "u1", fullName: "Ada")),
                ])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        var opened: [(UUID, String)] = []
        harness.view.blockControls.onOpenDocument = { id, blockID in opened.append((id, blockID)) }

        let enabledOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .interlink(_, _, _, let disabled, _) = $0 { return !disabled }
            return false
        }
        let disabledOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .interlink(_, _, _, let disabled, _) = $0 { return disabled }
            return false
        }
        let mentionOffset = try inlineChipOffset(in: harness.view.textStorage) {
            if case .mention = $0 { return true }
            return false
        }

        for editable in [false, true] {
            harness.view.isEditable = editable

            harness.view.selectedRange = NSRange(location: 0, length: 0)
            XCTAssertFalse((harness.view.accessibilityCustomActions ?? []).contains { $0.name == "Open link" })

            for range in [
                NSRange(location: enabledOffset, length: 0),
                NSRange(location: enabledOffset + 1, length: 0),
                NSRange(location: enabledOffset, length: 1),
            ] {
                harness.view.selectedRange = range
                let openAction = try XCTUnwrap(
                    harness.view.accessibilityCustomActions?.first { $0.name == "Open link" },
                    "editable=\(editable) range=\(range)")
                XCTAssertTrue(openAction.actionHandler?(openAction) ?? false)
            }

            for nonNavOffset in [disabledOffset, mentionOffset] {
                harness.view.selectedRange = NSRange(location: nonNavOffset, length: 1)
                XCTAssertFalse((harness.view.accessibilityCustomActions ?? []).contains { $0.name == "Open link" })
            }
        }

        XCTAssertEqual(opened.count, 6)
        XCTAssertTrue(opened.allSatisfy { $0.0 == targetID && $0.1 == "b9" })
        XCTAssertEqual(harness.log.commands, [])
    }

    func testPageLinkCoordinatorIgnoresSelfLinkAndDismissesCoversBeforePush() async throws {
        let currentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let otherID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        XCTAssertEqual(documentLinkAction(forDocumentID: currentID, currentDocumentID: currentID), .alreadyOpen)
        XCTAssertEqual(documentLinkAction(forDocumentID: otherID, currentDocumentID: currentID), .openInApp(otherID))

        let coordinator = NativeDocumentLinkCoordinator()
        var resolveCalls: [UUID] = []
        var coverOpen = true
        var dismissCount = 0
        var pushed: [Schrift.Document] = []

        // Self-link is a silent no-op: no resolution, no cover dismissal, no push.
        coordinator.open(
            documentID: currentID,
            currentDocumentID: currentID,
            resolve: { id in
                resolveCalls.append(id)
                return self.makeDocument(id: id, title: "Self")
            },
            hasPresentedCover: { coverOpen },
            dismissCovers: {
                dismissCount += 1
                coverOpen = false
            },
            push: { pushed.append($0) })
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(resolveCalls.isEmpty)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertTrue(pushed.isEmpty)

        // With an open cover, resolution requests dismissal first and pushes only after dismissal completes.
        coordinator.open(
            documentID: otherID,
            currentDocumentID: currentID,
            resolve: { id in
                resolveCalls.append(id)
                return self.makeDocument(id: id, title: "Target")
            },
            hasPresentedCover: { coverOpen },
            dismissCovers: { dismissCount += 1 },
            push: { pushed.append($0) })
        for _ in 0..<20 where dismissCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(resolveCalls, [otherID])
        XCTAssertEqual(dismissCount, 1)
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertEqual(coordinator.pendingDocument?.id, otherID)

        coverOpen = false
        coordinator.flushPendingIfReady(hasPresentedCover: { coverOpen }, push: { pushed.append($0) })
        XCTAssertEqual(pushed.map(\.id), [otherID])
        XCTAssertNil(coordinator.pendingDocument)

        // Without an open cover, resolution pushes immediately.
        let thirdID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        coordinator.open(
            documentID: thirdID,
            currentDocumentID: currentID,
            resolve: { id in self.makeDocument(id: id, title: "Third") },
            hasPresentedCover: { false },
            dismissCovers: { dismissCount += 1 },
            push: { pushed.append($0) })
        for _ in 0..<20 where pushed.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pushed.map(\.id), [otherID, thirdID])
        XCTAssertEqual(dismissCount, 1)
    }

    func testTableAndColumnChipTapForwardsOnOpenDocument() async throws {
        let targetID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        // Table surface: active cell opens with selectAll (length > 0); chip tap still fires navigation.
        let tableHarness = try await makeHarness(state: try fixtureUpdate("chipsInTable"))
        addTeardownBlock { await tableHarness.close() }
        var tableOpened: [(UUID, String)] = []
        let tableEditor = TableEditorViewController(document: tableHarness.session, tableID: "tbl")
        tableEditor.onOpenDocument = { id, blockID in tableOpened.append((id, blockID)) }
        _ = hostController(tableEditor)
        await tableEditor.load()
        for _ in 0..<300 where !tableEditor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        let cellSession = try XCTUnwrap(tableEditor.cellSession)
        addTeardownBlock { await cellSession.close().value }
        let cellChipOffset = try inlineChipOffset(in: cellSession.textView.textStorage) {
            if case .interlink(let id, _, _, let disabled, _) = $0 {
                return id == targetID.uuidString.lowercased() && !disabled
            }
            return false
        }
        let cellChipFrame = try await ensureInlineChipFrame(in: cellSession.textView, utf16Offset: cellChipOffset)
        let cellCenter = CGPoint(x: cellChipFrame.midX, y: cellChipFrame.midY)
        XCTAssertTrue(cellSession.textView.chipTapShouldBegin(at: cellCenter))
        XCTAssertTrue(cellSession.textView.handleChipTap(at: cellCenter))
        XCTAssertEqual(tableOpened.first?.0, targetID)
        XCTAssertEqual(tableOpened.first?.1, "")

        // Column surface: ColumnEditorScreen forwards onOpenDocument to column text hosts.
        let columnHarness = try await makeHarness(state: try fixtureUpdate("chipsInColumns"))
        addTeardownBlock { await columnHarness.close() }
        var columnOpened: [(UUID, String)] = []
        let columnModel = ColumnEditorModel(document: columnHarness.session, groupID: "cl")
        addTeardownBlock { columnModel.close() }
        let hosting = UIHostingController(
            rootView: ColumnEditorScreen(
                model: columnModel,
                serverOrigin: "https://example.test",
                onOpenDocument: { id, blockID in columnOpened.append((id, blockID)) }
            ).environment(LocalizationStore()))
        _ = hostController(hosting)
        for _ in 0..<300 where columnModel.columns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let colSession = try XCTUnwrap(columnModel.columns.first)
        let colChipOffset = try inlineChipOffset(in: colSession.textView.textStorage) {
            if case .interlink(let id, _, _, let disabled, _) = $0 {
                return id == targetID.uuidString.lowercased() && !disabled
            }
            return false
        }
        let colChipFrame = try await ensureInlineChipFrame(in: colSession.textView, utf16Offset: colChipOffset)
        let colCenter = CGPoint(x: colChipFrame.midX, y: colChipFrame.midY)
        XCTAssertTrue(colSession.textView.chipTapShouldBegin(at: colCenter))
        XCTAssertTrue(colSession.textView.handleChipTap(at: colCenter))
        XCTAssertEqual(columnOpened.first?.0, targetID)
        XCTAssertEqual(columnOpened.first?.1, "")

        // Column 2 only has mentions/mentionSearch; tapping them never navigates.
        if columnModel.columns.count > 1 {
            let rightSession = columnModel.columns[1]
            let mentionOffset = try inlineChipOffset(in: rightSession.textView.textStorage) {
                if case .mention = $0 { return true }
                return false
            }
            let mentionFrame = try await ensureInlineChipFrame(in: rightSession.textView, utf16Offset: mentionOffset)
            let mentionPoint = CGPoint(x: mentionFrame.midX, y: mentionFrame.midY)
            XCTAssertFalse(rightSession.textView.chipTapShouldBegin(at: mentionPoint))
            XCTAssertFalse(rightSession.textView.handleChipTap(at: mentionPoint))
        }
        XCTAssertEqual(columnOpened.count, 1)
    }

    // MARK: - Review Round 1 (S1, S2, C3)

    func testUnboundedInlineChipStringsAreClippedAndScrubbedAcrossSurfaces() async throws {
        let combiningBurst = "A" + String(repeating: "\u{0301}", count: 600)
        let dirtyTitle = "\u{202E}Alpha\n\r\t\u{0007}Beta\u{2066}" + String(repeating: "x", count: 400)
        let cachedID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(
                tx, into: group, after: &after, id: "h1", node: "heading",
                props: [("level", .int(2))],
                children: [
                    .inline(
                        .interlink(
                            docID: "11111111-1111-4111-8111-111111111111", blockID: nil, title: dirtyTitle,
                            disabled: false, trigger: "/")),
                    .text(" "),
                    .inline(.mention(userID: "u1", fullName: combiningBurst)),
                    .text(" "),
                    .inline(
                        .interlink(
                            docID: cachedID.uuidString.lowercased(), blockID: nil, title: nil, disabled: false,
                            trigger: "/")),
                    .text(" "),
                    .inline(.mentionSearch(disabled: true, trigger: "\u{202E}/\n")),
                ])
            try insertContainer(
                tx, into: group, after: &after, id: "custom", node: "customWidget",
                children: [
                    .inline(
                        .interlink(
                            docID: "22222222-2222-4222-8222-222222222222", blockID: nil, title: combiningBurst,
                            disabled: false, trigger: "/"))
                ])
        }

        // Raw Yjs values remain intact on NativeInlineObject for Yjs/shadow parity.
        let doc = try decodeDoc(state)
        defer { doc.destroy() }
        let proj = NativeBlockProjection.project(doc)
        let h1 = try XCTUnwrap(proj.blocks.first { $0.block.id == "h1" })
        if case .interlink(_, _, let rawTitle, _, _)? = h1.block.runs.first?.inlineObject {
            XCTAssertEqual(rawTitle, dirtyTitle)
        } else {
            XCTFail("expected raw interlink")
        }
        let customBlock = try XCTUnwrap(proj.blocks.first { $0.block.id == "custom" })
        if case .preserved(_, let summary) = customBlock.preview {
            XCTAssertLessThanOrEqual(summary.utf16.count, NativeBlockPreview.Limits.maxText)
            XCTAssertFalse(summary.contains("\u{FFFC}"))
        } else {
            XCTFail("expected preserved preview")
        }

        let engine = DocumentEngine(doc: doc, surface: nil)
        defer { engine.detach() }
        let navEntries = engine.navigationEntries()
        let navEntry = try XCTUnwrap(navEntries.first { $0.blockID == "h1" })
        let navText = navEntry.resolvedText { id in id == cachedID ? "\u{202E}Cached\nTitle" : nil }
        XCTAssertFalse(navText.contains("\u{202E}"))
        XCTAssertFalse(navText.contains("\u{2066}"))
        XCTAssertTrue(navText.contains("Alpha Beta"))
        XCTAssertTrue(navText.contains("Cached Title"))
        XCTAssertLessThan(navText.unicodeScalars.count, 1_000)

        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        harness.view.blockControls.documentTitle = { id in
            id == cachedID ? "\u{202A}Cached\nTitle\u{202E}" + String(repeating: "z", count: 400) : nil
        }

        let chips = inlineAttachments(in: harness.view.textStorage).map(\.1)
        XCTAssertEqual(chips.count, 4)
        for chip in chips {
            XCTAssertLessThanOrEqual(
                chip.content.displayLabel.unicodeScalars.count, NativeInlineObject.defaultDisplayLimit + 1)
            XCTAssertFalse(chip.content.displayLabel.contains("\n"))
            XCTAssertFalse(chip.content.displayLabel.contains("\r"))
            XCTAssertFalse(chip.content.displayLabel.contains("\t"))
            XCTAssertFalse(chip.content.displayLabel.contains("\u{0007}"))
            XCTAssertFalse(chip.content.displayLabel.contains("\u{202A}"))
            XCTAssertFalse(chip.content.displayLabel.contains("\u{202E}"))
            XCTAssertFalse(chip.content.displayLabel.contains("\u{2066}"))
            XCTAssertFalse(chip.content.displayLabel.contains("\u{FFFC}"))
            XCTAssertFalse(chip.content.accessibilityLabel.contains("\n"))
            XCTAssertFalse(chip.content.accessibilityLabel.contains("\u{202E}"))
        }
        XCTAssertTrue(chips[0].content.displayLabel.hasPrefix("Alpha Beta"))
        XCTAssertTrue(chips[0].content.displayLabel.hasSuffix("…"))
        XCTAssertEqual(chips[3].content.displayLabel, "/")

        let axValue = try XCTUnwrap(harness.view.accessibilityValue)
        XCTAssertFalse(axValue.contains("\u{202E}"))
        XCTAssertFalse(axValue.contains("\u{0007}"))
        XCTAssertLessThan(axValue.unicodeScalars.count, 1_500)
    }

    func testPasteInlineMultiLineMintsIDsAndRefusesOversizedOrUnpastablePayloads() async throws {
        let validID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let state = try makeYDocState { tx, group in
            var after: YItem?
            try insertContainer(tx, into: group, after: &after, id: "p1", node: "paragraph", children: [.text("AB")])
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }

        let p1 = try XCTUnwrap(harness.session.surface.rangeIndex.entry(for: "p1"))
        harness.view.selectedRange = NSRange(location: p1.textRange.location + 1, length: 0)

        // Multi-line BlockNoteInlinePayload pastes via NativeInputCoordinator (newBlockIDs minted by engine).
        let multiPayload = try BlockNoteInlinePayload.encode([
            [
                .text([.run(InlineRun("1"))]),
                .element("userMentionInline", [("userId", .string("u1")), ("fullName", .string("Ada"))], []),
            ],
            [
                .element(
                    "interlinkingLinkInline",
                    [
                        ("docId", .string(validID.uuidString.lowercased())),
                        ("blockId", .string("")),
                        ("disabled", .bool(false)),
                        ("trigger", .string("/")),
                    ], []),
                .text([.run(InlineRun("2"))]),
            ],
        ])
        harness.pasteboard.setItems([[BlockNoteInlinePayload.pasteboardType: multiPayload]])
        let ok = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertTrue(ok)
        XCTAssertEqual(harness.session.surface.blocks.count, 2)
        XCTAssertEqual(harness.session.surface.blocks[0].runs.compactMap(\.inlineObject).count, 1)
        XCTAssertEqual(harness.session.surface.blocks[1].runs.compactMap(\.inlineObject).count, 1)

        // Unpastable inline payload (non-UUID enabled interlink) is refused without writes.
        let beforeCount = harness.log.commands.count
        let badPayload = try BlockNoteInlinePayload.encode([
            [
                .element(
                    "interlinkingLinkInline",
                    [
                        ("docId", .string("not-a-uuid")),
                        ("blockId", .string("")),
                        ("disabled", .bool(false)),
                        ("trigger", .string("/")),
                    ], [])
            ]
        ])
        harness.pasteboard.setItems([[BlockNoteInlinePayload.pasteboardType: badPayload]])
        _ = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_unavailable)
        XCTAssertEqual(harness.log.commands.count, beforeCount)

        // Oversized inline payload (> maxPasteUTF16) refuses with native_editor_paste_too_large.
        let hugeText = String(repeating: "x", count: NativeClipboard.maxPasteUTF16 + 10)
        let hugePayload = try BlockNoteInlinePayload.encode([[.text([.run(InlineRun(hugeText))])]])
        harness.pasteboard.setItems([[BlockNoteInlinePayload.pasteboardType: hugePayload]])
        _ = await harness.session.run { harness.input.pasteFromPasteboard() }
        XCTAssertEqual(harness.input.noticeKey, .native_editor_paste_too_large)
        XCTAssertEqual(harness.log.commands.count, beforeCount)
    }

    func testInactiveTableCellChipsSizeToColumnWidth() async throws {
        let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let longTitle = String(repeating: "Very Long Linked Document Title ", count: 8)
        let state = try makeYDocState { tx, group in
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
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
                        let chip = YType(typeRef: .xmlElement(nodeName: "interlinkingLinkInline"))
                        try YWrite.insertAfter(tx, into: para, after: nil, [.type(chip)])
                        try YWrite.mapSet(tx, on: chip, key: "docId", .any([.string(docID.uuidString.lowercased())]))
                        try YWrite.mapSet(tx, on: chip, key: "blockId", .any([.string("")]))
                        try YWrite.mapSet(tx, on: chip, key: "disabled", .any([.bool(false)]))
                        try YWrite.mapSet(tx, on: chip, key: "trigger", .any([.string("/")]))
                        try YWrite.mapSet(tx, on: chip, key: "title", .any([.string(longTitle)]))
                    } else {
                        let xmlText = YType(typeRef: .xmlText)
                        try YWrite.insertAfter(tx, into: para, after: nil, [.type(xmlText)])
                        try YWrite.insertAfter(tx, into: xmlText, after: nil, [.string(Array("ok".utf16))])
                    }
                }
            }
        }
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        hostController(editor)
        editor.loadViewIfNeeded()
        await editor.load()
        for _ in 0..<300 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }

        // Activate a different cell so (0, 0) is rendered via an inactive TableCellView.
        XCTAssertTrue(editor.activate(TableGrid.CellRef(row: 1, index: 1)))
        editor.view.layoutIfNeeded()

        let cellView = try XCTUnwrap(editor.cellViews[TableGrid.CellRef(row: 0, index: 0)])
        let labelText = try XCTUnwrap(cellView.label.attributedText)
        let chips = inlineAttachments(in: labelText).map(\.1)
        XCTAssertEqual(chips.count, 1)
        let maxContentWidth = 120 - TableEditorViewController.padding * 2
        XCTAssertLessThanOrEqual(
            chips[0].content.size.width, maxContentWidth + 0.5,
            "inactive cell chip must clamp to column width (\(maxContentWidth)pt), not 320pt fallback")
    }
}
