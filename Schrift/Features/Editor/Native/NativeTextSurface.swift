import UIKit

/// Value inputs that can actually change the attributed projection. UIKit
/// trait collections carry other traits and need not have stable identity.
struct NativeTextPresentation: Equatable {
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels
}

/// A non-optimistic consumer: all origins apply, and identified command echoes
/// reconcile exactly once per emission. Only the changed
/// text ranges are replaced; props/replacements rebuild one block's slice.
/// A reset is the only patch that replaces the full document storage.
@MainActor
final class NativeTextSurface: @preconcurrency EditorSurface {
    let storage: NSTextStorage
    private(set) var blocks: [BlockSnapshot]
    private(set) var rangeIndex: ProjectionRangeIndex
    private(set) var traits: UITraitCollection
    private var presentation: NativeTextPresentation
    private var lastNativeStamp: NativePatchStamp?
    /// UIKit owns the marked range while a composition is active. Any
    /// programmatic storage edit — a peer patch, a restyle, a selection
    /// publication — can cancel it, so patches are buffered and presentation
    /// changes deferred until the engine's final deferral-complete signal.
    private var isFrozen = false
    private var frozenPatches: [BlockPatch] = []
    /// The block whose storage slice UIKit's marked text changed. Set by the
    /// composition session before the engine freezes; reconciliation rebuilds
    /// only this slice, so the rest of storage (and the scroll position) is
    /// never replaced.
    var provisionalBlockID: String?
    private var pendingPresentation: (traits: UITraitCollection, labels: NativeEditorLabels)?
    /// Replica-backed surfaces use the owner's settled projection to validate
    /// fast patches. Value-only fixtures may omit this callback.
    private let reprojectBlock: ((String) -> BlockSnapshot?)?
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
            AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels))
        _ = refreshFolding()
    }

    func applyPatch(_ patch: BlockPatch) {
        guard !isFrozen else {
            frozenPatches.append(patch)
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
                if let reprojectBlock {
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
                if let reprojectBlock {
                    guard let fresh = reprojectBlock(id) else { continue }
                    replace(at: position, with: fresh)
                    continue
                }
                var block = blocks[position]
                block.props = props
                replace(at: position, with: block)
            case .replaceBlock(let id, let block):
                guard let position = rangeIndex.position(for: id) else { continue }
                replace(at: position, with: block)
            case .remove(let ids):
                let removed = Set(ids)
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
                let position = after.flatMap { rangeIndex.position(for: $0) }.map { $0 + 1 } ?? 0
                let offset =
                    position < rangeIndex.entries.count ? rangeIndex.entries[position].range.location : storage.length
                storage.insert(
                    AttributedDocumentProjection.attributedString(blocks: fresh, traits: traits, labels: labels),
                    at: offset)
                blocks.insert(contentsOf: fresh, at: position)
                rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
            case .reset(let reset):
                blocks = reset
                rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
                storage.setAttributedString(
                    AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels))
            }
        }
        if renumbers {
            renumberLists()
            // Only a non-text patch moves, adds or retypes a block.
            foldChanged = refreshFolding()
        }
    }

    func isExpanded(_ blockID: String) -> Bool { expanded.contains(blockID) }

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
            next.append(folded != nil)
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
            listNumber: AttributedDocumentProjection.listNumbers(in: run).last ?? nil)
    }

    private func applyText(_ deltas: [TextDelta], at position: Int) {
        let entry = rangeIndex.entries[position]
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
        guard !isFrozen else {
            pendingPresentation = (traits, labels)
            return
        }
        applyPresentation(traits, labels: labels)
    }

    private func applyPresentation(_ traits: UITraitCollection, labels: NativeEditorLabels) {
        presentation = NativeTextPresentation(contentSize: traits.preferredContentSizeCategory, labels: labels)
        self.traits = traits
        rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
        storage.setAttributedString(
            AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels))
    }

    /// Character-level equality with the model's display (O(document); only
    /// checked after UIKit itself changed storage).
    var storageMatchesModel: Bool {
        storage.length == rangeIndex.length
            && storage.string
                == AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels).string
    }

    /// Rebuilds storage from the model after UIKit changed it behind the
    /// command path: only `blockID`'s slice when UIKit changed nothing else,
    /// otherwise everything. Never while frozen: marked text owns storage then.
    func restoreStorage(blockID: String? = nil) {
        guard !isFrozen else { return }
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
                AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels))
        }
    }

    /// The engine's composition window. While frozen, UIKit's provisional text
    /// is the only storage change; the model stays at the pre-composition state
    /// and every patch is buffered. Completion reconciles once: restore the
    /// model's display of the provisional block (dropping provisional text),
    /// apply the buffered patches at model coordinates, then apply any
    /// deferred restyle.
    func setCompositionDeferred(_ deferred: Bool) {
        if deferred {
            isFrozen = true
            return
        }
        guard isFrozen else { return }
        isFrozen = false
        reconcile()
    }

    private func reconcile() {
        if let id = provisionalBlockID {
            provisionalBlockID = nil
            restoreStorage(blockID: id)
        }
        let patches = frozenPatches
        frozenPatches = []
        for patch in patches { applyPatch(patch) }
        if let pending = pendingPresentation {
            pendingPresentation = nil
            applyPresentation(pending.traits, labels: pending.labels)
        }
    }

    private func replace(at position: Int, with block: BlockSnapshot) {
        storage.replaceCharacters(
            in: rangeIndex.entries[position].range,
            with: rendered(block, at: position))
        blocks[position] = block
        rangeIndex.replace(at: position, with: block, labels: labels)
    }
}
