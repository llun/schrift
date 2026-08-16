import PhotosUI
import SwiftUI

/// Either a fixed localized string, or the "Synced %@" template with the
/// relative-time portion already resolved by `RelativeDateTimeFormatter` —
/// which is itself locale-aware (like `documentRowDate`), so it needs no
/// lookup in `Strings_en`. The view resolves either case to display text via
/// `LocalizationStore`.
enum SyncCaptionText: Equatable {
    case key(L10nKey)
    case syncedAgo(String)
}

/// "Synced X ago" caption for the editor header. Pure — `now` is a parameter
/// (note `documentRowDate` reads `Date()` internally and is untestable; this
/// one is driven by a `TimelineView` tick so it must not) — and `locale`
/// mirrors `documentRowDate`'s so the relative-time wording follows the app's
/// chosen language, not the system's.
func syncStatusCaption(lastSyncedAt: Date, now: Date, locale: Locale) -> SyncCaptionText {
    if now.timeIntervalSince(lastSyncedAt) < 60 {
        return .key(.editor_sync_just_now)
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = locale
    return .syncedAgo(formatter.localizedString(for: lastSyncedAt, relativeTo: now))
}

/// The editor header's sync caption, and whether it doubles as a retry button.
struct SyncCaption: Equatable {
    let text: SyncCaptionText
    let offersRetry: Bool
}

/// Caption precedence: (0) a **recorded sync conflict** outranks everything, because it
/// *holds* the push — no retry here can run and no sync is coming until the user answers
/// the pill, so the caption states only the true part ("Saved on this device") and offers
/// no affordance. (1) a **failed save** wins over the rest, including the offline wording —
/// it is the only affordance that unpins the document, because `reconcileDraft`
/// deliberately no-ops every revalidation while a failed save's draft is on screen, and the
/// reading surface has no other retry. (1b) a **queued offline save** (`.pendingSync`) is
/// its own tier just below: its "syncs when online" caption beats the generic offline
/// wording, and it doubles as a manual retry when the device is online (where the auto-sync
/// triggers can't fire). (1c) **dirty** content sits above the generic offline wording,
/// because dirty means "not on disk yet" — the draft is written by the flush — while that
/// wording asserts durability. This is the same truth `saveStatusDisplay` keeps on the
/// editing surface, where `.dirty` holds its Save funnel even under a conflict. In normal
/// operation nothing renders `.dirty` on *this* caption. It used to be enough to say it
/// needs `mode == .reading` at render time; the editing status slot falls through to this
/// same caption when `saveStatusDisplay` is `.none`, so that premise is gone and a
/// narrower one carries it: `saveStatusDisplay` maps `.dirty` to `.save`, never `.none`,
/// so the fallback cannot render in a dirty state. On the reading side the old argument
/// still holds — the only mutator that runs outside an editing session — the
/// reading-mode photo insert — flushes in the same synchronous turn it dirties
/// (`insertImageBlock`'s `defer`), while `finishEditing` flushes before it sets `.reading`.
/// The one exception is a **discarded** document: `flushPendingChanges` returns on
/// `isDocumentDiscarded` *before* clearing `isDirty`, and `markDirty` has no such guard, so
/// a keystroke landing after a delete but before the screen pops can reach reading mode
/// still dirty. So the tier is near-defensive rather than dead, and there the wording it
/// produces is the truthful one.
/// (2) other unsaved local content → save wording (a previously-synced doc with a stranded
/// draft must not read "Not synced yet"); (3) synced → "Synced X ago"; (4) neither.
func syncCaption(
    hasUnsavedLocalContent: Bool,
    hasConflict: Bool,
    isOffline: Bool,
    saveState: EditorViewModel.SaveState,
    lastSyncedAt: Date?,
    now: Date,
    locale: Locale
) -> SyncCaption {
    // A standing conflict outranks *everything*, including "Synced X ago". It was nested inside
    // `hasUnsavedLocalContent`, so a conflict that is still recorded and still holding every push
    // could render as "Synced 5 min ago" — telling the user they are in sync while their next
    // save is parked behind a question they have not answered.
    if hasConflict {
        return SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false)
    }
    if hasUnsavedLocalContent {
        if case .failed = saveState {
            return SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true)
        }
        // A queued offline save gets its own caption, above the generic offline one:
        // it promises the edit will sync, not merely that it's on the device. When
        // the device is actually online (a 5xx / rate limit / HTTP-3 stall parked the
        // save), the reconnect/foreground auto-sync triggers can't fire, so the
        // caption doubles as a manual retry; offline it stays passive (reconnect
        // handles it).
        if case .pendingSync = saveState {
            return SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: !isOffline)
        }
        // Above the offline wording: content is not on disk until the flush writes
        // the draft, so "Saved on this device" would be a lie here.
        if case .dirty = saveState {
            return SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false)
        }
        if isOffline { return SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false) }
        switch saveState {
        case .saving: return SyncCaption(text: .key(.editor_saving), offersRetry: false)
        case .saved: return SyncCaption(text: .key(.editor_saved), offersRetry: false)
        case .failed: return SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true)
        case .pendingSync: return SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: false)
        case .dirty, .idle: return SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false)
        }
    }
    if let lastSyncedAt {
        return SyncCaption(
            text: syncStatusCaption(lastSyncedAt: lastSyncedAt, now: now, locale: locale), offersRetry: false)
    }
    return SyncCaption(text: .key(.editor_sync_not_synced_yet), offersRetry: false)
}

/// The sync caption, and the retry affordance it becomes when the save can be
/// retried. Both editor surfaces draw it — the reading one always, the editing
/// one whenever `saveStatusDisplay` has nothing of its own to add.
///
/// Its own view rather than a helper on `EditorView` so the tap target can be
/// *measured* (`EditorViewTests`) instead of asserted. It takes resolved strings
/// rather than `L10nKey`s, which keeps it free of `LocalizationStore` and makes
/// it hostable with nothing injected.
struct SyncCaptionLabel: View {
    let offersRetry: Bool
    let text: String
    let retryAccessibilityLabel: String
    var onRetry: () -> Void

