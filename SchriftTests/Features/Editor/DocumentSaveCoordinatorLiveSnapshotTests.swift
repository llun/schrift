import XCTest

@testable import Schrift

/// Captures the JSON of every `PATCH …/content/` body, so a live-snapshot test can prove
/// the base64 bytes and the `"websocket": true` flag actually went out. Lock-guarded
/// because stubs are delivered on URLSession's protocol thread.
private final class ContentPatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    func record(_ request: URLRequest) {
        guard request.httpMethod == "PATCH",
            request.url?.absoluteString.hasSuffix("/content/") == true,
            let data = bodyData(from: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lock.lock()
        defer { lock.unlock() }
        bodies.append(json)
    }

    var contentValues: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies.compactMap { $0["content"] as? String }
    }

    var websocketFlags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return bodies.map { $0["websocket"] as? Bool ?? false }
    }
}

@MainActor
final class DocumentSaveCoordinatorLiveSnapshotTests: DocumentSaveCoordinatorTestCase {
    // MARK: - Live-snapshot save (C2b)

    /// A queued live snapshot routes to `saveLiveSnapshot`: the content PATCH carries the
    /// exact snapshot bytes AND `"websocket": true`, then a title PATCH follows.
    func testEnqueueLiveSnapshotRoutesToSaveLiveSnapshot() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()
        let snapshot = Data([0xAA, 0xBB, 0xCC])

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: snapshot, projectedMarkdown: "# Body", title: "Doc")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.methods, ["PATCH", "PATCH"], "content then title")
        XCTAssertEqual(bodies.contentValues, [snapshot.base64EncodedString()], "the snapshot bytes are sent verbatim")
        XCTAssertEqual(bodies.websocketFlags, [true], "the content PATCH is tagged websocket:true")
    }

    /// A classic `enqueue` must NOT leak the live flag — its content PATCH carries no
    /// `"websocket"` key, and its bytes are the markdown-derived Yjs update, not the raw
    /// projected markdown.
    func testClassicEnqueueStillRoutesToSaveDocumentContentWithNoWebsocketFlag() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueue(documentID: documentID, title: "Doc", markdown: "# Content")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(bodies.websocketFlags, [false], "a classic save never carries the live-collab flag")
        // A real Yjs v1 update begins with the client-count varUint 0x01 — NOT the raw markdown.
        let sent = bodies.contentValues.first.flatMap { Data(base64Encoded: $0) }
        XCTAssertEqual(sent?.first, 0x01, "the classic path still sends MarkdownYjs.encode output")
    }

    /// Write-ahead: `enqueueLiveSnapshot` persists a draft carrying the **projected
    /// markdown** as its body and the supplied baseline, before the save completes — so the
    /// whole reconcile/replay machinery keys off the projected markdown, never the bytes.
    func testEnqueueLiveSnapshotWritesTheDraftWithProjectedMarkdownAndBaseline() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.3)  // hold the save open so we can read the draft
        let (coordinator, draftStore, _) = makeCoordinator()
        let baseline = DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 0), markdown: "# Base", title: "Doc")

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x09]), projectedMarkdown: "# Projected", title: "Doc",
            baseline: baseline)

        let draft = draftStore.draft(for: documentID)
        XCTAssertEqual(draft?.markdown, "# Projected", "the draft body is the projected markdown, not the bytes")
        XCTAssertEqual(draft?.title, "Doc")
        XCTAssertEqual(draft?.baseline, baseline, "the baseline is threaded through unchanged")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
    }

    /// On live-snapshot success, `lastConfirmedPushMarkdown` is stamped with the **projected
    /// markdown** — so a later classic reconcile recognises the server as holding our body
    /// (rule 1) and never raises a conflict against our own live write.
    func testLiveSnapshotSuccessStampsLastConfirmedPushWithProjectedMarkdown() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01, 0x02]), projectedMarkdown: "# Projected", title: "Doc")

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            coordinator.lastConfirmedPush(documentID: documentID), "# Projected",
            "the projected markdown is what the server is known to hold")
    }

    /// Enqueue-hold applies to the live path too: while a conflict is recorded, a queued live
    /// snapshot writes its draft but starts NO save (an autosave must never push over the
    /// conflicting server copy unasked), and the state degrades to `.pendingSync`.
    func testLiveSnapshotIsHeldWhileAConflictIsRecorded() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, draftStore, _) = makeCoordinator()
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 100))

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x07]), projectedMarkdown: "# Held", title: "Doc")

        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // a save is an unstructured Task
        XCTAssertEqual(coordinator.state(for: documentID), .pendingSync, "a held live save is not a saved save")
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Held", "the write-ahead draft still lands")
        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "# Held", "it sits in the hold")
    }

    /// Latest-wins coalescing applies to the live path: three snapshots queued behind an
    /// in-flight save collapse to the newest, which is the only one that reaches the wire.
    func testLiveSnapshotCoalescesToLatestWhileInFlight() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log, saveDelay: 0.2)
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01]), projectedMarkdown: "v1", title: "Doc")
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x02]), projectedMarkdown: "v2", title: "Doc")
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x03]), projectedMarkdown: "v3", title: "Doc")

        XCTAssertEqual(coordinator.pendingSave(documentID: documentID)?.markdown, "v3")

        await waitUntil(timeout: 5) { self.isSaved(coordinator.state(for: self.documentID)) }
        // Two saves total (the first, then the coalesced v3), each one content PATCH.
        XCTAssertEqual(savesInFlight(log), 2)
        XCTAssertEqual(coordinator.lastConfirmedPush(documentID: documentID), "v3")
    }

    // MARK: - Live-snapshot inherits the coordinator invariants (C2b Task 3)
    //
    // `saveLiveSnapshot` and `saveDocumentContent` share the identical half-land contract
    // (a THROW means the content PATCH never confirmed; a non-nil `DocsAPIError` RETURN means
    // it landed but the title PATCH failed) — see `DocumentSaveCoordinator.start`, which is the
    // one piece of code both paths share below the public entry points. These tests pin that
    // contract for the live path specifically, so a future change that special-cases
    // `save.liveSnapshot` inside `start`/`finish` cannot silently break it.

    /// Half-land, `contentLanded == false`: the content PATCH itself fails transiently
    /// (offline), so `saveLiveSnapshot` THROWS before it can even attempt the title PATCH.
    /// `finish` must NOT stamp `lastPushedMarkdown` — the server never confirmed holding this
    /// body, and stamping it would tell the next replay we pushed content we never actually
    /// sent, masking a real conflict against whatever the server actually holds.
    func testLiveSnapshotContentFailureIsRetryableAndLeavesThePushUnstamped() async {
        let (coordinator, draftStore, contentCache) = makeCoordinator()
        MockURLProtocol.stubHandler = { _ in
            MockURLProtocol.Stub(statusCode: 0, headers: [:], body: Data(), error: URLError(.notConnectedToInternet))
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0A]), projectedMarkdown: "# Unconfirmed", title: "Doc")

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        XCTAssertEqual(
            draftStore.draft(for: documentID)?.markdown, "# Unconfirmed", "the unsent edit stays safely on-device")
        XCTAssertNil(
            draftStore.draft(for: documentID)?.lastPushedMarkdown,
            "the content PATCH never confirmed landing (`saveLiveSnapshot` threw) — the push must not be "
                + "recorded, or the next replay would wrongly believe the server already holds this body")
        XCTAssertNil(contentCache.content(for: documentID), "a pending-sync save writes no cache entry")
    }

    /// Same throw path, a 5xx cause: `retryableSaveFailure` classifies a live snapshot exactly
    /// like a classic save (mirrors `testServerErrorSaveFailureBecomesPendingSync`).
    func testLiveSnapshotServerErrorContentFailureBecomesPendingSync() async {
        let log = RequestRecorder()
        let (coordinator, _, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0B]), projectedMarkdown: "# Retry me", title: "Doc")

        await waitUntil { self.isPendingSync(coordinator.state(for: self.documentID)) }

        // `saveLiveSnapshot` PATCHes content first and throws before attempting the title
        // PATCH, so exactly one request should have reached the stub — the failed content one.
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 1, "the content PATCH throws before a title PATCH is attempted")
    }

    /// The mirror classification: a content PATCH the server rejects on the merits (never a
    /// transport/5xx problem) is `.failed`, not `.pendingSync` — and, being a throw, must still
    /// leave the push unstamped (mirrors `testFailedSaveKeepsDraftAndReportsFailure`, for the
    /// live path).
    func testLiveSnapshotServerRejectedContentBecomesFailedNotPendingSync() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0C]), projectedMarkdown: "# Rejected", title: "Doc")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(draftStore.draft(for: documentID)?.markdown, "# Rejected")
        XCTAssertNil(
            draftStore.draft(for: documentID)?.lastPushedMarkdown,
            "the content PATCH was rejected outright (never landed) — the push must not be recorded")
        // A rejected content PATCH throws before the title PATCH is attempted — same
        // half-land short-circuit as the transient case above.
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/content/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH"), 1, "the content PATCH throws before a title PATCH is attempted")
    }

    /// Half-land, `contentLanded == true`: the content PATCH lands (204) but the title PATCH is
    /// rejected on the merits, so `saveLiveSnapshot` RETURNS a non-nil `DocsAPIError` instead of
    /// throwing. The server now holds this exact body, so the push must be recorded even though
    /// the save as a whole reports `.failed` (mirrors `testANonRetryableHalfLandedSaveStillRecordsThePush`).
    func testLiveSnapshotHalfLandRecordsThePushWhenOnlyTheTitleIsRejected() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 400, headers: [:], body: Data(), error: nil)  // title rejected
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0D]), projectedMarkdown: "# Half-landed", title: "Doc")

        await waitUntil { self.isFailed(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            draftStore.draft(for: documentID)?.lastPushedMarkdown, "# Half-landed",
            "the content PATCH landed (`saveLiveSnapshot` returned a non-nil error, not a throw) — the push "
                + "must be recorded even though the save as a whole failed")
    }

    /// A live snapshot must bump `settledSaves` on settle exactly like a classic save, or a
    /// revalidation fetch issued just before it would not be recognised as possibly racing it —
    /// `mayPredateSave` would wrongly clear a marker that in fact predates a landed live write.
    func testLiveSnapshotSaveMarkerBumpsSettledSavesOnSettle() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, _) = makeCoordinator()
        let marker = coordinator.saveMarker(documentID: documentID)
        XCTAssertFalse(coordinator.mayPredateSave(marker))

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0E]), projectedMarkdown: "# Marked", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        XCTAssertTrue(
            coordinator.mayPredateSave(marker),
            "the live snapshot must bump `settledSaves` on settle exactly like a classic save")
    }

    /// Mirrors `testSaveSuccessWritesContentCacheEntry` for the live path: `finish`'s
    /// content-cache write is not gated on `save.liveSnapshot == nil`, so a landed live
    /// snapshot must write through exactly like a classic save. Pins that against a future
    /// `if save.liveSnapshot == nil` guard slipping in around the cache write.
    func testLiveSnapshotSuccessWritesContentCacheEntry() async {
        let log = RequestRecorder()
        stubSavePipeline(log: log)
        let (coordinator, _, contentCache) = makeCoordinator(backgroundTasks: .noop)

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x0F]), projectedMarkdown: "# Live Content", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }

        let entry = contentCache.content(for: documentID)
        XCTAssertEqual(entry?.title, "Doc")
        XCTAssertEqual(
            entry?.markdown, "# Live Content", "the cache body is the projected markdown, not the raw snapshot bytes")
        XCTAssertNotNil(entry?.syncedAt)
        XCTAssertNil(entry?.serverUpdatedAt, "a void PATCH carries no server timestamp")
    }

    /// **`releaseHeldSave` must still route through `saveLiveSnapshot`, not reconstruct a
    /// classic save.** A live snapshot held behind a recorded conflict is parked in `queued` as
    /// the exact `PendingSave` it was enqueued with (bytes + `liveSnapshot` intact); when the
    /// user resolves the conflict, `releaseHeldSave` hands that same value straight to `start`.
    /// If it were ever rebuilt from `save.title`/`save.markdown` instead, the released PATCH
    /// would silently re-derive Yjs bytes from the *projected* markdown via `MarkdownYjs.encode`
    /// (wrong bytes) and drop the `"websocket": true` flag the server needs to accept a
    /// full-state snapshot over the live-collaboration channel.
    func testAReleasedHeldLiveSnapshotStillPatchesThroughSaveLiveSnapshot() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, draftStore, _) = makeCoordinator()
        let snapshot = Data([0x11, 0x22])
        coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date())

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: snapshot, projectedMarkdown: "# Held", title: "Doc")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }  // confirm it was held

        coordinator.resolveConflictKeepingLocal(documentID: documentID)

        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(
            bodies.contentValues, [snapshot.base64EncodedString()],
            "the released save must carry the ORIGINAL snapshot bytes it was held with")
        XCTAssertEqual(
            bodies.websocketFlags, [true],
            "and it must still be tagged websocket:true — a released hold is not a classic save")
        XCTAssertNil(draftStore.draft(for: documentID))
    }

    /// **`finish`'s plain queued-restart (latest-wins coalescing, no conflict involved) must
    /// also preserve the live-snapshot identity of the coalesced follow-up.** This is a
    /// different code path from the conflict-hold release above: when a second live snapshot
    /// coalesces behind an in-flight one and the first lands, `finish` calls `start` directly
    /// with the queued `PendingSave` — which must still carry `liveSnapshot` bytes and route
    /// through `saveLiveSnapshot`, not silently fall back to re-deriving Yjs from markdown.
    func testACoalescedQueuedRestartOfALiveSnapshotStillCarriesTheWebsocketFlag() async {
        let bodies = ContentPatchRecorder()
        let log = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            bodies.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "PATCH", url.hasSuffix("/content/") {
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil, delay: 0.2)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        let (coordinator, _, _) = makeCoordinator()

        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x01]), projectedMarkdown: "v1", title: "Doc")
        // Coalesces behind the in-flight v1 (no conflict, so this is `finish`'s plain restart —
        // not `releaseHeldSave`).
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x02]), projectedMarkdown: "v2", title: "Doc")

        await waitUntil(timeout: 5) {
            self.isSaved(coordinator.state(for: self.documentID)) && bodies.websocketFlags.count == 2
        }

        XCTAssertEqual(
            bodies.contentValues, [Data([0x01]).base64EncodedString(), Data([0x02]).base64EncodedString()],
            "the queued restart must carry the coalesced save's OWN snapshot bytes, not re-derive them")
        XCTAssertEqual(
            bodies.websocketFlags, [true, true],
            "both the first save and the coalesced restart must route through `saveLiveSnapshot`")
    }

    // MARK: - Downgrade / reconcile coherence (C2b Task 4)

    /// **Downgrade coherence.** After a live snapshot lands (stamping
    /// `lastConfirmedPushMarkdown = projectedMarkdown`), a stored draft written afterward
    /// carries that stamp, so a later markdown-based reconcile against a server holding the
    /// projected body hits `draftSyncDecision` rule 1 ("the server's most recent writer was
    /// us") — a `.push`, never a false `.conflict` against pre-live state — **even though the
    /// server's `updated_at` is far newer than the draft**. This is what lets C2c fall back
    /// from the live-snapshot path to a classic save without inventing a conflict.
    func testAClassicReconcileAfterALiveSnapshotDoesNotFalseConflict() async {
        let log = RequestRecorder()
        let (coordinator, draftStore, _) = makeCoordinator()

        // 1. A live snapshot lands, rendering "# Body" on the server.
        stubSavePipeline(log: log)
        coordinator.enqueueLiveSnapshot(
            documentID: documentID, snapshot: Data([0x07]), projectedMarkdown: "# Body", title: "Doc")
        await waitUntil { self.isSaved(coordinator.state(for: self.documentID)) }
        XCTAssertEqual(coordinator.lastConfirmedPush(documentID: documentID), "# Body")

        // 2. A later offline edit is queued as a draft, stamped with what the snapshot pushed.
        let lastPushed = coordinator.lastConfirmedPush(documentID: documentID)
        draftStore.save(
            PendingDraft(
                documentID: documentID, title: "Doc", markdown: "# Body edited more", updatedAt: Date(),
                baseline: nil, lastPushedMarkdown: lastPushed))

        // 3. The reconcile sees the server still holding the projected body "# Body" with a far
        //    NEWER updated_at (a pre-live-baseline timestamp would otherwise trip a conflict).
        let serverBody = Data(
            """
            {"id": "8b1b1b1b-1b1b-4b1b-8b1b-1b1b1b1b1b1b", "title": "Doc", "content": "# Body", "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "GET", url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: serverBody, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)  // content / title PATCH
        }

        await coordinator.syncPendingDrafts()

        XCTAssertNil(
            coordinator.conflict(for: documentID),
            "rule 1 recognises the server body as our own live-snapshot push — never a conflict")
        // `savesInFlight` counts every content PATCH sent by this test, including step 1's live
        // snapshot — so the reconcile's own replay is the SECOND one; waiting on `>= 1` would
        // pass instantly (before the replay's async save even lands) and race the draft-cleared
        // assertion below.
        await waitUntil { self.savesInFlight(log) >= 2 }
        await waitUntil { draftStore.draft(for: self.documentID) == nil }
        XCTAssertNil(draftStore.draft(for: documentID), "the draft replayed and cleared")
    }
}
