import Foundation

/// Turns one transaction's change signal into a `BlockPatch`.
///
/// **O(touched blocks).** The classification reads `transaction.changed` — the
/// types whose *direct* children changed — so a keystroke visits one `XmlText`
/// and projects no block at all. Only a tree change (a group's child list or a
/// container's children changed) rebuilds the index and diffs its preorder,
/// and only a block the delta cannot express is projected, one block at a time
/// (`NativeBlockProjection.projectBlock`). The counters below are the test
/// seam for that claim.
///
/// **One rule for `.text`.** A block, at any depth, gets a `.text` patch only
/// when all three hold: its container holds its content element (and at most
/// one nested group); that element has exactly one child, an `XmlText` (no
/// inline nodes, no sibling text children); and the only change to it in this
/// transaction is that text. Everything else touched in a block — attributes,
/// structure, a container replacement, a move to another depth or parent —
/// becomes a `.replaceBlock` of that block from its projection. A props-only
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

    mutating func openTable(_ id: String) -> Bool { index.openTable(id) }

    mutating func closeTable(_ id: String) { index.closeTable(id) }

    mutating func openColumns(_ id: String) -> Bool { index.openColumns(id) }

    mutating func closeColumns(_ id: String) { index.closeColumns(id) }

    @discardableResult
    mutating func openSource(_ target: SourceTarget) -> String? { index.openSource(target) }

    mutating func closeSource(_ id: String) { index.closeSource(id) }

    func sourceSnapshot(_ id: String) -> [BlockSnapshot]? {
        guard index.isSourceText(id), let entry = index.entries[id] else { return nil }
        return [BlockSnapshot(Self.sourceSnapshot(entry))]
    }

    mutating func build(_ transaction: YTransaction) -> BlockPatch {
        let origin = BlockPatchOrigin(transaction.origin)
        // Open tables (PR11a): their paragraph lists before this transaction.
        let previousTables = index.openTables
        var changedTables: Set<String> = []
        // Open source surfaces (PR14): their synthetic ids before this transaction.
        let previousSources = index.openSources
        var changedSources: Set<String> = []
        // Open column groups (PR12a): which column each block was in.
        let previousColumnOf = index.columnOf
        let rootAppeared = index.resolveRoot()
        var events: [ObjectIdentifier: YEvent] = [:]
        for entry in transaction.changedParentTypes {
            if let event = entry.events.first { events[ObjectIdentifier(entry.type)] = event }
        }

        var textDeltas: [String: [TextDelta]] = [:]
        var structural: Set<String> = []
        var props: Set<String> = []
        var touched: [String] = []
        var treeChanged = false
        var resync = rootAppeared || !index.isCanonical

        func touch(_ id: String) {
            if !touched.contains(id) { touched.append(id) }
        }

        func touchSourceOwner(_ ownerID: String, element: YType?) {
            if index.entries[ownerID] != nil {
                touch(ownerID)
                structural.insert(ownerID)
                if let table = TableGrid.tableID(ofParagraph: ownerID) { changedTables.insert(table) }
                return
            }
            var ancestor = element?.item?.parentType
            while let candidate = ancestor {
                if candidate.typeRef == .xmlElement(nodeName: "blockContainer")
                    || candidate.typeRef == .xmlElement(nodeName: "columnList"),
                    let ancestorID = BlockIndex.blockID(of: candidate), index.entries[ancestorID] != nil
                {
                    touch(ancestorID)
                    structural.insert(ancestorID)
                    return
                }
                ancestor = candidate.item?.parentType
            }
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
                if index.openTables[id] != nil { changedTables.insert(id) }
                if let openSource = index.openSources[id] {
                    changedSources.insert(id)
                    touchSourceOwner(openSource.target.ownerID, element: index.entries[id]?.element)
                }
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
                    !index.isSourceText(id) || runs.allSatisfy({ $0.marks.isEmpty }),
                    TextDelta.apply(deltas, to: block.runs) == runs
                {
                    textDeltas[id] = deltas
                } else {
                    structural.insert(id)
                }
                continue
            }
            if type.typeRef == .xmlElement(nodeName: "blockGroup") {
                // A new root-group object is a replacement, not a diff.
                if index.isRootGroup(type), index.rootGroupItem !== type.item { resync = true }
                // Membership of any group, root or nested: the preorder diff
                // below says which blocks came, went or moved.
                treeChanged = true
                // A group inside a closed column group: that group's preview (PR12a).
                if let id = index.blockID(for: type), index.isColumnGroup(id) {
                    touch(id)
                    structural.insert(id)
                }
                continue
            }
            // A column's or a column group's child list (PR12a): the group's
            // preview; an open group also re-reads its columns' lists, below.
            if type.typeRef == .xmlElement(nodeName: "column") || type.typeRef == .xmlElement(nodeName: "columnList"),
                entry.subs.contains(nil)
            {
                if let id = index.blockID(for: type) {
                    touch(id)
                    structural.insert(id)
                    if index.openGroups[id] != nil { treeChanged = true }
                }
                continue
            }
            // A container's `id` changed in place (possibly to an unreadable
            // value): the block's identity moved, which only a resync says.
            if type.typeRef == .xmlElement(nodeName: "blockContainer"), entry.subs.contains("id") {
                resync = true
                continue
            }
            // A cell's attributes (PR11c): its paragraphs carry its alignment,
            // so they are projected again; the table's change follows below.
            if type.typeRef == .xmlElement(nodeName: "tableCell")
                || type.typeRef == .xmlElement(nodeName: "tableHeader"),
                entry.subs.contains(where: { $0 != nil })
            {
                for child in YBlockProjection.children(of: type, includeFormats: false) {
                    guard case .type(let paragraph) = child.content, let id = index.blockID(for: paragraph),
                        index.isTableParagraph(id)
                    else { continue }
                    touch(id)
                    structural.insert(id)
                }
            }
            guard let id = index.blockID(for: type) else { continue }
            touch(id)
            // An open source element (`mathBlock`, `diagram`, or inline `math`):
            // child text creation/removal or attribute changes re-validate the
            // open source and refresh its owning card/paragraph.
            if let openSource = index.openSources[id] {
                changedSources.insert(id)
                if entry.subs.contains(nil) { treeChanged = true }
                structural.insert(id)
                touchSourceOwner(openSource.target.ownerID, element: type)
                continue
            }
            // A table paragraph's element changed (its first text, a break,
            // an attribute): rebuild that paragraph. Anything else inside an
            // open table re-reads its paragraph list below.
            if index.isTableParagraph(id) {
                structural.insert(id)
                continue
            }
            if index.openTables[id] != nil { changedTables.insert(id) }
            if type.typeRef == .xmlElement(nodeName: "blockContainer") || entry.subs.contains(nil) {
                // A container's child list (a nested group added or removed)
                // is a tree change too; its own shape may also have changed.
                if type.typeRef == .xmlElement(nodeName: "blockContainer"), entry.subs.contains(nil) {
                    treeChanged = true
                }
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

        if resync { return reset(origin) }

        var changes: [BlockChange] = []
        var removed: [String] = []
        var inserted: Set<String> = []
        var inserts: [(after: String?, blocks: [BlockSnapshot])] = []
        // An open group's columns, diffed like the document (PR12a).
        var columnRemoved: [String] = []
        var columnInserted: Set<String> = []
        var columnInserts: [(after: String?, blocks: [BlockSnapshot])] = []

        if treeChanged {
            let previous = index
            index.rebuild()
            // A shape the id-keyed index cannot mirror (an id-less or repeated
            // container, a stray group child) resyncs.
            guard index.isCanonical else { return reset(origin) }
            // Blocks kept in place: in both orders, and in the same relative
            // order. When survivors were reordered (a peer's move), the span
            // between the common prefix and suffix is removed and reinserted.
            var kept = Set(previous.order).intersection(index.order)
            let before = previous.order.filter(kept.contains)
            let after = index.order.filter(kept.contains)
            if before != after {
                var prefix = 0
                while before[prefix] == after[prefix] { prefix += 1 }
                var suffix = 0
                while before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
                kept.subtract(before[prefix..<(before.count - suffix)])
            }
            removed = previous.order.filter { !kept.contains($0) }
            var pending: [BlockSnapshot] = []
            var anchor: String?
            for id in index.order {
                guard let entry = index.entries[id] else { continue }
                guard kept.contains(id), let old = previous.entries[id] else {
                    inserted.insert(id)
                    pending.append(snapshot(entry))
                    continue
                }
                if !pending.isEmpty {
                    inserts.append((anchor, pending))
                    pending = []
                }
                anchor = id
                // Same id, another container (a clone-and-delete move or an
                // in-place replacement), or a new depth/parent.
                if old.containerItem !== entry.containerItem || old.depth != entry.depth
                    || old.parentID != entry.parentID
                {
                    touch(id)
                    structural.insert(id)
                }
            }
            if !pending.isEmpty { inserts.append((anchor, pending)) }
            // Each open column's list, against its list before (a block a
            // peer moved to another column leaves one and enters the other).
            for column in Set(previous.columnOrders.keys).union(index.columnOrders.keys).sorted() {
                let (gone, added) = Self.diff(previous.columnOrders[column] ?? [], index.columnOrders[column] ?? [])
                columnRemoved += (previous.columnOrders[column] ?? []).filter(gone.contains)
                for insert in added {
                    columnInserted.formUnion(insert.ids)
                    columnInserts.append(
                        (insert.after, insert.ids.compactMap { id in index.entries[id].map { snapshot($0) } }))
                }
                for id in index.columnOrders[column] ?? [] where !columnInserted.contains(id) {
                    guard let old = previous.entries[id], let entry = index.entries[id] else { continue }
                    if old.containerItem !== entry.containerItem || old.depth != entry.depth
                        || old.parentID != entry.parentID
                    {
                        touch(id)
                        structural.insert(id)
                    }
                }
            }
        }

        // Iterate the touched ids only, in document order — never `index.order`.
        // A removed id (a reorder removes them all) is re-inserted, if at all,
        // as a fresh snapshot: a per-block change for it would address a block
        // the same patch just took away.
        let removedSet = Set(removed).union(columnRemoved)
        let ordered = touched.filter {
            !removedSet.contains($0) && !inserted.contains($0) && !columnInserted.contains($0)
        }.sorted {
            (index.position[$0] ?? Int.max) < (index.position[$1] ?? Int.max)
        }
        for id in ordered {
            visitedEntries += 1
            if structural.contains(id) || (props.contains(id) && textDeltas[id] != nil) {
                guard let entry = index.entries[id] else { continue }
                changes.append(.replaceBlock(blockID: id, block: snapshot(entry)))
            } else if props.contains(id), let entry = index.entries[id] {
                // Unreadable props make the projection opaque (no props, no
                // runs): only a whole-block patch says that.
                if let element = entry.element, let blockProps = YBlockProjection.props(of: element) {
                    changes.append(.props(blockID: id, props: blockProps))
                } else {
                    changes.append(.replaceBlock(blockID: id, block: snapshot(entry)))
                }
            } else if let deltas = textDeltas[id], !deltas.isEmpty {
                changes.append(.text(blockID: id, deltas: deltas))
            }
        }

        if !removed.isEmpty { changes.insert(.remove(blockIDs: removed), at: 0) }
        if !columnRemoved.isEmpty { changes.insert(.remove(blockIDs: columnRemoved), at: 0) }
        for insert in inserts { changes.append(.insert(after: insert.after, blocks: insert.blocks)) }
        for insert in columnInserts { changes.append(.insert(after: insert.after, blocks: insert.blocks)) }

        // An open table whose structure changed (or any tree change, which
        // re-read every open table) gets its paragraph list diffed: the table
        // surface sees paragraphs come and go like blocks.
        let tables = treeChanged ? Set(previousTables.keys) : changedTables
        for table in tables.sorted() {
            if !treeChanged { index.reindexTable(table) }
            let (gone, added) = Self.diff(previousTables[table] ?? [], index.openTables[table] ?? [])
            changes.removeAll { change in
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _): gone.contains(id)
                default: false
                }
            }
            if !gone.isEmpty { changes.insert(.remove(blockIDs: Array(gone)), at: 0) }
            for insert in added {
                changes.append(
                    .insert(
                        after: insert.after,
                        blocks: insert.ids.compactMap { id in index.entries[id].map { snapshot($0) } }))
            }
        }

        // Open source surfaces (PR14): re-validate touched sources (or all of
        // them on a tree change); any that disappeared or became unfamiliar are
        // removed so the source editor sees peer deletion/replacement.
        let sources = treeChanged ? Set(previousSources.keys) : changedSources
        var goneSources: [String] = []
        for sourceID in sources.sorted() {
            if !treeChanged { index.refresh(sourceID) }
            if let entry = index.entries[sourceID], index.isSourceText(sourceID) {
                if textDeltas[sourceID] == nil,
                    !changes.contains(where: {
                        if case .replaceBlock(let id, _) = $0 { return id == sourceID }
                        return false
                    })
                {
                    changes.append(.replaceBlock(blockID: sourceID, block: snapshot(entry)))
                }
            } else {
                goneSources.append(sourceID)
            }
        }
        if !goneSources.isEmpty {
            let goneSet = Set(goneSources)
            changes.removeAll { change in
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _): goneSet.contains(id)
                default: false
                }
            }
            changes.insert(.remove(blockIDs: goneSources), at: 0)
        }

        // A tree change already rebuilt the index; anything else leaves its
        // entries valid, so it never pays for a rebuild.
        if !treeChanged {
            for id in touched where !sources.contains(id) { index.refresh(id) }
        }
        var patch = BlockPatch(changes, origin: origin)
        if !previousColumnOf.isEmpty || !index.columnOf.isEmpty { tagColumns(&patch, previous: previousColumnOf) }
        return patch
    }

    /// Names the column of every column block a patch mentions (PR12a), so
    /// the session routes it to that column's surface and never to the
    /// document's: a removal by the column the block was in, anything else
    /// by the column it is in now.
    private func tagColumns(_ patch: inout BlockPatch, previous: [String: String]) {
        for change in patch.changes {
            switch change {
            case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                if let column = index.columnOf[id] { patch.columns[id] = column }
            case .insert(_, let blocks):
                for block in blocks { if let column = index.columnOf[block.id] { patch.columns[block.id] = column } }
            case .remove(let ids):
                for id in ids { if let column = previous[id] { patch.removedColumns[id] = column } }
            case .reset:
                break
            }
        }
    }

    /// The paragraphs `new` lost and gained against `old`: survivors in the
    /// same relative order stay; a reordered span is removed and reinserted
    /// (as the block preorder diff does). Insertions are anchored after the
    /// previous kept paragraph (nil: first).
    static func diff(_ old: [String], _ new: [String]) -> (gone: Set<String>, added: [(after: String?, ids: [String])])
    {
        guard old != new else { return ([], []) }
        var kept = Set(old).intersection(new)
        let before = old.filter(kept.contains)
        let after = new.filter(kept.contains)
        if before != after {
            var prefix = 0
            while before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
            kept.subtract(before[prefix..<(before.count - suffix)])
        }
        var added: [(after: String?, ids: [String])] = []
        var anchor: String?
        var pending: [String] = []
        for id in new {
            if kept.contains(id) {
                if !pending.isEmpty { added.append((anchor, pending)) }
                pending = []
                anchor = id
            } else {
                pending.append(id)
            }
        }
        if !pending.isEmpty { added.append((anchor, pending)) }
        return (Set(old).subtracting(kept), added)
    }

    private mutating func reset(_ origin: BlockPatchOrigin) -> BlockPatch {
        index.rebuild()
        let blocks = NativeBlockProjection.project(doc, generation: index.generation).blocks.map(BlockSnapshot.init)
        return BlockPatch([.reset(blocks)], origin: origin)
    }

    private mutating func snapshot(_ entry: BlockIndex.Entry) -> BlockSnapshot {
        projectedBlocks += 1
        return BlockSnapshot(nativeSnapshot(entry))
    }

    /// One block at its indexed depth and parent, as the tree projection
    /// reads it. O(block); not counted (the engine's own reads use it).
    func nativeSnapshot(_ entry: BlockIndex.Entry) -> NativeBlockSnapshot {
        if index.isSourceText(entry.id) { return Self.sourceSnapshot(entry) }
        if index.isTableParagraph(entry.id) { return Self.paragraphSnapshot(entry) }
        return NativeBlockProjection.projectBlock(
            entry.containerItem, depth: entry.depth, parent: entry.parentID.flatMap { index.entries[$0]?.handle },
            generation: index.generation)
    }

    static func sourceSnapshot(_ entry: BlockIndex.Entry) -> NativeBlockSnapshot {
        let isInlineMath = entry.element?.typeRef == .xmlElement(nodeName: NativeInlineObject.mathNodeName)
        let node = isInlineMath ? "paragraph" : "codeBlock"
        let plain = entry.element.flatMap { element -> String? in
            if isInlineMath { return NativeInlineObject.read(element)?.visibleText }
            return SourceBlock.plainText(of: element)
        }
        let runs: [InlineRun] = (plain?.isEmpty == false) ? [InlineRun(plain!)] : []
        let block = ProjectedBlock(
            id: entry.id, node: node, props: [], runs: runs,
            fidelity: plain == nil ? .opaque(reason: "source") : .modeled)
        return NativeBlockSnapshot(handle: entry.handle, block: block, depth: 0, parentHandle: nil)
    }

    /// An open table's paragraph as the table surface shows it: a plain
    /// root paragraph (no props) with the paragraph's runs, a `hardBreak` as
    /// "\n" (shown, not typed into). Opaque when it holds anything else.
    static func paragraphSnapshot(_ entry: BlockIndex.Entry) -> NativeBlockSnapshot {
        let runs = entry.element.flatMap(TableGrid.paragraphRuns)
        // The cell's alignment (PR11c), so the active cell edits as it shows.
        var props: [ProjectedProp] = []
        if let cell = entry.element?.item?.parentType,
            let alignment = YBlockProjection.props(of: cell)?.first(where: { $0.key == "textAlignment" }),
            case .string(let value) = alignment.value, value != "left"
        {
            props = [alignment]
        }
        let block = ProjectedBlock(
            id: entry.id, node: "paragraph", props: props, runs: runs ?? [],
            fidelity: runs == nil ? .opaque(reason: "table paragraph") : .modeled)
        return NativeBlockSnapshot(handle: entry.handle, block: block, depth: 0, parentHandle: nil)
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
