import UIKit

/// Value inputs that can actually change the attributed projection. UIKit
/// trait collections carry other traits and need not have stable identity.
struct NativeTextPresentation: Equatable {
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels
}

/// The display of one replica session's deliveries: all origins apply, and
/// identified command echoes reconcile exactly once per emission. Only the
/// changed text ranges are replaced; props/replacements rebuild one block's
/// slice. A reset is the only patch that replaces the full document storage.
///
/// **Predictions (PR08b, option A).** Same-block typing is shown before its
/// journal append (`predict`), as provisional UI. The surface keeps each block's
/// canonical snapshot under its pending predictions; the command's own echo
/// confirms it (and repairs the slice if the journaled block differs), a
/// concurrent change to the block rebases the pending predictions through it
/// (`TextDelta.rebase`, as the session does) or, when that is impossible,
/// shows the canonical block and waits for the session's invalidation, and
/// `rollback` restores every canonical block.
@MainActor
final class NativeTextSurface: @preconcurrency EditorSurface {
    let storage: NSTextStorage
    private(set) var blocks: [BlockSnapshot]
    private(set) var rangeIndex: ProjectionRangeIndex
    private(set) var traits: UITraitCollection
    private var presentation: NativeTextPresentation
    private var lastNativeStamp: NativePatchStamp?
    /// UIKit owns the marked range from a composition's begin until the
    /// coordinator releases it: a restyle is a programmatic storage edit and
    /// would cancel it, so presentation changes wait. (Deliveries wait in the
    /// coordinator meanwhile, PR08b.)
    private var holdsComposition = false
    /// The block whose storage slice UIKit's marked text changed. Set by the
    /// composition session at its begin; the release rebuilds only this
    /// slice, so the rest of storage (and the scroll position) is never replaced.
    var provisionalBlockID: String?
    private var pendingPresentation: (traits: UITraitCollection, labels: NativeEditorLabels)?
    /// Attachment paragraph sizing (PR06e): the usable width and the image
    /// aspect ratios known at the last restyle. Never a Yjs input.
    private(set) var attachmentGeometry = NativeAttachmentGeometry()
    private var pendingAttachmentWidth: CGFloat?
    private var pendingGeometryRefresh = false
    /// An image URL's remembered aspect ratio (the image loader's), read only
    /// when the geometry is recomputed: a download never restyles storage.
    var aspectRatio: (@MainActor (String) -> CGFloat?)?
    /// Cached title for a linked document UUID, used only for inline interlink
    /// chip display without modifying Yjs.
    var documentTitle: (@MainActor (UUID) -> String?)?
    /// Titles recorded immediately upon picker selection so the first layout pass
    /// renders the page title even when `documentTitle` is unset or lags.
    private var recordedDocumentTitles: [UUID: String] = [:]

    func recordDocumentTitle(_ title: String, for documentID: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recordedDocumentTitles[documentID] = trimmed
        attachmentGeometry.documentTitles[documentID] = trimmed
    }
    /// Replica-backed surfaces use the owner's settled projection to validate
    /// fast patches. Value-only fixtures may omit this callback.
    private let reprojectBlock: ((String) -> BlockSnapshot?)?
    /// The delivery being applied: each `.text`/`.props` block's settled
    /// projection (replaces `reprojectBlock` for a replica session).
    private var settled: [String: BlockSnapshot]?
    /// The surface's id in its replica session: echoes stamped with it are
    /// this surface's own commands.
    var surfaceID: UUID?

    // MARK: Predictions (PR08b)

    struct Prediction: Equatable {
        let commandID: UUID
        let blockID: String
        /// Block-relative, in the display's coordinates when it was typed,
        /// rebased through every concurrent change since.
        var range: Range<Int>
        let text: String
        /// The complete marks the text carries (what Yjs will give it).
        let marks: [TextMark]
    }

