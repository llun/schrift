import Foundation

// MARK: - Keeping server blocks the markdown cannot spell

/// Keeps the server's blocks that the editor's markdown cannot express — a table, a callout,
/// a toggle, a video, a PDF, a coloured or centred paragraph — exactly as they are when the
/// user did not touch them, instead of letting the Docs 6 save rebuild them from their
/// markdown "shadow".
///
/// **Why it is needed.** The editor only ever sees the server's markdown export. A block the
/// app does not model reaches it as a shadow: a table as pipe-text lines, a callout as a
/// paragraph with its emoji in front, a toggle heading as a plain heading, a video as an
/// image line, a captioned image as one line of `<figure>` HTML. On save those shadows come
/// back as ordinary paragraphs, headings and images, `BlockNoteAlignment` cannot anchor them
/// to the original (different node, or the same node with props the markdown dropped), and
/// `BlockNoteWrite` deletes the original and inserts the shadow — so saving any page, even
/// after a single checkbox tick elsewhere, turned the web's table into pipe-text paragraphs.
/// Some blocks have no shadow at all (a PDF preview, a page break, a math block or diagram
/// the server's export drops) and were simply deleted.
///
/// **What this does.** Before alignment, every server block that is not fully `.modeled`
/// and that the plain alignment would not anchor gets a `Rule` for recognising its shadow
/// among the editor's new blocks, inside the same gap between anchors — and only among the
/// new blocks the user left exactly as they were in the markdown the edit started from
/// (`untouched(base:new:)`). That base is what makes the words below safe to match on: a
/// change they cannot see (punctuation, a bold word, a link target, a nested tick) makes the
/// block touched, so it is written, never preserved away.
///
/// - `.text` — the shortest run of new blocks (starting on one with text) whose words, in
///   order, are exactly the old block's words (`signatureTokens`). Punctuation, markdown
///   syntax, pipes, emoji and HTML tags carry no words, so a table's pipe lines, a callout's
///   emoji paragraph or a toggle heading's plain heading all read as the same words.
/// - `.media(url)` — one new block that is that media's shadow (`isMediaShadow`): an image
///   or file node with the same URL, a paragraph that is only a link to it, or a paragraph
///   of `<figure>`/`<audio>` HTML naming it.
/// - `.invisible` — a node the export never spells (`invisibleNodes`). If no text shadow is
///   found it is kept where it was, since the user could not have deleted what they never
///   saw.
///
/// A recognised shadow is replaced by an exact copy of the server block (same id, node,
/// props and runs as `BlockNoteIncrementalSave` hands `BlockNoteWrite` for it), and the pair
/// is forced into the alignment. `BlockNoteWrite` then finds it unchanged and in order and
/// writes nothing for it. Anything the user edited no longer reads as the same words, is not
/// recognised, and is saved from the markdown as before — so this only ever keeps what the
/// user left alone, and the content the user changed is still exactly what they wrote.
/// Without a base (a draft from before the base was recorded) no shadow is matched and only
/// the invisible blocks are kept.
///
/// List items with nested children are left out on purpose: the editor models their
/// structure, so re-indenting one keeps every word and must still be written.
///
/// Pure value code over a replica the caller owns; see `AGENTS.md`, "The Yjs CRDT core".
enum BlockNotePreservation {
    /// How a server block's shadow is recognised among the new blocks.
    enum Rule: Equatable {
        /// A node the editor models (`modeledNodes`) without nested children: one new block
        /// of the same node with the same runs, whose every prop the markdown can express
        /// (`unexpressibleKeys` aside) matches. Stricter than `.text`, because the user can
        /// change exactly these things in the app — a checklist tick, a heading level, a
        /// bold word — and such a change must be written, not preserved away.
        case exact(node: String, props: [String: YAnyValue], runs: [InlineRun])
        case text([String])
        case media(url: String)
        /// Kept where it was when no text shadow (possibly empty) is found.
        case invisible([String])
    }

