import Foundation

// MARK: - The Docs 6 save: the editor's markdown as an incremental update

/// Why an incremental save was refused. Every case means "the server's document is not a
/// shape this app can safely diff against", never a transport problem; the networking layer
/// reports it as `DocsAPIError.decoding`.
enum BlockNoteIncrementalSaveError: Error, Equatable {
    /// The server's bytes did not decode or integrate as a Yjs v1 update.
    case malformedServerState
    /// The server's update left dependencies unresolved (`pendingStructs`/`pendingDs`): the
    /// replica is incomplete, and a diff against it could reference items the server's own
    /// state does not order the way this one does.
    case incompleteServerState
    /// The `document-store` root is not the canonical single `blockGroup`, or a block lacks a
    /// unique id — `BlockNoteWrite.applyEdit` maps old blocks to live containers by position
    /// and id, and neither mapping would be trustworthy.
    case nonCanonicalDocument
}

/// Turns "the document should now read like this markdown" into the incremental Yjs update
/// that makes the server's current state read that way — the Docs 6 save path
/// (`DocsAPIClient.saveDocumentContent` on the collaboration route).
///
/// Docs 6 removed `PATCH documents/{id}/content/`; content lives in the collaboration server,
/// which applies a PATCHed update **incrementally**. A from-scratch document
/// (`MarkdownYjs.encode`) would therefore be appended to what is there and duplicate every
/// block. So the save fetches the server's state, rebuilds it as a throwaway replica, and
/// diffs the editor's blocks against it:
///
/// 1. integrate the server's update into a fresh `YDoc` (a fresh random client id, never one
///    the document already uses — a reused id would mint duplicate `(client, clock)` pairs);
/// 2. project it (`YBlockProjection`) into the old blocks;
/// 3. align the new blocks' ids with them (`BlockNoteAlignment`);
/// 4. `BlockNoteWrite.applyEdit` → the update holding exactly the ops this save made.
///
/// The replica is always destroyed before returning (`YDoc.destroy()` is not optional).
enum BlockNoteIncrementalSave {
    /// The update to PATCH, or nil when the server already reads exactly like `newBlocks`
    /// (nothing minted, nothing deleted) and no request is needed.
    ///
    /// `serverState` empty means an empty document. `serverOrigin` is used only to recognize
    /// the web's document-link nodes (see `oldBlocks`), never to build anything written.
    ///
    /// `baseBlocks` are the blocks parsed from the markdown the edit started from (the server
    /// copy the editor loaded). They tell `BlockNotePreservation` which new blocks the user did
    /// not touch; `nil` (no recorded base) keeps only blocks the markdown never shows.
    static func update(
        serverState: Data, newBlocks: [BlockNoteBlock], baseBlocks: [BlockNoteBlock]? = nil, serverOrigin: String,
        clientID: UInt = UInt(UInt32.random(in: 1...UInt32.max))
    ) throws -> Data? {
        var decoded: YUpdate?
        if !serverState.isEmpty {
            do {
                decoded = try YUpdateDecoder.decode(serverState)
            } catch {
                throw BlockNoteIncrementalSaveError.malformedServerState
            }
        }

        let doc = YDoc(clientID: clientID, gc: true)
        defer { doc.destroy() }
        if let decoded {
            do {
                try doc.applyUpdate(decoded)
            } catch {
                throw BlockNoteIncrementalSaveError.malformedServerState
            }
        }
        guard doc.store.pendingStructs == nil, doc.store.pendingDs == nil else {
            throw BlockNoteIncrementalSaveError.incompleteServerState
        }
        // Our items must not share a client id with anything already in the document.
        while doc.store.clients[doc.clientID] != nil {
            doc.clientID = UInt(UInt32.random(in: 1...UInt32.max))
        }

        let old = try oldBlocks(of: doc, serverOrigin: serverOrigin)
        // Server blocks the markdown cannot spell are put back in place of their untouched
        // shadows (`BlockNotePreservation`), so the write leaves them exactly as they are.
        let rules = BlockNotePreservation.rules(for: old, in: doc)
        let untouched = baseBlocks.map { BlockNotePreservation.untouched(base: $0, new: newBlocks) } ?? [:]
        let tokens = newBlocks.map { BlockNotePreservation.signatureTokens(of: $0) }
        // A server block's untouched shadow anchors to it, so a plain duplicate cannot take it.
        let anchors = BlockNoteAlignment.anchorPairs(old: old, new: newBlocks) { oldIndex, newIndex in
            guard untouched[newIndex] != nil, let rule = rules[oldIndex] else { return false }
            return BlockNotePreservation.isSingleShadow(newBlocks[newIndex], tokens: tokens[newIndex], of: rule)
        }
        let preserved = BlockNotePreservation.preserve(
            old: old, rules: rules, new: newBlocks, untouched: untouched, anchors: anchors, tokens: tokens)
        let aligned = BlockNoteAlignment.align(old: old, new: preserved.blocks, forced: preserved.forced)
        // The same copy a preserved block is written back as, so the write finds it unchanged.
        let oldForWrite = old.map(BlockNotePreservation.writableCopy(of:))

        let stateBefore = doc.store.getStateVector()
        let deletesBefore = YStateEncoder.deleteBlocks(YDeleteSet.from(store: doc.store))
        let update: Data
        do {
            update = try BlockNoteWrite.applyEdit(
                old: oldForWrite, new: aligned, to: doc, allowsNestedInserts: true)
        } catch {
            throw BlockNoteIncrementalSaveError.nonCanonicalDocument
        }
        // `encodeStateAsUpdate` always carries the document's whole delete set, so "nothing
        // changed" is read off the store, never off the update's size.
        if doc.store.getStateVector() == stateBefore,
            YStateEncoder.deleteBlocks(YDeleteSet.from(store: doc.store)) == deletesBefore
        {
            return nil
        }
        return update
    }