    /// Typed and shown, not yet journaled, oldest first.
    private(set) var predictions: [Prediction] = []
    /// Predicted blocks a concurrent change made show their canonical
    /// snapshot: their predictions are off screen until the invalidation, so
    /// later patches apply to these blocks as to any canonical block.
    private var offscreen: Set<String> = []
    /// A block whose display includes pending predictions.
    private func isPredicted(_ id: String) -> Bool {
        !offscreen.contains(id) && predictions.contains { $0.blockID == id }
    }
    /// Each predicted block's canonical snapshot (journaled state, without
    /// its pending predictions).
    private var canonical: [String: BlockSnapshot] = [:]
    /// The text deltas this surface showed for the delivery being applied, per
    /// block in display coordinates (the coordinator maps the view's
    /// selection through them when the session's endpoints are stale).
    private(set) var shownDeltas: [(blockID: String, deltas: [TextDelta])] = []
    /// Blocks whose slice was rebuilt (or removed) by that delivery: offsets
    /// in them cannot be mapped through deltas. `shownReset`: the whole storage.
    private(set) var shownReplaced: Set<String> = []
    /// The rebuilt blocks whose text changed (their offsets mean other text).
    private(set) var shownRetexted: Set<String> = []
    private(set) var shownReset = false
    func resetShownDeltas() {
        shownDeltas = []
        shownReplaced = []
        shownRetexted = []
        shownReset = false
    }
    /// A concurrent change could not be rebased: the session will invalidate
    /// the epoch; until then nothing is predicted.
    private(set) var expectsInvalidation = false
    var labels: NativeEditorLabels { presentation.labels }
    /// True while a patch edits storage: UIKit's own selection adjustments
    /// then are not the user's and must not be published.
    private(set) var isApplyingPatch = false
    /// Called after each patch reaches storage, so the selection coordinator
    /// can restore the relative selection.
    var onPatchApplied: ((BlockPatch) -> Void)?

    // MARK: Folding (PR06b)

    /// The toggles this reader expanded, by block id: view state for this open
    /// document only, never stored and never in Yjs. A toggle not named here
    /// is collapsed, BlockNote's default (`defaultToggledState`).
    private(set) var expanded: Set<String> = []
    /// Per block position: inside a collapsed toggle. Folding hides layout
    /// only (`NativeBlockControls` skips these paragraphs in TextKit 2), so
    /// storage, `blocks` and the range index stay the full projection and
    /// every patch, local or remote, lands in hidden blocks as anywhere else.
    private(set) var hidden: [Bool] = []
    /// Each toggle's direct child count, so a toggle that gains a child opens
    /// (BlockNote's toggle frame `update`).
    private var toggleChildren: [String: Int] = [:]
    /// Called after the hidden set changed, once storage editing ended: the
    /// view re-lays out. Never a storage edit.
    var onFoldChange: (() -> Void)?

    init(
        blocks: [BlockSnapshot], storage: NSTextStorage, traits: UITraitCollection = .current,
        reprojectBlock: ((String) -> BlockSnapshot?)? = nil
    ) {
        self.blocks = blocks
        self.storage = storage
        self.traits = traits
        self.reprojectBlock = reprojectBlock
        self.rangeIndex = ProjectionRangeIndex(blocks: blocks)
        self.presentation = NativeTextPresentation(
            contentSize: traits.preferredContentSizeCategory, labels: NativeEditorLabels())
        storage.setAttributedString(
            AttributedDocumentProjection.attributedString(
                blocks: blocks, traits: traits, labels: labels, geometry: attachmentGeometry))
        _ = refreshFolding()
    }

    /// One delivered patch with its settled per-block projections.
    func applyPatch(_ patch: BlockPatch, settled: [String: BlockSnapshot]) {
        self.settled = settled
        defer { self.settled = nil }
        applyPatch(patch)
    }

