import WebKit
import XCTest

@testable import Schrift

// Cookie fixtures use obviously fake values; no test prints cookie values.
@MainActor
final class SessionStoreIdentitySideEffectsTests: SessionStoreTestCase {
    func testImageCacheNamespaceSurvivesRelaunchButRotatesAtCookieHandoverAndSignIn() throws {
        let keychain = FakeKeychainStore()
        let cookies = FakeCookieStorage()
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookies)
        XCTAssertNil(first.imageCacheSessionID)
        try first.signIn(serverURL: serverURL)
        let initial = try XCTUnwrap(first.imageCacheSessionID)
        let cold = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookies)
        XCTAssertEqual(cold.imageCacheSessionID, initial)
        first.noteSessionExpired()
        first.cancelReauthentication()
        XCTAssertEqual(first.imageCacheSessionID, initial)
        first.noteSessionCookiesReplaced()
        XCTAssertNotEqual(first.imageCacheSessionID, initial)
        let handedOver = first.imageCacheSessionID
        try first.signIn(serverURL: serverURL)
        XCTAssertNotEqual(first.imageCacheSessionID, handedOver)
        try first.signOut()
        XCTAssertNil(first.imageCacheSessionID)
    }

    /// PR13a review V1: the thread-safe clock moves with every sign-in
    /// generation (cookie handover, sign-in, sign-out), so a request bound to
    /// an earlier one is never sent.
    func testTheGenerationClockMovesAtEveryAccountChange() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        for change in ["handover", "signIn", "signOut"] {
            let isCurrent = store.generationClock.isCurrent()
            XCTAssertTrue(isCurrent(), change)
            switch change {
            case "handover": store.noteSessionCookiesReplaced()
            case "signIn": try store.signIn(serverURL: serverURL)
            default: try store.signOut()
            }
            XCTAssertFalse(isCurrent(), change)
        }
    }

    /// PR13a review W1: a web login stops every request bound to the previous
    /// session before it writes new cookies, and nothing bound while it
    /// switches passes either, until the handover is noted.
    func testRequestsStopBeforeAWebLoginWritesItsCookies() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        let before = store.generationClock.isCurrent()
        store.noteSessionCookiesWillChange()
        XCTAssertFalse(before())
        let during = store.generationClock.isCurrent()
        XCTAssertFalse(during(), "bound while switching")
        store.noteSessionCookiesReplaced()
        XCTAssertFalse(during())
        XCTAssertTrue(store.generationClock.isCurrent()(), "the new session's requests pass")
    }

    /// Sign-in is the moment a possibly-different account takes over, and the cached profile
    /// is shown *before* any fetch — so a kept entry would put the previous user's name and
    /// email on the new user's Profile screen, indefinitely if they are offline.
    func testSignInForgetsThePreviousAccountsCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())

        try store.signIn(serverURL: serverURL)

        XCTAssertNil(cache.user)
    }

    /// Unlike pending-create records — which survive because they may be the only copy of a
    /// document — this is re-fetchable server data about the session that just ended.
    func testSignOutForgetsTheCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        try store.signOut()

        XCTAssertNil(cache.user)
    }

    /// The twin of `testExpiringASessionKeepsTheAccountId`, and the same contract: a dismissed
    /// re-login sheet keeps showing what it already showed, so a transient 401 must not empty
    /// the account row.
    func testExpiringASessionKeepsTheCachedProfile() throws {
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        store.noteSessionExpired()

        XCTAssertEqual(cache.user?.email, "ada@example.org")
    }

    /// Clearing the store is only half of session-scoping the account row: `ProfileViewModel`
    /// is `@State` in `MainTabView`, which survives a re-login, so its in-memory copy needs a
    /// reason to be re-read. This counter is that reason — `ProfileScreen` keys its `.task` on
    /// it, so answering the sheet as a different account re-runs `load()` instead of leaving
    /// the previous account's email on screen until the user happens to switch tabs.
    func testSignInAdvancesTheSignInGenerationSoOpenScreensReload() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        let before = store.signInGeneration

        try store.signIn(serverURL: serverURL)

        XCTAssertEqual(store.signInGeneration, before + 1)
    }

    /// Signing out changes the session too, so a mounted native editor closes instead of
    /// typing on under a forgotten identity.
    func testSignOutAdvancesTheSignInGeneration() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let afterSignIn = store.signInGeneration

        try store.signOut()

        XCTAssertEqual(store.signInGeneration, afterSignIn + 1)
    }

    /// It marks a *change of session*, not a failure of one — a dismissed sheet must not
    /// re-run every screen's load.
    func testExpiringASessionDoesNotAdvanceTheSignInGeneration() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let afterSignIn = store.signInGeneration

        store.noteSessionExpired()
        store.cancelReauthentication()

        XCTAssertEqual(store.signInGeneration, afterSignIn)
    }

    /// The stale-account disclosure. Signing in — which a completed re-login sheet also does
    /// — is the moment a possibly-different account takes over, so a kept id would list the
    /// previous user's unsynced documents to the new one, who could type into them, with the
    /// edits eventually POSTed into the first user's account.
    func testSigningInForgetsWhoWasSignedInBefore() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())

        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)

        XCTAssertNil(signedIn.userID, "fails closed until the server says whose session this is")
    }

    /// And a mere expiry does **not** clear it: the user may simply have hit a transient 401,
    /// or dismissed the sheet — whose contract is that cached data keeps showing. Emptying
    /// their local section there would be silent collateral with no safety gain, since the
    /// account has not changed until someone signs in.
    func testExpiringASessionKeepsTheAccountId() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        store.noteSessionExpired()

        XCTAssertNotNil(signedIn.userID)
    }

    func testSigningOutForgetsTheAccountId() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: URL(string: "https://docs.example.org")!)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

        try store.signOut()

        XCTAssertNil(signedIn.userID)
    }

    /// The window `signIn` alone cannot close. `WebLoginView` syncs the freshly authenticated
    /// cookies into the shared storage *before* anything confirms them, so by the time a login
    /// sheet reports back the session may already belong to somebody else — while `signIn`, the
    /// only thing that forgets the previous account, runs solely if the confirming `/users/me/`
    /// succeeds. A blip on that one request therefore left B's cookies live under A's identity.
    func testCookiesHandedOverByALoginForgetTheAccountTheyReplaced() throws {
        let signedIn = SignedInUserStore(userDefaults: userDefaults)
        let cache = CurrentUserCacheStore(userDefaults: userDefaults)
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        signedIn.remember(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        cache.remember(
            CurrentUser(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, email: "ada@example.org"))

        store.noteSessionCookiesReplaced()

        XCTAssertNil(signedIn.userID, "fails closed until the server says whose session this is")
        XCTAssertNil(cache.user, "the previous account's name and email must not outlive its cookies")
    }

    /// Forgetting the value is half of it — `ProfileViewModel` is `@State` in `MainTabView`,
    /// which the sheet is presented *over*, so its in-memory copy needs a reason to re-read.
    /// Without the bump the row keeps showing the previous account from memory even though the
    /// store behind it is empty.
    func testCookiesHandedOverByALoginAdvanceTheSignInGenerationSoOpenScreensReload() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let afterSignIn = store.signInGeneration

        store.noteSessionCookiesReplaced()

        XCTAssertEqual(store.signInGeneration, afterSignIn + 1)
    }

    func testAccountTransitionsClearAttachmentCacheAndMediaDropStaging() throws {
        var attachmentClears = 0
        var stagingClears = 0
        var playbackEnds = 0
        let store = SessionStore(
            userDefaults: userDefaults,
            keychain: FakeKeychainStore(),
            cookieStorage: FakeCookieStorage(),
            clearAttachmentCache: { attachmentClears += 1 },
            clearMediaDropStaging: { stagingClears += 1 },
            endMediaPlayback: { playbackEnds += 1 })

        try store.signIn(serverURL: serverURL)
        XCTAssertEqual(attachmentClears, 1)
        XCTAssertEqual(stagingClears, 1)
        XCTAssertEqual(playbackEnds, 1)

        store.noteSessionExpired()
        store.cancelReauthentication()
        XCTAssertEqual(attachmentClears, 1, "mere expiry must keep caches")
        XCTAssertEqual(stagingClears, 1)
        XCTAssertEqual(playbackEnds, 1)

        store.noteSessionCookiesReplaced()
        XCTAssertEqual(attachmentClears, 2)
        XCTAssertEqual(stagingClears, 2)
        XCTAssertEqual(playbackEnds, 2, "an account switch stops the player")

        try store.signOut()
        XCTAssertEqual(attachmentClears, 3)
        XCTAssertEqual(stagingClears, 3)
        XCTAssertEqual(playbackEnds, 3, "sign-out stops the player")
    }

    /// The login web view's page cache goes with the account; a mere expiry keeps it.
    func testAccountTransitionsClearTheWebLoginCache() throws {
        var webCacheClears = 0
        let keychain = FakeKeychainStore()
        let store = SessionStore(
            userDefaults: userDefaults,
            keychain: keychain,
            cookieStorage: FakeCookieStorage(),
            clearWebCache: { webCacheClears += 1 })

        try store.signIn(serverURL: serverURL)
        XCTAssertEqual(webCacheClears, 1)
        store.noteSessionExpired()
        store.cancelReauthentication()
        XCTAssertEqual(webCacheClears, 1, "mere expiry must keep caches")
        store.noteSessionCookiesReplaced()
        XCTAssertEqual(webCacheClears, 2)
        // A relaunch before the handover is confirmed clears it again, like the attachment cache.
        var coldClears = 0
        _ = SessionStore(
            userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage(),
            clearWebCache: { coldClears += 1 })
        XCTAssertEqual(coldClears, 1)
        try store.signOut()
        XCTAssertEqual(webCacheClears, 3)
    }

    /// Single sign-on (and the silent re-login) needs the web view's cookies to survive the clear.
    func testTheWebLoginCacheClearKeepsCookies() {
        XCTAssertEqual(webLoginCacheDataTypes, [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
        XCTAssertFalse(webLoginCacheDataTypes.contains(WKWebsiteDataTypeCookies))
    }

    /// No re-login starts or escalates to the sheet under a sign-out that is draining saves.
    func testNoReauthenticationStartsOrEscalatesWhileSigningOut() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        store.beginSignOut()
        store.noteSessionExpired()
        XCTAssertFalse(store.needsReauthentication, "a 401 during the drain starts nothing")

        store.endSignOut()
        store.noteSessionExpired()
        XCTAssertTrue(store.isSilentlyReauthenticating)
        store.beginSignOut()
        store.escalateReauthentication(attempt: store.reauthenticationAttempt)
        XCTAssertFalse(store.isReauthenticationInteractive, "no sheet over a sign-out")
    }

    /// Sign-out clears everything the login web view keeps, cookies too; a re-login clears its
    /// site data (not cookies) unless it is provably the same account;
    /// a silent re-login by the same account and a first sign-in clear nothing.
    func testWebSiteDataIsClearedAtSignOutAndOnAnAccountChange() throws {
        let accountA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let accountB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        var clears: [Bool] = []
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage(),
            clearWebSiteData: { clears.append($0) })
        XCTAssertEqual(clears, [], "constructing the store clears nothing; SchriftApp does at launch")

        store.noteSessionCookiesReplaced()
        try store.signIn(serverURL: serverURL, userID: accountA)
        XCTAssertEqual(clears, [], "a first sign-in")
        store.noteSessionCookiesReplaced()
        try store.signIn(serverURL: serverURL, userID: accountA)
        XCTAssertEqual(clears, [], "the same account re-logging in keeps single sign-on and its site data")
        store.noteSessionCookiesReplaced()
        try store.signIn(serverURL: serverURL, userID: accountB)
        XCTAssertEqual(clears, [false], "an account change: site data, not cookies")
        store.noteSessionCookiesReplaced()
        try store.signIn(serverURL: serverURL, userID: nil)
        XCTAssertEqual(clears, [false, false], "an account nobody can name counts as a change")
        try store.signOut()
        XCTAssertEqual(clears, [false, false, true], "sign-out: everything, cookies included")
        store.noteSessionCookiesReplaced()
        try store.signIn(serverURL: serverURL, userID: accountB)
        XCTAssertEqual(clears, [false, false, true], "signing in after a sign-out")
    }

    /// Another account's web login in between — confirmed or not, even across a relaunch — means
    /// the same account signing in again is no proof the site data is still its own.
    func testAnUnconfirmedLoginInBetweenStillClearsTheSiteData() throws {
        let accountA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        var clears: [Bool] = []
        let keychain = FakeKeychainStore()
        let first = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage())
        first.noteSessionCookiesReplaced()
        try first.signIn(serverURL: serverURL, userID: accountA)
        first.noteSessionCookiesReplaced()  // another account's login, never confirmed

        let relaunched = SessionStore(
            userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage(),
            clearWebSiteData: { clears.append($0) })
        relaunched.noteSessionCookiesReplaced()
        try relaunched.signIn(serverURL: serverURL, userID: accountA)

        XCTAssertEqual(clears, [false])
    }

    /// A stale login landing after the sign-out undoes what it wrote, in both cookie stores.
    func testAStaleLoginAfterTheSignOutClearsEverythingAgain() throws {
        var clears: [Bool] = []
        let cookies = FakeCookieStorage()
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: cookies,
            clearWebSiteData: { clears.append($0) })
        try store.signIn(serverURL: serverURL)
        try store.signOut()
        clears = []
        cookies.setCookie(
            HTTPCookie(properties: [.domain: "idp.example.org", .path: "/", .name: "idp_session", .value: "fake"])!)

        store.discardStaleLoginCookies()

        XCTAssertEqual(clears, [true])
        XCTAssertEqual(cookies.storedCookies, [])
    }

    /// Starting a sign-out unmounts a re-login in progress, so none answers the IdP mid-wipe.
    func testBeginningASignOutEndsAReauthenticationInProgress() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        store.noteSessionExpired()
        XCTAssertTrue(store.needsReauthentication)

        store.beginSignOut()

        XCTAssertFalse(store.needsReauthentication)
    }

    /// A launch that could not read the Keychain shows Connect without a sign-out having run;
    /// another account signing in there still drops the previous one's site data.
    func testASignInAfterAnUnreadableLaunchStillClearsAnotherAccountsSiteData() throws {
        let accountB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        // The account before the locked launch: a named one, and one nobody could name.
        for previous in [UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, nil] {
            userDefaults.removePersistentDomain(forName: suiteName)
            let keychain = FakeKeychainStore()
            let first = SessionStore(
                userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage())
            first.noteSessionCookiesReplaced()
            try first.signIn(serverURL: serverURL, userID: previous)
            keychain.failingLoadKeys = ["dev.llun.Schrift.isAuthenticated"]
            var clears: [Bool] = []
            let locked = SessionStore(
                userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage(),
                clearWebSiteData: { clears.append($0) })
            XCTAssertFalse(locked.isAuthenticated)
            XCTAssertFalse(SessionStore.hasNoSignInMarker(keychain: keychain), "a failed read is not a sign-out")
            keychain.failingLoadKeys = []

            locked.noteSessionCookiesReplaced()
            try locked.signIn(serverURL: serverURL, userID: accountB)

            XCTAssertEqual(clears, [false], "\(String(describing: previous))")
        }
    }

    /// Signed in on a build that kept no confirmed record, then a launch that cannot read the
    /// Keychain: the next sign-in on Connect still drops the web view's site data.
    func testASignInAfterAnUnreadableLaunchWithNoRecordStillClears() throws {
        let keychain = FakeKeychainStore()
        try keychain.save(Data([1]), forKey: "dev.llun.Schrift.isAuthenticated")
        keychain.failingLoadKeys = ["dev.llun.Schrift.isAuthenticated"]
        var clears: [Bool] = []
        let locked = SessionStore(
            userDefaults: userDefaults, keychain: keychain, cookieStorage: FakeCookieStorage(),
            clearWebSiteData: { clears.append($0) })
        keychain.failingLoadKeys = []

        locked.noteSessionCookiesReplaced()
        try locked.signIn(serverURL: serverURL, userID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)

        XCTAssertEqual(clears, [false])
    }

    /// A sign-out whose marker delete fails still clears the cookies and their snapshot, so a
    /// relaunch cannot restore the session without a password.
    func testAFailedMarkerDeleteAtSignOutLeavesNoSessionToRestore() throws {
        let keychain = FakeKeychainStore()
        let cookies = FakeCookieStorage()
        let store = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: cookies)
        cookies.setCookie(
            HTTPCookie(properties: [.domain: "docs.llun.dev", .path: "/", .name: "docs_sessionid", .value: "fake"])!)
        try store.signIn(serverURL: serverURL)
        keychain.failingDeleteKeys = ["dev.llun.Schrift.isAuthenticated"]

        XCTAssertThrowsError(try store.signOut())

        XCTAssertEqual(cookies.storedCookies, [])
        let relaunchedCookies = FakeCookieStorage()
        _ = SessionStore(userDefaults: userDefaults, keychain: keychain, cookieStorage: relaunchedCookies)
        XCTAssertEqual(relaunchedCookies.storedCookies, [], "nothing to restore")
    }

    func testOnlyAMissingMarkerCountsAsSignedOutAtLaunch() throws {
        let keychain = FakeKeychainStore()
        XCTAssertTrue(SessionStore.hasNoSignInMarker(keychain: keychain))
        try keychain.save(Data([1]), forKey: "dev.llun.Schrift.isAuthenticated")
        XCTAssertFalse(SessionStore.hasNoSignInMarker(keychain: keychain))
    }

    func testTheSiteDataClearKeepsCookiesOnlyOnAnAccountChange() {
        XCTAssertFalse(webLoginSiteDataTypes(includingCookies: false).contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(webLoginSiteDataTypes(includingCookies: true).contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(
            webLoginSiteDataTypes(includingCookies: false).isSuperset(of: [
                WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeDiskCache,
            ]))
    }

    /// The default wiring: sign-out deletes a media preview's staged copy.
    func testSignOutDeletesStagedMediaPreviews() throws {
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage())
        try store.signIn(serverURL: serverURL)
        let staged = try XCTUnwrap(NativeMediaPresenter.stage(Data([1, 2, 3]), fileExtension: "png"))

        try store.signOut()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: NativeMediaPresenter.stagingDirectory.path))
    }

    func testRelaunchAfterUnconfirmedCookieHandoverClearsAttachmentCache() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreS2b-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDir) }

        let keychain = FakeKeychainStore()
        let cookies = FakeCookieStorage()
        let store = SessionStore(
            userDefaults: userDefaults,
            keychain: keychain,
            cookieStorage: cookies,
            clearAttachmentCache: { AttachmentCacheStore(directory: cacheDir).removeAll() })
        try store.signIn(serverURL: serverURL)

        let docID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let fileID = UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")!
        let display = try XCTUnwrap(
            parseAttachmentLink(
                "[video](\(serverURL.absoluteString)/media/\(docID.uuidString.lowercased())/attachments/\(fileID.uuidString.lowercased()).mp4)",
                serverOrigin: serverURL.absoluteString))

        // Confirmed session relaunch preserves offline attachment cache.
        let confirmedCache = AttachmentCacheStore(directory: cacheDir)
        XCTAssertNotNil(
            confirmedCache.store(Data("account-a".utf8), for: display, ifGeneration: confirmedCache.generation))
        let confirmedRelaunch = SessionStore(
            userDefaults: userDefaults,
            keychain: keychain,
            cookieStorage: cookies,
            clearAttachmentCache: { AttachmentCacheStore(directory: cacheDir).removeAll() })
        XCTAssertNotNil(confirmedRelaunch.imageCacheSessionID)
        XCTAssertNotNil(AttachmentCacheStore(directory: cacheDir).cachedFileURL(for: display))

        // Unconfirmed cookie handover drops the persisted session key; B writes to AttachmentCacheStore before relaunch.
        confirmedRelaunch.noteSessionCookiesReplaced()
        let unconfirmedCache = AttachmentCacheStore(directory: cacheDir)
        XCTAssertNotNil(
            unconfirmedCache.store(
                Data("account-b-secret".utf8), for: display, ifGeneration: unconfirmedCache.generation))
        XCTAssertNotNil(unconfirmedCache.cachedFileURL(for: display))

        // Relaunch restores A's cookies and mints a new session key; AttachmentCacheStore MUST be cleared.
        var clearCount = 0
        let relaunched = SessionStore(
            userDefaults: userDefaults,
            keychain: keychain,
            cookieStorage: cookies,
            clearAttachmentCache: {
                clearCount += 1
                AttachmentCacheStore(directory: cacheDir).removeAll()
            })
        XCTAssertEqual(clearCount, 1)
        XCTAssertNotNil(relaunched.imageCacheSessionID)
        XCTAssertNil(
            AttachmentCacheStore(directory: cacheDir).cachedFileURL(for: display),
            "relaunch after unconfirmed handover must wipe Account B's unscoped attachment cache")
    }

    /// The attachment cache's file names carry no account, so a download still on the wire at sign-out or at
    /// an account switch must not land in the cache the session change just cleared.
    func testAnAttachmentDownloadInFlightAcrossAnAccountChangeIsNotCached() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreAttachmentRace-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDir) }
        addTeardownBlock { MockURLProtocol.reset() }
        let display = try XCTUnwrap(
            parseAttachmentLink(
                "[Report.pdf](\(serverURL.absoluteString)/media/11111111-2222-4333-8444-555555555555/attachments/"
                    + "66666666-7777-4888-8999-aaaaaaaaaaaa.pdf)",
                serverOrigin: serverURL.absoluteString))
        for change in ["handover", "signOut"] {
            MockURLProtocol.reset()
            let store = SessionStore(
                userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage(),
                clearAttachmentCache: { AttachmentCacheStore(directory: cacheDir).removeAll() })
            try store.signIn(serverURL: serverURL)
            let gate = MockURLProtocol.ResponseGate()
            MockURLProtocol.stubHandler = { _ in
                .init(statusCode: 200, headers: [:], body: Data("account-a".utf8), error: nil, releasedBy: gate)
            }
            let loader = AttachmentLoader(
                client: DocsAPIClient(
                    baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                    session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
                serverOrigin: serverURL.absoluteString, cache: AttachmentCacheStore(directory: cacheDir))
            let load = Task { await loader.loadIfNeeded(display) }
            await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }

            if change == "handover" { store.noteSessionCookiesReplaced() } else { try store.signOut() }
            gate.open()
            await load.value

            XCTAssertEqual(loader.state(for: display), .failed, change)
            XCTAssertNil(AttachmentCacheStore(directory: cacheDir).cachedFileURL(for: display), change)
        }
    }

    /// A silent same-account re-login clears the attachment cache at once; a download started after it must
    /// still land when a video scrolls in later and the poster loader first notices the new scope.
    func testAPosterLoaderSeeingTheNewScopeDoesNotFailADownloadStartedAfterTheReLogin() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStorePosterScope-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDir) }
        addTeardownBlock { MockURLProtocol.reset() }
        let origin = serverURL.absoluteString
        let display = try XCTUnwrap(
            parseAttachmentLink(
                "[Report.pdf](\(origin)/media/11111111-2222-4333-8444-555555555555/attachments/"
                    + "66666666-7777-4888-8999-aaaaaaaaaaaa.pdf)",
                serverOrigin: origin))
        let store = SessionStore(
            userDefaults: userDefaults, keychain: FakeKeychainStore(), cookieStorage: FakeCookieStorage(),
            clearAttachmentCache: { AttachmentCacheStore(directory: cacheDir).removeAll() })
        try store.signIn(serverURL: serverURL)
        let posters = VideoPosterLoader(
            cache: ImageCacheStore(directory: cacheDir.appendingPathComponent("posters", isDirectory: true)),
            attachmentCache: AttachmentCacheStore(directory: cacheDir),
            fetch: { _, _ in throw URLError(.notConnectedToInternet) },
            cookieProvider: { _ in [] },
            scopeProvider: { store.imageCacheScope.map { ImageCacheScope(serverOrigin: origin, sessionID: $0) } },
            scratchDirectory: cacheDir.appendingPathComponent("scratch", isDirectory: true))
        let video = try XCTUnwrap(URL(string: "\(origin)/media/clip.mp4"))
        _ = posters.poster(for: video)
        let previous = AttachmentCacheStore(directory: cacheDir)
        XCTAssertNotNil(previous.store(Data("before".utf8), for: display, ifGeneration: previous.generation))

        try store.signIn(serverURL: serverURL)
        XCTAssertNil(
            AttachmentCacheStore(directory: cacheDir).cachedFileURL(for: display),
            "SessionStore clears the attachment cache synchronously at the account change")

        let gate = MockURLProtocol.ResponseGate()
        MockURLProtocol.stubHandler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("after".utf8), error: nil, releasedBy: gate)
        }
        let loader = AttachmentLoader(
            client: DocsAPIClient(
                baseURL: serverURL.appendingPathComponent("api/v1.0/"),
                session: MockURLProtocol.makeSession(), cookieProvider: { [] }),
            serverOrigin: origin, cache: AttachmentCacheStore(directory: cacheDir))
        let load = Task { await loader.loadIfNeeded(display) }
        await waitUntil { MockURLProtocol.deferredDeliveryCount == 1 }
        _ = posters.poster(for: video)
        gate.open()
        await load.value

        guard case .cached(let url) = loader.state(for: display) else {
            return XCTFail("Expected .cached, got \(String(describing: loader.state(for: display)))")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("after".utf8))
    }

    func testDiagnosticsStoreResetsOnEveryAccountChange() throws {
        var resetCount = 0
        let store = SessionStore(
            userDefaults: userDefaults,
            keychain: FakeKeychainStore(),
            cookieStorage: FakeCookieStorage(),
            clearDiagnostics: { resetCount += 1 })

        store.noteSessionCookiesReplaced()
        XCTAssertEqual(resetCount, 1)

        try store.signIn(serverURL: serverURL, userID: UUID())
        XCTAssertEqual(resetCount, 2)

        try store.signOut()
        XCTAssertEqual(resetCount, 3)
    }
}
