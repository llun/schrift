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

    private func makeDocument(id: UUID = UUID(), title: String?) -> Document {
        Document(
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
}
