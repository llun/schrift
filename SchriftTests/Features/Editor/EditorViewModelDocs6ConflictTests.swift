import XCTest

@testable import Schrift

/// A stateful Docs 6 server: yhub holds a real replica (GET serves it, PATCH integrates the
/// update), `formatted-content` exports it, and the legacy content route is gone.
private final class FakeDocs6Server: @unchecked Sendable {
    let lock = NSLock()
    let doc: YDoc
    var updatedAt = "2026-01-15T10:30:00Z"
    var title = "Doc"
    var trail: [String] = []
    let origin = "https://docs.example.org"

    init(markdown: String) throws {
        doc = YDoc(clientID: 1, gc: true)
        let update = BlockNoteYjs.encode(MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin), clientID: 1)
        try doc.applyUpdate(try YUpdateDecoder.decode(update))
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// A peer (the web) saving: make the server read like `markdown`.
    func peerWrites(_ markdown: String, at stamp: String) throws {
        try locked {
            let state = try YStateEncoder.encodeStateAsUpdate(doc)
            if let update = try BlockNoteIncrementalSave.update(
                serverState: state,
                newBlocks: MarkdownYjs.blockNoteBlocks(from: markdown, serverOrigin: origin),
                baseBlocks: MarkdownYjs.blockNoteBlocks(from: exportLocked(), serverOrigin: origin),
                serverOrigin: origin)
            {
                try doc.applyUpdate(try YUpdateDecoder.decode(update))
            }
            updatedAt = stamp
        }
    }

    var export: String { locked { exportLocked() } }

    /// The top-level block ids, in order.
    var topLevelIDs: [String] {
        locked { YBlockProjection.project(doc).blocks.map(\.id) }
    }

    /// A minimal markdown export: paragraphs and (nested) bullets.
    private func exportLocked() -> String {
        var out: [String] = []
        func text(_ type: YType) -> String {
            var s = ""
            var item = type.start
            while let i = item {
                if !i.deleted, case .string(let units) = i.content { s += String(decoding: units, as: UTF16.self) }
                item = i.right
            }
            return s
        }
        func walk(_ group: YType, depth: Int) {
            var item = group.start
            while let i = item {
                defer { item = i.right }
                guard !i.deleted, case .type(let container) = i.content else { continue }
                var sub = container.start
                while let s = sub {
                    defer { sub = s.right }
                    guard !s.deleted, case .type(let el) = s.content, case .xmlElement(let name)? = el.typeRef else {
                        continue
                    }
                    if name == "blockGroup" {
                        walk(el, depth: depth + 1)
                        continue
                    }
                    var body = ""
                    var t = el.start
                    while let tt = t {
                        if !tt.deleted, case .type(let x) = tt.content, x.typeRef == .xmlText { body += text(x) }
                        t = tt.right
                    }
                    let indent = String(repeating: "  ", count: depth)
                    out.append(name == "bulletListItem" ? "\(indent)- \(body)" : body)
                }
            }
        }
        if let root = doc.share[BlockNoteYjs.fragmentField], let first = root.start,
            case .type(let group) = first.content
        {
            walk(group, depth: 0)
        }
        // Blank line between top-level blocks, none inside a list.
        var result = ""
        for (index, line) in out.enumerated() {
            if index > 0 { result += (line.hasPrefix(" ") ? "\n" : "\n\n") }
            result += line
        }
        return result
    }

