import Foundation

// MARK: - Yjs replica projection (B5 of the live-editing roadmap)

/// The read side of the live document bridge (C1): a total, never-trapping
/// projection of a `YDoc` replica into BlockNote-vocabulary blocks. A walk of
/// `document → blockGroup → blockContainer*` folds each text child's string
/// and format items back into `InlineRun`s for rendering. Every block carries
/// a `ProjectionFidelity` recording whether it can round-trip losslessly
/// (`.modeled`), renders with export parity but would lose data on write-back
/// (`.lossy`), or cannot be represented as markdown at all (`.opaque`).
/// Anything unexpected in the replica projects `.opaque`; nothing here throws
/// or traps.

/// A single projected block property: a key and a typed value decoded from the
/// Yjs replica. Properties are sorted by key for determinism in the projected
/// document and write-back path.
struct ProjectedProp: Equatable, Sendable {
    /// The property name (e.g. "level" for a heading, "url" for an image).
    var key: String
    /// The property value, one of the scalar/object/array cases from yjs's wire
    /// format. The value's type and presence drive fidelity classification.
    var value: YAnyValue
}

/// A single block projected from the Yjs replica: its BlockNote id, node type,
/// and decoded properties and inline runs. The id is the container map's "id"
/// field and serves as C1's identity map key for the live-write projection path.
/// Props are sorted by key for determinism.
struct ProjectedBlock: Equatable {
    /// The BlockNote block id from the replica's container-map "id" field.
    /// This is the key used to track the block identity across live edits (C1).
    var id: String
    /// The node type string: "paragraph", "heading", "bulletListItem", etc.,
    /// drawn from the content element in the blockContainer.
    var node: String
    /// The block's properties, sorted by key. Ordered attributes of the content
    /// element: heading level, list type, image url, etc.
    var props: [ProjectedProp]
    /// The block's inline content — text runs with their marks. Empty for leaf
    /// nodes like divider. Built from the xmlText child's content.
    var runs: [InlineRun]
    /// The fidelity classification of this block: whether it can be rendered,
    /// written back, or neither.
    var fidelity: ProjectionFidelity
}

/// The fidelity of a projected block: whether it can be faithfully rendered,
/// written back to the server, or neither.
enum ProjectionFidelity: Equatable, Sendable {
    /// The block is fully modeled and can be rendered and written back without
    /// data loss. This is the normal case for blocks built from the schema the
    /// app understands.
    case modeled
    /// The block can be rendered as markdown with visual fidelity equal to what
    /// the server would export, but writing it back would lose information. This
    /// happens when a block carries properties or structure the app's editor
    /// does not model (e.g. an unknown property on a heading, or a custom block
    /// type the app doesn't define). The block is frozen in the UI and cannot be
    /// edited.
    case lossy(reasons: [String])
    /// The block cannot be rendered as markdown at all — it requires server-side
    /// interpretation or carries a type or structure the app cannot display. The
    /// document containing this block cannot be edited, and the block appears as
    /// a placeholder or read-only element.
    case opaque(reason: String)

    /// True only for `.opaque` — the block cannot be rendered as markdown at all.
    /// The projector uses this to decide document-level `isFullyRenderable`.
    var isOpaque: Bool {
        if case .opaque = self { return true }
        return false
    }
}

/// The projection of a Yjs replica into BlockNote blocks: a sequence of
/// projected blocks with metadata about whether they can be rendered and
/// written back. Not `Sendable` because it contains `ProjectedBlock`, which
/// cannot be `Sendable` due to `InlineRun`'s tuple marks (C1 stays on the
/// main actor — nothing crosses isolation domains in Phase B).
struct ProjectedDocument: Equatable {
    /// The blocks of the document in order, each projected from the replica's
    /// blockGroup and blockContainer tree.
    var blocks: [ProjectedBlock]
    /// True if every block has .modeled or .lossy fidelity (no .opaque blocks)
    /// and the document's root shape is the canonical blockGroup + blockContainer
    /// structure. Fully renderable documents can be displayed and edited if all
    /// blocks are .modeled; lossy blocks are display-only. Non-fully-renderable
    /// documents cannot be rendered at all.
    var isFullyRenderable: Bool
    /// True if isFullyRenderable is true AND every block has .modeled fidelity
    /// (no .lossy blocks). Only fully modeled documents can be written back to
    /// the server without data loss.
    var isFullyModeled: Bool
}

// MARK: - The structural walk

/// The namespace for `project(_:)`. A caseless enum, matching the rest of
/// `Core/Yjs`'s pure-logic style — this is stateless value code, callable from
/// any isolation domain.
enum YBlockProjection {}

