import Foundation

/// Intent writer for the native editor (B5a). Offsets are UTF-16 units; an
/// inline XmlElement (mention, interlink, math) occupies one atomic unit.
/// Owns no replica lifetime: its caller must destroy `doc` when finished.
/// Each intent opens a local-user transaction and returns its incremental update.
/// `transaction` groups intents; nested intents return the empty update and the
/// outer call returns the combined update. No save path uses this writer yet.
struct BlockNoteWriter {
    enum Error: Swift.Error, Equatable {
        case missingBlock(String)
        case malformedBlock(String)
        case duplicateID(String)
        case noPreviousBlock(String)
        case unsupportedBlockType(String)
    }

    let doc: YDoc

    @discardableResult
    func transaction(_ body: (YTransaction) throws -> Void) throws -> Data {
        let nested = doc.transaction != nil
        let tx = try doc.transact(local: true, origin: .localUser) { tx in
            try body(tx)
            return tx
        }
        return nested ? Data([0, 0]) : try YTransactionEncoder.encodeUpdate(tx) ?? Data([0, 0])
    }

    @discardableResult
    func replaceText(block: String, range: NSRange, with text: String, marks: YTextAttributes? = nil) throws -> Data {
        let target = try find(block)
        let parts = try inline(target.element, block: block)
        let bounds = clamp(range, length: try length(parts))
        return try transaction { tx in
            try remove(tx, parts: parts, range: bounds)
            guard !text.isEmpty else { return }
            let current = try inline(target.element, block: block)
            let (type, offset) = try textPosition(tx, element: target.element, parts: current, at: bounds.lowerBound)
            try type.insert(UInt(offset), text, marks)
        }
    }

    /// Formats text portions of the range; atomic inline elements keep their
    /// own schema attributes, rather than receiving text ContentFormat items.
    @discardableResult
    func formatRange(block: String, range: NSRange, attributes: YTextAttributes) throws -> Data {
        let target = try find(block)
        let parts = try inline(target.element, block: block)
        let bounds = clamp(range, length: try length(parts))
        return try transaction { _ in
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

    /// Splits into a sibling of the same type/props. Nested child groups stay
    /// on the original container; inline nodes are copied without flattening.
    @discardableResult
    func splitBlock(block: String, at offset: Int, newID: String) throws -> Data {
        let target = try find(block)
        guard !newID.isEmpty else { throw Error.malformedBlock(newID) }
        do {
            _ = try find(newID)
            throw Error.duplicateID(newID)
        } catch Error.missingBlock {}
        let parts = try inline(target.element, block: block)
        let count = try length(parts)
        let index = min(max(0, offset), count)
        let suffix = try snapshots(parts, range: index..<count, block: block)
        let props = try properties(target.element, block: block)
        guard case .xmlElement(let node)? = target.element.typeRef else { throw Error.malformedBlock(block) }
        return try transaction { tx in
            try remove(tx, parts: parts, range: index..<count)
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: target.group, after: target.item, [.type(container)])
            try buildElement(tx, into: container, after: nil, node: node, props: props, children: suffix)
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string(newID)]))
        }
    }

    /// The first sibling has no join target and throws `noPreviousBlock`.
    /// Refuse a source with nested blocks, rather than silently deleting them.
    @discardableResult
    func joinBlocks(block: String) throws -> Data {
        let target = try find(block)
        let siblings = children(target.group)
        guard let index = siblings.firstIndex(where: { $0 === target.item }), index > 0 else {
            throw Error.noPreviousBlock(block)
        }
        let previous = try resolve(siblings[index - 1], group: target.group, id: block)
        guard children(target.container).count == 1 else { throw Error.malformedBlock(block) }
        let source = try inline(target.element, block: block)
        _ = try inline(previous.element, block: block)
        let copies = try snapshots(source, range: 0..<(try length(source)), block: block)
        return try transaction { tx in
            try append(tx, copies, into: previous.element)
            target.item.delete(tx)
        }
    }

    /// Replaces only the content element, preserving the container/id and any
    /// nested group. Props are ordered in the same order as BlockNote's schema.
    @discardableResult
    func setBlockType(block: String, to node: String, props: [(key: String, value: YAnyValue)]) throws -> Data {
        guard
            ["paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "codeBlock"].contains(node)
        else {
            throw Error.unsupportedBlockType(node)
        }
        let target = try find(block)
        let parts = try inline(target.element, block: block)
        let copies = try snapshots(parts, range: 0..<(try length(parts)), block: block)
        return try transaction { tx in
            target.elementItem.delete(tx)
            try buildElement(tx, into: target.container, after: nil, node: node, props: props, children: copies)
        }
    }

    // MARK: - Checked replica access

    private struct Target {
        let item: YItem
        let container: YType
        let elementItem: YItem
        let element: YType
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

    private func find(_ id: String) throws -> Target {
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
                    candidate == id
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
            case .xmlElement(let node)? = element.typeRef,
            ["paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "codeBlock"].contains(node)
        else {
            throw Error.malformedBlock(id)
        }
        let contents = children(container)
        guard contents.count <= 2 else { throw Error.malformedBlock(id) }
        if contents.count == 2 {
            guard case .type(let nested) = contents[1].content,
                nested.typeRef == .xmlElement(nodeName: "blockGroup")
            else { throw Error.malformedBlock(id) }
        }
        return Target(item: item, container: container, elementItem: first, element: element, group: group)
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
                ["userMentionInline", "interlinkingLinkInline", "math"].contains(node)
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

    private func clamp(_ range: NSRange, length: Int) -> Range<Int> {
        let start = min(max(0, range.location), length)
        let count = min(max(0, range.length), length - start)
        return start..<(start + count)
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

    // MARK: - Lossless inline copies (never reuse an integrated YType)

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
        guard depth < 64 else { throw Error.malformedBlock(block) }
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

    private func buildElement(
        _ tx: YTransaction, into parent: YType, after left: YItem?, node: String,
        props: [(key: String, value: YAnyValue)], children copies: [Copy]
    ) throws {
        let element = YType(typeRef: .xmlElement(nodeName: node))
        try YWrite.insertAfter(tx, into: parent, after: left, [.type(element)])
        try append(tx, copies, into: element)
        for prop in props { try YWrite.mapSet(tx, on: element, key: prop.key, .any([prop.value])) }
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
