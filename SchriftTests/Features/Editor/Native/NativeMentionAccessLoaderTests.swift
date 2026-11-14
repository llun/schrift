import Foundation
import XCTest

@testable import Schrift

@MainActor
final class NativeMentionAccessLoaderTests: XCTestCase {
    private let origin = "https://docs.example.org"
    private let docID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let userA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let userB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let editorUserID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let readerUserID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let downgradedUserID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private var client: DocsAPIClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        client = DocsAPIClient(
            baseURL: URL(string: "\(origin)/api/v1.0/")!,
            session: MockURLProtocol.makeSession(),
            cookieProvider: { [] })
    }

    override func tearDown() {
        MockURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    private func makeScope(
        origin: String? = nil,
        owner: UUID? = nil,
        documentID: UUID? = nil,
        generation: Int = 0
    ) -> NativeMentionAccessLoader.Scope {
        NativeMentionAccessLoader.Scope(
            serverOrigin: origin ?? self.origin,
            ownerUserID: owner,
            documentID: documentID ?? self.docID,
            signInGeneration: generation)
    }

    private func triggerKey(anchor: Int = 0) -> InlineTriggerKey {
        InlineTriggerKey(blockID: "b1", kind: .mention, anchor: anchor)
    }

    private func accessesPayloadJSON() -> Data {
        let json = """
            [
              {
                "id": "aaaaaaaa-0000-4000-8000-000000000001",
                "user": {
                  "id": "\(editorUserID.uuidString.lowercased())",
                  "email": "ada@example.org",
                  "full_name": "Ada Lovelace",
                  "short_name": "Ada"
                },
                "team": null,
                "role": "editor",
                "max_role": "editor",
                "abilities": {}
              },
              {
                "id": "aaaaaaaa-0000-4000-8000-000000000002",
                "user": {
                  "id": "\(readerUserID.uuidString.lowercased())",
                  "email": "reader@example.org",
                  "full_name": "Reader User",
                  "short_name": "Reader"
                },
                "team": null,
                "role": "reader",
                "max_role": "reader",
                "abilities": {}
              },
              {
                "id": "aaaaaaaa-0000-4000-8000-000000000003",
                "user": {
                  "id": "\(downgradedUserID.uuidString.lowercased())",
                  "email": "downgraded@example.org",
                  "full_name": "Downgraded Reader",
                  "short_name": "Down"
                },
                "team": null,
                "role": "editor",
                "max_role": "reader",
                "abilities": {}
              }
            ]
            """
        return Data(json.utf8)
    }

    func testGatingSuppressesFetchWhenDisabledLocalSignedOutOrOffline() async {
        let recorder = RequestRecorder()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(
                statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8), error: nil)
        }

        let noMention = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA), canMention: false, isLocalDocument: false, isOffline: false)
        noMention.requestMentions(for: triggerKey())
        XCTAssertEqual(noMention.state, .idle)

        let localDoc = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA), canMention: true, isLocalDocument: true, isOffline: false)
        localDoc.requestMentions(for: triggerKey())
        XCTAssertEqual(localDoc.state, .idle)

        let signedOut = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: nil), canMention: true, isLocalDocument: false, isOffline: false)
        signedOut.requestMentions(for: triggerKey())
        XCTAssertEqual(signedOut.state, .idle)

        let offline = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA), canMention: true, isLocalDocument: false, isOffline: true)
        offline.requestMentions(for: triggerKey())
        XCTAssertEqual(offline.state, .idle)

        await waitAndConfirmNever { recorder.count(ofMethod: "GET") > 0 }
    }

    func testOnlineFetchCoalescesConcurrentRequestsFiltersReadersAndSurvivesGoingOffline() async {
        let recorder = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        let payload = accessesPayloadJSON()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            return .init(
                statusCode: 200, headers: ["Content-Type": "application/json"], body: payload, error: nil,
                releasedBy: gate)
        }

        let loader = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA), canMention: true, isLocalDocument: false, isOffline: false)

        loader.requestMentions(for: triggerKey(anchor: 0))
        XCTAssertEqual(loader.state, .loading)

        // Subsequent keystrokes / re-requests while in flight reuse the single Task.
        loader.requestMentions(for: triggerKey(anchor: 0))
        loader.requestMentions(for: triggerKey(anchor: 2))
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        XCTAssertEqual(
            recorder.count(ofMethod: "GET", urlContaining: "/documents/\(docID.uuidString.lowercased())/accesses/"), 1)

        gate.open()

        let expectedCandidate = MentionCandidate(
            userID: editorUserID.uuidString.lowercased(),
            fullName: "Ada Lovelace",
            shortName: "Ada",
            email: "ada@example.org")
        await waitUntil { loader.state == .loaded([expectedCandidate]) }

        // Going offline later in the same open session keeps the in-memory candidates.
        loader.update(
            scope: makeScope(owner: userA), canMention: true, isLocalDocument: false, isOffline: true)
        XCTAssertEqual(loader.state, .loaded([expectedCandidate]))
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 1)
    }

    func testSilentFailureScopesToAnchorAndRetriesOnFreshOpener() async {
        let recorder = RequestRecorder()
        let counter = Counter()
        let payload = accessesPayloadJSON()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            let attempt = counter.next()
            if attempt == 1 {
                return .init(statusCode: 403, headers: [:], body: Data(), error: nil)
            }
            if attempt == 2 {
                return .init(statusCode: 500, headers: [:], body: Data(), error: nil)
            }
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: payload, error: nil)
        }

        let loader = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA), canMention: true, isLocalDocument: false, isOffline: false)

        let firstKey = triggerKey(anchor: 0)
        loader.requestMentions(for: firstKey)
        await waitUntil { loader.state == .failed(firstKey) }

        // Same opener stays silently failed without re-fetching.
        loader.requestMentions(for: firstKey)
        await waitAndConfirmNever { recorder.count(ofMethod: "GET") > 1 }

        // A fresh opener retries cleanly (500 -> .failed(secondKey)).
        let secondKey = triggerKey(anchor: 5)
        loader.requestMentions(for: secondKey)
        await waitUntil { loader.state == .failed(secondKey) }
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)

        // Clearing failure allows retry on the next trigger and succeeds.
        loader.clearFailure()
        XCTAssertEqual(loader.state, .idle)
        loader.requestMentions(for: secondKey)
        await waitUntil {
            if case .loaded(let candidates) = loader.state { return candidates.count == 1 }
            return false
        }
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 3)
    }

    func testSignInGenerationAndScopeChangesCancelInFlightAndResetLoadedState() async {
        let recorder = RequestRecorder()
        let gate = MockURLProtocol.ResponseGate()
        let payload = accessesPayloadJSON()
        let attempt = Counter()
        MockURLProtocol.stubHandler = { request in
            recorder.record(request)
            if attempt.next() == 1 {
                return .init(
                    statusCode: 200, headers: ["Content-Type": "application/json"], body: payload, error: nil,
                    releasedBy: gate)
            }
            return .init(
                statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8), error: nil)
        }

        let loader = NativeMentionAccessLoader(
            client: client, scope: makeScope(owner: userA, generation: 1),
            canMention: true, isLocalDocument: false, isOffline: false)

        // Bump signInGeneration while a request is in flight: late response must be dropped.
        loader.requestMentions(for: triggerKey())
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

        loader.update(
            scope: makeScope(owner: userB, generation: 2),
            canMention: true, isLocalDocument: false, isOffline: false)
        XCTAssertEqual(loader.state, .idle)

        gate.open()
        await waitAndConfirmNever { loader.state != .idle }

        // Next request for account B runs fresh and loads account B's empty roster.
        loader.requestMentions(for: triggerKey())
        await waitUntil { loader.state == .loaded([]) }
        XCTAssertEqual(recorder.count(ofMethod: "GET"), 2)

        // Changing documentID, serverOrigin, or disabling canMention resets cached state.
        loader.update(
            scope: makeScope(
                owner: userB, documentID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!, generation: 2),
            canMention: true, isLocalDocument: false, isOffline: false)
        XCTAssertEqual(loader.state, .idle)
    }
}