    func applyPatch(_ patch: BlockPatch) {
        let ownEcho =
            patch.nativeCommand.flatMap { stamp in
                stamp.surfaceID != nil && stamp.surfaceID == surfaceID
                    && predictions.contains(where: { $0.commandID == stamp.commandID }) ? stamp : nil
            }
        if let stamp = ownEcho {
            // This surface's own predicted keystroke, now journaled.
            lastNativeStamp = stamp
            // A composition commit whose rebuild had to reset the list: the reset shows it.
            if patch.changes.contains(where: { if case .reset = $0 { true } else { false } }) {
                predictions.removeAll { $0.commandID == stamp.commandID }
                var plain = patch
                plain.nativeCommand = nil
                applyPatch(plain)
                return
            }
            confirm(stamp.commandID, patch: patch)
            return
        }
        if patch.origin == .localUser, let stamp = patch.nativeCommand {
            if let last = lastNativeStamp,
                stamp.baseRevision < last.baseRevision
                    || (stamp.commandID == last.commandID && stamp.emission <= last.emission)
            {
                return
            }
            lastNativeStamp = stamp
        }
        var foldChanged = false
        // Defers run in reverse: storage ends editing before the callback.
        defer {
            isApplyingPatch = false
            if foldChanged { onFoldChange?() }
            onPatchApplied?(patch)
        }
        isApplyingPatch = true
        storage.beginEditing()
        defer { storage.endEditing() }
        // Text edits never move a block, so only other changes renumber lists.
        var renumbers = false
        for change in patch.changes {
            if case .text = change {} else { renumbers = true }
            switch change {
            case .text(let id, let deltas):
                guard let position = rangeIndex.position(for: id) else { continue }
                if isPredicted(id) {
                    applyConcurrent(deltas, to: id, at: position)
                    continue
                }
                if let reprojectBlock = lookup {
                    guard let fresh = reprojectBlock(id) else { continue }
                    var predicted = blocks[position]
                    predicted.runs = TextDelta.apply(deltas, to: predicted.runs)
                    // Readable engine text may still render as a placeholder.
                    // A settled replica can also be ahead of this buffered
                    // patch: assignment must win over replaying its deltas.
                    if AttributedDocumentProjection.isPlaceholder(blocks[position])
                        || AttributedDocumentProjection.isPlaceholder(fresh) || predicted != fresh
                    {
                        replace(at: position, with: fresh)
                        continue
                    }
                } else if AttributedDocumentProjection.isPlaceholder(blocks[position]) {
                    // Snapshot-only consumers cannot infer replica fidelity,
                    // but must never splice replica offsets into a UI label.
                    var block = blocks[position]
                    block.runs = TextDelta.apply(deltas, to: block.runs)
                    replace(at: position, with: block)
                    continue
                }
                applyText(deltas, at: position)
            case .props(let id, let props):
                guard let position = rangeIndex.position(for: id) else { continue }
                if isPredicted(id) {
                    // Props never move text: keep the predicted runs.
                    var block = blocks[position]
                    block.props = props
                    canonical[id]?.props = props
                    replace(at: position, with: block)
                    continue
                }
                if let reprojectBlock = lookup {
                    guard let fresh = reprojectBlock(id) else { continue }
                    replace(at: position, with: fresh)
                    continue
                }
                var block = blocks[position]
                block.props = props
                replace(at: position, with: block)
            case .replaceBlock(let id, let block):
                guard let position = rangeIndex.position(for: id) else { continue }
                if isPredicted(id) {
                    offscreen.insert(id)
                    expectsInvalidation = true
                }
                replace(at: position, with: block)
            case .remove(let ids):
                let removed = Set(ids)
                shownReplaced.formUnion(ids)
                for id in ids where canonical.removeValue(forKey: id) != nil { expectsInvalidation = true }
                for position in blocks.indices.reversed() where removed.contains(blocks[position].id) {
                    storage.deleteCharacters(in: rangeIndex.entries[position].range)
                    blocks.remove(at: position)
                }
                rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
            case .insert(let after, let inserted):
                let existing = Set(blocks.map(\.id))
                var seen = existing
                let fresh = inserted.filter { seen.insert($0.id).inserted }
                guard !fresh.isEmpty else { continue }
                for block in fresh {
                    collectDocumentTitles(from: block, into: &attachmentGeometry.documentTitles)
                }
                let position = after.flatMap { rangeIndex.position(for: $0) }.map { $0 + 1 } ?? 0
                let offset =
                    position < rangeIndex.entries.count ? rangeIndex.entries[position].range.location : storage.length
                storage.insert(
                    AttributedDocumentProjection.attributedString(
                        blocks: fresh, traits: traits, labels: labels, geometry: attachmentGeometry),
                    at: offset)
                blocks.insert(contentsOf: fresh, at: position)
                rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
            case .reset(let reset):
                shownReset = true
                if !predictions.isEmpty { expectsInvalidation = true }
                offscreen.formUnion(predictions.map(\.blockID))
                canonical = [:]
                blocks = reset
                attachmentGeometry = geometry(width: attachmentGeometry.width)
                rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
                storage.setAttributedString(
                    AttributedDocumentProjection.attributedString(
                        blocks: blocks, traits: traits, labels: labels, geometry: attachmentGeometry))
            }
        }
        // A block shown from the replica with no prediction left in it needs no
        // canonical copy: the display is canonical.
        for change in patch.changes {
            switch change {
            case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                if !isPredicted(id) { canonical[id] = nil }
            case .insert, .remove, .reset: break
            }
        }
        if renumbers {
            renumberLists()
            // Only a non-text patch moves, adds or retypes a block.
            foldChanged = refreshFolding()
        }
    }

