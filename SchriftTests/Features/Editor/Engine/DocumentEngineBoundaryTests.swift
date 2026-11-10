import XCTest

@testable import Schrift

/// The engine speaks `Range<Int>` and replica types only (AGENTS.md, document
/// engine layers): no UIKit or TextKit vocabulary in `Features/Editor/Engine`.
/// Reads the sources beside this file's checkout, which the simulator shares.
final class DocumentEngineBoundaryTests: XCTestCase {
    private func engineSources() throws -> [(name: String, source: String)] {
        let tests = URL(fileURLWithPath: #filePath)
        let root = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("Schrift/Features/Editor/Engine")
        let files = try FileManager.default.contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, engine.path)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testEngineSourcesUseNoUIKitOrTextKitTypes() throws {
        for (name, source) in try engineSources() {
            for token in ["NSRange", "NSText", "UIView", "UITextView", "UndoManager", "import UIKit"] {
                XCTAssertFalse(source.contains(token), "\(name) mentions \(token)")
            }
        }
    }

    /// PR08a: the engine is confined to the domain that creates it, so nothing
    /// in `Features/Editor/Engine` names the main actor.
    func testEngineSourcesNameNoMainActor() throws {
        for (name, source) in try engineSources() {
            XCTAssertFalse(source.contains("@MainActor"), "\(name) is main-actor isolated")
        }
    }

    /// Builds a replica and an engine inside an actor, types, and returns the
    /// patches across the actor boundary: they are `Sendable`, and the engine
    /// runs off the main actor.
    private actor EngineHost {
        func type(_ text: String, into blockID: String, state: Data) throws -> [BlockPatch] {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let doc = YDoc(clientID: 9, gc: true)
            defer { doc.destroy() }
            try doc.applyUpdate(YUpdateDecoder.decode(state))
            let surface = HeadlessSurface()
            let engine = DocumentEngine(doc: doc, surface: surface)
            try engine.replaceText(block: blockID, range: 0..<0, with: text)
            return surface.appliedPatches
        }
    }

    @MainActor
    func testEngineRunsInsideAnActor() async throws {
        let state = BlockNoteYjs.encode(DocumentEngineTestCase.seedBlocks(), clientID: 1)
        let id = DocumentEngineTestCase.firstID
        let patches = try await EngineHost().type("Hi ", into: id, state: state)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.origin, .localUser)
        guard case .text(let blockID, let deltas)? = patches.first?.changes.first else {
            return XCTFail("not a text patch: \(patches)")
        }
        XCTAssertEqual(blockID, id)
        XCTAssertEqual(deltas.map(\.range), [0..<0])
        XCTAssertEqual(deltas.map(\.replacement), ["Hi "])
    }
}
