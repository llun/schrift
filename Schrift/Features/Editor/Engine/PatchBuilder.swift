import Foundation

/// Turns one transaction's change signal into a `BlockPatch`.
///
/// **O(touched blocks).** The classification reads `transaction.changed` — the
/// types whose *direct* children changed — so a keystroke visits one `XmlText`
/// and projects no block at all. Only a structural change (a group's child list
/// moved) walks that group, and only a block the delta cannot express is
/// projected, one block at a time (`YBlockProjection.projectBlock`). The
/// counters below are the test seam for that claim.
///
/// The delta rules, in order of preference:
/// - a block whose only change is an `XmlText` → `.text`, mapped from the
///   `YTextEvent` delta (insert/delete with marks; a pure format change becomes
///   a replacement of the range's own text carrying the resulting marks);
/// - a block whose content element only changed attributes → `.props`;
/// - anything else (inline nodes, split/join, a type change, a mixed
///   text-and-format delta, a non-uniform format range) → `.replaceBlock`,
///   rebuilt from a projection of that block alone.
struct PatchBuilder {
    let doc: YDoc
    private(set) var index: BlockIndex
    /// Blocks projected into snapshots — the O(touched blocks) counter.
    private(set) var projectedBlocks = 0
    /// Changed types classified — the other half of the counter.
    private(set) var visitedTypes = 0

    init(doc: YDoc, index: BlockIndex? = nil) {
        self.doc = doc
        self.index = index ?? BlockIndex(doc: doc)
    }

    mutating func build(_ transaction: YTransaction) -> BlockPatch {
        let rootAppeared = index.resolveRoot()
        var events: [ObjectIdentifier: YEvent] = [:]
        for entry in transaction.changedParentTypes {
            if let event = entry.events.first { events[ObjectIdentifier(entry.type)] = event }
        }

        var textDeltas: [String: [TextDelta]] = [:]
        var structural: Set<String> = []
        var props: Set<String> = []
        var touched: [String] = []
        var groups: [YType] = []
        var rootGroupChanged = false

        func touch(_ id: String) {
            if !touched.contains(id) { touched.append(id) }
        }

        for case let oid? in transaction.changedOrder {
            guard let entry = transaction.changed[oid] else { continue }
            visitedTypes += 1
            let type = entry.type
            if type.typeRef == .xmlText {
                guard let id = index.blockID(for: type) else { continue }
                touch(id)
                // Only the block's own content text may become a `.text` patch.
                // Text in a nested block or a nested group is not addressable at
                // this block's offsets: rebuild the top-level block instead.
                if index.entries[id]?.textTypes.contains(where: { $0 === type }) == true,
                    let deltas = Self.textDeltas(events[oid], text: type)
                {
                    textDeltas[id] = deltas
                } else {
                    structural.insert(id)
                }
                continue
            }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") {
                if index.isRootGroup(type) {
                    groups.append(type)
                    rootGroupChanged = true
                } else if let id = index.blockID(for: type) {
                    // A nested group's child list moved: the top-level block's
                    // projection changed, and only a whole-block patch can say so.
                    touch(id)
                    structural.insert(id)
                }
                continue
            }
            // The fragment root itself: its child list is the root group, whose
            // own entry carries any membership change.
            if type.item == nil { continue }
            guard let id = index.blockID(for: type) else { continue }
            touch(id)
            if type.typeRef == .xmlElement(nodeName: "blockContainer") || entry.subs.contains(nil) {
                structural.insert(id)
            } else {
                props.insert(id)
            }
        }

        // An engine created on an empty document sees the root appear inside a
        // transaction whose group may not be in `changed`: the whole block list
        // is new, so diff it against the empty index.
        if rootAppeared, let group = index.rootGroupType(), !groups.contains(where: { $0 === group }) {
            groups.append(group)
            rootGroupChanged = true
        }

        var changes: [BlockChange] = []
        var removed: [String] = []
        var inserts: [(after: String?, blocks: [BlockSnapshot])] = []

        for group in groups {
            let current = index.containers(in: group)
            let previous = index.groupOrder[ObjectIdentifier(group)] ?? []
            let currentIDs = current.map(\.id)
            let previousSet = Set(previous)
            let currentSet = Set(currentIDs)
            let survivorsInPreviousOrder = previous.filter { currentSet.contains($0) }
            let survivorsInCurrentOrder = currentIDs.filter { previousSet.contains($0) }
            if survivorsInPreviousOrder != survivorsInCurrentOrder {
                // A reorder. The surface holds an ordered list, so the only
                // patch that expresses a move is remove-then-insert; moves are
                // rare and correctness beats a minimal diff.
                removed.append(contentsOf: previous)
                inserts.append((nil, current.map { snapshot($0.item) }))
            } else {
                removed.append(contentsOf: previous.filter { !currentSet.contains($0) })
                var pending: [BlockSnapshot] = []
                var after: String?
                for (id, item) in current {
                    if previousSet.contains(id) {
                        if !pending.isEmpty {
                            inserts.append((after, pending))
                            pending = []
                        }
                        after = id
                    } else {
                        pending.append(snapshot(item))
                    }
                }
                if !pending.isEmpty { inserts.append((after, pending)) }
            }
            index.setGroupOrder(group, currentIDs)
        }