    private var lookup: ((String) -> BlockSnapshot?)? {
        if let settled { return { settled[$0] } }
        return reprojectBlock
    }

    /// Shows a same-block keystroke before it is journaled.
    func predict(_ prediction: Prediction) {
        guard let position = rangeIndex.position(for: prediction.blockID) else { return }
        if canonical[prediction.blockID] == nil { canonical[prediction.blockID] = blocks[position] }
        predictions.append(prediction)
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        storage.beginEditing()
        applyText(
            [TextDelta(range: prediction.range, replacement: prediction.text, marks: prediction.marks)], at: position)
        storage.endEditing()
    }

    /// A prediction's echo: it is canonical now. The last pending one in its
    /// block is checked against the journaled block and repaired if it differs.
    private func confirm(_ commandID: UUID, patch: BlockPatch) {
        guard let index = predictions.firstIndex(where: { $0.commandID == commandID }) else { return }
        let prediction = predictions.remove(at: index)
        let id = prediction.blockID
        // An echo the engine spelled as a whole-block rebuild (an empty block's
        // first text) carries its own snapshot.
        let rebuilt = patch.changes.lazy.compactMap { change -> BlockSnapshot? in
            if case .replaceBlock(let block, let snapshot) = change, block == id { return snapshot }
            return nil
        }.last
        let journaled = settled?[id] ?? rebuilt
        // A block whose predictions are off screen shows canonical: it takes the journaled block.
        if isPredicted(id) {
            if let journaled { canonical[id] = journaled }
            return
        }
        canonical[id] = nil
        guard let journaled, let position = rangeIndex.position(for: id), blocks[position] != journaled else { return }
        isApplyingPatch = true
        defer {
            isApplyingPatch = false
            onPatchApplied?(patch)
        }
        storage.beginEditing()
        replace(at: position, with: journaled)
        storage.endEditing()
    }

    /// The result for a prediction that had no echo (nothing changed).
    func confirm(_ commandID: UUID) {
        guard let index = predictions.firstIndex(where: { $0.commandID == commandID }) else { return }
        let id = predictions.remove(at: index).blockID
        if !predictions.contains(where: { $0.blockID == id }) { canonical[id] = nil }
    }

    /// A concurrent text change to a block with pending predictions: each
    /// prediction is rebased through it (and it through each), exactly as the
    /// session rebases the commands, then the rebased change is shown.
    private func applyConcurrent(_ deltas: [TextDelta], to id: String, at position: Int) {
        var concurrent = deltas
        var rebased = predictions
        for index in rebased.indices where rebased[index].blockID == id {
            let prediction = rebased[index]
            guard let range = TextDelta.rebase(range: prediction.range, assoc: 1, through: concurrent),
                let next = TextDelta.rebase(
                    concurrent, throughReplacing: prediction.range, length: prediction.text.utf16.count)
            else {
                // The session cannot rebase it either: show the canonical
                // block and wait for its invalidation.
                expectsInvalidation = true
                offscreen.insert(id)
                let fresh =
                    settled?[id]
                    ?? canonical[id].map { block in
                        var block = block
                        block.runs = TextDelta.apply(deltas, to: block.runs)
                        return block
                    }
                if let fresh { replace(at: position, with: fresh) }
                return
            }
            rebased[index].range = range
            concurrent = next
        }
        predictions = rebased
        if let fresh = settled?[id] {
            canonical[id] = fresh
        } else if var block = canonical[id] {
            block.runs = TextDelta.apply(deltas, to: block.runs)
            canonical[id] = block
        }
        applyText(concurrent, at: position)
    }

    /// Drops every pending prediction and shows each predicted block's
    /// canonical snapshot (an invalidated epoch or a failed append). Returns
    /// the dropped predictions, oldest first.
    @discardableResult
    func rollback() -> [Prediction] {
        expectsInvalidation = false
        let dropped = predictions
        predictions = []
        offscreen = []
        let restore = canonical
        canonical = [:]
        guard !restore.isEmpty else { return dropped }
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        storage.beginEditing()
        // A block already showing its snapshot is not rebuilt (nor recorded as shown).
        for (id, block) in restore {
            if let position = rangeIndex.position(for: id), blocks[position] != block {
                replace(at: position, with: block)
            }
        }
        storage.endEditing()
        return dropped
    }