    func handle(_ request: URLRequest) -> MockURLProtocol.Stub {
        locked {
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true)?.path } ?? ""
            let method = request.httpMethod ?? ""
            trail.append("\(method) \(path)")
            func json(_ object: Any, status: Int = 200) -> MockURLProtocol.Stub {
                .init(
                    statusCode: status, headers: ["Content-Type": "application/json"],
                    body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), error: nil)
            }
            if method == "GET", path.hasSuffix("/config/") { return json(["RELEASE_VERSION": "6.0.4"]) }
            if method == "GET", path.contains("formatted-content") {
                return json([
                    "id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": title, "content": exportLocked(),
                    "created_at": "2026-01-15T10:30:00Z", "updated_at": updatedAt,
                ])
            }
            if path.contains("/collaboration/ydoc/") {
                if method == "GET" {
                    let state = (try? YStateEncoder.encodeStateAsUpdate(doc)) ?? Data()
                    return json(["doc": state.base64EncodedString()])
                }
                if method == "PATCH" {
                    guard let body = bodyData(from: request),
                        let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                        let update = object["update"].flatMap({ Data(base64Encoded: $0) })
                    else { return json(["error": "bad"], status: 400) }
                    do { try doc.applyUpdate(try YUpdateDecoder.decode(update)) } catch {
                        return json(["error": "\(error)"], status: 400)
                    }
                    return json(["success": true])
                }
            }
            if method == "PATCH", path.hasSuffix("/content/") {
                return .init(
                    statusCode: 404, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8), error: nil)
            }
            if method == "PATCH" { return json(["id": "x"]) }  // title
            return json([], status: 200)  // children etc.
        }
    }
}

/// TestFlight 0.103.0: a rich document on a Docs 6 server, edited in the app while a co-author
/// edits it on the web. The app's side of the flow — the conflict, "Keep the server version",
/// the next save — end to end over a stateful server.
@MainActor
final class EditorViewModelDocs6ConflictTests: EditorViewModelTestCase {
    private let base = "Intro\n\n- Bullet\n  - Another bullet poin\n\nEnd"

    /// A dirty classic session cannot rebase: its save would overwrite whatever the
    /// co-author wrote since the baseline, so the revalidation asks instead.
    func testACoAuthorsEditDuringADirtySessionRaisesAConflict() async throws {
        let server = try FakeDocs6Server(markdown: base)
        MockURLProtocol.stubHandler = { server.handle($0) }
        let (viewModel, _, _, _) = makeEnvironment()
        await viewModel.load()

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "TEST Can I see how this get sync")
        try server.peerWrites("Intro\n\n- Bullet\n  - Another bullet point\n\nEnd", at: "2026-01-15T10:31:00Z")
        await viewModel.refresh()

        XCTAssertNotNil(viewModel.syncConflict)
        XCTAssertFalse(server.trail.contains { $0.hasPrefix("PATCH /collaboration/") }, "nothing was written")
    }

    /// "Keep the server version", then edit again: the save lands, and the untouched nested
    /// item keeps its container, so the co-author's text is neither duplicated nor reverted.
    func testKeepingTheServerVersionThenEditingSavesCleanly() async throws {
        let server = try FakeDocs6Server(markdown: base)
        MockURLProtocol.stubHandler = { server.handle($0) }
        let (viewModel, coordinator, draftStore, _) = makeEnvironment()
        await viewModel.load()
        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "Mine")
        try server.peerWrites("Intro\n\n- Bullet\n  - Another bullet point\n\nEnd", at: "2026-01-15T10:31:00Z")
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.syncConflict)

        await viewModel.resolveConflictKeepingServer()
        XCTAssertNil(viewModel.syncConflict)
        XCTAssertNil(draftStore.draft(for: documentID))
        XCTAssertEqual(coordinator.state(for: documentID), .idle)
        XCTAssertEqual(viewModel.blocks.map(\.text), ["Intro", "Bullet", "Another bullet point", "End"])
        let bulletID = server.topLevelIDs[1]

        viewModel.startEditing()
        viewModel.updateText(blockID: viewModel.blocks[0].id, text: "TEST Can I see how this get sync")
        viewModel.flushPendingChanges()
        await waitUntil {
            if case .saving = coordinator.state(for: self.documentID) { return false } else { return true }
        }

        XCTAssertTrue(isSaved(coordinator.state(for: documentID)), "\(coordinator.state(for: documentID))")
        XCTAssertEqual(server.export, "TEST Can I see how this get sync\n\n- Bullet\n  - Another bullet point\n\nEnd")
        XCTAssertEqual(server.topLevelIDs[1], bulletID, "the untouched list item was not rebuilt")
    }

    private func isSaved(_ state: DocumentSaveCoordinator.DocSaveState) -> Bool {
        if case .saved = state { return true }
        return false
    }
}
