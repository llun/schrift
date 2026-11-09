import Foundation

/// Intent writer for the native editor (B5a). Offsets are UTF-16 units; an
/// inline XmlElement (mention, interlink, math, hard break) occupies one atomic
/// unit. An offset between a surrogate pair's halves moves outward to the
/// pair's edge (a range grows to cover the whole character), so no intent
/// writes U+FFFD.
/// Owns no replica lifetime: its caller must destroy `doc` when finished, and on
/// any throw. A throw out of transaction cleanup leaves `transactionCleanups`
/// non-empty, after which no later edit is cleaned up or encoded, exactly the
/// hazard AGENTS.md documents for `applyReplicaUpdate`.
/// Each intent opens a local-user transaction and returns its incremental update.
/// `transaction` groups intents; nested intents return the empty update and the
/// outer call returns the combined update. **A group is not atomic**: each
/// intent validates before it mutates, but when a later one throws, the earlier
/// ones stay in the store, the transaction's observers still deliver them, and
/// the call throws without returning bytes (yjs has no rollback). Treat the
/// replica, not the missing return value, as the truth after a throw.
/// The **live** path uses this writer: `BlockNoteWrite.applyEdit` (the
/// `DocumentCollaborationManager.applyLocalEdit` reconcile) authors a surviving
/// block's in-place edit as these intents. The Docs 6 incremental save still
/// uses the legacy `TextSpanDiff` + `YWrite` reconcile (`applyEditLegacy`).
/// Block intents follow BlockNote 0.56's own commands (Enter's split,
/// `mergeBlocksCommand`, `updateBlock`); keyboard-level choices made before
/// those commands run (Backspace resetting a list item to a paragraph, Enter
/// resetting an empty list item or outdenting an empty nested block) are the caller's.
struct BlockNoteWriter {
    enum Error: Swift.Error, Equatable {
        case missingBlock(String)
        /// The replica is structurally broken around this block.
        case malformedBlock(String)
        case duplicateID(String)
        case noPreviousBlock(String)
        /// A well-formed block this writer does not edit (divider, image,
        /// table, …), or an intent BlockNote refuses for this block type.
        case unsupportedBlockType(String)
    }

    /// The block types this writer reads and writes, with BlockNote 0.56's
    /// props (Docs schema) in schema order — the order y-prosemirror sets
    /// them — and their defaults.
    static let propSchemas: [String: [(key: String, value: YAnyValue)]] = {
        let base: [(key: String, value: YAnyValue)] = [
            ("backgroundColor", .string("default")), ("textColor", .string("default")),
            ("textAlignment", .string("left")),
        ]
        return [
            "paragraph": base,
            "heading": base + [("level", .int(1)), ("isToggleable", .bool(false))],
            "bulletListItem": base,
            "numberedListItem": base + [("start", .undefined)],
            "checkListItem": base + [("checked", .bool(false))],
            "codeBlock": [("language", .string("text"))],
        ]
    }()

    /// The native editor's table (PR05b): the classic six plus BlockNote 0.56's
    /// `quote` and Docs' `callout`, in their schema order. Only the native engine
    /// constructs a writer with it; the classic live reconcile keeps
    /// `propSchemas`, so its quote/callout fallbacks are unchanged.
    static let nativePropSchemas: [String: [(key: String, value: YAnyValue)]] = propSchemas.merging([
        "quote": [("backgroundColor", .string("default")), ("textColor", .string("default"))],
        "callout": [
            ("textAlignment", .string("left")), ("backgroundColor", .string("default")), ("emoji", .string("💡")),
        ],
    ]) { classic, _ in classic }

