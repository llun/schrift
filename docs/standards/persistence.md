# Persistence (`*Store` types)

- **Startup store reconstruction must settle without preferences writes.** SwiftUI
  may evaluate `@State` initializers again while constructing a view, even when it
  retains the original object. Writing an unchanged UserDefaults value or removing
  an absent key can invalidate `@AppStorage`, rebuild the view, and repeat until
  the scene-create watchdog kills launch. Guard one-time migrations on missing or
  invalid data; preserve existing valid values without writing them.
  `LaunchPreferencesTests` covers the session namespace, legacy list cleanup, and
  a bounded SwiftUI/AppStorage reproduction of the render loop.
- UserDefaults-backed stores key off `private static let` reverse-DNS constants
  (`dev.llun.Schrift.*`), take `userDefaults: UserDefaults = .standard` as the
  first init parameter, and use `try?` returning a safe empty default — they
  never throw to callers. Extract dedup/recency/limit logic into a top-level free
  function so it is testable without UserDefaults. Stores whose entries carry
  recency semantics (drafts' `updatedAt`, caches' `syncedAt`) encode dates with
  `.millisecondsSince1970`, never `.iso8601` — ISO-8601 truncates to whole
  seconds, making draft-vs-save races and eviction tie-breaks arbitrary
  (`DocumentCacheStore`, which carries no recency data, is the one `.iso8601`
  store).
- **A one-blob store that is read often memoizes its decode on the blob's bytes
  (`DecodedBlobMemo`), never on its own state.** `PendingDraftStore` and
  `DocumentChildrenCacheStore` share one static memo each: every read still fetches
  the current `Data` and reuses the decoded value only when the bytes are identical,
  so several instances over `.standard`, raw test writes and `removePersistentDomain`
  can never be served a stale copy, and an undecodable blob stays memoized as
  undecodable (`holdsUnreadableData` unchanged). Writes do **not** seed the memo with
  the dictionary they encoded: the `.millisecondsSince1970` round trip is not
  bit-exact, so readers must only ever see what the decoder produced. Same keys, same
  format — no migration.