    func isExpanded(_ blockID: String) -> Bool { expanded.contains(blockID) }

    /// A table surface's active cell (PR11a): when set, every block not in it
    /// is left out of layout exactly like folded content, so the table's one
    /// text view shows one cell. View state only; nil shows every block.
    private(set) var focus: Set<String>?

    func setFocus(_ blockIDs: Set<String>?) {
        guard blockIDs != focus else { return }
        focus = blockIDs
        if refreshFolding() { onFoldChange?() }
    }

    /// Folds or unfolds a toggle: view state only. Storage, the projection and
    /// Yjs are untouched; the view re-lays out.
    func setExpanded(_ blockID: String, _ open: Bool) {
        guard open != expanded.contains(blockID) else { return }
        if open { expanded.insert(blockID) } else { expanded.remove(blockID) }
        if refreshFolding() { onFoldChange?() }
    }

    /// Unfolds every collapsed toggle above `blockID`, so it is laid out.
    func reveal(_ blockID: String) {
        var parent = rangeIndex.position(for: blockID).flatMap { blocks[$0].parentID }
        var opened = false
        while let id = parent, let position = rangeIndex.position(for: id) {
            if AttributedDocumentProjection.isToggle(blocks[position]) {
                opened = expanded.insert(id).inserted || opened
            }
            parent = blocks[position].parentID
        }
        if opened, refreshFolding() { onFoldChange?() }
    }

    /// Whether the block at `position` sits inside a collapsed toggle.
    func isHidden(position: Int) -> Bool { hidden.indices.contains(position) && hidden[position] }

    func isHidden(blockID: String) -> Bool { rangeIndex.position(for: blockID).map(isHidden(position:)) ?? false }

    /// The hidden block (or its separator) at a document offset.
    func isHidden(atUTF16 offset: Int) -> Bool {
        rangeIndex.textPosition(atUTF16: offset).map { isHidden(position: $0.position) } ?? false
    }

    /// Each run of hidden blocks as one document range, in order.
    var hiddenRanges: [NSRange] {
        var ranges: [NSRange] = []
        for (position, entry) in rangeIndex.entries.enumerated() where isHidden(position: position) {
            if let last = ranges.last, NSMaxRange(last) == entry.range.location {
                ranges[ranges.count - 1].length += entry.range.length
            } else {
                ranges.append(entry.range)
            }
        }
        return ranges
    }

    /// Recomputes which blocks are hidden (O(document), only after a non-text
    /// patch or a fold change) and opens a toggle that gained a child. True
    /// when the hidden set changed.
    private func refreshFolding() -> Bool {
        var counts: [String: Int] = [:]
        for block in blocks { if let parent = block.parentID { counts[parent, default: 0] += 1 } }
        var toggles: [String: Int] = [:]
        for block in blocks where AttributedDocumentProjection.isToggle(block) {
            let count = counts[block.id] ?? 0
            if let before = toggleChildren[block.id], count > before { expanded.insert(block.id) }
            toggles[block.id] = count
        }
        toggleChildren = toggles
        var next: [Bool] = []
        next.reserveCapacity(blocks.count)
        // The depth of the outermost collapsed toggle being walked: deeper blocks are hidden.
        var folded: Int?
        for block in blocks {
            if let depth = folded, block.depth <= depth { folded = nil }
            next.append(folded != nil || focus.map { !$0.contains(block.id) } == true)
            if folded == nil, AttributedDocumentProjection.isToggle(block), !expanded.contains(block.id) {
                folded = block.depth
            }
        }
        defer { hidden = next }
        return next != hidden
    }

    /// A numbered item's number depends on the blocks above it, so an insert,
    /// removal or type/start change elsewhere can change it. Only the number
    /// attribute is set: no text changes, so UIKit's selection stays put.
    private func renumberLists() {
        for (position, number) in AttributedDocumentProjection.listNumbers(in: blocks).enumerated() {
            guard let number else { continue }
            let range = rangeIndex.entries[position].range
            if storage.attribute(.nativeListNumber, at: range.location, effectiveRange: nil) as? Int != number {
                storage.addAttribute(.nativeListNumber, value: number, range: range)
            }
        }
    }