    /// The replica's top-level blocks as the alignment's `old`, after refusing every shape
    /// `applyEdit`'s positional container mapping cannot trust.
    ///
    /// Fidelity comes from a projection **without** an interlinking origin, on purpose: a web
    /// document-link node then projects opaque, so it is never paired and text-reconciled —
    /// its single item would sit where the rendered link text has several characters, and a
    /// text-span diff over it would land at the wrong indices. But such a block is still
    /// worth *anchoring* when the user did not touch it, or every save would flatten the
    /// web's link nodes into plain links. So its runs are taken from a second projection that
    /// does know the origin (where the node reads exactly as the server's markdown export
    /// spells it), and it is classified `.lossy`: anchorable when unchanged, never reconciled.
    private static func oldBlocks(of doc: YDoc, serverOrigin: String) throws -> [ProjectedBlock] {
        let document = YBlockProjection.project(doc, interlinkingOrigin: nil)
        // The projection's one signal for a non-canonical root: nothing projected, yet not
        // renderable. (A canonical document with no blocks is renderable.)
        if document.blocks.isEmpty, !document.isFullyRenderable {
            throw BlockNoteIncrementalSaveError.nonCanonicalDocument
        }
        guard blockGroupChildrenAreCountable(doc) else {
            throw BlockNoteIncrementalSaveError.nonCanonicalDocument
        }
        let ids = document.blocks.map(\.id)
        guard !ids.contains(where: \.isEmpty), Set(ids).count == ids.count else {
            throw BlockNoteIncrementalSaveError.nonCanonicalDocument
        }

        let linked = serverOrigin.isEmpty ? nil : YBlockProjection.project(doc, interlinkingOrigin: serverOrigin)
        return document.blocks.enumerated().map { (index, block) -> ProjectedBlock in
            guard case .opaque(let reason) = block.fidelity, reason == "interlinkingLink",
                let linked, index < linked.blocks.count
            else { return block }
            let counterpart = linked.blocks[index]
            guard counterpart.id == block.id, !counterpart.fidelity.isOpaque else { return block }
            var result = counterpart
            result.fidelity = .lossy(reasons: ["interlinkingLink"])
            return result
        }
    }

    /// `applyEdit` maps old blocks to containers by walking the `blockGroup`'s undeleted
    /// children, while the projection skips non-countable ones. They agree only when every
    /// undeleted child is countable, which a well-formed BlockNote document always is.
    private static func blockGroupChildrenAreCountable(_ doc: YDoc) -> Bool {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { return true }
        var item = root.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted, case .type(let group) = current.content,
                group.typeRef == .xmlElement(nodeName: "blockGroup")
            else { continue }
            var child = group.start
            while let entry = child {
                if !entry.deleted, !entry.countable { return false }
                child = entry.right
            }
        }
        return true
    }
}