    /// BlockNote `splitKeepsType`: a split list item makes another list item.
    private static let splitKeepsType: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]

    /// Recursion bound for copied subtrees: a nested block is three XML levels
    /// (container, group, container), so this allows 64 block levels plus inline nodes.
    private static let maxCopyDepth = 3 * 64 + 8

    let doc: YDoc
    /// The block types this writer edits: `propSchemas` unless the caller
    /// (the native engine) passes `nativePropSchemas`.
    var schemas = BlockNoteWriter.propSchemas

    @discardableResult
    func transaction(_ body: (YTransaction) throws -> Void) throws -> Data {
        let nested = doc.transaction != nil
        let tx = try doc.transact(local: true, origin: .localUser) { tx in
            try body(tx)
            return tx
        }
        return nested ? Data([0, 0]) : try YTransactionEncoder.encodeUpdate(tx) ?? Data([0, 0])
    }

    /// Code blocks insert plain text, dropping supplied marks. Other blocks
    /// inherit marks when nil, or use the explicit map when supplied.
    @discardableResult
    func replaceText(block: String, range: NSRange, with text: String, marks: YTextAttributes? = nil) throws -> Data {
        try replaceText(in: try find(block), range: range, with: text, marks: marks)
    }

    /// `Range<Int>` spelling of `replaceText`, for callers below the UI seam
    /// (the engine) that must not mention `NSRange`.
    @discardableResult
    func replaceText(block: String, range: Range<Int>, with text: String, marks: YTextAttributes? = nil)
        throws -> Data
    {
        try replaceText(
            block: block, range: NSRange(location: range.lowerBound, length: range.count), with: text,
            marks: marks)
    }

    /// `replaceText` against an already-resolved target, so a caller applying
    /// several intents to one block walks the document once (`find` is a
    /// whole-document walk). The target must still be live: a kind change
    /// replaces the element, so re-resolve after one.
    @discardableResult
    func replaceText(in target: Target, range: NSRange, with text: String, marks: YTextAttributes? = nil)
        throws -> Data
    {
        let block = target.id
        let parts = try inline(target.element, block: block)
        let bounds = try clamp(range, parts: parts)
        return try transaction { tx in
            try remove(tx, parts: parts, range: bounds)
            guard !text.isEmpty else { return }
            let current = try inline(target.element, block: block)
            let (type, offset) = try textPosition(tx, element: target.element, parts: current, at: bounds.lowerBound)
            try type.insert(UInt(offset), text, target.node == "codeBlock" ? [:] : marks)
        }
    }

    /// Formats text portions of the range; atomic inline elements keep their
    /// own schema attributes, rather than receiving text ContentFormat items.
    /// Code blocks allow no marks: like BlockNote's style command, this is a
    /// successful no-op there, returning an empty update.
    @discardableResult
    func formatRange(block: String, range: NSRange, attributes: YTextAttributes) throws -> Data {
        try formatRange(in: try find(block), range: range, attributes: attributes)
    }

    /// `formatRange` against an already-resolved target, so a caller applying
    /// one command across several blocks walks the document once per block
    /// instead of once per intent.
    @discardableResult
    func formatRange(in target: Target, range: NSRange, attributes: YTextAttributes) throws -> Data {
        let block = target.id
        let parts = try inline(target.element, block: block)
        let bounds = try clamp(range, parts: parts)
        return try transaction { _ in
            guard target.node != "codeBlock" else { return }
            var start = 0
            for part in parts {
                let end = start + part.width
                let lower = max(start, bounds.lowerBound)
                let upper = min(end, bounds.upperBound)
                if lower < upper, part.type.typeRef == .xmlText {
                    try part.type.format(UInt(lower - start), UInt(upper - lower), attributes)
                }
                start = end
            }
        }
    }

    /// `Range<Int>` spelling of `formatRange(in:)`, for the engine.
    @discardableResult
    func formatRange(in target: Target, range: Range<Int>, attributes: YTextAttributes) throws -> Data {
        try formatRange(
            in: target, range: NSRange(location: range.lowerBound, length: range.count), attributes: attributes)
    }

    /// `Range<Int>` spelling of `formatRange`, for callers below the UI seam.
    @discardableResult
    func formatRange(block: String, range: Range<Int>, attributes: YTextAttributes) throws -> Data {
        try formatRange(
            block: block, range: NSRange(location: range.lowerBound, length: range.count),
            attributes: attributes)
    }

    /// BlockNote's Enter: the block keeps its id, type, props and the content
    /// before `offset`; a new block `newID` after it takes the rest and the
    /// nested children. The new block is a list item for list items and a
    /// paragraph otherwise, always with default props. At offset 0 of
    /// non-empty content an empty block is inserted above instead, so the
    /// original keeps its id, content and children. An offset inside a
    /// surrogate pair snaps back to the pair's start (BlockNote writes U+FFFD
    /// into both halves). Code blocks (Enter is a line break) and toggle
    /// headings (Enter depends on view state) throw `unsupportedBlockType`.
    @discardableResult
    func splitBlock(block: String, at offset: Int, newID: String) throws -> Data {
        let target = try find(block)
        guard !newID.isEmpty else { throw Error.malformedBlock(newID) }
        do {
            _ = try find(newID)
            throw Error.duplicateID(newID)
        } catch Error.missingBlock {
        } catch Error.unsupportedBlockType {
            throw Error.duplicateID(newID)
        }
        let props = try properties(target.element, block: block)
        if target.node == "codeBlock"
            || (target.node == "heading" && props.contains { $0.key == "isToggleable" && $0.value == .bool(true) })
        {
            throw Error.unsupportedBlockType(target.node)
        }
        let parts = try inline(target.element, block: block)
        let count = try length(parts)
        let index = snap(parts, min(max(0, offset), count))
        let node = Self.splitKeepsType.contains(target.node) ? target.node : "paragraph"
        let defaults = schemas[node] ?? []
        func insertBlock(_ tx: YTransaction, after left: YItem?, content: [Copy], kids: Copy?) throws {
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: target.group, after: left, [.type(container)])
            try buildElement(tx, into: container, after: nil, node: node, props: defaults, children: content)
            if let kids { try append(tx, [kids], into: container) }
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(newID)]))
        }
        if index == 0, count > 0 {
            return try transaction { tx in try insertBlock(tx, after: target.item.left, content: [], kids: nil) }
        }
        let suffix = try snapshots(parts, range: index..<count, block: block)
        let kids = try target.nested.map { try snapshot($0.type, block: block, depth: 0) }
        return try transaction { tx in
            try remove(tx, parts: parts, range: index..<count)
            target.nested?.item.delete(tx)
            try insertBlock(tx, after: target.item, content: suffix, kids: kids)
        }
    }

    /// BlockNote's `mergeBlocksCommand`: the block's content joins the end of
    /// the block visually above it — the previous sibling's last descendant —
    /// and its nested children move up into its place. When that block is
    /// empty with the same type and props, it is removed instead and this
    /// block, with its id and children, takes its place. The first sibling
    /// throws `noPreviousBlock` (BlockNote would merge a first child into its
    /// parent; not implemented). A code block on either side throws
    /// `unsupportedBlockType`, as BlockNote refuses that merge; so does any
    /// block type outside `propSchemas` on the way (a previous image, quote or
    /// toggle list item, even where BlockNote would merge into its last
    /// descendant), because this writer does not edit those blocks.
    @discardableResult
    func joinBlocks(block: String) throws -> Data {
        let target = try find(block)
        let siblings = children(target.group)
        guard let index = siblings.firstIndex(where: { $0 === target.item }), index > 0 else {
            throw Error.noPreviousBlock(block)
        }
        let previous = siblings[index - 1]
        var above = try resolve(previous, group: target.group, id: block)
        var depth = 0
        while let nested = above.nested, let last = children(nested.type).last {
            depth += 1
            guard depth < Self.maxCopyDepth else { throw Error.malformedBlock(block) }
            above = try resolve(last, group: nested.type, id: block)
        }
        for node in [target.node, above.node] where node == "codeBlock" { throw Error.unsupportedBlockType(node) }
        let source = try inline(target.element, block: block)
        let aboveLength = try length(try inline(above.element, block: block))
        if aboveLength == 0, above.node == target.node,
            try schemaProps(above, block: block) == schemaProps(target, block: block)
        {
            if above.item === previous { return try transaction { tx in above.item.delete(tx) } }
            let moved = try snapshot(target.container, block: block, depth: 0)
            return try transaction { tx in
                try insertCopy(tx, moved, into: above.group, after: above.item)
                above.item.delete(tx)
                target.item.delete(tx)
            }
        }
        let copies = try snapshots(source, range: 0..<(try length(source)), block: block)
        let kids = try target.nested.map { nested in
            try children(nested.type).map { item -> Copy in
                guard case .type(let kid) = item.content else { throw Error.malformedBlock(block) }
                return try snapshot(kid, block: block, depth: 0)
            }
        }
        return try transaction { tx in
            try append(tx, copies, into: above.element)
            var left = target.item
            for kid in kids ?? [] { left = try insertCopy(tx, kid, into: target.group, after: left) }
            target.item.delete(tx)
        }
    }

    /// ProseMirror's replace over a selection that may span sibling blocks, as
    /// plain text lines, in one transaction. `start` keeps its id, type, props
    /// and its content before `startOffset`, then takes the first line. Each
    /// later line becomes a new block named by `newIDs` (in order; a list item's
    /// kind for a list item, else a paragraph, default props, like
    /// `splitBlock`), and the last line's block (`start` itself for one line)
    /// takes `end`'s content after `endOffset`. Every block between is removed,
    /// and `end` when it is not `start`, so one empty line joins `end` into
    /// `start`. The new text inherits the marks at `startOffset`; new lines are
    /// unmarked. Both targets must be live siblings in one group with `start`
    /// first. The caller validates every block between (this writer removes
    /// them whatever they hold) and that `newIDs` are unused. Code, toggle
    /// headings and nested children that would move or be removed throw before
    /// anything is written.
    @discardableResult
    func replaceRange(
        from start: Target, at startOffset: Int, to end: Target, at endOffset: Int, lines: [String],
        newIDs: [String]
    ) throws -> Data {
        let same = start.item === end.item
        for target in [start, end] {
            let props = try properties(target.element, block: target.id)
            if target.node == "codeBlock"
                || (target.node == "heading" && props.contains { $0.key == "isToggleable" && $0.value == .bool(true) })
            {
                throw Error.unsupportedBlockType(target.node)
            }
        }
        if (!same && end.nested != nil) || (lines.count > 1 && start.nested != nil) {
            throw Error.unsupportedBlockType(start.nested != nil ? start.node : end.node)
        }
        guard !lines.isEmpty, newIDs.count == lines.count - 1, !newIDs.contains(where: \.isEmpty),
            Set(newIDs).count == newIDs.count, start.group === end.group
        else { throw Error.malformedBlock(start.id) }
        var middle: [YItem] = []
        if !same {
            var item = start.item.right
            while let current = item, current !== end.item {
                if !current.deleted { middle.append(current) }
                item = current.right
            }
            // Never delete to the end of the group: `end` must follow `start`.
            guard item === end.item else { throw Error.malformedBlock(end.id) }
        }
        let startParts = try inline(start.element, block: start.id)
        let startLength = try length(startParts)
        let endParts = same ? startParts : try inline(end.element, block: end.id)
        let endLength = try length(endParts)
        let lower = snap(startParts, min(max(0, startOffset), startLength))
        let upper = snap(endParts, min(max(0, endOffset), endLength), forward: true)
        guard !same || lower <= upper else { throw Error.malformedBlock(start.id) }
        // Copied before any delete: the content that follows the range.
        let suffix = try snapshots(endParts, range: upper..<endLength, block: end.id)
        let node = Self.splitKeepsType.contains(start.node) ? start.node : "paragraph"
        let defaults = schemas[node] ?? []
        return try transaction { tx in
            // One same-block line is a plain replacement; otherwise everything
            // after `lower` leaves `start` and the suffix returns from its copy.
            try remove(tx, parts: startParts, range: lower..<(same && lines.count == 1 ? upper : startLength))
            if !lines[0].isEmpty {
                let current = try inline(start.element, block: start.id)
                let (text, offset) = try textPosition(tx, element: start.element, parts: current, at: lower)
                try text.insert(UInt(offset), lines[0], nil)
            }
            if lines.count == 1, !same { try append(tx, suffix, into: start.element) }
            var left = start.item
            for (index, id) in newIDs.enumerated() {
                let line = lines[index + 1]
                var content: [Copy] = line.isEmpty ? [] : [.text([.run(InlineRun(line))])]
                if index == newIDs.count - 1 { content += suffix }
                let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
                guard let item = try YWrite.insertAfter(tx, into: start.group, after: left, [.type(container)]) else {
                    throw Error.malformedBlock(id)
                }
                try buildElement(tx, into: container, after: nil, node: node, props: defaults, children: content)
                try YWrite.mapSet(tx, on: container, key: "id", .any([.string(id)]))
                left = item
            }
            for item in middle { item.delete(tx) }
            if !same { end.item.delete(tx) }
        }
    }

    /// BlockNote's `updateBlock` type change: replaces only the content element,
    /// keeping the container/id and any nested group. `props` override; every
    /// other prop of the new type keeps the block's existing value or takes its
    /// default. Into a code block the content becomes its plain text
    /// (ProseMirror `textContent`: marks and textless inline nodes drop, math
    /// keeps its source). Keeping the type changes only the props that differ,
    /// on the existing element, as BlockNote does: a checkbox toggle or a
    /// heading level is one attribute, and concurrent typing in the block survives.
    @discardableResult
    func setBlockType(block: String, to node: String, props: [(key: String, value: YAnyValue)] = []) throws -> Data {
        // Validate the target type before the lookup, as before the `in:` split.
        guard schemas[node] != nil else { throw Error.unsupportedBlockType(node) }
        return try setBlockType(in: try find(block), to: node, props: props)
    }

    /// `setBlockType` against an already-resolved target (see `replaceText(in:)`).
    /// A kind change replaces the element, so re-resolve before a later intent.
    @discardableResult
    func setBlockType(in target: Target, to node: String, props: [(key: String, value: YAnyValue)] = [])
        throws -> Data
    {
        let block = target.id
        guard let schema = schemas[node] else { throw Error.unsupportedBlockType(node) }
        let existing = try properties(target.element, block: block)
        let merged = schema.map { field in
            (
                key: field.key,
                value: props.last { $0.key == field.key }?.value
                    ?? existing.last { $0.key == field.key }?.value ?? field.value
            )
        }
        if node == target.node {
            let current = try schemaProps(target, block: block)
            let changed = zip(merged, current).filter { $0.0.value != $0.1 }.map(\.0)
            return try transaction { tx in
                for prop in changed { try YWrite.mapSet(tx, on: target.element, key: prop.key, .any([prop.value])) }
            }
        }
        let parts = try inline(target.element, block: block)
        let copies: [Copy]
        if node == "codeBlock", target.node != "codeBlock" {
            let text = try parts.map { try textContent($0.type, block: block, depth: 0) }.joined()
            copies = text.isEmpty ? [] : [.text([.run(InlineRun(text))])]
        } else {
            copies = try snapshots(parts, range: 0..<(try length(parts)), block: block)
        }
        return try transaction { tx in
            target.elementItem.delete(tx)
            try buildElement(tx, into: target.container, after: nil, node: node, props: merged, children: copies)
        }
    }

    /// BlockNote's `updateBlock` with props only: the type never changes, so this
    /// is `setBlockType`'s same-type path (only the props that differ, on the
    /// existing element). Every key must be in the block's own schema.
    @discardableResult
    func setBlockProps(in target: Target, props: [(key: String, value: YAnyValue)]) throws -> Data {
        guard let schema = schemas[target.node],
            props.allSatisfy({ prop in schema.contains { $0.key == prop.key } })
        else { throw Error.unsupportedBlockType(target.node) }
        return try setBlockType(in: target, to: target.node, props: props)
    }

    // MARK: - Checked replica access

    /// A resolved block: its container, content element and node. Resolving is a
    /// whole-document walk, so a caller applying several intents to one block
    /// resolves once and passes the target to the `in:` overloads.
    struct Target {
        let id: String
        let item: YItem
        let container: YType
        let elementItem: YItem
        let element: YType
        let node: String
        let nested: (item: YItem, type: YType)?
        let group: YType
    }

    private func children(_ type: YType) -> [YItem] {
        var result: [YItem] = []
        var item = type.start
        while let current = item {
            if !current.deleted { result.append(current) }
            item = current.right
        }
        return result
    }

    func find(_ id: String) throws -> Target {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { throw Error.missingBlock(id) }
        var stack = [root]
        var found: Target?
        var visited = Set<ObjectIdentifier>()
        while let type = stack.popLast() {
            guard visited.insert(ObjectIdentifier(type)).inserted else { throw Error.malformedBlock(id) }
            for item in children(type) {
                guard case .type(let child) = item.content else { throw Error.malformedBlock(id) }
                if child.typeRef == .xmlElement(nodeName: "blockContainer"),
                    let value = child.map["id"], !value.deleted,
                    case .any(let values) = value.content, values.count == 1, case .string(let candidate) = values[0],
                    // BlockNote ids are opaque JS strings, not canonically
                    // equivalent Swift strings. This also governs duplicate ids
                    // and splitBlock's newID check, which both use this lookup.
                    candidate.utf16.elementsEqual(id.utf16)
                {
                    guard found == nil else { throw Error.duplicateID(id) }
                    found = try resolve(item, group: type, id: id)
                }
                // Only block groups/containers participate in block lookup;
                // inline elements and tables cannot masquerade as block ids.
                if child.typeRef == .xmlElement(nodeName: "blockContainer")
                    || child.typeRef == .xmlElement(nodeName: "blockGroup")
                {
                    stack.append(child)
                }
            }
        }
        guard let found else { throw Error.missingBlock(id) }
        return found
    }

    private func resolve(_ item: YItem, group: YType, id: String) throws -> Target {
        guard group.typeRef == .xmlElement(nodeName: "blockGroup"),
            case .type(let container) = item.content, container.typeRef == .xmlElement(nodeName: "blockContainer"),
            let first = children(container).first, case .type(let element) = first.content,
            case .xmlElement(let node)? = element.typeRef
        else {
            throw Error.malformedBlock(id)
        }
        let contents = children(container)
        guard contents.count <= 2 else { throw Error.malformedBlock(id) }
        var nested: (item: YItem, type: YType)?
        if contents.count == 2 {
            guard case .type(let group) = contents[1].content,
                group.typeRef == .xmlElement(nodeName: "blockGroup")
            else { throw Error.malformedBlock(id) }
            nested = (contents[1], group)
        }
        guard schemas[node] != nil else { throw Error.unsupportedBlockType(node) }
        return Target(
            id: id, item: item, container: container, elementItem: first, element: element, node: node,
            nested: nested, group: group)
    }

    /// The engine's canonical index has already proved unique root-container
    /// identity. Resolve that exact live item without another document walk.
    func indexedTarget(_ item: YItem, id: String) throws -> Target {
        guard !item.deleted, let group = item.parentType else { throw Error.missingBlock(id) }
        return try resolve(item, group: group, id: id)
    }

    private struct Part {
        let item: YItem
        let type: YType
        let width: Int
    }

    private func inline(_ element: YType, block: String) throws -> [Part] {
        let parts = try children(element).map { item in
            guard case .type(let type) = item.content else { throw Error.malformedBlock(block) }
            if type.typeRef == .xmlText {
                guard let width = Int(exactly: type.length) else { throw Error.malformedBlock(block) }
                // Validate before an operation can partially change a malformed text.
                for child in children(type) {
                    switch child.content {
                    case .string, .format, .embed: break
                    default: throw Error.malformedBlock(block)
                    }
                }
                return Part(item: item, type: type, width: width)
            }
            guard case .xmlElement(let node)? = type.typeRef,
                ["userMentionInline", "interlinkingLinkInline", "math", "hardBreak"].contains(node)
            else {
                throw Error.malformedBlock(block)
            }
            return Part(item: item, type: type, width: 1)
        }
        _ = try length(parts)
        return parts
    }

    private func length(_ parts: [Part]) throws -> Int {
        var total = 0
        for part in parts {
            let (sum, overflow) = total.addingReportingOverflow(part.width)
            guard !overflow else { throw Error.malformedBlock("inline length") }
            total = sum
        }
        return total
    }

    private func clamp(_ range: NSRange, parts: [Part]) throws -> Range<Int> {
        let length = try length(parts)
        let start = min(max(0, range.location), length)
        let count = min(max(0, range.length), length - start)
        let lower = snap(parts, start)
        // An empty range is a caret: it moves back with its start rather than growing.
        return lower..<(count == 0 ? lower : snap(parts, start + count, forward: true))
    }

    /// Moves an offset that falls between a surrogate pair's halves to the
    /// pair's start (or end, `forward`), like `TextSpanDiff`, so yjs never
    /// splices the pair and writes U+FFFD.
    private func snap(_ parts: [Part], _ offset: Int, forward: Bool = false) -> Int {
        var start = 0
        for part in parts {
            if part.type.typeRef == .xmlText, offset > start, offset < start + part.width {
                var units: [UInt16] = []
                for item in children(part.type) {
                    switch item.content {
                    case .string(let string): units += string
                    case .embed: units.append(0)
                    default: break
                    }
                }
                let index = offset - start
                let splitsPair =
                    index < units.count && UTF16.isTrailSurrogate(units[index])
                    && UTF16.isLeadSurrogate(units[index - 1])
                return splitsPair ? offset + (forward ? 1 : -1) : offset
            }
            start += part.width
        }
        return offset
    }

    private func remove(_ tx: YTransaction, parts: [Part], range: Range<Int>) throws {
        var start = 0
        for part in parts {
            let end = start + part.width
            let lower = max(start, range.lowerBound)
            let upper = min(end, range.upperBound)
            if lower < upper {
                if part.type.typeRef == .xmlText {
                    try part.type.delete(UInt(lower - start), UInt(upper - lower))
                } else {
                    part.item.delete(tx)
                }
            }
            start = end
        }
    }

    private func textPosition(_ tx: YTransaction, element: YType, parts: [Part], at index: Int) throws -> (YType, Int) {
        var start = 0
        var left: YItem?
        for part in parts {
            if part.type.typeRef == .xmlText, index >= start, index <= start + part.width {
                return (part.type, index - start)
            }
            if index == start { break }
            start += part.width
            left = part.item
        }
        let text = YType(typeRef: .xmlText)
        try YWrite.insertAfter(tx, into: element, after: left, [.type(text)])
        return (text, 0)
    }

    /// Props in the block type's schema order, missing ones at their default:
    /// ProseMirror's attrs, which `sameMarkup` compares.
    private func schemaProps(_ target: Target, block: String) throws -> [YAnyValue] {
        let existing = try properties(target.element, block: block)
        return (schemas[target.node] ?? []).map { field in
            existing.last { $0.key == field.key }?.value ?? field.value
        }
    }

    /// ProseMirror `textContent`: every string inside the node, formats and embeds dropped.
    private func textContent(_ type: YType, block: String, depth: Int) throws -> String {
        guard depth < Self.maxCopyDepth else { throw Error.malformedBlock(block) }
        var text = ""
        for item in children(type) {
            switch item.content {
            case .string(let units): text += String(decoding: units, as: UTF16.self)
            case .type(let child): text += try textContent(child, block: block, depth: depth + 1)
            default: break
            }
        }
        return text
    }

    // MARK: - Lossless copies (never reuse an integrated YType)

    private enum TextValue {
        case run(InlineRun)
        case embed(String, YTextAttributes)
    }

    private indirect enum Copy {
        case text([TextValue])
        case element(String, [(key: String, value: YAnyValue)], [Copy])
    }

    private func properties(_ type: YType, block: String) throws -> [(key: String, value: YAnyValue)] {
        // Map insertion clocks recover schema order, unlike Swift Dictionary order.
        try type.map.values.filter { !$0.deleted }.sorted {
            $0.id.client == $1.id.client ? $0.id.clock < $1.id.clock : $0.id.client < $1.id.client
        }.map { item in
            guard let key = item.parentSub, case .any(let values) = item.content, values.count == 1 else {
                throw Error.malformedBlock(block)
            }
            return (key, values[0])
        }
    }

    private func snapshots(_ parts: [Part], range: Range<Int>, block: String) throws -> [Copy] {
        var start = 0
        var result: [Copy] = []
        for part in parts {
            let lower = max(start, range.lowerBound)
            let upper = min(start + part.width, range.upperBound)
            if lower < upper {
                result.append(try snapshot(part.type, range: (lower - start)..<(upper - start), block: block, depth: 0))
            }
            start += part.width
        }
        return result
    }

    private func snapshot(_ type: YType, range: Range<Int>? = nil, block: String, depth: Int) throws -> Copy {
        guard depth < Self.maxCopyDepth else { throw Error.malformedBlock(block) }
        if type.typeRef == .xmlText {
            var marks = YTextAttributes()
            var position = 0
            var values: [TextValue] = []
            for item in children(type) {
                switch item.content {
                case .format(let key, let json):
                    marks[key] = json == "null" ? nil : YTextAttributeValue(json: json, identity: YAttributeIdentity())
                case .string(let units):
                    let lower = max(position, range?.lowerBound ?? 0)
                    let upper = min(position + units.count, range?.upperBound ?? Int.max)
                    if lower < upper {
                        let text = String(decoding: units[(lower - position)..<(upper - position)], as: UTF16.self)
                        values.append(
                            .run(
                                InlineRun(
                                    text, marks: marks.keys.compactMap { key in marks[key].map { (key, $0.json) } })))
                    }
                    position += units.count
                case .embed(let json):
                    if range == nil || range?.contains(position) == true { values.append(.embed(json, marks)) }
                    position += 1
                default: throw Error.malformedBlock(block)
                }
            }
            return .text(values)
        }
        guard case .xmlElement(let node)? = type.typeRef else { throw Error.malformedBlock(block) }
        let copies = try children(type).map { item -> Copy in
            guard case .type(let child) = item.content else { throw Error.malformedBlock(block) }
            return try snapshot(child, block: block, depth: depth + 1)
        }
        return .element(node, try properties(type, block: block), copies)
    }

    @discardableResult
    private func buildElement(
        _ tx: YTransaction, into parent: YType, after left: YItem?, node: String,
        props: [(key: String, value: YAnyValue)], children copies: [Copy]
    ) throws -> YItem {
        let element = YType(typeRef: .xmlElement(nodeName: node))
        guard let item = try YWrite.insertAfter(tx, into: parent, after: left, [.type(element)]) else {
            throw Error.malformedBlock(node)
        }
        try append(tx, copies, into: element)
        for prop in props { try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value])) }
        return item
    }

    /// Inserts a copied element (a whole block container) after `left`.
    @discardableResult
    private func insertCopy(_ tx: YTransaction, _ copy: Copy, into parent: YType, after left: YItem) throws -> YItem {
        guard case .element(let node, let props, let nested) = copy else { throw Error.malformedBlock("#text") }
        return try buildElement(tx, into: parent, after: left, node: node, props: props, children: nested)
    }

    private func append(_ tx: YTransaction, _ copies: [Copy], into element: YType) throws {
        for copy in copies {
            let last = children(element).last
            switch copy {
            case .text(let values):
                let text: YType
                if let last, case .type(let existing) = last.content, existing.typeRef == .xmlText {
                    text = existing
                } else {
                    text = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: element, after: last, [.type(text)])
                }
                // The single shared inline builder defines mark open/carry/close
                // shape; public YText ops own all string/embed/format mutations.
                var runs: [InlineRun] = []
                func flush() throws {
                    var attrs = YTextAttributes()
                    for piece in InlineContent.pieces(for: runs) {
                        switch piece {
                        case .format(let key, let json):
                            attrs[key] =
                                json == "null" ? nil : YTextAttributeValue(json: json, identity: YAttributeIdentity())
                        case .string(let string): try text.insert(text.length, string, attrs)
                        }
                    }
                    runs.removeAll()
                }
                for value in values {
                    switch value {
                    case .run(let run): runs.append(run)
                    case .embed(let json, let attrs):
                        try flush()
                        try text.insertEmbed(text.length, json, attrs)
                    }
                }
                try flush()
            case .element(let node, let props, let nested):
                try buildElement(tx, into: element, after: last, node: node, props: props, children: nested)
            }
        }
    }
}
