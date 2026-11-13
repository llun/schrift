import XCTest

@testable import Schrift

/// PR13b review F1b: `DocumentEngine.mediaLocation`'s search. Only a block id
/// absent from the whole document answers nil (an upload is dropped only
/// then); a block found but not addressable, or a search cut short by depth,
/// answers undecided (the upload waits); a cut branch never hides a block
/// found elsewhere; depth counts block levels, not XML levels.
@MainActor
final class DocumentEngineMediaLocationTests: DocumentEngineTestCase {
    /// A block: its id (nil: no id attribute), its content element (nil: none, a
    /// non-simple container) and its nested blocks.
    private struct Block {
        var id: String?
        var element: String? = "paragraph"
        var children: [Block] = []
    }

    /// A column group: its id and its columns' ids (nil: unreadable) and blocks.
    private struct Group {
        var id: String = "cl"
        var columns: [(id: String?, blocks: [Block])]
    }

    /// `depth` paragraphs nested one inside the next, ending with `last`.
    private func chain(_ depth: Int, prefix: String, last: Block) -> Block {
        var block = last
        for level in (0..<depth).reversed() { block = Block(id: "\(prefix)\(level)", children: [block]) }
        return block
    }

    private func location(_ id: String, root: [Block] = [], group: Group?) throws -> MediaLocation? {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let fragment = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            func element(_ name: String, into parent: YType, after: YItem?, id: String? = nil) throws -> (YItem?, YType)
            {
                let type = YType(typeRef: .xmlElement(nodeName: name))
                let item = try YWrite.insertAfter(tx, into: parent, after: after, [.type(type)])
                if let id { try YWrite.mapSet(tx, on: type, key: "id", .any([.string(id)])) }
                return (item, type)
            }
            func add(_ block: Block, into parent: YType, after: YItem?) throws -> YItem? {
                let (item, container) = try element("blockContainer", into: parent, after: after, id: block.id)
                var last: YItem?
                if let name = block.element {
                    let (elementItem, content) = try element(name, into: container, after: nil)
                    if name == "image" {
                        for (key, value) in [("url", ""), ("name", "")] {
                            try YWrite.mapSet(tx, on: content, key: key, .any([.string(value)]))
                        }
                    }
                    last = elementItem
                }
                if !block.children.isEmpty {
                    let (_, nested) = try element("blockGroup", into: container, after: last)
                    var previous: YItem?
                    for child in block.children { previous = try add(child, into: nested, after: previous) }
                }
                return item
            }
            let (_, rootGroup) = try element("blockGroup", into: fragment, after: nil)
            var previous = try add(Block(id: "lead"), into: rootGroup, after: nil)
            for block in root { previous = try add(block, into: rootGroup, after: previous) }
            if let group {
                let (listItem, list) = try element("columnList", into: rootGroup, after: previous, id: group.id)
                var lastColumn: YItem?
                for column in group.columns {
                    let (columnItem, columnType) = try element("column", into: list, after: lastColumn, id: column.id)
                    lastColumn = columnItem
                    var last: YItem?
                    for block in column.blocks { last = try add(block, into: columnType, after: last) }
                }
                previous = listItem
            }
            _ = try add(Block(id: "tail"), into: rootGroup, after: previous)
        }
        let engine = DocumentEngine(doc: doc, surface: HeadlessSurface(blocks: projection(doc)))
        return engine.mediaLocation(id)
    }

    private let image = Block(id: "m", element: "image")

    func testAnIdAbsentFromTheDocumentIsNil() throws {
        XCTAssertNil(try location("absent", group: Group(columns: [("c1", [Block(id: "a")])])))
    }

    /// (b) 40 block levels inside a closed column (about 80 XML levels) is
    /// within the projection's 64 block levels: found, with its column.
    func testDepthCountsBlockLevels() throws {
        let found = try XCTUnwrap(
            location("m", group: Group(columns: [("c1", [chain(40, prefix: "d", last: image)])])))
        XCTAssertFalse(found.isUndecided)
        XCTAssertEqual(found.slot.node, "image")
        XCTAssertEqual(found.column, MediaLocation.Column(group: "cl", id: "c1"))
    }

    /// (c) A branch cut by depth in one column never hides the block at the
    /// top of the next; a cut with the block nowhere else is undecided.
    func testACutBranchNeverStopsTheSearch() throws {
        let deep = chain(70, prefix: "d", last: Block(id: "bottom"))
        let found = try XCTUnwrap(
            location("m", group: Group(columns: [("c1", [deep]), ("c2", [image])])))
        XCTAssertFalse(found.isUndecided)
        XCTAssertEqual(found.column, MediaLocation.Column(group: "cl", id: "c2"))
        let cut = try XCTUnwrap(location("m", group: Group(columns: [("c1", [deep]), ("c2", [Block(id: "c")])])))
        XCTAssertTrue(cut.isUndecided, "maybe below the cut: undecided, never absent")
    }

    /// (d) Found but not addressable is undecided, never absent: a column with
    /// no id, an indexed container with no content element.
    func testAFoundButUnaddressableBlockIsUndecided() throws {
        let noColumnID = try XCTUnwrap(location("m", group: Group(columns: [(nil, [image])])))
        XCTAssertTrue(noColumnID.isUndecided)
        let bare = try XCTUnwrap(
            location("x", root: [Block(id: "x", element: nil, children: [Block(id: "inner")])], group: nil))
        XCTAssertTrue(bare.isUndecided)
    }
}