    var body: some View {
        if offersRetry {
            Button(action: onRetry) {
                Text(text)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textBrand)
                    // The floor and the shape go on the **label**, exactly as
                    // `SaveStatusIndicator` puts them on its own. A plain
                    // `Button` hit-tests the shape its label draws, and a `Text`
                    // draws one line — so a row floored at 44pt around this
                    // leaves the target the ~16pt strip it always was. This is
                    // the only affordance that unpins a document whose save
                    // failed, so it is the last one that should be hard to hit.
                    .frame(minHeight: DocsSpacing.rowMinHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(retryAccessibilityLabel)
        } else {
            // No floor: nothing here is tappable, and the row it sits in carries
            // its own so the slot's height does not move when the state changes.
            Text(text)
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textTertiary)
        }
    }
}

/// The editor toolbar's trailing actions, as an ordered list of intents. Pure so
/// the edit/done swap is unit-testable without SwiftUI — the view maps each case
/// to a `ToolbarItem`.
///
/// Reading mode exposes **Edit unconditionally**, offline included. It used to
/// take `isOffline` and withhold Edit, because offline was read-only; editing
/// offline now queues through the write-ahead draft pipeline (the draft is on
/// disk before the PATCH is attempted, a transport failure parks the save at
/// `.pendingSync`, and the reconnect/foreground/launch triggers replay it), so
/// the gate is gone — along with the parameter, which would otherwise invite it
/// back. What keeps Edit safe on a document whose content never loaded is
/// `EditorViewModel.startEditing`'s `hasLoadedContent` guard, exactly as it
/// already is online during a load or an error state.
///
/// Editing mode swaps Edit for **Done** in the same slot and keeps the rest.
/// There is one system toolbar in both modes now, so Done no longer needs a bar
/// of its own; the save status it used to sit beside moved into the editing
/// surface, where there is room for it.
enum EditorToolbarAction: Equatable {
    case edit
    case done
    case share
    case options
}

/// `isLocal` drops **Share**: a document that exists only on this device has no share URL
/// and no accesses to list, so the sheet would show "Couldn't load members" over a link
/// nobody else can open. Everything else stays — editing, and Options for Delete — because
/// they are exactly what a local document needs. Deliberately *not* keyed on `isOffline`:
/// sharing an already-synced document offline fails loudly, which is the pre-existing
/// behaviour and not this change's business.
func editorToolbarActions(isEditing: Bool, isLocal: Bool = false) -> [EditorToolbarAction] {
    var actions: [EditorToolbarAction] = [isEditing ? .done : .edit]
    if !isLocal { actions.append(.share) }
    actions.append(.options)
    return actions
}

