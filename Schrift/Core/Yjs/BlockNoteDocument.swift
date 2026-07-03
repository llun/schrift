import Foundation

// MARK: - BlockNote document model (the shape docs/BlockNote stores in Yjs)

/// A single inline run: a span of text carrying zero or more marks. Each mark
/// is `(key, valueJSON)` where `valueJSON` is `"{}"` for a boolean mark
/// (bold/italic/code/strike) or e.g. `#"{"href":"…"}"#` for a link.
struct InlineRun: Equatable {
    var text: String
    var marks: [(key: String, valueJSON: String)]

    init(_ text: String, marks: [(key: String, valueJSON: String)] = []) {
        self.text = text
        self.marks = marks
    }

    static func == (lhs: InlineRun, rhs: InlineRun) -> Bool {
        lhs.text == rhs.text && lhs.marks.map { [$0.key, $0.valueJSON] } == rhs.marks.map { [$0.key, $0.valueJSON] }
    }
}

/// A BlockNote block: a `blockContainer` wrapping one content element
/// (`paragraph`, `heading`, `bulletListItem`, …). `props` are the content
/// element's ordered attributes; `divider` carries no text and no props.
struct BlockNoteBlock: Equatable {
    var node: String
    var props: [(key: String, value: YAnyValue)]
    var runs: [InlineRun]
    var id: String

    var hasTextChild: Bool { node != "divider" }

    static func == (lhs: BlockNoteBlock, rhs: BlockNoteBlock) -> Bool {
        lhs.node == rhs.node && lhs.id == rhs.id && lhs.runs == rhs.runs
            && lhs.props.map { [$0.key, String(describing: $0.value)] }
                == rhs.props.map { [$0.key, String(describing: $0.value)] }
    }
}

// MARK: - BlockNote document -> Yjs update

enum BlockNoteYjs {
    static let fragmentField = "document-store"

    /// Encodes a BlockNote document into a Yjs v1 update (base64-ready `Data`)
    /// byte-identical to what `blocksToYDoc(blocks, "document-store")` +
    /// `Y.encodeStateAsUpdate` produce for the same blocks and client id.
    static func encode(_ blocks: [BlockNoteBlock], clientID: UInt32) -> Data {
        var items: [YItem] = []
        var clock = 0

        func emit(
            _ content: YContent, origin: Int? = nil, parentRootKey: String? = nil,
            parentClock: Int? = nil, parentSub: String? = nil
        ) -> Int {
            let start = clock
            items.append(
                YItem(
                    clock: start, origin: origin, parentRootKey: parentRootKey,
                    parentClock: parentClock, parentSub: parentSub, content: content))
            clock += content.length
            return start
        }

        let blockGroup = emit(.xmlElement(nodeName: "blockGroup"), parentRootKey: fragmentField)

        var previousContainer: Int?
        for block in blocks {
            let container: Int
            if let previous = previousContainer {
                container = emit(.xmlElement(nodeName: "blockContainer"), origin: previous)
            } else {
                container = emit(.xmlElement(nodeName: "blockContainer"), parentClock: blockGroup)
            }

            let element = emit(.xmlElement(nodeName: block.node), parentClock: container)

            if block.hasTextChild {
                let text = emit(.xmlText, parentClock: element)
                emitInline(block.runs, parentText: text, emit: emit)
                for prop in block.props {
                    _ = emit(.any([prop.value]), parentClock: element, parentSub: prop.key)
                }
            }
            _ = emit(.any([.string(block.id)]), parentClock: container, parentSub: "id")

            previousContainer = container
        }

        return YjsUpdateEncoder.encode(clientID: clientID, items: items)
    }

    /// Emits the string/format item sequence for a run list, mirroring yjs
    /// `Y.XmlText.applyDelta`: marks are opened when they first appear, carried
    /// across runs, and closed (value `null`) once no longer active — including
    /// after the final run.
    private static func emitInline(
        _ runs: [InlineRun],
        parentText: Int,
        emit: (YContent, Int?, String?, Int?, String?) -> Int
    ) {
        var lastClock: Int? = nil  // clock of the previously emitted item's last position
        var openMarks: [(key: String, valueJSON: String)] = []

        func emitItem(_ content: YContent) {
            let origin = lastClock
            let parentClock = lastClock == nil ? parentText : nil
            let start = emit(content, origin, nil, parentClock, nil)
            lastClock = start + content.length - 1
        }

        for run in runs {
            let newMarks = run.marks
            // Close marks that are open but not present (or changed) in this run.
            for open in openMarks
            where !newMarks.contains(where: { $0.key == open.key && $0.valueJSON == open.valueJSON }) {
                emitItem(.format(key: open.key, valueJSON: "null"))
            }
            // Open marks newly present in this run.
            for mark in newMarks
            where !openMarks.contains(where: { $0.key == mark.key && $0.valueJSON == mark.valueJSON }) {
                emitItem(.format(key: mark.key, valueJSON: mark.valueJSON))
            }
            if !run.text.isEmpty {
                emitItem(.string(run.text))
            }
            openMarks = newMarks
        }
        // Close any marks still open after the last run.
        for open in openMarks {
            emitItem(.format(key: open.key, valueJSON: "null"))
        }
    }
}
