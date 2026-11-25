import XCTest

@testable import Schrift

/// Tests for `NativeEditUnavailableReason` copy, icon mapping, projection refusal diagnostics,
/// `NativeEditorOpen.resolveUnavailableReason`, and `NativeEditorOpen.editUnavailableReason`.
@MainActor
final class NativeEditUnavailableReasonTests: DocumentEngineTestCase {
    private let owner = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    // MARK: - Icons and Localized Notes

    func testAllReasonCasesExposeExpectedIconAndLocalizedNote() {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let cases:
            [(
                reason: NativeEditUnavailableReason, icon: MaterialIcon, expectedNote: String,
                expectedDetails: String?
            )] = [
                (
                    .unfamiliarContent(blockNode: "callout", reason: "nested blocks"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (Callout: nested content)",
                    "Details: callout:nestedblocks"
                ),
                (
                    .unfamiliarContent(blockNode: "", reason: "unsupported root"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (a block type the native editor doesn't know: other)",
                    "Details: unsupportedroot"
                ),
                (
                    .unfamiliarContent(blockNode: "diagram", reason: "diagram: unsupported"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (Diagram: other)",
                    "Details: diagram:unsupported"
                ),
                (
                    .unfamiliarContent(blockNode: "exoticWidget", reason: "unknownNode:exoticWidget"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (a block type the native editor doesn't know: unsupported block type)",
                    "Details: unknownNode:exoticWidget"
                ),
                (
                    .unfamiliarContent(blockNode: "heading", reason: "prop:textColor"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (Heading: unsupported block setting)",
                    "Details: heading:prop:textColor"
                ),
                (
                    .unfamiliarContent(blockNode: "paragraph", reason: "interlinkingLink"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (Paragraph: unsupported link)",
                    "Details: paragraph:interlinkingLink"
                ),
                (
                    .unfamiliarContent(blockNode: "table", reason: "table: large table"),
                    .info,
                    "Read-only: this document has a block the native editor can't edit yet (Table: oversized content)",
                    "Details: table:largetable"
                ),
                (.noEditAccess, .lock, loc[.native_editor_read_only_no_access], nil),
                (.nativeSwitchOff, .lock, loc[.native_editor_owned_read_only_body], nil),
                (.pendingSync, .sync, loc[.native_editor_read_only_pending_sync], nil),
                (.pendingDelete, .delete, loc[.editor_pending_delete], nil),
                (.classicDraft, .sync, loc[.native_editor_read_only_classic_draft], nil),
                (.liveHeld, .sync, loc[.native_editor_read_only_live_held], nil),
                (.signedOut, .lock, loc[.native_editor_read_only_signed_out], nil),
                (.preservedUnavailable, .warning, loc[.native_editor_owned_unavailable_body], nil),
            ]

        for entry in cases {
            XCTAssertEqual(entry.reason.icon, entry.icon, "icon mismatch for \(entry.reason)")
            let note = entry.reason.localizedNote(using: loc)
            XCTAssertFalse(note.isEmpty, "empty note for \(entry.reason)")
            XCTAssertEqual(note, entry.expectedNote, "note mismatch for \(entry.reason)")
            XCTAssertEqual(
                entry.reason.localizedDetailsLine(using: loc), entry.expectedDetails,
                "details mismatch for \(entry.reason)")
        }
        XCTAssertTrue(loc[.native_editor_read_only_pending_sync].contains("reopen"))
        XCTAssertTrue(loc[.native_editor_read_only_classic_draft].contains("reopen"))
        XCTAssertTrue(loc[.native_editor_read_only_live_held].contains("reopen"))
    }

    // MARK: - Projection Refusal & No Text Leak

    func testCalloutWithNestedBlocksProducesUnfamiliarReasonWithoutLeakingText() async throws {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let secretParent = "CONFIDENTIAL_CALLOUT_TEXT"
        let secretChild = "CONFIDENTIAL_CHILD_TEXT"
        let callout = BlockNoteBlock(
            node: "callout",
            props: [
                ("backgroundColor", .string("default")),
                ("emoji", .string("💡")),
                ("textAlignment", .string("left")),
            ],
            runs: [InlineRun(secretParent)],
            id: "callout-1",
            children: [
                BlockNoteBlock(
                    node: "paragraph", props: Self.paragraphProps, runs: [InlineRun(secretChild)], id: "child-1")
            ])
        let state = BlockNoteYjs.encode([callout], clientID: Self.seedClientID)
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(state), origin: .remote)

        let unsupported = NativeBlockProjection.firstUnsupportedReason(doc)
        XCTAssertEqual(unsupported, NativeUnfamiliarBlock(node: "callout", reason: "nested blocks"))

        let session = try await NativeEditorSession.inspect(state: state)
        defer { session.close() }
        XCTAssertFalse(session.canType)
        XCTAssertEqual(session.unfamiliarContent, NativeUnfamiliarBlock(node: "callout", reason: "nested blocks"))

        let reason = NativeEditUnavailableReason.unfamiliarContent(
            blockNode: session.unfamiliarContent?.node ?? "",
            reason: session.unfamiliarContent?.reason ?? "")
        let note = reason.localizedNote(using: loc)
        XCTAssertEqual(
            note,
            "Read-only: this document has a block the native editor can't edit yet (Callout: nested content)")
        let details = try XCTUnwrap(reason.localizedDetailsLine(using: loc))
        XCTAssertEqual(details, "Details: callout:nestedblocks")
        XCTAssertFalse(note.contains(secretParent))
        XCTAssertFalse(note.contains(secretChild))
        XCTAssertFalse(details.contains(secretParent))
        XCTAssertFalse(details.contains(secretChild))
    }

    func testAnUnknownBlockAloneIsTypeableAndAnUnsupportedRootNeverLeaksDocumentText() async throws {
        let (_, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        // An unknown block is a locked preserved card (PR02): the document is
        // typeable, so there is no reason to leak anything into.
        let secretOpaque = "SECRET_WIDGET_BODY"
        let exotic = BlockNoteBlock(
            node: "exoticWidget", props: [], runs: [InlineRun(secretOpaque)], id: "exotic-1")
        let exoticState = BlockNoteYjs.encode([exotic], clientID: Self.seedClientID)
        let exoticSession = try await NativeEditorSession.inspect(state: exoticState)
        defer { exoticSession.close() }
        XCTAssertTrue(exoticSession.canType)
        XCTAssertNil(exoticSession.unfamiliarContent)
        XCTAssertNil(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: exoticSession))

        let badRootDoc = YDoc(clientID: 2)
        defer { badRootDoc.destroy() }
        let root = badRootDoc.get(BlockNoteYjs.fragmentField)
        try badRootDoc.transact { tx -> Void in
            _ = try YWrite.insertAfter(
                tx, into: root, after: nil, [.type(YType(typeRef: .xmlElement(nodeName: "unknown")))])
        }
        let badRootState = try YStateEncoder.encodeStateAsUpdate(badRootDoc)
        let badRootSession = try await NativeEditorSession.inspect(state: badRootState)
        defer { badRootSession.close() }
        XCTAssertTrue(badRootSession.hasUnsupportedRoot)
        XCTAssertFalse(badRootSession.canType)

        let badRootReason = NativeEditorOpen.resolveUnavailableReason(
            enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
            hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: badRootSession)
        XCTAssertEqual(badRootReason, .unfamiliarContent(blockNode: "", reason: "unsupported root"))
    }

    // MARK: - Resolution Precedence

    func testResolveUnavailableReasonPrecedenceAcrossGates() async throws {
        let typeableState = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let typeableSession = try await NativeEditorSession.inspect(state: typeableState)
        defer { typeableSession.close() }
        XCTAssertTrue(typeableSession.canType)

        XCTAssertNil(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: typeableSession))

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: false, hasEditAccess: false, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .noEditAccess)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: false, hasEditAccess: true, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .nativeSwitchOff)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: true,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .pendingDelete)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: true, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .pendingSync)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: true, hasClassicDraft: true, session: typeableSession),
            .liveHeld)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: true, session: typeableSession),
            .classicDraft)

        XCTAssertEqual(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: false, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: typeableSession),
            .signedOut)
    }

    // MARK: - Open Route Integration

    func testOpenPopulatesEditUnavailableReasonOnReadOnlyRoutesAndClearsOnWritableRoute() async throws {
        // 1. Reader (no edit access)
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: false)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: false)
            guard case .native(let session) = open.route else { return XCTFail("expected .native reader") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .noEditAccess)
        }

        // 2. Unfamiliar block (callout with nested block)
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            let callout = BlockNoteBlock(
                node: "callout",
                props: [("backgroundColor", .string("default")), ("emoji", .string("💡"))],
                runs: [InlineRun("Body")],
                id: "c1",
                children: [
                    BlockNoteBlock(
                        node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Child")], id: "p1")
                ])
            stubServer(state: BlockNoteYjs.encode([callout], clientID: Self.seedClientID), canUpdate: true)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected .native reader") }
            XCTAssertNil(session.input)
            XCTAssertEqual(
                open.editUnavailableReason, .unfamiliarContent(blockNode: "callout", reason: "nested blocks"))
        }

        // 3. Owned replica with switch off -> .nativeSwitchOff
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            try seedReplica(env)
            let open = NativeEditorOpen(preference: { false })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected owned .native route") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .nativeSwitchOff)
        }

        // 4. Owned replica held by live owner -> .liveHeld
        do {
            let env = makeEnvironment(isLiveHeld: { _ in true })
            defer { env.clean() }
            try seedReplica(env)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected owned .native route") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .liveHeld)
        }

        // 5. Ownership marker without readable replica (switch off) -> .preservedUnavailable
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            let scope = ReplicaScope(
                serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
                documentID: env.documentID)
            try env.replicaStore.create(
                for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
            let manifestURL = env.directory
                .appendingPathComponent("ReplicaDrafts")
                .appendingPathComponent(try scope.directoryName())
                .appendingPathComponent("manifest.json")
            try FileManager.default.removeItem(at: manifestURL)
            let open = NativeEditorOpen(preference: { false })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: true, canUpdate: true)
            guard case .preservedUnavailable = open.route else {
                return XCTFail("expected .preservedUnavailable route")
            }
            XCTAssertEqual(open.editUnavailableReason, .preservedUnavailable)
        }

        // 6. Typeable document clears editUnavailableReason
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: true)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected .native editor") }
            XCTAssertNotNil(session.input)
            XCTAssertNil(open.editUnavailableReason)
        }
    }

    // MARK: - German Locale & Crafted Peer String Sanitization

    func testGermanLocaleMainLineContainsNoRawProjectionTokens() throws {
        let (loc, cleanup) = makeLocalizationStore(language: .german)
        defer { cleanup() }

        let forbiddenRawTokens = [
            "unknownNode", "unknownProp", "prop:", "nested blocks", "unsupported",
            "interlinkingLink", "badLink", "large table", "exoticWidget",
            "callout", "diagram:", "heading", "paragraph", "table",
        ]
        let reasons: [(NativeEditUnavailableReason, expectedLabel: String, expectedCategory: String)] = [
            (
                .unfamiliarContent(blockNode: "callout", reason: "nested blocks"),
                loc[.native_editor_block_callout],
                loc[.native_editor_unfamiliar_category_nested_content]
            ),
            (
                .unfamiliarContent(blockNode: "diagram", reason: "diagram: unsupported"),
                loc[.native_editor_diagram],
                loc[.native_editor_unfamiliar_category_other]
            ),
            (
                .unfamiliarContent(blockNode: "heading", reason: "prop:textColor"),
                loc[.native_editor_block_heading],
                loc[.native_editor_unfamiliar_category_block_setting]
            ),
            (
                .unfamiliarContent(blockNode: "paragraph", reason: "unknownProp:peerKey"),
                loc[.native_editor_block_paragraph],
                loc[.native_editor_unfamiliar_category_block_setting]
            ),
            (
                .unfamiliarContent(blockNode: "paragraph", reason: "interlinkingLink"),
                loc[.native_editor_block_paragraph],
                loc[.native_editor_unfamiliar_category_link]
            ),
            (
                .unfamiliarContent(blockNode: "table", reason: "table: large table"),
                loc[.native_editor_block_table],
                loc[.native_editor_unfamiliar_category_oversized]
            ),
            (
                .unfamiliarContent(blockNode: "exoticWidget", reason: "unknownNode:exoticWidget"),
                loc[.native_editor_unfamiliar_unknown_block_type],
                loc[.native_editor_unfamiliar_category_block_type]
            ),
            (
                .unfamiliarContent(blockNode: "", reason: "unsupported root"),
                loc[.native_editor_unfamiliar_unknown_block_type],
                loc[.native_editor_unfamiliar_category_other]
            ),
        ]

        for (reason, expectedLabel, expectedCategory) in reasons {
            let mainLine = reason.localizedNote(using: loc)
            XCTAssertTrue(mainLine.contains(expectedLabel), "expected \(expectedLabel) in \(mainLine)")
            XCTAssertTrue(mainLine.contains(expectedCategory), "expected \(expectedCategory) in \(mainLine)")
            for token in forbiddenRawTokens {
                XCTAssertFalse(
                    mainLine.localizedCaseInsensitiveContains(token),
                    "main line leaked raw token '\(token)': \(mainLine)")
            }
            XCTAssertNotNil(reason.localizedDetailsLine(using: loc))
        }
    }

    func testCraftedTenThousandCharNodeNameWithControlAndBidiCharsIsCleanAndBounded() async throws {
        let (loc, cleanup) = makeLocalizationStore()
        defer { cleanup() }

        let controlAndBidi = "\u{0000}\u{0007}\u{001B}\n\r\t\u{202E}\u{2066}\u{2069}\u{200F}\u{200E}💥"
        let craftedNode = controlAndBidi + "evilNode_123." + String(repeating: "A\u{202E}\u{0008}", count: 4000)
        XCTAssertGreaterThan(craftedNode.count, 10_000)

        let secretBody = "CONFIDENTIAL_PEER_DOC_TEXT"
        // An unknown node is a locked card now (PR02), so the document stays
        // read-only through the one block-level reason left: an id the engine
        // cannot address. The crafted node name still reaches the reason.
        let block = BlockNoteBlock(
            node: craftedNode,
            props: [("craftedKey\u{202E}\n" + String(repeating: "k", count: 10_000), .string("val"))],
            runs: [InlineRun(secretBody)],
            id: "")
        let state = BlockNoteYjs.encode([block], clientID: Self.seedClientID)
        let session = try await NativeEditorSession.inspect(state: state)
        defer { session.close() }
        XCTAssertFalse(session.canType)
        XCTAssertEqual(session.unfamiliarContent?.reason, "missing block id")

        let reason = try XCTUnwrap(
            NativeEditorOpen.resolveUnavailableReason(
                enabled: true, hasEditAccess: true, hasAccount: true, isPendingDelete: false,
                hasCheckpointedCreate: false, isLiveHeld: false, hasClassicDraft: false, session: session))
        let mainLine = reason.localizedNote(using: loc)
        XCTAssertEqual(
            mainLine,
            "Read-only: this document has a block the native editor can't edit yet (a block type the native editor doesn't know: other)"
        )
        XCTAssertFalse(mainLine.contains(secretBody))
        XCTAssertFalse(mainLine.contains("evilNode"))

        let detailsLine = try XCTUnwrap(reason.localizedDetailsLine(using: loc))
        let prefix = "Details: "
        XCTAssertTrue(detailsLine.hasPrefix(prefix), "unexpected details prefix: \(detailsLine)")
        let payload = String(detailsLine.dropFirst(prefix.count))
        XCTAssertLessThanOrEqual(payload.count, 48)
        XCTAssertFalse(payload.isEmpty)
        XCTAssertTrue(
            payload.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (v >= 0x41 && v <= 0x5A)
                    || (v >= 0x61 && v <= 0x7A)
                    || (v >= 0x30 && v <= 0x39)
                    || scalar == ":" || scalar == "." || scalar == "_" || scalar == "-"
            },
            "details payload contained disallowed characters: \(payload)")
        XCTAssertFalse(detailsLine.contains(secretBody))

        // Direct crafted unknownProp on a known block is also bounded and clean.
        let craftedPropReason = NativeEditUnavailableReason.unfamiliarContent(
            blockNode: "paragraph",
            reason: "unknownProp:" + controlAndBidi + String(repeating: "P", count: 10_000))
        XCTAssertEqual(
            craftedPropReason.localizedNote(using: loc),
            "Read-only: this document has a block the native editor can't edit yet (Paragraph: unsupported block setting)"
        )
        let propDetails = try XCTUnwrap(craftedPropReason.localizedDetailsLine(using: loc))
        let propPayload = String(propDetails.dropFirst(prefix.count))
        XCTAssertEqual(propPayload.count, 48)
        XCTAssertTrue(propPayload.hasPrefix("paragraph:unknownProp:P"))
    }

    // MARK: - Transient Reason Recompute on Refresh

    func testTransientReasonsRecomputeAfterHoldClearsAndRefreshRuns() async throws {
        // 1. liveHeld clears -> reason clears to nil (or .noEditAccess if server downgraded)
        do {
            var held = true
            let env = makeEnvironment(isLiveHeld: { _ in held })
            defer { env.clean() }
            try seedReplica(env)
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: true)

            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else { return XCTFail("expected .native route") }
            XCTAssertNil(session.input)
            XCTAssertEqual(open.editUnavailableReason, .liveHeld)

            held = false
            await open.refresh(viewModel: env.model, isOffline: false)
            XCTAssertEqual(
                open.editUnavailableReason, .liveHeld,
                "a cleared hold keeps the reopen-to-edit note while typing is not installed")
        }

        // 2. pendingSync clears into liveHeld, then clears to .noEditAccess when server says reader
        do {
            var held = true
            let localID = UUID()
            let env = makeEnvironment(
                isLiveHeld: { _ in held },
                preSeed: { defaults, documentID, origin in
                    PendingDocumentCreateStore(userDefaults: defaults).save(
                        PendingDocumentCreate(
                            localID: localID, title: "Pending", parentID: nil, createdAt: Date(),
                            serverOrigin: origin, ownerUserID: self.owner,
                            syncedServerID: documentID, postedTitle: "Pending"))
                })
            defer { env.clean() }
            try seedReplica(env)
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: false)

            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            XCTAssertEqual(open.editUnavailableReason, .pendingSync)

            env.model.saveCoordinator.discardPendingWork(documentID: localID)
            await open.refresh(viewModel: env.model, isOffline: true)
            XCTAssertEqual(open.editUnavailableReason, .liveHeld)

            held = false
            await open.refresh(viewModel: env.model, isOffline: false)
            XCTAssertEqual(open.editUnavailableReason, .noEditAccess)
        }

        // 3. classicDraft clears -> reason clears to nil
        do {
            let env = makeEnvironment()
            defer { env.clean() }
            try seedReplica(env)
            let draftStore = PendingDraftStore(userDefaults: env.defaults)
            draftStore.save(
                PendingDraft(
                    documentID: env.documentID, title: "Draft", markdown: "Draft", updatedAt: Date(),
                    replica: nil))
            stubServer(state: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID), canUpdate: true)

            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            XCTAssertEqual(open.editUnavailableReason, .classicDraft)

            draftStore.remove(documentID: env.documentID)
            await open.refresh(viewModel: env.model, isOffline: false)
            XCTAssertEqual(open.editUnavailableReason, .classicDraft, "keeps the reopen-to-edit note")
        }
    }

    // MARK: - Auxiliary Broadcast Root (doc-<UUID>)

    func testAuxiliaryBroadcastArrayRootIsTypablePreservedAndIgnoredByShadowWhileUnknownRootsStayReadOnly()
        async throws
    {
        let baseState = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let baseDoc = YDoc(clientID: 10, gc: true)
        defer { baseDoc.destroy() }
        try baseDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        let expectedShadow = try XCTUnwrap(NativeBlockProjection.markdownShadow(baseDoc))

        // 1. Build a doc with document-store + root array `doc-<uuid>` holding `"broadcast: doc-<uuid>"`.
        let broadcastUUID = "72ebe1bb-b927-49d0-9554-8235827e2c5a"
        let broadcastRootName = "doc-\(broadcastUUID)"
        let broadcastItem = "broadcast: \(broadcastRootName)"

        let seedDoc = YDoc(clientID: 20, gc: true)
        defer { seedDoc.destroy() }
        try seedDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        try seedDoc.transact { tx -> Void in
            let broadcast = seedDoc.get(broadcastRootName)
            try YWrite.insertAfter(tx, into: broadcast, after: nil, [.any([.string(broadcastItem)])])
        }
        let wireState = try YStateEncoder.encodeStateAsUpdate(seedDoc)

        // Decode from wire into a fresh YDoc (untyped bare root, matching live capture).
        let wireDoc = YDoc(clientID: 21, gc: true)
        defer { wireDoc.destroy() }
        try wireDoc.applyUpdate(YUpdateDecoder.decode(wireState), origin: .remote)

        let projection = NativeBlockProjection.project(wireDoc)
        XCTAssertTrue(projection.isFullyRenderable)
        XCTAssertTrue(projection.isFullyModeled)
        XCTAssertNil(NativeBlockProjection.firstUnsupportedReason(wireDoc))
        XCTAssertEqual(NativeBlockProjection.markdownShadow(wireDoc), expectedShadow)

        // Also check an explicitly `.array`-typed root.
        let typedArrayDoc = YDoc(clientID: 22, gc: true)
        defer { typedArrayDoc.destroy() }
        try typedArrayDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        let typedArrayRoot = YType(typeRef: .array)
        typedArrayRoot.integrate(doc: typedArrayDoc, item: nil)
        typedArrayDoc.share[broadcastRootName] = typedArrayRoot
        try typedArrayDoc.transact { tx -> Void in
            try YWrite.insertAfter(tx, into: typedArrayRoot, after: nil, [.any([.string(broadcastItem)])])
        }
        XCTAssertTrue(NativeBlockProjection.project(typedArrayDoc).isFullyModeled)
        XCTAssertEqual(NativeBlockProjection.markdownShadow(typedArrayDoc), expectedShadow)

        // Inspect and open through NativeEditorOpen (with a different documentID than broadcastUUID).
        let inspected = try await NativeEditorSession.inspect(state: wireState)
        defer { inspected.close() }
        XCTAssertTrue(inspected.canType)
        XCTAssertFalse(inspected.hasUnsupportedRoot)
        XCTAssertNil(inspected.unfamiliarContent)

        let env = makeEnvironment()
        defer { env.clean() }
        XCTAssertNotEqual(env.documentID.uuidString.lowercased(), broadcastUUID)
        stubServer(state: wireState, canUpdate: true)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected .native route") }
        let input = try XCTUnwrap(session.input, "doc-<UUID> broadcast array must keep document typable")
        XCTAssertTrue(session.canType)
        XCTAssertFalse(session.hasUnsupportedRoot)
        XCTAssertNil(open.editUnavailableReason)

        // 2. Edit round-trip leaves the broadcast root's items unchanged.
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "Edited "))
        await session.settle()
        let maybeRoundTripped = await session.replicaDoc { doc in
            try? YStateEncoder.encodeStateAsUpdate(doc)
        }
        let roundTrippedBytes = try XCTUnwrap(maybeRoundTripped.flatMap { $0 })
        let roundTrippedDoc = YDoc(clientID: 23, gc: true)
        defer { roundTrippedDoc.destroy() }
        try roundTrippedDoc.applyUpdate(YUpdateDecoder.decode(roundTrippedBytes), origin: .remote)
        XCTAssertTrue(
            NativeBlockProjection.project(roundTrippedDoc).blocks[0].block.runs.map(\.text).joined()
                .hasPrefix("Edited "))
        let preservedItems = YBlockProjection.children(
            of: try XCTUnwrap(roundTrippedDoc.share[broadcastRootName]), includeFormats: false)
        XCTAssertEqual(preservedItems.map(\.content), [.any([.string(broadcastItem)])])

        // 3. Different unknown roots (e.g. root map `comments`, or non-string / invalid `doc-*` roots) stay read-only.
        let commentsDoc = YDoc(clientID: 30, gc: true)
        defer { commentsDoc.destroy() }
        try commentsDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        try commentsDoc.transact { tx -> Void in
            let comments = commentsDoc.get("comments")
            try YWrite.mapSet(tx, on: comments, key: "c1", .any([.string("hello")]))
        }
        let commentsState = try YStateEncoder.encodeStateAsUpdate(commentsDoc)
        XCTAssertFalse(NativeBlockProjection.project(commentsDoc).isFullyModeled)
        XCTAssertNil(NativeBlockProjection.markdownShadow(commentsDoc))
        XCTAssertEqual(
            NativeBlockProjection.firstUnsupportedReason(commentsDoc),
            NativeUnfamiliarBlock(node: "", reason: "unsupported root"))

        let commentsEnv = makeEnvironment()
        defer { commentsEnv.clean() }
        stubServer(state: commentsState, canUpdate: true)
        let commentsOpen = NativeEditorOpen(preference: { true })
        defer { commentsOpen.close() }
        await commentsOpen.open(viewModel: commentsEnv.model, isOffline: false, canUpdate: true)
        guard case .native(let commentsSession) = commentsOpen.route else {
            return XCTFail("expected .native read-only route")
        }
        XCTAssertFalse(commentsSession.canType)
        XCTAssertNil(commentsSession.input)
        XCTAssertEqual(
            commentsOpen.editUnavailableReason,
            .unfamiliarContent(blockNode: "", reason: "unsupported root"))

        // Non-string item in `doc-<uuid>` is also refused.
        let nonStringBroadcastDoc = YDoc(clientID: 31, gc: true)
        defer { nonStringBroadcastDoc.destroy() }
        try nonStringBroadcastDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        try nonStringBroadcastDoc.transact { tx -> Void in
            let bad = nonStringBroadcastDoc.get(broadcastRootName)
            try YWrite.insertAfter(tx, into: bad, after: nil, [.any([.int(42)])])
        }
        XCTAssertFalse(NativeBlockProjection.project(nonStringBroadcastDoc).isFullyModeled)
        XCTAssertNil(NativeBlockProjection.markdownShadow(nonStringBroadcastDoc))
    }

    func testAuxiliaryBroadcastRootBoundsAndPrefixRefuseEditing() async throws {
        let baseState = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let broadcastUUID = "72ebe1bb-b927-49d0-9554-8235827e2c5a"
        let rootName = "doc-\(broadcastUUID)"
        let validItem = "broadcast: \(rootName)"

        func makeBroadcastDoc(_ configure: (YDoc) throws -> Void) throws -> YDoc {
            let doc = YDoc(clientID: 40, gc: true)
            try doc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
            try configure(doc)
            return doc
        }

        func assertReadOnly(_ doc: YDoc, label: String) async throws {
            XCTAssertTrue(NativeBlockProjection.hasUnsupportedAuxiliaryRoot(doc), label)
            XCTAssertFalse(NativeBlockProjection.project(doc).isFullyModeled, label)
            XCTAssertNil(NativeBlockProjection.markdownShadow(doc), label)
            XCTAssertEqual(
                NativeBlockProjection.firstUnsupportedReason(doc),
                NativeUnfamiliarBlock(node: "", reason: "unsupported root"),
                label)

            let state = try YStateEncoder.encodeStateAsUpdate(doc)
            let env = makeEnvironment()
            defer { env.clean() }
            stubServer(state: state, canUpdate: true)
            let open = NativeEditorOpen(preference: { true })
            defer { open.close() }
            await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
            guard case .native(let session) = open.route else {
                return XCTFail("expected .native route for \(label)")
            }
            XCTAssertFalse(session.canType, label)
            XCTAssertNil(session.input, label)
            XCTAssertEqual(
                open.editUnavailableReason,
                .unfamiliarContent(blockNode: "", reason: "unsupported root"),
                label)
        }

        // 1. Item without the `"broadcast: "` prefix stays read-only.
        for badItem in ["broadcast:\(rootName)", "other: \(rootName)", ""] {
            let doc = try makeBroadcastDoc { doc in
                try doc.transact { tx -> Void in
                    let root = doc.get(rootName)
                    try YWrite.insertAfter(tx, into: root, after: nil, [.any([.string(badItem)])])
                }
            }
            defer { doc.destroy() }
            try await assertReadOnly(doc, label: "missing prefix: \(badItem.debugDescription)")
        }

        // 2. Item byte-length bound: 256 UTF-8 bytes allowed; 257 UTF-8 bytes (ASCII and multi-byte) read-only.
        let exactLimitItem = "broadcast: " + String(repeating: "a", count: 256 - "broadcast: ".utf8.count)
        XCTAssertEqual(exactLimitItem.utf8.count, 256)
        let exactBytesDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                try YWrite.insertAfter(tx, into: doc.get(rootName), after: nil, [.any([.string(exactLimitItem)])])
            }
        }
        defer { exactBytesDoc.destroy() }
        XCTAssertFalse(NativeBlockProjection.hasUnsupportedAuxiliaryRoot(exactBytesDoc))
        XCTAssertTrue(NativeBlockProjection.project(exactBytesDoc).isFullyModeled)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(exactBytesDoc))

        let overByteLimitASCII = exactLimitItem + "a"
        XCTAssertEqual(overByteLimitASCII.utf8.count, 257)
        let overBytesDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                try YWrite.insertAfter(
                    tx, into: doc.get(rootName), after: nil, [.any([.string(overByteLimitASCII)])])
            }
        }
        defer { overBytesDoc.destroy() }
        try await assertReadOnly(overBytesDoc, label: "257 UTF-8 ASCII bytes")

        let overByteLimitMultibyte =
            "broadcast: " + String(repeating: "a", count: 255 - "broadcast: ".utf8.count) + "é"
        XCTAssertEqual(overByteLimitMultibyte.count, 256)
        XCTAssertEqual(overByteLimitMultibyte.utf8.count, 257)
        let overMultibyteDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                try YWrite.insertAfter(
                    tx, into: doc.get(rootName), after: nil, [.any([.string(overByteLimitMultibyte)])])
            }
        }
        defer { overMultibyteDoc.destroy() }
        try await assertReadOnly(overMultibyteDoc, label: "257 UTF-8 multi-byte")

        // 3. Per-root item count bound: 10,000 undeleted items (+ deleted items) allowed; 10,001 read-only.
        let exactItemsDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                let root = doc.get(rootName)
                let items = Array(repeating: YAnyValue.string(validItem), count: 10_001)
                try YWrite.insertAfter(tx, into: root, after: nil, [.any(items)])
                try YWrite.delete(tx, from: root, at: 0, length: 1)
            }
        }
        defer { exactItemsDoc.destroy() }
        XCTAssertFalse(NativeBlockProjection.hasUnsupportedAuxiliaryRoot(exactItemsDoc))
        XCTAssertTrue(NativeBlockProjection.project(exactItemsDoc).isFullyModeled)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(exactItemsDoc))

        let overItemsDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                let items = Array(repeating: YAnyValue.string(validItem), count: 10_001)
                try YWrite.insertAfter(tx, into: doc.get(rootName), after: nil, [.any(items)])
            }
        }
        defer { overItemsDoc.destroy() }
        try await assertReadOnly(overItemsDoc, label: "10,001 undeleted items")

        // 4. Document root count bound: 8 `doc-<UUID>` roots allowed; 9 read-only.
        let nineRoots = (0..<9).map { _ in "doc-\(UUID().uuidString.lowercased())" }
        let exactRootsDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                for name in nineRoots.prefix(8) {
                    try YWrite.insertAfter(
                        tx, into: doc.get(name), after: nil, [.any([.string("broadcast: \(name)")])])
                }
            }
        }
        defer { exactRootsDoc.destroy() }
        XCTAssertFalse(NativeBlockProjection.hasUnsupportedAuxiliaryRoot(exactRootsDoc))
        XCTAssertTrue(NativeBlockProjection.project(exactRootsDoc).isFullyModeled)
        XCTAssertNotNil(NativeBlockProjection.markdownShadow(exactRootsDoc))

        let overRootsDoc = try makeBroadcastDoc { doc in
            try doc.transact { tx -> Void in
                for name in nineRoots {
                    try YWrite.insertAfter(
                        tx, into: doc.get(name), after: nil, [.any([.string("broadcast: \(name)")])])
                }
            }
        }
        defer { overRootsDoc.destroy() }
        try await assertReadOnly(overRootsDoc, label: "9 doc-<UUID> roots")
    }

    func testPeerAppendToBroadcastRootPreservesSessionSelectionTypingAndShadowWithoutReset() async throws {
        let baseState = BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID)
        let broadcastUUID = "72ebe1bb-b927-49d0-9554-8235827e2c5a"
        let broadcastRootName = "doc-\(broadcastUUID)"
        let broadcastItem = "broadcast: \(broadcastRootName)"

        let seedDoc = YDoc(clientID: 20, gc: true)
        defer { seedDoc.destroy() }
        try seedDoc.applyUpdate(YUpdateDecoder.decode(baseState), origin: .remote)
        try seedDoc.transact { tx -> Void in
            let broadcast = seedDoc.get(broadcastRootName)
            try YWrite.insertAfter(tx, into: broadcast, after: nil, [.any([.string(broadcastItem)])])
        }
        let initialState = try YStateEncoder.encodeStateAsUpdate(seedDoc)

        let env = makeEnvironment()
        defer { env.clean() }
        stubServer(state: initialState, canUpdate: true)
        let open = NativeEditorOpen(preference: { true })
        defer { open.close() }
        await open.open(viewModel: env.model, isOffline: false, canUpdate: true)
        guard case .native(let session) = open.route else { return XCTFail("expected .native route") }
        let input = try XCTUnwrap(session.input)
        XCTAssertTrue(session.canType)
        session.setEditing(true)
        XCTAssertTrue(session.textView.isEditable)

        let firstEntry = try XCTUnwrap(session.surface.rangeIndex.entry(for: Self.firstID))
        let initialSelection = NSRange(location: firstEntry.textRange.location + 3, length: 2)
        session.textView.selectedRange = initialSelection
        input.textViewDidChangeSelection(session.textView)
        await session.settle()
        XCTAssertEqual(session.textView.selectedRange, initialSelection)

        let maybeInitialShadow = await session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        let initialShadow = try XCTUnwrap(maybeInitialShadow.flatMap { $0 })
        let log = PatchLog(session)

        // A peer appends another `"broadcast: doc-<uuid>"` item to the same broadcast root.
        let peerDoc = YDoc(clientID: 21, gc: true)
        defer { peerDoc.destroy() }
        try peerDoc.applyUpdate(YUpdateDecoder.decode(initialState), origin: .remote)
        let before = peerDoc.store.getStateVector()
        try peerDoc.transact { tx -> Void in
            let broadcast = peerDoc.get(broadcastRootName)
            let tail = YBlockProjection.children(of: broadcast, includeFormats: false).last
            try YWrite.insertAfter(tx, into: broadcast, after: tail, [.any([.string(broadcastItem)])])
        }
        let peerUpdate = try YStateEncoder.encodeStateAsUpdate(peerDoc, since: before)

        try await session.integrateServerState(peerUpdate)

        XCTAssertFalse(log.didReset)
        XCTAssertTrue(log.deliveries.allSatisfy { $0.resync == nil })
        XCTAssertTrue(log.patches.isEmpty)
        XCTAssertEqual(session.textView.selectedRange, initialSelection)
        XCTAssertTrue(session.canType)
        XCTAssertNotNil(session.input)
        XCTAssertTrue(session.state.writable)
        XCTAssertTrue(session.textView.isEditable)

        let maybeShadowAfterPeer = await session.replicaDoc { NativeBlockProjection.markdownShadow($0) }
        let shadowAfterPeer = try XCTUnwrap(maybeShadowAfterPeer.flatMap { $0 })
        XCTAssertEqual(shadowAfterPeer, initialShadow)

        // Typing remains functional and updates the document after the peer broadcast append.
        XCTAssertTrue(input.replace(range: NSRange(location: 0, length: 0), with: "Typed "))
        await session.settle()
        XCTAssertTrue(session.surface.blocks[0].runs.map(\.text).joined().hasPrefix("Typed "))
    }

    // MARK: - Helpers

    private func makeLocalizationStore(language: AppLanguage = .english) -> (LocalizationStore, () -> Void) {
        let suite = "NativeEditUnavailableReasonTests.Loc.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = LocalizationStore(userDefaults: defaults)
        store.language = language
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    private struct Environment {
        let model: EditorViewModel
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let replicaStore: ReplicaStore
        let documentID: UUID
        func clean() {
            MockURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEnvironment(
        isLiveHeld: @escaping @MainActor (UUID) -> Bool = { _ in false },
        preSeed: ((UserDefaults, UUID, String) -> Void)? = nil
    ) -> Environment {
        MockURLProtocol.reset()
        let suite = "NativeEditUnavailableReasonTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let documentID = UUID()
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let client = DocsAPIClient(
            baseURL: URL(string: "https://docs.example.org/api/v1.0/")!, session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
        preSeed?(defaults, documentID, client.serverOrigin)
        let content = DocumentContentCacheStore(directory: directory)
        let children = DocumentChildrenCacheStore(userDefaults: defaults)
        let replicaStore = ReplicaStore(
            directory: directory.appendingPathComponent("ReplicaDrafts"),
            ownershipStore: ReplicaOwnershipStore(userDefaults: defaults))
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: PendingDraftStore(userDefaults: defaults), replicaStore: replicaStore,
            contentCache: content, createStore: PendingDocumentCreateStore(userDefaults: defaults),
            deleteStore: PendingDocumentDeleteStore(userDefaults: defaults),
            attachmentStore: PendingAttachmentStore(
                userDefaults: defaults, directory: directory.appendingPathComponent("attachments")),
            listCache: DocumentCacheStore(userDefaults: defaults), childrenCache: children,
            serverOrigin: client.serverOrigin, backgroundTasks: .noop, isLiveReplicaHeld: isLiveHeld, sleep: neverSleep)
        let model = EditorViewModel(
            client: client, documentID: documentID, title: "Title", saveCoordinator: coordinator,
            signedInUser: SignedInUserStore(userDefaults: defaults), contentCache: content, childrenCache: children,
            listCache: DocumentCacheStore(userDefaults: defaults),
            availability: OnlineAvailability(userDefaults: defaults))
        return Environment(
            model: model, defaults: defaults, suite: suite, directory: directory,
            replicaStore: replicaStore, documentID: documentID)
    }

    private func seedReplica(_ env: Environment) throws {
        let scope = ReplicaScope(
            serverOrigin: env.model.client.serverOrigin, ownerUserID: owner, org: "docs",
            documentID: env.documentID)
        _ = try env.replicaStore.create(
            for: scope, checkpoint: BlockNoteYjs.encode(Self.seedBlocks(), clientID: Self.seedClientID))
    }

    private func stubServer(state: Data, canUpdate: Bool) {
        MockURLProtocol.stubHandler = { request in
            let url = request.url?.absoluteString ?? ""
            let json = ["Content-Type": "application/json"]
            if url.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: json, body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if url.contains("/collaboration/ydoc/") {
                let body = try! JSONSerialization.data(withJSONObject: ["doc": state.base64EncodedString()])
                return .init(statusCode: 200, headers: json, body: body, error: nil)
            }
            if url.contains("formatted-content") {
                let id = request.url!.path.split(separator: "/").first { UUID(uuidString: String($0)) != nil }!
                let object: [String: Any] = [
                    "id": String(id), "title": "Server title", "content": "Server body",
                    "created_at": "2026-11-07T10:00:00Z", "updated_at": "2026-11-07T10:00:00Z",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: object),
                    error: nil)
            }
            if request.httpMethod == "GET", url.hasSuffix("/"),
                let id = url.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) })
            {
                let detail: [String: Any] = [
                    "id": id.uuidString.lowercased(), "title": "Server title", "excerpt": NSNull(),
                    "abilities": ["update": canUpdate], "computed_link_reach": "restricted",
                    "computed_link_role": NSNull(), "created_at": "2026-11-07T10:00:00Z", "creator": NSNull(),
                    "depth": 1, "link_role": "reader", "link_reach": "restricted", "numchild": 0, "path": "0001",
                    "updated_at": "2026-11-07T10:00:00Z", "user_role": "owner",
                ]
                return .init(
                    statusCode: 200, headers: json, body: try! JSONSerialization.data(withJSONObject: detail),
                    error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }
}