    /// The block's slice, numbered by the run of numbered siblings it ends
    /// (and, in preorder, their children between them).
    private func rendered(_ block: BlockSnapshot, at position: Int) -> NSAttributedString {
        var first = position
        while first > 0,
            blocks[first - 1].depth > block.depth
                || (blocks[first - 1].depth == block.depth && blocks[first - 1].node == "numberedListItem")
        {
            first -= 1
        }
        let run = Array(blocks[first..<position]) + [block]
        return AttributedDocumentProjection.attributedBlock(
            block, traits: traits, labels: labels,
            listNumber: AttributedDocumentProjection.listNumbers(in: run).last ?? nil, geometry: attachmentGeometry)
    }

    private func applyText(_ deltas: [TextDelta], at position: Int) {
        let entry = rangeIndex.entries[position]
        shownDeltas.append((entry.blockID, deltas))
        var block = blocks[position]
        block.runs = TextDelta.apply(deltas, to: block.runs)
        let rendered = rendered(block, at: position)
        var shift = 0
        var replacements: [(old: NSRange, new: NSRange)] = []
        for delta in deltas {
            // Engine deltas are ordered, non-overlapping pre-change ranges.
            // Compute the corresponding final attributed slice before touching
            // storage, then reverse array order (including same-offset inserts).
            let old = NSRange(location: entry.range.location + delta.range.lowerBound, length: delta.range.count)
            let new = NSRange(location: delta.range.lowerBound + shift, length: delta.replacement.utf16.count)
            replacements.append((old, new))
            shift += new.length - old.length
        }
        for replacement in replacements.reversed() {
            storage.replaceCharacters(in: replacement.old, with: rendered.attributedSubstring(from: replacement.new))
        }
        blocks[position] = block
        rangeIndex.replace(at: position, with: block, labels: labels)
    }

    /// Dynamic Type changes invalidate presentation only, never the replica.
    func updatePresentation(traits: UITraitCollection, labels: NativeEditorLabels) {
        let next = NativeTextPresentation(contentSize: traits.preferredContentSizeCategory, labels: labels)
        // Keep this ahead of every mutation, including replacing cached inputs:
        // selection-driven SwiftUI updates must leave TextKit interactions alone.
        guard presentation != next else { return }
        // A restyle is a programmatic storage edit and would cancel marked text.
        guard !holdsComposition else {
            pendingPresentation = (traits, labels)
            return
        }
        applyPresentation(traits, labels: labels)
    }

    private func applyPresentation(_ traits: UITraitCollection, labels: NativeEditorLabels) {
        presentation = NativeTextPresentation(contentSize: traits.preferredContentSizeCategory, labels: labels)
        self.traits = traits
        attachmentGeometry = geometry(width: attachmentGeometry.width)
        rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
        storage.setAttributedString(
            AttributedDocumentProjection.attributedString(
                blocks: blocks, traits: traits, labels: labels, geometry: attachmentGeometry))
    }

    /// Character-level equality with the model's display (O(document); only
    /// checked after UIKit itself changed storage).
    var storageMatchesModel: Bool {
        storage.length == rangeIndex.length
            && storage.string
                == AttributedDocumentProjection.attributedString(
                    blocks: blocks, traits: traits, labels: labels, geometry: attachmentGeometry
                ).string
    }

    /// Rebuilds storage from the model after UIKit changed it behind the
    /// command path: only `blockID`'s slice when UIKit changed nothing else,
    /// otherwise everything. Never during a composition: marked text owns storage then.
    func restoreStorage(blockID: String? = nil) {
        guard !holdsComposition else { return }
        // UIKit changed only this block's slice, so the length difference is
        // all inside it. Anything else falls back to a full rebuild.
        let delta = storage.length - rangeIndex.length
        if let blockID, let position = rangeIndex.position(for: blockID),
            rangeIndex.entries[position].range.length + delta >= 0
        {
            let entry = rangeIndex.entries[position]
            storage.replaceCharacters(
                in: NSRange(location: entry.range.location, length: entry.range.length + delta),
                with: rendered(blocks[position], at: position))
        } else {
            storage.setAttributedString(
                AttributedDocumentProjection.attributedString(
                    blocks: blocks, traits: traits, labels: labels, geometry: attachmentGeometry))
        }
    }

