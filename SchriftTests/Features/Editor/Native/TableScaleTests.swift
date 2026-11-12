import UIKit
import XCTest

@testable import Schrift

/// PR11c: very large tables. The grid realises only the cells on screen.
@MainActor
final class TableScaleTests: NativeEditingTestCase {
    /// A document of one BlockNote-shaped table, `rows` × `columns`, each
    /// cell one paragraph "r<row>c<column>", between two paragraphs.
    nonisolated static func tableState(rows: Int, columns: Int) throws -> Data {
        let doc = YDoc(clientID: 1, gc: true)
        defer { doc.destroy() }
        let root = doc.get(BlockNoteYjs.fragmentField)
        try doc.transact { tx in
            let group = YType(typeRef: .xmlElement(nodeName: "blockGroup"))
            try YWrite.insertAfter(tx, into: root, after: nil, [.type(group)])
            let container = YType(typeRef: .xmlElement(nodeName: "blockContainer"))
            try YWrite.insertAfter(tx, into: group, after: nil, [.type(container)])
            try YWrite.mapSet(tx, on: container, key: "id", .any([.string("tbl")]))
            let table = YType(typeRef: .xmlElement(nodeName: "table"))
            try YWrite.insertAfter(tx, into: container, after: nil, [.type(table)])
            var lastRow: YItem?
            for row in 0..<rows {
                let rowType = YType(typeRef: .xmlElement(nodeName: "tableRow"))
                lastRow = try YWrite.insertAfter(tx, into: table, after: lastRow, [.type(rowType)])
                var lastCell: YItem?
                for column in 0..<columns {
                    let cell = YType(typeRef: .xmlElement(nodeName: row == 0 ? "tableHeader" : "tableCell"))
                    lastCell = try YWrite.insertAfter(tx, into: rowType, after: lastCell, [.type(cell)])
                    for (key, value) in [
                        ("colspan", YAnyValue.int(1)), ("rowspan", .int(1)), ("backgroundColor", .string("default")),
                        ("textColor", .string("default")), ("textAlignment", .string("left")),
                    ] {
                        try YWrite.mapSet(tx, on: cell, key: key, .any([value]))
                    }
                    let paragraph = YType(typeRef: .xmlElement(nodeName: "tableParagraph"))
                    try YWrite.insertAfter(tx, into: cell, after: nil, [.type(paragraph)])
                    let text = YType(typeRef: .xmlText)
                    try YWrite.insertAfter(tx, into: paragraph, after: nil, [.type(text)])
                    try text.insert(0, "r\(row)c\(column)", YTextAttributes())
                }
            }
        }
        return try YStateEncoder.encodeStateAsUpdate(doc)
    }

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        try await super.tearDown()
    }

    private func editor(_ harness: Harness) async throws -> TableEditorViewController {
        let editor = TableEditorViewController(document: harness.session, tableID: "tbl")
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window =
            scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
        }
        windows.append(window)
        editor.loadViewIfNeeded()
        await editor.load()
        for _ in 0..<1_000 where !editor.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.isLoaded)
        if let session = editor.cellSession { addTeardownBlock { await session.close().value } }
        window.layoutIfNeeded()
        return editor
    }

    private static func percentile(_ times: [Duration], _ fraction: Double) -> Duration {
        let sorted = times.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    /// The fixture gate: a 10,000-row table (30,000 cells, past the editing
    /// bound) opens as a read-only viewer that realises only the cells on
    /// screen, scrolls by realising the next ones, and VoiceOver reaches every
    /// cell through the data table without a view for it.
    func testA10000RowTableOpensVirtualisedAndScrolls() async throws {
        let clock = ContinuousClock()
        let harness = try await makeHarness(state: try Self.tableState(rows: 10_000, columns: 3))
        addTeardownBlock { await harness.close() }
        var start = clock.now
        let editor = try await editor(harness)
        let open = clock.now - start
        XCTAssertNil(editor.cellSession, "past the editing bound: the viewer")
        XCTAssertEqual(editor.grid?.rows.count, 10_000)
        XCTAssertEqual(editor.grid?.familiarity, .unfamiliar("large table"))
        XCTAssertLessThan(editor.cellViews.count, 150, "only the screen's cells are realised")
        XCTAssertNotNil(editor.cellViews[TableGrid.CellRef(row: 0, index: 0)])
        var steps: [Duration] = []
        for step in 1...200 {
            start = clock.now
            editor.scrollView.contentOffset.y = CGFloat(step) * 40
            steps.append(clock.now - start)
        }
        // A jump to the middle realises the middle and recycles the top.
        start = clock.now
        editor.scrollView.contentOffset.y = editor.scrollView.contentSize.height / 2
        let jump = clock.now - start
        let rows = editor.cellViews.keys.map(\.row)
        XCTAssertLessThan(editor.cellViews.count, 150)
        XCTAssertNil(editor.cellViews[TableGrid.CellRef(row: 0, index: 0)], "recycled")
        XCTAssertTrue(rows.allSatisfy { (4_000..<6_000).contains($0) }, "the middle rows: \(rows.min() ?? -1)")
        let realised = try XCTUnwrap(editor.cellViews.values.first { $0.ref?.index == 1 })
        let ref = try XCTUnwrap(realised.ref)
        XCTAssertEqual(realised.label.attributedText?.string, "r\(ref.row)c1")
        XCTAssertEqual(editor.gridView.accessibilityElementCount(), 30_000)
        let element = try XCTUnwrap(editor.gridView.accessibilityDataTableCellElement(forRow: 9_999, column: 2))
        XCTAssertEqual((element as? NSObject)?.accessibilityValue, "r9999c2")
        print("SCALE viewer open \(open), scroll p50 \(Self.percentile(steps, 0.5)) p99 \(Self.percentile(steps, 0.99)), jump \(jump)")
        // Generous for a debug build on the simulator; the provisional device
        // budget (scroll step p99 < 8.3 ms) is checked on TestFlight.
        XCTAssertLessThan(Self.percentile(steps, 0.99), .milliseconds(100))
    }

    /// An editable table at the bound realises only what is on screen too,
    /// and a cell far down still takes typing.
    func testAnEditableTableAtTheBoundRealisesOnlyTheScreen() async throws {
        let harness = try await makeHarness(state: try Self.tableState(rows: 333, columns: 3))
        addTeardownBlock { await harness.close() }
        let editor = try await editor(harness)
        let table = try XCTUnwrap(editor.cellSession, "999 cells edit")
        XCTAssertLessThan(editor.cellViews.count, 150)
        let far = TableGrid.CellRef(row: 300, index: 1)
        XCTAssertTrue(editor.activate(far))
        XCTAssertNotNil(editor.cellViews[far], "the active cell is realised where it scrolled to")
        XCTAssertLessThan(editor.cellViews.count, 150)
        let clock = ContinuousClock()
        var keys: [Duration] = []
        for _ in 0..<10 {
            let start = clock.now
            table.textView.insertText("x")
            editor.view.layoutIfNeeded()
            keys.append(clock.now - start)
        }
        await harness.settle()
        let text = await harness.engine { $0.tableGrid("tbl")?.rows[300][1].runs.map(\.text).joined() }
        XCTAssertEqual(text, "xxxxxxxxxx")
        print("SCALE editable 999 cells key p50 \(Self.percentile(keys, 0.5))")
    }
}