    /// Nodes the server's markdown export does not spell at all, so the editor never shows
    /// them: a PDF with its preview on (exported as an `<iframe>`, which the converter
    /// drops), and the nodes the collaboration server's schema does not register.
    static let invisibleNodes: Set<String> = [
        "pageBreak", "mathBlock", "diagram", "columnList", "column", "uploadLoader",
    ]

    /// Nodes whose shadow is one block naming the same URL.
    static let mediaNodes: Set<String> = ["image", "video", "audio", "file", "pdf"]

    /// Nodes the editor models, so their shadow is the same node (`Rule.exact`).
    static let modeledNodes: Set<String> = [
        "paragraph", "heading", "bulletListItem", "numberedListItem", "checkListItem", "quote", "codeBlock",
    ]

    /// Props the markdown cannot carry, so a shadow always has them at their defaults.
    static let unexpressibleKeys: Set<String> = [
        "backgroundColor", "textColor", "textAlignment", "isToggleable", "start",
    ]

    /// List items whose nested children the editor models and may restructure.
    static let structuredListNodes: Set<String> = ["bulletListItem", "numberedListItem", "checkListItem"]

    /// Upper bound on the Yjs items one block's text walk visits, so a hostile replica with an
    /// enormous block cannot stall the save. A block that reaches it is not preserved.
    static let maxItemsPerBlock = 100_000

    // MARK: - Rules from the replica

    /// One `Rule` per old block (`nil` = left to the plain alignment), read from the live
    /// replica. `old` must be `doc`'s top-level blocks in order, as
    /// `BlockNoteIncrementalSave.oldBlocks` projects them.
    static func rules(for old: [ProjectedBlock], in doc: YDoc) -> [Rule?] {
        let containers = topLevelContainers(of: doc)
        return old.enumerated().map { index, block in
            guard index < containers.count, let container = containers[index] else { return nil }
            return rule(for: block, container: container)
        }
    }

    private static func rule(for block: ProjectedBlock, container: YType) -> Rule? {
        guard block.fidelity != .modeled, !block.id.isEmpty else { return nil }
        let children = liveChildren(of: container)
        guard case .type(let element)? = children.first?.content,
            case .xmlElement(let node)? = element.typeRef
        else { return nil }
        let hasNestedChildren = children.count > 1
        if hasNestedChildren, structuredListNodes.contains(node) { return nil }
        let props = attributes(of: element)

        if node == "pdf", props["showPreview"] != .bool(false) {
            return walkedTokens(of: container).map { .invisible($0) }
        }
        if invisibleNodes.contains(node) {
            return walkedTokens(of: container).map { .invisible($0) }
        }
        if mediaNodes.contains(node), !hasNestedChildren {
            guard case .string(let url)? = props["url"], !url.isEmpty else { return nil }
            return .media(url: url)
        }
        // A modeled node whose runs the projection read (a coloured paragraph, a toggleable
        // heading with no children yet) must come back as itself. One whose inline content
        // it could not read (a mention, a hard break: opaque with no runs) falls through to
        // its words.
        if modeledNodes.contains(node), !hasNestedChildren, block.node == node, !block.runs.isEmpty {
            return .exact(node: node, props: props, runs: block.runs)
        }
        guard let tokens = walkedTokens(of: container), !tokens.isEmpty else { return nil }
        return .text(tokens)
    }

    /// The words a block shows: every string in its `xmlText`s, in document order, across
    /// its whole subtree (a table's cells, a toggle's children). When the subtree holds no
    /// text at all, the string attributes that carry content instead (a diagram's source, a
    /// formula), so a node the export *does* spell as text is still recognised. `nil` when
    /// the walk exceeds `maxItemsPerBlock`.
    private static func walkedTokens(of container: YType) -> [String]? {
        var text = ""
        var attributeText = ""
        var visited = 0
        // Iterative, so a deeply nested replica cannot overrun the stack.
        var stack: [YType] = [container]
        while let type = stack.popLast() {
            if type.typeRef != .xmlText, type.typeRef != .xmlElement(nodeName: "blockContainer") {
                for (key, value) in attributes(of: type) where !styleKeys.contains(key) {
                    if case .string(let string) = value { attributeText += " " + string }
                }
            }
            var pending: [YType] = []
            var item = type.start
            while let current = item {
                visited += 1
                if visited > maxItemsPerBlock { return nil }
                if !current.deleted {
                    switch current.content {
                    case .string(let units): text += String(decoding: units, as: UTF16.self)
                    case .type(let child):
                        text += " "
                        pending.append(child)
                    default: break
                    }
                }
                item = current.right
            }
            // Pushed in reverse so the next pop is the first child: document order.
            stack.append(contentsOf: pending.reversed())
        }
        let tokens = signatureTokens(text)
        return tokens.isEmpty ? signatureTokens(attributeText) : tokens
    }