- **List-metadata caches** (`DocumentCacheStore`: pinned + recent (the
  unfiltered Home feed) + shared lists; `DocumentChildrenCacheStore`: sub-page
  lists keyed by parent document) make every document list instant and
  offline-readable, following
  the content cache's pattern: the VM seeds **synchronously** (init or the
  pre-await phase of `load()`), a loading placeholder may show only when there
  is **no local entry** — list loads return Optional (`loadPinnedDocuments()`
  is the `[]` exception), and nil (never cached) is distinct from a cached
  empty list — revalidation is silent and latest-wins (generation counter),
  transient failures keep cached rows with no error — loudness is keyed to
  **cache existence for the exact list being loaded** (pull-to-refresh is the
  always-loud path — except `.sessionExpired`, which stays silent because the
  client's `onSessionExpired` hook already raised the re-login sheet) — and
  successful fetches write through. Delete/404/403 purge the **children**
  store only (the document's own entry *and* its ghost in other parents'
  cached lists); the Home/Shared list caches have no purge path — a deleted
  document drops out of them on the next successful fetch. The children store
  caps entries by reusing the pure `contentCacheEvictions` selection. The
  `schrift.workOffline` read goes through the VM's injected `userDefaults`,
  never the singleton. Metadata caches are **not** cleared on sign-out — a
  recorded decision; neither are unsaved drafts in `PendingDraftStore` (full
  document text, deliberately backup-included so unsaved work survives) nor the
  on-device create records in `PendingDocumentCreateStore` (same reasoning — for
  a document that exists nowhere else, that record and its draft are the only
  copies; surviving sign-out is made safe by the record's **`ownerUserID`**, not by
  `serverOrigin` alone, which identifies the server and not the account) nor the
  tombstones in `PendingDocumentDeleteStore` (a queued deletion is work the user asked
  for that has not happened yet, scoped the same way by `ownerUserID`) nor the
  queued photos in `PendingAttachmentStore` (records *and* JPEG bytes, backup-included
  and owner-scoped for exactly the same reason — an un-uploaded photo exists nowhere
  else); the full bodies in `DocumentContentCacheStore` are, and so is the account
  profile in `CurrentUserCacheStore` (next bullet — cleared, like the account id
  beside it, in `SessionStore` itself and not only in RootView, because it has to go
  on sign-*in* too, which only `SessionStore` sees). **The content caches are the
  ones with the RootView-only rule**: `DocumentContentCacheStore().removeAll()` and
  `AttachmentCacheStore().removeAll()` live in RootView's `onSignOut` closure and
  **not** inside `SessionStore.signOut()`, so a new sign-out path must call them
  explicitly. Displayed image bytes are also cleared at cookie handover, sign-in
  and sign-out through SessionStore's injected `clearImageCache` callback; keep
  that stronger account-isolation lifecycle. See [`docs/offline-and-sync.md`](../offline-and-sync.md).
- **The account's displayed profile is cached too** (`CurrentUserCacheStore`,
  `dev.llun.Schrift.currentUser`), because `/users/me/` is the only source of the
  email and names and it is a network call: `ProfileViewModel` held it in memory
  only, so offline the user row rendered its "—" placeholder and the account detail
  was unreachable on a screen whose every other row works offline. It seeds the view
  model **synchronously in `init`** (the screen renders `user` in its `body` before
  `.task` runs, so a fetch is a frame too late to be the only source), and `load()`
  replaces `user` from a successful fetch — assigning the failed fetch's nil is the
  bug itself, one frame later. **A fetch that answers nothing re-reads the store; it
  never keeps what is on screen.** Two reasons, and both bite: this view model is
  `@State` in `MainTabView`, which is *not* rebuilt across a re-login (the sheet is
  presented over it while `isAuthenticated` stays true), so the in-memory copy can
  belong to the account that just went away — keeping it would show one user's email
  inside another's session, and the store is the session-scoped answer because
  `signIn` clears it. And at launch `MainTabView.init` runs *before* RootView's task
  fills the cache, so a one-shot seed would leave Profile empty for the whole session
  if the network died in between. A response carrying **no** account detail at all
  (`{}` decodes to an all-nil `CurrentUser` — every field is `decodeIfPresent`) counts
  as answering nothing, or it would sail past `if let` and destroy a good profile;
  an id with no name still counts as an answer. **Two** of the app's `/users/me/`
  callers write through — `ProfileViewModel.load` and
  `HomeViewModel.refreshSignedInUser` (without the second, a user who never opens
  Profile while online still has nothing cached). The others deliberately do not:
  the save coordinator's three replay gates and RootView's awareness provider read
  only the id or the display name, and none of them is a Profile refresh.
  Unlike the stores above it is **cleared at sign-in *and* sign-out**
  (`SessionStore`, plus RootView's belt-and-braces call): it is re-fetchable server
  data with no unsynced-work argument, and it is *displayed* before any fetch, so a
  kept entry would name the previous account on the new user's screen — indefinitely
  if they are offline. It is deliberately **not** merged into `SignedInUserStore`:
  that one answers *whose session is this*, gating what may be listed and sent for
  another account's unsynced documents, so it stays written only from a live fetch —
  `ProfileViewModel` seeds its display from the cache but never lets a cached id
  reach `remember`. Clearing the store is only half of session-scoping the row: the
  view model is `@State` in `MainTabView`, which the re-login sheet is presented
  *over*, so `SessionStore.signInGeneration` (bumped by `signIn`, never by an expiry
  or a cancel) keys `ProfileScreen`'s `.task` and makes an answered sheet re-run
  `load()` — otherwise the previous account's row survives until the user happens to
  switch tabs. Two consequences of that restart: the re-seed is `load()`'s **first**
  line, so a session change blanks the row immediately instead of after a round trip
  (or a ~60s timeout), and both awaits are followed by a **`Task.isCancelled` guard**,
  since the restart cancels the load in flight and a cancelled load holding an
  already-resolved response would otherwise write the previous account back into both
  stores — re-arming `SignedInUserStore`, the one that gates replay. The one predicate that decides whether that row is *tappable* is
  `accountDisplayName`, the same one `AccountScreen` branches on.
- **Both identity stores are forgotten when the *cookies* change hands, not when the
  sign-in succeeds** — `SessionStore.noteSessionCookiesReplaced()`, called by
  `ReauthenticationViewModel.handleLoginComplete` and `ConnectViewModel
  .handleLoginComplete` **before** their confirming `GET users/me/`. `signIn` cannot
  be the only clearing point, because it runs only when that confirmation succeeds,
  while `WebLoginView.captureCookies` syncs the new session into
  `HTTPCookieStorage.shared` unconditionally and *earlier*. So a 5xx or a dropped
  connection on that one request left the app running **B's session under A's
  identity** — and *stably*, since B's cookies are valid and nothing 401s again to
  re-present the sheet, so it persisted until the next successful `/users/me/`. Three
  things go wrong in that state, and the middle one is not what it looks like: A's
  unsynced documents are listed to B (the disclosure `belongsToSession` exists to
  prevent — their content on screen, and any edit landing in their document); anything
  B creates or deletes is stamped `ownerUserID = A`, which is **deferred
  misattribution, not immunity** — all three replay passes gate on a live
  `client.currentUser()` rather than on this store, so nothing of B's is ever sent into
  *B's* account, but the record matches `belongsToSession` again the moment **A** signs
  in on this device and is then sent under A (B's document POSTed into A's account, B's
  queued deletion of A's document actually made), exactly as `belongsToSession`'s own
  comment warns; and Profile shows A's name and email inside B's session. Binding the
  clear to the handover makes the failure fail closed (nil is what every reader already
  handles). The cost, when the *same* account re-authenticates and the confirm blips, is
  that their local-only documents drop out of the lists and **all three** create affordances
  refuse to mint another — Home's `+`, `EditorViewModel.addSubpage` and
  `PagesTreeViewModel.addPage`, the latter two mattering more because neither screen can
  reach the retry from its own UI — until the identity is re-learned. Create records are
  protected unconditionally by `isPendingCreate`, so no *document* is lost — but that
  guarantee is about creates and does not generalise, and two neighbours key off the same
  owner. A **queued photo** was the one that could genuinely lose data:
  `pendingAttachmentDisplay` collapsed "unknown session" into "another account's", so the
  card declared the photo gone — over bytes `PendingAttachmentStore` holds the only copy of —
  and offered a Remove that deletes them, contradicting the rule `isAttachmentReplayable`
  states for the identical condition. Fixed here by giving that case its own non-destructive
  state, `PendingAttachmentDisplay.unattributable` (no claim, no actions; it may not render
  the photo either — an unknown session is not *proof* of the same account). **Queueing a new photo** refuses too (`EditorViewModel`'s
  `queuePendingPhoto`, with the generic "Couldn't add the photo") — fail-closed, nothing
  written, nothing lost. A **queued deletion** shares the collapse in
  `isListablePendingDelete`, deliberately left: the row
  stops drawing struck through and its tap opens the document instead of offering the undo,
  but the unscoped `isPendingDelete` still protects the tombstone, so it costs the undo
  affordance rather than the deletion and heals with the identity — and milder still, since
  `EditorViewModel.isDocumentPendingDelete` and `undoPendingDeleteForThisDocument` are both
  unscoped, the undo is reachable one tap deeper rather than lost. Starting a **new** deletion
  in the window is a third case: `DocumentActions` needs a known owner to queue a tombstone, so
  a retryable failure surfaces the error instead of queueing — fail-closed, nothing lost. **Fail-closed needs a way back open**, or a
  transient blip strands the user until a relaunch: the store's other writers run at
  launch, after a *successful* re-auth, and on any Profile visit — none of which a user
  sitting on Home will hit — so `HomeViewModel
  .refreshSignedInUserIfUnknown` re-asks `/users/me/` while and only while the answer is
  missing, from `refresh()` and `syncPendingDrafts()` — pull-to-refresh, reconnect,
  foreground: the three paths that already mean "catch up". **It carries its own
  `schrift.workOffline` guard**, because it runs *ahead* of `load()` and so is not covered by
  `load()`'s early return — `HomeViewModel` is one of the three view models that honour the
  preference, and without it a pull made while the identity is unknown reaches the network —
  which in this mode is every such pull, since nothing arrives to make it known. Two things that
  guard does **not** mean: the preference is not app-wide (`RootView`'s launch task and
  `ProfileViewModel.load` both fetch `/users/me/` without reading it — pre-existing, and what
  keeps the withheld retry from stranding anyone), and inside the mode a dropped identity now
  has **no in-Home remedy**: rows stay hidden and `+` answers "Couldn't create a document"
  until a relaunch, a Profile visit, or turning the preference off and pulling. Accepted — the
  mode's promise is that a read path does not reach the network. Deliberately **not** from
  `load()`, which is wrong twice: a per-appearance `/users/me/` is more traffic than this
  rare case warrants, and several Home tests gate on *the first GET a load makes* while
  blocking `MockURLProtocol`'s single delivery thread, so a request inserted ahead of the
  list fetches stalls that thread and cascades into every test after it (36/64 failures,
  2833s, when tried). It bumps `signInGeneration` for the
  same reason `signIn` does: clearing the value is only half the job while
  `ProfileViewModel` holds an in-memory copy behind a sheet that never rebuilt it. It
  is deliberately **not** fired by opening or cancelling the sheet — no cookies changed
  hands there, so the dismissed-sheet contract (cached data keeps showing, the same
  reason this is not done at `noteSessionExpired`) still holds. Add any future
  account-scoped state to the private `forgetSignedInIdentity()` the three callers
  share, not to one of them.
- User **preferences** use `@AppStorage` / `UserDefaults` with the `schrift.`
  prefix (distinct from the `dev.llun.Schrift.` data-key prefix).
- Sensitive/auth state goes in the **Keychain**, never UserDefaults.
- **Session cookies persist in the Keychain** (`dev.llun.Schrift.sessionCookies`):
  `SessionStore.signIn` snapshots the server's cookies (as Codable
  `StoredCookie`s — the Django `sessionid` is session-only, so
  `HTTPCookieStorage` alone drops it when iOS kills the process) and
  `SessionStore.init` restores them into `HTTPCookieStorage.shared`
  synchronously, before RootView builds the API client. Deleted on sign-out.
  Never log cookie values; never add `kSecAttrSynchronizable`. Items are stored
  `…WhenUnlockedThisDeviceOnly` (a live session stays on the device that got it;
  the cost is one re-login after a device migration), re-applied on every
  delete-then-add `save` and back-filled onto pre-existing items by
  `SessionStore.init` via `KeychainStore.upgradeAccessibility`.
  The snapshot is **re-taken on every move to the background**
  (`refreshPersistedSessionCookies`, from RootView's `scenePhase` observer): the
  server rotates/extends its cookies mid-session, and a sign-in-only snapshot
  restored stale ones so every cold launch 401'd. It is skipped while
  `needsReauthentication` (the cookies are refused) and while a web login's
  cookies await confirmation (`cookiesAwaitingConfirmation`, set by
  `noteSessionCookiesReplaced`, cleared only by `signIn`/`signOut` — it must
  outlive a cancelled sheet, since they may be another account's and only
  `signIn` persists those), and never writes an empty set. That write runs as the scene backgrounds, while the device is
  still unlocked; a failure is swallowed and only costs the old behaviour.
  **If a Keychain read or write ever moves onto a background-task path** (none
  today) this must become `…AfterFirstUnlockThisDeviceOnly`, or a background
  launch reads nil and silently signs the user out.
- **A 401 is recovered silently first.** `noteSessionExpired` starts a hidden
  web login (`SilentReauthenticationView`, mounted invisibly by RootView while
  `isSilentlyReauthenticating`); the visible sheet is bound to
  `presentsReauthenticationSheet`, not `needsReauthentication`, and appears only
  via `escalateReauthentication(attempt:)`. *When* to escalate is
  `SilentReauthenticationAttempt` (tested, durations injected), fed by
  `WebLoginView`'s `WebLoginProgress`: stopped off the server for a 2 s grace
  that any new load cancels (superseded loads — `NSURLErrorCancelled`, WebKit
  102 — are not stops), a failed confirmation, or the 15 s timeout;
  `.reachedServer` (reported before the cookie hand-off) disarms both timers.
  Escalation names the attempt and is a no-op unless that silent attempt is
  running, so a late timer can't reopen an answered sheet or escalate a later
  attempt. After one failed silent attempt, or a 401 within
  `silentReauthenticationCooldown` (60 s) of a silent sign-in, expiries go
  straight to the sheet — the latter stops a refused-again session looping
  through hidden logins. `onSessionExpired` carries the refused request's
  start instant, and a 401 for a request issued before the last `signIn` is
  ignored (it was refused on the replaced cookies). Keep the hidden web view transparent, never
  `isHidden`: WebKit throttles hidden views.
- `DocumentContentCacheStore` is the one **file-based** store (full document
  bodies are too large for UserDefaults): stateless over its directory,
  `isExcludedFromBackup`, cleared on sign-out, never logged. Its eviction
  selection is a top-level pure free function (`contentCacheEvictions`).
- **"Continue reading" positions** (`ReadingPositionStore`,
  `dev.llun.Schrift.readingPositions`, one JSON blob in UserDefaults) remember which
  block was at the top of the screen when a document was left, so reopening scrolls
  back to it. Keyed by `readingPositionKey(serverOrigin:documentID:)`, capped to 200
  documents by the pure `recordingReadingPosition` (least recently saved evicted; the
  entry being written always survives), dates in milliseconds. A position is a block id
  plus `readingPositionFingerprint` — an FNV-1a hash of the block's normalised first 160
  characters, **not** `Hashable` (seeded per process) and **no document text** — because
  block ids are re-minted by every parse and only the fingerprint survives a relaunch.
  `readingPositionRestore` is the pure decision: id, else fingerprint (nearest to the old
  index among equals), else nothing, and nothing when the block is within the first two.
  **Cleared on sign-out** in RootView's `onSignOut` beside the content caches (it is
  reading history, not unsynced work, so unlike drafts it does not outlive the session).
  `ReadingPositionSession` (in `EditorView`'s `@State`) decides the restore once per open
  and **writes nothing until it has** — before then the viewport is at the top and
  persisting would overwrite the very position about to be restored. Deciding and scrolling
  are separate (`beginRestore`, then `takeRestoreScroll` once the target row reports a frame,
  gated by the pure `readingRestoreScrollStep`, which judges the target against the rows
  the surface *presents* — a hidden completed item is abandoned, never waited for — and
  waits only for a presented row's frame): a **cached** open installs its body from
  `.task` after the reading surface appeared empty, so the restore is decided in the update
  that inserts the rows, and a `scrollTo` there has nothing laid out to reach. The top block is
  tracked continuously in `EditorScrollAnchorStore.lastTopVisibleBlockID` because a
  disappearing screen reports no frames. No deep link addresses a position inside a
  document today; one would need to bypass the restore.