extension YBlockProjection {
    /// Non-deleted child items of a type, in list order. Includes non-countable
    /// items (formats) when `includeFormats` — the text fold needs them.
    private static func children(of type: YType, includeFormats: Bool) -> [YItem] {
        var result: [YItem] = []
        var item = type.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted else { continue }
            if !includeFormats, !current.countable { continue }
            result.append(current)
        }
        return result
    }

    /// Projects a live Yjs replica into BlockNote blocks: a walk of
    /// `document-store → blockGroup → blockContainer*`. Total and
    /// never-trapping — the replica is peer-controlled data (a remote update
    /// applied it), never a trusted invariant, so any shape that isn't the
    /// canonical one downgrades to `.opaque`/non-renderable output instead of
    /// throwing.
    static func project(_ doc: YDoc) -> ProjectedDocument {
        guard let root = doc.share[BlockNoteYjs.fragmentField] else {
            return ProjectedDocument(blocks: [], isFullyRenderable: true, isFullyModeled: true)  // empty replica
        }
        let rootChildren = children(of: root, includeFormats: false)
        if rootChildren.isEmpty {
            return ProjectedDocument(blocks: [], isFullyRenderable: true, isFullyModeled: true)
        }
        // Canonical shape: exactly one blockGroup at the root.
        guard rootChildren.count == 1, case .type(let group) = rootChildren[0].content,
            group.typeRef == .xmlElement(nodeName: "blockGroup")
        else {
            return ProjectedDocument(blocks: [], isFullyRenderable: false, isFullyModeled: false)
        }
        var blocks: [ProjectedBlock] = []
        for containerItem in children(of: group, includeFormats: false) {
            blocks.append(projectContainer(containerItem))
        }
        let renderable = blocks.allSatisfy { !$0.fidelity.isOpaque }
        let modeled = renderable && blocks.allSatisfy { $0.fidelity == .modeled }
        return ProjectedDocument(blocks: blocks, isFullyRenderable: renderable, isFullyModeled: modeled)
    }

    // MARK: - Per-block projection

    /// Builds one projected block from a `blockGroup` child item. Every branch
    /// either returns a fully classified block or an `.opaque` one recording
    /// why — never a trap or a thrown error.
    private static func projectContainer(_ containerItem: YItem) -> ProjectedBlock {
        guard case .type(let containerType) = containerItem.content,
            containerType.typeRef == .xmlElement(nodeName: "blockContainer")
        else {
            return opaqueBlock(id: "", reason: "unexpected root child")
        }
        guard let id = blockID(of: containerType) else {
            return opaqueBlock(id: "", reason: "missing block id")
        }

        // Exactly one element child is expected. A second child that is itself
        // a nested blockGroup means this block has sub-page children — a
        // structure this projection does not model (opaque, not just lossy:
        // there is no flat markdown spelling for it).
        let containerChildren = children(of: containerType, includeFormats: false)
        guard containerChildren.count == 1 else {
            if containerChildren.count == 2, case .type(let second) = containerChildren[1].content,
                second.typeRef == .xmlElement(nodeName: "blockGroup")
            {
                return opaqueBlock(id: id, reason: "nested children")
            }
            return opaqueBlock(id: id, reason: "unexpected container shape")
        }
        guard case .type(let element) = containerChildren[0].content,
            case .xmlElement(let node)? = element.typeRef
        else {
            return opaqueBlock(id: id, reason: "unexpected container shape")
        }

        let (props, propsFailure) = readProps(element)
        if let propsFailure {
            return ProjectedBlock(id: id, node: node, props: [], runs: [], fidelity: .opaque(reason: propsFailure))
        }
        let (rawRuns, runsFailure) = foldInline(element)
        if let runsFailure {
            return ProjectedBlock(id: id, node: node, props: props, runs: [], fidelity: .opaque(reason: runsFailure))
        }
        // A link mark whose value doesn't parse to a usable href can't be
        // rendered or written back at all — opaque outranks every other
        // classification, so this is checked before node-specific rules.
        if rawRuns.contains(where: { run in
            run.marks.contains { $0.key == "link" && linkHref(from: $0.valueJSON) == nil }
        }) {
            return ProjectedBlock(id: id, node: node, props: props, runs: [], fidelity: .opaque(reason: "badLink"))
        }

        // Structural classification (props + node-specific rules) reads the
        // *raw* runs, because whether a node may carry marks at all (codeBlock
        // must not; divider/image must carry no runs) is independent of
        // whether any individual mark key is one the app recognizes.
        let structural = classifyStructure(node: node, props: props, runs: rawRuns)
        let (scrubbedRuns, markReasons) = scrubUnknownMarks(rawRuns)
        let fidelity = mergingMarkReasons(markReasons, into: structural)
        return ProjectedBlock(id: id, node: node, props: props, runs: scrubbedRuns, fidelity: fidelity)
    }

    private static func opaqueBlock(id: String, reason: String) -> ProjectedBlock {
        ProjectedBlock(id: id, node: "", props: [], runs: [], fidelity: .opaque(reason: reason))
    }

    /// The block's BlockNote id: the container type's "id" map entry, which
    /// `BlockNoteYjs.encode` always writes as a single-value `.any` content.
    /// Read independently of the element/props/runs walk below, so an opaque
    /// block still carries a real id whenever the id itself was legible.
    private static func blockID(of containerType: YType) -> String? {
        guard let idItem = containerType.map["id"], !idItem.deleted,
            case .any(let values) = idItem.content, values.count == 1,
            case .string(let id) = values[0]
        else { return nil }
        return id
    }

    /// Reads the content element's attribute map into sorted, typed props.
    /// Every prop the encoder writes is a single-value `.any` map entry; any
    /// entry that isn't fails the whole block, since there is no way to know
    /// what an unreadable attribute might have meant.
    private static func readProps(_ element: YType) -> (props: [ProjectedProp], failureReason: String?) {
        var props: [ProjectedProp] = []
        for (key, item) in element.map {
            guard !item.deleted else { continue }
            guard case .any(let values) = item.content, values.count == 1 else {
                return ([], "unreadable prop")
            }
            props.append(ProjectedProp(key: key, value: values[0]))
        }
        return (props.sorted { $0.key < $1.key }, nil)
    }

    /// Folds a content element's inline children into `InlineRun`s. Each child
    /// must be an `xmlText`; walking each one's items replays
    /// `BlockNoteYjs.emitInline`'s delta encoding in reverse — a `"null"`
    /// format closes a mark, any other format value replaces the open entry
    /// for that key (appended at the end, the deterministic order), and a
    /// string is appended to the run under the currently open marks. Marks
    /// never carry across sibling `xmlText` children, matching the encoder,
    /// which always starts a fresh block's text with no open marks.
    ///
    /// A non-text element child is opaque `"non-text inline content"` for now
    /// — a later task adds the `interlinkingLinkInline` inline node.
    private static func foldInline(_ element: YType) -> (runs: [InlineRun], failureReason: String?) {
        var runs: [InlineRun] = []
        for child in children(of: element, includeFormats: false) {
            guard case .type(let textType) = child.content, textType.typeRef == .xmlText else {
                return ([], "non-text inline content")
            }
            var openMarks: [(key: String, valueJSON: String)] = []
            for item in children(of: textType, includeFormats: true) {
                switch item.content {
                case .string(let units):
                    appendRun(text: String(decoding: units, as: UTF16.self), marks: openMarks, to: &runs)
                case .format(let key, let valueJSON):
                    openMarks.removeAll { $0.key == key }
                    if valueJSON != "null" {
                        openMarks.append((key: key, valueJSON: valueJSON))
                    }
                default:
                    return ([], "unexpected text content")
                }
            }
        }
        return (runs, nil)
    }

    /// Appends visible text to `runs`, coalescing with the last run when marks
    /// match exactly and dropping empty text outright.
    private static func appendRun(
        text: String, marks: [(key: String, valueJSON: String)], to runs: inout [InlineRun]
    ) {
        guard !text.isEmpty else { return }
        if let last = runs.last, sameMarks(last.marks, marks) {
            runs[runs.count - 1] = InlineRun(last.text + text, marks: marks)
        } else {
            runs.append(InlineRun(text, marks: marks))
        }
    }

    private static func sameMarks(
        _ a: [(key: String, valueJSON: String)], _ b: [(key: String, valueJSON: String)]
    ) -> Bool {
        a.map { [$0.key, $0.valueJSON] } == b.map { [$0.key, $0.valueJSON] }
    }

    /// Drops any mark whose key isn't in the vocabulary the app's markdown
    /// export understands (bold/italic/code/strike/link), reporting a lossy
    /// reason per dropped key. The server's own markdown export drops unknown
    /// marks the same way, so this keeps write-back parity rather than
    /// inventing a new divergence.
    private static func scrubUnknownMarks(_ runs: [InlineRun]) -> (runs: [InlineRun], reasons: [String]) {
        var reasons: [String] = []
        let result = runs.map { run -> InlineRun in
            var kept: [(key: String, valueJSON: String)] = []
            for mark in run.marks {
                switch mark.key {
                case "bold", "italic", "code", "strike", "link":
                    kept.append(mark)
                default:
                    let reason = "unknownMark:\(mark.key)"
                    if !reasons.contains(reason) { reasons.append(reason) }
                }
            }
            return InlineRun(run.text, marks: kept)
        }
        return (result, reasons)
    }

    /// Extracts a link mark's `href` by parsing the JSON value — never a
    /// literal scan — so escaping differences (e.g. `\/` vs `/`) never matter
    /// here; only the byte-exact encoder (`InlineMarkdown.linkValueJSON`) cares
    /// about that. `nil` means the value is unreadable as `{"href": string}`.
    private static func linkHref(from valueJSON: String) -> String? {
        guard let data = valueJSON.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dict = object as? [String: Any] else { return nil }
        return dict["href"] as? String
    }

    /// Folds mark-vocabulary lossy reasons into a node's structural fidelity.
    /// Opaque always wins (nothing can render); a lossy reason list gains the
    /// mark reasons; a modeled result becomes lossy if any mark reasons exist.
    private static func mergingMarkReasons(
        _ markReasons: [String], into structural: ProjectionFidelity
    ) -> ProjectionFidelity {
        switch structural {
        case .opaque:
            return structural
        case .modeled:
            return markReasons.isEmpty ? .modeled : .lossy(reasons: markReasons)
        case .lossy(let reasons):
            return .lossy(reasons: reasons + markReasons)
        }
    }

    // MARK: - Fidelity classification (the inverse of `MarkdownYjs.map`)

    private static func value(for key: String, in props: [ProjectedProp]) -> YAnyValue? {
        props.first { $0.key == key }?.value
    }

    /// paragraph/bulletListItem/heading's base props and their modeled
    /// defaults — mirrors `MarkdownYjs.baseProps`.
    private static let baseDefaults: [String: YAnyValue] = [
        "backgroundColor": .string("default"),
        "textColor": .string("default"),
        "textAlignment": .string("left"),
    ]

    /// quote's props in BlockNote 0.51.4 — no `textAlignment`.
    private static let quoteDefaults: [String: YAnyValue] = [
        "backgroundColor": .string("default"),
        "textColor": .string("default"),
    ]

    private static let imageDefaults: [String: YAnyValue] = [
        "textAlignment": .string("left"),
        "backgroundColor": .string("default"),
    ]

    /// Classifies a block's fidelity from its node name, props, and (raw,
    /// pre-mark-scrub) runs. This is deliberately the inverse of
    /// `MarkdownYjs.map`'s node/prop table: every node kind, required prop,
    /// and default value here has a matching entry there.
    private static func classifyStructure(
        node: String, props: [ProjectedProp], runs: [InlineRun]
    ) -> ProjectionFidelity {
        switch node {
        case "paragraph", "bulletListItem":
            return classifyDefaultsOnly(props, defaults: baseDefaults)
        case "heading":
            return classifyHeading(props)
        case "numberedListItem":
            return classifyNumberedListItem(props)
        case "checkListItem":
            return classifyCheckListItem(props)
        case "quote":
            return classifyDefaultsOnly(props, defaults: quoteDefaults)
        case "codeBlock":
            return classifyCodeBlock(props, runs: runs)
        case "divider":
            return classifyDivider(props, runs: runs)
        case "image":
            return classifyImage(props, runs: runs)
        default:
            return .opaque(reason: "unknownNode:\(node)")
        }
    }

    /// A node whose only props are a subset of the known default-valued keys:
    /// present-but-non-default is lossy, present-and-unrecognized is lossy,
    /// absent silently defaults (modeled). Covers paragraph, bulletListItem,
    /// and quote.
    private static func classifyDefaultsOnly(
        _ props: [ProjectedProp], defaults: [String: YAnyValue]
    ) -> ProjectionFidelity {
        var reasons: [String] = []
        for prop in props {
            if let def = defaults[prop.key] {
                if prop.value != def { reasons.append("prop:\(prop.key)") }
            } else {
                reasons.append("unknownProp:\(prop.key)")
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyHeading(_ props: [ProjectedProp]) -> ProjectionFidelity {
        // Collapsible headings are structural (they own children), which this
        // flat projection cannot express — opaque, not lossy. Same for a
        // missing/out-of-range level: there is no default to fall back to.
        guard let levelValue = value(for: "level", in: props) else {
            return .opaque(reason: "missing heading level")
        }
        guard case .int(let level) = levelValue, (1...6).contains(level) else {
            return .opaque(reason: "invalid heading level")
        }
        if case .bool(true)? = value(for: "isToggleable", in: props) {
            return .opaque(reason: "toggleable heading")
        }
        let known: Set<String> = ["backgroundColor", "textColor", "textAlignment", "level", "isToggleable"]
        var reasons: [String] = []
        for prop in props {
            guard known.contains(prop.key) else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            if prop.key == "isToggleable" {
                // `.bool(true)` already returned `.opaque` above; only
                // `.bool(false)` is modeled here — the app's own encoder emits
                // `.bool(false)` explicitly, and absence never reaches this loop.
                // Any other value type is data a markdown write-back can't
                // honor (there is no bool to round-trip), so it's lossy rather
                // than silently falling through as modeled.
                if case .bool(false) = prop.value {
                } else {
                    reasons.append("prop:isToggleable")
                }
                continue
            }
            if let def = baseDefaults[prop.key], prop.value != def {
                reasons.append("prop:\(prop.key)")
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyNumberedListItem(_ props: [ProjectedProp]) -> ProjectionFidelity {
        let known: Set<String> = ["backgroundColor", "textColor", "textAlignment", "start"]
        var reasons: [String] = []
        for prop in props {
            guard known.contains(prop.key) else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            if prop.key == "start" {
                switch prop.value {
                case .null, .int(1):
                    break  // modeled: no explicit start, or the default first item
                default:
                    reasons.append("prop:start")
                }
                continue
            }
            if let def = baseDefaults[prop.key], prop.value != def {
                reasons.append("prop:\(prop.key)")
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyCheckListItem(_ props: [ProjectedProp]) -> ProjectionFidelity {
        let known: Set<String> = ["backgroundColor", "textColor", "textAlignment", "checked"]
        var reasons: [String] = []
        for prop in props {
            guard known.contains(prop.key) else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            if prop.key == "checked" {
                if case .bool = prop.value {
                    // Either state is modeled; there is no "default" to compare.
                } else {
                    reasons.append("prop:checked")
                }
                continue
            }
            if let def = baseDefaults[prop.key], prop.value != def {
                reasons.append("prop:\(prop.key)")
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyCodeBlock(_ props: [ProjectedProp], runs: [InlineRun]) -> ProjectionFidelity {
        // A code block's content never carries marks in BlockNote — any mark
        // at all (known or not) means this replica's code block was formatted
        // in a way the app cannot reproduce as markdown.
        if runs.count > 1 || runs.contains(where: { !$0.marks.isEmpty }) {
            return .opaque(reason: "marked code")
        }
        var reasons: [String] = []
        for prop in props {
            guard prop.key == "language" else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            if case .string = prop.value {
                // Any language string is modeled; "text" is only the default
                // when the key is absent entirely.
            } else {
                reasons.append("prop:language")
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyDivider(_ props: [ProjectedProp], runs: [InlineRun]) -> ProjectionFidelity {
        guard runs.isEmpty else {
            return .opaque(reason: "unexpected divider content")
        }
        let reasons = props.map { "unknownProp:\($0.key)" }  // divider has no known props at all
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }

    private static func classifyImage(_ props: [ProjectedProp], runs: [InlineRun]) -> ProjectionFidelity {
        guard runs.isEmpty else {
            return .opaque(reason: "unexpected image content")
        }
        // A url is what makes an image renderable at all; not just missing —
        // it must actually be text, or there is nothing to point an <img> at.
        guard case .string? = value(for: "url", in: props) else {
            return .opaque(reason: "missing url")
        }
        let known: Set<String> = [
            "textAlignment", "backgroundColor", "name", "url", "caption", "showPreview", "previewWidth",
        ]
        var reasons: [String] = []
        for prop in props {
            guard known.contains(prop.key) else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            switch prop.key {
            case "textAlignment", "backgroundColor":
                if let def = imageDefaults[prop.key], prop.value != def {
                    reasons.append("prop:\(prop.key)")
                }
            case "url":
                break  // any string is modeled; url's presence was checked above
            case "name":
                // Missing `name` defaults to "" (modeled — the app treats an
                // absent alt as empty text). A non-string value is data a
                // markdown write-back can't preserve as alt text, so it's
                // lossy rather than a silent pass-through.
                if case .string = prop.value {
                } else {
                    reasons.append("prop:name")
                }
            case "caption":
                if case .string("") = prop.value {
                } else {
                    reasons.append("prop:caption")
                }
            case "showPreview":
                if case .bool(true) = prop.value {
                } else {
                    reasons.append("prop:showPreview")
                }
            case "previewWidth":
                if case .undefined = prop.value {
                } else {
                    reasons.append("prop:previewWidth")
                }
            default:
                break
            }
        }
        return reasons.isEmpty ? .modeled : .lossy(reasons: reasons)
    }
}
