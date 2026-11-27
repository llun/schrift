import XCTest

@testable import Schrift

@MainActor
final class DocumentSaveCoordinatorNativeRetryTests: DocumentSaveCoordinatorTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private struct Fixture {
        let coordinator: DocumentSaveCoordinator
        let drafts: PendingDraftStore
        let store: ReplicaStore
        let adapter: ReplicaSaveAdapter
        let scope: ReplicaScope
        let gate: SleepGate
        let checkpoint: Data
        let update: Data
    }

    private func fixture(
        isOnline: @escaping @MainActor () -> Bool = { true },
        isHeld: @escaping @MainActor (UUID) -> Bool = { _ in false },
        isForegrounded: Bool = true
    ) throws -> Fixture {
        let gate = SleepGate()
        let scope = ReplicaScope(
            serverOrigin: "https://docs.example.org", ownerUserID: owner, org: "docs", documentID: documentID)
        let checkpoint = BlockNoteYjs.encode(
            [
                BlockNoteBlock(
                    node: "paragraph",
                    props: DocumentEngineTestCase.paragraphProps, runs: [InlineRun("One")], id: "one")
            ], clientID: 1)
        let doc = YDoc(clientID: 2)
        defer { doc.destroy() }
        try doc.applyUpdate(YUpdateDecoder.decode(checkpoint), origin: .remote)
        let update = try BlockNoteWriter(doc: doc).replaceText(block: "one", range: 0..<0, with: "x")
        let suite = "DocumentSaveCoordinatorNativeRetryTests.\(UUID().uuidString)"
        draftSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let ownership = ReplicaOwnershipStore(userDefaults: defaults)
        let store = ReplicaStore(
            directory: cacheDirectory.appendingPathComponent("ReplicaDrafts.\(UUID().uuidString)"),
            ownershipStore: ownership)
        _ = try store.create(for: scope, checkpoint: checkpoint)
        let adapter = ReplicaSaveAdapter(store: store, scope: scope)
        try adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: 0, blockID: "one", range: 0..<0, replacement: "x"),
            update: update)
        let drafts = PendingDraftStore(userDefaults: defaults)
        let listCache = DocumentCacheStore(userDefaults: defaults)
        SignedInUserStore(userDefaults: defaults).remember(owner)
        let contentCache = DocumentContentCacheStore(directory: cacheDirectory)
        let client = DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] })
        let coordinator = DocumentSaveCoordinator(
            client: client, draftStore: drafts, replicaStore: store, contentCache: contentCache,
            listCache: listCache, serverOrigin: "https://docs.example.org", backgroundTasks: .noop,
            isLiveReplicaHeld: isHeld, isOnline: isOnline, isForegrounded: isForegrounded,
            sleep: { try await gate.sleep($0) })
        return Fixture(
            coordinator: coordinator, drafts: drafts, store: store, adapter: adapter, scope: scope,
            gate: gate, checkpoint: checkpoint, update: update)
    }

    private func enqueue(_ f: Fixture, title: String = "Doc") throws {
        try f.coordinator.enqueueReplica(
            adapter: f.adapter, title: title,
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1), markdown: "One", title: "Doc"))
    }

    private func appendEdit(_ f: Fixture, revision: UInt64, text: String) throws {
        let doc = YDoc(clientID: UInt(10 + revision))
        defer { doc.destroy() }
        let restored = try XCTUnwrap(try f.store.restore(for: f.scope))
        try doc.applyUpdate(YUpdateDecoder.decode(restored.checkpoint), origin: .remote)
        for existing in restored.updates {
            try doc.applyUpdate(YUpdateDecoder.decode(existing), origin: .remote)
        }
        let update = try BlockNoteWriter(doc: doc).replaceText(block: "one", range: 0..<0, with: text)
        try f.adapter.record(
            NativeEditCommand(id: UUID(), baseRevision: revision, blockID: "one", range: 0..<0, replacement: text),
            update: update)
    }

    private func stub(
        log: RequestRecorder,
        bodyResponses: @escaping @Sendable () -> (statusCode: Int, headers: [String: String]),
        titleStatus: @escaping @Sendable () -> Int = { 200 },
        formattedContent: String = "One",
        formattedUpdatedAt: String = "1970-01-01T00:00:01Z"
    ) {
        let ownerID = owner.uuidString
        let formatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"\(formattedContent)",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"\(formattedUpdatedAt)"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                let response = bodyResponses()
                return .init(statusCode: response.statusCode, headers: response.headers, body: Data(), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: titleStatus(), headers: [:], body: Data(), error: nil)
            }
            if path.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
    }

    func testNativeSaveRetriesAfter503WithExponentialBackoffAndReachesSaved() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let bodyAttempt = Counter()
        stub(
            log: log,
            bodyResponses: {
                let n = bodyAttempt.next()
                return n <= 2 ? (503, [:]) : (200, [:])
            })

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations, [.seconds(2)], "first backoff step is 2s")
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)

        // First retry also hits 503: backoff doubles to 4s.
        f.gate.releaseNext()
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 2
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
                && f.gate.pendingCount == 1
        }
        XCTAssertEqual(f.gate.durations, [.seconds(2), .seconds(4)], "second backoff step doubles to 4s")

        // Second retry succeeds: ends .saved without user action, draft & outbox cleared.
        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(f.gate.pendingCount, 0)
        XCTAssertNil(try f.store.outbox(for: f.scope))
        XCTAssertNil(f.drafts.draft(for: documentID))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 3)
        XCTAssertGreaterThanOrEqual(
            log.count(ofMethod: "GET", urlContaining: "formatted-content"), 2,
            "retries must reuse the coordinator's replay path")

        // A later edit that fails starts fresh at 2s (backoff reset on success).
        try appendEdit(f, revision: 1, text: "y")
        let nextAttempt = Counter()
        stub(
            log: log,
            bodyResponses: { nextAttempt.next() == 1 ? (503, [:]) : (200, [:]) },
            formattedContent: "xOne")
        try f.coordinator.enqueueReplica(
            adapter: f.adapter, title: "Doc",
            baseline: DraftBaseline(serverUpdatedAt: Date(timeIntervalSince1970: 1), markdown: "xOne", title: "Doc"))
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations.last, .seconds(2), "backoff must reset after success")
        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
    }

    func testNativeSave429RespectsRetryAfterAndRecoversToSaved() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let bodyAttempt = Counter()
        stub(
            log: log,
            bodyResponses: {
                bodyAttempt.next() == 1 ? (429, ["Retry-After": "15"]) : (200, [:])
            })

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations, [.seconds(15)], "429 Retry-After must govern the retry delay")

        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(f.gate.pendingCount, 0)
        XCTAssertNil(f.drafts.draft(for: documentID))
    }

    func testNativeTitlePatchFailureAfterBodyLandedRetriesAndReachesSaved() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let titleAttempt = Counter()
        stub(
            log: log,
            bodyResponses: { (204, [:]) },
            titleStatus: { titleAttempt.next() == 1 ? 503 : 200 },
            formattedContent: "xOne",
            formattedUpdatedAt: "2026-01-15T10:30:00Z")

        try enqueue(f, title: "Renamed")
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertNil(try f.store.outbox(for: f.scope), "body PATCH was already acknowledged")
        XCTAssertEqual(f.gate.durations, [.seconds(2)])

        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/api/v1.0/documents/"), 2)
    }

    func testConflictHeldSaveIsNotRetried() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        stub(log: log, bodyResponses: { (503, [:]) })

        // First: a 503 schedules a retry; recording a conflict cancels it so nothing retries.
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        let patchesBeforeConflict = log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/")

        f.coordinator.recordConflict(documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 999))
        await waitUntil { f.gate.pendingCount == 0 }
        f.gate.releaseAll()
        await waitAndConfirmNever {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") > patchesBeforeConflict
                || f.gate.pendingCount > 0
        }

        // Second: a server change observed while a failing save is in flight records a conflict
        // during finish and never schedules a retry.
        f.coordinator.clearResolvedConflict(documentID: documentID)
        let bodyGate = MockURLProtocol.ResponseGate()
        defer { bodyGate.open() }
        let ownerID = owner.uuidString
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil, releasedBy: bodyGate)
            }
            return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
        }
        let sleepsBeforeObserved = f.gate.durations.count
        try enqueue(f)
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        f.coordinator.noteServerObservedDuringSave(
            documentID: documentID, serverUpdatedAt: Date(timeIntervalSince1970: 2000), markdown: "Co-author edit")
        bodyGate.open()
        await waitUntil { f.coordinator.conflict(for: self.documentID) != nil }
        await waitAndConfirmNever { f.gate.durations.count > sleepsBeforeObserved }
    }

    func testGoingOfflineStopsRetries() async throws {
        var online = true
        let f = try fixture(isOnline: { online })
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        stub(log: log, bodyResponses: { (503, [:]) })

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        let patchesBeforeOffline = log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/")

        // Going offline stops the scheduled retry even if the sleep completes without explicit cancel.
        online = false
        f.gate.releaseNext()
        await waitAndConfirmNever {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") > patchesBeforeOffline
                || f.gate.pendingCount > 0
        }

        // A new failure while already offline schedules no retry at all.
        let sleepsWhileOffline = f.gate.durations.count
        try enqueue(f)
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == patchesBeforeOffline + 1
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
        }
        await waitAndConfirmNever { f.gate.durations.count > sleepsWhileOffline }
    }

    func testLifecycleCancelsHoldsSuppressAndNewEditResetsBackoff() async throws {
        var liveHeld = false
        let f = try fixture(isHeld: { _ in liveHeld })
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        stub(log: log, bodyResponses: { (503, [:]) })

        // 1. Backgrounding cancels a scheduled retry.
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        f.coordinator.setForegrounded(false)
        await waitUntil { f.gate.pendingCount == 0 }
        f.coordinator.setForegrounded(true)

        // 2. Live hold stops a scheduled retry from firing.
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        let patchesBeforeLiveHold = log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/")
        liveHeld = true
        f.gate.releaseNext()
        await waitAndConfirmNever {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") > patchesBeforeLiveHold
                || f.gate.pendingCount > 0
        }
        liveHeld = false

        // 3. Backoff advances to 4s, then a new edit resets it back to 2s.
        try enqueue(f)
        await waitUntil { f.gate.pendingCount == 1 }
        f.gate.releaseNext()
        await waitUntil { f.gate.durations.last == .seconds(4) && f.gate.pendingCount == 1 }
        try appendEdit(f, revision: 1, text: "z")
        try enqueue(f)
        await waitUntil { f.gate.durations.last == .seconds(2) && f.gate.pendingCount == 1 }

        // 4. Sign-out cancels pending retries.
        f.coordinator.purgeCleanNativeReplicasOnSignOut(ownerUserID: owner)
        await waitUntil { f.gate.pendingCount == 0 }

        // 5. Pending delete cancels pending retries.
        try enqueue(f)
        await waitUntil { f.gate.pendingCount == 1 }
        f.coordinator.recordPendingDelete(documentID: documentID, ownerUserID: owner)
        await waitUntil { f.gate.pendingCount == 0 }
        f.coordinator.cancelPendingDelete(documentID: documentID)

        // 6. Document delete cancels pending retries.
        try enqueue(f)
        await waitUntil { f.gate.pendingCount == 1 }
        f.coordinator.discardPendingWork(documentID: documentID)
        await waitUntil { f.gate.pendingCount == 0 }

        // 7. Classic saves do NOT schedule native backoff retries.
        let classicGate = SleepGate()
        let classicSuite = "DocumentSaveCoordinatorNativeRetryTests.Classic.\(UUID().uuidString)"
        draftSuiteNames.append(classicSuite)
        let classicDefaults = UserDefaults(suiteName: classicSuite)!
        let classicCoordinator = DocumentSaveCoordinator(
            client: DocsAPIClient(baseURL: baseURL, session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            draftStore: signedInDraftStore(classicDefaults),
            replicaStore: ReplicaStore(
                directory: cacheDirectory.appendingPathComponent("ClassicReplica.\(UUID().uuidString)"),
                ownershipStore: ReplicaOwnershipStore(userDefaults: classicDefaults)),
            contentCache: DocumentContentCacheStore(directory: cacheDirectory),
            backgroundTasks: .noop,
            sleep: { try await classicGate.sleep($0) })
        let classicID = otherDocumentID
        stubSavePipeline(log: log, contentStatus: 503)
        classicCoordinator.enqueue(documentID: classicID, title: "Classic", markdown: "Body")
        await waitUntil { self.isPendingSync(classicCoordinator.state(for: classicID)) }
        await waitAndConfirmNever { !classicGate.durations.isEmpty }
    }

    func testBackoffCapsAtSixtySecondsAndFloorsRetryAfter() {
        let backoff = DocumentSaveCoordinator.NativeSaveRetryBackoff()
        let delays = (0...7).map { backoff.delay(attempt: $0) }
        XCTAssertEqual(
            delays,
            [
                .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60),
                .seconds(60),
            ]
        )
        XCTAssertEqual(backoff.delay(attempt: 0, retryAfter: 12), .seconds(12))
        XCTAssertEqual(backoff.delay(attempt: 2, retryAfter: 1), .seconds(8), "never faster than exponential floor")
    }

    func testRetryFiringDuringSyncPassIsCoalescedNotDropped() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()

        // A second document whose replay GET blocks `syncPendingDrafts()` inside `runSyncPass()`
        // after `runSyncPass()` has already snapshotted `draftStore.allDrafts()`.
        f.drafts.save(
            PendingDraft(
                documentID: otherDocumentID, title: "Other", markdown: "Other body",
                updatedAt: Date(timeIntervalSince1970: 2),
                baseline: DraftBaseline(
                    serverUpdatedAt: Date(timeIntervalSince1970: 1), markdown: "Other", title: "Other")))

        let otherGetGate = MockURLProtocol.ResponseGate()
        defer { otherGetGate.open() }
        let bodyAttempt = Counter()
        let ownerID = owner.uuidString
        let docFormatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"One",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"1970-01-01T00:00:01Z"}
            """.utf8)
        let otherFormatted = Data(
            """
            {"id":"\(otherDocumentID.uuidString)","title":"Other","content":"Other",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"1970-01-01T00:00:01Z"}
            """.utf8)
        let docIDLower = documentID.uuidString.lowercased()
        let otherIDLower = otherDocumentID.uuidString.lowercased()

        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                return bodyAttempt.next() == 1
                    ? .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
            if path.contains("formatted-content") {
                if path.lowercased().contains(otherIDLower) {
                    return .init(
                        statusCode: 200, headers: [:], body: otherFormatted, error: nil, releasedBy: otherGetGate)
                }
                if path.lowercased().contains(docIDLower) {
                    return .init(statusCode: 200, headers: [:], body: docFormatted, error: nil)
                }
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        // Start a sync pass and pause it on `otherDocumentID`'s GET: `runSyncPass()` has already
        // snapshotted `draftStore.allDrafts()` without `documentID`.
        let syncTask = Task { await f.coordinator.syncPendingDrafts() }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // Enqueue `documentID` while the pass is running; its PATCH hits 503 and schedules a retry.
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }

        // Fire the retry while `isSyncingDrafts` is still true; it must coalesce rather than drop.
        f.gate.releaseNext()
        await waitUntil { f.gate.pendingCount == 0 }

        // Let the slow sync pass finish; the coalesced pass must replay `documentID` to `.saved`.
        otherGetGate.open()
        await syncTask.value
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 2)
    }

    func testBackgroundingDuringReplayGetCancelsRetryAndSendsNoPatch() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let formattedGate = MockURLProtocol.ResponseGate()
        defer { formattedGate.open() }
        let ownerID = owner.uuidString
        let formatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"One",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"1970-01-01T00:00:01Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
            }
            if path.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil, releasedBy: formattedGate)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        let patchesBeforeRetry = log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/")
        XCTAssertEqual(patchesBeforeRetry, 1)

        // Start the retry and pause it inside its `formatted-content` GET.
        f.gate.releaseNext()
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        // Background the app while the retry's GET is in flight, then let the response finish.
        f.coordinator.setForegrounded(false)
        formattedGate.open()

        await waitAndConfirmNever {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") > patchesBeforeRetry
                || f.gate.pendingCount > 0
        }
    }

    func testSyncPassPreservesBackoffAcrossSustainedFailures() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        stub(log: log, bodyResponses: { (503, [:]) })

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations, [.seconds(2)])

        // An unrelated sync pass (home refresh, editor close, search) replays and fails again:
        // backoff must advance to 4s instead of restarting at 2s.
        await f.coordinator.syncPendingDrafts()
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 2
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
                && f.gate.pendingCount == 1
        }
        XCTAssertEqual(f.gate.durations, [.seconds(2), .seconds(4)], "sync pass must not reset backoff to 2s")

        // A second sync pass during sustained 503s advances backoff to 8s.
        await f.coordinator.syncPendingDrafts()
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 3
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
                && f.gate.pendingCount == 1
        }
        XCTAssertEqual(f.gate.durations, [.seconds(2), .seconds(4), .seconds(8)])
    }

    func testTerminal401And403And404ScheduleNoRetry() async throws {
        for status in [401, 403, 404] {
            let f = try fixture()
            defer { f.coordinator.cancelNativeSaveRetries() }
            let log = RequestRecorder()
            stub(log: log, bodyResponses: { (status, [:]) })

            try enqueue(f)
            await waitUntil { self.isFailed(f.coordinator.state(for: self.documentID)) }
            await waitAndConfirmNever { !f.gate.durations.isEmpty }
        }

        // Same on the replay's own GET: 401 stays pending without retrying; 403/404 mark failed without retrying.
        for status in [401, 403, 404] {
            let f = try fixture()
            defer { f.coordinator.cancelNativeSaveRetries() }
            let log = RequestRecorder()
            let ownerID = owner.uuidString
            let patchAttempt = Counter()
            MockURLProtocol.stubHandler = { request in
                log.record(request)
                let path = request.url?.absoluteString ?? ""
                if path.hasSuffix("/config/") {
                    return .init(
                        statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
                }
                if path.hasSuffix("/users/me/") {
                    return .init(
                        statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
                }
                if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                    _ = patchAttempt.next()
                    return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                }
                if path.contains("formatted-content") {
                    return .init(statusCode: status, headers: [:], body: Data(), error: nil)
                }
                return .init(statusCode: 204, headers: [:], body: Data(), error: nil)
            }

            try enqueue(f)
            await waitUntil {
                self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1
            }
            let sleepsBefore = f.gate.durations.count
            f.gate.releaseNext()
            if status == 401 {
                await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
                await waitAndConfirmNever {
                    f.gate.durations.count > sleepsBefore || self.isFailed(f.coordinator.state(for: self.documentID))
                }
                XCTAssertTrue(isPendingSync(f.coordinator.state(for: documentID)))
            } else {
                await waitUntil { self.isFailed(f.coordinator.state(for: self.documentID)) }
                await waitAndConfirmNever { f.gate.durations.count > sleepsBefore }
            }
        }
    }

    func testReplayGet503SchedulesNextBackoffRetry() async throws {
        let f = try fixture()
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let ownerID = owner.uuidString
        let bodyAttempt = Counter()
        let getAttempt = Counter()
        let formatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"One",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"1970-01-01T00:00:01Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                return bodyAttempt.next() == 1
                    ? .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
            if path.contains("formatted-content") {
                return getAttempt.next() == 1
                    ? .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) && f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations, [.seconds(2)])

        // First retry's `formatted-content` GET returns 503 -> must schedule next backoff step (4s).
        f.gate.releaseNext()
        await waitUntil {
            log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 && f.gate.durations.count == 2
                && f.gate.pendingCount == 1
        }
        XCTAssertEqual(f.gate.durations, [.seconds(2), .seconds(4)])
        XCTAssertTrue(isPendingSync(f.coordinator.state(for: documentID)))
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 1)

        // Second retry's GET and PATCH succeed -> reaches `.saved`.
        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 2)
    }

    func testRunSyncPassSchedulesRetryWhenReplayGetReturns503() async throws {
        var online = false
        let f = try fixture(isOnline: { online })
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let ownerID = owner.uuidString
        let bodyAttempt = Counter()
        let getAttempt = Counter()
        let formatted = Data(
            """
            {"id":"\(documentID.uuidString)","title":"Doc","content":"One",
             "created_at":"1970-01-01T00:00:01Z","updated_at":"1970-01-01T00:00:01Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let path = request.url?.absoluteString ?? ""
            if path.hasSuffix("/config/") {
                return .init(
                    statusCode: 200, headers: [:], body: Data(#"{"RELEASE_VERSION":"6.0.0"}"#.utf8), error: nil)
            }
            if path.hasSuffix("/users/me/") {
                return .init(statusCode: 200, headers: [:], body: Data("{\"id\":\"\(ownerID)\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH", path.contains("/collaboration/ydoc/") {
                return bodyAttempt.next() == 1
                    ? .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
            if path.contains("formatted-content") {
                return getAttempt.next() == 1
                    ? .init(statusCode: 503, headers: [:], body: Data(), error: nil)
                    : .init(statusCode: 200, headers: [:], body: formatted, error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        // Fail while offline so no retry is scheduled yet.
        try enqueue(f)
        await waitUntil { self.isPendingSync(f.coordinator.state(for: self.documentID)) }
        XCTAssertTrue(f.gate.durations.isEmpty)

        // Come online and run a sync pass: `runSyncPass`'s GET hits 503 and schedules a retry.
        online = true
        await f.coordinator.syncPendingDrafts()
        await waitUntil { f.gate.pendingCount == 1 }
        XCTAssertEqual(f.gate.durations, [.seconds(2)])

        // Releasing that scheduled retry succeeds.
        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
    }

    func testColdLaunchInBackgroundSchedulesNoRetryUntilForegrounded() async throws {
        let f = try fixture(isForegrounded: false)
        defer { f.coordinator.cancelNativeSaveRetries() }
        let log = RequestRecorder()
        let bodyAttempt = Counter()
        stub(
            log: log,
            bodyResponses: { bodyAttempt.next() <= 2 ? (503, [:]) : (200, [:]) })

        // Cold launch in background (`isForegrounded: false`): a 503 stays pending and schedules no retry.
        try enqueue(f)
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 1
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
        }
        await waitAndConfirmNever { !f.gate.durations.isEmpty }

        // Even a background sync pass schedules no retry while still not foregrounded.
        await f.coordinator.syncPendingDrafts()
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 2
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
        }
        await waitAndConfirmNever { !f.gate.durations.isEmpty }

        // Returning to foreground enables retries on the next sync pass failure, then recovers to `.saved`.
        let nextAttempt = Counter()
        stub(
            log: log,
            bodyResponses: { nextAttempt.next() == 1 ? (503, [:]) : (200, [:]) })
        f.coordinator.setForegrounded(true)
        await f.coordinator.syncPendingDrafts()
        await waitUntil {
            log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/") == 3
                && self.isPendingSync(f.coordinator.state(for: self.documentID))
                && f.gate.pendingCount == 1
        }
        XCTAssertEqual(f.gate.durations, [.seconds(2)])

        f.gate.releaseNext()
        await waitUntil { self.isSaved(f.coordinator.state(for: self.documentID)) }
        XCTAssertEqual(log.count(ofMethod: "PATCH", urlContaining: "/collaboration/ydoc/"), 4)
    }
}
