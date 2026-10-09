import XCTest

@testable import Schrift

/// The create replay's migration when the *server* id is live too: deferral while an editor,
/// queued save or in-flight save holds it, draft adoption and the conflict/baseline rules.
@MainActor
final class DocumentSaveCoordinatorReplayMigrationTests: DocumentSaveCoordinatorReplayTestCase {
    /// Once a record is checkpointed the local row is withheld and the *server* document comes
    /// back in an ordinary list fetch — so the user can be editing it under `serverID` while
    /// the migration still guards only `localID`. Migrating then would overwrite that screen's
    /// draft and replace its queued keystrokes.
    func testAMigrationDefersWhileAnEditorHoldsTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // No competing save: the retain is the *only* thing that can defer this, so the
        // assertion cannot be satisfied by one of the sibling guards instead.
        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and wrote nothing under the server id")
    }

    /// The same hazard without a registered editor: a save for the server id sitting in the
    /// *queued* slot with nothing in flight — the shape the conflict hold produces. Migrating
    /// would replace that slot, and releasing the hold would then PATCH the offline body over
    /// the text the user typed.
    func testAMigrationDefersWhileASaveForTheServerIDIsQueued() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // The local draft has to go, or the both-drafts discriminator defers first and this
        // test passes without ever reaching the guard it names.
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The enqueue-hold parks the save in `queued` and starts nothing, so `inFlight` is
        // provably nil and only the `queued` half of the guard can be what defers.
        relaunched.coordinator.recordConflict(documentID: serverID, serverUpdatedAt: Date())
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Typed on the real doc")
        XCTAssertEqual(savesInFlight(log), 0, "held, not sent — so `inFlight` is nil")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        // The discriminator is the record above, not the stamp below. An earlier version of
        // this comment claimed the stamp was: it is not, because with the guard deleted
        // `migrateCreatedDocument`'s terminal `enqueue` re-writes
        // `conflictServerUpdatedAt: conflicts[documentID]?.serverUpdatedAt`, restoring exactly
        // what the rewrite dropped. The stamp is asserted anyway — it is the state the hold
        // depends on surviving — but it is not what fails under mutation.
        XCTAssertNotNil(
            relaunched.drafts.draft(for: serverID)?.conflictServerUpdatedAt,
            "the held work keeps its conflict stamp")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Typed on the real doc",
            "and its body")
    }

    /// The other half of the same guard: a save actually on the wire for the server id.
    /// Migrating would replace the queued slot behind it, and `finish` would then PATCH the
    /// offline body over the text the user just typed.
    func testAMigrationDefersWhileASaveForTheServerIDIsInFlight() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // The resume GETs must SUCCEED, or the pass never reaches the migration and the test
        // passes for the wrong reason. Only the PATCH is held open, so the save is provably
        // still in flight when the migration runs its guards.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if request.httpMethod == "PATCH" {
                return .init(statusCode: 200, headers: [:], body: Data(), error: nil, delay: 2.0)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil, delay: 0.6)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }
        // The save must START AFTER the resume takes its marker, or the pass exits at
        // `replayCreate`'s own `mayPredateSave` guard and never reaches `finishMigration` —
        // which is what an earlier version of this test did, passing for a guard it does not
        // name. So it is launched from inside the resume's own fetch window: the recorder logs
        // a request when it is issued, so once the `formatted-content` GET appears the marker
        // is already taken, and that GET is held open long enough for the PATCH to be on the
        // wire when it answers. `hadPendingSave` is then false and `settledSaves` has not
        // moved, so only `finishMigration`'s `inFlight[serverID] == nil` can defer this.
        let starter = Task { @MainActor in
            await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
            relaunched.coordinator.enqueue(
                documentID: serverID, title: "Notes", markdown: "# On the wire")
        }

        await relaunched.coordinator.syncPendingDrafts()
        _ = await starter.value

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "the migration deferred")
        XCTAssertEqual(
            log.count(ofMethod: "GET", urlContaining: "formatted-content"), 1,
            "the resume issued its fetch, so the pass reached the migration")
        XCTAssertEqual(savesInFlight(log), 1, "the save was still on the wire when it deferred")
    }

    /// A death *between* the migration's two draft writes leaves **both** drafts present. The
    /// discriminator reads that as the user's, so the migration defers rather than migrating —
    /// safe, and it recovers, because `runSyncPass` pushes the server-id draft and a later
    /// trigger then migrates.
    func testADeathBetweenTheTwoDraftWritesDefersRatherThanGuessing() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Offline body")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Both drafts on disk — the server-id one written, the local one not yet removed.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Offline body",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.creates.create(for: local.id), "deferred rather than migrated")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Offline body"
        }
    }

    /// A draft under the server id belongs to the user unless the local draft is already gone
    /// (which is what defines the partial-migration window). With both present, overwriting
    /// the server-id one would destroy work.
    func testAMigrationNeverOverwritesAUserDraftUnderTheServerID() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Real doc", markdown: "# Authored against the server",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# Authored against the server",
            "the user's draft survives")
    }

    /// The partial-migration window itself — the local draft already removed, the server-id
    /// one written. The body must come from there, not fall through to `""`.
    func testAPartiallyMigratedDraftIsAdoptedRatherThanEmptied() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Exactly the shape a death between the two draft writes leaves behind.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Survived the crash",
                updatedAt: Date(), baseline: nil))

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration finished")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Survived the crash"
        }
    }

    /// An empty local body must never be offered as a conflict candidate: "Keep my version"
    /// would PATCH `""` and wipe the document. With nothing local to contribute, adopt the
    /// server.
    func testAnEmptyLocalBodyAdoptsTheServerInsteadOfArmingAWipe() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // No body anywhere on this device — the seed draft is gone too.
        env.drafts.remove(documentID: local.id)
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        // One body answers both GETs (the cosmetic `document` fetch and `formatted-content`).
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(relaunched.coordinator.conflict(for: serverID), "nothing to ask about")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and no empty draft left to push")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// Adopting the server means adopting its **title** as well as its body: this branch has
    /// no evidence its own title is the newer one (it falls back to the mint title, and it
    /// only fires once the server has acquired a body, i.e. after real elapsed time during
    /// which a web rename is at least as likely). So it writes nothing at all — not the body,
    /// which would flatten a co-author's table through `MarkdownYjs`, and not the title, which
    /// would silently revert their rename.
    func testAdoptingTheServerWritesNothingBackAtAll() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Renamed on this device, never typed into.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "My renamed page", markdown: "", updatedAt: Date(),
                baseline: nil))
        // The co-author's body is a table — an `.unknown` block that cannot round-trip.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "| a | b |\\n| - | - |\\n| 1 | 2 |",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in
            .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "no draft left behind")
        // Nothing is written back: not a content PATCH that would flatten the table, and not a
        // title PATCH that would revert a rename this branch cannot prove is stale. The window
        // is widened past the 0.3 s default because a regression here would most likely be a
        // fire-and-forget `Task`, which the default could outrun.
        await waitAndConfirmNever(timeout: 2) {
            log.count(ofMethod: "PATCH", urlContaining: "documents/") > 0
        }
    }

    /// Both sides canonically empty satisfies `==`, but proves nothing: `serverMarkdown` is
    /// `formatted.content ?? ""`, so the equality is manufactured by the fallback rather than
    /// by anyone making the server match us. `willAdoptServer` requires a non-empty server, so
    /// this state falls through to the release — and releasing here would push an empty body
    /// unheld, which is more destructive than the arm the condition was narrowed to exclude.
    func testABothEmptyComparisonDoesNotReleaseAConflict() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Empty local body against the stub's empty server copy, with a persisted stamp.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Untitled document", markdown: "  \n\n ",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: nil,
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "kept — an equality manufactured by the `?? \"\"` fallback is not evidence")
    }

    /// The other arm of `!diverged`, which must **not** release. An empty server with a
    /// non-empty local body is not proof the conflict is moot: `serverMarkdown` is
    /// `formatted.content ?? ""`, so a response carrying no body is indistinguishable from an
    /// emptied document, and nothing here compares the observed `updated_at` against the stamp
    /// the conflict was recorded with. Releasing would discharge a pill the user has already
    /// been shown and then immediately full-overwrite the co-author, since the enqueue that
    /// follows would no longer be parked.
    func testAnEmptyServerDoesNotReleaseAConflictAgainstANonEmptyLocalBody() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Partial-migration window, stamped — but with a real body, against the stub's empty
        // server copy. So `diverged` is false via the empty-server arm, not via equality.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Untitled document", markdown: "# Real local work",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: nil,
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(
            relaunched.coordinator.conflict(for: serverID),
            "kept — an absent body is not proof the co-author's document is empty")
        await waitAndConfirmNever { self.savesInFlight(log) > 0 }
    }

    /// A conflict stamp persisted by an earlier session is rehydrated by `init` for the
    /// *server* id. If the migration then finds the server holding our own body — the
    /// **equality** arm, the only one that proves anything — that record protects nothing —
    /// and leaving it parks the enqueue below, makes `runSyncPass` skip the
    /// document, and self-perpetuates until the user happens to open the editor.
    func testAnUndivergedMigrationReleasesAConflictItProvesIsMoot() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // A **non-empty** body that the server also holds. Both-empty would satisfy `==` too,
        // but only via `formatted.content ?? ""` — no one made anything match there, so it
        // proves nothing and is deliberately excluded.
        let shared = "# Shared body"
        let serverID = self.serverID
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Untitled document", markdown: shared, updatedAt: Date(),
                baseline: nil, lastPushedMarkdown: nil,
                conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data(
                        """
                        {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
                         "content": "\(shared)", "created_at": "2026-03-01T12:00:00Z",
                         "updated_at": "2026-03-01T12:00:00Z"}
                        """.utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "released — the server holds our own non-empty body, so nothing is left to protect")
        XCTAssertNil(relaunched.creates.create(for: local.id), "and the migration completed")
    }

    /// The registry the deferrals key off is now wired from `EditorView`, so a balanced
    /// appear/disappear pair must actually defer a migration and then let it complete. This
    /// pins the coordinator half of that contract — the view owns the balance, the view model
    /// only forwards.
    func testAnEditorRegistrationDefersTheMigrationAndReleasingCompletesIt() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")

        env.coordinator.retainOpenEditor(documentID: local.id)
        await env.coordinator.syncPendingDrafts()
        XCTAssertEqual(creates(log), 0, "deferred while the screen holds it")
        XCTAssertNotNil(env.creates.create(for: local.id))

        env.coordinator.releaseOpenEditor(documentID: local.id)
        await waitUntil { env.creates.create(for: local.id) == nil }

        XCTAssertEqual(creates(log), 1, "and releasing kicks the funnel — no extra trigger needed")
    }

    /// Adopting the server removes every trace of local work for that id, so a conflict record
    /// rehydrated from a persisted stamp is now moot — and a record outliving the work it
    /// protects parks every future save for that document behind a pill with nothing to ask.
    func testAdoptingTheServerReleasesAConflictThatIsNowMoot() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        // A server-id draft with an empty body carrying a conflict stamp — what `init`
        // rehydrates `conflicts` from.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "", updatedAt: Date(), baseline: nil,
                lastPushedMarkdown: nil, conflictServerUpdatedAt: Date(timeIntervalSince1970: 1)))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "rehydrated from the draft")

        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "released — otherwise every later save for this document is parked behind it")
    }

    /// Releasing the editor that held the *server* id must kick the funnel too, or the
    /// deferred migration waits for an unrelated foreground or reconnect.
    func testReleasingAnEditorOnTheServerIDRunsTheDeferredMigration() async {
        let log = RequestRecorder()
        stubReplayPipeline(log: log)
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        relaunched.coordinator.retainOpenEditor(documentID: serverID)
        await relaunched.coordinator.syncPendingDrafts()
        XCTAssertNotNil(relaunched.creates.create(for: local.id), "deferred while held")

        relaunched.coordinator.releaseOpenEditor(documentID: serverID)

        await waitUntil { relaunched.creates.create(for: local.id) == nil }
    }

    /// The conflict check compares **canonically**, because the local body has been through
    /// the parser and the server's has not. Without that, a formatting-only difference in the
    /// export records a conflict against a document nothing is wrong with — and the pill then
    /// parks every future save for it behind a question with no real answer.
    func testAFormattingOnlyDifferenceIsNotAConflict() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Heading\n\nBody")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Same document, spelled with trailing whitespace and an extra blank line.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Heading  \\n\\n\\nBody\\n",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        // One body answers both GETs (the cosmetic `document` fetch and `formatted-content`).
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "a formatting-only export difference is not a divergence to ask about")
    }

    /// **The conflict must survive rule 1 as well as rule 2.** A checkpointed document is met
    /// under its *server* id, so the user can have opened it, typed and had that save land
    /// before the migration runs — leaving `lastConfirmedPushMarkdown[serverID]` holding the
    /// very body the migration then records a conflict against. `enqueue` stamps that onto the
    /// draft, and rule 1 (`serverHoldsOurLastPush`) is consulted *before* rule 2, so an honest
    /// baseline is never even reached: `releaseConflictIfProven` clears the conflict and the
    /// held save overwrites them. Every other conflict test uses a relaunched coordinator,
    /// where that map is structurally empty — which is exactly why this axis was uncovered.
    func testAConflictSurvivesEvidenceOfAPushUnderTheServerID() async throws {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)

        // Relaunch so the mirror picks up the checkpoint, then — in *this* session — the user
        // meets the document under its server id and their save lands, leaving push evidence
        // on the same coordinator the migration will run on.
        let relaunched = makeEnvironment(sharing: env.defaults)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 200, headers: [:], body: Data(), error: nil)
        }
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "# Their newer text")
        await waitUntil {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == "# Their newer text"
        }

        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Their newer text",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T09:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNotNil(relaunched.coordinator.conflict(for: serverID), "the divergence is recorded")
        let draft = try XCTUnwrap(relaunched.drafts.draft(for: serverID))
        XCTAssertNil(
            draft.lastPushedMarkdown,
            "the push evidence is cleared — the offline body does not descend from that push")
        let decision = draftSyncDecision(
            baseline: draft.baseline, lastPushedMarkdown: draft.lastPushedMarkdown,
            localMarkdown: draft.markdown, draftTitle: draft.title, draftUpdatedAt: draft.updatedAt,
            serverTitle: "Notes",
            serverUpdatedAt: ISO8601DateFormatter().date(from: "2026-03-02T09:00:00Z")!,
            serverMarkdown: "# Their newer text")
        guard case .conflict = decision else {
            return XCTFail("rule 1 must not release the conflict — got \(decision)")
        }
    }

    /// Both emptiness tests are **canonical**, matching the inequality between them. Raw, a
    /// local body of `" "` is non-empty, so it skips the adopt branch and falls to the conflict
    /// — arming a "Keep my version" that PATCHes whitespace over the co-author, the exact wipe
    /// that branch exists to prevent.
    func testAWhitespaceOnlyLocalBodyAdoptsTheServerRatherThanArmingAWipe() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // Present, and whitespace-only — canonically empty but raw non-empty.
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Notes", markdown: "   \n\n  ", updatedAt: Date(),
                baseline: nil))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        // Positive first: without it, anything that stops the pass reaching the migration
        // turns the two absences green while testing nothing.
        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(relaunched.coordinator.conflict(for: serverID), "nothing to ask about")
        XCTAssertNil(relaunched.drafts.draft(for: serverID), "and no whitespace draft left to push")
    }

    /// The other direction: a server body that is raw non-empty but canonically empty must not
    /// record a conflict at all. Raw, it records one that the very next evaluation releases
    /// (rule 2's body tiebreak matches `"" == ""`) — a pill that provably self-clears.
    func testAWhitespaceOnlyServerBodyIsNotADivergence() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        env.coordinator.enqueue(documentID: local.id, title: "Notes", markdown: "# Written offline")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "  \\n\\n ",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertNil(
            relaunched.coordinator.conflict(for: serverID),
            "a canonically empty server body is not a divergence to ask about")
    }

    /// Adopting the server must also reset the state, as `resolveConflictKeepingServer` does
    /// for the same "the local side is gone" transition. Left at `.failed`, the editing surface
    /// keeps a live retry whose `saveNow` enqueues the *server's own* re-fetched body with no
    /// baseline — a full overwrite re-encoded through `MarkdownYjs`, exactly the flattening
    /// this branch refuses to perform.
    func testAdoptingTheServerClearsAFailedStateUnderTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)

        let relaunched = makeEnvironment(sharing: env.defaults)
        // A save under the server id, rejected on the merits, leaving `.failed` and an empty
        // server-id draft — the partial-migration shape the branch's comment names.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            return .init(statusCode: 400, headers: [:], body: Data(), error: nil)
        }
        relaunched.coordinator.enqueue(documentID: serverID, title: "Notes", markdown: "")
        await waitUntil {
            if case .failed = relaunched.coordinator.state(for: self.serverID) { return true }
            return false
        }

        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        if case .failed = relaunched.coordinator.state(for: serverID) {
            XCTFail("a live retry here would PATCH the co-author's own body back, re-encoded")
        }
    }

    /// The partial-migration draft's push evidence must be **carried forward** when the body
    /// comes from it. That body is not the offline one — a previous attempt already wrote it
    /// under the server id — so "the local body does not descend from that push" is false of
    /// it, and dropping the stamp raises a conflict no evidence can ever release against the
    /// user's own earlier write. Every other test builds server-id drafts with a nil stamp, so
    /// replacing `carriedPush` with `nil` outright leaves them all green.
    func testAPartiallyMigratedDraftKeepsThePushItDescendsFrom() async throws {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The partial-migration shape: local draft gone, server-id draft present — and it
        // records that its body was already pushed.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# Already pushed",
                updatedAt: Date(), baseline: nil, lastPushedMarkdown: "# Already pushed"))
        // The server holds that same pushed body, so this is our own write, not a divergence.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Already pushed",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        let draft = try XCTUnwrap(relaunched.drafts.draft(for: serverID))
        XCTAssertEqual(
            draft.lastPushedMarkdown, "# Already pushed",
            "the evidence rides along, so rule 1 can still recognise our own landed write")
    }

    /// The migration writes the body under `serverID` before removing the local draft, so a
    /// death in that window leaves it as the **only copy** — and `isPendingCreate` is keyed on
    /// the *local* id, so `runSyncPass`'s 404/403 sweep does not see it as protected. The
    /// `.notFound` start-over rescues it by moving it back; a `.forbidden` resume has no such
    /// branch and would land here, as would any pass where the record simply is not replayable
    /// this session (a foreign origin, another account, a failing `/users/me/`, an open
    /// editor — not a build block, which cannot coexist with a checkpoint). Deleting it makes
    /// the later migration build an empty document.
    func testTheSweepNeverDeletesTheOnlyCopyUnderACheckpointedServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The partial-migration window: local draft gone, body only under the server id.
        env.drafts.remove(documentID: local.id)
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# The only copy",
                updatedAt: Date(), baseline: nil))
        // Everything 403s — the resume takes the transient branch and does not rescue it.
        stubUsersMeThen(log: log) { _ in .init(statusCode: 403, headers: [:], body: Data(), error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# The only copy",
            "the sweep must not delete the body of a checkpointed record")
    }

    /// A rename made **on this device, under the server id** must survive the migration.
    /// Once checkpointed the local row is withheld, so the user meets the document under
    /// `serverID` in an ordinary list; a rename there lands and `finish` removes that draft,
    /// leaving the seed draft holding the mint title. Preferring the local title
    /// unconditionally PATCHes "Untitled document" back over their rename, silently.
    func testAMigrationDoesNotRevertARenameMadeUnderTheServerID() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        // The seed draft still holds the mint title — the local side never renamed.
        // The server has since been renamed under its own id.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Recipes", "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Recipes",
            "the server's rename is kept — the local side only ever held the mint title")
    }

    /// The `.discardServerWins` deleting line's own server-id guard. Rule 3 needs a nil
    /// baseline, which no production writer produces under a server id — but the guard states
    /// the invariant at the deleting line rather than resting on that, exactly as its twin in
    /// the 404/403 catch does.
    func testTheLaunchDiscardNeverDeletesACheckpointedServerIDDraft() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        env.creates.save(record)
        env.drafts.remove(documentID: local.id)
        // Baseline-less, and far older than the 120 s tolerance, so rule 3 answers
        // `.discardServerWins`.
        env.drafts.save(
            PendingDraft(
                documentID: serverID, title: "Notes", markdown: "# The only copy",
                updatedAt: Date(timeIntervalSince1970: 1), baseline: nil))
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes",
             "content": "# Written on the web",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        // Another account, so `runCreatePass` skips the record before it can migrate or rescue.
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            if request.url?.absoluteString.hasSuffix("users/me/") == true {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"99999999-9999-4999-8999-999999999999\"}".utf8), error: nil)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.recoverDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.markdown, "# The only copy",
            "the launch discard must not delete a checkpointed record's only copy")
    }

    /// **Both sides renamed.** A rename made *before* the POST is already the server's name,
    /// so comparing against the mint title reads it as a local rename forever — and the resume
    /// then pushes that now-stale title over the newer one made under the server id. Comparing
    /// against what the POST actually sent is what settles it.
    func testARenameMadeBeforeThePostDoesNotOutrankOneMadeAfterIt() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        // Renamed before the replay, so this is the title the POST sent.
        env.coordinator.enqueue(documentID: local.id, title: "Recipes", markdown: "# Body")
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Recipes"
        env.creates.save(record)
        // Then renamed again under the server id, which is where the user meets it.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Notes", "content": "# Body",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertNil(relaunched.creates.create(for: local.id), "the migration completed")
        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Notes",
            "the rename made after the server learned the name is the newer one")
    }

    /// The mirror cell: a rename made *after* the POST must still win. Comparing against the
    /// POSTed title must not weaken the case the discriminator was built for.
    func testARenameMadeAfterThePostStillWins() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)
        env.drafts.save(
            PendingDraft(
                documentID: local.id, title: "Renamed locally", markdown: "# Body",
                updatedAt: Date(), baseline: nil))
        // The server still holds the POSTed title — nobody renamed it there.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "# Body",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z"}
            """.utf8)
        stubUsersMeThen(log: log) { _ in .init(statusCode: 200, headers: [:], body: formatted, error: nil) }

        let relaunched = makeEnvironment(sharing: env.defaults)
        await relaunched.coordinator.syncPendingDrafts()

        XCTAssertEqual(
            relaunched.drafts.draft(for: serverID)?.title, "Renamed locally",
            "a local rename after the POST is still the newer one")
    }

    /// A save under the server id that starts **and settles inside the resume's fetch** leaves
    /// `inFlight`/`queued` nil and removes its own draft — so all three of `finishMigration`'s
    /// guards pass and the migration decides from a body the server no longer holds, pushing
    /// the older local one over content the user just saw confirmed as saved. That is the
    /// boolean this coordinator documents as insufficient; `mayPredateSave` is the instrument.
    func testAMigrationNeverActsOnABodyASaveOvertookMidFetch() async {
        let log = RequestRecorder()
        let env = makeEnvironment()
        let local = env.coordinator.createLocalDocument(
            title: "Untitled document", parentID: nil, ownerUserID: user)
        var record = env.creates.create(for: local.id)!
        record.syncedServerID = serverID
        record.postedTitle = "Untitled document"
        env.creates.save(record)

        let relaunched = makeEnvironment(sharing: env.defaults)
        let coordinator = relaunched.coordinator
        // The resume's `formatted-content` GET is held open; everything else answers at once.
        let formatted = Data(
            """
            {"id": "\(serverID.uuidString.lowercased())", "title": "Untitled document",
             "content": "",
             "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-01T12:00:00Z"}
            """.utf8)
        MockURLProtocol.stubHandler = { request in
            log.record(request)
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("users/me/") {
                return .init(
                    statusCode: 200, headers: [:],
                    body: Data("{\"id\": \"11111111-1111-4111-8111-111111111111\"}".utf8), error: nil)
            }
            if url.contains("formatted-content") {
                return .init(statusCode: 200, headers: [:], body: formatted, error: nil, delay: 0.6)
            }
            return .init(statusCode: 200, headers: [:], body: formatted, error: nil)
        }

        let pass = Task { await coordinator.syncPendingDrafts() }
        // Inside that window the user types under the server id and the save lands.
        await waitUntil { log.count(ofMethod: "GET", urlContaining: "formatted-content") == 1 }
        coordinator.enqueue(documentID: serverID, title: "Untitled document", markdown: "# World")
        await waitUntil { coordinator.lastConfirmedPush(documentID: self.serverID) == "# World" }
        await pass.value

        XCTAssertNotNil(
            relaunched.creates.create(for: local.id),
            "the migration bailed rather than deciding from a body the save had overtaken")
        await waitAndConfirmNever {
            relaunched.coordinator.lastConfirmedPush(documentID: self.serverID) == ""
        }
    }
}
