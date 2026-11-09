import XCTest

@testable import Schrift

/// Shared fixtures for the headless engine tests: a seeded replica, the
/// surface/projection assertions, and the one two-replica harness the
/// concurrent-editor cases use.
@MainActor
class DocumentEngineTestCase: XCTestCase {
    static let paragraphProps: [(key: String, value: YAnyValue)] = [
        ("backgroundColor", .string("default")), ("textColor", .string("default")),
        ("textAlignment", .string("left")),
    ]

    static let firstID = "b0000000-0000-4000-8000-000000000001"
    static let secondID = "b0000000-0000-4000-8000-000000000002"
    static let thirdID = "b0000000-0000-4000-8000-000000000003"

    /// Three paragraphs, the second carrying a bold run — the C2 seed shape.
    static func seedBlocks() -> [BlockNoteBlock] {
        [
            BlockNoteBlock(
                node: "paragraph", props: paragraphProps, runs: [InlineRun("First paragraph.")], id: firstID),
            BlockNoteBlock(
                node: "paragraph", props: paragraphProps,
                runs: [
                    InlineRun("Second paragraph has "),
                    InlineRun("bold words", marks: [("bold", "{}")]),
                    InlineRun(" inside it."),
                ], id: secondID),
            BlockNoteBlock(
                node: "paragraph", props: paragraphProps, runs: [InlineRun("Third paragraph.")], id: thirdID),
        ]
    }

    /// One seed, one client id: every replica in a test must start from the
    /// *same* bytes, or the two sides are different documents.
    static let seedClientID: UInt32 = 1

    func makeDoc(_ blocks: [BlockNoteBlock] = seedBlocks(), clientID: UInt32) throws -> YDoc {
        let doc = YDoc(clientID: UInt(clientID), gc: true)
        try doc.applyUpdate(YUpdateDecoder.decode(BlockNoteYjs.encode(blocks, clientID: Self.seedClientID)))
        return doc
    }

    struct Pair {
        let a: YDoc
        let b: YDoc
        let surfaceA: HeadlessSurface
        let surfaceB: HeadlessSurface
        let engineA: DocumentEngine
        let engineB: DocumentEngine

        func destroy() {
            a.destroy()
            b.destroy()
        }
    }

    func makePair() throws -> Pair {
        let a = try makeDoc(clientID: 1)
        let b: YDoc
        do { b = try makeDoc(clientID: 2) } catch {
            a.destroy()
            throw error
        }
        let surfaceA = HeadlessSurface(blocks: projection(a))
        let surfaceB = HeadlessSurface(blocks: projection(b))
        return Pair(
            a: a, b: b, surfaceA: surfaceA, surfaceB: surfaceB,
            engineA: DocumentEngine(doc: a, surface: surfaceA),
            engineB: DocumentEngine(doc: b, surface: surfaceB))
    }

    /// The replica's projection in the surface's vocabulary.
    /// The engine's reading: every stored mark kept (`nativeMarks`).
    func projection(_ doc: YDoc) -> [BlockSnapshot] {
        YBlockProjection.project(doc, nativeMarks: true).blocks.map(BlockSnapshot.init)
    }

    /// The invariant every scenario asserts after every step.
    func assertSurfaceMatchesProjection(
        _ surface: HeadlessSurface, _ doc: YDoc, _ label: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(surface.blocks, projection(doc), label, file: file, line: line)
    }

    func text(of block: BlockSnapshot) -> String {
        block.runs.map(\.text).joined()
    }

    func block(_ surface: HeadlessSurface, _ id: String) -> BlockSnapshot? {
        surface.blocks.first { $0.id == id }
    }
}
