# Repository layout

```
Schrift/
├── App/                 app entry (SchriftApp), root navigation (RootView),
│                        the tab shell lives in Features/Home/MainTabView,
│                        AppAppearance + AppearanceStore (dark-mode preference)
├── Core/
│   ├── Auth/            SignedInUserStore (the account id offline creation needs),
│   │                    CurrentUserCacheStore (the account's *displayed* profile,
│   │                    so Profile has a name to show with no network),
│   │                    SessionStore (persists session cookies in the Keychain and
│   │                    exposes needsReauthentication), SessionCookies (Codable
│   │                    HTTPCookie snapshot), WebLogin (WKWebView cookie login),
│   │                    KeychainStore
│   ├── Collaboration/   Hocuspocus + y-websocket/Yjs layer — pure wire
│   │                    codecs (HocuspocusMessage, SyncMessage, AwarenessCodec),
│   │                    origin-pinned endpoint builders (CollaborationEndpoint),
│   │                    the WebSocket transport (WebSocketConnecting seam +
│   │                    URLSessionWebSocket adapter, CollaborationTransport actor,
│   │                    CollaborationEvents), the session state machine
│   │                    (DocumentCollaborationSession) with availability gating
│   │                    (LiveCollaborationAvailability +
│   │                    LiveCollaborationPreference +
│   │                    ServerConfig.collaborationWsUrl), and the app-scoped
│   │                    DocumentCollaborationManager (keyed sessions,
│   │                    refcount/linger, scenePhase suspend/resume, reconnect on
│   │                    the ConnectivityMonitor edge) wired in RootView, dormant
│   │                    behind the default-off flag. C1 makes the session deliver
│   │                    inbound update bytes (onSyncUpdate), gives the manager a
│   │                    per-document YDoc replica (applyUpdate → replicaVersion +
│   │                    projectedReplica, failSafe, destroy on teardown), and adds
│   │                    the caret-preserving LiveEditingBridge (read-side live
│   │                    apply). C2a makes the handshake real (SyncStep1 now carries
│   │                    the replica's actual state vector; a peer's SyncStep1 is
│   │                    answered with a SyncStep2 diff via onStateRequest →
│   │                    stateReply, deliberately ungated on replica health so the
│   │                    room always converges and a reconnect re-offers everything
│   │                    accumulated so far) and adds the outbound write path:
│   │                    applyLocalEdit(old:new:for:) wraps B6's
│   │                    BlockNoteWrite.applyEdit and broadcasts the incremental
│   │                    update, bumping a separate localEditVersion — never
│   │                    replicaVersion/remoteChangeToken (local-echo suppression,
│   │                    or the editor would read-apply its own edit).
│   │                    initialSyncApplied is set only by onInitialSync on the
│   │                    first inbound SyncStep2 (an earlier .update still builds
│   │                    the replica but leaves it non-writable), and
│   │                    encodeSnapshotForSave(for:) returns nil unless
│   │                    canWriteReplica(for:). C2b adds the save mechanism
│   │                    (enqueueLiveSnapshot/saveLiveSnapshot) through the existing
│   │                    save coordinator. C2c (Features/Editor) is what finally
│   │                    calls both: LiveEditingBridge.forwardLocalEdit forwards a
│   │                    local keystroke to applyLocalEdit + schedules a ~60s
│   │                    snapshot debounce, EditorViewModel.markDirty's mode split
│   │                    forwards instead of dirtying when a weak liveWrite
│   │                    delegate is engaged, and persistLiveSnapshot calls
│   │                    enqueueLiveSnapshot. Opt-in via the C3 Profile toggle
│   │                    (default off — see Features/Profile)
│   ├── Localization/    in-code catalog: AppLanguage (11 langs), L10nKey,
│   │                    Strings+<lang>.swift tables, LocalizationStore, PluralRule,
│   │                    RelativeDateFormatterCache (one shared relative-date formatter
│   │                    per locale)
│   ├── Networking/      actor DocsAPIClient + per-feature endpoint extensions
│   │                    (incl. AttachmentEndpoints: multipart upload + media-check;
│   │                    VersionEndpoints: read-only version list;
│   │                    CollaborationYDocEndpoints: ContentSaveRoute + the Docs 6
│   │                    collaboration-server body save), Codable models,
│   │                    DocsAPIError, CSRF, ConnectivityMonitor (NWPathMonitor →
│   │                    the reconnect trigger for draft sync)
│   └── Yjs/             two halves. (a) the on-device Markdown→BlockNote→Yjs
│                        encoder that builds the base64 content payload for saves
│                        (MarkdownYjs, BlockNoteDocument, InlineMarkdown,
│                        YjsUpdateEncoder + its YEncoderItem/YEncoderContent model);
│                        (b) the CRDT core — Lib0Decoder (read-side lib0 primitives,
│                        shared with Core/Collaboration), YUpdateDecoder (v1 wire
│                        model + byte-identical re-encode), the live replica:
│                        YContent, YStruct/YItem/YGC/YSkip, YType/YDoc, YStructStore,
│                        YDeleteSet, YTransaction, YStructIntegrator, YStateEncoder
│                        (B3: encode the live store → v1 update / state vector,
│                        byte-identical to yjs), YTextCleanup (B4: remote-change
│                        format cleanup), YUndoManager (PR07a: yjs's
│                        UndoManager, the native editor's history since
│                        PR07b) — a literal transliteration of
│                        yjs 13.6.33, gc on by default — and YBlockProjection +
│                        InlineMarkdownWriter (B5: total, never-trapping read-out of
│                        an integrated replica → BlockNote-vocabulary blocks →
│                        editor markdown, with per-block fidelity flags); plus the
│                        Docs 6 save's incremental half — BlockNoteAlignment (give
│                        parsed blocks the server replica's ids) and
│                        BlockNoteIncrementalSave (server state + markdown →
│                        incremental update via BlockNoteWrite.applyEdit)
├── DesignSystem/
│   ├── Tokens/          DocsColor, DocsTypography (DocsFont/DocsTracking),
│   │                    DocsSpacing, DocsRadius, DocsMotion (Reduce Motion → animation),
│   │                    HexColor (light+dark adaptive),
│   │                    MaterialIcon (the app's icon set — Material Symbols)
│   └── Components/      Avatar, AvatarGroup, Badge, Button, DocIcon, DocIdentity, DocRow, PinnedCard,
│                        IconButton, LinkReachPill, ListRow, ListSection,
│                        MaterialSymbol, OfflineBanner, SearchField, SheetHeader,
│                        ShareMemberRow, Skeleton, SwipeRevealRow, Switch, TextField,
│                        Toast (SwiftUI + style resolvers, each with light+dark hex)
│                        — plus SwipeRevealGesture, the one file here that is not a
│                        component: the UIKit gesture bridge SwipeRevealRow drags with
│                        (UIGestureRecognizerRepresentable + pure gates), so it has no
│                        #Preview catalog and no style resolver
├── DesignSystemCatalog/ ComponentCatalogPreview (visual QA catalog)
├── Features/
│   ├── Connect/         server URL entry + WKWebView OIDC login + the session-expiry
│   │                    re-login sheet (ReauthenticationSheetView +
│   │                    ReauthenticationViewModel, tried first invisibly by
│   │                    SilentReauthenticationView), RecentServersStore
│   ├── Documents/       DocumentActions — the one delete/pin/move ladder, shared by the
│   │                    Options sheet and every swipe surface — plus the move destination
│   │                    picker (MoveDocumentViewModel + MoveDocumentSheetView)
│   ├── Home/            document list (pinned + recent, each document in exactly one),
│   │                    offline metadata cache, FavoriteOverlay (pins vs. a list fetch that
│   │                    predates them; and the Pinned/Recent split), MoveOverlay (moves vs.
│   │                    the same race)
│   ├── Search/ Shared/  the other tabs; Profile also hosts the Appearance/Language
│   │   Profile/         picker sheets (AppearancePickerSheet, LanguagePickerSheet),
│   │                    the server-version row (ServerConfig), and the Attachments
│   │                    list (AttachmentsScreen: every file linked from a document
│   │                    in the content cache, no request of its own — docs has no
│   │                    attachments listing API)
│   ├── Options/ Share/
│   └── Editor/          block editor, save coordinator, drafts, content cache,
│                        file attachments (AttachmentDisplay classifier +
│                        AttachmentLoader + AttachmentCacheStore + AttachmentCardView),
│                        Pages tree drawer (PagesTreeDrawer + PagesTreeViewModel,
│                        lazy per-level children via the children cache; PagesDrawerPan:
│                        the edge pull / drag-to-close, progress-driven, back-swipe aware),
│                        the "In this document" outline + find sheet for the OPEN document
│                        (DocumentOutline: pure outline/find/section counts/stepping;
│                        DocumentOutlineSheet; opened from Options or Command-F),
│                        offline sync + detect-and-ask conflicts (DraftSyncDecision,
│                        ConflictSheetView), documents created on-device
│                        (PendingDocumentCreateStore + the replay; Home/editor create UI),
│                        documents deleted on-device (PendingDocumentDeleteStore + runDeletePass,
│                        strikethrough rows + PendingDeleteUndo),
│                        photo insert (ImagePreparation),
│                        leaf nesting restored from the block tree (LeafNestingOverlay),
│                        in-app document links (DocumentLink),
│                        inline rendering (BlockTextView glyph suppression, HiddenSyntaxSelection,
│                        InlineTextStyle) + link authoring (MarkdownLinkEditing, LinkEditorSheet,
│                        the `[[` page picker: PageLinkPicker + PageLinkPickerView),
│                        the one style table BOTH surfaces draw from (EditorBlockStyle:
│                        EditorBlockMetrics, blockTextAppearance, editorBlockDecoration,
│                        EditorBlockAdornment) + the shared EditorDocumentHeader and the
│                        EditorScrollAnchorStore that carries scroll position across the
│                        reading ↔ editing swap (EditorScrollTarget names the editing
│                        canvas's rows for its own ScrollViewReader, nothing more),
│                        "continue reading" (ReadingPositionStore, ReadingPositionSession,
│                        BackToTopPill — see Persistence),
│                        read-only version history (VersionHistoryViewModel,
│                        VersionHistorySheetView — see Networking)
└── Assets.xcassets/
SchriftTests/            XCTest suite; mirrors the source tree by directory (see below)
SchriftUITests/          checklist UI tests + isolated production-row host entry point
docs/                    living project docs — architecture.md, offline-and-sync.md,
                         design-system.md, ci.md, testflight-setup.md (see docs/README.md);
                         assets/app-icon/ holds the icon's vector masters + export script
fastlane/ scripts/ .github/workflows/   CI: PR build/test checks + TestFlight release pipeline
ci_scripts/             Xcode Cloud build hooks (ci_post_clone.sh regenerates the project)
project.yml              XcodeGen spec — the source of truth for the Xcode project
Signing.xcconfig         committed signing config; optionally #include?s the git-ignored
                         Local.xcconfig (copy Local.xcconfig.example) holding your
                         DEVELOPMENT_TEAM — never put a team id in project.yml
Gemfile / .ruby-version  fastlane Ruby deps (bundle install)
.swift-format            swift-format config (4-space indent, 120 cols) enforced by PR checks
```

The test tree mirrors the source tree **by directory**: a file at
`Schrift/X/Y.swift` is tested from `SchriftTests/X/`, usually as `YTests.swift` —
but test files are named for the primary type or behavior under test when that
differs from the file name (`YjsUpdateEncoder.swift` → `YjsEncoderTests.swift`,
`WebLoginView.swift`'s coordinator → `WebLoginCoordinatorTests.swift`, the
component style resolvers → `<X>StyleResolverTests.swift`), so search the
mirrored directory before adding a new test file. Test doubles and shared
helpers have no source counterpart: fakes live beside the code they fake
(`SchriftTests/Core/Networking/MockURLProtocol.swift`,
`SchriftTests/Core/Auth/FakeKeychainStore.swift` / `FakeCookieStorage.swift`),
and cross-suite helpers live in `SchriftTests/Support/` (`FormatSpecifiers.swift` — `formatArgumentList(of:)`, the localization
gate's parser, itself tested by `FormatSpecifiersTests`; `AsyncTestHelpers.swift`
— the shared `waitUntil` poller and `RequestRecorder`; `RequestBodyHelpers.swift`
— `bodyData(from:)`, which drains `httpBodyStream` because `URLSession` moves
bodies there; `TestImages.swift` — `testPNGData`/`testPixelSize`/`testImageProperties`/
`testJPEGDataWithGPSMetadata`, CoreGraphics fixtures so image tests need no bundle
asset); `ColorContrast.swift` — `relativeLuminance`/`contrastRatio`, the WCAG
helpers behind the contrast invariants). Follow the directory mirror when adding files.
