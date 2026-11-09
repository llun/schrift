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
/// **One rule for `.text`.** A block gets a `.text` patch only when all three
/// hold: it has no nested children; its content element has exactly one child,
/// an `XmlText` (no inline nodes, no sibling text children); and the only change
/// to it in this transaction is that text. Everything else touched in a block —
/// attributes, structure, a container replacement, a nested change — becomes a
/// `.replaceBlock` of the top-level block from its projection. A props-only
/// change is still `.props`. A fragment-root or root-group replacement is a
/// `.reset` of the whole surface.
struct PatchBuilder {
    let doc: YDoc
    private(set) var index: BlockIndex
    /// Blocks projected into snapshots — the O(touched blocks) counter.
    private(set) var projectedBlocks = 0
    /// Changed types classified — the other half of the counter.
    private(set) var visitedTypes = 0
    /// Index entries visited while emitting — proves the emit loop is
    /// O(touched), not O(document).
    private(set) var visitedEntries = 0

    init(doc: YDoc, index: BlockIndex? = nil) {
        self.doc = doc
        self.index = index ?? BlockIndex(doc: doc)
    }

    mutating func build(_ transaction: YTransaction) -> BlockPatch {
        let origin = BlockPatchOrigin(transaction.origin)
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
        var resync = rootAppeared || !index.isCanonical

        func touch(_ id: String) {
            if !touched.contains(id) { touched.append(id) }
        }

        for case let oid? in transaction.changedOrder {
            guard let entry = transaction.changed[oid] else { continue }
            visitedTypes += 1
            let type = entry.type
            // The fragment root itself: a root-group add, remove or replacement
            // has no block-relative spelling. Resync the whole surface.
            if type.item == nil {
                resync = true
                continue
            }
            if type.typeRef == .xmlText {
                guard let id = index.blockID(for: type) else { continue }
                touch(id)
                // The narrowed rule: only a simple container whose element is
                // exactly this XmlText may take the fast path.
                // `isProjectable` is the pre-transaction state (the entry was
                // refreshed after the last one): when the projection dropped or
                // scrubbed content, the surface's runs are not the text's, so a
                // delta computed from the text would not line up.
                // The deltas must turn the surface's runs into exactly what the
                // projection now folds: the event delta compares marks as a set,
                // so a mark re-opened in another order, or a link value spelled
                // differently, on retained text has no delta of its own.
                if let block = index.entries[id], block.isSimpleText, block.isProjectable, block.textType === type,
                    let element = block.element, YBlockProjection.props(of: element) != nil,
                    let deltas = Self.textDeltas(events[oid], text: type),
                    let runs = YBlockProjection.textRuns(type),
                    TextDelta.apply(deltas, to: block.runs) == runs
                {
                    textDeltas[id] = deltas
                } else {
                    structural.insert(id)
                }
                continue
            }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") {
                if index.isRootGroup(type) {
                    // A new root-group object is a replacement, not a diff.
                    if index.rootGroupItem !== type.item { resync = true }
                    groups.append(type)
                    rootGroupChanged = true
                } else if let id = index.blockID(for: type) {
                    touch(id)
                    structural.insert(id)
                }
                continue
            }
            // A container's `id` changed in place (possibly to an unreadable
            // value): the block's identity moved, which only a resync says.
            if type.typeRef == .xmlElement(nodeName: "blockContainer"), entry.subs.contains("id") {
                resync = true
                continue
            }
            guard let id = index.blockID(for: type) else { continue }
            touch(id)
            if type.typeRef == .xmlElement(nodeName: "blockContainer") || entry.subs.contains(nil) {
                structural.insert(id)
            } else if let block = index.entries[id], block.element === type, block.isSimpleContainer,
                block.isProjectable
            {
                props.insert(id)
            } else {
                // A nested element's attributes are not the top-level block's.
                structural.insert(id)
            }
        }