        for id in index.order where touched.contains(id) {
            if structural.contains(id) {
                guard let entry = index.entries[id] else { continue }
                changes.append(.replaceBlock(blockID: id, block: snapshot(entry.containerItem)))
            } else {
                // Props and text are independent: one transaction may change
                // both, and dropping either leaves the surface stale.
                if props.contains(id), let element = index.entries[id]?.element {
                    changes.append(.props(blockID: id, props: YBlockProjection.props(of: element) ?? []))
                }
                if let deltas = textDeltas[id], !deltas.isEmpty {
                    changes.append(.text(blockID: id, deltas: deltas))
                }
            }
        }

        if !removed.isEmpty { changes.insert(.remove(blockIDs: removed), at: 0) }
        for insert in inserts { changes.append(.insert(after: insert.after, blocks: insert.blocks)) }

        // Only a root-group change alters the block list; a nested change leaves
        // the index's entries valid, so it never pays for a rebuild.
        if rootGroupChanged {
            index.rebuild()
        } else {
            for id in touched { index.refresh(id) }
        }
        return BlockPatch(changes)
    }

    private mutating func snapshot(_ item: YItem) -> BlockSnapshot {
        projectedBlocks += 1
        return BlockSnapshot(YBlockProjection.projectBlock(item))
    }

    // MARK: - Delta mapping

    /// Maps a `YTextEvent` delta to block-relative `TextDelta`s, or `nil` when
    /// the change is not expressible as text replacement.
    static func textDeltas(_ event: YEvent?, text: YType) -> [TextDelta]? {
        guard let event, let delta = event.delta else { return nil }
        var changesText = false
        var changesMarks = false
        for op in delta {
            switch op.kind {
            case .insert, .delete: changesText = true
            case .retain: if op.attributes != nil { changesMarks = true }
            }
        }
        // A delta that both rewrites text and re-marks it has no single
        // pre-change coordinate space; the block is rebuilt instead.
        if changesText && changesMarks { return nil }
        if changesMarks { return formatDeltas(delta, text: text) }
        var oldCursor = 0
        var newCursor = 0
        var out: [TextDelta] = []
        for op in delta {
            switch op.kind {
            case .retain(let length):
                oldCursor += Int(length)
                newCursor += Int(length)
            case .delete(let length):
                out.append(TextDelta(range: oldCursor..<(oldCursor + Int(length)), replacement: ""))
                oldCursor += Int(length)
            case .insert(let value):
                guard case .text(let string) = value else { return nil }
                let length = string.utf16.count
                // Marks come from the text itself, in format-item order, so the
                // surface's run order matches the projection's. `[]` is explicit:
                // an insertion with no marks in force must not inherit the marks
                // to its right. A non-uniform range is not one delta.
                guard let marks = uniformMarks(in: text, range: newCursor..<(newCursor + length)) else {
                    return nil
                }
                out.append(TextDelta(range: oldCursor..<oldCursor, replacement: string, marks: marks))
                newCursor += length
            }
        }
        return out
    }

    /// A pure format change: each retained range is replaced by its own current
    /// text carrying the marks the replica now holds. A range whose marks are
    /// not uniform cannot be one `TextDelta`, so the block is rebuilt.
    private static func formatDeltas(_ delta: [YDeltaOp], text: YType) -> [TextDelta]? {
        guard let units = textUnits(text) else { return nil }
        var cursor = 0
        var out: [TextDelta] = []
        for op in delta {
            guard case .retain(let length) = op.kind else { continue }
            let range = cursor..<(cursor + Int(length))
            cursor = range.upperBound
            guard op.attributes != nil else { continue }
            guard range.upperBound <= units.count else { return nil }
            guard let marks = uniformMarks(in: text, range: range) else { return nil }
            out.append(
                TextDelta(
                    range: range, replacement: String(decoding: units[range], as: UTF16.self), marks: marks))
        }
        return out
    }

    /// The text's current UTF-16 units, or `nil` when it holds something other
    /// than strings and formats (an embed or an inline element).
    private static func textUnits(_ text: YType) -> [UInt16]? {
        var units: [UInt16] = []
        var item = text.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted else { continue }
            switch current.content {
            case .string(let value): units.append(contentsOf: value)
            case .format: continue
            default: return nil
            }
        }
        return units
    }

    /// The marks in force over `range`, or `nil` when they are not uniform.
    private static func uniformMarks(in text: YType, range: Range<Int>) -> [TextMark]? {
        var open: [(key: String, valueJSON: String)] = []
        var index = 0
        var result: [TextMark]?
        var item = text.start
        while let current = item, index < range.upperBound {
            defer { item = current.right }
            guard !current.deleted else { continue }
            switch current.content {
            case .format(let key, let valueJSON):
                open.removeAll { $0.key == key }
                if valueJSON != "null" { open.append((key, valueJSON)) }
            case .string(let units):
                let end = index + units.count
                if end > range.lowerBound {
                    let marks = open.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) }
                    if let result, result != marks { return nil }
                    result = marks
                }
                index = end
            default:
                return nil
            }
        }
        return result ?? []
    }
}
