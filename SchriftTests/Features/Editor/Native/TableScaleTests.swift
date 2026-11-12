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

    func testExploreTiming() async throws {
        for rows in [333] { try await explore(rows: rows) }
        // The document surface with as many paragraphs, nothing hidden.
        let blocks = (0..<1000).map {
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("p\($0)")], id: "p\($0)")
        }
        let harness = try await makeHarness(blocks)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(harness.view)
        harness.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.isHidden = false
        defer { window.isHidden = true }
        harness.view.selectedRange = NSRange(location: try location(harness.session, "p500", 2), length: 0)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            harness.view.insertText("x")
            harness.view.layoutIfNeeded()
            times.append(clock.now - start)
        }
        print("SCALE doc keys", times.sorted()[10], times.sorted()[18])
        await harness.close()
    }

    private func explore(rows: Int) async throws {
        print("SCALE ---- rows", rows)
        let clock = ContinuousClock()
        var start = clock.now
        let state = try Self.tableState(rows: rows, columns: 3)
        print("SCALE state", clock.now - start, state.count)
        start = clock.now
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        print("SCALE harness", clock.now - start)
        start = clock.now
        let grid = await harness.session.tableGrid("tbl")
        print("SCALE grid", clock.now - start, grid?.familiarity as Any)
        start = clock.now
        let table = await harness.session.openTable("tbl")
        print("SCALE openTable", clock.now - start, table?.surface.blocks.count as Any)
        guard let table else { return }
        addTeardownBlock { await table.close().value }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(table.textView)
        table.textView.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.isHidden = false
        defer { window.isHidden = true }
        start = clock.now
        let ids = table.surface.blocks.map(\.id)
        table.input?.showCell([ids[ids.count / 2]])
        table.textView.layoutIfNeeded()
        print("SCALE showCell", clock.now - start)
        var times: [Duration] = []
        for _ in 0..<20 {
            start = clock.now
            table.textView.insertText("x")
            let typed = clock.now - start
            table.textView.layoutIfNeeded()
            times.append(clock.now - start)
            print("SCALE key typed", typed)
        }
        print("SCALE keys", times.sorted()[10], times.sorted()[18])
        await harness.settle()
        await table.close().value
        await harness.close()
    }
}
