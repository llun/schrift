import XCTest

@testable import Schrift

/// `pagesTreeRows` is the whole layout rule of the drawer: which nodes are
/// visible, at what depth, and with what disclosure state.
final class PagesTreeRowsTests: XCTestCase {
    private func document(_ id: UUID, title: String, numchild: Int = 0) -> Document {
        Document(
            id: id, title: title, excerpt: nil, abilities: DocumentAbilities(),
            linkReach: .restricted, linkRole: .reader, isFavorite: false,
            depth: 1, numchild: numchild, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }

    private let root = UUID()
    private let a = UUID()
    private let b = UUID()
    private let a1 = UUID()

    func testNoLoadedChildrenProducesNoRows() {
        XCTAssertTrue(pagesTreeRows(parentID: root, children: [:], expanded: []).isEmpty)
    }

    func testRootChildrenRenderAtDepthZero() {
        let children = [root: [document(a, title: "A"), document(b, title: "B")]]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [])
        XCTAssertEqual(rows.map(\.document.id), [a, b])
        XCTAssertEqual(rows.map(\.depth), [0, 0])
    }

    /// The arrow comes from the server's `numchild`, so it shows before that
    /// level has ever been fetched — otherwise every node would look like a leaf
    /// until you somehow discovered it wasn't.
    func testDisclosureFollowsNumchildNotLoadedChildren() {
        let children = [root: [document(a, title: "A", numchild: 3)]]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [])
        XCTAssertEqual(rows.first?.hasChildren, true)
        XCTAssertEqual(rows.first?.isExpanded, false)
    }

    func testCollapsedNodeHidesItsLoadedChildren() {
        let children = [
            root: [document(a, title: "A", numchild: 1)],
            a: [document(a1, title: "A1")],
        ]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [])
        XCTAssertEqual(rows.map(\.document.id), [a])
    }

    func testExpandedNodeShowsItsChildrenIndentedBeneathIt() {
        let children = [
            root: [document(a, title: "A", numchild: 1), document(b, title: "B")],
            a: [document(a1, title: "A1")],
        ]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [a])
        XCTAssertEqual(rows.map(\.document.id), [a, a1, b], "children belong directly under their parent")
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
        XCTAssertEqual(rows.first?.isExpanded, true)
    }

    /// An expanded node whose level is still in flight contributes nothing yet —
    /// it must not collapse or reorder the levels already on screen.
    func testExpandedButUnloadedNodeStillRendersItself() {
        let children = [root: [document(a, title: "A", numchild: 2)]]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [a])
        XCTAssertEqual(rows.map(\.document.id), [a])
        XCTAssertEqual(rows.first?.isExpanded, true)
    }

    /// Server data should never place a document beneath itself, but the tree
    /// walks whatever it is given, and a cycle would otherwise recurse until the
    /// stack ran out.
    func testACycleTerminatesInsteadOfRecursingForever() {
        let children = [
            root: [document(a, title: "A", numchild: 1)],
            a: [document(root, title: "Root again", numchild: 1)],
        ]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [a, root])
        XCTAssertEqual(rows.map(\.document.id), [a, root])
    }

    func testDeepNestingKeepsIncrementingDepth() {
        let c = UUID()
        let children = [
            root: [document(a, title: "A", numchild: 1)],
            a: [document(b, title: "B", numchild: 1)],
            b: [document(c, title: "C")],
        ]
        let rows = pagesTreeRows(parentID: root, children: children, expanded: [a, b])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }
}

final class PagesTreeLayoutTests: XCTestCase {
    /// The panel must never cover the whole screen: the scrim beside it is the
    /// main way out of the drawer.
    func testPanelLeavesScrimVisibleOnANarrowScreen() {
        let narrow = PagesTreeLayout.width(availableWidth: 320)
        XCTAssertLessThan(narrow, 320)
        XCTAssertEqual(narrow, 320 * PagesTreeLayout.maxWidthFraction, accuracy: 0.001)
    }

    func testPanelUsesTheHandoffWidthWhenThereIsRoom() {
        XCTAssertEqual(PagesTreeLayout.width(availableWidth: 800), PagesTreeLayout.panelWidth)
    }
}
