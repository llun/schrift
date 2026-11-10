import XCTest

@testable import Schrift

/// Differential test against yjs 13.6.33's `Y.UndoManager`: replays every
/// `YUndoManagerOracleCaptures` scenario on a client-1 `YDoc` with a
/// `YUndoManager` over its roots, and after each step asserts the stack depths,
/// undo/redo's result, and that `encodeStateAsUpdate` is **byte-identical** to
/// yjs's. The captures come from `.review/oracle/gen-undo.js` (kept out of git),
/// run with node against the phase 0 S3 harness's yjs; regenerate the captures
/// file with it rather than editing them by hand.
///
/// Op vocabulary (each top-level op is one transaction, in both replays): `ins`/
/// `tdel`/`fmt` are `YText.insert`/`delete`/`format`, `ldel` is a list delete,
/// `el` inserts an element subtree (element, then its attributes, then its
/// children), `pel` inserts one the way y-prosemirror's prelim types integrate
/// (children before attributes; BlockNote's Enter), `attr` is `setAttribute`,
/// `tx` groups ops; `remote` applies the peer's update with origin `.remote`;
/// `undo`, `redo`, `stop` and `clear` drive the manager.
final class YUndoManagerOracleTests: XCTestCase {

    func testReplaysYjsUndoManagerCaptures() throws {
        for json in YUndoManagerOracleCaptures.scenarios {
            let scenario = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let name = scenario["name"] as? String ?? "?"
            do {
                try Replay(scenario).run(name)
            } catch {
                XCTFail("\(name): threw \(error)")
            }
        }
    }

    private struct Replay {
        let scenario: [String: Any]
        let doc = YDoc(clientID: 1)
        var roots: [String: YType] = [:]

        init(_ scenario: [String: Any]) {
            self.scenario = scenario
            for (name, kind) in scenario["roots"] as! [String: String] {
                roots[name] = kind == "text" ? doc.getText(name) : doc.get(name)
            }
        }

        func run(_ name: String) throws {
            defer { doc.destroy() }
            for op in scenario["seed"] as! [[String: Any]] {
                try doc.transact { try apply($0, op) }
            }
            let um = YUndoManager(
                doc: doc, scope: Array(roots.values),
                captureTimeout: scenario["captureTimeout"] as! Double,
                ignoreRemoteMapChanges: scenario["ignoreRemoteMapChanges"] as! Bool)
            for (index, step) in (scenario["steps"] as! [[String: Any]]).enumerated() {
                let op = step["op"] as! [String: Any]
                let expected = step["exp"] as! [String: Any]
                var popped: Bool?
                switch op["t"] as! String {
                case "remote":
                    let update = try YUpdateDecoder.decode(Data(base64Encoded: op["u"] as! String)!)
                    try doc.applyUpdate(update, origin: .remote)
                case "undo": popped = try um.undo() != nil
                case "redo": popped = try um.redo() != nil
                case "stop": um.stopCapturing()
                case "clear": try um.clear()
                default: try doc.transact { try apply($0, op) }
                }
                let at = "\(name) step \(index) (\(op["t"]!))"
                XCTAssertEqual(um.undoStack.count, expected["undo"] as? Int, "\(at): undo stack")
                XCTAssertEqual(um.redoStack.count, expected["redo"] as? Int, "\(at): redo stack")
                XCTAssertEqual(popped, expected["ret"] as? Bool, "\(at): result")
                XCTAssertEqual(
                    try YStateEncoder.encodeStateAsUpdate(doc).base64EncodedString(), expected["state"] as? String,
                    "\(at): state differs from yjs (\(expected["view"]!))")
            }
            um.destroy()
        }

        private func apply(_ tx: YTransaction, _ op: [String: Any]) throws {
            let index = UInt(op["i"] as? Int ?? 0)
            let length = UInt(op["n"] as? Int ?? 0)
            switch op["t"] as! String {
            case "ins": try type(op).insert(index, op["s"] as! String, op["a"].map(attributes))
            case "tdel": try type(op).delete(index, length)
            case "fmt": try type(op).format(index, length, attributes(op["a"]!))
            case "ldel": try YWrite.delete(tx, from: type(op), at: index, length: length)
            case "el": try insert(tx, op["spec"] as! [String: Any], into: type(op), at: index, prelim: false)
            case "pel": try insert(tx, op["spec"] as! [String: Any], into: type(op), at: index, prelim: true)
            case "attr":
                try YWrite.mapSet(tx, on: type(op), key: op["k"] as! String, .any([.string(op["v"] as! String)]))
            case "tx": for inner in op["ops"] as! [[String: Any]] { try apply(tx, inner) }
            default: XCTFail("unknown op \(op)")
            }
        }

        /// `el` (`gen-undo.js` `insertSpec`): the element, its attributes, then its
        /// children. `pel` (`prelim`, y-prosemirror's prelim element as yjs integrates
        /// it): the element, its children, then its attributes, with text written
        /// through `applyDelta`'s explicit empty attributes.
        private func insert(
            _ tx: YTransaction, _ spec: [String: Any], into parent: YType, at index: UInt, prelim: Bool
        ) throws {
            if let text = spec["text"] as? String {
                let child = YType(typeRef: .xmlText)
                try YWrite.insert(tx, into: parent, at: index, [.type(child)])
                try child.insert(0, text, prelim ? YTextAttributes() : nil)
                return
            }
            let element = YType(typeRef: .xmlElement(nodeName: spec["name"] as! String))
            try YWrite.insert(tx, into: parent, at: index, [.type(element)])
            func setAttributes() throws {
                for case let pair as [String] in spec["attrs"] as? [Any] ?? [] {
                    try YWrite.mapSet(tx, on: element, key: pair[0], .any([.string(pair[1])]))
                }
            }
            if !prelim { try setAttributes() }
            for (i, child) in (spec["children"] as? [[String: Any]] ?? []).enumerated() {
                try insert(tx, child, into: element, at: UInt(i), prelim: prelim)
            }
            if prelim { try setAttributes() }
        }

        /// The type at `op["p"]`: a root name, then visible child indices.
        private func type(_ op: [String: Any]) throws -> YType {
            let path = op["p"] as! [Any]
            var type = roots[path[0] as! String]!
            for case let index as Int in path.dropFirst() {
                var seen = 0
                var item = type.start
                var found: YType?
                while let current = item, found == nil {
                    if !current.deleted, case .type(let child) = current.content {
                        if seen == index { found = child }
                        seen += 1
                    }
                    item = current.right
                }
                type = try XCTUnwrap(found, "no child \(index) in \(path)")
            }
            return type
        }

        /// `[[key, value]]` → raw-JSON attributes, in the captured key order.
        private func attributes(_ raw: Any) -> YTextAttributes {
            YTextAttributes(
                (raw as! [[Any]]).map { pair in
                    let json = try! JSONSerialization.data(
                        withJSONObject: pair[1], options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    return (pair[0] as! String, String(decoding: json, as: UTF8.self))
                })
        }
    }
}