/// How many peers to present, or `nil` when presence should not be shown at all.
///
/// Offline suppresses it: peer state is whatever the socket last said, and
/// presenting a stale count as live would be a small lie.
///
/// `isOffline` is a **coarse** proxy for that, and knowingly so — it is derived
/// from `HomeViewModel`'s last *list* fetch, so a 5xx or a decoding bug on that
/// one endpoint sets it with the socket perfectly healthy, and `schrift
/// .workOffline` sets it outright. It is the signal this app uses to gate
/// chrome, and presence is chrome; the failure is to hide something true, never
/// to assert something false.
///
/// It was `presenceBadgeCount`, named for the count badge the Options button
/// carried while editing, which existed only because the reading surface's
/// avatar stack had no editing counterpart. The document header is shared now
/// and draws `PresenceBar` in both modes, so the badge is gone — and the name
/// went with it, rather than leaving a symbol pointing at an affordance nobody
/// can find. This is the one rule deciding whether that bar has anything fresh
/// enough to say, on **both** surfaces; before, the reading one drew its avatars
/// offline and only the badge was suppressed.
func presentedPeerCount(peerCount: Int, isOffline: Bool) -> Int? {
    guard !isOffline, peerCount > 0 else { return nil }
    return peerCount
}

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    /// Origin the reading/editing surfaces gate embedded images against
    /// (`imageLoadPolicy`) — off-origin images are tap-to-load.
    let serverOrigin: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var isOffline: Bool = false
    var onDeleted: (() -> Void)? = nil
    var onOpenDocument: ((Document) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationStore.self) private var loc
    @Environment(DocumentCollaborationManager.self) private var collaboration
    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var conflictToResolve: IdentifiedSyncConflict?
    /// Transient confirmations ("Link copied"). Owned here, not in the sheets
    /// that raise them — those dismiss themselves in the same breath, and a
    /// toast inside one would be torn down before it could be read.
    @State private var toastMessage: ToastMessage?
    @State private var isPresentingPagesTree = false
    /// The struck-through sub-page (or drawer page) the user tapped — see
    /// `pendingDeleteUndoAlert`.
    @State private var documentPendingUndo: Document?
    /// The Subpages row whose Delete swipe action was tapped, awaiting confirmation.
    @State private var subpagePendingDeleteConfirmation: Document?
    /// The drawer row whose Delete was tapped. Deliberately **not** shared with the one above:
    /// each routes to its own view model, so a failure reports on the surface the user is
    /// actually looking at — a drawer deletion reporting through `EditorViewModel` would put
    /// the message on a screen the drawer is covering.
    @State private var drawerPendingDeleteConfirmation: Document?
    /// The row whose Move swipe action was tapped, in the Subpages list or the drawer.
    /// **One** state for both, unlike the two delete confirmations above: the picker reports
    /// its own failures inside itself, so there is no per-surface message to route.
    @State private var documentPendingMove: Document?
    /// Which Subpages row's swipe strip is open. The drawer keeps its **own** state rather
    /// than sharing this one: it floats over this list, and a single value would let either
    /// close the other's strip.
    @State private var subpageSwipe = SwipeRevealState<UUID>()
    /// Where the document body is scrolled to, carried across the reading ↔
    /// editing swap so tapping a block below the fold places a caret instead of
    /// throwing the reader back to the top of the page. Shared by both surfaces
    /// and deliberately not observable — see `EditorScrollAnchorStore`.
    @State private var scrollAnchor = EditorScrollAnchorStore()
    @State private var pagesTreeViewModel: PagesTreeViewModel

    /// Height the formatting bar reserves at the bottom of the editing canvas:
    /// its 44pt tap target plus the inset's own padding.
    private var editingToastInset: CGFloat { DocsSpacing.rowMinHeight + DocsSpacing.spaceBase }
    @State private var pendingShareAfterOptions = false
    @State private var optionsViewModel: OptionsViewModel
    @State private var shareViewModel: ShareViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// Whether we currently hold a live-collaboration reference for this document,
    /// so the request/release stays one-shot and balanced even as availability
    /// flips (a session opened only once, released exactly once).
    @State private var holdsCollaborationSession = false
    /// C1's live-write coordinator. `nil` until the first collaboration-session
    /// request, because it needs the `collaboration` manager, which only becomes
    /// available from `@Environment` once the view has been installed — not in
    /// `init`. Built once and retained in `@State` alongside the session hold.
    @State private var liveEditingBridge: LiveEditingBridge?

    init(
        viewModel: EditorViewModel,
        reach: LinkReach,
        serverHost: String,
        serverOrigin: String,
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        isOffline: Bool = false,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.reach = reach
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        self.isOffline = isOffline
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
        _optionsViewModel = State(
            initialValue: OptionsViewModel(
                client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite,
                // So Delete can tell a document that exists only here from one the replay has
                // already POSTed, and issue the server DELETE for the latter.
                saveCoordinator: viewModel.saveCoordinator))
        _shareViewModel = State(
            initialValue: ShareViewModel(
                client: viewModel.client, documentID: viewModel.documentID, linkReach: reach, linkRole: linkRole))
        // The same store the editor's own Subpages list fills, so a level either
        // side has fetched is available to the other — and so a test can hand
        // both an isolated one.
        _pagesTreeViewModel = State(
            initialValue: PagesTreeViewModel(
                rootID: viewModel.documentID, client: viewModel.client, cache: childrenCache,
                // So "New page" can fall back to a local page when the POST cannot land — and
                // so the drawer's read-time merge scopes local pages to the same account the
                // editor does, rather than to a second store of its own.
                saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser))
    }

    var body: some View {
        // The undo alert is applied here, before the long modifier chain below, purely to
        // keep that chain inside the type-checker's budget — it belongs to the whole screen
        // either way (a struck-through row can be tapped in the Subpages list or the drawer).
        mainContent
            .pendingDeleteUndoAlert(for: $documentPendingUndo) { document in
                viewModel.undoPendingDelete(document)
            }
            .deleteConfirmationAlert(
                for: $subpagePendingDeleteConfirmation,
                hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
            ) { document in
                Task { await viewModel.deleteSubpage(document) }
            }
            .deleteConfirmationAlert(
                for: $drawerPendingDeleteConfirmation,
                hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
            ) { document in
                Task { await pagesTreeViewModel.deletePage(document) }
            }
            // Keyed to the row it was opened from, with the view model owned in `@State` by
            // `MoveDocumentSheet` — this screen re-renders on nearly every editor state
            // change, and an inline model would be swapped out from under an open picker.
            .sheet(item: $documentPendingMove) { document in
                MoveDocumentSheet(
                    client: viewModel.client, document: document,
                    saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .background(DocsColor.surfacePage)
            // While editing, clear the formatting bar the canvas floats at the
            // same edge — Copy Link is reachable from the toolbar mid-edit, so
            // the two genuinely collide.
            .toast($toastMessage, bottomInset: viewModel.isEditing ? editingToastInset : 0)
            // The drawer is an overlay rather than a sheet, so it gets none of a
            // sheet's VoiceOver scoping for free: without this the editor behind
            // it stays in the accessibility tree and a swipe walks straight into
            // toolbar buttons the drawer is covering. Ordered before `.overlay`,
            // which adds the drawer on top of the hidden content.
            .accessibilityHidden(isPresentingPagesTree)
            .overlay { pagesTreeOverlay }
            // One system toolbar in both modes. The document title stays in the
            // canvas as a large content header (`EditorDocumentHeader`) rather than in the
            // bar, so the bar carries only the back button and the trailing actions
            // — hence `.inline` with no `.navigationTitle`.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading, beside back: this is a *left* panel, and the trailing
                // group is already three items.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresentingPagesTree = true
                    } label: {
                        MaterialSymbol(.account_tree, size: 22)
                    }
                    .accessibilityLabel(loc[.pages_open])
                    // Hidden here as well as on `mainContent`: toolbar content is
                    // hosted by the navigation bar as its own accessibility
                    // subtree, so hiding the screen's body never reached it, and
                    // a VoiceOver swipe could still land on a bar button the
                    // drawer is covering.
                    .accessibilityHidden(isPresentingPagesTree)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForEach(
                        editorToolbarActions(isEditing: viewModel.isEditing, isLocal: viewModel.isLocalDocument),
                        id: \.self
                    ) {
                        action in
                        toolbarButton(for: action)
                            .accessibilityHidden(isPresentingPagesTree)
                    }
                }
            }
            .task {
                await viewModel.load()
            }
            // Presence: request a live session while this document is on screen, so
            // our avatar shows to peers and theirs to us. Reference-counted + balanced
            // with `release` on disappear; the manager owns the socket lifecycle
            // (linger, suspend, reconnect), so a background/foreground cycle is handled
            // there.
            .onAppear {
                requestCollaborationSessionIfNeeded()
                // Tell the save coordinator a screen is writing under this id. The create
                // replay re-keys a document's draft, coordinator maps and caches from the
                // local id onto the server id — and `EditorViewModel.documentID` is a `let`
                // captured by four sibling view models and by the pushed `NavigationPath`
                // value, so a live screen cannot follow that swap and would keep writing
                // under an id the holds no longer cover. Registering here is what makes the
                // migration defer instead.
                //
                // **For every document, not only locally-created ones.** The motivating case
                // is an ordinary document opened from Home whose id a checkpointed record is
                // about to migrate *onto*: that screen writes under the server id, and the
                // guards protecting it are keyed on the server id too.
                viewModel.noteEditorAppeared()
            }
            // Availability can resolve *after* the editor is already on screen — the
            // `/config/` fetch that decides server support runs concurrently with
            // navigation — so re-request when it flips to available; the one-shot hold
            // keeps this from double-counting.
            .onChange(of: collaboration.availability) { _, _ in
                requestCollaborationSessionIfNeeded()
            }
            // C1: a replica update integrated cleanly — hand it to the bridge, which
            // diffs the projection against the editor's blocks and applies it in place
            // (when engagement allows) so live edits land under the user's own cursor.
            .onChange(of: collaboration.replicaVersion(for: viewModel.documentID)) { _, _ in
                liveEditingBridge?.replicaDidChange()
            }
            // Live refresh: a peer touched the document (a change signal on the socket
            // bumps this token), so debounce a silent revalidation. Suppressed while the
            // bridge is actively applying live content — the stream is already newer than
            // a REST re-fetch would be, and installing a REST body over it would reset the
            // caret the bridge just preserved.
            .onChange(of: collaboration.remoteChangeToken(for: viewModel.documentID)) { _, _ in
                if liveEditingBridge?.isApplyingLiveContent != true {
                    viewModel.noteRemoteChange()
                }
            }
            .onDisappear {
                // The editor registration is deliberately *not* released here: `onDisappear`
                // means "not visible" (a tab switch, a pushed sub-document), and the replay
                // must not re-key a document whose screen is about to come back. It is
                // released when the view model is deallocated — see `noteEditorAppeared`.
                viewModel.flushPendingChanges()
                if holdsCollaborationSession {
                    collaboration.release(viewModel.documentID)
                    holdsCollaborationSession = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || phase == .inactive {
                    viewModel.flushPendingChanges()
                }
            }
            .sheet(isPresented: $isPresentingShareSheet) { shareSheet }
            .sheet(
                isPresented: $isPresentingOptionsSheet,
                onDismiss: {
                    if pendingShareAfterOptions {
                        pendingShareAfterOptions = false
                        isPresentingShareSheet = true
                    }
                }
            ) {
                optionsSheet
            }
            // `.sheet(item:)`, not `isPresented`: the sheet renders the conflict's server
            // timestamp, so it must never be presented without one. Both choices dismiss
            // the sheet themselves before handing off to the view model.
            .sheet(item: $conflictToResolve) { conflict in
                ConflictSheetView(
                    conflict: conflict.value,
                    onKeepMine: { viewModel.resolveConflictKeepingMine() },
                    onKeepServer: { Task { await viewModel.resolveConflictKeepingServer() } }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
    }

    /// Extracted from the `.sheet` closure: `body`'s modifier chain is long
    /// enough that inlining these two tips the type-checker over.
    private var shareSheet: some View {
        ShareSheetView(
            viewModel: shareViewModel,
            shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
            onLinkCopied: { toastMessage = ToastMessage(loc[.toast_link_copied]) }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var optionsSheet: some View {
        OptionsSheetView(
            viewModel: optionsViewModel,
            client: viewModel.client,
            documentID: viewModel.documentID,
            serverHost: serverHost,
            shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
            saveCoordinator: viewModel.saveCoordinator,
            signedInUser: viewModel.signedInUser,
            onLinkCopied: { toastMessage = ToastMessage(loc[.toast_link_copied]) },
            onShare: { pendingShareAfterOptions = true },
            onDeleted: { queued in
                // A *queued* deletion is still cancellable, so the teardown must not purge:
                // the draft, the create record and the cached body are what the undo puts
                // back. `DocumentSaveCoordinator.completePendingDelete` removes them once the
                // DELETE has really landed. A queued deletion also announces nothing, so this
                // is the only thing that ends the session for it.
                //
                // A *made* deletion deliberately has no branch here any more. It now goes
                // through `completeImmediateDelete`, whose announcement reaches this screen's
                // own `noteDocumentDeleted` → `handleDeletionLanded`, which calls
                // `handleDidDelete()` and additionally goes terminal. Calling it here too
                // would be a harmless second call — it only sets latches and bumps
                // generations — but one reaction path is better than two, and this way the
                // teardown is identical however the deletion was made (from this sheet, or
                // from a swipe on a list while this screen sits in an iPad detail pane).
                if queued {
                    viewModel.handleDidQueueDelete()
                } else {
                    // The announcement has already torn this session down via
                    // `handleDeletionLanded`, which is written for a deletion made *elsewhere*
                    // and so leaves "no longer available" on screen. The user made this one
                    // and is being popped away from it, so drop the message — in this same
                    // turn, before anything renders.
                    viewModel.noteDeletedFromThisScreen()
                }
                onDeleted?()
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var pagesTreeOverlay: some View {
        // The `.animation` belongs here, on the container the drawer comes and
        // goes inside — on the body it would also animate whatever else changed
        // in the same transaction (the save status, a conflict pill).
        ZStack {
            if isPresentingPagesTree {
                PagesTreeDrawer(
                    viewModel: pagesTreeViewModel,
                    rootTitle: viewModel.title.isEmpty ? loc[.common_untitled] : viewModel.title,
                    onOpen: { document in
                        // A page on its way out is not opened from the drawer either.
                        guard !viewModel.isDeletePending(document) else {
                            isPresentingPagesTree = false
                            documentPendingUndo = document
                            return
                        }
                        isPresentingPagesTree = false
                        onOpenDocument?(document)
                    },
                    onClose: { dismissPagesTree() },
                    // The drawer closes first: the confirmation is presented by the editor
                    // beneath it, and leaving the drawer up would put a system alert over a
                    // transitioning overlay.
                    onRequestDelete: { document in
                        dismissPagesTree()
                        drawerPendingDeleteConfirmation = document
                    },
                    // Same handover as Delete, and for the same reason: the drawer closes and
                    // the editor beneath it presents the picker.
                    onRequestMove: { document in
                        dismissPagesTree()
                        documentPendingMove = document
                    },
                    onUndoPendingDelete: { document in
                        dismissPagesTree()
                        documentPendingUndo = document
                    }
                )
                .task {
                    // Nothing announces an overlay the way it would a sheet, so
                    // say the screen changed and let VoiceOver land in the drawer.
                    AccessibilityNotification.ScreenChanged().post()
                    // A document queued for deletion is asked nothing — the same rule
                    // `load`/`revalidate`/`refresh` follow, and this is the one other path
                    // that would GET its children.
                    guard !viewModel.isDocumentPendingDelete else { return }
                    await pagesTreeViewModel.loadRoot()
                }
            }
        }
        .animation(.snappy, value: isPresentingPagesTree)
    }

    private func dismissPagesTree() {
        isPresentingPagesTree = false
        AccessibilityNotification.ScreenChanged().post()
    }

    /// The screen's content column, lifted out of `body` so the long
    /// modifier chain that follows stays type-checkable on its own — with
    /// both in one expression the compiler gives up.
    private var mainContent: some View {
        VStack(spacing: 0) {

            if isOffline, viewModel.hasLocalCopy {
                OfflineBanner(note: loc[.editor_offline_local_copy])
            }

            // Shown while EDITING too, unlike the "Updated" banner. The enqueue-hold parks
            // an editing session's autosave, so without the pill the user has no affordance
            // and no signal at all — they would keep typing into content that is silently
            // not being pushed.
            if viewModel.syncConflict != nil {
                Button {
                    conflictToResolve = viewModel.syncConflict.map(IdentifiedSyncConflict.init)
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        MaterialSymbol(.warning, size: 13)
                        Text(loc[.editor_conflict_pill])
                            .font(DocsFont.footnote)
                    }
                    .foregroundStyle(DocsColor.danger)
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.vertical, DocsSpacing.space2xs)
                    .background(Capsule().fill(DocsColor.gray050))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(loc[.editor_conflict_pill_a11y])
            }

            if viewModel.updateAvailable, !viewModel.isEditing {
                Button {
                    viewModel.applyPendingUpdate()
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        MaterialSymbol(.sync, size: 13)
                        Text(loc[.editor_update_available])
                            .font(DocsFont.footnote)
                    }
                    .foregroundStyle(DocsColor.textBrand)
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.vertical, DocsSpacing.space2xs)
                    .background(Capsule().fill(DocsColor.gray050))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(loc[.editor_update_available_a11y])
            }

            // A queued deletion is not a failure, so it is neither drawn in `danger` nor left
            // without a way out. **This is the only undo affordance that does not depend on
            // finding a list row**, which matters because the rows are account-scoped while
            // the gate is not: a tombstone this session cannot see — another account's, or
            // one whose owner is unknown — would otherwise leave the document permanently
            // unopenable with nothing anywhere in the app to clear it.
            if viewModel.isDocumentPendingDelete {
                pendingDeleteNotice
            } else if let errorKey = viewModel.errorKey {
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.danger)
                    if let errorDetail = viewModel.errorDetail {
                        Text(errorDetail)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
            }

            if viewModel.isLoading {
                ProgressView()
                    .padding(DocsSpacing.spaceBase)
                Spacer()
            } else if viewModel.isEditing {
                editingSurface
            } else {
                readingSurface
            }
        }
    }

    /// Shown instead of the body for a document whose deletion is queued, with the undo beside
    /// it. Deliberately not `errorKey`/`danger` styling: nothing has failed, the deletion is
    /// simply waiting — and the button is what keeps this screen from being a dead end.
    private var pendingDeleteNotice: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            Text(loc[.editor_pending_delete])
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textSecondary)
            DocsButton(title: loc[.pending_delete_undo], variant: .secondary, size: .medium) {
                viewModel.undoPendingDeleteForThisDocument()
                Task { await viewModel.load() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.top, DocsSpacing.spaceXS)
    }

    // MARK: - Editing

    private var editingSurface: some View {
        BlockEditorView(
            viewModel: viewModel, serverOrigin: serverOrigin, isOffline: isOffline, scrollAnchor: scrollAnchor
        ) {
            // The same header the reading surface draws, so the swap moves
            // nothing. Only the status slot differs: `saveStatusDisplay` decides
            // what it says — including holding back any claim of a sync while a
            // conflict parks the push, which is the rule that row exists to
            // honour — and falls back to the reading caption when it has
            // nothing of its own to add (`.none`), so the slot is never empty
            // and its height never changes under the user mid-keystroke.
            EditorDocumentHeader(
                title: viewModel.title, onEditTitle: { viewModel.updateTitle($0) }, reach: reach,
                peers: headerPeers
            ) {
                editingStatus
            }
        }
        .safeAreaInset(edge: .bottom) {
            // A container so the glass surfaces stacked here (the bar, and the
            // slash menu when it is up) are rendered as one system pass and
            // blend where they meet, rather than as separate panes sitting on
            // top of each other.
            GlassEffectContainer(spacing: DocsSpacing.spaceXS) {
                VStack(spacing: DocsSpacing.spaceXS) {
                    if viewModel.isUploadingPhoto {
                        uploadingBanner(loc[.editor_uploading_photo], a11y: loc[.editor_uploading_photo_a11y])
                    }
                    if viewModel.isUploadingAttachment {
                        uploadingBanner(loc[.editor_uploading_file], a11y: loc[.editor_uploading_file_a11y])
                    }
                    if let query = viewModel.slashQueryText {
                        SlashMenuView(
                            query: query, isOffline: isOffline,
                            isLocalDocument: viewModel.isLocalDocument,
                            onSelect: { viewModel.applySlashSelection($0) })
                    }
                    EditorFormattingBar(viewModel: viewModel)
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.bottom, DocsSpacing.spaceXS)
        }
        // The out-of-process system picker: no photo-library usage description and
        // no project.yml change are needed. Do NOT add `photoLibrary: .shared()` —
        // that makes it in-process and would require NSPhotoLibraryUsageDescription.
        .photosPicker(isPresented: $viewModel.isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        // The system document picker, also out of process: no usage description
        // and no project.yml change. `.item` because the server decides what it
        // will accept — the app has no business second-guessing which types a
        // deployment allows.
        .fileImporter(
            isPresented: $viewModel.isAttachmentImporterPresented,
            allowedContentTypes: [.item]
        ) { result in
            // A cancelled pick is `.failure(CocoaError.userCancelled)`; either
            // way there is nothing to insert and nothing to report.
            guard case .success(let url) = result else { return }
            Task { await viewModel.insertAttachment(loadingFile: { try loadPickedAttachmentFile(at: url) }) }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            // Clear immediately so re-picking the same asset fires onChange again.
            selectedPhotoItem = nil
            Task {
                await viewModel.insertPhoto(
                    isOffline: isOffline,
                    loadingData: { try await newItem.loadTransferable(type: Data.self) })
            }
        }
        // `.sheet(item:)` rather than `isPresented`: the request carries the
        // block, span and range the edit applies to, and a fresh `id` per
        // presentation reseeds the fields.
        .sheet(item: $viewModel.linkEditor) { request in
            LinkEditorSheet(
                request: request,
                onSave: { label, url in viewModel.commitLinkEditing(label: label, url: url) },
                onRemove: request.span.map { span in
                    {
                        viewModel.cancelLinkEditing()
                        viewModel.removeLink(blockID: request.blockID, span: span)
                    }
                },
                onCancel: { viewModel.cancelLinkEditing() }
            )
        }
    }

    /// The editing session's save status, in the document header's status slot.
    ///
    /// It used to be a strip pinned *above* the canvas, which cost two jumps:
    /// the reading header's own metadata row had no counterpart while editing,
    /// and the strip appeared out of nothing on the first keystroke
    /// (`saveStatusDisplay` is `.none` while `.idle`) and shoved the whole
    /// document down ~52pt under the caret. Sharing the header's slot fixes
    /// both, and `saveStatusDisplay`'s precedence — including holding back any
    /// claim of a sync while a conflict parks the push — is untouched.
    ///
    /// `.none` falls through to the reading caption rather than collapsing, so
    /// the slot always says *something* and can never change height mid-edit.
    /// The trade this makes: the status now scrolls with the document instead of
    /// staying pinned. Nothing is lost that the user cannot reach — the toolbar
    /// keeps Done, which flushes exactly as tapping "Save" here does.
    @ViewBuilder
    private var editingStatus: some View {
        let display = saveStatusDisplay(
            saveState: viewModel.saveState,
            hasConflict: viewModel.syncConflict != nil,
            hasUnsavedLocalContent: viewModel.hasUnsavedLocalContent)
        if display == .none {
            syncCaptionLabel
        } else {
            SaveStatusIndicator(display: display, onTap: { viewModel.saveNow() })
        }
    }

    /// The reading surface's status slot: the live "Synced 5 minutes ago" /
    /// "Couldn't save · tap to retry" caption.
    ///
    /// Extracted from `headerBlock` when the header became shared, so the two
    /// surfaces' slots are literally the same view where they say the same
    /// thing.
    private var syncCaptionLabel: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let caption = currentSyncCaption(now: context.date)
            SyncCaptionLabel(
                offersRetry: caption.offersRetry,
                text: resolvedCaption(caption.text),
                // The failed-save label only fits the failed caption; a
                // pending-sync retry falls back to its visible text.
                retryAccessibilityLabel: caption.text == .key(.editor_sync_save_failed)
                    ? loc[.editor_sync_save_failed_a11y] : resolvedCaption(caption.text),
                onRetry: { viewModel.saveNow() })
        }
    }

    private func uploadingBanner(_ message: String, a11y: String) -> some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            ProgressView()
            Text(message)
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceXS)
        // Glass like its siblings: this floats in the same container, directly
        // above the formatting bar, so a flat capsule here would read as a
        // material seam on the one surface stack the app renders as glass.
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }

    // MARK: - Reading

    /// The queued-photo state for a block, or nil when it is not a placeholder image.
    private func pendingAttachmentDisplay(for block: EditorBlock) -> PendingAttachmentDisplay? {
        guard case .image(_, let url) = block.kind else { return nil }
        return viewModel.pendingAttachmentDisplay(forPlaceholderURL: url)
    }

    private func pendingAttachmentAlt(for block: EditorBlock) -> String {
        guard case .image(let alt, _) = block.kind else { return "" }
        return alt
    }

    private func retryPendingAttachment(for block: EditorBlock) {
        guard case .image(_, let url) = block.kind else { return }
        viewModel.retryPendingAttachment(placeholderURL: url)
    }

    /// The reading half of the editor.
    ///
    /// Laid out to match `BlockEditorView` block for block: the same header, the
    /// same `EditorBlockMetrics.gutter`, the same `blockSpacing` between rows,
    /// and the same header-to-body gap — so the tap that swaps this for the
    /// editing canvas moves nothing. The rows are named with `EditorScrollTarget`
    /// so the scroll anchor survives that swap too.
    ///
    /// A flat stack rather than nested section stacks, for the same reason:
    /// `.scrollTargetLayout()` makes each *direct child* a scroll target, and a
    /// nested blocks stack would make the whole document one target.
    private var readingSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                readingHeader
                    // Tops the stack's own `blockSpacing` up to the header-to-body
                    // gap, exactly as the editing canvas does.
                    .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
                    .id(EditorScrollTarget.header)

                if viewModel.blocks.isEmpty {
                    // `isDocumentPendingDelete` joins the error check for the same reason the
                    // error is here at all: the gated load leaves `blocks` empty *and* — since the
                    // notice is rendered from the predicate rather than an `errorKey` — no error to
                    // suppress this. Without it the screen claims a document with content is empty
                    // and offers "Start writing", which `canStartEditing` makes a silent no-op.
                    if viewModel.errorKey == nil, !viewModel.isDocumentPendingDelete {
                        emptyContent
                    }
                } else {
                    ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                        // Grouped so the scroll target is named once for the row
                        // whichever branch draws it — a queued photo is still a
                        // block the anchor may land on.
                        Group {
                            // A queued photo renders from the bytes on disk. Branched here
                            // rather than inside `MarkdownBlockView` because the state and the
                            // Retry/Remove intents belong to the view model, which that view
                            // deliberately does not take — and ahead of `MarkdownImageView`,
                            // whose fail-closed policy would otherwise show a tap-to-load card
                            // for a URL that can never be fetched.
                            if let display = pendingAttachmentDisplay(for: block) {
                                PendingAttachmentImageView(
                                    alt: pendingAttachmentAlt(for: block), display: display,
                                    onRetry: { retryPendingAttachment(for: block) },
                                    onRemove: { viewModel.removePendingAttachment(blockID: block.id) })
                            } else {
                                MarkdownBlockView(
                                    block: block, serverOrigin: serverOrigin,
                                    numberedIndex: numberedIndex(of: index, in: viewModel.blocks),
                                    isOffline: isOffline
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.startEditing(focusing: block.id)
                                }
                            }
                        }
                        .id(EditorScrollTarget.block(block.id))
                    }
                }

                subpagesSection
                    .padding(.top, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
                    // `.trailer` — the same name the editing canvas gives the
                    // space below its last block. The two layouts have to offer
                    // the *same* set of scroll targets or the anchor stops
                    // round-tripping: a reader parked past the last block would
                    // hand the editor an id it cannot find (and vice versa), and
                    // the handoff would silently degrade to "open at the top"
                    // exactly where the document is long enough for that to be
                    // the thing the user notices.
                    .id(EditorScrollTarget.trailer)
            }
            .scrollTargetLayout()
            .padding(.horizontal, EditorBlockMetrics.gutter)
            .padding(.top, DocsSpacing.spaceSM)
            .padding(.bottom, DocsSpacing.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(
            id: Binding(get: { scrollAnchor.target }, set: { scrollAnchor.target = $0 }), anchor: .top
        )
        .refreshable {
            await viewModel.refresh()
        }
        // The Subpages rows live in this scroll view, so an open swipe strip closes here for
        // the same reason it does on Home and in the drawer — and guarded the same way, so a
        // swipe that nudges this scroll view does not close its own strip.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe) }
        }
        // A `.link` run in a `Text` — an inline markdown link, or a bare URL the
        // autolinker matched — dispatches through this action. Without an override the
        // default one hands every link to the system, so a link to a sub-page left the app
        // for Safari. Scoped to the reading surface: it is the only subtree that renders
        // content the user didn't type, and the sheets keep the system behavior.
        .environment(\.openURL, OpenURLAction(handler: openLink))
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        switch documentLinkAction(for: url, serverHost: serverHost, currentDocumentID: viewModel.documentID) {
        case .openInBrowser:
            return .systemAction
        case .alreadyOpen:
            return .handled
        case .openInApp(let linkedID):
            // No navigation host (previews, and nothing else today): the link is still a
            // real URL, so let the system have it rather than swallow the tap.
            guard let onOpenDocument else { return .systemAction }
            Task {
                if let document = await viewModel.openLinkedDocument(linkedID) {
                    onOpenDocument(document)
                }
            }
            return .handled
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label {
                Text(loc[.editor_empty_title])
            } icon: {
                MaterialSymbol(.description, size: 20)
            }
        } description: {
            Text(loc[.editor_empty_body])
        } actions: {
            // Offline included: a cached-empty document is a legitimate edit target,
            // and the first keystroke's draft is written before any network attempt.
            Button(loc[.editor_start_writing]) {
                viewModel.startEditing()
            }
            .font(DocsFont.body)
            .foregroundStyle(DocsColor.textBrand)
        }
        .padding(.top, DocsSpacing.spaceLG)
    }

    /// Peers present in this document, read through the manager so the value
    /// tracks both a peer joining/leaving and the manager swapping in a fresh
    /// session — the view never caches a stale session reference. `[]` (bar
    /// hidden) whenever live collaboration is unavailable or nobody else is here.
    private var collaborationPeers: [CollaborationPeer] {
        collaboration.peers(for: viewModel.documentID)
    }

    /// Opens a live-collaboration session once, if we don't already hold one and
    /// live editing is available. A no-op when unavailable (`session(for:)`
    /// returns nil), so it can be retried when availability later flips.
    ///
    /// Also builds the C1 bridge on first call — lazily, because it needs the
    /// `collaboration` manager from `@Environment`, which isn't available in
    /// `init`. Built regardless of whether a session actually opens this call
    /// (retrying availability later must not mint a second bridge instance and
    /// lose the first's identity map / seed state).
    private func requestCollaborationSessionIfNeeded() {
        // First, before the bridge is even built: a document the server has never seen has no
        // collaboration room to join — the socket dials a URL containing its id. A document
        // queued for deletion is the same shape for a different reason: it is on its way out,
        // and "no requests for a tombstoned document" has to include the socket.
        guard !viewModel.isLocalDocument, !viewModel.isDocumentPendingDelete else { return }
        if liveEditingBridge == nil {
            let bridge = LiveEditingBridge(
                documentID: viewModel.documentID, viewModel: viewModel, collaboration: collaboration,
                serverOrigin: "https://\(serverHost)")
            liveEditingBridge = bridge
            // Thread the outbound write path in (C2c). Weak on the VM side, so no cycle.
            // The gate inside `forwardLocalEdit` keeps this a no-op until live-write mode
            // is actually engaged, so classic-only documents are unaffected.
            viewModel.liveWrite = bridge
        }
        guard !holdsCollaborationSession else { return }
        if collaboration.session(for: viewModel.documentID) != nil {
            holdsCollaborationSession = true
            // Register the bridge's synchronous read-apply observer on every session
            // (re)acquisition, NOT once at bridge construction. The manager drops it when
            // this document's entry is torn down after linger, but the bridge (held in
            // `@State`) outlives that, so a reopen must re-register or the C2c stale-baseline
            // race reopens. Keying it to acquisition also means a document that never opens a
            // session (feature off / unsupported / offline) never registers one — no leak.
            liveEditingBridge?.registerReplicaObserver()
        }
    }

    /// The reading canvas's document header: the title as a large content
    /// header (moved out of the nav bar to match the handoff — the bar keeps
    /// only the back button and trailing actions), then the reach pill and the
    /// sync caption on the row beneath it.
    ///
    /// The *same* `EditorDocumentHeader` the editing canvas draws — only the
    /// status slot and the title's editability differ — so the swap between the
    /// two surfaces moves nothing.
    private var readingHeader: some View {
        EditorDocumentHeader(
            title: viewModel.title, onEditTitle: nil, reach: reach, peers: headerPeers
        ) {
            syncCaptionLabel
        }
    }

    /// One Subpages row, wrapped in its swipe container.
    ///
    /// A method rather than inline in the `ForEach`, matching `PagesTreeDrawer.treeRow`: the
    /// row needs several derived values, and `let` bindings inside a `ForEach`'s `ViewBuilder`
    /// defeat its type inference (it falls back to the `Range<Int>` overload and reports the
    /// failure against the collection, several lines away from the cause).
    private func subpageRow(_ child: Document) -> some View {
        // Reading the predicate here registers the `@Observable` dependency, so a sub-page
        // deleted from its own screen strikes through the moment the user pops back, with no
        // children refetch — which offline never comes.
        let isPendingDelete = viewModel.isDeletePending(child)
        let trimmed = child.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let childTitle = trimmed.isEmpty ? loc[.common_untitled] : trimmed
        // Annotated: `onOpenDocument?(child)` is optional-chained, so an inferred closure
        // would be `() -> ()?` and match neither parameter it is handed to.
        let open: () -> Void = {
            if isPendingDelete {
                documentPendingUndo = child
            } else {
                onOpenDocument?(child)
            }
        }

        return SwipeRevealRow(
            id: child.id,
            state: $subpageSwipe,
            // No Pin here: `SubpageRow` renders no pinned state, so the action would succeed
            // with nothing on the row to show for it.
            actions: documentRowSwipeActions(
                isPendingDelete: isPendingDelete,
                isLocalDocument: false,
                isFavorite: child.isFavorite,
                offersPin: false,
                keepLabel: loc[.pending_delete_undo],
                pinLabel: loc[.options_pin],
                unpinLabel: loc[.options_unpin],
                moveLabel: loc[.options_move],
                deleteLabel: loc[.options_delete],
                onKeep: { viewModel.undoPendingDelete(child) },
                onTogglePin: {},
                onMove: { documentPendingMove = child },
                onDelete: { subpagePendingDeleteConfirmation = child }),
            accessibilityLabel: subpageRowAccessibilityLabel(
                title: childTitle,
                summary: child.excerpt,
                childCount: child.numchild,
                pendingDelete: isPendingDelete,
                pendingDeleteLabel: loc[.docrow_pending_delete]),
            onActivate: open
        ) {
            SubpageRow(document: child, pendingDelete: isPendingDelete, onOpen: open)
        }
    }

    private var subpagesSection: some View {
        // 40pt above the rule, 16pt below it before the header (reference spacing).
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space2xs) {
                    MaterialSymbol(.account_tree, size: 16)
                        .accessibilityHidden(true)
                    Text(
                        (viewModel.mergedSubpages?.isEmpty ?? true)
                            ? loc[.editor_subpages_title]
                            : loc.format(.editor_subpages_title_count, viewModel.mergedSubpages?.count ?? 0)
                    )
                    .font(DocsFont.footnote.weight(.semibold))
                    .docsTracking(DocsTypographySpec.footnote, DocsTracking.eyebrow)
                }
                .textCase(.uppercase)
                .foregroundStyle(DocsColor.textTertiary)
                .padding(.horizontal, DocsSpacing.spaceXS)
                // The eyebrow hugs the first row (reference 4pt), not a 12pt gap.
                .padding(.bottom, DocsSpacing.space3xs)

                if let subpages = viewModel.mergedSubpages {
                    if subpages.isEmpty {
                        Text(loc[.editor_subpages_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .padding(.horizontal, DocsSpacing.spaceXS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(subpages) { child in
                                subpageRow(child)
                            }
                        }
                    }
                }
                // nil (never fetched or cached): just the eyebrow — never claim "no subpages".

                // Ungated. Neither being offline nor the parent being unsynced stops this any
                // more: `addSubpage` mints locally in both cases, and the replay POSTs the
                // parent before the sub-page that names it. The gate that used to live here
                // was the whole reason a document created offline offered nothing but a
                // "Subpages" heading.
                Button {
                    Task {
                        if let child = await viewModel.addSubpage() {
                            onOpenDocument?(child)
                        }
                    }
                } label: {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        MaterialSymbol(.add, size: 22)
                        Text(loc[.editor_add_subpage])
                            .docsScaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    }
                    .foregroundStyle(DocsColor.textBrand)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, DocsSpacing.spaceBase)
        }
        // Tops up to the reference's 40pt gap above Subpages. The body stack
        // contributes `blockSpacing` (12) and `readingSurface` adds
        // `headerToBodySpacing - blockSpacing` (12) at the call site, so the
        // remainder here is measured from `spaceMD` — the 24pt those two make
        // between them, which is what this stack used to contribute on its own
        // before the two surfaces were given a shared inter-block gap. Change
        // either metric and the 40pt has to be re-derived; it is spread across
        // two files precisely because the *body* gap is now shared and this one
        // is not.
        .padding(.top, DocsSpacing.spaceXL - DocsSpacing.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currentSyncCaption(now: Date) -> SyncCaption {
        syncCaption(
            hasUnsavedLocalContent: viewModel.hasUnsavedLocalContent,
            hasConflict: viewModel.syncConflict != nil,
            isOffline: isOffline,
            saveState: viewModel.saveState,
            lastSyncedAt: viewModel.lastSyncedAt,
            now: now,
            locale: loc.locale
        )
    }

    private func resolvedCaption(_ text: SyncCaptionText) -> String {
        switch text {
        case .key(let key): return loc[key]
        case .syncedAgo(let ago): return loc.format(.editor_sync_ago, ago)
        }
    }

    /// `MaterialSymbol` renders fine inside a toolbar button (unlike a tab-bar
    /// label, which needs a `UIImage`), so the app's icon set carries over
    /// unchanged. Each button states its own label: the glyph is a
    /// Private-Use-Area character with no spoken text.
    @ViewBuilder
    private func toolbarButton(for action: EditorToolbarAction) -> some View {
        switch action {
        case .edit:
            Button {
                viewModel.startEditing()
            } label: {
                MaterialSymbol(.edit, size: 22)
            }
            // `startEditing` silently declines without loaded content, and offline with
            // nothing cached that is now the common case — where the load error also
            // suppresses "Start writing", leaving Edit as the only affordance on screen
            // doing nothing at all. Mirror the formatting bar's rule: if the view model
            // would decline, don't invite the tap. `canStartEditing` is the very predicate
            // the guard uses, so the two cannot drift; it is keyed to loaded content, not
            // to connectivity — the parameter this resolver dropped.
            .disabled(!viewModel.canStartEditing)
            .accessibilityLabel(loc[.editor_action_edit])

        case .done:
            Button {
                viewModel.finishEditing()
            } label: {
                MaterialSymbol(.check, size: 22, fill: true)
            }
            .accessibilityLabel(loc[.editor_action_done])

        case .share:
            Button {
                isPresentingShareSheet = true
            } label: {
                MaterialSymbol(.share, size: 22)
            }
            .accessibilityLabel(loc[.editor_action_share])

        case .options:
            Button {
                isPresentingOptionsSheet = true
            } label: {
                MaterialSymbol(.more_horiz, size: 22)
            }
            .accessibilityLabel(loc[.editor_action_options])
        }
    }

    /// The peers the shared header's `PresenceBar` draws.
    ///
    /// The Options button used to carry a presence *count badge* while editing,
    /// because the reading surface's avatar stack had no editing counterpart —
    /// "the same information, in the space a toolbar has". The document header is
    /// shared now and draws `PresenceBar` in both modes, so that badge became a
    /// second copy of the same fact one row above it, and it is gone. Presence
    /// has one home again, and `presentedPeerCount` — with its tests — becomes
    /// the one rule for whether peer state is fresh enough to show at all,
    /// applied on **both** surfaces. Before, only the badge honoured it: the
    /// reading surface drew its avatars offline, where they are whatever the
    /// socket last said.
    private var headerPeers: [CollaborationPeer] {
        presentedPeerCount(peerCount: collaborationPeers.count, isOffline: isOffline) == nil
            ? [] : collaborationPeers
    }
}

#Preview {
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)
    EditorView(
        viewModel: EditorViewModel(
            client: client,
            documentID: UUID(),
            title: "Q3 Planning",
            saveCoordinator: DocumentSaveCoordinator(client: client, backgroundTasks: .noop),
            serverOrigin: "https://docs.llun.dev"
        ),
        reach: .restricted,
        serverHost: "docs.llun.dev",
        serverOrigin: "https://docs.llun.dev"
    )
    .environment(LocalizationStore())
    .environment(DocumentCollaborationManager.inert())
    .environment(AttachmentLoader.inert())
}
