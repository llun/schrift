import Foundation
import XCTest

@testable import Schrift

/// PR14 Step 2: `DocumentReplicaSession` scoped source adapters (`openSource`
/// via `attach(surfaceID:source:)`, surface isolation, predicted rebase and
/// invalidation, peer delete/replace delivery, close refresh, and resync).
@MainActor
final class ReplicaSessionSourceTests: NativeEditingTestCase {
    private final class DeliveryCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ReplicaDelivery] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<ReplicaDelivery>) {
            task = Task {
                for await delivery in stream {
                    lock.withLock {
                        items.append(delivery)
                    }
                }
            }
        }

        var deliveries: [ReplicaDelivery] {
            lock.withLock { items }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private func seedState(_ blocks: [BlockNoteBlock], clientID: UInt32 = 1) -> Data {
        BlockNoteYjs.encode(blocks, clientID: clientID)
    }

    func testOpenSourceIsolatesDeltasHidesSyntheticIDsAndRefreshesOwnerOnClose() async throws {
        let state = seedState([
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Lead")], id: "p"),
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("x^2")], id: "mx"),
        ])
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let replica = try XCTUnwrap(harness.session.replica)

        let sourceSurfaceID = UUID()
        let attachment = try unwrapped(await replica.attach(surfaceID: sourceSurfaceID, source: .block(id: "mx")))
        XCTAssertEqual(attachment.blocks.count, 1)
        let syntheticID = try XCTUnwrap(attachment.blocks.first?.id)
        XCTAssertTrue(SourceTarget.isSourceID(syntheticID))
        XCTAssertEqual(attachment.blocks.first?.runs, [InlineRun("x^2")])

        let collector = DeliveryCollector(attachment.deliveries)
        defer { collector.cancel() }

        // Type via the source surface: source receives `.text`, main document
        // sees updated `.source` preview for "mx" and never sees the synthetic id.
        let editID = UUID()
        replica.mailbox.post(
            .command(
                ReplicaCommand(
                    surfaceID: sourceSurfaceID, epoch: 0, predicted: false,
                    command: NativeEditCommand(
                        id: editID, baseRevision: attachment.revision, blockID: syntheticID,
                        range: 3..<3, replacement: "+y^2"),
                    undoBefore: true, undoAfter: true)))
        let drainToken = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: drainToken))

        await waitUntil { collector.deliveries.contains(where: { $0.drained == drainToken }) }
        await harness.settle()

        // Main document never sees syntheticID and shows updated preview card for "mx".
        XCTAssertFalse(harness.session.surface.blocks.contains { SourceTarget.isSourceID($0.id) })
        guard case .source(_, let lines, _)? = harness.session.surface.blocks.first(where: { $0.id == "mx" })?.preview
        else { return XCTFail("missing source preview on main surface") }
        XCTAssertEqual(lines, ["x^2+y^2"])

        // Source surface never received "p" or "mx" patches — only `syntheticID` text delta.
        let patches = collector.deliveries.flatMap(\.events).compactMap { event -> BlockPatch? in
            if case .patch(let patch, _) = event { return patch }
            return nil
        }
        XCTAssertFalse(patches.isEmpty)
        for patch in patches {
            for change in patch.changes {
                switch change {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _):
                    XCTAssertEqual(id, syntheticID)
                case .remove(let ids):
                    XCTAssertEqual(ids, [syntheticID])
                case .insert(_, let blocks):
                    XCTAssertEqual(blocks.map(\.id), [syntheticID])
                case .reset(let blocks):
                    XCTAssertEqual(blocks.map(\.id), [syntheticID])
                }
            }
        }

        // Detach closes the scoped source cleanly.
        replica.mailbox.post(.detach(surfaceID: sourceSurfaceID))
        await harness.settle()
        let stillOpen = await harness.session.engine { $0.sourceSnapshot(syntheticID) != nil }
        XCTAssertEqual(stillOpen, false)
    }

    func testPredictedTypingRebasesAgainstPeerEditAndInvalidatesThenRemovesOnPeerDelete() async throws {
        let initial = [
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("Lead")], id: "p"),
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("abc")], id: "mx"),
        ]
        let state = seedState(initial, clientID: 1)
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let replica = try XCTUnwrap(harness.session.replica)

        let sourceSurfaceID = UUID()
        let attachment = try unwrapped(await replica.attach(surfaceID: sourceSurfaceID, source: .block(id: "mx")))
        let syntheticID = try XCTUnwrap(attachment.blocks.first?.id)
        let collector = DeliveryCollector(attachment.deliveries)
        defer { collector.cancel() }

        // Peer (client 2) inserts "0" at start of mathBlock before source surface sends predicted key at offset 3.
        let peerDoc = try makeDoc(initial, clientID: 2)
        defer { peerDoc.destroy() }
        let peerWriter = BlockNoteWriter(doc: peerDoc)
        let peerEl = try peerWriter.findSource("mx").element
        let peerInsert = try peerWriter.replaceSourceText(in: peerEl, range: 0..<0, with: "0", block: "mx")

        replica.mailbox.post(.integrate(peerInsert, reply: nil))
        let predictedID = UUID()
        replica.mailbox.post(
            .command(
                ReplicaCommand(
                    surfaceID: sourceSurfaceID, epoch: 0, predicted: true,
                    command: NativeEditCommand(
                        id: predictedID, baseRevision: attachment.revision, blockID: syntheticID,
                        range: 3..<3, replacement: "X"),
                    undoBefore: true, undoAfter: true)))
        let afterRebaseToken = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: afterRebaseToken))
        await waitUntil { collector.deliveries.contains(where: { $0.drained == afterRebaseToken }) }

        let currentText = await harness.session.engine { $0.sourceSnapshot(syntheticID)?.first?.runs.first?.text }
        XCTAssertEqual(currentText, "0abcX", "predicted edit rebased past peer prefix")

        // Next: peer deletes the mathBlock while source surface predicts with a stale baseRevision.
        let staleRevision = attachment.revision
        let deleteUpdate = try peerWriter.deleteBlock(try peerWriter.findSource("mx").item, id: "mx")
        replica.mailbox.post(.integrate(deleteUpdate, reply: nil))
        let staleCmdID = UUID()
        replica.mailbox.post(
            .command(
                ReplicaCommand(
                    surfaceID: sourceSurfaceID, epoch: 0, predicted: true,
                    command: NativeEditCommand(
                        id: staleCmdID, baseRevision: staleRevision, blockID: syntheticID,
                        range: 0..<0, replacement: "Y"),
                    undoBefore: false, undoAfter: false)))
        let afterDeleteToken = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: afterDeleteToken))
        await waitUntil { collector.deliveries.contains(where: { $0.drained == afterDeleteToken }) }

        let changes = collector.deliveries.flatMap(\.events).compactMap { event -> [BlockChange]? in
            if case .patch(let patch, _) = event { return patch.changes }
            return nil
        }.flatMap { $0 }
        XCTAssertTrue(
            changes.contains {
                if case .remove(let ids) = $0 { return ids.contains(syntheticID) }
                return false
            }, "source surface receives .remove on peer delete")
        XCTAssertTrue(
            collector.deliveries.contains {
                if case .invalidated(_, let id)? = $0.result { return id == staleCmdID }
                return false
            })

        // Resync on a deleted source resets to empty blocks under bumped epoch.
        replica.mailbox.post(.resync(surfaceID: sourceSurfaceID))
        let resyncToken = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: resyncToken))
        await waitUntil { collector.deliveries.contains(where: { $0.drained == resyncToken }) }

        let resetBlocks = collector.deliveries.compactMap { delivery -> [BlockSnapshot]? in
            guard delivery.resync != nil else { return nil }
            for event in delivery.events {
                if case .patch(let patch, _) = event, case .reset(let blocks)? = patch.changes.first {
                    return blocks
                }
            }
            return nil
        }.last
        XCTAssertEqual(resetBlocks, [])
        replica.mailbox.post(.detach(surfaceID: sourceSurfaceID))
        await harness.settle()
    }

    func testOpenSourceInlineMathInTableCellIsolatesTableSourceAndDocumentSurfaces() async throws {
        let capture = try XCTUnwrap(BlockNoteSourceCaptures.fixtures.first { $0.name == "sourceAroundTable" })
        let state = try XCTUnwrap(Data(base64Encoded: capture.update))
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let replica = try XCTUnwrap(harness.session.replica)

        // Open table surface AND inline math source inside cell 0's tableParagraph concurrently.
        let tableSurfaceID = UUID()
        let tableAttachment = try unwrapped(await replica.attach(surfaceID: tableSurfaceID, table: "tbl"))
        let firstCellID = try XCTUnwrap(tableAttachment.blocks.first?.id)
        let tableCollector = DeliveryCollector(tableAttachment.deliveries)
        defer { tableCollector.cancel() }

        let mathItemID = try unwrapped(
            await harness.session.replicaDoc { doc -> YID? in
                let writer = BlockNoteWriter(doc: doc)
                guard let root = doc.share[BlockNoteYjs.fragmentField] else { return nil }
                for item in writer.children(root) {
                    guard case .type(let group) = item.content else { continue }
                    for blockItem in writer.children(group) {
                        guard case .type(let container) = blockItem.content,
                            container.typeRef == .xmlElement(nodeName: "blockContainer"),
                            BlockIndex.blockID(of: container) == "tbl",
                            let first = writer.children(container).first,
                            case .type(let tblElement) = first.content,
                            tblElement.typeRef == .xmlElement(nodeName: "table")
                        else { continue }
                        for row in writer.children(tblElement) {
                            guard case .type(let rowType) = row.content else { continue }
                            for cell in writer.children(rowType) {
                                guard case .type(let cellType) = cell.content,
                                    let paraItem = writer.children(cellType).first,
                                    case .type(let paraType) = paraItem.content
                                else { continue }
                                for child in writer.children(paraType) {
                                    if case .type(let type) = child.content,
                                        type.typeRef == .xmlElement(nodeName: NativeInlineObject.mathNodeName)
                                    {
                                        return child.id
                                    }
                                }
                            }
                        }
                    }
                }
                return nil
            } ?? nil)

        let sourceSurfaceID = UUID()
        let sourceAttachment = try unwrapped(
            await replica.attach(
                surfaceID: sourceSurfaceID, source: .inlineMath(blockID: firstCellID, itemID: mathItemID)))
        let syntheticID = try XCTUnwrap(sourceAttachment.blocks.first?.id)
        XCTAssertEqual(sourceAttachment.blocks.first?.runs, [InlineRun("a+b")])
        let sourceCollector = DeliveryCollector(sourceAttachment.deliveries)
        defer { sourceCollector.cancel() }

        // Edit inline math via source surface: table surface gets `.replaceBlock(firstCellID)` (never syntheticID),
        // source surface gets `.text(syntheticID)`, document surface never sees either synthetic id!
        replica.mailbox.post(
            .command(
                ReplicaCommand(
                    surfaceID: sourceSurfaceID, epoch: 0, predicted: false,
                    command: NativeEditCommand(
                        id: UUID(), baseRevision: sourceAttachment.revision, blockID: syntheticID,
                        range: 3..<3, replacement: "+c"),
                    undoBefore: true, undoAfter: true)))
        let doneToken = UUID()
        replica.mailbox.post(.drain(surfaceID: tableSurfaceID, token: doneToken))
        await waitUntil { tableCollector.deliveries.contains(where: { $0.drained == doneToken }) }
        await harness.settle()

        // Document surface hides both `\u{1}` tableParagraphs and `\u{2}` source ids.
        XCTAssertFalse(
            harness.session.surface.blocks.contains { TableGrid.isParagraphID($0.id) || SourceTarget.isSourceID($0.id) }
        )

        // Table surface received updated cell paragraph without any source synthetic id leaking in.
        let tableChanges = tableCollector.deliveries.flatMap(\.events).compactMap { event -> [BlockChange]? in
            if case .patch(let patch, _) = event { return patch.changes }
            return nil
        }.flatMap { $0 }
        XCTAssertFalse(
            tableChanges.contains {
                switch $0 {
                case .text(let id, _), .props(let id, _), .replaceBlock(let id, _): return SourceTarget.isSourceID(id)
                case .remove(let ids): return ids.contains(where: SourceTarget.isSourceID)
                case .insert(_, let blocks): return blocks.contains { SourceTarget.isSourceID($0.id) }
                case .reset: return false
                }
            })
        XCTAssertTrue(
            tableChanges.contains {
                if case .replaceBlock(let id, let snapshot) = $0, id == firstCellID {
                    return snapshot.runs.contains { $0.inlineObject == .math(source: "a+b+c") }
                }
                return false
            })

        // Detaching source refreshes cell paragraph and detaching table refreshes table card on main surface.
        replica.mailbox.post(.detach(surfaceID: sourceSurfaceID))
        replica.mailbox.post(.detach(surfaceID: tableSurfaceID))
        await harness.settle()
    }

    func testS2InvalidSourceCompositionCommitInvalidatesWithoutFailingSession() async throws {
        let state = seedState([
            BlockNoteBlock(node: "paragraph", props: Self.paragraphProps, runs: [InlineRun("x")], id: "p"),
            BlockNoteBlock(node: SourceBlock.mathBlock, props: [], runs: [InlineRun("a")], id: "mx"),
        ])
        let harness = try await makeHarness(state: state)
        addTeardownBlock { await harness.close() }
        let replica = try XCTUnwrap(harness.session.replica)

        let sourceSurfaceID = UUID()
        let attachment = try unwrapped(await replica.attach(surfaceID: sourceSurfaceID, source: .block(id: "mx")))
        let syntheticID = try XCTUnwrap(attachment.blocks.first?.id)
        let collector = DeliveryCollector(attachment.deliveries)
        defer { collector.cancel() }

        replica.mailbox.post(
            .compositionBegin(
                surfaceID: sourceSurfaceID, epoch: 0, baseRevision: attachment.revision, blockID: syntheticID,
                range: 1..<1))
        let commitID = UUID()
        replica.mailbox.post(
            .compositionCommit(
                surfaceID: sourceSurfaceID, epoch: 0, commandID: commitID, text: "bad\u{000C}char"))
        let token = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: token))
        await waitUntil { collector.deliveries.contains(where: { $0.drained == token }) }

        XCTAssertTrue(
            collector.deliveries.contains {
                if case .invalidated(_, let id)? = $0.result { return id == commitID }
                return false
            })
        XCTAssertFalse(
            collector.deliveries.contains {
                if case .composition(_, .failed)? = $0.result { return true }
                return false
            })
        let failed = await harness.session.engine { $0.nativeWriteFailed }
        XCTAssertEqual(failed, false)

        // Epoch bumped by invalidation (epoch 1); a subsequent valid edit applies cleanly.
        let validID = UUID()
        replica.mailbox.post(
            .command(
                ReplicaCommand(
                    surfaceID: sourceSurfaceID, epoch: 1, predicted: false,
                    command: NativeEditCommand(
                        id: validID, baseRevision: attachment.revision, blockID: syntheticID,
                        range: 1..<1, replacement: "+b"),
                    undoBefore: true, undoAfter: true)))
        let token2 = UUID()
        replica.mailbox.post(.drain(surfaceID: sourceSurfaceID, token: token2))
        await waitUntil { collector.deliveries.contains(where: { $0.drained == token2 }) }
        XCTAssertTrue(
            collector.deliveries.contains {
                if case .applied(let id, _, _)? = $0.result { return id == validID }
                return false
            })
        replica.mailbox.post(.detach(surfaceID: sourceSurfaceID))
        await harness.settle()
    }
}