        // A root-group change that leaves a shape the index cannot mirror
        // (an id-less or duplicate container, a stray child) resyncs too.
        if resync || groups.contains(where: { !BlockIndex.isCanonical(group: $0) }) {
            let blocks = YBlockProjection.project(doc, nativeMarks: true).blocks.map(BlockSnapshot.init)
            index.rebuild()
            return BlockPatch([.reset(blocks)], origin: origin)
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
                        // Same id, different container object: the block was
                        // replaced in place. Membership alone cannot see it.
                        if index.entries[id]?.containerItem !== item {
                            index.setContainer(id, item: item)
                            touch(id)
                            structural.insert(id)
                        }
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

        // Iterate the touched ids only, in document order — never `index.order`.
        // A removed id (a reorder removes them all) is re-inserted, if at all,
        // as a fresh snapshot: a per-block change for it would address a block
        // the same patch just took away.
        let removedSet = Set(removed)
        let ordered = touched.filter { !removedSet.contains($0) }.sorted {
            (index.position[$0] ?? Int.max) < (index.position[$1] ?? Int.max)
        }
        for id in ordered {
            visitedEntries += 1
            if structural.contains(id) || (props.contains(id) && textDeltas[id] != nil) {
                guard let entry = index.entries[id] else { continue }
                changes.append(.replaceBlock(blockID: id, block: snapshot(entry.containerItem)))
            } else if props.contains(id), let entry = index.entries[id] {
                // Unreadable props make the projection opaque (no props, no
                // runs): only a whole-block patch says that.
                if let element = entry.element, let blockProps = YBlockProjection.props(of: element) {
                    changes.append(.props(blockID: id, props: blockProps))
                } else {
                    changes.append(.replaceBlock(blockID: id, block: snapshot(entry.containerItem)))
                }
            } else if let deltas = textDeltas[id], !deltas.isEmpty {
                changes.append(.text(blockID: id, deltas: deltas))
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
        return BlockPatch(changes, origin: origin)
    }

    private mutating func snapshot(_ item: YItem) -> BlockSnapshot {
        projectedBlocks += 1
        return BlockSnapshot(YBlockProjection.projectBlock(item, nativeMarks: true))
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
        // An embed or an unreadable link anywhere in the text makes the
        // projection opaque (no runs): no `.text` delta can say that.
        guard BlockIndex.projectsAsText(text) else { return nil }
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
    /// text carrying the marks the replica now holds, one delta per run of
    /// uniform marks, so a mixed range is still a marks-only `.text` patch.
    private static func formatDeltas(_ delta: [YDeltaOp], text: YType) -> [TextDelta]? {
        guard let units = textUnits(text) else { return nil }
        var cursor = 0
        var out: [TextDelta] = []
        for op in delta {
            guard case .retain(let length) = op.kind else { continue }
            let range = cursor..<(cursor + Int(length))
            cursor = range.upperBound
            guard op.attributes != nil else { continue }
            guard range.upperBound <= units.count, let runs = markRuns(in: text, range: range) else { return nil }
            for run in runs {
                out.append(
                    TextDelta(
                        range: run.range, replacement: String(decoding: units[run.range], as: UTF16.self),
                        marks: run.marks))
            }
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
        guard let runs = markRuns(in: text, range: range), runs.count <= 1 else { return nil }
        return runs.first?.marks ?? []
    }

    /// `range` split into maximal runs of equal marks, in order, or `nil` when
    /// the text holds something other than strings and formats.
    private static func markRuns(in text: YType, range: Range<Int>) -> [(range: Range<Int>, marks: [TextMark])]? {
        var open: [(key: String, valueJSON: String)] = []
        var index = 0
        var runs: [(range: Range<Int>, marks: [TextMark])] = []
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
                let lower = max(index, range.lowerBound)
                let upper = min(end, range.upperBound)
                if lower < upper {
                    let marks = open.map { TextMark(key: $0.key, valueJSON: $0.valueJSON) }
                    if let last = runs.last, last.marks == marks, last.range.upperBound == lower {
                        runs[runs.count - 1].range = last.range.lowerBound..<upper
                    } else {
                        runs.append((lower..<upper, marks))
                    }
                }
                index = end
            default:
                return nil
            }
        }
        return runs
    }
}