    /// Holds storage for a composition from its begin. The release puts the
    /// composed block's slice back to the model (dropping UIKit's provisional
    /// text), then applies a restyle that waited.
    func holdForComposition(_ hold: Bool) {
        guard hold != holdsComposition else { return }
        holdsComposition = hold
        guard !hold else { return }
        // Applied like a patch: the selection UIKit moves meanwhile is not the user's.
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        if let id = provisionalBlockID {
            provisionalBlockID = nil
            restoreStorage(blockID: id)
        }
        if let pending = pendingPresentation {
            pendingPresentation = nil
            applyPresentation(pending.traits, labels: pending.labels)
        }
        if let width = pendingAttachmentWidth {
            pendingAttachmentWidth = nil
            pendingGeometryRefresh = false
            updateAttachmentWidth(width)
        } else if pendingGeometryRefresh {
            pendingGeometryRefresh = false
            refreshAttachmentGeometry()
        }
    }

    // MARK: Attachment geometry (PR06e)

    private func collectDocumentTitles(from block: BlockSnapshot, into titles: inout [UUID: String]) {
        for run in block.runs {
            guard case .interlink(let docID, _, _, let disabled, _)? = run.inlineObject,
                !disabled,
                let uuid = UUID(uuidString: docID),
                titles[uuid] == nil,
                let title = documentTitle?(uuid) ?? recordedDocumentTitles[uuid],
                !title.isEmpty
            else { continue }
            titles[uuid] = title
        }
    }

    /// The geometry for `width`, with the current ratio of every image shown
    /// and cached document titles for any inline interlink chips.
    private func geometry(width: CGFloat) -> NativeAttachmentGeometry {
        var next = NativeAttachmentGeometry(width: width)
        for block in blocks {
            if let aspectRatio, AttributedDocumentProjection.isPlaceholder(block),
                case .image(let url, _, _)? = block.preview, let ratio = aspectRatio(url)
            {
                next.aspectRatios[url] = ratio
            }
            collectDocumentTitles(from: block, into: &next.documentTitles)
        }
        return next
    }

    /// Recomputes cached image aspect ratios and linked document titles without
    /// changing the width or writing to Yjs.
    func refreshAttachmentGeometry() {
        guard !holdsComposition else {
            pendingGeometryRefresh = true
            return
        }
        pendingGeometryRefresh = false
        let next = geometry(width: attachmentGeometry.width)
        guard next != attachmentGeometry else { return }
        attachmentGeometry = next
        let positions = blocks.indices.filter {
            AttributedDocumentProjection.isPlaceholder(blocks[$0]) || blocks[$0].hasInlineObjects
        }
        restyleAttachments(positions: positions)
    }

    /// The text container's usable width changed (first layout, rotation,
    /// split view). Only attachment paragraphs are restyled, each in place
    /// with the same one character, so text, offsets and the selection stay;
    /// nothing reaches Yjs. Deferred while text is marked.
    func updateAttachmentWidth(_ width: CGFloat) {
        let width = width.rounded(.down)
        guard width > 0 else { return }
        guard !holdsComposition else {
            pendingAttachmentWidth = width
            return
        }
        pendingGeometryRefresh = false
        let next = geometry(width: width)
        guard next != attachmentGeometry else { return }
        attachmentGeometry = next
        let positions = blocks.indices.filter {
            AttributedDocumentProjection.isPlaceholder(blocks[$0]) || blocks[$0].hasInlineObjects
        }
        restyleAttachments(positions: positions)
    }

    private func restyleAttachments(positions: [Int]) {
        guard !positions.isEmpty else { return }
        isApplyingPatch = true
        defer { isApplyingPatch = false }
        storage.beginEditing()
        for position in positions {
            let range = rangeIndex.entries[position].range
            let rendered = rendered(blocks[position], at: position)
            if !storage.attributedSubstring(from: range).isEqual(to: rendered) {
                storage.replaceCharacters(in: range, with: rendered)
            }
        }
        storage.endEditing()
    }

    private func replace(at position: Int, with block: BlockSnapshot) {
        shownReplaced.insert(block.id)
        if blocks[position].runs.map(\.text).joined() != block.runs.map(\.text).joined() {
            shownRetexted.insert(block.id)
        }
        collectDocumentTitles(from: block, into: &attachmentGeometry.documentTitles)
        storage.replaceCharacters(
            in: rangeIndex.entries[position].range,
            with: rendered(block, at: position))
        blocks[position] = block
        rangeIndex.replace(at: position, with: block, labels: labels)
    }
}
