import XCTest

@testable import Schrift

/// The create replay's start-over and take-back paths: a checkpointed record whose server
/// document is gone, and what must survive it.
@MainActor
final class DocumentSaveCoordinatorReplayStartOverTests: DocumentSaveCoordinatorReplayTestCase {
    /// The start-over must not retract the checkpoint under a live screen on the server id.
    /// It removes no draft itself — so the take-back's rationale does not apply — but clearing
    /// `syncedServerID` disarms `runSyncPass`'s server-id suppression, and `runCreatePass`
    /// guards only the *local* id. A user reading the document under `serverID` (the only id
    /// they are offered once checkpointed) can type straight after, take a transient save
    /// failure, and have the next pass meet the same 404 with nothing left holding their
    /// draft back.
    func testAStartOverDoesNotFireWhileAnEditorHoldsTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The screen is open on the server id, with nothing written under it yet — so the
        // draft-absence gate below would pass and the marker is clean.
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.creates.create(for: local.id)?.syncedServerID, serverID,
            "the checkpoint is not retracted while a screen is still writing under that id")
    }

    /// **A save that lands inside the fetch window must not be read as "nothing to lose".**
    /// The start-over's draft-absence gate asks whether work survives under the server id —
    /// but a save that started *and settled successfully* during the resume's fetches has
    /// `finish` remove its draft on the way out, manufacturing exactly the emptiness the gate
    /// reads as safe. The 404 that came back may have been answered from before that save.
    ///
    /// Without the marker check the checkpoint is cleared and the next trigger POSTs a second
    /// document, orphaning the one holding the body the user just watched save. Note the
    /// take-back's identical conjunct cannot cover this: a local draft is present here, so the
    /// take-back is skipped before its conjuncts are ever evaluated.
    func testAStartOverDoesNotFireWhenASaveLandedInsideTheFetchWindow() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The seed draft under the local id stays, so the take-back is skipped outright.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            // The save SUCCEEDS — that is the whole point. `finish` then removes its draft,
            // which is what opens the draft-absence gate.
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil, delay: 1.5)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        let starter = Task { @MainActor in
            await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
            relaunched.coordinator.enqueue(
                documentID: serverID, title: "Notes", markdown: "# Saved during the fetch")
            await waitUntil { relaunched.drafts.draft(for: serverID) == nil }
        }

        await relaunched.coordinator.syncPendingDrafts()
        _ = await starter.value

        XCTAssertEqual(
            relaunched.creates.create(for: local.id)?.syncedServerID, serverID,
            "the checkpoint survives a 404 that may predate the save that just landed")
        XCTAssertEqual(creates(log), 0, "and nothing is re-POSTed")
    }

    /// The take-back's third conjunct, `!mayPredateSave(marker)` — the one cell neither
    /// sibling reaches. `inFlight` catches a save still on the wire and `hasOpenEditor` a live
    /// screen; this catches a save that both **started and settled** inside the resume's fetch
    /// window, which leaves no witness in either. The marker's settled-save counter is the
    /// only thing that still remembers it.
    ///
    /// Why it matters: the fetched 404 may have been answered from a state that predates that
    /// save, so it is no evidence the document is gone. Without the conjunct the take-back
    /// moves the draft off the server id and the start-over then clears the checkpoint,
    /// re-POSTing a document that may still exist — a duplicate, from a save the pass itself
    /// raced.
    func testTheTakeBackDeclinesWhenASaveSettledInsideTheFetchWindow() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The partial-migration window: the server-id draft is the only copy.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Only copy", updatedAt: Date(),
                baseline: nil))
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            // The save fails transiently, so it settles fast and *keeps* its draft — which is
            // what leaves the take-back looking at an orphan with `inFlight` already nil.
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 503, headers: [:], body: Data(), error: nil)
            }
            if request.url?.absoluteString.contains("formatted-content") == true {
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil, delay: 1.5)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        let starter = Task { @MainActor in
            await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
            relaunched.coordinator.enqueue(
                documentID: serverID, title: "Notes", markdown: "# Typed during the fetch")
            // Settled before the 404 lands: `inFlight` is nil again, so only the marker knows.
            await waitUntil { relaunched.coordinator.pendingSave(documentID: serverID) == nil }
        }

        await relaunched.coordinator.syncPendingDrafts()
        _ = await starter.value

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Typed during the fetch",
            "the settled save's body stays under the id it was written for")
        XCTAssertNil(relaunched.drafts.draft(for: local.id), "not taken back")
        XCTAssertEqual(
            relaunched.creates.create(for: local.id)?.syncedServerID, serverID,
            "and the checkpoint survives, so nothing is re-POSTed")
    }

    /// **The start-over's discharge, reached with something to discharge.** Round 34 inverted
    /// the two tests that used to cover these lines — correctly, since they asserted a
    /// discharge that costs content — but that left `queued[serverID] = nil` and
    /// `clearResolvedConflict(documentID: serverID)` with no discriminating test: every
    /// remaining test that reaches them arrives with both already nil.
    ///
    /// The reachable shape is the take-back path. A conflicted, parked save under the server
    /// id, whose draft the take-back moves back to the local id — after which the start-over
    /// gate passes (nothing is left under that id) and the discharge fires with the conflict
    /// and the queued save still live. Without the clear, `conflicts[serverID]` outlives its
    /// draft and can never be repaired (`persistConflictOnDraft` needs a draft to write to),
    /// so a spurious 404 parks every future save for that document behind a pill nothing can
    /// answer. Without the `queued` drop first, `clearResolvedConflict` → `releaseHeldSave`
    /// pops the parked save and PATCHes the id that just 404'd.
    func testAStartOverDischargesAConflictItLeavesNothingToProtect() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // A recorded conflict, then an edit that parks rather than starts — so the take-back's
        // `inFlight` conjunct holds and it is free to move the body back.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Parked")
        XCTAssertEqual(savesInFlight(log), 0, "held, not sent")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Parked",
            "the body came back rather than being discharged along with the hold")
        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "discharged — nothing is left under that id for it to protect")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// A death inside the migration can leave the only copy of the body under `serverID`.
    /// Dropping the checkpoint severs the last thing tying it to the record, **orphaning** the
    /// body: the re-POST mints a different server id and its body chain looks under the local
    /// id and the new one, never the old, so it builds an *empty* document in place of the
    /// text — and the stranded draft is separately reaped by `runSyncPass`'s 404 rule. (That
    /// draft is never covered by the pending-create hold in either ordering; the hold is keyed
    /// on the local id.)
    func testAStartOverTakesTheOrphanedBodyBackToTheLocalID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Exactly the partial-migration window: server-id draft written, local one removed.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Only copy", updatedAt: Date(),
                baseline: nil))
        // The checkpointed document is gone, and so the draft's own GET would 404 too.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the record survives to be retried")
        XCTAssertNil(relaunched.creates.create(for: local.id)?.syncedServerID, "the checkpoint dropped")
        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Only copy",
            "and the body came back to the id a fresh create will look for")
        // Deliberately *not* asserting the server-id draft is gone. It would be — but not
        // necessarily because the take-back removed it: `runSyncPass` runs next in this same
        // pass, is not gated by the pending-create hold (keyed on the local id), GETs that
        // draft, meets the same 404 and reaps it. So the assertion passes even with the
        // take-back's `remove` deleted, which makes it a claim the test cannot establish.
        // Pinning move-versus-copy here would need that draft's own GET to succeed, and it
        // cannot: it names the id that just 404'd.
    }

    /// The tail of `discardPendingWork` belongs to the document being **deleted**, not to the
    /// record — so the open-editor branch must not cancel it. Written as an early `return` it
    /// did: the `serverID` draft survived, and `discardedDuringSave` never learned about the
    /// in-flight save, so `finish` took its success path and re-created the content cache
    /// entry for a document that had just been DELETEd. Invariant 0b, introduced once already.
    func testDeletingTheServerStrayStillPurgesItsOwnDraftAndSuppressesTheWriteThrough() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil, delay: 0.2)
        }
        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: local.id)
        // The user opened the server stray, typed, and a save is on the wire for it.
        relaunched.coordinator.enqueue(documentID: serverID, title: "Stray", markdown: "# Typed")
        await waitUntil { self.savesInFlight(log) == 1 }

        relaunched.coordinator.discardPendingWork(documentID: serverID)

        XCTAssertNil(
            relaunched.drafts.draft(for: serverID),
            "the deleted document's own draft goes, whatever happens to the record")
        // Wait for the save to actually settle before asserting the cache.
        // `waitAndConfirmNever` defaults to 0.3 s, so against the old 2 s stub the assertion
        // could not have failed however the code behaved — vacuous, which is the one thing
        // this PR's review keeps finding. `finish` sets `.idle` on the discarded path and
        // `.saved` otherwise, so this synchronises for both.
        await waitUntil { relaunched.coordinator.state(for: self.serverID) != .saving }
        let cache = DocumentContentCacheStore(directory: cacheDirectory)
        XCTAssertNil(
            cache.content(for: serverID),
            "the settled save must not re-create a cache entry for a DELETEd document")
        XCTAssertNotNil(
            relaunched.drafts.draft(for: local.id), "and the live editor's body is untouched")
        XCTAssertNotNil(relaunched.creates.create(for: local.id))
    }

    /// **Deleting the empty server stray must not take a live editor's body.** An editor
    /// reopened during the POST leaves the record checkpointed-but-unmigrated, so Home shows
    /// the server document — empty, since the body is enqueued only at migration — and the
    /// user deletes it as a duplicate. That path removed the record *and the local draft*,
    /// which is the only copy of what they are still typing.
    func testDeletingTheServerStrayKeepsALiveEditorsBody() async {
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Still typing")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: local.id)

        relaunched.coordinator.discardPendingWork(documentID: serverID)

        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Still typing",
            "the body the open screen is showing is still on disk")
        XCTAssertNotNil(relaunched.creates.create(for: local.id), "and it can still be created")
        XCTAssertNil(
            relaunched.creates.create(for: local.id)?.syncedServerID,
            "starting over, since the document it was checkpointed onto is gone")
    }

    /// The take-back's other reason to decline: a save on the wire for the server id. Removing
    /// that draft under an in-flight save drops the write-ahead copy of what is being sent, and
    /// the start-over that follows re-POSTs the body as a second document. Sibling of
    /// `testTheTakeBackDeclinesWhileAnEditorHoldsTheServerID`; the conjuncts differ, the harm
    /// does not.
    func testTheTakeBackDeclinesWhileASaveForTheServerIDIsOnTheWire() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil, delay: 2.0)
            }
            if request.url?.absoluteString.contains("formatted-content") == true {
                return .init(statusCode: 404, headers: [:], body: Data(), error: nil, delay: 0.6)
            }
            return .init(statusCode: 404, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The save must START AFTER the resume takes its marker. Enqueuing first makes
        // `marker.hadPendingSave` true, and the take-back is then blocked by `!mayPredateSave`
        // — a *different* conjunct — leaving the one this test names with no coverage at all.
        // That is what the first version of this test did. Launch it from inside the resume's
        // fetch window instead: the recorder logs a request when it is issued, so once the
        // `formatted-content` GET appears the marker is taken, and that GET is held open long
        // enough for the PATCH to still be on the wire when the take-back runs.
        let starter = Task { @MainActor in
            await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
            relaunched.coordinator.enqueue(
                documentID: serverID, title: "Notes", markdown: "# On the wire")
        }

        await relaunched.coordinator.syncPendingDrafts()
        _ = await starter.value

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# On the wire",
            "the write-ahead copy of the save on the wire is not moved out from under it")
        XCTAssertNil(relaunched.drafts.draft(for: local.id), "not taken back under a live save")
        XCTAssertEqual(relaunched.creates.create(for: local.id)?.syncedServerID, serverID)
        // The counter is monotonic, so this only shows a content PATCH was *issued*. What
        // establishes it was still open is the pair above: the draft was neither moved nor
        // removed, and the checkpoint survived.
        XCTAssertEqual(savesInFlight(log), 1, "the save reached the network")
    }

    /// With a local draft still present this is *not* the partial-migration window, so a draft
    /// under the server id is the user's own separate work — the take-back must not overwrite
    /// the local body with it. Since round 34 that draft is preserved as well: with both
    /// present the take-back declines *and* the start-over declines, so the checkpoint
    /// survives — and the checkpoint is exactly what makes `runSyncPass` skip its own 404
    /// delete for this id. (An earlier revision of this comment said the opposite, describing
    /// the behaviour that round closed.)
    func testAStartOverLeavesAUserDraftUnderTheServerIDAlone() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Both present: the local seed draft (rewritten with a body) and a server-id draft.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Mine", markdown: "# Local body", updatedAt: Date(),
                baseline: nil))
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Theirs", markdown: "# Against the real document",
                updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: local.id)?.markdown, "# Local body",
            "the local body is not overwritten by the server-id draft")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Against the real document",
            "and the server-id body survives the pass rather than being reaped by it")
    }

    /// **A delete arriving under the server id must clear the record too.** Once checkpointed,
    /// that is the only id the user is offered — the local row is withheld — so this is the
    /// ordinary way such a document gets deleted. `isPendingCreate` is keyed on the *local* id
    /// and answers false, so without the branch the record and the local draft both survive a
    /// successful DELETE, the resume 404s, the checkpoint clears, and the next pass re-POSTs
    /// the document from that draft.
    func testDeletingUnderTheServerIDDoesNotResurrectTheDocument() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // What `EditorViewModel.handleDidDelete` does after the server DELETE succeeds — and
        // the id it has is the server one.
        relaunched.coordinator.discardPendingWork(documentID: serverID)

        XCTAssertNil(relaunched.creates.create(for: local.id), "the record went with the delete")
        XCTAssertNil(relaunched.drafts.draft(for: local.id), "and so did the body it would rebuild from")

        // The server now 404s it, as it would after a real delete. Two passes, because one is
        // not enough to distinguish the fix from its absence: without the branch the first
        // pass only clears the checkpoint, and it is the *second* that re-POSTs.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }
        await relaunched.coordinator.syncPendingDrafts()
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(creates(log), 0, "nothing re-POSTs a document the user deleted")
    }

    /// A start-over must **keep** a conflict whose draft still holds the user's work. This
    /// docstring used to argue the opposite — that discharging is required, because
    /// `runSyncPass` skips a conflicted draft so the 404 rule it defers to never collects it,
    /// stranding the record. True, and beside the point: discharging drops the held keystrokes
    /// and then the draft with them, and stranding is recoverable where that is not.
    ///
    /// The line this actually pins is `guard draftStore.draft(for: serverID) == nil` — the
    /// start-over gate — not the discharge, which it never reaches. `init` rehydrating the
    /// stamp from disk is what makes the state survive relaunches; no process kill is needed.
    func testAStartOverKeepsAConflictAgainstTheDeadServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The user met the document under its server id, typed, and a divergence was recorded
        // there before the document was deleted — a draft carrying a conflict stamp.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Typed under the server id",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: nil,
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        // Round 33 asserted the opposite here, on the reasoning that a discharged conflict
        // stops the record stranding. That was wrong in the direction that costs content: a
        // bare 404 is not proof the document is gone, and discharging drops the held
        // keystrokes *and* the checkpoint protecting this draft, after which `runSyncPass` —
        // next in the same pass, on the same 404 — deletes it. Stranding is recoverable;
        // deleting the only copy is not.
        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "kept — the 404 is not evidence, and the body it holds is the only copy")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Typed under the server id")
    }

    /// The start-over must **keep** the conflict when a save is parked behind it, because the
    /// parked save *is* the user's work. An earlier revision of this docstring argued the
    /// reverse — that a queued slot with nothing in flight is the conflict hold, `releaseHeldSave`
    /// its only drainer, and the discharge its only reach, so declining strands the record
    /// permanently. All true; it simply ranks stranding above losing the body, which is
    /// backwards.
    ///
    /// Like its sibling above, this pins the start-over **gate**, not the discharge —
    /// `testAStartOverDischargesAConflictItLeavesNothingToProtect` covers the discharge, on
    /// the one path that reaches it with anything to discharge.
    func testAStartOverKeepsAConflictEvenWithASaveParked() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The conflict hold: a recorded divergence, then an edit that parks rather than starts.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Parked")
        XCTAssertEqual(savesInFlight(log), 0, "held, not sent")

        await relaunched.coordinator.syncPendingDrafts()

        // Inverted for the same reason as the test above: the parked save *is* the user's
        // work, and discharging it here is the loss, not the cleanup.
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "kept")
        XCTAssertEqual(relaunched.drafts.draft(for: serverID)?.markdown, "# Parked")
    }

    /// The loss path with no conflict anywhere. A checkpointed record, a local draft, and the
    /// user's own work under the server id whose save failed transiently. The take-back
    /// declines by design (a local draft is present, so that body is not ours to move), and
    /// before the start-over was gated, clearing `syncedServerID` disarmed the only thing
    /// stopping `runSyncPass` — next in the same pass, on the same 404 — from deleting it.
    func testASpuriousNotFoundKeepsADraftTheTakeBackDeclinesToMove() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        // Both bodies exist: the seed draft under the local id, the user's under the server id.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Their own work",
                updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        // Relaunch, so the coordinator's in-memory mirror actually carries the checkpoint —
        // writing it straight to the store leaves the mirror stale, and every guard that keys
        // off `checkpointedRecord(forServerID:)` reads the mirror.
        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "# Their own work")
        XCTAssertNotNil(env.drafts.draft(for: local.id))
        XCTAssertEqual(env.creates.create(for: local.id)?.syncedServerID, serverID)
    }

    /// The take-back moves an orphaned body off the server id — but it must not do that under a
    /// live editor, which would yank the disk backing out from under the screen and let the
    /// re-POST mint a second document holding the same text.
    func testTheTakeBackDeclinesWhileAnEditorHoldsTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Live", updatedAt: Date(), baseline: nil))
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(env.drafts.draft(for: serverID)?.markdown, "# Live")
        XCTAssertNil(env.drafts.draft(for: local.id))
        XCTAssertEqual(env.creates.create(for: local.id)?.syncedServerID, serverID)
    }

    /// A spurious 404 must not void a persisted conflict hold. The start-over's premise is
    /// "the document is gone", but a proxy hiccup maps to `.notFound` too — and discharging on
    /// one drops the held keystrokes, erases the hold in memory and on disk, and removes the
    /// suppression protecting that draft, after which a keystroke landing before `runSyncPass`
    /// re-detects reaches `enqueue` with nothing holding it.
    func testASpuriousNotFoundDoesNotVoidAHeldConflict() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 404, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The user typed under the server id, a conflict held the push — and they navigated
        // away, so no editor is open and no save is in flight. That is the whole point: the
        // work at stake leaves no witness of *concurrent* activity, so a gate that only asks
        // about concurrency lets the discharge through and reaps the draft.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Held")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "a bare 404 is not evidence enough to void a hold the user still has to answer")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Held",
            "and the held work is still on disk")
    }
}
