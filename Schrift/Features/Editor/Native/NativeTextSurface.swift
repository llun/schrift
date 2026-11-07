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
    /// Replica-backed surfaces use the owner's settled projection to validate
    /// fast patches. Value-only fixtures may omit this callback.
    private let reprojectBlock: ((String) -> BlockSnapshot?)?
    var labels: NativeEditorLabels { presentation.labels }

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
    }

    func applyPatch(_ patch: BlockPatch) {
        if patch.origin == .localUser, let stamp = patch.nativeCommand {
            if let last = lastNativeStamp,
                stamp.baseRevision < last.baseRevision
                    || (stamp.commandID == last.commandID && stamp.emission <= last.emission)
            {
                return
            }
            lastNativeStamp = stamp
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        for change in patch.changes {
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
    }

    private func applyText(_ deltas: [TextDelta], at position: Int) {
        let entry = rangeIndex.entries[position]
        var block = blocks[position]
        block.runs = TextDelta.apply(deltas, to: block.runs)
        let rendered = AttributedDocumentProjection.attributedBlock(block, traits: traits, labels: labels)
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
        presentation = next
        self.traits = traits
        rangeIndex = ProjectionRangeIndex(blocks: blocks, labels: labels)
        storage.setAttributedString(
            AttributedDocumentProjection.attributedString(blocks: blocks, traits: traits, labels: labels))
    }

    private func replace(at position: Int, with block: BlockSnapshot) {
        storage.replaceCharacters(
            in: rangeIndex.entries[position].range,
            with: AttributedDocumentProjection.attributedBlock(block, traits: traits, labels: labels))
        blocks[position] = block
        rangeIndex.replace(at: position, with: block, labels: labels)
    }
}
