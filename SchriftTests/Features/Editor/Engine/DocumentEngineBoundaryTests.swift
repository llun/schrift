import XCTest

/// The engine speaks `Range<Int>` and replica types only (AGENTS.md, document
/// engine layers): no UIKit or TextKit vocabulary in `Features/Editor/Engine`.
/// Reads the sources beside this file's checkout, which the simulator shares.
final class DocumentEngineBoundaryTests: XCTestCase {
    func testEngineSourcesUseNoUIKitOrTextKitTypes() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let root = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("Schrift/Features/Editor/Engine")
        let files = try FileManager.default.contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, engine.path)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in ["NSRange", "NSText", "UIView", "UITextView", "UndoManager", "import UIKit"] {
                XCTAssertFalse(source.contains(token), "\(file.lastPathComponent) mentions \(token)")
            }
        }
    }
}
