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
///
/// **The web editor's `interlinkingLinkInline` custom node** (a document link
/// authored in the web client — `y-provider`'s `InterlinkingLinkInline.ts`) is
/// a `content: 'none'` inline leaf: y-prosemirror represents it as its own
/// `Y.XmlElement` sibling in the *same* children list as the surrounding
/// `Y.XmlText` runs inside a content element — never nested inside one
/// `xmlText`'s item list — confirmed against a captured oracle fixture. Its
/// href is never stored on the wire (the web client computes it at export
/// time as `${instanceOrigin}/docs/${docId}/`), so projecting it into a real
/// link run needs the server origin the app itself is talking to. `project`
/// therefore takes an optional `interlinkingOrigin`: when it's `nil` — the
/// default, so every existing caller is unaffected — or the node is
/// disabled/carries no usable `docId`, the containing block is `.opaque`
/// rather than guessing at or dropping the link.

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
    ///
    /// `interlinkingOrigin` is the server origin (e.g.
    /// `"https://docs.example.test"`) needed to build a faithful href for an
    /// `interlinkingLinkInline` node — see the file overview. `nil` (the
    /// default) makes every such node opaque rather than affecting any other
    /// block, so existing callers are unchanged.
    static func project(_ doc: YDoc, interlinkingOrigin: String? = nil) -> ProjectedDocument {
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
            blocks.append(projectContainer(containerItem, interlinkingOrigin: interlinkingOrigin))
        }
        let renderable = blocks.allSatisfy { !$0.fidelity.isOpaque }
        let modeled = renderable && blocks.allSatisfy { $0.fidelity == .modeled }
        return ProjectedDocument(blocks: blocks, isFullyRenderable: renderable, isFullyModeled: modeled)
    }

    // MARK: - Per-block projection

    /// Builds one projected block from a `blockGroup` child item. Every branch
    /// either returns a fully classified block or an `.opaque` one recording
    /// why — never a trap or a thrown error.
    private static func projectContainer(_ containerItem: YItem, interlinkingOrigin: String?) -> ProjectedBlock {
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
        let (rawRuns, runsFailure) = foldInline(element, interlinkingOrigin: interlinkingOrigin)
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

    /// The `interlinkingLinkInline` node name — see the file overview.
    private static let interlinkingLinkNodeName = "interlinkingLinkInline"

    /// Folds a content element's inline children into `InlineRun`s. Each child
    /// is either an `xmlText` — walking its items replays
    /// `BlockNoteYjs.emitInline`'s delta encoding in reverse: a `"null"`
    /// format closes a mark, any other format value replaces the open entry
    /// for that key (appended at the end, the deterministic order), and a
    /// string is appended to the run under the currently open marks — or an
    /// `interlinkingLinkInline` element, folded into a single link run by
    /// `projectInterlinkingLink`. Marks never carry across sibling `xmlText`
    /// children (matching the encoder, which always starts a fresh block's
    /// text with no open marks) or across an interlinking node in between.
    ///
    /// Any other child shape is opaque `"non-text inline content"`.
    private static func foldInline(
        _ element: YType, interlinkingOrigin: String?
    ) -> (runs: [InlineRun], failureReason: String?) {
        var runs: [InlineRun] = []
        for child in children(of: element, includeFormats: false) {
            guard case .type(let childType) = child.content else {
                return ([], "non-text inline content")
            }
            if childType.typeRef == .xmlText {
                var openMarks: [(key: String, valueJSON: String)] = []
                for item in children(of: childType, includeFormats: true) {
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
            } else if childType.typeRef == .xmlElement(nodeName: interlinkingLinkNodeName) {
                guard let (text, href) = projectInterlinkingLink(childType, interlinkingOrigin: interlinkingOrigin)
                else {
                    return ([], "interlinkingLink")
                }
                appendRun(text: text, marks: [(key: "link", valueJSON: linkValueJSON(href))], to: &runs)
            } else {
                return ([], "non-text inline content")
            }
        }
        return (runs, nil)
    }

    /// Projects an `interlinkingLinkInline` node (the web editor's custom
    /// document-link node) into `(label, href)`, or `nil` when it can't be
    /// faithfully rendered as a markdown link — never a lossy guess. The href
    /// is never stored on the wire; the web client computes it at export time
    /// as `${instanceOrigin}/docs/${docId}/`, so this needs the caller-supplied
    /// server origin to reproduce it.
    ///
    /// `nil` when: `interlinkingOrigin` is nil (no origin to build a parity
    /// URL from); the node is `disabled`; `docId` is missing, empty, or not a
    /// string; or `docId` contains a character `encodeURIComponent` would
    /// escape — this app's `DocumentLink` compares the raw `/docs/<id>/` path
    /// byte-for-byte and never unescapes it, so a docId needing escaping has
    /// no faithful raw-path spelling here.
    ///
    /// Reads `docId`/`title`/`disabled` from the type's map the same way
    /// `readProps` does: every attribute `Y.XmlElement.setAttribute` writes is
    /// a single-value `.any` map entry.
    private static func projectInterlinkingLink(
        _ type: YType, interlinkingOrigin: String?
    ) -> (text: String, href: String)? {
        guard let interlinkingOrigin else { return nil }
        func attr(_ key: String) -> YAnyValue? {
            guard let item = type.map[key], !item.deleted,
                case .any(let values) = item.content, values.count == 1
            else { return nil }
            return values[0]
        }
        if case .bool(true)? = attr("disabled") { return nil }
        guard case .string(let docID)? = attr("docId"), isSimpleDocID(docID) else { return nil }
        let origin = trimmingTrailingSlashes(interlinkingOrigin)
        let href = "\(origin)/docs/\(docID)/"
        if case .string(let title)? = attr("title"), !title.isEmpty {
            return (title, href)
        }
        return (docID, href)
    }

    /// Trims trailing `/`s from a caller-supplied origin so the built href
    /// never double-slashes (`"https://x/"` + `"/docs/…"` → `"https://x//docs/…"`).
    private static func trimmingTrailingSlashes(_ origin: String) -> String {
        var result = Substring(origin)
        while result.hasSuffix("/") { result.removeLast() }
        return String(result)
    }

    /// True for a non-empty id built only from characters `encodeURIComponent`
    /// never escapes (a real docId is a lowercase UUID, well inside this set).
    /// Anything else can't be embedded in a href this app's `DocumentLink`
    /// compares as a raw, unescaped path segment.
    private static func isSimpleDocID(_ docID: String) -> Bool {
        !docID.isEmpty
            && docID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// BlockNote stores a link mark's destination as `{"href": …}`. Mirrors
    /// `InlineMarkdown`'s private `linkValueJSON(_:)` exactly — built with
    /// `JSONSerialization` and `.withoutEscapingSlashes`, never string
    /// interpolation (the href is derived from peer-controlled replica data) —
    /// so a projected interlinking link carries the identical wire-shaped
    /// value a `[text](url)` link mark would, and downstream code (mark
    /// scrubbing, `linkHref(from:)`, the markdown writer) sees no difference
    /// between the two origins of a link run.
    private static func linkValueJSON(_ href: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["href": href], options: [.withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"href\":\"\"}"
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
        // `checked` is render-required — there is no default to pick `- [ ]`
        // vs `- [x]` from, exactly like heading's `level` — so a missing or
        // non-bool value is opaque rather than lossy/modeled. This keeps
        // `editorBlock`'s own `guard case .bool(let checked)? = value(for:
        // "checked", …)` in lockstep: that guard can only ever succeed for a
        // block this function has already classified as (at worst) `.lossy`,
        // never for one it called renderable but that has no bool to read.
        guard let checkedValue = value(for: "checked", in: props) else {
            return .opaque(reason: "missing checkListItem checked")
        }
        guard case .bool = checkedValue else {
            return .opaque(reason: "invalid checkListItem checked")
        }
        let known: Set<String> = ["backgroundColor", "textColor", "textAlignment", "checked"]
        var reasons: [String] = []
        for prop in props {
            guard known.contains(prop.key) else {
                reasons.append("unknownProp:\(prop.key)")
                continue
            }
            if prop.key == "checked" {
                continue  // either state is modeled; validity already checked above
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

// MARK: - Editor-vocabulary rendering + self-verifying document markdown (B5 Task 4)

extension YBlockProjection {
    /// Editor-vocabulary rendering of one projected block — the inverse of
    /// `MarkdownYjs.map`'s node/prop table. `nil` means the block cannot be
    /// rendered as markdown at this `escapeAll` setting: opaque fidelity
    /// (checked first, unconditionally), or — for the six text-bearing node
    /// kinds — a run set `InlineMarkdownWriter.write` itself cannot spell
    /// (see that type's doc comment for the exhaustive list of why).
    /// `codeBlock`/`divider`/`image` never call the writer at all: a code
    /// block's content is always its single run's raw text (code has no
    /// inline markdown grammar to invert), and `divider`/`image` carry no
    /// text. `projectedMarkdown` upgrades any single nil here to a
    /// whole-document nil — a document can't show some blocks as markdown
    /// and silently drop others.
    static func editorBlock(_ block: ProjectedBlock, escapeAll: Bool) -> (kind: BlockKind, text: String)? {
        if block.fidelity.isOpaque { return nil }
        switch block.node {
        case "heading":
            guard case .int(let level)? = value(for: "level", in: block.props) else { return nil }
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.heading(level: level), text)
        case "paragraph":
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.paragraph, text)
        case "bulletListItem":
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.bulletItem, text)
        case "numberedListItem":
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.numberedItem, text)
        case "checkListItem":
            guard case .bool(let checked)? = value(for: "checked", in: block.props) else { return nil }
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.checklistItem(checked: checked), text)
        case "quote":
            guard let text = InlineMarkdownWriter.write(block.runs, escapeAll: escapeAll) else { return nil }
            return (.quote, text)
        case "codeBlock":
            // Verbatim, never escaped — a code block's content has no inline
            // markdown grammar for the writer to invert. Absent language
            // (only reachable from a hand-crafted replica; `MarkdownYjs`
            // always writes one) defaults to "", the bare-fence spelling.
            let language: String
            if case .string(let lang)? = value(for: "language", in: block.props) {
                language = lang
            } else {
                language = ""
            }
            return (.codeBlock(language: language), block.runs.first?.text ?? "")
        case "divider":
            return (.divider, "")
        case "image":
            guard case .string(let url)? = value(for: "url", in: block.props) else { return nil }
            // Missing `name` defaults to "" — mirrors `classifyImage`'s own
            // modeled-when-absent rule.
            let alt: String
            if case .string(let name)? = value(for: "name", in: block.props) {
                alt = name
            } else {
                alt = ""
            }
            return (.image(alt: alt, url: url), "")
        default:
            return nil
        }
    }

    /// The per-block rendering `projectedMarkdown` settles on, paired with each
    /// block's BlockNote id (`document.blocks[i].id`), plus the whole-document
    /// markdown those same rendered blocks serialize to. This is C1's read-side
    /// bridge point: the identity map is keyed by BlockNote id, and the bridge
    /// must diff against exactly the per-block `(kind, text)` this function
    /// settled on — never re-derive it independently — or
    /// `serializeMarkdown(<EditorBlocks built from the paired list>)` could
    /// diverge from `.markdown` and a later save would re-parse differently
    /// than what was shown on screen.
    ///
    /// Same escalation loop as `projectedMarkdown` (see that doc comment for
    /// the bounding argument): each pass renders every block minimally first
    /// (`escapeAll: false` for any not-yet-escalated index), checks the
    /// result, and on a mismatch escalates the *first* offending block and
    /// retries. On the pass that verifies, every entry of `document.blocks` is
    /// paired with its rendered `(kind, text)` — same count and order,
    /// including blocks `serializeMarkdown` itself drops from the string
    /// (e.g. a trailing empty paragraph), which keeps the pairing aligned with
    /// `document.blocks` regardless of what the string omits.
    ///
    /// `nil` under exactly the same conditions `projectedMarkdown` returns
    /// `nil`.
    static func renderedEditorDocument(_ document: ProjectedDocument) -> (
        blocks: [ProjectedEditorBlock], markdown: String
    )? {
        guard document.isFullyRenderable else { return nil }
        var escalated = Set<Int>()  // block indices rendered with escapeAll
        for _ in 0...document.blocks.count {  // bounded: each pass escalates ≥1 new block or returns
            var rendered: [EditorBlock] = []
            for (i, block) in document.blocks.enumerated() {
                guard let (kind, text) = editorBlock(block, escapeAll: escalated.contains(i)) else { return nil }
                rendered.append(EditorBlock(kind: kind, text: text))
            }
            let markdown = serializeMarkdown(rendered)
            if let failing = firstMismatch(
                markdown: markdown, rendered: rendered, against: document, escalated: escalated)
            {
                if escalated.contains(failing) { return nil }  // escaping didn't fix it
                escalated.insert(failing)
                continue
            }
            let paired = zip(document.blocks, rendered).map { projected, editor in
                ProjectedEditorBlock(blockNoteID: projected.id, kind: editor.kind, text: editor.text)
            }
            return (paired, markdown)
        }
        return nil
    }

    /// Whole-document markdown: `nil` unless every block renders (via
    /// `editorBlock`) AND the assembled markdown re-parses
    /// (`parseEditorBlocks`) back to an equivalent document. A thin projection
    /// of `renderedEditorDocument` — see that function for the escalation
    /// loop and boundedness argument, which live there now.
    static func projectedMarkdown(_ document: ProjectedDocument) -> String? {
        renderedEditorDocument(document)?.markdown
    }

    /// Re-parses `markdown` and compares it, block by block, against the
    /// projected document it was rendered from — `projectedMarkdown`'s
    /// self-verification. `rendered` is the exact `EditorBlock` list that
    /// produced `markdown` (one `editorBlock` call per `document.blocks`
    /// entry, same count and order), which lets this drop the same
    /// empty-paragraph blocks `serializeMarkdown` itself drops while staying
    /// aligned with `document.blocks`'s original runs for the text-kind
    /// comparison below.
    ///
    /// Returns the *original* `document.blocks` index of the first block
    /// whose re-parsed kind/content diverges. `.codeBlock`/`.image` compare
    /// by `BlockKind` equality alone (it already carries the payload —
    /// language, or alt+url); every other text-bearing kind additionally
    /// compares `InlineMarkdown.parse` of the re-parsed text against
    /// `InlineMarkdownWriter.normalized` of the *original* projected runs via
    /// `runsEquivalent` (order-insensitive on marks, href-based on links) —
    /// not against the rendered text, since two different spellings
    /// (`*x*`/`_x_`) can be equally valid renderings of the same runs.
    ///
    /// When the re-parsed block count itself differs from the projected
    /// count (a block split or merged on re-parse — e.g. an embedded
    /// newline breaking one block into two lines), no single index can
    /// always be blamed by construction, so this falls back to the first
    /// index `escalated` hasn't tried yet. That fallback is what keeps
    /// `projectedMarkdown`'s loop both bounded *and* fair: every block gets
    /// one chance to escalate before the document gives up, rather than the
    /// same (possibly innocent) index being re-reported forever. Once every
    /// index has already been escalated, it falls back to re-reporting one
    /// of them, which is exactly what makes the caller's
    /// `escalated.contains(failing)` check terminate the loop.
    private static func firstMismatch(
        markdown: String, rendered: [EditorBlock], against document: ProjectedDocument, escalated: Set<Int>
    ) -> Int? {
        var kept: [(originalIndex: Int, kind: BlockKind, text: String, runs: [InlineRun])] = []
        for (index, pair) in zip(document.blocks, rendered).enumerated() {
            let (block, editorBlock) = pair
            if case .paragraph = editorBlock.kind, editorBlock.text.isEmpty { continue }
            kept.append((index, editorBlock.kind, editorBlock.text, block.runs))
        }
        let reparsed = parseEditorBlocks(markdown)

        for i in 0..<min(kept.count, reparsed.count) {
            let expected = kept[i]
            let candidate = reparsed[i]
            guard candidate.kind == expected.kind else { return expected.originalIndex }
            switch expected.kind {
            case .codeBlock:
                if candidate.text != expected.text { return expected.originalIndex }
            case .divider, .image:
                break  // the payload is already covered by the `kind` equality above
            default:
                let reparsedRuns = InlineMarkdown.parse(candidate.text)
                if !InlineMarkdownWriter.runsEquivalent(reparsedRuns, InlineMarkdownWriter.normalized(expected.runs)) {
                    return expected.originalIndex
                }
            }
        }
        guard kept.count != reparsed.count else { return nil }
        return document.blocks.indices.first(where: { !escalated.contains($0) }) ?? 0
    }
}
