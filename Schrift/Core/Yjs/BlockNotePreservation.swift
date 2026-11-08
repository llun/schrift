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
/// - `.invisible` — a node the export never spells (`invisibleNodes`). It has no shadow to
///   look for, so it is always kept where it was: the user could not have deleted what they
///   never saw, and a word search could only ever hit someone else's block.
///
/// A multi-block shadow must also have been one run in the base (its blocks map to
/// consecutive base blocks), so a table that lost a row cannot borrow the next block's words.
/// A server block that is the untouched shadow of a single new block also counts as a match
/// for the plain alignment's anchors, so a plain duplicate of that block cannot claim it
/// first and leave the server block with nothing to match.
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
/// List items with nested children get the stricter `.listTree`: the editor models their
/// structure, so re-indenting one keeps every word and must still be written. Rebuilding an
/// untouched one on every save instead deleted the subtree a co-author might be typing in.
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
        /// A list item with nested children (`structuredListNodes`): one new block with the
        /// same tree (`treeShape`), node for node the same expressible props and the same text,
        /// so a re-indent or a nested tick is always written. The text is each node's exact
        /// `runs` (punctuation, marks and link targets included) when the replica's inline
        /// content reads as runs, else only its `words` (a document link or mention inside).
        /// `base` is the base block this server block was when the edit started
        /// (`placingListTrees`); only a new block the user left at that base block may be its
        /// shadow, so two items that read the same (a duplicate, a reorder) cannot swap.
        /// Without one it is never matched.
        case listTree(
            shape: [String], props: [[String: YAnyValue]], runs: [[InlineRun]]?, words: [String], base: Int? = nil)
        case media(url: String)
        /// Never spelled by the export: always kept where it was.
        case invisible
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

    /// List items whose nested children the editor models and may restructure (`Rule.listTree`).
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
        let rules = old.enumerated().map { index, block -> Rule? in
            guard index < containers.count, let container = containers[index] else { return nil }
            return rule(for: block, container: container)
        }
        // Skipping inline math can make blocks that differ only in their formulas (or a formula
        // and none) read alike, and a single-block shadow could then go to the wrong one. So a
        // math block the editor models (a paragraph, heading, quote or childless list item, whose
        // shadow is one block) gets no rule when another top-level block shares its math-free
        // words: it projects opaque and illegible (math is never inline text), so the plain
        // alignment cannot anchor it either, and it is rebuilt from the markdown, losing its
        // formula. Invisible blocks are never a shadow, so they neither collide nor lose their rule;
        // a list tree is already tied to its base block, and a multi-block shadow (a table) is kept.
        let walks = containers.indices.map { index -> (tokens: [String], hasMath: Bool)? in
            guard index < rules.count, let container = containers[index] else { return nil }
            if case .invisible? = rules[index] { return nil }
            return walk(of: container)
        }
        var counts: [[String]: Int] = [:]
        for walk in walks { if let walk { counts[walk.tokens, default: 0] += 1 } }
        return rules.enumerated().map { index, rule in
            guard case .text? = rule, index < walks.count, let walk = walks[index], walk.hasMath,
                counts[walk.tokens, default: 0] > 1, let container = containers[index]
            else { return rule }
            let children = liveChildren(of: container)
            guard children.count == 1, case .type(let element)? = children.first?.content,
                case .xmlElement(let node)? = element.typeRef, modeledNodes.contains(node)
            else { return rule }
            return nil
        }
    }

    private static func rule(for block: ProjectedBlock, container: YType) -> Rule? {
        guard block.fidelity != .modeled, !block.id.isEmpty else { return nil }
        let children = liveChildren(of: container)
        guard case .type(let element)? = children.first?.content,
            case .xmlElement(let node)? = element.typeRef
        else { return nil }
        let hasNestedChildren = children.count > 1
        if hasNestedChildren, structuredListNodes.contains(node) {
            guard let tree = treeShape(of: container), let words = walkedTokens(of: container), !words.isEmpty
            else { return nil }
            return .listTree(shape: tree.shape, props: tree.props, runs: tree.runs, words: words)
        }
        let props = attributes(of: element)

        if node == "pdf", props["showPreview"] != .bool(false) { return .invisible }
        if invisibleNodes.contains(node) { return .invisible }
        if mediaNodes.contains(node), !hasNestedChildren {
            guard case .string(let url)? = props["url"], !url.isEmpty else { return nil }
            return .media(url: url)
        }
        // A modeled node whose runs the projection read (a coloured paragraph, a toggleable
        // heading with no children yet) must come back as itself. One whose inline content
        // it could not read (a mention, a hard break: opaque with no runs) falls through to
        // its words.
        if modeledNodes.contains(node), !hasNestedChildren, block.node == node, !block.runs.isEmpty {
            // Coalesced as the markdown parser's runs are: an underlined word mid-sentence is
            // scrubbed to its own unmarked run, which must still read like its shadow's.
            return .exact(node: node, props: props, runs: YBlockProjection.inlineRuns(of: element) ?? block.runs)
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
        walk(of: container)?.tokens
    }

    /// `walkedTokens`, and whether the walk skipped any inline math.
    private static func walk(of container: YType) -> (tokens: [String], hasMath: Bool)? {
        var hasMath = false
        var text = ""
        var attributeText = ""
        var visited = 0
        // Iterative, so a deeply nested replica cannot overrun the stack.
        var stack: [YType] = [container]
        while let type = stack.popLast() {
            // Each type's text starts on a word boundary, so sibling `xmlText`s (either side
            // of a hard break or a mention) never run together.
            text += " "
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
                    // The export drops inline math without a trace, so its words are not the block's.
                    case .type(let child) where child.typeRef == .xmlElement(nodeName: "math"): hasMath = true
                    case .type(let child): pending.append(child)
                    default: break
                    }
                }
                item = current.right
            }
            // Pushed in reverse so the next pop is the first child: document order.
            stack.append(contentsOf: pending.reversed())
        }
        let tokens = signatureTokens(text)
        return (tokens.isEmpty ? signatureTokens(attributeText) : tokens, hasMath)
    }

    /// The nodes of a block's subtree in document order, each with its nesting depth, and each
    /// node's props and inline runs (`runs` is nil when any node's do not read as runs). `nil`
    /// for a shape the editor cannot spell (a non-block child) or past `maxItemsPerBlock`.
    private static func treeShape(
        of container: YType
    ) -> (shape: [String], props: [[String: YAnyValue]], runs: [[InlineRun]]?)? {
        var shape: [String] = []
        var props: [[String: YAnyValue]] = []
        var runs: [[InlineRun]]? = []
        // Iterative, like `walkedTokens`, so a deeply nested replica cannot overrun the stack.
        var stack: [(container: YType, depth: Int)] = [(container, 0)]
        while let (current, depth) = stack.popLast() {
            guard shape.count < maxItemsPerBlock else { return nil }
            var nested: [YType] = []
            for child in liveChildren(of: current) {
                guard case .type(let type) = child.content, case .xmlElement(let name)? = type.typeRef else {
                    return nil
                }
                guard name == "blockGroup" else {
                    shape.append("\(depth):\(name)")
                    props.append(attributes(of: type))
                    if let nodeRuns = YBlockProjection.inlineRuns(of: type) {
                        runs?.append(trimmingTrailingBlanks(nodeRuns))
                    } else {
                        runs = nil
                    }
                    continue
                }
                for entry in liveChildren(of: type) {
                    guard case .type(let next) = entry.content, next.typeRef == .xmlElement(nodeName: "blockContainer")
                    else { return nil }
                    nested.append(next)
                }
            }
            stack.append(contentsOf: nested.reversed().map { ($0, depth + 1) })
        }
        return (shape, props, runs)
    }

    /// `runs` without the trailing spaces and tabs the markdown's list parsers strip (`rstrip`),
    /// so a server "Task " reads like its markdown "Task" (the markdown cannot keep them either).
    /// A code or link run keeps its own, which its delimiters protect from the strip.
    private static func trimmingTrailingBlanks(_ runs: [InlineRun]) -> [InlineRun] {
        var runs = runs
        while var last = runs.last, !last.marks.contains(where: { $0.key == "code" || $0.key == "link" }) {
            while last.text.last == " " || last.text.last == "\t" { last.text.removeLast() }
            guard last.text.isEmpty else {
                runs[runs.count - 1] = last
                break
            }
            runs.removeLast()
        }
        return runs
    }

    /// `treeShape` of a new block.
    static func treeShape(of block: BlockNoteBlock, depth: Int = 0) -> [String] {
        ["\(depth):\(block.node)"] + block.children.flatMap { treeShape(of: $0, depth: depth + 1) }
    }

    /// A new block and its nested children in `treeShape` order.
    private static func treeNodes(of block: BlockNoteBlock) -> [BlockNoteBlock] {
        [block] + block.children.flatMap { treeNodes(of: $0) }
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
        return expressiblePropsMatch(block, props)
    }

    /// Whether every prop of `block` the markdown can express equals the server's `props`.
    private static func expressiblePropsMatch(_ block: BlockNoteBlock, _ props: [String: YAnyValue]) -> Bool {
        block.props.allSatisfy { prop in
            if unexpressibleKeys.contains(prop.key) { return true }
            // A prop the server block lacks only matches its default: a `checked` or `level`
            // the user set must never read as untouched.
            return (props[prop.key] ?? omittedDefaults[prop.key]) == prop.value
        }
    }

    /// Whether `block` reads like a `.listTree` server block: the same tree, expressible props
    /// and text — the exact runs where the rule has them, else (or `byWords`) the same words.
    /// `tokens` are `signatureTokens(of: block)`.
    private static func isListTreeShadow(
        _ block: BlockNoteBlock, tokens: [String], of rule: Rule?, byWords: Bool = false
    ) -> Bool {
        guard case .listTree(let shape, let props, let runs, let words, _)? = rule, treeShape(of: block) == shape
        else { return false }
        let nodes = treeNodes(of: block)
        if let runs, !byWords {
            guard sameRunsIgnoringMarkOrder(nodes.map(\.runs), runs) else { return false }
        } else if tokens != words {
            return false
        }
        return zip(nodes, props).allSatisfy { expressiblePropsMatch($0, $1) }
    }

    /// Whether two runs-per-item lists match in text and marks, ignoring the order of each run's
    /// marks: the server may hold `[italic, bold]` where the markdown parses `[bold, italic]`.
    private static func sameRunsIgnoringMarkOrder(_ lhs: [[InlineRun]], _ rhs: [[InlineRun]]) -> Bool {
        func canonical(_ runs: [[InlineRun]]) -> [[[String]]] {
            runs.map { $0.map { [$0.text] + $0.marks.map { "\($0.key)\u{0}\($0.valueJSON)" }.sorted() } }
        }
        return canonical(lhs) == canonical(rhs)
    }

    /// `rules` with each `.listTree` tied to the base block it was when the edit started: an
    /// LCS of the server blocks with the base under `isListTreeShadow` (the plain alignment's
    /// anchors hold the rest in step). A server item no base block reads like keeps no base and
    /// is rebuilt from the markdown. One whose text the replica does not spell as runs is
    /// matched by words only when that is unambiguous both ways — the one base block reading
    /// like it, and no other server item reading like that block — since words cannot tell
    /// `Task` from `Task!` and two such items could swap; past `maxTableCells`, never.
    static func placingListTrees(_ rules: [Rule?], old: [ProjectedBlock], base: [BlockNoteBlock]) -> [Rule?] {
        let listTrees = rules.indices.filter { if case .listTree? = rules[$0] { true } else { false } }
        guard !listTrees.isEmpty else { return rules }
        let tokens = base.map { signatureTokens(of: $0) }
        func readsByWords(_ oldIndex: Int, _ baseIndex: Int) -> Bool {
            isListTreeShadow(base[baseIndex], tokens: tokens[baseIndex], of: rules[oldIndex], byWords: true)
        }
        var wordsOnlyPlacement: [Int: Int] = [:]
        if old.count * base.count <= BlockNoteAlignment.maxTableCells {
            for oldIndex in listTrees {
                guard case .listTree(_, _, .none, _, _)? = rules[oldIndex] else { continue }
                let candidates = base.indices.filter { readsByWords(oldIndex, $0) }
                if candidates.count == 1, listTrees.filter({ readsByWords($0, candidates[0]) }).count == 1 {
                    wordsOnlyPlacement[oldIndex] = candidates[0]
                }
            }
        }
        var placed = rules
        let pairs = BlockNoteAlignment.anchorPairs(old: old, new: base) { oldIndex, baseIndex in
            if case .listTree(_, _, .none, _, _)? = rules[oldIndex] { return wordsOnlyPlacement[oldIndex] == baseIndex }
            return isListTreeShadow(base[baseIndex], tokens: tokens[baseIndex], of: rules[oldIndex])
        }
        for pair in pairs {
            guard case .listTree(let shape, let props, let runs, let words, _)? = rules[pair.old] else { continue }
            placed[pair.old] = .listTree(shape: shape, props: props, runs: runs, words: words, base: pair.new)
        }
        return placed
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

    /// The `new` blocks the user did not touch, each mapped to its index in `base` (the blocks
    /// parsed from the markdown the edit started from): a longest common subsequence. Only these may be a
    /// server block's shadow, so a change the words cannot see (punctuation, a bold word, a
    /// link target, a tick on a nested checklist item, a callout turned into a heading) is
    /// always written. Past `BlockNoteAlignment.maxTableCells` only the common prefix and
    /// suffix count, which just preserves less.
    static func untouched(base: [BlockNoteBlock], new: [BlockNoteBlock]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var prefix = 0
        while prefix < base.count, prefix < new.count, sameContent(base[prefix], new[prefix]) {
            result[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix, suffix < new.count - prefix,
            sameContent(base[base.count - 1 - suffix], new[new.count - 1 - suffix])
        {
            result[new.count - 1 - suffix] = base.count - 1 - suffix
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
                result[prefix + j] = prefix + i
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
    /// construction. An anchor whose new block is its server block's untouched shadow (see
    /// `isSingleShadow`, which the save passes to `anchorPairs`) is a placement too.
    /// `untouched` (see `untouched(base:new:)`) are the only new blocks a shadow may be made of.
    static func preserve(
        old: [ProjectedBlock], rules: [Rule?], new: [BlockNoteBlock], untouched: [Int: Int],
        anchors: [(old: Int, new: Int)], tokens precomputed: [[String]]? = nil
    ) -> (blocks: [BlockNoteBlock], forced: [(old: Int, new: Int)]) {
        let tokens = precomputed ?? new.map { signatureTokens(of: $0) }
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
                if case .invisible = rule {
                    let position = min(cursor + passed, newEnd)
                    placements.append((old: oldIndex, range: position..<position))
                    cursor = position
                    passed = 0
                } else if let range = shadow(
                    of: rule, in: new, tokens: tokens, untouched: untouched, from: cursor, to: newEnd,
                    budget: &budget)
                {
                    placements.append((old: oldIndex, range: range))
                    cursor = range.upperBound
                    passed = 0
                } else {
                    passed += 1
                }
            }
            if anchor.old < old.count, anchor.old < rules.count, let rule = rules[anchor.old],
                untouched[anchor.new] != nil,
                isSingleShadow(new[anchor.new], tokens: tokens[anchor.new], base: untouched[anchor.new], of: rule)
            {
                placements.append((old: anchor.old, range: anchor.new..<(anchor.new + 1)))
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

    /// Whether one untouched new block is, on its own, the shadow of the server block `rule`
    /// was made for. `tokens` are `signatureTokens(of: block)`; `base` is the base block the
    /// user left it as (`untouched`).
    static func isSingleShadow(_ block: BlockNoteBlock, tokens: [String], base: Int?, of rule: Rule) -> Bool {
        switch rule {
        case .exact(let node, let props, let runs): return isExactShadow(block, node: node, props: props, runs: runs)
        case .media(let url): return isMediaShadow(block, url: url)
        case .text(let words): return !words.isEmpty && tokens == words
        case .listTree(_, _, _, _, let origin):
            return origin != nil && base == origin && isListTreeShadow(block, tokens: tokens, of: rule)
        case .invisible: return false
        }
    }

    private static func shadow(
        of rule: Rule, in new: [BlockNoteBlock], tokens: [[String]], untouched: [Int: Int], from start: Int,
        to end: Int, budget: inout Int
    ) -> Range<Int>? {
        guard start < end else { return nil }
        switch rule {
        case .invisible:
            return nil
        case .exact(let node, let props, let runs):
            for index in start..<end where untouched[index] != nil {
                budget -= 1
                if isExactShadow(new[index], node: node, props: props, runs: runs) { return index..<(index + 1) }
            }
            return nil
        case .media(let url):
            for index in start..<end where untouched[index] != nil {
                budget -= 1
                if isMediaShadow(new[index], url: url) { return index..<(index + 1) }
            }
            return nil
        case .listTree:
            for index in start..<end where untouched[index] != nil {
                budget -= 1
                if isSingleShadow(new[index], tokens: tokens[index], base: untouched[index], of: rule) {
                    return index..<(index + 1)
                }
            }
            return nil
        case .text(let words):
            guard !words.isEmpty else { return nil }
            for first in start..<end {
                guard let firstBase = untouched[first] else { continue }
                budget -= 1
                guard budget > 0 else { return nil }
                let firstTokens = tokens[first]
                guard !firstTokens.isEmpty, words.starts(with: firstTokens) else { continue }
                var matched = firstTokens.count
                var last = first
                // Each further block must have followed the last one in the base too: one run
                // there, so it was this block's export and not its neighbour's.
                while matched < words.count, last + 1 < end, untouched[last + 1] == firstBase + (last + 1 - first) {
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