    /// Attributes that style a block rather than carry its content.
    private static let styleKeys: Set<String> = [
        "id", "backgroundColor", "textColor", "textAlignment", "level", "isToggleable", "language", "url",
        "showPreview", "previewWidth", "checked", "start", "emoji",
    ]

    /// The `blockGroup`'s live children, index for index with the projection's blocks (`nil`
    /// where a child is not a type, which the projection reads as an id-less opaque block).
    private static func topLevelContainers(of doc: YDoc) -> [YType?] {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else { return [] }
        let rootChildren = liveChildren(of: root)
        guard rootChildren.count == 1, case .type(let group) = rootChildren[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else { return [] }
        return liveChildren(of: group).map { item in
            if case .type(let container) = item.content { return container }
            return nil
        }
    }

    private static func liveChildren(of type: YType) -> [YItem] {
        var result: [YItem] = []
        var item = type.start
        while let current = item {
            if !current.deleted, current.countable { result.append(current) }
            item = current.right
        }
        return result
    }

    private static func attributes(of type: YType) -> [String: YAnyValue] {
        var result: [String: YAnyValue] = [:]
        for (key, item) in type.map where !item.deleted {
            if case .any(let values) = item.content, values.count == 1 { result[key] = values[0] }
        }
        return result
    }

    // MARK: - Words

    /// The words of `text`: maximal runs of letters and digits. Markdown link targets
    /// (`](…)`) and HTML tags are dropped first, since the server block shows neither.
    static func signatureTokens(_ text: String) -> [String] {
        var cleaned = text.replacingOccurrences(of: #"\]\([^)\s]*\)"#, with: "]", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in cleaned.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    /// A new block's words, its nested children's included.
    static func signatureTokens(of block: BlockNoteBlock) -> [String] {
        signatureTokens(block.runs.map(\.text).joined()) + block.children.flatMap { signatureTokens(of: $0) }
    }

    /// Whether a new block is a media block's shadow: an image or file node with that `url`,
    /// a paragraph that is nothing but one link to it, or a paragraph of raw HTML (the
    /// export's `<figure>`/`<audio>`/`<video>`) naming it as an attribute. Never just any
    /// block that mentions the URL, which would swallow a user's paragraph linking to it.
    static func isMediaShadow(_ block: BlockNoteBlock, url: String) -> Bool {
        guard block.children.isEmpty else { return false }
        if block.node == "image" || block.node == "file" {
            return block.props.contains { $0.key == "url" && $0.value == .string(url) }
        }
        guard block.node == "paragraph", !block.runs.isEmpty else { return false }
        if block.runs.allSatisfy({ run in run.marks.contains { $0.key == "link" && linkHref($0.valueJSON) == url } }) {
            return true
        }
        let text = block.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("<"), text.hasSuffix(">") else { return false }
        return text.contains("\"\(url)\"") || text.contains("'\(url)'")
    }

    private static func linkHref(_ valueJSON: String) -> String? {
        guard let data = valueJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["href"] as? String
    }

    /// Defaults for a prop a server block may simply omit (BlockNote leaves defaults out).
    private static let omittedDefaults: [String: YAnyValue] = ["backgroundColor": .string("default")]

    /// Whether `block` is an untouched shadow of a modeled server block (`Rule.exact`).
    static func isExactShadow(
        _ block: BlockNoteBlock, node: String, props: [String: YAnyValue], runs: [InlineRun]
    ) -> Bool {
        guard block.node == node, block.children.isEmpty, block.runs == runs else { return false }
        return block.props.allSatisfy { prop in
            if unexpressibleKeys.contains(prop.key) { return true }
            // A prop the server block lacks only matches its default: a `checked` or `level`
            // the user set must never read as untouched.
            return (props[prop.key] ?? omittedDefaults[prop.key]) == prop.value
        }
    }

    // MARK: - What the user left alone

    /// Same content: node, props, runs and nested children — everything but the id, which
    /// every parse mints afresh.
    static func sameContent(_ lhs: BlockNoteBlock, _ rhs: BlockNoteBlock) -> Bool {
        lhs.node == rhs.node && lhs.runs == rhs.runs && lhs.children.count == rhs.children.count
            && lhs.props.map { [$0.key, String(describing: $0.value)] }
                == rhs.props.map { [$0.key, String(describing: $0.value)] }
            && zip(lhs.children, rhs.children).allSatisfy { sameContent($0, $1) }
    }

    /// The indices of `new` blocks the user did not touch: a longest common subsequence with
    /// `base`, the blocks parsed from the markdown the edit started from. Only these may be a
    /// server block's shadow, so a change the words cannot see (punctuation, a bold word, a
    /// link target, a tick on a nested checklist item, a callout turned into a heading) is
    /// always written. Past `BlockNoteAlignment.maxTableCells` only the common prefix and
    /// suffix count, which just preserves less.
    static func untouched(base: [BlockNoteBlock], new: [BlockNoteBlock]) -> Set<Int> {
        var result: Set<Int> = []
        var prefix = 0
        while prefix < base.count, prefix < new.count, sameContent(base[prefix], new[prefix]) {
            result.insert(prefix)
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix, suffix < new.count - prefix,
            sameContent(base[base.count - 1 - suffix], new[new.count - 1 - suffix])
        {
            result.insert(new.count - 1 - suffix)
            suffix += 1
        }
        let rows = base.count - prefix - suffix
        let columns = new.count - prefix - suffix
        guard rows > 0, columns > 0, (rows + 1) * (columns + 1) <= BlockNoteAlignment.maxTableCells else {
            return result
        }
        let width = columns + 1
        var lengths = [Int](repeating: 0, count: (rows + 1) * width)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                if sameContent(base[prefix + i], new[prefix + j]) {
                    lengths[i * width + j] = lengths[(i + 1) * width + j + 1] + 1
                } else {
                    lengths[i * width + j] = max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
        }
        var i = 0
        var j = 0
        while i < rows, j < columns {
            if sameContent(base[prefix + i], new[prefix + j]) {
                result.insert(prefix + j)
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // MARK: - Placing preserved blocks

    /// Upper bound on block comparisons the shadow search makes in one save, so a hostile
    /// replica with many unmatched blocks cannot stall it. Past it, the remaining server
    /// blocks are left to the plain alignment — exactly the behaviour before preservation.
    static let maxShadowComparisons = 2_000_000

    /// `new` with each recognised shadow replaced by its server block (and each unshadowed
    /// invisible block inserted where it was), plus the forced `(old, new)` pairs that hold
    /// those blocks in the alignment.
    ///
    /// `anchors` are the plain alignment's anchors between `old` and `new`; each old block is
    /// only looked for inside its own gap, so the pairs are ascending in both coordinates by
    /// construction. `untouched` (see `untouched(base:new:)`) are the only new blocks a shadow
    /// may be made of.
    static func preserve(
        old: [ProjectedBlock], rules: [Rule?], new: [BlockNoteBlock], untouched: Set<Int>,
        anchors: [(old: Int, new: Int)]
    ) -> (blocks: [BlockNoteBlock], forced: [(old: Int, new: Int)]) {
        let tokens = new.map { signatureTokens(of: $0) }
        var budget = maxShadowComparisons
        // Placements in `new` coordinates: replace `range` (empty = insert at its lower bound).
        var placements: [(old: Int, range: Range<Int>)] = []
        var oldStart = 0
        var newStart = 0
        for anchor in anchors + [(old: old.count, new: new.count)] {
            var cursor = newStart
            let newEnd = max(anchor.new, newStart)
            // Old blocks passed since the last placement that the plain alignment will handle;
            // an unshadowed invisible block goes after as many new blocks, so it stays below
            // the edited block before it rather than jumping to the top of the gap.
            var passed = 0
            for oldIndex in oldStart..<max(anchor.old, oldStart) {
                guard oldIndex < rules.count, let rule = rules[oldIndex], budget > 0 else {
                    passed += 1
                    continue
                }
                if let range = shadow(
                    of: rule, in: new, tokens: tokens, untouched: untouched, from: cursor, to: newEnd,
                    budget: &budget)
                {
                    placements.append((old: oldIndex, range: range))
                    cursor = range.upperBound
                    passed = 0
                } else if case .invisible = rule {
                    let position = min(cursor + passed, newEnd)
                    placements.append((old: oldIndex, range: position..<position))
                    cursor = position
                    passed = 0
                } else {
                    passed += 1
                }
            }
            oldStart = anchor.old + 1
            newStart = anchor.new + 1
        }

        var blocks: [BlockNoteBlock] = []
        var forced: [(old: Int, new: Int)] = []
        var next = 0
        for placement in placements {
            blocks.append(contentsOf: new[next..<placement.range.lowerBound])
            forced.append((old: placement.old, new: blocks.count))
            blocks.append(writableCopy(of: old[placement.old]))
            next = placement.range.upperBound
        }
        blocks.append(contentsOf: new[next...])
        return (blocks, forced)
    }

    /// Exactly the block `BlockNoteIncrementalSave` hands `BlockNoteWrite` as this server
    /// block's old value, so the write finds nothing to change.
    static func writableCopy(of block: ProjectedBlock) -> BlockNoteBlock {
        BlockNoteBlock(
            node: block.node, props: block.props.map { (key: $0.key, value: $0.value) }, runs: block.runs, id: block.id)
    }

    /// A block with no words that may sit inside a multi-block text shadow: a paragraph that
    /// still has text, such as a table's `| --- |` separator row. Never an image, a file, a
    /// divider or an empty paragraph, which would be the user's own insertion.
    private static func isWordlessContinuation(_ block: BlockNoteBlock) -> Bool {
        block.node == "paragraph" && block.children.isEmpty
            && !block.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func shadow(
        of rule: Rule, in new: [BlockNoteBlock], tokens: [[String]], untouched: Set<Int>, from start: Int,
        to end: Int, budget: inout Int
    ) -> Range<Int>? {
        guard start < end else { return nil }
        switch rule {
        case .exact(let node, let props, let runs):
            for index in start..<end where untouched.contains(index) {
                budget -= 1
                if isExactShadow(new[index], node: node, props: props, runs: runs) { return index..<(index + 1) }
            }
            return nil
        case .media(let url):
            for index in start..<end where untouched.contains(index) {
                budget -= 1
                if isMediaShadow(new[index], url: url) { return index..<(index + 1) }
            }
            return nil
        case .text(let words), .invisible(let words):
            guard !words.isEmpty else { return nil }
            for first in start..<end where untouched.contains(first) {
                budget -= 1
                guard budget > 0 else { return nil }
                let firstTokens = tokens[first]
                guard !firstTokens.isEmpty, words.starts(with: firstTokens) else { continue }
                var matched = firstTokens.count
                var last = first
                while matched < words.count, last + 1 < end, untouched.contains(last + 1) {
                    budget -= 1
                    let more = tokens[last + 1]
                    if more.isEmpty {
                        guard isWordlessContinuation(new[last + 1]) else { break }
                    } else {
                        guard words[matched...].starts(with: more) else { break }
                    }
                    matched += more.count
                    last += 1
                }
                if matched == words.count { return first..<(last + 1) }
            }
            return nil
        }
    }
}
